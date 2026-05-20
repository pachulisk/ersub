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

%% === T4-09: User Dashboard Enhancement ===

%% GET /api/v1/usage/stats
handle(<<"GET">>, [<<"stats">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT COUNT(*), COALESCE(SUM(actual_cost),0), COALESCE(AVG(duration_ms),0) "
        "FROM usage_logs WHERE user_id = $1",
        [UserId])
    of
        {ok, _, [{Count, TotalCost, AvgLatency}]} ->
            Req = reply_json(200, #{data => #{
                total_requests => Count,
                total_cost => TotalCost,
                avg_latency_ms => AvgLatency
            }}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/v1/usage/dashboard/trend
handle(<<"GET">>, [<<"dashboard">>, <<"trend">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT date_trunc('day', created_at) AS day, COUNT(*), "
        "COALESCE(SUM(actual_cost),0) "
        "FROM usage_logs WHERE user_id = $1 "
        "AND created_at > NOW() - INTERVAL '30 days' "
        "GROUP BY day ORDER BY day",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{day => D, count => C, cost => Co} || {D, C, Co} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/v1/usage/dashboard/models
handle(<<"GET">>, [<<"dashboard">>, <<"models">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT requested_model, COUNT(*), COALESCE(SUM(actual_cost),0) "
        "FROM usage_logs WHERE user_id = $1 "
        "AND created_at > NOW() - INTERVAL '30 days' "
        "GROUP BY requested_model ORDER BY COUNT(*) DESC",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{model => M, count => C, cost => Co} || {M, C, Co} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% === T5-07: User Subscriptions (routed from /api/v1/subscriptions/[...]) ===

%% GET /api/v1/subscriptions/list
handle(<<"GET">>, [<<"list">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT s.id, s.group_id, s.status, s.starts_at, s.expires_at, "
        "s.daily_usage_usd, s.weekly_usage_usd, s.monthly_usage_usd, "
        "g.name AS group_name "
        "FROM user_subscriptions s JOIN groups g ON g.id = s.group_id "
        "WHERE s.user_id = $1 ORDER BY s.created_at DESC",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{id => Id, group_id => GId, status => St,
                      starts_at => SA, expires_at => EA,
                      daily_usage_usd => DU, weekly_usage_usd => WU,
                      monthly_usage_usd => MU, group_name => GN}
                    || {Id, GId, St, SA, EA, DU, WU, MU, GN} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/v1/subscriptions/active
handle(<<"GET">>, [<<"active">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT s.id, s.group_id, s.status, s.starts_at, s.expires_at, "
        "s.daily_usage_usd, s.weekly_usage_usd, s.monthly_usage_usd, "
        "g.name AS group_name "
        "FROM user_subscriptions s JOIN groups g ON g.id = s.group_id "
        "WHERE s.user_id = $1 AND s.status = 'active' "
        "AND (s.expires_at IS NULL OR s.expires_at > NOW()) "
        "ORDER BY s.created_at DESC",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{id => Id, group_id => GId, status => St,
                      starts_at => SA, expires_at => EA,
                      daily_usage_usd => DU, weekly_usage_usd => WU,
                      monthly_usage_usd => MU, group_name => GN}
                    || {Id, GId, St, SA, EA, DU, WU, MU, GN} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/v1/subscriptions/progress
handle(<<"GET">>, [<<"progress">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT s.id, g.name AS group_name, s.daily_usage_usd, "
        "s.weekly_usage_usd, s.monthly_usage_usd, s.starts_at, s.expires_at "
        "FROM user_subscriptions s JOIN groups g ON g.id = s.group_id "
        "WHERE s.user_id = $1 AND s.status = 'active' "
        "AND (s.expires_at IS NULL OR s.expires_at > NOW())",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{id => Id, group_name => GN,
                      daily_usage_usd => DU, weekly_usage_usd => WU,
                      monthly_usage_usd => MU,
                      starts_at => SA, expires_at => EA}
                    || {Id, GN, DU, WU, MU, SA, EA} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/v1/subscriptions/summary
handle(<<"GET">>, [<<"summary">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT COUNT(*) FILTER (WHERE status = 'active' "
        "AND (expires_at IS NULL OR expires_at > NOW())), "
        "COUNT(*), COALESCE(SUM(monthly_usage_usd), 0) "
        "FROM user_subscriptions WHERE user_id = $1",
        [UserId])
    of
        {ok, _, [{ActiveCount, TotalCount, TotalMonthlyUsage}]} ->
            Req = reply_json(200, #{data => #{
                active_count => ActiveCount,
                total_count => TotalCount,
                total_monthly_usage_usd => TotalMonthlyUsage
            }}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% === T5-08: User Redeem (routed from /api/v1/redeem/[...]) ===

%% POST /api/v1/redeem/use
handle(<<"POST">>, [<<"use">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"code">> := Code} = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "UPDATE redeem_codes SET is_used = TRUE, used_by = $1, used_at = NOW() "
        "WHERE code = $2 AND is_used = FALSE RETURNING amount_usd",
        [UserId, Code])
    of
        {ok, 1, _, [{Amount}]} ->
            AmtFloat = to_float(Amount),
            ersub_repo:update_user_balance(UserId, AmtFloat),
            ersub_billing_srv:sync_balance(UserId),
            Req = reply_json(200, #{success => true, amount_usd => AmtFloat}, Req1),
            {ok, Req, State};
        {ok, 0, _, []} ->
            Req = reply_json(400, #{error => #{message => <<"Invalid or already used code">>}}, Req1),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
            {ok, Req, State}
    end;

%% GET /api/v1/redeem/history
handle(<<"GET">>, [<<"history">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT code, amount_usd, used_at "
        "FROM redeem_codes WHERE used_by = $1 ORDER BY used_at DESC",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{code => C, amount_usd => A, used_at => U}
                    || {C, A, U} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% === T5-09: User Groups Available + Rates (routed from /api/v1/groups/[...]) ===

%% GET /api/v1/groups/available
handle(<<"GET">>, [<<"available">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT g.id, g.name, g.platform "
        "FROM groups g JOIN user_allowed_groups uag ON uag.group_id = g.id "
        "WHERE uag.user_id = $1 ORDER BY g.sort_order ASC, g.id ASC",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{id => Id, name => N, platform => P}
                    || {Id, N, P} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/v1/groups/rates
handle(<<"GET">>, [<<"rates">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT g.id, g.name, g.rate_multiplier "
        "FROM groups g JOIN user_allowed_groups uag ON uag.group_id = g.id "
        "WHERE uag.user_id = $1 ORDER BY g.sort_order ASC, g.id ASC",
        [UserId])
    of
        {ok, _, Rows} ->
            Data = [#{id => Id, name => N, rate_multiplier => RM}
                    || {Id, N, RM} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% === T5-10: TOTP 2FA User Endpoints (routed from /api/v1/user/totp/[...]) ===

%% GET /api/v1/user/totp/status
handle(<<"GET">>, [<<"totp">>, <<"status">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT totp_secret FROM users WHERE id = $1 AND deleted_at IS NULL",
        [UserId])
    of
        {ok, _, [{TotpSecret}]} ->
            Enabled = TotpSecret =/= null andalso TotpSecret =/= undefined,
            Req = reply_json(200, #{data => #{enabled => Enabled}}, Req0),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{message => <<"User not found">>}}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% POST /api/v1/user/totp/setup
handle(<<"POST">>, [<<"totp">>, <<"setup">>], Req0, State, UserId) ->
    Secret = ersub_totp:generate_secret(),
    case ersub_repo:query(
        "SELECT email FROM users WHERE id = $1 AND deleted_at IS NULL",
        [UserId])
    of
        {ok, _, [{Email}]} ->
            Uri = ersub_totp:generate_uri(Email, Secret),
            {ok, _Body, Req1} = cowboy_req:read_body(Req0),
            Req = reply_json(200, #{data => #{
                secret => Secret,
                otpauth_uri => Uri
            }}, Req1),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{message => <<"User not found">>}}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% POST /api/v1/user/totp/enable
handle(<<"POST">>, [<<"totp">>, <<"enable">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"secret">> := Secret, <<"code">> := Code} =
        jsx:decode(Body, [return_maps]),
    case ersub_totp:verify_token(Code, Secret) of
        true ->
            case ersub_repo:query(
                "UPDATE users SET totp_secret = $2, totp_enabled = TRUE, "
                "updated_at = NOW() WHERE id = $1",
                [UserId, Secret])
            of
                {ok, _} ->
                    Req = reply_json(200, #{success => true}, Req1),
                    {ok, Req, State};
                {error, Reason} ->
                    Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
                    {ok, Req, State}
            end;
        false ->
            Req = reply_json(400, #{error => #{message => <<"Invalid TOTP code">>}}, Req1),
            {ok, Req, State}
    end;

%% POST /api/v1/user/totp/disable
handle(<<"POST">>, [<<"totp">>, <<"disable">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"code">> := Code} = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "SELECT totp_secret FROM users WHERE id = $1 AND deleted_at IS NULL",
        [UserId])
    of
        {ok, _, [{TotpSecret}]} when TotpSecret =/= null ->
            case ersub_totp:verify_token(Code, TotpSecret) of
                true ->
                    case ersub_repo:query(
                        "UPDATE users SET totp_secret = NULL, totp_enabled = FALSE, "
                        "updated_at = NOW() WHERE id = $1",
                        [UserId])
                    of
                        {ok, _} ->
                            Req = reply_json(200, #{success => true}, Req1),
                            {ok, Req, State};
                        {error, Reason} ->
                            Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
                            {ok, Req, State}
                    end;
                false ->
                    Req = reply_json(400, #{error => #{message => <<"Invalid TOTP code">>}}, Req1),
                    {ok, Req, State}
            end;
        {ok, _, [{_}]} ->
            Req = reply_json(400, #{error => #{message => <<"2FA is not enabled">>}}, Req1),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{message => <<"User not found">>}}, Req1),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
            {ok, Req, State}
    end;

%% === T5-18: User Email/Identity Binding ===

%% POST /api/v1/user/account-bindings/email — Bind email to user
handle(<<"POST">>, [<<"account-bindings">>, <<"email">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"email">> := NewEmail} = jsx:decode(Body, [return_maps]),
    case ersub_repo:update_user(UserId, #{email => NewEmail}) of
        {ok, _} ->
            Req = reply_json(200, #{success => true}, Req1),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
            {ok, Req, State}
    end;

%% DELETE /api/v1/user/account-bindings/:provider — Unbind OAuth identity
handle(<<"DELETE">>, [<<"account-bindings">>, Provider], Req0, State, UserId) ->
    case ersub_repo:query(
        "DELETE FROM auth_identities WHERE user_id = $1 AND provider = $2",
        [UserId, Provider])
    of
        {ok, 1} ->
            Req = reply_json(200, #{success => true}, Req0),
            {ok, Req, State};
        {ok, 0} ->
            Req = reply_json(404, #{error => #{message => <<"Identity not found">>}}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% POST /api/v1/user/auth-identities/bind/start — Start identity binding
handle(<<"POST">>, [<<"auth-identities">>, <<"bind">>, <<"start">>], Req0, State, _UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"provider">> := Provider} = jsx:decode(Body, [return_maps]),
    Prefix = <<"auth_oauth_providers_", Provider/binary>>,
    ClientId = ersub_config_srv:get(
        binary_to_atom(<<Prefix/binary, "_client_id">>), undefined),
    case ClientId of
        undefined ->
            Req = reply_json(400, #{error => #{message => <<"OAuth provider not configured">>}}, Req1),
            {ok, Req, State};
        _ ->
            AuthUrl = to_bin_cfg(ersub_config_srv:get(
                binary_to_atom(<<Prefix/binary, "_auth_url">>), <<>>)),
            Scope = to_bin_cfg(ersub_config_srv:get(
                binary_to_atom(<<Prefix/binary, "_scope">>), <<"openid email profile">>)),
            RedirectUri = build_bind_redirect_uri(Provider),
            OAuthState = binary:encode_hex(crypto:strong_rand_bytes(16)),
            Location = iolist_to_binary([
                AuthUrl, <<"?client_id=">>, to_bin_cfg(ClientId),
                <<"&redirect_uri=">>, RedirectUri,
                <<"&response_type=code">>,
                <<"&state=">>, OAuthState,
                <<"&scope=">>, Scope
            ]),
            Req = reply_json(200, #{data => #{url => Location}}, Req1),
            {ok, Req, State}
    end;

%% === T6-10: User Notify Email ===

%% POST /api/v1/user/notify-email/send-code
handle(<<"POST">>, [<<"notify-email">>, <<"send-code">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"email">> := Email} = jsx:decode(Body, [return_maps]),
    UIdBin = integer_to_binary(UserId),
    Code = integer_to_binary(100000 + rand:uniform(899999)),
    Expiry = erlang:system_time(second) + 600,
    SettingKey = <<"notify_code_", UIdBin/binary>>,
    case ersub_repo:upsert_setting(SettingKey, #{code => Code, email => Email, expires => Expiry}) of
        {ok, _} ->
            Req = reply_json(200, #{success => true, message => <<"Verification code sent">>}, Req1),
            {ok, Req, State};
        {ok, _, _} ->
            Req = reply_json(200, #{success => true, message => <<"Verification code sent">>}, Req1),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
            {ok, Req, State}
    end;

%% POST /api/v1/user/notify-email/verify
handle(<<"POST">>, [<<"notify-email">>, <<"verify">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"code">> := InputCode} = jsx:decode(Body, [return_maps]),
    UIdBin = integer_to_binary(UserId),
    SettingKey = <<"notify_code_", UIdBin/binary>>,
    case ersub_repo:get_setting(SettingKey) of
        {ok, #{<<"code">> := StoredCode, <<"email">> := Email, <<"expires">> := Expiry}} ->
            Now = erlang:system_time(second),
            case InputCode =:= StoredCode andalso Now < Expiry of
                true ->
                    %% Store verified notify email
                    EmailKey = <<"user_notify_email_", UIdBin/binary>>,
                    ersub_repo:upsert_setting(EmailKey, #{email => Email, enabled => true}),
                    Req = reply_json(200, #{success => true, email => Email}, Req1),
                    {ok, Req, State};
                false ->
                    Req = reply_json(400, #{error => #{message => <<"Invalid or expired code">>}}, Req1),
                    {ok, Req, State}
            end;
        _ ->
            Req = reply_json(400, #{error => #{message => <<"No pending verification">>}}, Req1),
            {ok, Req, State}
    end;

%% PUT /api/v1/user/notify-email/toggle
handle(<<"PUT">>, [<<"notify-email">>, <<"toggle">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"enabled">> := Enabled} = jsx:decode(Body, [return_maps]),
    UIdBin = integer_to_binary(UserId),
    SettingKey = <<"user_notify_email_", UIdBin/binary>>,
    case ersub_repo:upsert_setting(SettingKey, #{enabled => Enabled}) of
        {ok, _} ->
            Req = reply_json(200, #{success => true}, Req1),
            {ok, Req, State};
        {ok, _, _} ->
            Req = reply_json(200, #{success => true}, Req1),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
            {ok, Req, State}
    end;

%% DELETE /api/v1/user/notify-email
handle(<<"DELETE">>, [<<"notify-email">>], Req0, State, UserId) ->
    UIdBin = integer_to_binary(UserId),
    SettingKey = <<"user_notify_email_", UIdBin/binary>>,
    case ersub_repo:query("DELETE FROM settings WHERE key = $1", [SettingKey]) of
        {ok, _} ->
            Req = reply_json(200, #{success => true}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% === T6-11: User Affiliate ===

%% GET /api/v1/user/aff
handle(<<"GET">>, [<<"aff">>], Req0, State, UserId) ->
    case ersub_affiliate_srv:get_affiliate(UserId) of
        {ok, AffInfo} ->
            Req = reply_json(200, #{data => AffInfo}, Req0),
            {ok, Req, State};
        {error, not_found} ->
            Req = reply_json(200, #{data => #{}}, Req0),
            {ok, Req, State}
    end;

%% POST /api/v1/user/aff/transfer
handle(<<"POST">>, [<<"aff">>, <<"transfer">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ToUserId = maps:get(<<"to_user_id">>, Params),
    Amount = to_float(maps:get(<<"amount">>, Params)),
    case Amount > 0 of
        false ->
            Req = reply_json(400, #{error => #{message => <<"Amount must be positive">>}}, Req1),
            {ok, Req, State};
        true ->
            %% Deduct from caller's aff_quota
            case ersub_repo:query(
                "UPDATE user_affiliates SET aff_quota = aff_quota - $2 "
                "WHERE user_id = $1 AND aff_quota >= $2 AND is_frozen = FALSE "
                "RETURNING aff_quota", [UserId, Amount])
            of
                {ok, 1, _, [{NewQuota}]} ->
                    %% Add to target user's balance
                    ersub_repo:update_user_balance(ToUserId, Amount),
                    %% Record ledger entry
                    ersub_repo:query(
                        "INSERT INTO user_affiliate_ledger "
                        "(user_id, action, amount, related_user_id) "
                        "VALUES ($1, 'transfer', $2, $3)",
                        [UserId, Amount, ToUserId]),
                    ersub_billing_srv:sync_balance(ToUserId),
                    Req = reply_json(200, #{success => true, remaining_quota => NewQuota}, Req1),
                    {ok, Req, State};
                {ok, 0, _, []} ->
                    Req = reply_json(400, #{error => #{message => <<"Insufficient affiliate quota">>}}, Req1),
                    {ok, Req, State};
                {error, Reason} ->
                    Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
                    {ok, Req, State}
            end
    end;

%% === T7-02: Single-item GET endpoints ===

%% GET /api/v1/usage/usage-detail/:id — Get single usage record
handle(<<"GET">>, [<<"usage-detail">>, IdBin], Req0, State, UserId) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, request_id, requested_model, input_tokens, output_tokens, "
        "actual_cost, stream, duration_ms, created_at "
        "FROM usage_logs WHERE id = $1 AND user_id = $2",
        [Id, UserId])
    of
        {ok, _, [{LId, RId, M, IT, OT, C, S, D, CA}]} ->
            Req = reply_json(200, #{data => #{
                id => LId, request_id => RId, model => M,
                input_tokens => IT, output_tokens => OT,
                cost => C, stream => S, duration_ms => D,
                created_at => CA
            }}, Req0),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{message => <<"Usage record not found">>}}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% === T7-04: User Email Bind Send Code ===

%% POST /api/v1/user/account-bindings/email/send-code
handle(<<"POST">>, [<<"account-bindings">>, <<"email">>, <<"send-code">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"email">> := NewEmail} = jsx:decode(Body, [return_maps]),
    UIdBin = integer_to_binary(UserId),
    Code = integer_to_binary(100000 + rand:uniform(899999)),
    Expiry = erlang:system_time(second) + 600,
    SettingKey = <<"email_bind_code_", UIdBin/binary>>,
    case ersub_repo:upsert_setting(SettingKey, #{code => Code, email => NewEmail, expires => Expiry}) of
        {ok, _} ->
            Req = reply_json(200, #{success => true, message => <<"Verification code sent">>}, Req1),
            {ok, Req, State};
        {ok, _, _} ->
            Req = reply_json(200, #{success => true, message => <<"Verification code sent">>}, Req1),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req1),
            {ok, Req, State}
    end;

%% === T7-07: User Channel Monitors (read-only) ===

%% GET /api/v1/user/channel-monitors — List active monitors
handle(<<"GET">>, [<<"channel-monitors">>], Req0, State, _UserId) ->
    case ersub_repo:squery(
        "SELECT cm.id, cm.channel_id, cm.is_active, cm.created_at "
        "FROM channel_monitors cm "
        "WHERE cm.is_active = TRUE "
        "ORDER BY cm.id LIMIT 50"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => Id, channel_id => ChId, is_active => IA, created_at => CA}
                    || {Id, ChId, IA, CA} <- Rows],
            Req = reply_json(200, #{data => Data}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% GET /api/v1/user/channel-monitors/:id/status — Monitor status
handle(<<"GET">>, [<<"channel-monitors">>, IdBin, <<"status">>], Req0, State, _UserId) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT cm.id, cm.channel_id, cm.is_active, cm.created_at, "
        "h.status_code, h.latency_ms, h.is_success, h.checked_at "
        "FROM channel_monitors cm "
        "LEFT JOIN LATERAL ("
        "  SELECT status_code, latency_ms, is_success, checked_at "
        "  FROM channel_monitor_histories WHERE monitor_id = cm.id "
        "  ORDER BY checked_at DESC LIMIT 1"
        ") h ON TRUE "
        "WHERE cm.id = $1", [Id])
    of
        {ok, _, [{MId, ChId, IA, CA, SC, LM, IS, ChAt}]} ->
            Req = reply_json(200, #{data => #{
                id => MId, channel_id => ChId, is_active => IA,
                created_at => CA,
                last_check => #{status_code => SC, latency_ms => LM,
                                is_success => IS, checked_at => ChAt}
            }}, Req0),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{message => <<"Monitor not found">>}}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% POST /api/v1/usage/api-keys-usage — Batch API key usage for user
handle(<<"POST">>, [<<"api-keys-usage">>], Req0, State, UserId) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    KeyIds = maps:get(<<"key_ids">>, P, []),
    Data = lists:foldl(fun(KID, Acc) ->
        KIdInt = case is_integer(KID) of true -> KID; false -> binary_to_integer(KID) end,
        %% Only query keys owned by this user
        case ersub_repo:query(
            "SELECT COUNT(*), COALESCE(SUM(ul.actual_cost::numeric),0) "
            "FROM usage_logs ul "
            "JOIN api_keys ak ON ak.id = ul.api_key_id "
            "WHERE ak.id = $1 AND ak.user_id = $2 "
            "AND ul.created_at > NOW() - INTERVAL '24 hours'",
            [KIdInt, UserId]) of
            {ok, _, [{Cnt, Cost}]} ->
                Acc#{integer_to_binary(KIdInt) => #{requests => Cnt, cost => Cost}};
            _ ->
                Acc#{integer_to_binary(KIdInt) => #{requests => 0, cost => <<"0">>}}
        end
    end, #{}, KeyIds),
    Req = reply_json(200, #{data => Data}, Req1),
    {ok, Req, State};

%% === T7-10: TOTP Extension ===

%% GET /api/v1/user/totp/verification-method — Current verification method
handle(<<"GET">>, [<<"totp">>, <<"verification-method">>], Req0, State, UserId) ->
    case ersub_repo:query(
        "SELECT totp_secret FROM users WHERE id = $1 AND deleted_at IS NULL",
        [UserId])
    of
        {ok, _, [{TotpSecret}]} ->
            Method = case TotpSecret of
                null -> <<"none">>;
                undefined -> <<"none">>;
                _ -> <<"totp">>
            end,
            Req = reply_json(200, #{data => #{method => Method}}, Req0),
            {ok, Req, State};
        {ok, _, []} ->
            Req = reply_json(404, #{error => #{message => <<"User not found">>}}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = reply_json(500, #{error => fmt_err(Reason)}, Req0),
            {ok, Req, State}
    end;

%% POST /api/v1/user/totp/send-code — Placeholder for email code (no SMTP)
handle(<<"POST">>, [<<"totp">>, <<"send-code">>], Req0, State, _UserId) ->
    {ok, _Body, Req1} = cowboy_req:read_body(Req0),
    Req = reply_json(200, #{data => #{sent => false,
        reason => <<"email_not_configured">>}}, Req1),
    {ok, Req, State};

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

to_float(V) when is_binary(V) ->
    try binary_to_float(V) catch _:_ ->
        try float(binary_to_integer(V)) catch _:_ -> 0.0 end
    end;
to_float(V) when is_float(V) -> V;
to_float(V) when is_integer(V) -> V * 1.0;
to_float(_) -> 0.0.
auth_msg(missing_token) -> <<"Missing Authorization header">>;
auth_msg(token_expired) -> <<"Token expired">>;
auth_msg(_) -> <<"Authentication failed">>.

to_bin_cfg(V) when is_binary(V) -> V;
to_bin_cfg(V) when is_list(V) -> list_to_binary(V);
to_bin_cfg(V) when is_atom(V) -> atom_to_binary(V);
to_bin_cfg(V) -> iolist_to_binary(io_lib:format("~p", [V])).

build_bind_redirect_uri(Provider) ->
    BaseUrl = ersub_config_srv:get(server_base_url, undefined),
    Base = case BaseUrl of
        undefined ->
            Host = ersub_config_srv:get(server_host, "0.0.0.0"),
            Port = ersub_config_srv:get(server_port, 8080),
            iolist_to_binary(io_lib:format("http://~s:~p", [Host, Port]));
        U when is_list(U) -> list_to_binary(U);
        U when is_binary(U) -> U
    end,
    <<Base/binary, "/api/auth/oauth/", Provider/binary, "/callback">>.
