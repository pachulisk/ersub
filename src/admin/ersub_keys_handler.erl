-module(ersub_keys_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    %% JWT auth for management endpoints
    case verify_jwt_auth(Req0) of
        {error, Reason} ->
            Req = reply_json(401, #{error => #{
                type => <<"authentication_error">>,
                message => auth_error_message(Reason)
            }}, Req0),
            {ok, Req, State};
        {ok, Claims} ->
            UserId = maps:get(<<"user_id">>, Claims),
            Path = cowboy_req:path_info(Req0),
            handle(Method, Path, Req0, State, UserId)
    end.

%% GET /api/keys — list keys
handle(<<"GET">>, undefined, Req0, State, UserId) ->
    case ersub_repo:list_api_keys(UserId) of
        {ok, Keys} ->
            Req = reply_json(200, #{data => Keys}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => format_error(Reason)}, Req0),
            {ok, Req, State}
    end;

%% POST /api/keys — create key
handle(<<"POST">>, undefined, Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Name = maps:get(<<"name">>, Params, null),
    %% Generate API key: sk-ersub-<random>
    RawKey = generate_api_key(),
    Hash = ersub_auth_middleware:hash_api_key(RawKey),
    Prefix = binary:part(RawKey, 0, min(12, byte_size(RawKey))),
    case ersub_repo:create_api_key(#{
        user_id => UserId,
        key_hash => Hash,
        key_prefix => Prefix,
        name => Name
    }) of
        {ok, Key} ->
            %% Return the raw key only on creation
            Result = Key#{raw_key => RawKey},
            Req = reply_json(201, #{data => Result}, Req1),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => format_error(Reason)}, Req1),
            {ok, Req, State}
    end;

%% GET /api/keys/:id — get single key
handle(<<"GET">>, [IdBin], Req0, State, UserId) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, key_prefix, name, rpm_limit, max_concurrency, "
        "ip_whitelist, ip_blacklist, is_active, expires_at, created_at "
        "FROM api_keys WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL",
        [Id, UserId])
    of
        {ok, _, [{KId, KP, N, RPM, MC, IW, IB, Active, Exp, CA}]} ->
            Req = reply_json(200, #{data => #{
                id => KId, key_prefix => KP, name => N,
                rpm_limit => RPM, max_concurrency => MC,
                ip_whitelist => IW, ip_blacklist => IB,
                is_active => Active, expires_at => Exp,
                created_at => CA
            }}, Req0),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{
                message => <<"Key not found">>
            }}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => format_error(Reason)}, Req0),
            {ok, Req, State}
    end;

%% PUT /api/keys/:id — update key
handle(<<"PUT">>, [IdBin], Req0, State, UserId) ->
    Id = binary_to_integer(IdBin),
    %% Verify ownership
    case ersub_repo:query(
        "SELECT user_id FROM api_keys WHERE id = $1 AND deleted_at IS NULL", [Id]
    ) of
        {ok, _, [{UserId}]} ->
            %% Key belongs to this user, proceed with update
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Params = jsx:decode(Body, [return_maps]),
            Fields = build_key_update_fields(Params),
            case map_size(Fields) of
                0 ->
                    Req = reply_json(400, #{error => #{
                        message => <<"No valid fields to update">>
                    }}, Req1),
                    {ok, Req, State};
                _ ->
                    case ersub_repo:update_api_key(Id, Fields) of
                        {ok, _} ->
                            Req = reply_json(200, #{success => true}, Req1),
                            {ok, Req, State};
                        {error, Reason} ->
                            Req = reply_json(500, #{error => format_error(Reason)}, Req1),
                            {ok, Req, State}
                    end
            end;
        {ok, _, [{_OtherUserId}]} ->
            Req = reply_json(403, #{error => #{
                message => <<"Key does not belong to you">>
            }}, Req0),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{
                message => <<"Key not found">>
            }}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => format_error(Reason)}, Req0),
            {ok, Req, State}
    end;

%% DELETE /api/keys/:id
handle(<<"DELETE">>, [IdBin], Req0, State, _UserId) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:delete_api_key(Id) of
        {ok, _} ->
            Req = reply_json(200, #{success => true}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => format_error(Reason)}, Req0),
            {ok, Req, State}
    end;

handle(_, _, Req0, State, _) ->
    Req = reply_json(404, #{error => #{message => <<"Not found">>}}, Req0),
    {ok, Req, State}.

%%% Internal

verify_jwt_auth(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            ersub_auth_srv:verify_jwt(string:trim(Token));
        _ ->
            {error, missing_token}
    end.

generate_api_key() ->
    Rand = binary:encode_hex(crypto:strong_rand_bytes(24)),
    <<"sk-ersub-", Rand/binary>>.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

format_error(Reason) ->
    #{type => <<"api_error">>, message => iolist_to_binary(io_lib:format("~p", [Reason]))}.

auth_error_message(missing_token) -> <<"Missing Authorization header">>;
auth_error_message(token_expired) -> <<"Token expired">>;
auth_error_message(invalid_signature) -> <<"Invalid token">>;
auth_error_message(_) -> <<"Authentication failed">>.

build_key_update_fields(Params) ->
    Mappings = [
        {<<"name">>, name, fun(V) -> V end},
        {<<"rpm_limit">>, rpm_limit, fun(V) -> V end},
        {<<"concurrency_limit">>, max_concurrency, fun(V) -> V end},
        {<<"ip_whitelist">>, ip_whitelist, fun(V) -> jsx:encode(V) end},
        {<<"ip_blacklist">>, ip_blacklist, fun(V) -> jsx:encode(V) end},
        {<<"expires_at">>, expires_at, fun(V) -> V end}
    ],
    lists:foldl(fun({JsonKey, DbKey, Transform}, Acc) ->
        case maps:find(JsonKey, Params) of
            {ok, Value} -> Acc#{DbKey => Transform(Value)};
            error -> Acc
        end
    end, #{}, Mappings).
