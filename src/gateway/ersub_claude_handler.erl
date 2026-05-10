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
    %% 3. Read request body
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
                    forward_to_upstream(Req1, State, AuthCtx, Parsed, Body)
            end
    end.

forward_to_upstream(Req0, State, _AuthCtx, Parsed, OrigBody) ->
    %% For MVP: pick the first active account and forward directly
    %% TODO: integrate with scheduler service (P2-06)
    case get_upstream_account() of
        {error, no_account} ->
            Req = reply_json(503, #{error => #{
                type => <<"api_error">>,
                message => <<"No upstream accounts available">>
            }}, Req0),
            {ok, Req, State};
        {ok, Account} ->
            do_forward(Req0, State, Account, Parsed, OrigBody)
    end.

do_forward(Req0, State, Account, Parsed, OrigBody) ->
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

    Url = <<BaseUrl/binary, "/v1/messages">>,
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"x-api-key">>, ApiKey},
        {<<"anthropic-version">>, <<"2023-06-01">>}
    ],

    case IsStream of
        true ->
            %% TODO: P2-01 streaming support
            Req = reply_json(501, #{error => #{
                type => <<"api_error">>,
                message => <<"Streaming not yet implemented, set stream=false">>
            }}, Req0),
            {ok, Req, State};
        _ ->
            case http_request(Url, Headers, OrigBody) of
                {ok, Status, RespHeaders, RespBody} ->
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

%%% HTTP client

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

get_upstream_account() ->
    case ersub_repo:list_accounts(#{status => <<"active">>}) of
        {ok, [Account | _]} ->
            %% Fetch full account with credentials
            ersub_repo:get_account(maps:get(id, Account));
        {ok, []} ->
            {error, no_account};
        {error, Reason} ->
            logger:error("Failed to list accounts: ~p", [Reason]),
            {error, no_account}
    end.

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
