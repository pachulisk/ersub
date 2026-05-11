-module(ersub_claude_handler).
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
    %% 1. Authenticate
    case ersub_auth_middleware:authenticate(Req0) of
        {error, Reason} ->
            Req = handle_auth_error(Reason, Req0),
            {ok, Req, State};
        {ok, AuthCtx} ->
            %% 2. IP access check
            case check_ip_access(Req0, AuthCtx) of
                deny ->
                    Req = reply_json(403, #{error => #{
                        type => <<"permission_error">>,
                        message => <<"IP address not allowed">>
                    }}, Req0),
                    {ok, Req, State};
                allow ->
                    handle_authenticated(Req0, State, AuthCtx)
            end
    end.

handle_authenticated(Req0, State, AuthCtx) ->
    #{user_id := UserId, key_rpm_limit := KeyRpm, user_rpm_limit := UserRpm,
      key_id := _KeyId, user_max_concurrency := MaxConc} = AuthCtx,

    %% 3. Rate limit check
    EffectiveRpm = effective_rpm(KeyRpm, UserRpm),
    case ersub_rate_limiter:check_rpm(user, UserId, EffectiveRpm) of
        {error, rate_limited} ->
            Req = reply_json(429, #{error => #{
                type => <<"rate_limit_error">>,
                message => <<"Rate limit exceeded">>
            }}, Req0),
            {ok, Req, State};
        ok ->
            %% 4. Concurrency check
            EffectiveConc = case maps:get(key_max_concurrency, AuthCtx) of
                null -> MaxConc;
                undefined -> MaxConc;
                KC when is_integer(KC), KC > 0 -> KC;
                _ -> MaxConc
            end,
            case ersub_concurrency_srv:acquire(UserId, EffectiveConc) of
                {rejected, queue_full} ->
                    Req = reply_json(429, #{error => #{
                        type => <<"rate_limit_error">>,
                        message => <<"Too many concurrent requests">>
                    }}, Req0),
                    {ok, Req, State};
                {ok, ConcRef} ->
                    try
                        do_request_pipeline(Req0, State, AuthCtx)
                    after
                        ersub_concurrency_srv:release(UserId, ConcRef)
                    end
            end
    end.

do_request_pipeline(Req0, State, AuthCtx) ->
    #{user_id := UserId} = AuthCtx,
    %% 5. Read request body
    case read_body(Req0) of
        {error, Req1} ->
            Req = reply_json(400, #{error => #{
                type => <<"invalid_request_error">>,
                message => <<"Failed to read request body">>
            }}, Req1),
            {ok, Req, State};
        {ok, Body, Req1} ->
            case jsx:is_json(Body) of
                false ->
                    Req = reply_json(400, #{error => #{
                        type => <<"invalid_request_error">>,
                        message => <<"Invalid JSON body">>
                    }}, Req1),
                    {ok, Req, State};
                true ->
                    Parsed = jsx:decode(Body, [return_maps]),
                    %% 6. Balance pre-check
                    case ersub_billing_srv:check_balance(UserId, 0.001) of
                        {error, insufficient_balance} ->
                            Req = reply_json(402, #{error => #{
                                type => <<"billing_error">>,
                                message => <<"Insufficient balance">>
                            }}, Req1),
                            {ok, Req, State};
                        ok ->
                            %% 7. Select account via scheduler with failover
                            Model = maps:get(<<"model">>, Parsed, <<>>),
                            SessionHash = compute_session_hash(Parsed),
                            SchedulerReq = #{
                                user_id => UserId,
                                platform => <<"claude">>,
                                session_hash => SessionHash,
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
                                    do_forward(Req1, State, Account, Parsed, Body, AuthCtx)
                            end
                    end
            end
    end.

do_forward(Req0, State, Account, Parsed, OrigBody, AuthCtx) ->
    #{credentials := Creds, base_url := BaseUrl0} = Account,
    ApiKey = maps:get(<<"api_key">>, Creds, maps:get(api_key, Creds, <<>>)),
    BaseUrl = case BaseUrl0 of
        null -> <<"https://api.anthropic.com">>;
        undefined -> <<"https://api.anthropic.com">>;
        <<>> -> <<"https://api.anthropic.com">>;
        U -> U
    end,

    IsStream = maps:get(<<"stream">>, Parsed, false),
    %% For MVP, only handle non-streaming
    %% Streaming will be added in P2-01

    AccountType = maps:get(account_type, Account, <<"api_key">>),
    RequestModel = maps:get(<<"model">>, Parsed, <<>>),
    Url = case AccountType of
        <<"bedrock">> ->
            BRegion = maps:get(<<"region">>, Creds, <<"us-east-1">>),
            BModel = case RequestModel of <<>> -> <<"anthropic.claude-v2">>; M -> M end,
            iolist_to_binary([<<"https://bedrock-runtime.">>, BRegion,
                              <<".amazonaws.com/model/">>, BModel, <<"/invoke">>]);
        _ ->
            <<BaseUrl/binary, "/v1/messages">>
    end,
    BaseHeaders = [
        {<<"content-type">>, <<"application/json">>},
        {<<"anthropic-version">>, <<"2023-06-01">>}
    ],
    Headers = case AccountType of
        <<"bedrock">> ->
            AwsCreds = #{
                access_key => maps:get(<<"access_key">>, Creds, <<>>),
                secret_key => maps:get(<<"secret_key">>, Creds, <<>>),
                region => maps:get(<<"region">>, Creds, <<"us-east-1">>),
                service => <<"bedrock">>
            },
            ersub_aws_signer:sign_request(<<"POST">>, Url, BaseHeaders, OrigBody, AwsCreds);
        _ ->
            [{<<"x-api-key">>, ApiKey} | BaseHeaders]
    end,

    case IsStream of
        true ->
            handle_streaming(Req0, State, Url, Headers, OrigBody, Account);
        _ ->
            case http_request(Url, Headers, OrigBody) of
                {ok, Status, RespHeaders, RespBody} ->
                    %% Record usage and deduct billing for non-streaming
                    Model = maps:get(<<"model">>, Parsed, <<>>),
                    AccountId = maps:get(id, Account, 0),
                    case Status of
                        S when S >= 200, S < 300 ->
                            ersub_billing_helper:record_non_streaming_usage(
                                AuthCtx, AccountId, RespBody, Model);
                        _ -> ok
                    end,
                    FilteredHeaders = filter_response_headers(RespHeaders),
                    Req = cowboy_req:reply(Status, FilteredHeaders, RespBody, Req0),
                    {ok, Req, State};
                {error, Reason} ->
                    logger:error("Upstream request failed: ~p", [Reason]),
                    Req = reply_json(502, #{error => #{
                        type => <<"api_error">>,
                        message => <<"Upstream request failed">>
                    }}, Req0),
                    {ok, Req, State}
            end
    end.

%%% Streaming

handle_streaming(Req0, State, Url, Headers, Body, Account) ->
    ConnInfo = parse_url_to_conn_info(Url),
    AccountId = maps:get(id, Account, 0),
    ReqId = generate_request_id(),
    Opts = #{account_id => AccountId, request_id => ReqId, model => <<"unknown">>},
    case ersub_stream_fsm:start(ConnInfo, Headers, Body, Opts) of
        {ok, FsmPid} ->
            %% Wait for headers from FSM
            receive
                {stream_headers, FsmPid, _Status, RespHeaders} ->
                    %% Send chunked response headers
                    FilteredHeaders = filter_response_headers(maps:from_list(RespHeaders)),
                    StreamHeaders = FilteredHeaders#{
                        <<"content-type">> => <<"text/event-stream">>,
                        <<"cache-control">> => <<"no-cache">>,
                        <<"connection">> => <<"keep-alive">>
                    },
                    Req1 = cowboy_req:stream_reply(200, StreamHeaders, Req0),
                    %% Stream chunks
                    stream_loop(Req1, State, FsmPid);
                {stream_error, FsmPid, {upstream_error, ErrStatus, _ErrHeaders, ErrBody}} ->
                    %% Upstream returned an error — pass it through
                    Req = cowboy_req:reply(ErrStatus,
                        #{<<"content-type">> => <<"application/json">>},
                        ErrBody, Req0),
                    {ok, Req, State};
                {stream_error, FsmPid, Reason} ->
                    logger:error("Stream connect error: ~p", [Reason]),
                    Req = reply_json(502, #{error => #{
                        type => <<"api_error">>,
                        message => <<"Upstream streaming failed">>
                    }}, Req0),
                    {ok, Req, State}
            after 30000 ->
                ersub_stream_fsm:stop(FsmPid),
                Req = reply_json(504, #{error => #{
                    type => <<"api_error">>,
                    message => <<"Upstream connection timeout">>
                }}, Req0),
                {ok, Req, State}
            end;
        {error, Reason} ->
            logger:error("Failed to start stream FSM: ~p", [Reason]),
            Req = reply_json(502, #{error => #{
                type => <<"api_error">>,
                message => <<"Failed to connect to upstream">>
            }}, Req0),
            {ok, Req, State}
    end.

stream_loop(Req, State, FsmPid) ->
    receive
        {stream_chunk, FsmPid, Chunk} ->
            cowboy_req:stream_body(Chunk, nofin, Req),
            stream_loop(Req, State, FsmPid);
        {stream_done, FsmPid, _Accumulated} ->
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State};
        {stream_error, FsmPid, Reason} ->
            logger:error("Mid-stream error: ~p", [Reason]),
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State}
    after 600000 ->
        cowboy_req:stream_body(<<>>, fin, Req),
        {ok, Req, State}
    end.

parse_url_to_conn_info(Url) ->
    {Scheme, Host, Port, Path} = parse_url(Url),
    #{scheme => Scheme, host => Host, port => Port, path => Path}.

generate_request_id() ->
    Rand = crypto:strong_rand_bytes(8),
    iolist_to_binary([<<"req-">>, binary:encode_hex(Rand)]).

%%% HTTP client (non-streaming)

http_request(Url, Headers, Body) ->
    {Scheme, Host, Port, Path} = parse_url(Url),
    ConnectOpts = case Scheme of
        https -> #{transport => tls, tls_opts => [{verify, verify_none}]};
        http -> #{}
    end,
    case gun:open(binary_to_list(Host), Port, ConnectOpts#{
        connect_timeout => 10000,
        protocols => [http]
    }) of
        {ok, ConnPid} ->
            MRef = monitor(process, ConnPid),
            case gun:await_up(ConnPid, 10000, MRef) of
                {ok, _} ->
                    StreamRef = gun:post(ConnPid, Path, Headers, Body),
                    Result = await_response(ConnPid, StreamRef, MRef),
                    demonitor(MRef, [flush]),
                    gun:close(ConnPid),
                    Result;
                {error, Reason} ->
                    demonitor(MRef, [flush]),
                    gun:close(ConnPid),
                    {error, {connect_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {open_failed, Reason}}
    end.

await_response(ConnPid, StreamRef, MRef) ->
    await_response(ConnPid, StreamRef, MRef, undefined, []).

await_response(ConnPid, StreamRef, MRef, _Status, Acc) ->
    receive
        {gun_response, ConnPid, StreamRef, fin, S, Headers} ->
            {ok, S, maps:from_list(Headers), <<>>};
        {gun_response, ConnPid, StreamRef, nofin, S, Headers} ->
            await_body(ConnPid, StreamRef, MRef, S, maps:from_list(Headers), Acc);
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, Reason};
        {gun_error, ConnPid, Reason} ->
            {error, Reason};
        {'DOWN', MRef, process, ConnPid, Reason} ->
            {error, {connection_down, Reason}}
    after 600000 ->
        {error, timeout}
    end.

await_body(ConnPid, StreamRef, MRef, Status, Headers, Acc) ->
    receive
        {gun_data, ConnPid, StreamRef, fin, Data} ->
            Body = iolist_to_binary(lists:reverse([Data | Acc])),
            {ok, Status, Headers, Body};
        {gun_data, ConnPid, StreamRef, nofin, Data} ->
            await_body(ConnPid, StreamRef, MRef, Status, Headers, [Data | Acc]);
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, Reason};
        {gun_error, ConnPid, Reason} ->
            {error, Reason};
        {'DOWN', MRef, process, ConnPid, Reason} ->
            {error, {connection_down, Reason}}
    after 600000 ->
        {error, timeout}
    end.

%%% Helpers

check_ip_access(Req, AuthCtx) ->
    #{ip_whitelist := WL, ip_blacklist := BL} = AuthCtx,
    case {WL, BL} of
        {[], []} -> allow;
        _ ->
            {IP, _Port} = cowboy_req:peer(Req),
            ersub_ip_access:check_ip_access(IP, WL, BL)
    end.

handle_auth_error(missing_key, Req) ->
    reply_json(401, #{error => #{
        type => <<"authentication_error">>,
        message => <<"Missing API key. Include x-api-key header or Authorization: Bearer <key>">>
    }}, Req);
handle_auth_error(invalid_key, Req) ->
    reply_json(401, #{error => #{
        type => <<"authentication_error">>,
        message => <<"Invalid API key">>
    }}, Req);
handle_auth_error(user_banned, Req) ->
    reply_json(403, #{error => #{
        type => <<"permission_error">>,
        message => <<"Account has been suspended">>
    }}, Req);
handle_auth_error(key_inactive, Req) ->
    reply_json(403, #{error => #{
        type => <<"permission_error">>,
        message => <<"API key is inactive">>
    }}, Req);
handle_auth_error(key_expired, Req) ->
    reply_json(403, #{error => #{
        type => <<"permission_error">>,
        message => <<"API key has expired">>
    }}, Req).

read_body(Req) ->
    read_body(Req, <<>>).

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0, #{length => 268435456, period => 60000}) of
        {ok, Data, Req} -> {ok, <<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} -> read_body(Req, <<Acc/binary, Data/binary>>);
        {error, _} -> {error, Req0}
    end.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

filter_response_headers(Headers) ->
    Allowed = [<<"content-type">>, <<"x-request-id">>,
               <<"anthropic-ratelimit-requests-limit">>,
               <<"anthropic-ratelimit-requests-remaining">>,
               <<"anthropic-ratelimit-tokens-limit">>,
               <<"anthropic-ratelimit-tokens-remaining">>],
    maps:filter(fun(K, _V) ->
        lists:member(string:lowercase(K), Allowed)
    end, Headers).

effective_rpm(null, null) -> 0;
effective_rpm(undefined, undefined) -> 0;
effective_rpm(null, UserRpm) -> UserRpm;
effective_rpm(undefined, UserRpm) -> UserRpm;
effective_rpm(KeyRpm, _) when is_integer(KeyRpm), KeyRpm > 0 -> KeyRpm;
effective_rpm(_, UserRpm) when is_integer(UserRpm), UserRpm > 0 -> UserRpm;
effective_rpm(_, _) -> 0.

compute_session_hash(Parsed) ->
    SystemPrompt = maps:get(<<"system">>, Parsed, <<>>),
    Messages = maps:get(<<"messages">>, Parsed, []),
    FirstMsg = case Messages of
        [#{<<"content">> := C} | _] when is_binary(C) -> C;
        [#{<<"content">> := C} | _] when is_list(C) -> jsx:encode(C);
        _ -> <<>>
    end,
    Data = <<SystemPrompt/binary, FirstMsg/binary>>,
    binary:encode_hex(crypto:hash(sha256, Data)).

parse_url(Url) when is_binary(Url) ->
    parse_url(binary_to_list(Url));
parse_url(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host, path := Path} = Parsed ->
            Port = maps:get(port, Parsed, case Scheme of
                "https" -> 443;
                "http" -> 80;
                _ -> 443
            end),
            {list_to_atom(Scheme), list_to_binary(Host), Port,
             list_to_binary(Path)};
        _ ->
            {https, <<"api.anthropic.com">>, 443, <<"/v1/messages">>}
    end.
