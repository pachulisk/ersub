-module(ersub_auth_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    handle(Method, Path, Req0, State).

%% POST /api/auth/login — email/password login
handle(<<"POST">>, [<<"login">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"email">> := Email, <<"password">> := Password} =
        jsx:decode(Body, [return_maps]),
    case ersub_repo:get_user_by_email(Email) of
        {ok, #{id := UserId, password_hash := Hash, role := Role,
               is_banned := IsBanned}} ->
            case IsBanned of
                true ->
                    {ok, reply_json(403, #{error => #{message => <<"Account suspended">>}}, Req1), State};
                _ ->
                    case ersub_auth_srv:verify_password(Password, Hash) of
                        true ->
                            {ok, Token} = ersub_auth_srv:generate_jwt(#{
                                <<"user_id">> => UserId,
                                <<"role">> => Role
                            }),
                            {ok, reply_json(200, #{token => Token, user_id => UserId, role => Role}, Req1), State};
                        false ->
                            {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
                    end
            end;
        {error, not_found} ->
            {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
    end;

%% POST /api/auth/register — user registration
handle(<<"POST">>, [<<"register">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Email = maps:get(<<"email">>, Params),
    Password = maps:get(<<"password">>, Params),
    Hash = ersub_auth_srv:hash_password(Password),
    case ersub_repo:create_user(#{email => Email, password_hash => Hash}) of
        {ok, User} ->
            UserId = maps:get(id, User),
            {ok, Token} = ersub_auth_srv:generate_jwt(#{
                <<"user_id">> => UserId,
                <<"role">> => <<"user">>
            }),
            {ok, reply_json(201, #{token => Token, user_id => UserId}, Req1), State};
        {error, Reason} ->
            Msg = case Reason of
                {error, {_, _, <<"23505">>, _, _, _}} -> <<"Email already registered">>;
                _ -> <<"Registration failed">>
            end,
            {ok, reply_json(400, #{error => #{message => Msg}}, Req1), State}
    end;

%% GET /api/auth/oauth/:provider — initiate OAuth flow
handle(<<"GET">>, [<<"oauth">>, Provider], Req0, State) ->
    case get_oauth_config(Provider) of
        {error, not_configured} ->
            {ok, reply_json(400, #{error => #{message => <<"OAuth provider not configured">>}}, Req0), State};
        {ok, Config} ->
            #{client_id := ClientId, auth_url := AuthUrl, redirect_uri := RedirectUri} = Config,
            OAuthState = binary:encode_hex(crypto:strong_rand_bytes(16)),
            Location = iolist_to_binary([
                AuthUrl, <<"?client_id=">>, ClientId,
                <<"&redirect_uri=">>, RedirectUri,
                <<"&response_type=code">>,
                <<"&state=">>, OAuthState,
                <<"&scope=">>, maps:get(scope, Config, <<"read:user user:email">>)
            ]),
            Req = cowboy_req:reply(302, #{<<"location">> => Location}, <<>>, Req0),
            {ok, Req, State}
    end;

%% GET /api/auth/oauth/:provider/callback — OAuth callback
handle(<<"GET">>, [<<"oauth">>, Provider, <<"callback">>], Req0, State) ->
    #{code := Code} = cowboy_req:match_qs([code], Req0),
    case exchange_oauth_code(Provider, Code) of
        {ok, #{user_id := UserId, role := Role}} ->
            {ok, Token} = ersub_auth_srv:generate_jwt(#{
                <<"user_id">> => UserId, <<"role">> => Role
            }),
            {ok, reply_json(200, #{token => Token, user_id => UserId}, Req0), State};
        {error, Reason} ->
            {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("~p", [Reason]))}}, Req0), State}
    end;

handle(_, _, Req0, State) ->
    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}.

%%% Internal

reply_json(S, B, R) ->
    cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).

get_oauth_config(<<"github">>) ->
    ClientId = ersub_config_srv:get(auth_oauth_providers_github_client_id, undefined),
    case ClientId of
        undefined -> {error, not_configured};
        _ ->
            {ok, #{
                client_id => to_bin(ClientId),
                client_secret => to_bin(ersub_config_srv:get(auth_oauth_providers_github_client_secret, <<>>)),
                auth_url => <<"https://github.com/login/oauth/authorize">>,
                token_url => <<"https://github.com/login/oauth/access_token">>,
                user_url => <<"https://api.github.com/user">>,
                redirect_uri => build_redirect_uri(<<"github">>),
                scope => <<"read:user user:email">>
            }}
    end;
get_oauth_config(_) ->
    {error, not_configured}.

exchange_oauth_code(Provider, Code) ->
    case get_oauth_config(Provider) of
        {error, _} = Err -> Err;
        {ok, Config} ->
            #{client_id := CId, client_secret := CS, token_url := TUrl} = Config,
            Body = jsx:encode(#{
                client_id => CId, client_secret => CS,
                code => Code, redirect_uri => maps:get(redirect_uri, Config)
            }),
            Headers = [{<<"content-type">>, <<"application/json">>},
                       {<<"accept">>, <<"application/json">>}],
            case ersub_upstream_pool:request(<<"POST">>, TUrl, Headers, Body, #{}, 10000) of
                {ok, 200, _, RespBody} ->
                    TokenData = jsx:decode(RespBody, [return_maps]),
                    AccessToken = maps:get(<<"access_token">>, TokenData),
                    fetch_oauth_user(Config, AccessToken);
                {ok, Status, _, RespBody} ->
                    {error, {token_exchange_failed, Status, RespBody}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

fetch_oauth_user(#{user_url := UserUrl}, AccessToken) ->
    Headers = [{<<"authorization">>, <<"Bearer ", AccessToken/binary>>},
               {<<"accept">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"GET">>, UserUrl, Headers, <<>>, #{}, 10000) of
        {ok, 200, _, Body} ->
            UserData = jsx:decode(Body, [return_maps]),
            ProviderId = integer_to_binary(maps:get(<<"id">>, UserData, 0)),
            Email = maps:get(<<"email">>, UserData, <<>>),
            %% Find or create user
            case ersub_repo:query(
                "SELECT user_id FROM auth_identities WHERE provider = 'github' AND provider_id = $1",
                [ProviderId]) of
                {ok, _, [{UserId}]} ->
                    case ersub_repo:get_user(UserId) of
                        {ok, #{role := Role}} -> {ok, #{user_id => UserId, role => Role}};
                        _ -> {error, user_not_found}
                    end;
                {ok, _, []} ->
                    %% Create new user
                    Hash = ersub_auth_srv:hash_password(crypto:strong_rand_bytes(32)),
                    case ersub_repo:create_user(#{email => Email, password_hash => Hash}) of
                        {ok, User} ->
                            UserId = maps:get(id, User),
                            ersub_repo:query(
                                "INSERT INTO auth_identities (user_id, provider, provider_id) "
                                "VALUES ($1, 'github', $2)", [UserId, ProviderId]),
                            {ok, #{user_id => UserId, role => <<"user">>}};
                        {error, R} -> {error, R}
                    end;
                {error, R} -> {error, R}
            end;
        _ ->
            {error, user_fetch_failed}
    end.

build_redirect_uri(Provider) ->
    Host = ersub_config_srv:get(server_host, "0.0.0.0"),
    Port = ersub_config_srv:get(server_port, 8080),
    BaseUrl = ersub_config_srv:get(server_base_url, undefined),
    Base = case BaseUrl of
        undefined ->
            iolist_to_binary(io_lib:format("http://~s:~p", [Host, Port]));
        U when is_list(U) -> list_to_binary(U);
        U when is_binary(U) -> U
    end,
    <<Base/binary, "/api/auth/oauth/", Provider/binary, "/callback">>.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
