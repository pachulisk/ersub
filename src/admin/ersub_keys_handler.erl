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
