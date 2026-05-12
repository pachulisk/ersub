-module(ersub_gemini_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%% Gemini API proxy (/gemini/v1beta/...)
%% Handles both streaming and non-streaming

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, State);
        <<"OPTIONS">> ->
            {ok, cowboy_req:reply(204, #{}, <<>>, Req0), State};
        _ ->
            {ok, reply_json(405, #{error => #{message => <<"Method not allowed">>}}, Req0), State}
    end.

handle_post(Req0, State) ->
    case ersub_auth_middleware:authenticate(Req0) of
        {error, Reason} ->
            {ok, ersub_auth_middleware:reply_error(Req0, 401, auth_msg(Reason)), State};
        {ok, AuthCtx} ->
            #{user_id := UserId, user_max_concurrency := MaxConc} = AuthCtx,
            case ersub_concurrency_srv:acquire(UserId, MaxConc) of
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
                    case ersub_billing_srv:check_balance(UserId, 0.001) of
                        {error, insufficient_balance} ->
                            {ok, reply_json(402, #{error => #{message => <<"Insufficient balance">>}}, Req1), State};
                        ok ->
                            %% Extract path suffix for Gemini routing
                            PathInfo = cowboy_req:path_info(Req0),
                            case ersub_scheduler_srv:select_account(#{
                                user_id => UserId, platform => <<"gemini">>,
                                session_hash => <<>>, model => <<"gemini">>
                            }) of
                                {error, no_available_account} ->
                                    {ok, reply_json(503, #{error => #{message => <<"No accounts">>}}, Req1), State};
                                {ok, Account} ->
                                    forward(Req1, State, Account, Body, PathInfo, AuthCtx)
                            end
                    end
            end;
        _ ->
            {ok, reply_json(400, #{error => #{message => <<"Read failed">>}}, Req0), State}
    end.

forward(Req0, State, Account, Body, PathInfo, AuthCtx) ->
    #{credentials := Creds, base_url := BaseUrl0} = Account,
    ApiKey = maps:get(<<"api_key">>, Creds, maps:get(api_key, Creds, <<>>)),
    DefaultUrl = maps:get(<<"base-url">>, ersub_clips_config:get_platform(<<"gemini">>), <<"https://generativelanguage.googleapis.com">>),
    BaseUrl = case BaseUrl0 of
        B when B =:= null; B =:= undefined; B =:= <<>> -> DefaultUrl;
        U -> U
    end,
    %% Reconstruct Gemini path from path_info
    SubPath = case PathInfo of
        undefined -> <<"/v1beta/models/gemini-2.5-pro:generateContent">>;
        Parts when is_list(Parts) ->
            iolist_to_binary([<<"/v1beta/">>, lists:join(<<"/">>, Parts)])
    end,
    Url = <<BaseUrl/binary, SubPath/binary, "?key=", ApiKey/binary>>,
    Headers = [{<<"content-type">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"POST">>, Url, Headers, Body, #{}) of
        {ok, Status, RespHeaders, RespBody} ->
            case Status of
                S when S >= 200, S < 300 ->
                    ersub_billing_helper:record_non_streaming_usage(
                        AuthCtx, maps:get(id, Account, 0), RespBody, <<"gemini">>);
                _ -> ok
            end,
            Filtered = maps:filter(fun(K,_) ->
                lists:member(string:lowercase(K), [<<"content-type">>])
            end, RespHeaders),
            {ok, cowboy_req:reply(Status, Filtered, RespBody, Req0), State};
        {error, Reason} ->
            logger:error("Gemini request failed: ~p", [Reason]),
            {ok, reply_json(502, #{error => #{message => <<"Upstream failed">>}}, Req0), State}
    end.

reply_json(S, B, R) ->
    cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).
auth_msg(missing_key) -> <<"Missing API key">>; auth_msg(_) -> <<"Auth failed">>.
