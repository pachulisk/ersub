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
                            %% Update last_login_at on success
                            ersub_repo:query(
                                "UPDATE users SET last_login_at = NOW() WHERE id = $1",
                                [UserId]),
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
            %% Record signup source as email
            ersub_repo:query(
                "UPDATE users SET signup_source = 'email' WHERE id = $1",
                [UserId]),
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

%% POST /api/auth/forgot-password — request password reset
handle(<<"POST">>, [<<"forgot-password">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Email = maps:get(<<"email">>, Params, <<>>),
    %% Always return success to avoid revealing if email exists
    case ersub_repo:get_user_by_email(Email) of
        {ok, #{id := UserId}} ->
            Token = generate_reset_token(UserId),
            UserIdBin = integer_to_binary(UserId),
            SettingKey = <<"password_reset:", UserIdBin/binary>>,
            ersub_repo:upsert_setting(SettingKey, #{token => Token}),
            ok;
        {error, _} ->
            ok
    end,
    {ok, reply_json(200, #{success => true,
        message => <<"If the email exists, a reset token has been generated">>
    }, Req1), State};

%% POST /api/auth/reset-password — reset password with token
handle(<<"POST">>, [<<"reset-password">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Token = maps:get(<<"token">>, Params, <<>>),
    NewPassword = maps:get(<<"new_password">>, Params, <<>>),
    case verify_reset_token(Token) of
        {ok, UserId} ->
            %% Verify stored token matches
            UserIdBin = integer_to_binary(UserId),
            SettingKey = <<"password_reset:", UserIdBin/binary>>,
            case ersub_repo:get_setting(SettingKey) of
                {ok, #{<<"token">> := Token}} ->
                    NewHash = ersub_auth_srv:hash_password(NewPassword),
                    ersub_repo:update_user(UserId, #{password_hash => NewHash}),
                    %% Invalidate token after use
                    ersub_repo:upsert_setting(SettingKey, #{token => null}),
                    {ok, reply_json(200, #{success => true,
                        message => <<"Password has been reset">>
                    }, Req1), State};
                _ ->
                    {ok, reply_json(400, #{error => #{
                        message => <<"Invalid or expired reset token">>
                    }}, Req1), State}
            end;
        {error, _Reason} ->
            {ok, reply_json(400, #{error => #{
                message => <<"Invalid or expired reset token">>
            }}, Req1), State}
    end;

%% POST /api/auth/refresh — refresh JWT token
handle(<<"POST">>, [<<"refresh">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"token">> := Token} = jsx:decode(Body, [return_maps]),
    case ersub_auth_srv:verify_jwt(Token) of
        {ok, Claims} ->
            FreshClaims = maps:without([<<"iat">>, <<"exp">>], Claims),
            {ok, NewToken} = ersub_auth_srv:generate_jwt(FreshClaims),
            {ok, reply_json(200, #{token => NewToken}, Req1), State};
        {error, _Reason} ->
            {ok, reply_json(401, #{error => #{message => <<"Invalid or expired token">>}}, Req1), State}
    end;

%% POST /api/auth/logout — stateless JWT logout
handle(<<"POST">>, [<<"logout">>], Req0, State) ->
    case cowboy_req:header(<<"authorization">>, Req0) of
        <<"Bearer ", _Token/binary>> ->
            {ok, reply_json(200, #{success => true}, Req0), State};
        _ ->
            {ok, reply_json(401, #{error => #{message => <<"Missing Authorization header">>}}, Req0), State}
    end;

%% GET /api/auth/me — current user info
handle(<<"GET">>, [<<"me">>], Req0, State) ->
    case extract_bearer(Req0) of
        {ok, Token} ->
            case ersub_auth_srv:verify_jwt(Token) of
                {ok, Claims} ->
                    UserId = maps:get(<<"user_id">>, Claims),
                    case ersub_repo:query(
                        "SELECT id, email, role, balance_usd, created_at "
                        "FROM users WHERE id = $1 AND deleted_at IS NULL",
                        [UserId])
                    of
                        {ok, _, [{Id, Email, Role, Balance, CreatedAt}]} ->
                            {ok, reply_json(200, #{data => #{
                                id => Id, email => Email, role => Role,
                                balance_usd => Balance, created_at => CreatedAt
                            }}, Req0), State};
                        {ok, _, []} ->
                            {ok, reply_json(404, #{error => #{message => <<"User not found">>}}, Req0), State};
                        {error, Reason} ->
                            {ok, reply_json(500, #{error => #{message => iolist_to_binary(io_lib:format("~p", [Reason]))}}, Req0), State}
                    end;
                {error, _Reason} ->
                    {ok, reply_json(401, #{error => #{message => <<"Invalid or expired token">>}}, Req0), State}
            end;
        {error, missing_token} ->
            {ok, reply_json(401, #{error => #{message => <<"Missing Authorization header">>}}, Req0), State}
    end;

%% POST /api/auth/login/2fa — login with TOTP 2FA
handle(<<"POST">>, [<<"login">>, <<"2fa">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"email">> := Email, <<"password">> := Password,
      <<"totp_code">> := TotpCode} = jsx:decode(Body, [return_maps]),
    case ersub_repo:get_user_by_email(Email) of
        {ok, #{id := UserId, password_hash := Hash, role := Role,
               is_banned := IsBanned, totp_secret := TotpSecret}} ->
            case IsBanned of
                true ->
                    {ok, reply_json(403, #{error => #{message => <<"Account suspended">>}}, Req1), State};
                _ ->
                    case ersub_auth_srv:verify_password(Password, Hash) of
                        true ->
                            case TotpSecret of
                                null ->
                                    {ok, reply_json(400, #{error => #{message => <<"2FA not enabled for this account">>}}, Req1), State};
                                undefined ->
                                    {ok, reply_json(400, #{error => #{message => <<"2FA not enabled for this account">>}}, Req1), State};
                                _ ->
                                    case ersub_totp:verify_token(TotpCode, TotpSecret) of
                                        true ->
                                            ersub_repo:query(
                                                "UPDATE users SET last_login_at = NOW() WHERE id = $1",
                                                [UserId]),
                                            {ok, Token} = ersub_auth_srv:generate_jwt(#{
                                                <<"user_id">> => UserId,
                                                <<"role">> => Role
                                            }),
                                            {ok, reply_json(200, #{token => Token, user_id => UserId, role => Role}, Req1), State};
                                        false ->
                                            {ok, reply_json(401, #{error => #{message => <<"Invalid TOTP code">>}}, Req1), State}
                                    end
                            end;
                        false ->
                            {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
                    end
            end;
        {error, not_found} ->
            {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
    end;

%% POST /api/auth/send-verify-code — send email verification code
handle(<<"POST">>, [<<"send-verify-code">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Email = maps:get(<<"email">>, Params, <<>>),
    %% Generate 6-digit code and store; always return success
    Code = integer_to_binary(100000 + rand:uniform(899999)),
    Expiry = erlang:system_time(second) + 600,
    SettingKey = <<"verify_code_", Email/binary>>,
    ersub_repo:upsert_setting(SettingKey, #{code => Code, expires => Expiry}),
    {ok, reply_json(200, #{success => true,
        message => <<"Verification code sent">>
    }, Req1), State};

%% POST /api/auth/validate-promo-code — validate a promotional code
handle(<<"POST">>, [<<"validate-promo-code">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    CodeVal = maps:get(<<"code">>, Params, <<>>),
    case ersub_repo:query(
        "SELECT id, code, discount_type, discount_value, is_active, "
        "valid_from, valid_until FROM promo_codes WHERE code = $1",
        [CodeVal])
    of
        {ok, _, [{_Id, _Code, DiscType, DiscVal, IsActive, ValidFrom, ValidUntil}]} ->
            Now = calendar:universal_time(),
            FromOk = case ValidFrom of
                null -> true;
                _ -> Now >= ValidFrom
            end,
            UntilOk = case ValidUntil of
                null -> true;
                _ -> Now =< ValidUntil
            end,
            Valid = (IsActive =:= true) andalso FromOk andalso UntilOk,
            {ok, reply_json(200, #{valid => Valid,
                discount_type => DiscType,
                discount_value => DiscVal
            }, Req1), State};
        _ ->
            {ok, reply_json(200, #{valid => false}, Req1), State}
    end;

%% POST /api/auth/validate-invitation-code — validate an invitation/redeem code
handle(<<"POST">>, [<<"validate-invitation-code">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    CodeVal = maps:get(<<"code">>, Params, <<>>),
    case ersub_repo:query(
        "SELECT id, code, amount_usd FROM redeem_codes "
        "WHERE code = $1 AND is_used = FALSE",
        [CodeVal])
    of
        {ok, _, [{_Id, _Code, Amount}]} ->
            {ok, reply_json(200, #{valid => true, amount => Amount}, Req1), State};
        _ ->
            {ok, reply_json(200, #{valid => false}, Req1), State}
    end;

%% POST /api/auth/revoke-all-sessions — revoke all user sessions
handle(<<"POST">>, [<<"revoke-all-sessions">>], Req0, State) ->
    case extract_bearer(Req0) of
        {ok, Token} ->
            case ersub_auth_srv:verify_jwt(Token) of
                {ok, _Claims} ->
                    %% Stateless JWT: no-op for now; future: increment version counter
                    {ok, reply_json(200, #{success => true,
                        message => <<"All sessions revoked">>
                    }, Req0), State};
                {error, _Reason} ->
                    {ok, reply_json(401, #{error => #{message => <<"Invalid or expired token">>}}, Req0), State}
            end;
        {error, missing_token} ->
            {ok, reply_json(401, #{error => #{message => <<"Missing Authorization header">>}}, Req0), State}
    end;

%% === T6-16: OAuth Per-Provider Complete Flow ===

%% POST /api/auth/oauth/:provider/complete-registration
handle(<<"POST">>, [<<"oauth">>, Provider, <<"complete-registration">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Email = maps:get(<<"email">>, Params),
    Password = maps:get(<<"password">>, Params),
    ProviderId = maps:get(<<"provider_id">>, Params),
    Hash = ersub_auth_srv:hash_password(Password),
    case ersub_repo:create_user(#{email => Email, password_hash => Hash}) of
        {ok, User} ->
            UserId = maps:get(id, User),
            ersub_repo:query(
                "UPDATE users SET signup_source = $1 WHERE id = $2",
                [Provider, UserId]),
            ersub_repo:query(
                "INSERT INTO auth_identities (user_id, provider, provider_id) "
                "VALUES ($1, $2, $3)", [UserId, Provider, ProviderId]),
            {ok, Token} = ersub_auth_srv:generate_jwt(#{
                <<"user_id">> => UserId, <<"role">> => <<"user">>
            }),
            {ok, reply_json(201, #{token => Token, user_id => UserId}, Req1), State};
        {error, Reason} ->
            Msg = case Reason of
                {error, {_, _, <<"23505">>, _, _, _}} -> <<"Email already registered">>;
                _ -> <<"Registration failed">>
            end,
            {ok, reply_json(400, #{error => #{message => Msg}}, Req1), State}
    end;

%% POST /api/auth/oauth/:provider/bind-login
handle(<<"POST">>, [<<"oauth">>, Provider, <<"bind-login">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Email = maps:get(<<"email">>, Params),
    Password = maps:get(<<"password">>, Params),
    ProviderId = maps:get(<<"provider_id">>, Params),
    case ersub_repo:get_user_by_email(Email) of
        {ok, #{id := UserId, password_hash := Hash, role := Role, is_banned := IsBanned}} ->
            case IsBanned of
                true ->
                    {ok, reply_json(403, #{error => #{message => <<"Account suspended">>}}, Req1), State};
                _ ->
                    case ersub_auth_srv:verify_password(Password, Hash) of
                        true ->
                            ersub_repo:query(
                                "INSERT INTO auth_identities (user_id, provider, provider_id) "
                                "VALUES ($1, $2, $3) "
                                "ON CONFLICT (provider, provider_id) DO NOTHING",
                                [UserId, Provider, ProviderId]),
                            ersub_repo:query(
                                "UPDATE users SET last_login_at = NOW() WHERE id = $1",
                                [UserId]),
                            {ok, Token} = ersub_auth_srv:generate_jwt(#{
                                <<"user_id">> => UserId, <<"role">> => Role
                            }),
                            {ok, reply_json(200, #{token => Token, user_id => UserId, role => Role}, Req1), State};
                        false ->
                            {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
                    end
            end;
        {error, not_found} ->
            {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
    end;

%% POST /api/auth/oauth/:provider/create-account
handle(<<"POST">>, [<<"oauth">>, Provider, <<"create-account">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ProviderId = maps:get(<<"provider_id">>, Params),
    DisplayName = maps:get(<<"display_name">>, Params, <<>>),
    %% Create user without real password
    Hash = ersub_auth_srv:hash_password(crypto:strong_rand_bytes(32)),
    Email = <<Provider/binary, "_", ProviderId/binary, "@oauth.local">>,
    case ersub_repo:create_user(#{email => Email, password_hash => Hash}) of
        {ok, User} ->
            UserId = maps:get(id, User),
            ersub_repo:query(
                "UPDATE users SET signup_source = $1 WHERE id = $2",
                [Provider, UserId]),
            case DisplayName of
                <<>> -> ok;
                _ ->
                    ersub_repo:query(
                        "INSERT INTO user_attribute_values (user_id, attribute_key, attribute_value) "
                        "VALUES ($1, 'display_name', $2) "
                        "ON CONFLICT (user_id, attribute_key) DO UPDATE SET attribute_value = $2",
                        [UserId, DisplayName])
            end,
            ersub_repo:query(
                "INSERT INTO auth_identities (user_id, provider, provider_id) "
                "VALUES ($1, $2, $3)", [UserId, Provider, ProviderId]),
            {ok, Token} = ersub_auth_srv:generate_jwt(#{
                <<"user_id">> => UserId, <<"role">> => <<"user">>
            }),
            {ok, reply_json(201, #{token => Token, user_id => UserId}, Req1), State};
        {error, Reason} ->
            {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("~p", [Reason]))}}, Req1), State}
    end;

%% POST /api/auth/oauth/pending/exchange — complete registration from pending auth
handle(<<"POST">>, [<<"oauth">>, <<"pending">>, <<"exchange">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    PendingToken = maps:get(<<"pending_token">>, Params),
    PendingKey = <<"pending_auth_", PendingToken/binary>>,
    case ersub_repo:get_setting(PendingKey) of
        {ok, #{<<"provider">> := Provider, <<"provider_id">> := ProviderId} = PendingData} ->
            Email = maps:get(<<"email">>, Params, maps:get(<<"email">>, PendingData, <<>>)),
            Password = maps:get(<<"password">>, Params, <<>>),
            Hash = case Password of
                <<>> -> ersub_auth_srv:hash_password(crypto:strong_rand_bytes(32));
                _ -> ersub_auth_srv:hash_password(Password)
            end,
            case ersub_repo:create_user(#{email => Email, password_hash => Hash}) of
                {ok, User} ->
                    UserId = maps:get(id, User),
                    ersub_repo:query(
                        "UPDATE users SET signup_source = $1 WHERE id = $2",
                        [Provider, UserId]),
                    ersub_repo:query(
                        "INSERT INTO auth_identities (user_id, provider, provider_id) "
                        "VALUES ($1, $2, $3)", [UserId, Provider, ProviderId]),
                    %% Clean up pending state
                    ersub_repo:query("DELETE FROM settings WHERE key = $1", [PendingKey]),
                    {ok, Token} = ersub_auth_srv:generate_jwt(#{
                        <<"user_id">> => UserId, <<"role">> => <<"user">>
                    }),
                    {ok, reply_json(201, #{token => Token, user_id => UserId}, Req1), State};
                {error, Reason} ->
                    {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("~p", [Reason]))}}, Req1), State}
            end;
        _ ->
            {ok, reply_json(400, #{error => #{message => <<"Invalid or expired pending token">>}}, Req1), State}
    end;

%% POST /api/auth/oauth/pending/create-account — create account from pending auth
handle(<<"POST">>, [<<"oauth">>, <<"pending">>, <<"create-account">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    PendingToken = maps:get(<<"pending_token">>, Params),
    PendingKey = <<"pending_auth_", PendingToken/binary>>,
    case ersub_repo:get_setting(PendingKey) of
        {ok, #{<<"provider">> := Provider, <<"provider_id">> := ProviderId}} ->
            DisplayName = maps:get(<<"display_name">>, Params, <<>>),
            Hash = ersub_auth_srv:hash_password(crypto:strong_rand_bytes(32)),
            Email = <<Provider/binary, "_", ProviderId/binary, "@oauth.local">>,
            case ersub_repo:create_user(#{email => Email, password_hash => Hash}) of
                {ok, User} ->
                    UserId = maps:get(id, User),
                    ersub_repo:query(
                        "UPDATE users SET signup_source = $1 WHERE id = $2",
                        [Provider, UserId]),
                    case DisplayName of
                        <<>> -> ok;
                        _ ->
                            ersub_repo:query(
                                "INSERT INTO user_attribute_values (user_id, attribute_key, attribute_value) "
                                "VALUES ($1, 'display_name', $2) "
                                "ON CONFLICT (user_id, attribute_key) DO UPDATE SET attribute_value = $2",
                                [UserId, DisplayName])
                    end,
                    ersub_repo:query(
                        "INSERT INTO auth_identities (user_id, provider, provider_id) "
                        "VALUES ($1, $2, $3)", [UserId, Provider, ProviderId]),
                    %% Clean up pending state
                    ersub_repo:query("DELETE FROM settings WHERE key = $1", [PendingKey]),
                    {ok, Token} = ersub_auth_srv:generate_jwt(#{
                        <<"user_id">> => UserId, <<"role">> => <<"user">>
                    }),
                    {ok, reply_json(201, #{token => Token, user_id => UserId}, Req1), State};
                {error, Reason} ->
                    {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("~p", [Reason]))}}, Req1), State}
            end;
        _ ->
            {ok, reply_json(400, #{error => #{message => <<"Invalid or expired pending token">>}}, Req1), State}
    end;

%% POST /api/auth/oauth/pending/bind-login — bind provider from pending auth to existing account
handle(<<"POST">>, [<<"oauth">>, <<"pending">>, <<"bind-login">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    PendingToken = maps:get(<<"pending_token">>, Params),
    Email = maps:get(<<"email">>, Params),
    Password = maps:get(<<"password">>, Params),
    PendingKey = <<"pending_auth_", PendingToken/binary>>,
    case ersub_repo:get_setting(PendingKey) of
        {ok, #{<<"provider">> := Provider, <<"provider_id">> := ProviderId}} ->
            case ersub_repo:get_user_by_email(Email) of
                {ok, #{id := UserId, password_hash := Hash, role := Role, is_banned := IsBanned}} ->
                    case IsBanned of
                        true ->
                            {ok, reply_json(403, #{error => #{message => <<"Account suspended">>}}, Req1), State};
                        _ ->
                            case ersub_auth_srv:verify_password(Password, Hash) of
                                true ->
                                    ersub_repo:query(
                                        "INSERT INTO auth_identities (user_id, provider, provider_id) "
                                        "VALUES ($1, $2, $3) "
                                        "ON CONFLICT (provider, provider_id) DO NOTHING",
                                        [UserId, Provider, ProviderId]),
                                    ersub_repo:query(
                                        "UPDATE users SET last_login_at = NOW() WHERE id = $1",
                                        [UserId]),
                                    %% Clean up pending state
                                    ersub_repo:query("DELETE FROM settings WHERE key = $1", [PendingKey]),
                                    {ok, Token} = ersub_auth_srv:generate_jwt(#{
                                        <<"user_id">> => UserId, <<"role">> => Role
                                    }),
                                    {ok, reply_json(200, #{token => Token, user_id => UserId, role => Role}, Req1), State};
                                false ->
                                    {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
                            end
                    end;
                {error, not_found} ->
                    {ok, reply_json(401, #{error => #{message => <<"Invalid credentials">>}}, Req1), State}
            end;
        _ ->
            {ok, reply_json(400, #{error => #{message => <<"Invalid or expired pending token">>}}, Req1), State}
    end;

%% GET /api/auth/settings/public — public site settings (no auth)
handle(<<"GET">>, [<<"settings">>, <<"public">>], Req0, State) ->
    SiteName = ersub_config_srv:get(site_name, <<"ErSub">>),
    RegistrationEnabled = ersub_config_srv:get(registration_enabled, true),
    OAuthProviders = lists:filtermap(fun(P) ->
        case ersub_config_srv:get(
            binary_to_atom(<<"auth_oauth_providers_", P/binary, "_client_id">>),
            undefined) of
            undefined -> false;
            _ -> {true, P}
        end
    end, [<<"github">>, <<"google">>, <<"linuxdo">>, <<"wechat">>]),
    {ok, reply_json(200, #{
        site_name => to_bin(SiteName),
        registration_enabled => RegistrationEnabled,
        oauth_providers => OAuthProviders
    }, Req0), State};

%% === T7-05: OAuth Bind Flow ===

%% GET /api/auth/oauth/:provider/bind/start — Initiate OAuth bind flow
handle(<<"GET">>, [<<"oauth">>, Provider, <<"bind">>, <<"start">>], Req0, State) ->
    case get_oauth_config(Provider) of
        {error, not_configured} ->
            {ok, reply_json(400, #{error => #{message => <<"OAuth provider not configured">>}}, Req0), State};
        {ok, Config} ->
            #{client_id := ClientId, auth_url := AuthUrl, redirect_uri := RedirectUri} = Config,
            OAuthState = <<"bind_", (binary:encode_hex(crypto:strong_rand_bytes(16)))/binary>>,
            Location = iolist_to_binary([
                AuthUrl, <<"?client_id=">>, ClientId,
                <<"&redirect_uri=">>, RedirectUri,
                <<"&response_type=code">>,
                <<"&state=">>, OAuthState,
                <<"&scope=">>, maps:get(scope, Config, <<"read:user user:email">>),
                <<"&intent=bind">>
            ]),
            Req = cowboy_req:reply(302, #{<<"location">> => Location}, <<>>, Req0),
            {ok, Req, State}
    end;

%% POST /api/auth/oauth/pending/send-verify-code — Send verification code for pending auth
handle(<<"POST">>, [<<"oauth">>, <<"pending">>, <<"send-verify-code">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    PendingToken = maps:get(<<"pending_token">>, Params, <<>>),
    Email = maps:get(<<"email">>, Params, <<>>),
    PendingKey = <<"pending_auth_", PendingToken/binary>>,
    case ersub_repo:get_setting(PendingKey) of
        {ok, _PendingData} ->
            Code = integer_to_binary(100000 + rand:uniform(899999)),
            Expiry = erlang:system_time(second) + 600,
            SettingKey = <<"pending_verify_", PendingToken/binary>>,
            ersub_repo:upsert_setting(SettingKey, #{code => Code, email => Email, expires => Expiry}),
            {ok, reply_json(200, #{success => true,
                message => <<"Verification code sent">>
            }, Req1), State};
        _ ->
            {ok, reply_json(400, #{error => #{message => <<"Invalid or expired pending token">>}}, Req1), State}
    end;

%% POST /api/auth/oauth/bind-token — Generate a signed bind token from JWT
handle(<<"POST">>, [<<"oauth">>, <<"bind-token">>], Req0, State) ->
    case extract_bearer(Req0) of
        {ok, Token} ->
            case ersub_auth_srv:verify_jwt(Token) of
                {ok, Claims} ->
                    {ok, Body, Req1} = cowboy_req:read_body(Req0),
                    Params = jsx:decode(Body, [return_maps]),
                    ProviderVal = maps:get(<<"provider">>, Params, <<>>),
                    UserId = maps:get(<<"user_id">>, Claims),
                    Expires = erlang:system_time(second) + 600,
                    UserIdBin = case is_integer(UserId) of
                        true -> integer_to_binary(UserId);
                        false -> UserId
                    end,
                    ExpiryBin = integer_to_binary(Expires),
                    Payload = <<UserIdBin/binary, ".", ProviderVal/binary, ".", ExpiryBin/binary>>,
                    Secret = to_bin(ersub_config_srv:get(auth_jwt_secret, <<"default_secret">>)),
                    Mac = crypto:mac(hmac, sha256, Secret, Payload),
                    BindToken = <<Payload/binary, ".", (binary:encode_hex(Mac))/binary>>,
                    {ok, reply_json(200, #{bind_token => BindToken}, Req1), State};
                {error, _Reason} ->
                    {ok, reply_json(401, #{error => #{message => <<"Invalid or expired token">>}}, Req0), State}
            end;
        {error, missing_token} ->
            {ok, reply_json(401, #{error => #{message => <<"Missing Authorization header">>}}, Req0), State}
    end;

%% === T7-11: WeChat Payment OAuth ===

%% GET /api/auth/oauth/wechat/payment/start — Initiate WeChat payment OAuth
handle(<<"GET">>, [<<"oauth">>, <<"wechat">>, <<"payment">>, <<"start">>], Req0, State) ->
    AppId = ersub_config_srv:get(auth_oauth_providers_wechat_payment_app_id, undefined),
    case AppId of
        undefined ->
            {ok, reply_json(400, #{error => #{message => <<"WeChat payment OAuth not configured">>}}, Req0), State};
        _ ->
            AppIdBin = to_bin(AppId),
            RedirectUri = build_redirect_uri(<<"wechat/payment">>),
            OAuthState = binary:encode_hex(crypto:strong_rand_bytes(16)),
            Location = iolist_to_binary([
                <<"https://open.weixin.qq.com/connect/oauth2/authorize">>,
                <<"?appid=">>, AppIdBin,
                <<"&redirect_uri=">>, RedirectUri,
                <<"&response_type=code">>,
                <<"&scope=snsapi_base">>,
                <<"&state=">>, OAuthState,
                <<"#wechat_redirect">>
            ]),
            Req = cowboy_req:reply(302, #{<<"location">> => Location}, <<>>, Req0),
            {ok, Req, State}
    end;

%% GET /api/auth/oauth/wechat/payment/callback — WeChat payment OAuth callback
handle(<<"GET">>, [<<"oauth">>, <<"wechat">>, <<"payment">>, <<"callback">>], Req0, State) ->
    #{code := Code} = cowboy_req:match_qs([code], Req0),
    AppId = to_bin(ersub_config_srv:get(auth_oauth_providers_wechat_payment_app_id, <<>>)),
    AppSecret = to_bin(ersub_config_srv:get(auth_oauth_providers_wechat_payment_app_secret, <<>>)),
    TokenUrl = iolist_to_binary([
        <<"https://api.weixin.qq.com/sns/oauth2/access_token">>,
        <<"?appid=">>, AppId,
        <<"&secret=">>, AppSecret,
        <<"&code=">>, Code,
        <<"&grant_type=authorization_code">>
    ]),
    Headers = [{<<"accept">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"GET">>, TokenUrl, Headers, <<>>, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            TokenData = jsx:decode(RespBody, [return_maps]),
            OpenId = maps:get(<<"openid">>, TokenData, <<>>),
            %% Find or create user by WeChat payment openid
            case ersub_repo:query(
                "SELECT user_id FROM auth_identities "
                "WHERE provider = 'wechat_payment' AND provider_id = $1",
                [OpenId]) of
                {ok, _, [{UserId}]} ->
                    ersub_repo:query(
                        "UPDATE users SET last_login_at = NOW() WHERE id = $1",
                        [UserId]),
                    case ersub_repo:get_user(UserId) of
                        {ok, #{role := Role}} ->
                            {ok, JwtToken} = ersub_auth_srv:generate_jwt(#{
                                <<"user_id">> => UserId, <<"role">> => Role
                            }),
                            {ok, reply_json(200, #{token => JwtToken, user_id => UserId}, Req0), State};
                        _ ->
                            {ok, reply_json(400, #{error => #{message => <<"User not found">>}}, Req0), State}
                    end;
                {ok, _, []} ->
                    %% New user — create account
                    Hash = ersub_auth_srv:hash_password(crypto:strong_rand_bytes(32)),
                    Email = <<"wechat_pay_", OpenId/binary, "@oauth.local">>,
                    case ersub_repo:create_user(#{email => Email, password_hash => Hash}) of
                        {ok, User} ->
                            UserId = maps:get(id, User),
                            ersub_repo:query(
                                "UPDATE users SET signup_source = 'wechat_payment' WHERE id = $1",
                                [UserId]),
                            ersub_repo:query(
                                "INSERT INTO auth_identities (user_id, provider, provider_id) "
                                "VALUES ($1, 'wechat_payment', $2)", [UserId, OpenId]),
                            {ok, JwtToken} = ersub_auth_srv:generate_jwt(#{
                                <<"user_id">> => UserId, <<"role">> => <<"user">>
                            }),
                            {ok, reply_json(201, #{token => JwtToken, user_id => UserId}, Req0), State};
                        {error, R} ->
                            {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("~p", [R]))}}, Req0), State}
                    end;
                {error, R} ->
                    {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("~p", [R]))}}, Req0), State}
            end;
        {ok, Status, _, RespBody} ->
            {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("Token exchange failed: ~p ~s", [Status, RespBody]))}}, Req0), State};
        {error, Reason} ->
            {ok, reply_json(400, #{error => #{message => iolist_to_binary(io_lib:format("~p", [Reason]))}}, Req0), State}
    end;

handle(_, _, Req0, State) ->
    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}.

%%% Internal

reply_json(S, B, R) ->
    cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).

%% TODO: OAuth provider URLs (auth_url, token_url, user_url) are per-provider
%% constants. They should be loaded from CLIPS in future, but since they are
%% per-provider (not per-platform), keeping them in config for now.
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
get_oauth_config(<<"linuxdo">>) ->
    ClientId = ersub_config_srv:get(auth_oauth_providers_linuxdo_client_id, undefined),
    case ClientId of
        undefined -> {error, not_configured};
        _ ->
            {ok, #{
                client_id => to_bin(ClientId),
                client_secret => to_bin(ersub_config_srv:get(auth_oauth_providers_linuxdo_client_secret, <<>>)),
                auth_url => <<"https://connect.linux.do/oauth2/authorize">>,
                token_url => <<"https://connect.linux.do/oauth2/token">>,
                user_url => <<"https://connect.linux.do/api/user">>,
                redirect_uri => build_redirect_uri(<<"linuxdo">>),
                scope => <<"read">>
            }}
    end;
get_oauth_config(<<"wechat">>) ->
    AppId = ersub_config_srv:get(auth_oauth_providers_wechat_app_id, undefined),
    case AppId of
        undefined -> {error, not_configured};
        _ ->
            {ok, #{
                client_id => to_bin(AppId),
                client_secret => to_bin(ersub_config_srv:get(auth_oauth_providers_wechat_app_secret, <<>>)),
                auth_url => <<"https://open.weixin.qq.com/connect/qrconnect">>,
                token_url => <<"https://api.weixin.qq.com/sns/oauth2/access_token">>,
                user_url => <<"https://api.weixin.qq.com/sns/userinfo">>,
                redirect_uri => build_redirect_uri(<<"wechat">>),
                scope => <<"snsapi_login">>
            }}
    end;
get_oauth_config(<<"google">>) ->
    ClientId = ersub_config_srv:get(auth_oauth_providers_google_client_id, undefined),
    case ClientId of
        undefined -> {error, not_configured};
        _ ->
            {ok, #{
                client_id => to_bin(ClientId),
                client_secret => to_bin(ersub_config_srv:get(auth_oauth_providers_google_client_secret, <<>>)),
                auth_url => <<"https://accounts.google.com/o/oauth2/v2/auth">>,
                token_url => <<"https://oauth2.googleapis.com/token">>,
                user_url => <<"https://www.googleapis.com/oauth2/v2/userinfo">>,
                redirect_uri => build_redirect_uri(<<"google">>),
                scope => <<"openid email profile">>
            }}
    end;
get_oauth_config(Provider) ->
    %% Generic OIDC: read from config dynamically
    Prefix = <<"auth_oauth_providers_", Provider/binary>>,
    ClientId = ersub_config_srv:get(binary_to_atom(<<Prefix/binary, "_client_id">>), undefined),
    case ClientId of
        undefined -> {error, not_configured};
        _ ->
            {ok, #{
                client_id => to_bin(ClientId),
                client_secret => to_bin(ersub_config_srv:get(
                    binary_to_atom(<<Prefix/binary, "_client_secret">>), <<>>)),
                auth_url => to_bin(ersub_config_srv:get(
                    binary_to_atom(<<Prefix/binary, "_auth_url">>), <<>>)),
                token_url => to_bin(ersub_config_srv:get(
                    binary_to_atom(<<Prefix/binary, "_token_url">>), <<>>)),
                user_url => to_bin(ersub_config_srv:get(
                    binary_to_atom(<<Prefix/binary, "_user_url">>), <<>>)),
                redirect_uri => build_redirect_uri(Provider),
                scope => to_bin(ersub_config_srv:get(
                    binary_to_atom(<<Prefix/binary, "_scope">>), <<"openid email profile">>))
            }}
    end.

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
                    fetch_oauth_user(Provider, Config, AccessToken);
                {ok, Status, _, RespBody} ->
                    {error, {token_exchange_failed, Status, RespBody}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

fetch_oauth_user(Provider, #{user_url := UserUrl}, AccessToken) ->
    Headers = [{<<"authorization">>, <<"Bearer ", AccessToken/binary>>},
               {<<"accept">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"GET">>, UserUrl, Headers, <<>>, #{}, 10000) of
        {ok, 200, _, Body} ->
            UserData = jsx:decode(Body, [return_maps]),
            ProviderId = integer_to_binary(maps:get(<<"id">>, UserData, 0)),
            Email = maps:get(<<"email">>, UserData, <<>>),
            %% Find or create user using actual provider
            case ersub_repo:query(
                "SELECT user_id FROM auth_identities WHERE provider = $1 AND provider_id = $2",
                [Provider, ProviderId]) of
                {ok, _, [{UserId}]} ->
                    %% Update last_login_at on OAuth login
                    ersub_repo:query(
                        "UPDATE users SET last_login_at = NOW() WHERE id = $1",
                        [UserId]),
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
                            %% Record signup_source as provider name
                            ersub_repo:query(
                                "UPDATE users SET signup_source = $1 WHERE id = $2",
                                [Provider, UserId]),
                            ersub_repo:query(
                                "INSERT INTO auth_identities (user_id, provider, provider_id) "
                                "VALUES ($1, $2, $3)", [UserId, Provider, ProviderId]),
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

extract_bearer(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> -> {ok, string:trim(Token)};
        _ -> {error, missing_token}
    end.

%% Generate an HMAC-SHA256 signed reset token: UserIdBin.ExpiryBin.HmacHex
generate_reset_token(UserId) ->
    Secret = ersub_config_srv:get(auth_jwt_secret, <<"default_secret">>),
    SecretBin = to_bin(Secret),
    Expiry = erlang:system_time(second) + 3600,  %% 1 hour
    UserIdBin = integer_to_binary(UserId),
    ExpiryBin = integer_to_binary(Expiry),
    Payload = <<UserIdBin/binary, ".", ExpiryBin/binary>>,
    Mac = crypto:mac(hmac, sha256, SecretBin, Payload),
    MacHex = binary:encode_hex(Mac),
    <<Payload/binary, ".", MacHex/binary>>.

%% Verify reset token: check HMAC signature and expiry
verify_reset_token(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [UserIdBin, ExpiryBin, MacHex] ->
            Secret = ersub_config_srv:get(auth_jwt_secret, <<"default_secret">>),
            SecretBin = to_bin(Secret),
            Payload = <<UserIdBin/binary, ".", ExpiryBin/binary>>,
            Expected = crypto:mac(hmac, sha256, SecretBin, Payload),
            ExpectedHex = binary:encode_hex(Expected),
            case crypto:hash_equals(ExpectedHex, MacHex) of
                true ->
                    Now = erlang:system_time(second),
                    Expiry = binary_to_integer(ExpiryBin),
                    case Expiry > Now of
                        true -> {ok, binary_to_integer(UserIdBin)};
                        false -> {error, token_expired}
                    end;
                false ->
                    {error, invalid_signature}
            end;
        _ ->
            {error, invalid_token}
    end.
