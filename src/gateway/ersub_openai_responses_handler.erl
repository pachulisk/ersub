-module(ersub_openai_responses_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%% OpenAI Responses API (/openai/v1/responses) — used by Codex CLI
%% Proxies to upstream with auth + rate limiting + billing pipeline

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, State);
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, #{}, <<>>, Req0),
            {ok, Req, State};
        _ ->
            {ok, reply_json(405, #{error => #{message => <<"Method not allowed">>}}, Req0), State}
    end.

handle_post(Req0, State) ->
    case ersub_auth_middleware:authenticate(Req0) of
        {error, Reason} ->
            {ok, ersub_auth_middleware:reply_error(Req0, 401, auth_msg(Reason)), State};
        {ok, AuthCtx} ->
            #{user_id := UserId, user_max_concurrency := MaxConc} = AuthCtx,
            EffConc = eff_conc(maps:get(key_max_concurrency, AuthCtx), MaxConc),
            case ersub_concurrency_srv:acquire(UserId, EffConc) of
                {rejected, queue_full} ->
                    {ok, reply_json(429, #{error => #{message => <<"Too many requests">>}}, Req0), State};
                {ok, ConcRef} ->
                    try do_pipeline(Req0, State, AuthCtx)
                    after ersub_concurrency_srv:release(UserId, ConcRef)
                    end
            end
    end.

do_pipeline(Req0, State, AuthCtx) ->
    #{user_id := UserId} = AuthCtx,
    case cowboy_req:read_body(Req0, #{length => 268435456}) of
        {ok, Body, Req1} ->
            case jsx:is_json(Body) of
                false ->
                    {ok, reply_json(400, #{error => #{message => <<"Invalid JSON">>}}, Req1), State};
                true ->
                    Parsed = jsx:decode(Body, [return_maps]),
                    %% Strip service_tier to avoid 400 from Codex/Responses endpoint
                    CleanParsed = maps:without([<<"service_tier">>], Parsed),
                    %% Inject default instructions if missing (Bug #2409)
                    CleanParsed2 = case maps:is_key(<<"instructions">>, CleanParsed) of
                        true -> CleanParsed;
                        false ->
                            DefaultInst = ersub_config_srv:get(default_instructions, undefined),
                            case DefaultInst of
                                undefined -> CleanParsed;
                                Inst -> CleanParsed#{<<"instructions">> => Inst}
                            end
                    end,
                    %% Bug #2147: Strip system messages for OAuth Codex endpoint
                    %% The Codex internal endpoint doesn't accept role:"system" in input
                    CleanParsed3 = strip_system_messages_if_needed(CleanParsed2),
                    CleanBody = jsx:encode(CleanParsed3),
                    %% Extract previous_response_id for sticky session (Bug #2411)
                    PrevResponseId = maps:get(<<"previous_response_id">>, CleanParsed2, <<>>),
                    SessionHash = case PrevResponseId of
                        <<>> -> <<>>;
                        null -> <<>>;
                        PRI -> crypto:hash(sha256, PRI)
                    end,
                    case ersub_billing_srv:check_balance(UserId, 0.001) of
                        {error, insufficient_balance} ->
                            {ok, reply_json(402, #{error => #{message => <<"Insufficient balance">>}}, Req1), State};
                        ok ->
                            Model = maps:get(<<"model">>, CleanParsed2, <<>>),
                            case ersub_scheduler_srv:select_account(#{
                                user_id => UserId, platform => <<"openai">>,
                                session_hash => SessionHash, model => Model
                            }) of
                                {error, no_available_account} ->
                                    {ok, reply_json(503, #{error => #{message => <<"No accounts">>}}, Req1), State};
                                {ok, Account} ->
                                    forward(Req1, State, Account, CleanParsed2, CleanBody, AuthCtx, UserId)
                            end
                    end
            end;
        _ ->
            {ok, reply_json(400, #{error => #{message => <<"Read failed">>}}, Req0), State}
    end.

forward(Req0, State, Account, Parsed, Body, AuthCtx, UserId) ->
    #{credentials := Creds, base_url := BaseUrl0} = Account,
    ApiKey = maps:get(<<"api_key">>, Creds, maps:get(api_key, Creds, <<>>)),
    DefaultUrl = maps:get(<<"base-url">>, ersub_clips_config:get_platform(<<"openai">>), <<"https://api.openai.com">>),
    BaseUrl = case BaseUrl0 of
        B when B =:= null; B =:= undefined; B =:= <<>> -> DefaultUrl;
        U -> U
    end,
    IsStream = maps:get(<<"stream">>, Parsed, false),
    Url = <<BaseUrl/binary, "/v1/responses">>,
    Headers = [{<<"content-type">>, <<"application/json">>},
               {<<"authorization">>, <<"Bearer ", ApiKey/binary>>}],
    case IsStream of
        true ->
            ConnInfo = parse_url(Url),
            {PeerIP, _PeerPort} = cowboy_req:peer(Req0),
            IPBin = list_to_binary(inet:ntoa(PeerIP)),
            LogCtx = #{
                user_id => UserId,
                account_id => maps:get(id, Account, 0),
                platform => <<"openai">>,
                model => maps:get(<<"model">>, Parsed, <<>>)
            },
            case ersub_stream_fsm:start(ConnInfo, Headers, Body,
                    #{account_id => maps:get(id, Account, 0),
                      request_id => gen_req_id(),
                      model => maps:get(<<"model">>, Parsed, <<>>),
                      user_id => maps:get(user_id, AuthCtx, undefined),
                      key_id => maps:get(key_id, AuthCtx, undefined),
                      ip_address => IPBin}) of
                {ok, FsmPid} -> handle_stream(Req0, State, FsmPid, LogCtx);
                {error, Reason} ->
                    ersub_system_log:log_request_error(LogCtx#{
                        status_code => 502,
                        error_type => <<"connection">>,
                        error_message => iolist_to_binary(
                            io_lib:format("~p", [Reason]))
                    }),
                    {ok, reply_json(502, #{error => #{message => <<"Connect failed">>}}, Req0), State}
            end;
        _ ->
            case ersub_upstream_pool:request(<<"POST">>, Url, Headers, Body, #{}) of
                {ok, S, RH, RB} ->
                    case S of
                        Sc when Sc >= 200, Sc < 300 ->
                            Model = maps:get(<<"model">>, Parsed, <<>>),
                            ersub_billing_helper:record_non_streaming_usage(
                                AuthCtx, maps:get(id, Account, 0), RB, Model),
                            %% Store session stickiness for response_id (Bug #2411)
                            case extract_response_id(RB) of
                                {ok, NewRespId} ->
                                    RespHash = crypto:hash(sha256, NewRespId),
                                    ersub_session_srv:store(UserId, RespHash, maps:get(id, Account, 0));
                                _ -> ok
                            end;
                        _ ->
                            ersub_system_log:log_request_error(#{
                                user_id => UserId,
                                account_id => maps:get(id, Account, null),
                                platform => <<"openai">>,
                                model => maps:get(<<"model">>, Parsed, <<>>),
                                status_code => S,
                                error_type => <<"upstream">>,
                                error_message => RB
                            })
                    end,
                    {ok, cowboy_req:reply(S, filter_h(RH), RB, Req0), State};
                {error, Reason} ->
                    ersub_system_log:log_request_error(#{
                        user_id => UserId,
                        account_id => maps:get(id, Account, null),
                        platform => <<"openai">>,
                        model => maps:get(<<"model">>, Parsed, <<>>),
                        status_code => 502,
                        error_type => <<"connection">>,
                        error_message => iolist_to_binary(
                            io_lib:format("~p", [Reason]))
                    }),
                    {ok, reply_json(502, #{error => #{message => <<"Upstream failed">>}}, Req0), State}
            end
    end.

handle_stream(Req0, State, FsmPid, LogCtx) ->
    receive
        {stream_headers, FsmPid, _, RH} ->
            H = (filter_h(maps:from_list(RH)))#{<<"content-type">> => <<"text/event-stream">>},
            Req1 = cowboy_req:stream_reply(200, H, Req0),
            stream_loop(Req1, State, FsmPid, LogCtx);
        {stream_error, FsmPid, {upstream_error, S, _, B}} ->
            ersub_system_log:log_request_error(LogCtx#{
                status_code => S,
                error_type => <<"upstream">>,
                error_message => B
            }),
            {ok, cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, B, Req0), State};
        {stream_error, FsmPid, Reason} ->
            ersub_system_log:log_request_error(LogCtx#{
                status_code => 502,
                error_type => <<"connection">>,
                error_message => iolist_to_binary(
                    io_lib:format("~p", [Reason]))
            }),
            {ok, reply_json(502, #{error => #{message => <<"Stream failed">>}}, Req0), State}
    after 30000 ->
        catch ersub_stream_fsm:stop(FsmPid),
        ersub_system_log:log_request_error(LogCtx#{
            status_code => 504,
            error_type => <<"timeout">>,
            error_message => <<"Upstream timeout">>
        }),
        {ok, reply_json(504, #{error => #{message => <<"Timeout">>}}, Req0), State}
    end.

stream_loop(Req, State, Pid, LogCtx) ->
    receive
        {stream_chunk, Pid, C} ->
            cowboy_req:stream_body(C, nofin, Req),
            stream_loop(Req, State, Pid, LogCtx);
        {stream_done, Pid, _} ->
            %% Flush any remaining chunks in mailbox before closing (Bug #2245)
            flush_remaining_chunks(Req, Pid),
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State};
        {stream_error, Pid, Reason} ->
            ersub_system_log:log_request_error(LogCtx#{
                status_code => 502,
                error_type => <<"stream">>,
                error_message => iolist_to_binary(
                    io_lib:format("~p", [Reason]))
            }),
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State}
    after 600000 ->
        cowboy_req:stream_body(<<>>, fin, Req),
        {ok, Req, State}
    end.

reply_json(S, B, R) -> cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).
filter_h(H) -> maps:filter(fun(K,_) -> lists:member(string:lowercase(K), [<<"content-type">>,<<"x-request-id">>]) end, H).
parse_url(U) -> case uri_string:parse(binary_to_list(U)) of #{scheme:=S,host:=H}=P -> #{scheme=>list_to_atom(S),host=>list_to_binary(H),port=>maps:get(port,P,case S of "https"->443;_->80 end),path=>list_to_binary(maps:get(path,P,"/"))}; _ -> #{scheme=>https,host=><<"api.openai.com">>,port=>443,path=><<"/v1/responses">>} end.
gen_req_id() -> iolist_to_binary([<<"req-">>, binary:encode_hex(crypto:strong_rand_bytes(8))]).
eff_conc(null, U) -> U; eff_conc(undefined, U) -> U; eff_conc(K, _) when is_integer(K), K > 0 -> K; eff_conc(_, U) -> U.
auth_msg(missing_key) -> <<"Missing API key">>; auth_msg(invalid_key) -> <<"Invalid API key">>; auth_msg(_) -> <<"Auth failed">>.

extract_response_id(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        case maps:get(<<"id">>, Json, undefined) of
            undefined -> error;
            Id -> {ok, Id}
        end
    catch _:_ -> error
    end.

flush_remaining_chunks(Req, Pid) ->
    receive
        {stream_chunk, Pid, C} ->
            cowboy_req:stream_body(C, nofin, Req),
            flush_remaining_chunks(Req, Pid)
    after 0 -> ok
    end.

%% Bug #2147: Strip system role messages from input array.
%% The Codex internal endpoint (chatgpt.com/backend-api/codex/responses)
%% rejects role:"system" in the input array.
%% Only strip when the config flag is set (for OAuth/Codex accounts).
strip_system_messages_if_needed(Parsed) ->
    case ersub_config_srv:get(strip_responses_system_messages, false) of
        true ->
            Input = maps:get(<<"input">>, Parsed, []),
            case is_list(Input) of
                true ->
                    Filtered = [Item || Item <- Input,
                                not is_system_message(Item)],
                    Parsed#{<<"input">> => Filtered};
                false ->
                    Parsed
            end;
        false ->
            Parsed
    end.

is_system_message(#{<<"role">> := <<"system">>}) -> true;
is_system_message(_) -> false.
