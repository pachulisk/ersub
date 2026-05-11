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
                    case ersub_billing_srv:check_balance(UserId, 0.001) of
                        {error, insufficient_balance} ->
                            {ok, reply_json(402, #{error => #{message => <<"Insufficient balance">>}}, Req1), State};
                        ok ->
                            Model = maps:get(<<"model">>, Parsed, <<>>),
                            case ersub_scheduler_srv:select_account(#{
                                user_id => UserId, platform => <<"openai">>,
                                session_hash => <<>>, model => Model
                            }) of
                                {error, no_available_account} ->
                                    {ok, reply_json(503, #{error => #{message => <<"No accounts">>}}, Req1), State};
                                {ok, Account} ->
                                    forward(Req1, State, Account, Parsed, Body, AuthCtx)
                            end
                    end
            end;
        _ ->
            {ok, reply_json(400, #{error => #{message => <<"Read failed">>}}, Req0), State}
    end.

forward(Req0, State, Account, Parsed, Body, AuthCtx) ->
    #{credentials := Creds, base_url := BaseUrl0} = Account,
    ApiKey = maps:get(<<"api_key">>, Creds, maps:get(api_key, Creds, <<>>)),
    BaseUrl = case BaseUrl0 of
        B when B =:= null; B =:= undefined; B =:= <<>> -> <<"https://api.openai.com">>;
        U -> U
    end,
    IsStream = maps:get(<<"stream">>, Parsed, false),
    Url = <<BaseUrl/binary, "/v1/responses">>,
    Headers = [{<<"content-type">>, <<"application/json">>},
               {<<"authorization">>, <<"Bearer ", ApiKey/binary>>}],
    case IsStream of
        true ->
            ConnInfo = parse_url(Url),
            case ersub_stream_fsm:start(ConnInfo, Headers, Body,
                    #{account_id => maps:get(id, Account, 0),
                      request_id => gen_req_id(),
                      model => maps:get(<<"model">>, Parsed, <<>>)}) of
                {ok, FsmPid} -> handle_stream(Req0, State, FsmPid);
                _ -> {ok, reply_json(502, #{error => #{message => <<"Connect failed">>}}, Req0), State}
            end;
        _ ->
            case ersub_upstream_pool:request(<<"POST">>, Url, Headers, Body, #{}) of
                {ok, S, RH, RB} ->
                    case S of
                        Sc when Sc >= 200, Sc < 300 ->
                            Model = maps:get(<<"model">>, Parsed, <<>>),
                            ersub_billing_helper:record_non_streaming_usage(
                                AuthCtx, maps:get(id, Account, 0), RB, Model);
                        _ -> ok
                    end,
                    {ok, cowboy_req:reply(S, filter_h(RH), RB, Req0), State};
                _ ->
                    {ok, reply_json(502, #{error => #{message => <<"Upstream failed">>}}, Req0), State}
            end
    end.

handle_stream(Req0, State, FsmPid) ->
    receive
        {stream_headers, FsmPid, _, RH} ->
            H = (filter_h(maps:from_list(RH)))#{<<"content-type">> => <<"text/event-stream">>},
            Req1 = cowboy_req:stream_reply(200, H, Req0),
            stream_loop(Req1, State, FsmPid);
        {stream_error, FsmPid, {upstream_error, S, _, B}} ->
            {ok, cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, B, Req0), State};
        {stream_error, FsmPid, _} ->
            {ok, reply_json(502, #{error => #{message => <<"Stream failed">>}}, Req0), State}
    after 30000 ->
        catch ersub_stream_fsm:stop(FsmPid),
        {ok, reply_json(504, #{error => #{message => <<"Timeout">>}}, Req0), State}
    end.

stream_loop(Req, State, Pid) ->
    receive
        {stream_chunk, Pid, C} -> cowboy_req:stream_body(C, nofin, Req), stream_loop(Req, State, Pid);
        {stream_done, Pid, _} -> cowboy_req:stream_body(<<>>, fin, Req), {ok, Req, State};
        {stream_error, Pid, _} -> cowboy_req:stream_body(<<>>, fin, Req), {ok, Req, State}
    after 600000 -> cowboy_req:stream_body(<<>>, fin, Req), {ok, Req, State}
    end.

reply_json(S, B, R) -> cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).
filter_h(H) -> maps:filter(fun(K,_) -> lists:member(string:lowercase(K), [<<"content-type">>,<<"x-request-id">>]) end, H).
parse_url(U) -> case uri_string:parse(binary_to_list(U)) of #{scheme:=S,host:=H}=P -> #{scheme=>list_to_atom(S),host=>list_to_binary(H),port=>maps:get(port,P,case S of "https"->443;_->80 end),path=>list_to_binary(maps:get(path,P,"/"))}; _ -> #{scheme=>https,host=><<"api.openai.com">>,port=>443,path=><<"/v1/responses">>} end.
gen_req_id() -> iolist_to_binary([<<"req-">>, binary:encode_hex(crypto:strong_rand_bytes(8))]).
eff_conc(null, U) -> U; eff_conc(undefined, U) -> U; eff_conc(K, _) when is_integer(K), K > 0 -> K; eff_conc(_, U) -> U.
auth_msg(missing_key) -> <<"Missing API key">>; auth_msg(invalid_key) -> <<"Invalid API key">>; auth_msg(_) -> <<"Auth failed">>.
