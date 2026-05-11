-module(ersub_openai_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            handle_post(Req0, State);
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, #{}, <<>>, Req0),
            {ok, Req, State};
        _ ->
            Req = reply_json(405, #{error => #{
                type => <<"invalid_request_error">>,
                message => <<"Method not allowed">>
            }}, Req0),
            {ok, Req, State}
    end.

handle_post(Req0, State) ->
    case ersub_auth_middleware:authenticate(Req0) of
        {error, Reason} ->
            Req = ersub_auth_middleware:reply_error(Req0, 401,
                auth_error_message(Reason)),
            {ok, Req, State};
        {ok, AuthCtx} ->
            #{user_id := UserId, key_rpm_limit := KeyRpm,
              user_rpm_limit := UserRpm,
              user_max_concurrency := MaxConc} = AuthCtx,
            %% Rate limit
            EffRpm = effective_rpm(KeyRpm, UserRpm),
            case ersub_rate_limiter:check_rpm(user, UserId, EffRpm) of
                {error, rate_limited} ->
                    Req = reply_json(429, #{error => #{
                        type => <<"rate_limit_error">>,
                        message => <<"Rate limit exceeded">>
                    }}, Req0),
                    {ok, Req, State};
                ok ->
                    %% Concurrency
                    EffConc = effective_conc(maps:get(key_max_concurrency, AuthCtx), MaxConc),
                    case ersub_concurrency_srv:acquire(UserId, EffConc) of
                        {rejected, queue_full} ->
                            Req = reply_json(429, #{error => #{
                                type => <<"rate_limit_error">>,
                                message => <<"Too many concurrent requests">>
                            }}, Req0),
                            {ok, Req, State};
                        {ok, ConcRef} ->
                            try
                                do_pipeline(Req0, State, AuthCtx)
                            after
                                ersub_concurrency_srv:release(UserId, ConcRef)
                            end
                    end
            end
    end.

do_pipeline(Req0, State, AuthCtx) ->
    #{user_id := UserId} = AuthCtx,
    case read_body_json(Req0) of
        {error, Reason, Req1} ->
            Req = reply_json(400, #{error => #{
                type => <<"invalid_request_error">>,
                message => Reason
            }}, Req1),
            {ok, Req, State};
        {ok, Parsed, Body, Req1} ->
            case ersub_billing_srv:check_balance(UserId, 0.001) of
                {error, insufficient_balance} ->
                    Req = reply_json(402, #{error => #{
                        type => <<"billing_error">>,
                        message => <<"Insufficient balance">>
                    }}, Req1),
                    {ok, Req, State};
                ok ->
                    Model = maps:get(<<"model">>, Parsed, <<>>),
                    SchedulerReq = #{
                        user_id => UserId,
                        platform => <<"openai">>,
                        session_hash => <<>>,
                        model => Model
                    },
                    case ersub_scheduler_srv:select_account(SchedulerReq) of
                        {error, no_available_account} ->
                            Req = reply_json(503, #{error => #{
                                type => <<"api_error">>,
                                message => <<"No upstream accounts available">>
                            }}, Req1),
                            {ok, Req, State};
                        {ok, Account} ->
                            forward_to_openai(Req1, State, Account, Parsed, Body, AuthCtx)
                    end
            end
    end.

forward_to_openai(Req0, State, Account, Parsed, Body, AuthCtx) ->
    #{credentials := Creds, base_url := BaseUrl0} = Account,
    ApiKey = maps:get(<<"api_key">>, Creds, maps:get(api_key, Creds, <<>>)),
    BaseUrl = case BaseUrl0 of
        null -> <<"https://api.openai.com">>;
        undefined -> <<"https://api.openai.com">>;
        <<>> -> <<"https://api.openai.com">>;
        U -> U
    end,
    IsStream = maps:get(<<"stream">>, Parsed, false),
    Url = <<BaseUrl/binary, "/v1/chat/completions">>,
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>}
    ],
    case IsStream of
        true ->
            ConnInfo = parse_url_to_map(Url),
            Opts = #{account_id => maps:get(id, Account, 0),
                     request_id => generate_request_id(),
                     model => maps:get(<<"model">>, Parsed, <<>>)},
            case ersub_stream_fsm:start(ConnInfo, Headers, Body, Opts) of
                {ok, FsmPid} ->
                    handle_stream(Req0, State, FsmPid);
                {error, Reason} ->
                    logger:error("OpenAI stream failed: ~p", [Reason]),
                    Req = reply_json(502, #{error => #{
                        type => <<"api_error">>,
                        message => <<"Upstream connection failed">>
                    }}, Req0),
                    {ok, Req, State}
            end;
        _ ->
            case ersub_upstream_pool:request(<<"POST">>, Url, Headers, Body, #{}) of
                {ok, Status, RespHeaders, RespBody} ->
                    case Status of
                        S when S >= 200, S < 300 ->
                            Model = maps:get(<<"model">>, Parsed, <<>>),
                            ersub_billing_helper:record_non_streaming_usage(
                                AuthCtx, maps:get(id, Account, 0), RespBody, Model);
                        _ -> ok
                    end,
                    Filtered = filter_headers(RespHeaders),
                    Req = cowboy_req:reply(Status, Filtered, RespBody, Req0),
                    {ok, Req, State};
                {error, Reason} ->
                    logger:error("OpenAI request failed: ~p", [Reason]),
                    Req = reply_json(502, #{error => #{
                        type => <<"api_error">>,
                        message => <<"Upstream request failed">>
                    }}, Req0),
                    {ok, Req, State}
            end
    end.

handle_stream(Req0, State, FsmPid) ->
    receive
        {stream_headers, FsmPid, _Status, RespHeaders} ->
            Filtered = filter_headers(maps:from_list(RespHeaders)),
            StreamHeaders = Filtered#{
                <<"content-type">> => <<"text/event-stream">>,
                <<"cache-control">> => <<"no-cache">>
            },
            Req1 = cowboy_req:stream_reply(200, StreamHeaders, Req0),
            stream_loop(Req1, State, FsmPid);
        {stream_error, FsmPid, {upstream_error, ErrStatus, _, ErrBody}} ->
            Req = cowboy_req:reply(ErrStatus,
                #{<<"content-type">> => <<"application/json">>},
                ErrBody, Req0),
            {ok, Req, State};
        {stream_error, FsmPid, Reason} ->
            logger:error("OpenAI stream error: ~p", [Reason]),
            Req = reply_json(502, #{error => #{
                type => <<"api_error">>,
                message => <<"Upstream streaming failed">>
            }}, Req0),
            {ok, Req, State}
    after 30000 ->
        catch ersub_stream_fsm:stop(FsmPid),
        Req = reply_json(504, #{error => #{
            type => <<"api_error">>,
            message => <<"Upstream timeout">>
        }}, Req0),
        {ok, Req, State}
    end.

stream_loop(Req, State, FsmPid) ->
    receive
        {stream_chunk, FsmPid, Chunk} ->
            cowboy_req:stream_body(Chunk, nofin, Req),
            stream_loop(Req, State, FsmPid);
        {stream_done, FsmPid, _} ->
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State};
        {stream_error, FsmPid, _} ->
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State}
    after 600000 ->
        cowboy_req:stream_body(<<>>, fin, Req),
        {ok, Req, State}
    end.

%%% Internal

read_body_json(Req0) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => 268435456, period => 60000}),
    case jsx:is_json(Body) of
        true -> {ok, jsx:decode(Body, [return_maps]), Body, Req1};
        false -> {error, <<"Invalid JSON">>, Req1}
    end.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

filter_headers(Headers) ->
    maps:filter(fun(K, _) ->
        K2 = string:lowercase(K),
        lists:member(K2, [<<"content-type">>, <<"x-request-id">>,
                          <<"openai-processing-ms">>])
    end, Headers).

parse_url_to_map(Url) when is_binary(Url) ->
    case uri_string:parse(binary_to_list(Url)) of
        #{scheme := S, host := H} = P ->
            #{scheme => list_to_atom(S),
              host => list_to_binary(H),
              port => maps:get(port, P, case S of "https" -> 443; _ -> 80 end),
              path => list_to_binary(maps:get(path, P, "/"))};
        _ ->
            #{scheme => https, host => <<"api.openai.com">>,
              port => 443, path => <<"/v1/chat/completions">>}
    end.

generate_request_id() ->
    iolist_to_binary([<<"req-">>, binary:encode_hex(crypto:strong_rand_bytes(8))]).

effective_rpm(null, null) -> 0;
effective_rpm(undefined, undefined) -> 0;
effective_rpm(null, U) -> U;
effective_rpm(undefined, U) -> U;
effective_rpm(K, _) when is_integer(K), K > 0 -> K;
effective_rpm(_, U) when is_integer(U), U > 0 -> U;
effective_rpm(_, _) -> 0.

effective_conc(null, UserMax) -> UserMax;
effective_conc(undefined, UserMax) -> UserMax;
effective_conc(KC, _) when is_integer(KC), KC > 0 -> KC;
effective_conc(_, UserMax) -> UserMax.

auth_error_message(missing_key) -> <<"Missing API key">>;
auth_error_message(invalid_key) -> <<"Invalid API key">>;
auth_error_message(user_banned) -> <<"Account suspended">>;
auth_error_message(key_inactive) -> <<"API key inactive">>;
auth_error_message(key_expired) -> <<"API key expired">>.
