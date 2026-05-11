-module(ersub_user_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case verify_jwt(Req0) of
        {error, Reason} ->
            Req = reply_json(401, #{error => #{
                type => <<"authentication_error">>,
                message => auth_msg(Reason)
            }}, Req0),
            {ok, Req, State};
        {ok, Claims} ->
            UserId = maps:get(<<"user_id">>, Claims),
            Path = cowboy_req:path_info(Req0),
            handle(Method, Path, Req0, State, UserId)
    end.

%% GET /api/user/profile
handle(<<"GET">>, [<<"profile">>], Req0, State, UserId) ->
    case ersub_repo:get_user(UserId) of
        {ok, User} ->
            Safe = maps:without([password_hash, totp_secret], User),
            Req = reply_json(200, #{data => Safe}, Req0),
            {ok, Req, State};
        {error, not_found} ->
            Req = reply_json(404, #{error => #{message => <<"User not found">>}}, Req0),
            {ok, Req, State}
    end;

%% PUT /api/user/profile
handle(<<"PUT">>, [<<"profile">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Fields = jsx:decode(Body, [return_maps]),
    %% Only allow updating safe fields
    Allowed = [<<"email">>],
    Updates = maps:fold(fun(K, V, Acc) ->
        case lists:member(K, Allowed) of
            true -> Acc#{binary_to_atom(K) => V};
            false -> Acc
        end
    end, #{}, Fields),
    case maps:size(Updates) of
        0 ->
            Req = reply_json(400, #{error => #{message => <<"No valid fields to update">>}}, Req1),
            {ok, Req, State};
        _ ->
            case ersub_repo:update_user(UserId, Updates) of
                {ok, _} ->
                    Req = reply_json(200, #{success => true}, Req1),
                    {ok, Req, State};
                {error, Reason} ->
                    Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
                    {ok, Req, State}
            end
    end;

%% POST /api/user/change-password
handle(<<"POST">>, [<<"change-password">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"old_password">> := OldPass, <<"new_password">> := NewPass} =
        jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "SELECT password_hash FROM users WHERE id = $1 AND deleted_at IS NULL",
        [UserId]) of
        {ok, _, [{StoredHash}]} ->
            case ersub_auth_srv:verify_password(OldPass, StoredHash) of
                true ->
                    NewHash = ersub_auth_srv:hash_password(NewPass),
                    ersub_repo:update_user(UserId, #{password_hash => NewHash}),
                    Req = reply_json(200, #{success => true}, Req1),
                    {ok, Req, State};
                false ->
                    Req = reply_json(400, #{error => #{message => <<"Wrong old password">>}}, Req1),
                    {ok, Req, State}
            end;
        _ ->
            Req = reply_json(404, #{error => #{message => <<"User not found">>}}, Req1),
            {ok, Req, State}
    end;

%% GET /api/user/balance
handle(<<"GET">>, [<<"balance">>], Req0, State, UserId) ->
    Balance = ersub_billing_srv:get_cached_balance(UserId),
    Req = reply_json(200, #{data => #{balance_usd => Balance}}, Req0),
    {ok, Req, State};

%% GET /api/user/usage
handle(<<"GET">>, [<<"usage">>], Req0, State, UserId) ->
    Limit = binary_to_integer(cowboy_req:header(<<"x-limit">>, Req0, <<"50">>)),
    case ersub_repo:query(
        "SELECT request_id, requested_model, input_tokens, output_tokens, "
        "actual_cost, stream, created_at FROM usage_logs "
        "WHERE user_id = $1 ORDER BY created_at DESC LIMIT $2",
        [UserId, Limit]
    ) of
        {ok, _, Rows} ->
            Logs = [#{request_id => RId, model => M, input_tokens => IT,
                      output_tokens => OT, cost => C, stream => S,
                      created_at => CA}
                    || {RId, M, IT, OT, C, S, CA} <- Rows],
            Req = reply_json(200, #{data => Logs}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/user/attributes
handle(<<"GET">>, [<<"attributes">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT d.attribute_key, d.attribute_type, d.default_value, "
        "COALESCE(v.attribute_value, d.default_value) AS value "
        "FROM user_attribute_definitions d "
        "LEFT JOIN user_attribute_values v "
        "ON d.attribute_key = v.attribute_key AND v.user_id = $1 "
        "ORDER BY d.attribute_key",
        [UserId])
    of
        {ok, _, Rows} ->
            Attrs = [#{key => K, type => T, default => D, value => V}
                     || {K, T, D, V} <- Rows],
            Req = reply_json(200, #{data => Attrs}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% PUT /api/user/attributes
handle(<<"PUT">>, [<<"attributes">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Attrs = jsx:decode(Body, [return_maps]),
    %% Attrs is a map of key→value
    Results = maps:fold(fun(Key, Value, Acc) ->
        case ersub_repo:query(
            "SELECT attribute_key FROM user_attribute_definitions WHERE attribute_key = $1",
            [Key])
        of
            {ok, _, [_]} ->
                %% Definition exists, upsert value
                case ersub_repo:query(
                    "INSERT INTO user_attribute_values (user_id, attribute_key, attribute_value) "
                    "VALUES ($1, $2, $3) "
                    "ON CONFLICT (user_id, attribute_key) DO UPDATE "
                    "SET attribute_value = $3, updated_at = NOW()",
                    [UserId, Key, Value])
                of
                    {ok, _, _} -> Acc;
                    {ok, _} -> Acc;
                    {error, R} -> [{Key, R} | Acc]
                end;
            {ok, _, []} ->
                [{Key, unknown_attribute} | Acc];
            {error, R} ->
                [{Key, R} | Acc]
        end
    end, [], Attrs),
    case Results of
        [] ->
            Req = reply_json(200, #{success => true}, Req1),
            {ok, Req, State};
        Errors ->
            ErrMap = maps:from_list([{K, iolist_to_binary(io_lib:format("~p", [R]))}
                                     || {K, R} <- Errors]),
            Req = reply_json(400, #{error => #{message => <<"Some attributes failed">>,
                                               details => ErrMap}}, Req1),
            {ok, Req, State}
    end;

handle(_, _, Req0, State, _) ->
    Req = reply_json(404, #{error => #{message => <<"Not found">>}}, Req0),
    {ok, Req, State}.

%%% Internal

verify_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            ersub_auth_srv:verify_jwt(string:trim(Token));
        _ -> {error, missing_token}
    end.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

fmt_err(R) -> #{type => <<"api_error">>, message => iolist_to_binary(io_lib:format("~p", [R]))}.
auth_msg(missing_token) -> <<"Missing Authorization header">>;
auth_msg(token_expired) -> <<"Token expired">>;
auth_msg(_) -> <<"Authentication failed">>.
