-module(ersub_openai_ws_handler).

%% Cowboy WebSocket handler for OpenAI Responses v2 mode.
%% Bidirectional frame-level relay between client and upstream.

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

-record(state, {
    user_id     :: integer(),
    account_id  :: integer(),
    conn_pid    :: pid() | undefined,
    conn_mref   :: reference() | undefined,
    stream_ref  :: reference() | undefined,
    session_id  :: binary(),
    metrics     :: map()
}).

%%% Cowboy callbacks

init(Req, _Opts) ->
    %% Authenticate via x-api-key or Authorization header
    case ersub_auth_middleware:authenticate(Req) of
        {error, _Reason} ->
            Req2 = cowboy_req:reply(401,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":\"authentication_required\"}">>, Req),
            {ok, Req2, undefined};
        {ok, AuthCtx} ->
            #{user_id := UserId} = AuthCtx,
            %% Upgrade to WebSocket
            State = #state{
                user_id = UserId,
                session_id = generate_session_id(),
                metrics = #{frames_in => 0, frames_out => 0,
                            start_time => erlang:monotonic_time(millisecond),
                            errors => 0}
            },
            {cowboy_websocket, Req, State, #{
                idle_timeout => 600000,
                max_frame_size => 16777216  %% 16MB
            }}
    end.

websocket_init(State) ->
    %% Select upstream account and connect
    case ersub_scheduler_srv:select_account(#{
        user_id => State#state.user_id,
        platform => <<"openai">>,
        session_hash => State#state.session_id,
        model => <<"gpt-4o">>
    }) of
        {ok, Account} ->
            AccountId = maps:get(id, Account),
            case connect_upstream(Account) of
                {ok, ConnPid, MRef, StreamRef} ->
                    {ok, State#state{
                        account_id = AccountId,
                        conn_pid = ConnPid,
                        conn_mref = MRef,
                        stream_ref = StreamRef
                    }};
                {error, Reason} ->
                    logger:error("WS upstream connect failed: ~p", [Reason]),
                    {[{close, 1011, <<"Upstream unavailable">>}], State}
            end;
        {error, no_available_account} ->
            {[{close, 1013, <<"No accounts">>}], State}
    end.

%% Client → Upstream
websocket_handle({text, Frame}, State) ->
    case State#state.conn_pid of
        undefined ->
            {ok, State};
        ConnPid ->
            gun:ws_send(ConnPid, State#state.stream_ref, {text, Frame}),
            Metrics = State#state.metrics,
            NewMetrics = Metrics#{frames_in => maps:get(frames_in, Metrics) + 1},
            {ok, State#state{metrics = NewMetrics}}
    end;
websocket_handle({binary, Frame}, State) ->
    case State#state.conn_pid of
        undefined -> {ok, State};
        ConnPid ->
            gun:ws_send(ConnPid, State#state.stream_ref, {binary, Frame}),
            {ok, State}
    end;
websocket_handle({ping, _}, State) ->
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

%% Upstream → Client
websocket_info({gun_ws, ConnPid, _StreamRef, {text, Frame}},
               #state{conn_pid = ConnPid} = State) ->
    State2 = maybe_handle_rate_limit(Frame, State),
    Metrics = State2#state.metrics,
    NewMetrics = Metrics#{frames_out => maps:get(frames_out, Metrics) + 1},
    {[{text, Frame}], State2#state{metrics = NewMetrics}};

websocket_info({gun_ws, ConnPid, _StreamRef, {binary, Frame}},
               #state{conn_pid = ConnPid} = State) ->
    {[{binary, Frame}], State};

websocket_info({gun_ws, ConnPid, _StreamRef, close},
               #state{conn_pid = ConnPid} = State) ->
    log_metrics(State),
    {[{close, 1000, <<"upstream closed">>}], State#state{conn_pid = undefined}};

websocket_info({gun_ws, ConnPid, _StreamRef, {close, Code, Reason}},
               #state{conn_pid = ConnPid} = State) ->
    log_metrics(State),
    {[{close, Code, Reason}], State#state{conn_pid = undefined}};

websocket_info({gun_error, ConnPid, _, Reason},
               #state{conn_pid = ConnPid} = State) ->
    logger:error("WS upstream error: ~p", [Reason]),
    Metrics = State#state.metrics,
    NewMetrics = Metrics#{errors => maps:get(errors, Metrics) + 1},
    {[{close, 1011, <<"upstream error">>}], State#state{metrics = NewMetrics}};

websocket_info({'DOWN', MRef, process, ConnPid, Reason},
               #state{conn_pid = ConnPid, conn_mref = MRef} = State) ->
    logger:warning("WS upstream down: ~p", [Reason]),
    {[{close, 1011, <<"upstream down">>}], State#state{conn_pid = undefined}};

websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, undefined) ->
    ok;
terminate(_Reason, _Req, State) ->
    log_metrics(State),
    cleanup(State),
    ok.

%%% Internal

connect_upstream(Account) ->
    #{credentials := Creds, base_url := BaseUrl0} = Account,
    ApiKey = maps:get(<<"api_key">>, Creds, maps:get(api_key, Creds, <<>>)),
    BaseUrl = case BaseUrl0 of
        B when B =:= null; B =:= undefined; B =:= <<>> ->
            <<"wss://api.openai.com">>;
        U -> U
    end,
    {Host, Port, Path} = parse_ws_url(BaseUrl),
    GunOpts = #{
        connect_timeout => 10000,
        protocols => [http],
        ws_opts => #{compress => true}
    },
    case gun:open(Host, Port, GunOpts#{transport => tls,
                                        tls_opts => [{verify, verify_none}]}) of
        {ok, ConnPid} ->
            MRef = monitor(process, ConnPid),
            case gun:await_up(ConnPid, 10000, MRef) of
                {ok, _} ->
                    WsHeaders = [
                        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>}
                    ],
                    StreamRef = gun:ws_upgrade(ConnPid, Path, WsHeaders),
                    receive
                        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
                            {ok, ConnPid, MRef, StreamRef};
                        {gun_response, ConnPid, _, _, Status, _} ->
                            demonitor(MRef, [flush]),
                            gun:close(ConnPid),
                            {error, {ws_upgrade_failed, Status}};
                        {gun_error, ConnPid, StreamRef, Reason} ->
                            demonitor(MRef, [flush]),
                            gun:close(ConnPid),
                            {error, {ws_error, Reason}}
                    after 10000 ->
                        demonitor(MRef, [flush]),
                        gun:close(ConnPid),
                        {error, ws_upgrade_timeout}
                    end;
                {error, Reason} ->
                    demonitor(MRef, [flush]),
                    gun:close(ConnPid),
                    {error, {connect, Reason}}
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

parse_ws_url(Url) when is_binary(Url) ->
    UrlStr = binary_to_list(Url),
    case uri_string:parse(UrlStr) of
        #{host := H} = P ->
            Port = maps:get(port, P, 443),
            Path = case maps:get(path, P, "/") of
                "" -> "/v1/realtime";
                Pa -> Pa
            end,
            {H, Port, list_to_binary(Path)};
        _ ->
            {"api.openai.com", 443, <<"/v1/realtime">>}
    end.

maybe_handle_rate_limit(Frame, State) ->
    case jsx:is_json(Frame) of
        true ->
            try
                Json = jsx:decode(Frame, [return_maps]),
                case maps:get(<<"type">>, Json, undefined) of
                    <<"rate_limit">> ->
                        logger:warning("WS rate limit signal: account=~p",
                                       [State#state.account_id]),
                        State;
                    _ -> State
                end
            catch _:_ -> State
            end;
        false -> State
    end.

log_metrics(#state{metrics = M, user_id = UID, account_id = AID, session_id = SID}) ->
    Duration = erlang:monotonic_time(millisecond) - maps:get(start_time, M, 0),
    logger:info("WS session ~s: user=~p account=~p frames_in=~p frames_out=~p "
                "errors=~p duration_ms=~p",
                [SID, UID, AID,
                 maps:get(frames_in, M, 0), maps:get(frames_out, M, 0),
                 maps:get(errors, M, 0), Duration]).

cleanup(#state{conn_pid = undefined}) -> ok;
cleanup(#state{conn_pid = ConnPid, conn_mref = MRef}) ->
    demonitor(MRef, [flush]),
    gun:close(ConnPid).

generate_session_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8)).
