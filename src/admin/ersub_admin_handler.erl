-module(ersub_admin_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case verify_admin_jwt(Req0) of
        {error, Reason} ->
            Req = reply_json(401, #{error => #{
                type => <<"authentication_error">>,
                message => auth_msg(Reason)
            }}, Req0),
            {ok, Req, State};
        {ok, Claims} ->
            Path = cowboy_req:path_info(Req0),
            handle(Method, Path, Req0, State, Claims)
    end.

%% === Users ===

%% GET /api/admin/users
handle(<<"GET">>, [<<"users">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, email, role, balance_usd, max_concurrency, is_banned, "
        "created_at FROM users WHERE deleted_at IS NULL ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Users = [#{id => Id, email => E, role => R, balance_usd => B,
                       max_concurrency => MC, is_banned => IB, created_at => CA}
                     || {Id, E, R, B, MC, IB, CA} <- Rows],
            reply_ok(#{data => Users}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/users
handle(<<"POST">>, [<<"users">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Email = maps:get(<<"email">>, Params),
    Password = maps:get(<<"password">>, Params),
    Role = maps:get(<<"role">>, Params, <<"user">>),
    Hash = ersub_auth_srv:hash_password(Password),
    case ersub_repo:create_user(#{email => Email, password_hash => Hash, role => Role}) of
        {ok, User} ->
            reply_ok(#{data => maps:without([password_hash], User)}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === Accounts ===

%% GET /api/admin/accounts
handle(<<"GET">>, [<<"accounts">>], Req0, State, _Claims) ->
    case ersub_repo:list_accounts(#{}) of
        {ok, Accounts} ->
            reply_ok(#{data => Accounts}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/accounts
handle(<<"POST">>, [<<"accounts">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Attrs = #{
        name => maps:get(<<"name">>, Params),
        platform => maps:get(<<"platform">>, Params),
        account_type => maps:get(<<"account_type">>, Params),
        credentials => maps:get(<<"credentials">>, Params, #{}),
        priority => maps:get(<<"priority">>, Params, 100),
        concurrency => maps:get(<<"concurrency">>, Params, 5)
    },
    case ersub_repo:create_account(Attrs) of
        {ok, Account} ->
            %% Start account process
            _ = case ersub_repo:get_account(maps:get(id, Account)) of
                {ok, FullAcc} -> ersub_platform_sup:start_account(FullAcc);
                _ -> ok
            end,
            reply_ok(#{data => Account}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% DELETE /api/admin/accounts/:id
handle(<<"DELETE">>, [<<"accounts">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    _ = ersub_platform_sup:stop_account(Id),
    case ersub_repo:delete_account(Id) of
        {ok, _} -> reply_ok(#{success => true}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === Groups ===

%% GET /api/admin/groups
handle(<<"GET">>, [<<"groups">>], Req0, State, _Claims) ->
    case ersub_repo:list_groups() of
        {ok, Groups} -> reply_ok(#{data => Groups}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/groups
handle(<<"POST">>, [<<"groups">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Attrs = #{
        name => maps:get(<<"name">>, Params),
        platform => maps:get(<<"platform">>, Params),
        rate_multiplier => maps:get(<<"rate_multiplier">>, Params, 1.0)
    },
    case ersub_repo:create_group(Attrs) of
        {ok, Group} -> reply_ok(#{data => Group}, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% === Account-Group Binding ===

%% POST /api/admin/account-groups
handle(<<"POST">>, [<<"account-groups">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"account_id">> := AId, <<"group_id">> := GId} =
        jsx:decode(Body, [return_maps]),
    case ersub_repo:bind_account_to_group(AId, GId) of
        ok -> reply_ok(#{success => true}, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% === Typed Settings (T4-10) ===

%% GET /api/v1/admin/settings/overload-cooldown
handle(<<"GET">>, [<<"settings">>, <<"overload-cooldown">>], Req0, State, _Claims) ->
    typed_setting_get(<<"ops_overload_cooldown_s">>, Req0, State);

%% PUT /api/v1/admin/settings/overload-cooldown
handle(<<"PUT">>, [<<"settings">>, <<"overload-cooldown">>], Req0, State, _Claims) ->
    typed_setting_put(<<"ops_overload_cooldown_s">>, Req0, State);

%% GET /api/v1/admin/settings/rate-limit-cooldown
handle(<<"GET">>, [<<"settings">>, <<"rate-limit-cooldown">>], Req0, State, _Claims) ->
    typed_setting_get(<<"ops_rate_limit_cooldown_s">>, Req0, State);

%% PUT /api/v1/admin/settings/rate-limit-cooldown
handle(<<"PUT">>, [<<"settings">>, <<"rate-limit-cooldown">>], Req0, State, _Claims) ->
    typed_setting_put(<<"ops_rate_limit_cooldown_s">>, Req0, State);

%% GET /api/v1/admin/settings/stream-timeout
handle(<<"GET">>, [<<"settings">>, <<"stream-timeout">>], Req0, State, _Claims) ->
    typed_setting_get(<<"ops_stream_timeout_ms">>, Req0, State);

%% PUT /api/v1/admin/settings/stream-timeout
handle(<<"PUT">>, [<<"settings">>, <<"stream-timeout">>], Req0, State, _Claims) ->
    typed_setting_put(<<"ops_stream_timeout_ms">>, Req0, State);

%% === T5-28: Admin Settings Extension ===

%% GET /api/v1/admin/settings/admin-api-key — Read (masked)
handle(<<"GET">>, [<<"settings">>, <<"admin-api-key">>], Req0, State, _Claims) ->
    case ersub_repo:get_setting(<<"admin_api_key">>) of
        {ok, KeyVal} when is_binary(KeyVal), byte_size(KeyVal) > 12 ->
            Masked = iolist_to_binary([
                binary:part(KeyVal, 0, 8), <<"****">>,
                binary:part(KeyVal, byte_size(KeyVal) - 4, 4)
            ]),
            reply_ok(#{data => #{key => <<"admin_api_key">>, value => Masked}}, Req0, State);
        {ok, _KeyVal} ->
            reply_ok(#{data => #{key => <<"admin_api_key">>, value => <<"****">>}}, Req0, State);
        {error, not_found} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/settings/admin-api-key/regenerate — Generate new key
handle(<<"POST">>, [<<"settings">>, <<"admin-api-key">>, <<"regenerate">>], Req0, State, _Claims) ->
    NewKey = binary:encode_hex(crypto:strong_rand_bytes(24)),
    case ersub_repo:upsert_setting(<<"admin_api_key">>, NewKey) of
        {ok, _} ->
            ersub_config_srv:set(admin_api_key, NewKey),
            Masked = iolist_to_binary([
                binary:part(NewKey, 0, 8), <<"****">>,
                binary:part(NewKey, byte_size(NewKey) - 4, 4)
            ]),
            reply_ok(#{data => #{key => <<"admin_api_key">>, value => Masked}}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% DELETE /api/v1/admin/settings/admin-api-key — Delete the key
handle(<<"DELETE">>, [<<"settings">>, <<"admin-api-key">>], Req0, State, _Claims) ->
    case ersub_repo:query("DELETE FROM settings WHERE key = $1", [<<"admin_api_key">>]) of
        {ok, _} ->
            reply_ok(#{success => true}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/settings/rectifier
handle(<<"GET">>, [<<"settings">>, <<"rectifier">>], Req0, State, _Claims) ->
    typed_setting_get(<<"ops_rectifier">>, Req0, State);

%% PUT /api/v1/admin/settings/rectifier
handle(<<"PUT">>, [<<"settings">>, <<"rectifier">>], Req0, State, _Claims) ->
    typed_setting_put(<<"ops_rectifier">>, Req0, State);

%% GET /api/v1/admin/settings/beta-policy
handle(<<"GET">>, [<<"settings">>, <<"beta-policy">>], Req0, State, _Claims) ->
    typed_setting_get(<<"ops_beta_policy">>, Req0, State);

%% PUT /api/v1/admin/settings/beta-policy
handle(<<"PUT">>, [<<"settings">>, <<"beta-policy">>], Req0, State, _Claims) ->
    typed_setting_put(<<"ops_beta_policy">>, Req0, State);

%% === T6-12: Settings Extension ===

%% GET /api/v1/admin/settings/web-search-emulation
handle(<<"GET">>, [<<"settings">>, <<"web-search-emulation">>], Req0, State, _Claims) ->
    typed_setting_get(<<"ops_web_search_emulation">>, Req0, State);

%% PUT /api/v1/admin/settings/web-search-emulation
handle(<<"PUT">>, [<<"settings">>, <<"web-search-emulation">>], Req0, State, _Claims) ->
    typed_setting_put(<<"ops_web_search_emulation">>, Req0, State);

%% POST /api/v1/admin/settings/web-search-emulation/test
handle(<<"POST">>, [<<"settings">>, <<"web-search-emulation">>, <<"test">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Query = maps:get(<<"query">>, Params, <<>>),
    Result = ersub_web_search:emulate_search_result(Query),
    reply_ok(#{data => Result}, Req1, State);

%% POST /api/v1/admin/settings/web-search-emulation/reset-usage
handle(<<"POST">>, [<<"settings">>, <<"web-search-emulation">>, <<"reset-usage">>], Req0, State, _Claims) ->
    case ersub_repo:query("DELETE FROM settings WHERE key = $1", [<<"web_search_usage_count">>]) of
        {ok, _} -> reply_ok(#{success => true}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === Settings ===

%% GET /api/admin/settings/:key
handle(<<"GET">>, [<<"settings">>, Key], Req0, State, _Claims) ->
    case ersub_repo:get_setting(Key) of
        {ok, Value} -> reply_ok(#{data => #{key => Key, value => Value}}, Req0, State);
        {error, not_found} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/settings/:key
handle(<<"POST">>, [<<"settings">>, Key], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Value = jsx:decode(Body, [return_maps]),
    case ersub_repo:upsert_setting(Key, Value) of
        {ok, _} ->
            %% Also update runtime config
            ersub_config_srv:set(binary_to_atom(Key), Value),
            reply_ok(#{success => true}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === Dashboard ===

%% GET /api/admin/dashboard
handle(<<"GET">>, [<<"dashboard">>], Req0, State, _Claims) ->
    %% Basic dashboard stats
    {ok, _, [{UserCount}]} = ersub_repo:squery(
        "SELECT COUNT(*) FROM users WHERE deleted_at IS NULL"),
    {ok, _, [{AccountCount}]} = ersub_repo:squery(
        "SELECT COUNT(*) FROM accounts WHERE status = 'active'"),
    {ok, _, [{KeyCount}]} = ersub_repo:squery(
        "SELECT COUNT(*) FROM api_keys WHERE deleted_at IS NULL AND is_active = TRUE"),
    RunningAccounts = length(ersub_platform_sup:list_accounts()),
    Dashboard = #{
        users => binary_to_integer(UserCount),
        active_accounts => binary_to_integer(AccountCount),
        running_accounts => RunningAccounts,
        active_keys => binary_to_integer(KeyCount)
    },
    reply_ok(#{data => Dashboard}, Req0, State);

%% === Reload accounts ===

%% POST /api/admin/accounts/reload
handle(<<"POST">>, [<<"accounts">>, <<"reload">>], Req0, State, _Claims) ->
    _ = ersub_platform_sup:load_all_accounts(),
    reply_ok(#{success => true, running => length(ersub_platform_sup:list_accounts())},
             Req0, State);

%% POST /api/admin/clips/reload
handle(<<"POST">>, [<<"clips">>, <<"reload">>], Req0, State, _Claims) ->
    ersub_clips_pool:reload_rules(),
    ersub_clips_config:reload(),
    reply_ok(#{success => true}, Req0, State);

%% === Data Export ===

%% GET /api/admin/export/usage
handle(<<"GET">>, [<<"export">>, <<"usage">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT request_id, user_id, requested_model, input_tokens, output_tokens, "
        "actual_cost, stream, created_at FROM usage_logs "
        "ORDER BY created_at DESC LIMIT 10000"
    ) of
        {ok, _, Rows} ->
            Header = <<"request_id,user_id,model,input_tokens,output_tokens,cost,stream,created_at\r\n">>,
            CsvRows = lists:map(fun({RId, UID, Model, IT, OT, Cost, Stream, CA}) ->
                iolist_to_binary([
                    csv_field(RId), <<",">>, csv_field(UID), <<",">>,
                    csv_field(Model), <<",">>, csv_field(IT), <<",">>,
                    csv_field(OT), <<",">>, csv_field(Cost), <<",">>,
                    csv_field(Stream), <<",">>, csv_field(CA), <<"\r\n">>
                ])
            end, Rows),
            CsvBody = iolist_to_binary([Header | CsvRows]),
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/csv">>,
                  <<"content-disposition">> => <<"attachment; filename=\"usage_export.csv\"">>},
                CsvBody, Req0),
            {ok, Req, State};
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/admin/export/users
handle(<<"GET">>, [<<"export">>, <<"users">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, email, role, balance_usd, max_concurrency, is_banned, "
        "created_at FROM users WHERE deleted_at IS NULL ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Header = <<"id,email,role,balance_usd,max_concurrency,is_banned,created_at\r\n">>,
            CsvRows = lists:map(fun({Id, E, R, B, MC, IB, CA}) ->
                iolist_to_binary([
                    csv_field(Id), <<",">>, csv_field(E), <<",">>,
                    csv_field(R), <<",">>, csv_field(B), <<",">>,
                    csv_field(MC), <<",">>, csv_field(IB), <<",">>,
                    csv_field(CA), <<"\r\n">>
                ])
            end, Rows),
            CsvBody = iolist_to_binary([Header | CsvRows]),
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/csv">>,
                  <<"content-disposition">> => <<"attachment; filename=\"users_export.csv\"">>},
                CsvBody, Req0),
            {ok, Req, State};
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === Ops Settings ===

%% GET /api/v1/admin/ops/settings
handle(<<"GET">>, [<<"ops">>, <<"settings">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT key, value FROM settings WHERE key LIKE 'ops_%' ORDER BY key"
    ) of
        {ok, _, Rows} ->
            Settings = maps:from_list([{K, jsx:decode(V, [return_maps])} || {K, V} <- Rows]),
            reply_ok(#{data => Settings}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/ops/settings
handle(<<"PUT">>, [<<"ops">>, <<"settings">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Results = maps:fold(fun(Key, Value, Acc) ->
        FullKey = <<"ops_", Key/binary>>,
        case ersub_repo:upsert_setting(FullKey, Value) of
            {ok, _} ->
                ersub_config_srv:set(binary_to_atom(FullKey), Value),
                Acc;
            {error, R} ->
                [{Key, R} | Acc]
        end
    end, [], Params),
    case Results of
        [] -> reply_ok(#{success => true}, Req1, State);
        Errors ->
            ErrMap = maps:from_list([{K, iolist_to_binary(io_lib:format("~p", [R]))}
                                     || {K, R} <- Errors]),
            reply_err(400, ErrMap, Req1, State)
    end;

%% === Channel Monitor ===

%% GET /api/v1/channels/:id/monitor
handle(<<"GET">>, [Id, <<"monitor">>], Req0, State, _Claims) ->
    ChannelId = binary_to_integer(Id),
    case ersub_repo:query(
        "SELECT h.id, h.monitor_id, h.status_code, h.latency_ms, h.is_success, "
        "h.error_message, h.checked_at "
        "FROM channel_monitor_histories h "
        "JOIN channel_monitors m ON m.id = h.monitor_id "
        "WHERE m.channel_id = $1 "
        "ORDER BY h.checked_at DESC LIMIT 50",
        [ChannelId]
    ) of
        {ok, _, Rows} ->
            Histories = [#{id => HId, monitor_id => MId, status_code => SC,
                           latency_ms => LMs, is_success => Succ,
                           error_message => EMsg, checked_at => CA}
                         || {HId, MId, SC, LMs, Succ, EMsg, CA} <- Rows],
            reply_ok(#{data => Histories}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === Usage Analytics ===

%% GET /api/v1/admin/usage/search-users — Search users by email fragment
handle(<<"GET">>, [<<"usage">>, <<"search-users">>], Req0, State, _Claims) ->
    QS = cowboy_req:parse_qs(Req0),
    Q = proplists:get_value(<<"q">>, QS, <<>>),
    case ersub_repo:query(
        "SELECT id, email FROM users "
        "WHERE email ILIKE '%' || $1 || '%' AND deleted_at IS NULL LIMIT 20",
        [Q])
    of
        {ok, _, Rows} ->
            Data = [#{id => Id, email => E} || {Id, E} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/usage/search-api-keys — Search API keys by prefix
handle(<<"GET">>, [<<"usage">>, <<"search-api-keys">>], Req0, State, _Claims) ->
    QS = cowboy_req:parse_qs(Req0),
    Q = proplists:get_value(<<"q">>, QS, <<>>),
    case ersub_repo:query(
        "SELECT id, key_prefix, name, user_id FROM api_keys "
        "WHERE key_prefix ILIKE '%' || $1 || '%' AND deleted_at IS NULL LIMIT 20",
        [Q])
    of
        {ok, _, Rows} ->
            Data = [#{id => Id, key_prefix => KP, name => N, user_id => UID}
                    || {Id, KP, N, UID} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/usage/stats
handle(<<"GET">>, [<<"usage">>, <<"stats">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT COUNT(*), COALESCE(SUM(actual_cost), 0), "
        "COALESCE(AVG(duration_ms), 0) FROM usage_logs"
    ) of
        {ok, _, [{TotalReqs, TotalCost, AvgLatency}]} ->
            reply_ok(#{data => #{
                total_requests => binary_to_integer(TotalReqs),
                total_cost => TotalCost,
                avg_latency_ms => AvgLatency
            }}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/usage
handle(<<"GET">>, [<<"usage">>], Req0, State, _Claims) ->
    QS = cowboy_req:parse_qs(Req0),
    Page = qs_int(<<"page">>, QS, 1),
    Limit = qs_int(<<"limit">>, QS, 50),
    Offset = (Page - 1) * Limit,
    UserFilter = case proplists:get_value(<<"user_id">>, QS, undefined) of
        undefined -> undefined;
        UBin -> try binary_to_integer(UBin) catch _:_ -> undefined end
    end,
    ModelFilter = proplists:get_value(<<"model">>, QS, undefined),
    {WhereClause, Params} = build_usage_filters(UserFilter, ModelFilter),
    CountSQL = iolist_to_binary([
        "SELECT COUNT(*) FROM usage_logs", WhereClause]),
    DataSQL = iolist_to_binary([
        "SELECT id, user_id, request_id, requested_model, input_tokens, output_tokens, "
        "actual_cost, stream, duration_ms, created_at FROM usage_logs",
        WhereClause,
        " ORDER BY created_at DESC LIMIT $", integer_to_binary(length(Params) + 1),
        " OFFSET $", integer_to_binary(length(Params) + 2)]),
    case ersub_repo:query(CountSQL, Params) of
        {ok, _, [{Total}]} ->
            case ersub_repo:query(DataSQL, Params ++ [Limit, Offset]) of
                {ok, _, Rows} ->
                    Logs = [#{id => LId, user_id => UID, request_id => RId,
                              model => M, input_tokens => IT, output_tokens => OT,
                              cost => C, stream => S, duration_ms => D,
                              created_at => CA}
                            || {LId, UID, RId, M, IT, OT, C, S, D, CA} <- Rows],
                    reply_ok(#{data => Logs,
                               meta => #{total => Total, page => Page, limit => Limit}},
                             Req0, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req0, State)
            end;
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === Subscriptions ===

%% GET /api/v1/admin/subscriptions
handle(<<"GET">>, [<<"subscriptions">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, user_id, group_id, status, starts_at, expires_at, "
        "daily_usage_usd, weekly_usage_usd, monthly_usage_usd, created_at "
        "FROM user_subscriptions ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Subs = [#{id => SId, user_id => UID, group_id => GID, status => St,
                       starts_at => SA, expires_at => EA,
                       daily_usage_usd => DU, weekly_usage_usd => WU,
                       monthly_usage_usd => MU, created_at => CA}
                    || {SId, UID, GID, St, SA, EA, DU, WU, MU, CA} <- Rows],
            reply_ok(#{data => Subs}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/subscriptions — uses CLIPS subscription.clp
handle(<<"POST">>, [<<"subscriptions">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    UserId = maps:get(<<"user_id">>, Params),
    GroupId = maps:get(<<"group_id">>, Params),
    StartsAt = maps:get(<<"starts_at">>, Params, <<"now">>),
    %% Look up group billing_type for CLIPS validation
    case ersub_repo:query("SELECT billing_type FROM groups WHERE id = $1", [GroupId]) of
        {ok, _, [{BillingType}]} ->
            ClipsData = #{user_id => UserId, group_id => GroupId, billing_type => BillingType},
            case ersub_clips_pool:evaluate_subscription(ClipsData) of
                {ok, Result} ->
                    Allowed = maps:get(<<"allowed">>, Result, false),
                    IsAllowed = (Allowed =:= true orelse Allowed =:= <<"TRUE">>),
                    case IsAllowed of
                        true ->
                            case ersub_repo:query(
                                "INSERT INTO user_subscriptions (user_id, group_id, starts_at) "
                                "VALUES ($1, $2, $3) RETURNING id, status, created_at",
                                [UserId, GroupId, StartsAt]
                            ) of
                                {ok, 1, _, [{SubId, Status, CreatedAt}]} ->
                                    reply_ok(#{data => #{id => SubId, user_id => UserId,
                                                         group_id => GroupId, status => Status,
                                                         starts_at => StartsAt,
                                                         created_at => CreatedAt}}, Req1, State);
                                {error, Reason} ->
                                    reply_err(500, Reason, Req1, State)
                            end;
                        false ->
                            DenyReason = maps:get(<<"reason">>, Result, <<"subscription_denied">>),
                            reply_err(400, DenyReason, Req1, State)
                    end;
                {error, Reason} ->
                    reply_err(400, Reason, Req1, State)
            end;
        {ok, _, []} ->
            reply_err(404, group_not_found, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% DELETE /api/v1/admin/subscriptions/:id
handle(<<"DELETE">>, [<<"subscriptions">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "DELETE FROM user_subscriptions WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === System Diagnostics ===

%% GET /api/v1/admin/system
handle(<<"GET">>, [<<"system">>], Req0, State, _Claims) ->
    Memory = erlang:memory(),
    Children = supervisor:which_children(ersub_sup),
    {PoolStatus, PoolWorkers, PoolOverflow, PoolMonitors} =
        poolboy:status(ersub_clips_pool),
    {WallClock, _} = erlang:statistics(wall_clock),
    UptimeSecs = WallClock div 1000,
    SystemInfo = #{
        memory => #{
            total => proplists:get_value(total, Memory),
            processes => proplists:get_value(processes, Memory),
            system => proplists:get_value(system, Memory),
            atom => proplists:get_value(atom, Memory),
            binary => proplists:get_value(binary, Memory),
            ets => proplists:get_value(ets, Memory)
        },
        clips_pool => #{
            status => PoolStatus,
            available_workers => PoolWorkers,
            overflow => PoolOverflow,
            monitors => PoolMonitors
        },
        supervisor_children => length(Children),
        uptime_seconds => UptimeSecs,
        otp_release => list_to_binary(erlang:system_info(otp_release)),
        node => atom_to_binary(node())
    },
    reply_ok(#{data => SystemInfo}, Req0, State);

%% === Affiliates ===

%% GET /api/v1/admin/affiliates
handle(<<"GET">>, [<<"affiliates">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, user_id, aff_code, inviter_id, rebate_rate, aff_quota, "
        "aff_history, is_frozen, created_at "
        "FROM user_affiliates ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Affiliates = [#{id => AId, user_id => UID, aff_code => Code,
                            inviter_id => Inv, rebate_rate => Rate,
                            aff_quota => Quota, aff_history => History,
                            is_frozen => Frozen, created_at => CA}
                          || {AId, UID, Code, Inv, Rate, Quota, History, Frozen, CA} <- Rows],
            reply_ok(#{data => Affiliates}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/affiliates/:id/freeze
handle(<<"POST">>, [<<"affiliates">>, IdBin, <<"freeze">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE user_affiliates SET is_frozen = TRUE WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/affiliates/:id/unfreeze
handle(<<"POST">>, [<<"affiliates">>, IdBin, <<"unfreeze">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE user_affiliates SET is_frozen = FALSE WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === Group Dispatch Config (F03) ===

%% GET /api/v1/admin/groups/:id/dispatch
handle(<<"GET">>, [<<"groups">>, IdBin, <<"dispatch">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT messages_dispatch, messages_dispatch_model_config "
        "FROM groups WHERE id = $1", [Id]
    ) of
        {ok, _, [{Dispatch, ModelConfig}]} ->
            reply_ok(#{data => #{
                messages_dispatch => Dispatch,
                messages_dispatch_model_config => decode_nullable_json(ModelConfig)
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/groups/:id/dispatch
handle(<<"PUT">>, [<<"groups">>, IdBin, <<"dispatch">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Dispatch = maps:get(<<"messages_dispatch">>, Params, null),
    ModelConfig = case maps:get(<<"messages_dispatch_model_config">>, Params, null) of
        null -> null;
        MC -> jsx:encode(MC)
    end,
    case ersub_repo:query(
        "UPDATE groups SET messages_dispatch = $2, "
        "messages_dispatch_model_config = $3 WHERE id = $1",
        [Id, Dispatch, ModelConfig]
    ) of
        {ok, 1} ->
            ersub_clips_pool:reload_rules(),
            reply_ok(#{success => true}, Req1, State);
        {ok, 0} ->
            reply_err(404, not_found, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === Account Today Stats (F04) ===

%% GET /api/v1/admin/accounts/today-stats
handle(<<"GET">>, [<<"accounts">>, <<"today-stats">>], Req0, State, _Claims) ->
    QS = cowboy_req:parse_qs(Req0),
    AccountIds = case proplists:get_value(<<"account_ids">>, QS, undefined) of
        undefined ->
            %% Return stats for all active accounts
            case ersub_repo:squery(
                "SELECT id FROM accounts WHERE status = 'active' ORDER BY id"
            ) of
                {ok, _, Rows} -> [binary_to_integer(AId) || {AId} <- Rows];
                _ -> []
            end;
        IdsBin ->
            [binary_to_integer(string:trim(I))
             || I <- binary:split(IdsBin, <<",">>, [global]),
                I =/= <<>>]
    end,
    {ok, Stats} = ersub_account_stats_cache:get_batch_stats(AccountIds),
    reply_ok(#{data => Stats}, Req0, State);

%% === Batch Redeem/Promo (F14) ===

%% POST /api/v1/admin/redeem/batch
handle(<<"POST">>, [<<"redeem">>, <<"batch">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Codes = maps:get(<<"codes">>, Params, []),
    Results = lists:map(fun(Item) ->
        Code = maps:get(<<"code">>, Item),
        Amount = maps:get(<<"amount">>, Item),
        case ersub_repo:query(
            "INSERT INTO redeem_codes (code, amount) VALUES ($1, $2) "
            "ON CONFLICT (code) DO NOTHING RETURNING id",
            [Code, Amount]
        ) of
            {ok, 1, _, [{Id}]} -> #{code => Code, id => Id, status => <<"created">>};
            {ok, 0, _, _} -> #{code => Code, status => <<"duplicate">>};
            {ok, 0} -> #{code => Code, status => <<"duplicate">>};
            {error, Reason} ->
                #{code => Code, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Codes),
    reply_ok(#{data => Results}, Req1, State);

%% POST /api/v1/admin/promo/batch
handle(<<"POST">>, [<<"promo">>, <<"batch">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Codes = maps:get(<<"codes">>, Params, []),
    Results = lists:map(fun(Item) ->
        Code = maps:get(<<"code">>, Item),
        DiscountType = maps:get(<<"discount_type">>, Item),
        DiscountValue = maps:get(<<"discount_value">>, Item),
        case ersub_repo:query(
            "INSERT INTO promo_codes (code, discount_type, discount_value) "
            "VALUES ($1, $2, $3) ON CONFLICT (code) DO NOTHING RETURNING id",
            [Code, DiscountType, DiscountValue]
        ) of
            {ok, 1, _, [{Id}]} -> #{code => Code, id => Id, status => <<"created">>};
            {ok, 0, _, _} -> #{code => Code, status => <<"duplicate">>};
            {ok, 0} -> #{code => Code, status => <<"duplicate">>};
            {error, Reason} ->
                #{code => Code, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Codes),
    reply_ok(#{data => Results}, Req1, State);

%% === Proxy CRUD (F18) ===

%% GET /api/v1/admin/proxies
handle(<<"GET">>, [<<"proxies">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, url, protocol, is_active, created_at "
        "FROM proxies ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Proxies = [#{id => PId, url => Url, protocol => Proto,
                         is_active => Active, created_at => CA}
                       || {PId, Url, Proto, Active, CA} <- Rows],
            reply_ok(#{data => Proxies}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/proxies
handle(<<"POST">>, [<<"proxies">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Url = maps:get(<<"url">>, Params),
    Protocol = maps:get(<<"protocol">>, Params, <<"http">>),
    case ersub_repo:query(
        "INSERT INTO proxies (url, protocol) VALUES ($1, $2) "
        "RETURNING id, created_at",
        [Url, Protocol]
    ) of
        {ok, 1, _, [{Id, CA}]} ->
            reply_ok(#{data => #{id => Id, url => Url, protocol => Protocol,
                                 created_at => CA}}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === T5-21: Proxy Extension ===

%% POST /api/v1/admin/proxies/batch — Batch insert proxies
handle(<<"POST">>, [<<"proxies">>, <<"batch">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Proxies = maps:get(<<"proxies">>, Params, []),
    Results = lists:map(fun(Item) ->
        Name = maps:get(<<"name">>, Item, <<"proxy">>),
        Protocol = maps:get(<<"protocol">>, Item, <<"http">>),
        Host = maps:get(<<"host">>, Item, <<>>),
        Port = maps:get(<<"port">>, Item, 0),
        case ersub_repo:query(
            "INSERT INTO proxies (name, protocol, host, port) "
            "VALUES ($1, $2, $3, $4) RETURNING id, created_at",
            [Name, Protocol, Host, Port]
        ) of
            {ok, 1, _, [{Id, CA}]} ->
                #{id => Id, name => Name, protocol => Protocol,
                  host => Host, port => Port, created_at => CA,
                  status => <<"created">>};
            {error, Reason} ->
                #{name => Name, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Proxies),
    reply_ok(#{data => Results}, Req1, State);

%% POST /api/v1/admin/proxies/batch-delete — Delete multiple proxies
handle(<<"POST">>, [<<"proxies">>, <<"batch-delete">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Ids = maps:get(<<"ids">>, Params, []),
    case Ids of
        [] ->
            reply_ok(#{success => true, deleted => 0}, Req1, State);
        _ ->
            {Placeholders, _} = lists:foldl(fun(_Id, {Acc, I}) ->
                P = iolist_to_binary([<<"$">>, integer_to_binary(I)]),
                {[P | Acc], I + 1}
            end, {[], 1}, Ids),
            InClause = iolist_to_binary(lists:join(<<", ">>, lists:reverse(Placeholders))),
            SQL = iolist_to_binary([
                "DELETE FROM proxies WHERE id IN (", InClause, ")"
            ]),
            case ersub_repo:query(SQL, Ids) of
                {ok, N} ->
                    reply_ok(#{success => true, deleted => N}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end
    end;

%% === T6-20: Proxy Extension ===

%% GET /api/v1/admin/proxies/all — List all proxies without LIMIT
handle(<<"GET">>, [<<"proxies">>, <<"all">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, url, protocol, is_active, created_at "
        "FROM proxies ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Proxies = [#{id => PId, url => Url, protocol => Proto,
                         is_active => Active, created_at => CA}
                       || {PId, Url, Proto, Active, CA} <- Rows],
            reply_ok(#{data => Proxies}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/proxies/data — Export all proxies as JSON
handle(<<"GET">>, [<<"proxies">>, <<"data">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, url, protocol, is_active, created_at "
        "FROM proxies ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => PId, url => Url, protocol => Proto,
                      is_active => Active, created_at => CA}
                    || {PId, Url, Proto, Active, CA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/proxies/data — Import proxies from JSON array
handle(<<"POST">>, [<<"proxies">>, <<"data">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ProxyList = maps:get(<<"proxies">>, Params, []),
    Results = lists:map(fun(Item) ->
        Url = maps:get(<<"url">>, Item, <<>>),
        Protocol = maps:get(<<"protocol">>, Item, <<"http">>),
        case ersub_repo:query(
            "INSERT INTO proxies (url, protocol) VALUES ($1, $2) "
            "RETURNING id, created_at",
            [Url, Protocol]
        ) of
            {ok, 1, _, [{Id, CA}]} ->
                #{id => Id, url => Url, protocol => Protocol,
                  created_at => CA, status => <<"created">>};
            {error, Reason} ->
                #{url => Url, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, ProxyList),
    reply_ok(#{data => Results}, Req1, State);

%% GET /api/v1/admin/proxies/:id — Get single proxy
handle(<<"GET">>, [<<"proxies">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, name, protocol, host, port, auth_user, is_active, "
        "last_probe_ms, last_probe_at, created_at "
        "FROM proxies WHERE id = $1", [Id])
    of
        {ok, _, [{PId, N, Proto, Host, Port, AuthUser, Active, PMs, PAt, CA}]} ->
            reply_ok(#{data => #{
                id => PId, name => N, protocol => Proto,
                host => Host, port => Port, auth_user => AuthUser,
                is_active => Active, last_probe_ms => PMs,
                last_probe_at => PAt, created_at => CA
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/proxies/:id — Update proxy
handle(<<"PUT">>, [<<"proxies">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AllFields = [
        {<<"name">>, <<"name">>},
        {<<"protocol">>, <<"protocol">>},
        {<<"host">>, <<"host">>},
        {<<"port">>, <<"port">>},
        {<<"auth_user">>, <<"auth_user">>},
        {<<"auth_pass">>, <<"auth_pass">>},
        {<<"is_active">>, <<"is_active">>}
    ],
    {SetParts, Values, _Idx} = lists:foldl(fun({JsonKey, Col}, {Sets, Vals, I}) ->
        case maps:find(JsonKey, Params) of
            {ok, Val} ->
                SetClause = iolist_to_binary([Col, " = $", integer_to_binary(I)]),
                {[SetClause | Sets], Vals ++ [Val], I + 1};
            error ->
                {Sets, Vals, I}
        end
    end, {[], [], 2}, AllFields),
    case SetParts of
        [] ->
            reply_err(400, no_fields_to_update, Req1, State);
        _ ->
            SetStr = iolist_to_binary(lists:join(<<", ">>, lists:reverse(SetParts))),
            SQL = iolist_to_binary([
                "UPDATE proxies SET ", SetStr, " WHERE id = $1"
            ]),
            case ersub_repo:query(SQL, [Id | Values]) of
                {ok, 1} -> reply_ok(#{success => true}, Req1, State);
                {ok, 0} -> reply_err(404, not_found, Req1, State);
                {error, Reason} -> reply_err(500, Reason, Req1, State)
            end
    end;

%% DELETE /api/v1/admin/proxies/:id
handle(<<"DELETE">>, [<<"proxies">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query("DELETE FROM proxies WHERE id = $1", [Id]) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/proxies/:id/test — Test proxy connectivity (T4-17)
handle(<<"POST">>, [<<"proxies">>, IdBin, <<"test">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT url, protocol FROM proxies WHERE id = $1", [Id]
    ) of
        {ok, _, [{Url, _Protocol}]} ->
            case parse_proxy_host_port(Url) of
                {ok, Host, Port} ->
                    T0 = erlang:monotonic_time(millisecond),
                    case gen_tcp:connect(Host, Port, [], 5000) of
                        {ok, Sock} ->
                            gen_tcp:close(Sock),
                            T1 = erlang:monotonic_time(millisecond),
                            LatencyMs = T1 - T0,
                            reply_ok(#{data => #{
                                proxy_id => Id,
                                status => <<"ok">>,
                                latency_ms => LatencyMs
                            }}, Req0, State);
                        {error, TcpErr} ->
                            T1 = erlang:monotonic_time(millisecond),
                            reply_ok(#{data => #{
                                proxy_id => Id,
                                status => <<"error">>,
                                latency_ms => T1 - T0,
                                error => iolist_to_binary(io_lib:format("~p", [TcpErr]))
                            }}, Req0, State)
                    end;
                {error, ParseErr} ->
                    reply_err(400, ParseErr, Req0, State)
            end;
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/proxies/:id/quality-check — Multiple ping quality check
handle(<<"POST">>, [<<"proxies">>, IdBin, <<"quality-check">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT url, protocol FROM proxies WHERE id = $1", [Id]
    ) of
        {ok, _, [{Url, _Protocol}]} ->
            case parse_proxy_host_port(Url) of
                {ok, Host, Port} ->
                    PingCount = 5,
                    Latencies = lists:filtermap(fun(_) ->
                        T0 = erlang:monotonic_time(millisecond),
                        case gen_tcp:connect(Host, Port, [], 5000) of
                            {ok, Sock} ->
                                gen_tcp:close(Sock),
                                T1 = erlang:monotonic_time(millisecond),
                                {true, T1 - T0};
                            {error, _} ->
                                false
                        end
                    end, lists:seq(1, PingCount)),
                    case Latencies of
                        [] ->
                            reply_ok(#{data => #{
                                proxy_id => Id,
                                status => <<"error">>,
                                message => <<"All pings failed">>
                            }}, Req0, State);
                        _ ->
                            Avg = lists:sum(Latencies) div length(Latencies),
                            Min = lists:min(Latencies),
                            Max = lists:max(Latencies),
                            reply_ok(#{data => #{
                                proxy_id => Id,
                                status => <<"ok">>,
                                ping_count => PingCount,
                                success_count => length(Latencies),
                                avg_latency_ms => Avg,
                                min_latency_ms => Min,
                                max_latency_ms => Max
                            }}, Req0, State)
                    end;
                {error, ParseErr} ->
                    reply_err(400, ParseErr, Req0, State)
            end;
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/proxies/:id/accounts — List accounts using this proxy
handle(<<"GET">>, [<<"proxies">>, IdBin, <<"accounts">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query("SELECT url FROM proxies WHERE id = $1", [Id]) of
        {ok, _, [{ProxyUrl}]} ->
            %% Search accounts whose credentials contain this proxy URL
            SearchPattern = iolist_to_binary([<<"%">>, ProxyUrl, <<"%">>]),
            case ersub_repo:query(
                "SELECT id, name, platform, status FROM accounts "
                "WHERE credentials::text LIKE $1 ORDER BY id",
                [SearchPattern]
            ) of
                {ok, _, Rows} ->
                    Accounts = [#{id => AId, name => Name, platform => Platform,
                                  status => Status}
                                || {AId, Name, Platform, Status} <- Rows],
                    reply_ok(#{data => Accounts}, Req0, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req0, State)
            end;
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/proxies/:id/stats — Proxy usage stats (placeholder)
handle(<<"GET">>, [<<"proxies">>, IdBin, <<"stats">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    %% Verify proxy exists
    case ersub_repo:query("SELECT id FROM proxies WHERE id = $1", [Id]) of
        {ok, _, [{_}]} ->
            reply_ok(#{data => #{proxy_id => Id, account_count => 0}}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === Account Temp-Unschedule (F21) ===

%% POST /api/v1/admin/accounts/:id/temp-unschedule
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"temp-unschedule">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_account_srv:update_status(Id, temp_unschedulable) of
        ok -> reply_ok(#{success => true}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/accounts/:id/recover
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"recover">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_account_srv:update_status(Id, active) of
        ok -> reply_ok(#{success => true}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === T6-18: Account Status Management (3-segment) ===

%% GET /api/v1/admin/accounts/:id/temp-unschedulable
handle(<<"GET">>, [<<"accounts">>, IdBin, <<"temp-unschedulable">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    try ersub_account_srv:get_stats(Id) of
        {ok, Stats} ->
            Status = maps:get(status, Stats, maps:get(<<"status">>, Stats, <<"unknown">>)),
            IsTemp = (Status =:= <<"temp_unschedulable">> orelse Status =:= temp_unschedulable),
            reply_ok(#{data => #{
                account_id => Id,
                temp_unschedulable => IsTemp,
                status => Status
            }}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    catch
        exit:{noproc, _} ->
            reply_err(404, account_not_running, Req0, State);
        exit:{timeout, _} ->
            reply_err(504, timeout, Req0, State)
    end;

%% DELETE /api/v1/admin/accounts/:id/temp-unschedulable — Clear temp-unschedulable
handle(<<"DELETE">>, [<<"accounts">>, IdBin, <<"temp-unschedulable">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_account_srv:update_status(Id, active) of
        ok -> reply_ok(#{success => true}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === Account Notes (F25) ===

%% GET /api/v1/admin/accounts/:id/notes
handle(<<"GET">>, [<<"accounts">>, IdBin, <<"notes">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT notes, extra FROM accounts WHERE id = $1", [Id]
    ) of
        {ok, _, [{Notes, Extra}]} ->
            reply_ok(#{data => #{
                notes => Notes,
                extra => decode_nullable_json(Extra)
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/accounts/:id/notes
handle(<<"PUT">>, [<<"accounts">>, IdBin, <<"notes">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Notes = maps:get(<<"notes">>, Params, null),
    Extra = case maps:get(<<"extra">>, Params, null) of
        null -> null;
        E -> jsx:encode(E)
    end,
    case ersub_repo:query(
        "UPDATE accounts SET notes = $2, extra = $3, updated_at = NOW() WHERE id = $1",
        [Id, Notes, Extra]
    ) of
        {ok, 1} ->
            reply_ok(#{success => true}, Req1, State);
        {ok, 0} ->
            reply_err(404, not_found, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === Account Batch Operations (T4-06) ===

%% POST /api/v1/admin/accounts/batch
handle(<<"POST">>, [<<"accounts">>, <<"batch">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Accounts = maps:get(<<"accounts">>, Params, []),
    Results = lists:map(fun(Item) ->
        Name = maps:get(<<"name">>, Item),
        Platform = maps:get(<<"platform">>, Item),
        Type = maps:get(<<"account_type">>, Item),
        Creds = maps:get(<<"credentials">>, Item, #{}),
        Priority = maps:get(<<"priority">>, Item, 100),
        Concurrency = maps:get(<<"concurrency">>, Item, 5),
        %% Bug #2365: Check for duplicate account by name before inserting
        case ersub_repo:query(
            "SELECT id FROM accounts WHERE name = $1 LIMIT 1", [Name]) of
            {ok, _, [{ExistingId}]} ->
                #{name => Name, status => <<"duplicate">>, id => ExistingId};
            _ ->
                Attrs = #{name => Name, platform => Platform, account_type => Type,
                          credentials => Creds, priority => Priority,
                          concurrency => Concurrency},
                case ersub_repo:create_account(Attrs) of
                    {ok, Account} ->
                        #{id => maps:get(id, Account), status => <<"created">>};
                    {error, Reason} ->
                        #{status => <<"error">>,
                          message => iolist_to_binary(io_lib:format("~p", [Reason]))}
                end
        end
    end, Accounts),
    reply_ok(#{data => Results}, Req1, State);

%% POST /api/v1/admin/accounts/batch-update
handle(<<"POST">>, [<<"accounts">>, <<"batch-update">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Updates = maps:get(<<"updates">>, Params, []),
    Results = lists:map(fun(Item) ->
        Id = maps:get(<<"id">>, Item),
        Fields = maps:without([<<"id">>], Item),
        ErlFields = maps:fold(fun(K, V, Acc) ->
            maps:put(binary_to_atom(K), V, Acc)
        end, #{}, Fields),
        case ersub_repo:update_account(Id, ErlFields) of
            {ok, 1} -> #{id => Id, status => <<"updated">>};
            {ok, 0} -> #{id => Id, status => <<"not_found">>};
            {error, Reason} ->
                #{id => Id, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Updates),
    reply_ok(#{data => Results}, Req1, State);

%% POST /api/v1/admin/accounts/batch-clear-error
handle(<<"POST">>, [<<"accounts">>, <<"batch-clear-error">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Ids = maps:get(<<"account_ids">>, Params, []),
    Results = lists:map(fun(Id) ->
        case ersub_repo:query(
            "UPDATE accounts SET status = 'active', rate_limited_until = NULL, "
            "overload_until = NULL, updated_at = NOW() WHERE id = $1", [Id]
        ) of
            {ok, 1} -> #{id => Id, status => <<"cleared">>};
            {ok, 0} -> #{id => Id, status => <<"not_found">>};
            {error, Reason} ->
                #{id => Id, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Ids),
    reply_ok(#{data => Results}, Req1, State);

%% === T6-02: Account Extended Operations ===

%% GET /api/v1/admin/accounts/data — Export all accounts as JSON
handle(<<"GET">>, [<<"accounts">>, <<"data">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, name, platform, account_type, credentials, priority, "
        "concurrency, status FROM accounts ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => AId, name => Name, platform => Platform,
                      account_type => Type, credentials => decode_nullable_json(Creds),
                      priority => Priority, concurrency => Conc, status => Status}
                    || {AId, Name, Platform, Type, Creds, Priority, Conc, Status} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/accounts/data — Import accounts from JSON array
handle(<<"POST">>, [<<"accounts">>, <<"data">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AccountList = maps:get(<<"accounts">>, Params, []),
    Results = lists:map(fun(Item) ->
        Attrs = #{
            name => maps:get(<<"name">>, Item, <<"imported">>),
            platform => maps:get(<<"platform">>, Item, <<"openai">>),
            account_type => maps:get(<<"account_type">>, Item, <<"api_key">>),
            credentials => maps:get(<<"credentials">>, Item, #{}),
            priority => maps:get(<<"priority">>, Item, 100),
            concurrency => maps:get(<<"concurrency">>, Item, 5)
        },
        case ersub_repo:create_account(Attrs) of
            {ok, Account} ->
                #{id => maps:get(id, Account), status => <<"created">>};
            {error, Reason} ->
                #{status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, AccountList),
    reply_ok(#{data => Results}, Req1, State);

%% POST /api/v1/admin/accounts/batch-refresh — Batch trigger refresh
handle(<<"POST">>, [<<"accounts">>, <<"batch-refresh">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Ids = maps:get(<<"account_ids">>, Params, []),
    Results = lists:map(fun(Id) ->
        try
            ok = ersub_token_refresh_srv:trigger_refresh(Id),
            #{id => Id, status => <<"refresh_triggered">>}
        catch
            _:Err ->
                #{id => Id, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Err]))}
        end
    end, Ids),
    reply_ok(#{data => Results}, Req1, State);

%% POST /api/v1/admin/accounts/batch-update-credentials — Batch update credentials
handle(<<"POST">>, [<<"accounts">>, <<"batch-update-credentials">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Updates = maps:get(<<"updates">>, Params, []),
    Results = lists:map(fun(Item) ->
        Id = maps:get(<<"id">>, Item),
        Creds = maps:get(<<"credentials">>, Item),
        case ersub_repo:query(
            "UPDATE accounts SET credentials = $2::jsonb, updated_at = NOW() "
            "WHERE id = $1", [Id, jsx:encode(Creds)]
        ) of
            {ok, 1} -> #{id => Id, status => <<"updated">>};
            {ok, 0} -> #{id => Id, status => <<"not_found">>};
            {error, Reason} ->
                #{id => Id, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Updates),
    reply_ok(#{data => Results}, Req1, State);

%% === Subscription Management Enhancement (T4-07) ===

%% POST /api/v1/admin/subscriptions/:id/extend
handle(<<"POST">>, [<<"subscriptions">>, IdBin, <<"extend">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Days = maps:get(<<"days">>, Params),
    case ersub_repo:query(
        "UPDATE user_subscriptions SET expires_at = COALESCE(expires_at, NOW()) "
        "+ ($2 * interval '1 day') WHERE id = $1 RETURNING id, expires_at",
        [Id, Days]
    ) of
        {ok, 1, _, [{SId, NewExpiry}]} ->
            reply_ok(#{data => #{id => SId, expires_at => NewExpiry}}, Req1, State);
        {ok, 0, _, []} ->
            reply_err(404, not_found, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% POST /api/v1/admin/subscriptions/bulk-assign
handle(<<"POST">>, [<<"subscriptions">>, <<"bulk-assign">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Assignments = maps:get(<<"assignments">>, Params, []),
    Results = lists:map(fun(Item) ->
        UserId = maps:get(<<"user_id">>, Item),
        GroupId = maps:get(<<"group_id">>, Item),
        case ersub_repo:query(
            "INSERT INTO user_subscriptions (user_id, group_id, starts_at) "
            "VALUES ($1, $2, NOW()) RETURNING id, status, created_at",
            [UserId, GroupId]
        ) of
            {ok, 1, _, [{SubId, Status, CA}]} ->
                #{id => SubId, user_id => UserId, group_id => GroupId,
                  status => Status, created_at => CA};
            {error, Reason} ->
                #{user_id => UserId, group_id => GroupId, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Assignments),
    reply_ok(#{data => Results}, Req1, State);

%% POST /api/v1/admin/subscriptions/:id/reset-quota
handle(<<"POST">>, [<<"subscriptions">>, IdBin, <<"reset-quota">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE user_subscriptions SET daily_usage_usd = 0, weekly_usage_usd = 0, "
        "monthly_usage_usd = 0 WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/subscriptions/:id/progress
handle(<<"GET">>, [<<"subscriptions">>, IdBin, <<"progress">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT s.id, s.user_id, s.group_id, s.status, s.starts_at, s.expires_at, "
        "s.daily_usage_usd, s.weekly_usage_usd, s.monthly_usage_usd, "
        "g.name AS group_name, g.billing_type, "
        "COALESCE(g.daily_limit_usd, 0) AS daily_limit, "
        "COALESCE(g.weekly_limit_usd, 0) AS weekly_limit, "
        "COALESCE(g.monthly_limit_usd, 0) AS monthly_limit "
        "FROM user_subscriptions s "
        "JOIN groups g ON g.id = s.group_id "
        "WHERE s.id = $1", [Id]
    ) of
        {ok, _, [{SId, UID, GID, Status, SA, EA, DU, WU, MU,
                   GName, BType, DL, WL, ML}]} ->
            reply_ok(#{data => #{
                id => SId, user_id => UID, group_id => GID,
                status => Status, starts_at => SA, expires_at => EA,
                daily_usage_usd => DU, weekly_usage_usd => WU,
                monthly_usage_usd => MU, group_name => GName,
                billing_type => BType,
                daily_limit_usd => DL, weekly_limit_usd => WL,
                monthly_limit_usd => ML
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/subscriptions/:id — Get single subscription (T5-25)
handle(<<"GET">>, [<<"subscriptions">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, user_id, group_id, status, starts_at, expires_at, "
        "daily_usage_usd, weekly_usage_usd, monthly_usage_usd, created_at "
        "FROM user_subscriptions WHERE id = $1", [Id]
    ) of
        {ok, _, [{SId, UID, GID, Status, SA, EA, DU, WU, MU, CA}]} ->
            reply_ok(#{data => #{
                id => SId, user_id => UID, group_id => GID,
                status => Status, starts_at => SA, expires_at => EA,
                daily_usage_usd => DU, weekly_usage_usd => WU,
                monthly_usage_usd => MU, created_at => CA
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === Account Credential Lifecycle (T4-11) ===

%% POST /api/v1/admin/accounts/:id/refresh
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"refresh">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    ok = ersub_token_refresh_srv:trigger_refresh(Id),
    reply_ok(#{success => true, message => <<"refresh_triggered">>}, Req0, State);

%% POST /api/v1/admin/accounts/:id/clear-rate-limit
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"clear-rate-limit">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE accounts SET rate_limited_until = NULL, updated_at = NOW() "
        "WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/accounts/:id/reset-quota
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"reset-quota">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE accounts SET quota_used = 0, updated_at = NOW() WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/accounts/:id/stats
handle(<<"GET">>, [<<"accounts">>, IdBin, <<"stats">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    try ersub_account_srv:get_stats(Id) of
        {ok, Stats} ->
            reply_ok(#{data => Stats}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    catch
        exit:{noproc, _} ->
            reply_err(404, account_not_running, Req0, State);
        exit:{timeout, _} ->
            reply_err(504, timeout, Req0, State)
    end;

%% === Group Management Enhancement (T4-12) ===

%% GET /api/v1/admin/groups/:id/stats
handle(<<"GET">>, [<<"groups">>, IdBin, <<"stats">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT COUNT(*) AS total_requests, "
        "COALESCE(SUM(actual_cost), 0) AS total_cost, "
        "COALESCE(SUM(input_tokens), 0) AS total_input_tokens, "
        "COALESCE(SUM(output_tokens), 0) AS total_output_tokens, "
        "COALESCE(AVG(duration_ms), 0) AS avg_latency_ms "
        "FROM usage_logs WHERE group_id = $1", [Id]
    ) of
        {ok, _, [{TotalReqs, TotalCost, InputTokens, OutputTokens, AvgLatency}]} ->
            reply_ok(#{data => #{
                group_id => Id,
                total_requests => TotalReqs,
                total_cost => TotalCost,
                total_input_tokens => InputTokens,
                total_output_tokens => OutputTokens,
                avg_latency_ms => AvgLatency
            }}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/groups/sort-order
handle(<<"PUT">>, [<<"groups">>, <<"sort-order">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Order = maps:get(<<"order">>, Params, []),
    Results = lists:map(fun(Item) ->
        Id = maps:get(<<"id">>, Item),
        SortOrder = maps:get(<<"sort_order">>, Item),
        case ersub_repo:query(
            "UPDATE groups SET sort_order = $2 WHERE id = $1", [Id, SortOrder]
        ) of
            {ok, 1} -> #{id => Id, status => <<"updated">>};
            {ok, 0} -> #{id => Id, status => <<"not_found">>};
            {error, Reason} ->
                #{id => Id, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Order),
    reply_ok(#{data => Results}, Req1, State);

%% GET /api/v1/admin/groups/all — List ALL groups including inactive
handle(<<"GET">>, [<<"groups">>, <<"all">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, name, platform, rate_multiplier, billing_type, created_at "
        "FROM groups ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Groups = [#{id => GId, name => GName, platform => GPlatform,
                        rate_multiplier => RM, billing_type => BT,
                        created_at => CA}
                      || {GId, GName, GPlatform, RM, BT, CA} <- Rows],
            reply_ok(#{data => Groups}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/groups/usage-summary — Aggregate usage per group (24h)
handle(<<"GET">>, [<<"groups">>, <<"usage-summary">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT g.id, g.name, COUNT(ul.id) as requests, "
        "COALESCE(SUM(ul.actual_cost::numeric),0) as cost "
        "FROM groups g "
        "LEFT JOIN account_groups ag ON ag.group_id = g.id "
        "LEFT JOIN usage_logs ul ON ul.account_id = ag.account_id "
        "AND ul.created_at > NOW() - INTERVAL '24 hours' "
        "GROUP BY g.id, g.name ORDER BY requests DESC"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => GId, name => GName,
                      requests => binary_to_integer(Req),
                      cost => Co}
                    || {GId, GName, Req, Co} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/groups/capacity-summary
handle(<<"GET">>, [<<"groups">>, <<"capacity-summary">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT g.id, g.name, g.platform, "
        "COUNT(DISTINCT ag.account_id) FILTER (WHERE a.status = 'active') AS active_accounts, "
        "COUNT(DISTINCT us.id) FILTER (WHERE us.status = 'active') AS active_subscriptions "
        "FROM groups g "
        "LEFT JOIN account_groups ag ON ag.group_id = g.id "
        "LEFT JOIN accounts a ON a.id = ag.account_id "
        "LEFT JOIN user_subscriptions us ON us.group_id = g.id "
        "GROUP BY g.id, g.name, g.platform "
        "ORDER BY g.sort_order ASC, g.id ASC"
    ) of
        {ok, _, Rows} ->
            Groups = [#{id => GId, name => GName, platform => GPlatform,
                        active_accounts => binary_to_integer(AC),
                        active_subscriptions => binary_to_integer(AS)}
                      || {GId, GName, GPlatform, AC, AS} <- Rows],
            reply_ok(#{data => Groups}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/groups/:id/rate-multipliers
handle(<<"PUT">>, [<<"groups">>, IdBin, <<"rate-multipliers">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    InputMult = maps:get(<<"input_multiplier">>, Params),
    OutputMult = maps:get(<<"output_multiplier">>, Params),
    case ersub_repo:query(
        "UPDATE groups SET input_multiplier = $2, output_multiplier = $3 "
        "WHERE id = $1", [Id, InputMult, OutputMult]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req1, State);
        {ok, 0} -> reply_err(404, not_found, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% === T4-15: User Attributes Definition Management ===

%% GET /api/v1/admin/user-attributes
handle(<<"GET">>, [<<"user-attributes">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, name, data_type, is_required, created_at "
        "FROM user_attribute_definitions ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => Id, name => N, data_type => DT,
                      is_required => IR, created_at => CA}
                    || {Id, N, DT, IR, CA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/user-attributes
handle(<<"POST">>, [<<"user-attributes">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Name = maps:get(<<"name">>, Params),
    DataType = maps:get(<<"data_type">>, Params),
    IsRequired = maps:get(<<"is_required">>, Params, false),
    case ersub_repo:query(
        "INSERT INTO user_attribute_definitions (name, data_type, is_required) "
        "VALUES ($1, $2, $3) RETURNING id",
        [Name, DataType, IsRequired]
    ) of
        {ok, 1, _, [{Id}]} ->
            reply_ok(#{data => #{id => Id}}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% POST /api/v1/admin/user-attributes/batch — Batch query user attributes
handle(<<"POST">>, [<<"user-attributes">>, <<"batch">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    UserIds = maps:get(<<"user_ids">>, P, []),
    Data = lists:foldl(fun(UID, Acc) ->
        UIdInt = case is_integer(UID) of true -> UID; false -> binary_to_integer(UID) end,
        case ersub_repo:query(
            "SELECT uav.attribute_id, uad.name, uav.value "
            "FROM user_attribute_values uav "
            "JOIN user_attribute_definitions uad ON uad.id = uav.attribute_id "
            "WHERE uav.user_id = $1", [UIdInt]) of
            {ok, _, Rows} ->
                Attrs = [#{attribute_id => AId, name => N, value => V}
                         || {AId, N, V} <- Rows],
                Acc#{integer_to_binary(UIdInt) => Attrs};
            _ ->
                Acc#{integer_to_binary(UIdInt) => []}
        end
    end, #{}, UserIds),
    reply_ok(#{data => Data}, Req1, State);

%% PUT /api/v1/admin/user-attributes/reorder (placeholder)
handle(<<"PUT">>, [<<"user-attributes">>, <<"reorder">>], Req0, State, _Claims) ->
    {ok, _Body, Req1} = cowboy_req:read_body(Req0),
    reply_ok(#{success => true}, Req1, State);

%% PUT /api/v1/admin/user-attributes/:id
handle(<<"PUT">>, [<<"user-attributes">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "UPDATE user_attribute_definitions SET "
        "name = COALESCE($2, name), "
        "data_type = COALESCE($3, data_type), "
        "is_required = COALESCE($4, is_required) "
        "WHERE id = $1",
        [Id, maps:get(<<"name">>, Params, null),
         maps:get(<<"data_type">>, Params, null),
         maps:get(<<"is_required">>, Params, null)]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req1, State);
        {ok, 0} -> reply_err(404, not_found, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% DELETE /api/v1/admin/user-attributes/:id
handle(<<"DELETE">>, [<<"user-attributes">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "DELETE FROM user_attribute_definitions WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === T5-26: Affiliate Admin Extension ===

%% GET /api/v1/admin/affiliates/users — List users with affiliate data
handle(<<"GET">>, [<<"affiliates">>, <<"users">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT ua.id, ua.user_id, ua.aff_code, ua.inviter_id, ua.rebate_rate, "
        "ua.aff_quota, ua.aff_history, ua.is_frozen, ua.custom_settings, "
        "ua.created_at, u.email "
        "FROM user_affiliates ua "
        "JOIN users u ON u.id = ua.user_id "
        "ORDER BY ua.id LIMIT 100"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => AId, user_id => UID, aff_code => Code,
                      inviter_id => Inv, rebate_rate => Rate,
                      aff_quota => Quota, aff_history => History,
                      is_frozen => Frozen,
                      custom_settings => decode_nullable_json(CS),
                      created_at => CA, email => Email}
                    || {AId, UID, Code, Inv, Rate, Quota, History,
                        Frozen, CS, CA, Email} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/affiliates/users/lookup?email=xxx — Search affiliate by email
handle(<<"GET">>, [<<"affiliates">>, <<"users">>, <<"lookup">>], Req0, State, _Claims) ->
    #{email := EmailVal} = cowboy_req:match_qs([{email, [], <<>>}], Req0),
    case ersub_repo:query(
        "SELECT ua.id, ua.user_id, ua.aff_code, ua.inviter_id, ua.rebate_rate, "
        "ua.aff_quota, ua.aff_history, ua.is_frozen, ua.created_at, u.email "
        "FROM user_affiliates ua "
        "JOIN users u ON u.id = ua.user_id "
        "WHERE u.email ILIKE $1 "
        "LIMIT 20",
        [<<"%", EmailVal/binary, "%">>]) of
        {ok, _, Rows} ->
            Data = [#{id => AId, user_id => UID, aff_code => Code,
                      inviter_id => Inv, rebate_rate => Rate,
                      aff_quota => Quota, aff_history => History,
                      is_frozen => Frozen, created_at => CA, email => E}
                    || {AId, UID, Code, Inv, Rate, Quota, History,
                        Frozen, CA, E} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/affiliates/users/:id/overview — Affiliate overview for user
handle(<<"GET">>, [<<"affiliates">>, <<"users">>, IdBin, <<"overview">>], Req0, State, _Claims) ->
    UserId = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT ua.id, ua.aff_code, ua.rebate_rate, ua.aff_quota, ua.aff_history, "
        "ua.is_frozen, u.email "
        "FROM user_affiliates ua "
        "JOIN users u ON u.id = ua.user_id "
        "WHERE ua.user_id = $1", [UserId]
    ) of
        {ok, _, [{AId, Code, Rate, Quota, History, Frozen, Email}]} ->
            %% Aggregate ledger stats
            {ok, _, [{InviteCount}]} = ersub_repo:query(
                "SELECT COUNT(*) FROM user_affiliate_ledger "
                "WHERE user_id = $1 AND action = 'invite'", [UserId]),
            {ok, _, [{RebateTotal}]} = ersub_repo:query(
                "SELECT COALESCE(SUM(amount), 0) FROM user_affiliate_ledger "
                "WHERE user_id = $1 AND action = 'rebate'", [UserId]),
            {ok, _, [{TransferTotal}]} = ersub_repo:query(
                "SELECT COALESCE(SUM(amount), 0) FROM user_affiliate_ledger "
                "WHERE user_id = $1 AND action = 'transfer'", [UserId]),
            reply_ok(#{data => #{
                id => AId, user_id => UserId, email => Email,
                aff_code => Code, rebate_rate => Rate,
                aff_quota => Quota, aff_history => History,
                is_frozen => Frozen,
                total_invites => InviteCount,
                total_rebates => RebateTotal,
                total_transfers => TransferTotal
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/affiliates/users/:id — Update affiliate settings
handle(<<"PUT">>, [<<"affiliates">>, <<"users">>, IdBin], Req0, State, _Claims) ->
    UserId = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AllFields = [
        {<<"rebate_rate">>, <<"rebate_rate">>, plain},
        {<<"is_frozen">>, <<"is_frozen">>, plain},
        {<<"custom_settings">>, <<"custom_settings">>, jsonb}
    ],
    {SetParts, Values, _Idx} = lists:foldl(fun({JsonKey, Col, Type}, {Sets, Vals, I}) ->
        case maps:find(JsonKey, Params) of
            {ok, Val} ->
                EncodedVal = case Type of
                    jsonb -> encode_nullable_json(Val);
                    _ -> Val
                end,
                SetClause = iolist_to_binary([Col, " = $", integer_to_binary(I)]),
                {[SetClause | Sets], Vals ++ [EncodedVal], I + 1};
            error ->
                {Sets, Vals, I}
        end
    end, {[], [], 2}, AllFields),
    case SetParts of
        [] ->
            reply_err(400, no_fields_to_update, Req1, State);
        _ ->
            SetStr = iolist_to_binary(lists:join(<<", ">>, lists:reverse(SetParts))),
            SQL = iolist_to_binary([
                "UPDATE user_affiliates SET ", SetStr, " WHERE user_id = $1"
            ]),
            case ersub_repo:query(SQL, [UserId | Values]) of
                {ok, 1} -> reply_ok(#{success => true}, Req1, State);
                {ok, 0} -> reply_err(404, not_found, Req1, State);
                {error, Reason} -> reply_err(500, Reason, Req1, State)
            end
    end;

%% DELETE /api/v1/admin/affiliates/users/:id — Delete affiliate record
handle(<<"DELETE">>, [<<"affiliates">>, <<"users">>, IdBin], Req0, State, _Claims) ->
    UserId = binary_to_integer(IdBin),
    case ersub_repo:query(
        "DELETE FROM user_affiliates WHERE user_id = $1", [UserId]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === T4-16: Affiliate Management Enhancement ===

%% GET /api/v1/admin/affiliates/invites
handle(<<"GET">>, [<<"affiliates">>, <<"invites">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, user_id, action, amount, ref_user_id, note, created_at "
        "FROM user_affiliate_ledger WHERE action = 'invite' "
        "ORDER BY created_at DESC"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => Id, user_id => UID, action => Act,
                      amount => Amt, ref_user_id => RefUID,
                      note => Note, created_at => CA}
                    || {Id, UID, Act, Amt, RefUID, Note, CA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/affiliates/rebates
handle(<<"GET">>, [<<"affiliates">>, <<"rebates">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, user_id, action, amount, ref_user_id, note, created_at "
        "FROM user_affiliate_ledger WHERE action = 'rebate' "
        "ORDER BY created_at DESC"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => Id, user_id => UID, action => Act,
                      amount => Amt, ref_user_id => RefUID,
                      note => Note, created_at => CA}
                    || {Id, UID, Act, Amt, RefUID, Note, CA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/affiliates/transfers
handle(<<"GET">>, [<<"affiliates">>, <<"transfers">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, user_id, action, amount, ref_user_id, note, created_at "
        "FROM user_affiliate_ledger WHERE action = 'transfer' "
        "ORDER BY created_at DESC"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => Id, user_id => UID, action => Act,
                      amount => Amt, ref_user_id => RefUID,
                      note => Note, created_at => CA}
                    || {Id, UID, Act, Amt, RefUID, Note, CA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/affiliates/batch-rate
handle(<<"POST">>, [<<"affiliates">>, <<"batch-rate">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Updates = maps:get(<<"updates">>, Params, []),
    Results = lists:map(fun(Item) ->
        UserId = maps:get(<<"user_id">>, Item),
        RebateRate = maps:get(<<"rebate_rate">>, Item),
        case ersub_repo:query(
            "UPDATE user_affiliates SET rebate_rate = $2 WHERE user_id = $1",
            [UserId, RebateRate]
        ) of
            {ok, 1} -> #{user_id => UserId, status => <<"updated">>};
            {ok, 0} -> #{user_id => UserId, status => <<"not_found">>};
            {error, Reason} ->
                #{user_id => UserId, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Updates),
    reply_ok(#{data => Results}, Req1, State);

%% === Codex Session Import (T4-25) ===

%% POST /api/v1/admin/accounts/import/codex-session
handle(<<"POST">>, [<<"accounts">>, <<"import">>, <<"codex-session">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    SessionToken = maps:get(<<"session_token">>, Params),
    Name = maps:get(<<"name">>, Params, <<"Codex Import">>),
    Attrs = #{
        name => Name,
        platform => <<"openai">>,
        account_type => <<"oauth">>,
        credentials => #{<<"session_token">> => SessionToken, <<"source">> => <<"codex_import">>},
        priority => 100,
        concurrency => 5
    },
    case ersub_repo:create_account(Attrs) of
        {ok, Account} ->
            _ = case ersub_repo:get_account(maps:get(id, Account)) of
                {ok, FullAcc} -> ersub_platform_sup:start_account(FullAcc);
                _ -> ok
            end,
            reply_ok(#{data => Account}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === T5-19: Account OAuth Management (Claude) ===

%% POST /api/v1/admin/accounts/generate-auth-url
handle(<<"POST">>, [<<"accounts">>, <<"generate-auth-url">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ClientId = ersub_config_srv:get(anthropic_oauth_client_id, <<>>),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    Url = iolist_to_binary([
        <<"https://console.anthropic.com/oauth/authorize">>,
        <<"?client_id=">>, uri_string:quote(ClientId),
        <<"&redirect_uri=">>, uri_string:quote(RedirectUri),
        <<"&response_type=code">>,
        <<"&scope=org:create_api_key">>
    ]),
    reply_ok(#{data => #{url => Url, client_id => ClientId}}, Req1, State);

%% POST /api/v1/admin/accounts/exchange-code
handle(<<"POST">>, [<<"accounts">>, <<"exchange-code">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Code = maps:get(<<"code">>, Params),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    ClientId = ersub_config_srv:get(anthropic_oauth_client_id, <<>>),
    ClientSecret = ersub_config_srv:get(anthropic_oauth_client_secret, <<>>),
    PostBody = jsx:encode(#{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => ClientId,
        <<"client_secret">> => ClientSecret,
        <<"code">> => Code,
        <<"redirect_uri">> => RedirectUri
    }),
    case exchange_oauth_token(PostBody) of
        {ok, TokenData} ->
            ApiKey = maps:get(<<"access_token">>, TokenData, <<>>),
            Attrs = #{
                name => <<"Claude OAuth Account">>,
                platform => <<"claude">>,
                account_type => <<"oauth">>,
                credentials => #{<<"api_key">> => ApiKey, <<"source">> => <<"oauth">>,
                                  <<"token_data">> => TokenData},
                priority => 100,
                concurrency => 5
            },
            case ersub_repo:create_account(Attrs) of
                {ok, Account} ->
                    _ = case ersub_repo:get_account(maps:get(id, Account)) of
                        {ok, FullAcc} -> ersub_platform_sup:start_account(FullAcc);
                        _ -> ok
                    end,
                    reply_ok(#{data => Account}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end;
        {error, Reason} ->
            reply_err(502, Reason, Req1, State)
    end;

%% POST /api/v1/admin/accounts/cookie-auth
handle(<<"POST">>, [<<"accounts">>, <<"cookie-auth">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    SessionKey = maps:get(<<"session_key">>, Params),
    Attrs = #{
        name => <<"Claude Cookie Auth">>,
        platform => <<"claude">>,
        account_type => <<"oauth">>,
        credentials => #{<<"session_key">> => SessionKey, <<"source">> => <<"cookie_auth">>},
        priority => 100,
        concurrency => 5
    },
    case ersub_repo:create_account(Attrs) of
        {ok, Account} ->
            _ = case ersub_repo:get_account(maps:get(id, Account)) of
                {ok, FullAcc} -> ersub_platform_sup:start_account(FullAcc);
                _ -> ok
            end,
            reply_ok(#{data => Account}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === T4-23: System Version Info ===

%% GET /api/v1/admin/system/version
handle(<<"GET">>, [<<"system">>, <<"version">>], Req0, State, _Claims) ->
    VersionInfo = #{
        app_version => <<"0.4.0">>,
        otp_release => list_to_binary(erlang:system_info(otp_release)),
        erts_version => list_to_binary(erlang:system_info(version)),
        clips_pool_size => ersub_config_srv:get(clips_pool_size, 8),
        uptime_seconds => element(1, erlang:statistics(wall_clock)) div 1000,
        node => atom_to_binary(node())
    },
    reply_ok(#{data => VersionInfo}, Req0, State);

%% GET /api/v1/admin/system/check-updates — Check for available updates
handle(<<"GET">>, [<<"system">>, <<"check-updates">>], Req0, State, _Claims) ->
    CurrentVersion = <<"0.4.0">>,
    %% Check GitHub releases API for latest version
    CheckUrl = ersub_config_srv:get(system_update_url,
        <<"https://api.github.com/repos/ersub/ersub/releases/latest">>),
    Result = try
        case ersub_upstream_pool:request(
            <<"GET">>, CheckUrl,
            [{<<"accept">>, <<"application/json">>},
             {<<"user-agent">>, <<"ersub/", CurrentVersion/binary>>}],
            <<>>, #{}, 10000
        ) of
            {ok, 200, _, RespBody} ->
                Release = jsx:decode(RespBody, [return_maps]),
                LatestVersion = maps:get(<<"tag_name">>, Release, CurrentVersion),
                #{
                    current_version => CurrentVersion,
                    latest_version => LatestVersion,
                    update_available => (LatestVersion =/= CurrentVersion),
                    release_url => maps:get(<<"html_url">>, Release, <<>>),
                    published_at => maps:get(<<"published_at">>, Release, <<>>)
                };
            {ok, Status, _, _} ->
                #{current_version => CurrentVersion,
                  update_available => false,
                  check_error => iolist_to_binary([<<"HTTP ">>, integer_to_binary(Status)])};
            {error, Reason} ->
                #{current_version => CurrentVersion,
                  update_available => false,
                  check_error => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    catch _:Err ->
        #{current_version => CurrentVersion,
          update_available => false,
          check_error => iolist_to_binary(io_lib:format("~p", [Err]))}
    end,
    reply_ok(#{data => Result}, Req0, State);

%% POST /api/v1/admin/system/restart — Restart the application
handle(<<"POST">>, [<<"system">>, <<"restart">>], Req0, State, _Claims) ->
    %% Schedule restart after response is sent (1 second delay)
    spawn(fun() ->
        timer:sleep(1000),
        logger:info("System restart requested by admin"),
        init:restart()
    end),
    reply_ok(#{success => true, message => <<"Restart scheduled in 1 second">>}, Req0, State);

%% POST /api/v1/admin/system/rollback — Rollback to previous release
handle(<<"POST">>, [<<"system">>, <<"rollback">>], Req0, State, _Claims) ->
    %% Erlang/OTP release handler rollback
    Result = try
        case release_handler:which_releases() of
            Releases when is_list(Releases) ->
                %% Find the previous permanent release
                OldReleases = [Vsn || {_Name, Vsn, _Apps, Status} <- Releases,
                                      Status =:= old],
                case OldReleases of
                    [PrevVsn | _] ->
                        case release_handler:reboot_old_release(PrevVsn) of
                            ok ->
                                #{success => true,
                                  message => <<"Rolling back to version ",
                                               (list_to_binary(PrevVsn))/binary>>};
                            {error, Reason} ->
                                #{success => false,
                                  error => iolist_to_binary(io_lib:format("~p", [Reason]))}
                        end;
                    [] ->
                        #{success => false,
                          error => <<"No previous release available for rollback">>}
                end
        end
    catch _:Err ->
        #{success => false,
          error => iolist_to_binary(io_lib:format("~p", [Err]))}
    end,
    reply_ok(#{data => Result}, Req0, State);

%% POST /api/v1/admin/system/update — Trigger hot code reload
handle(<<"POST">>, [<<"system">>, <<"update">>], Req0, State, _Claims) ->
    %% Reload all changed modules (Erlang hot code upgrade)
    ChangedModules = [M || {M, Loaded} <- code:all_loaded(),
                           is_list(Loaded),
                           is_list(code:which(M)),
                           beam_modified(M, Loaded)],
    Results = lists:map(fun(Mod) ->
        case code:purge(Mod) of
            true -> ok;
            false -> ok
        end,
        case code:load_file(Mod) of
            {module, Mod} -> #{module => Mod, status => <<"reloaded">>};
            {error, Reason} -> #{module => Mod, status => <<"error">>,
                                  error => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, ChangedModules),
    %% Also reload CLIPS rules
    ersub_clips_pool:reload_rules(),
    ersub_clips_config:reload(),
    reply_ok(#{data => #{
        reloaded_modules => length(ChangedModules),
        modules => Results,
        clips_reloaded => true
    }}, Req0, State);

%% === Channels (T5-05) ===

%% GET /api/v1/admin/channels — List all channels
handle(<<"GET">>, [<<"channels">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, name, group_id, platform, base_url, model_mapping, "
        "pricing_override, is_active, created_at "
        "FROM channels ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Channels = [#{id => Id, name => Name, group_id => GId,
                          platform => P, base_url => BUrl,
                          model_mapping => decode_nullable_json(MM),
                          pricing_override => decode_nullable_json(PO),
                          is_active => IA, created_at => CA}
                        || {Id, Name, GId, P, BUrl, MM, PO, IA, CA} <- Rows],
            reply_ok(#{data => Channels}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/channels/model-pricing — Default model pricing
handle(<<"GET">>, [<<"channels">>, <<"model-pricing">>], Req0, State, _Claims) ->
    Pricing = ersub_pricing_srv:get_all(),
    reply_ok(#{data => Pricing}, Req0, State);

%% POST /api/v1/admin/channels — Create channel
handle(<<"POST">>, [<<"channels">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Name = maps:get(<<"name">>, Params),
    GroupId = maps:get(<<"group_id">>, Params),
    Platform = maps:get(<<"platform">>, Params),
    BaseUrl = maps:get(<<"base_url">>, Params),
    ModelMapping = encode_nullable_json(maps:get(<<"model_mapping">>, Params, null)),
    PricingOverride = encode_nullable_json(maps:get(<<"pricing_override">>, Params, null)),
    AllowedModels = encode_nullable_json(maps:get(<<"allowed_models">>, Params, null)),
    case ersub_repo:query(
        "INSERT INTO channels (name, group_id, platform, base_url, "
        "model_mapping, pricing_override, allowed_models) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7) "
        "RETURNING id, is_active, created_at",
        [Name, GroupId, Platform, BaseUrl, ModelMapping, PricingOverride, AllowedModels]
    ) of
        {ok, 1, _, [{Id, IsActive, CreatedAt}]} ->
            reply_ok(#{data => #{
                id => Id, name => Name, group_id => GroupId,
                platform => Platform, base_url => BaseUrl,
                model_mapping => decode_nullable_json(ModelMapping),
                pricing_override => decode_nullable_json(PricingOverride),
                allowed_models => decode_nullable_json(AllowedModels),
                is_active => IsActive, created_at => CreatedAt
            }}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% GET /api/v1/admin/channels/:id — Get single channel
handle(<<"GET">>, [<<"channels">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, name, group_id, platform, base_url, model_mapping, "
        "pricing_override, allowed_models, is_active, created_at "
        "FROM channels WHERE id = $1",
        [Id]
    ) of
        {ok, _, [{CId, Name, GId, P, BUrl, MM, PO, AM, IA, CA}]} ->
            reply_ok(#{data => #{
                id => CId, name => Name, group_id => GId,
                platform => P, base_url => BUrl,
                model_mapping => decode_nullable_json(MM),
                pricing_override => decode_nullable_json(PO),
                allowed_models => decode_nullable_json(AM),
                is_active => IA, created_at => CA
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/channels/:id — Update channel
handle(<<"PUT">>, [<<"channels">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    %% Build dynamic SET clause from provided fields
    AllFields = [
        {<<"name">>, <<"name">>, text},
        {<<"group_id">>, <<"group_id">>, int},
        {<<"platform">>, <<"platform">>, text},
        {<<"base_url">>, <<"base_url">>, text},
        {<<"model_mapping">>, <<"model_mapping">>, jsonb},
        {<<"pricing_override">>, <<"pricing_override">>, jsonb},
        {<<"allowed_models">>, <<"allowed_models">>, jsonb},
        {<<"is_active">>, <<"is_active">>, bool}
    ],
    {SetParts, Values, _Idx} = lists:foldl(fun({JsonKey, Col, Type}, {Sets, Vals, I}) ->
        case maps:find(JsonKey, Params) of
            {ok, Val} ->
                EncodedVal = case Type of
                    jsonb -> encode_nullable_json(Val);
                    _ -> Val
                end,
                SetClause = iolist_to_binary([Col, " = $", integer_to_binary(I)]),
                {[SetClause | Sets], Vals ++ [EncodedVal], I + 1};
            error ->
                {Sets, Vals, I}
        end
    end, {[], [], 2}, AllFields),
    case SetParts of
        [] ->
            reply_err(400, no_fields_to_update, Req1, State);
        _ ->
            SetStr = iolist_to_binary(lists:join(<<", ">>, lists:reverse(SetParts))),
            SQL = iolist_to_binary([
                "UPDATE channels SET ", SetStr,
                ", updated_at = NOW() WHERE id = $1"
            ]),
            case ersub_repo:query(SQL, [Id | Values]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req1, State);
                {ok, 0} ->
                    reply_err(404, not_found, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end
    end;

%% DELETE /api/v1/admin/channels/:id — Delete channel
handle(<<"DELETE">>, [<<"channels">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query("DELETE FROM channels WHERE id = $1", [Id]) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === T6-01: Admin User Extended Operations ===

%% POST /api/v1/admin/users/batch-concurrency — Batch update max_concurrency
handle(<<"POST">>, [<<"users">>, <<"batch-concurrency">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Updates = maps:get(<<"updates">>, Params, []),
    Results = lists:map(fun(Item) ->
        UserId = maps:get(<<"user_id">>, Item),
        MaxConc = maps:get(<<"max_concurrency">>, Item),
        case ersub_repo:query(
            "UPDATE users SET max_concurrency = $2 WHERE id = $1", [UserId, MaxConc]
        ) of
            {ok, 1} -> #{user_id => UserId, status => <<"updated">>};
            {ok, 0} -> #{user_id => UserId, status => <<"not_found">>};
            {error, Reason} ->
                #{user_id => UserId, status => <<"error">>,
                  message => iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    end, Updates),
    reply_ok(#{data => Results}, Req1, State);

%% === T5-01: Admin User Detail Management ===

%% GET /api/v1/admin/users/:id
handle(<<"GET">>, [<<"users">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, email, role, balance_usd, max_concurrency, is_banned, "
        "signup_source, last_login_at, created_at "
        "FROM users WHERE id = $1 AND deleted_at IS NULL", [Id]
    ) of
        {ok, _, [{UId, Email, Role, Balance, MaxConc, IsBanned,
                  SignupSrc, LastLogin, CreatedAt}]} ->
            reply_ok(#{data => #{
                id => UId, email => Email, role => Role,
                balance_usd => Balance, max_concurrency => MaxConc,
                is_banned => IsBanned, signup_source => SignupSrc,
                last_login_at => LastLogin, created_at => CreatedAt
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/users/:id
handle(<<"PUT">>, [<<"users">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AllowedFields = [<<"role">>, <<"max_concurrency">>, <<"is_banned">>, <<"email">>],
    Fields = maps:fold(fun(K, V, Acc) ->
        case lists:member(K, AllowedFields) of
            true -> maps:put(binary_to_atom(K), V, Acc);
            false -> Acc
        end
    end, #{}, Params),
    case maps:size(Fields) of
        0 ->
            reply_err(400, no_fields_provided, Req1, State);
        _ ->
            case ersub_repo:update_user(Id, Fields) of
                {ok, 1} -> reply_ok(#{success => true}, Req1, State);
                {ok, 0} -> reply_err(404, not_found, Req1, State);
                {error, Reason} -> reply_err(500, Reason, Req1, State)
            end
    end;

%% DELETE /api/v1/admin/users/:id
handle(<<"DELETE">>, [<<"users">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE users SET deleted_at = NOW() WHERE id = $1 AND deleted_at IS NULL", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === T5-02: Admin User Balance + Keys + Usage + History ===

%% POST /api/v1/admin/users/:id/balance
handle(<<"POST">>, [<<"users">>, IdBin, <<"balance">>], Req0, State, Claims) ->
    Id = binary_to_integer(IdBin),
    AdminId = maps:get(<<"user_id">>, Claims, null),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Amount = maps:get(<<"amount">>, Params),
    Note = maps:get(<<"note">>, Params, null),
    case ersub_repo:query(
        "UPDATE users SET balance_usd = balance_usd + $2, updated_at = NOW() "
        "WHERE id = $1 AND deleted_at IS NULL RETURNING balance_usd", [Id, Amount]
    ) of
        {ok, 1, _, [{NewBalance}]} ->
            _ = ersub_repo:query(
                "INSERT INTO balance_history "
                "(user_id, amount, balance_after, action, note, admin_id) "
                "VALUES ($1, $2, $3, $4, $5, $6)",
                [Id, Amount, NewBalance, <<"admin_adjust">>, Note, AdminId]
            ),
            reply_ok(#{data => #{user_id => Id, balance_usd => NewBalance}}, Req1, State);
        {ok, 0, _, []} ->
            reply_err(404, not_found, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% GET /api/v1/admin/users/:id/api-keys
handle(<<"GET">>, [<<"users">>, IdBin, <<"api-keys">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, key_prefix, name, is_active, created_at "
        "FROM api_keys WHERE user_id = $1 AND deleted_at IS NULL", [Id]
    ) of
        {ok, _, Rows} ->
            Keys = [#{id => KId, key_prefix => KP, name => N,
                      is_active => A, created_at => CA}
                    || {KId, KP, N, A, CA} <- Rows],
            reply_ok(#{data => Keys}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/users/:id/usage
handle(<<"GET">>, [<<"users">>, IdBin, <<"usage">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, request_id, requested_model, input_tokens, output_tokens, "
        "actual_cost, created_at FROM usage_logs WHERE user_id = $1 "
        "ORDER BY created_at DESC LIMIT 100", [Id]
    ) of
        {ok, _, Rows} ->
            Logs = [#{id => LId, request_id => RId, requested_model => M,
                      input_tokens => IT, output_tokens => OT,
                      actual_cost => C, created_at => CA}
                    || {LId, RId, M, IT, OT, C, CA} <- Rows],
            reply_ok(#{data => Logs}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/users/:id/balance-history
handle(<<"GET">>, [<<"users">>, IdBin, <<"balance-history">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, amount, balance_after, action, note, admin_id, created_at "
        "FROM balance_history WHERE user_id = $1 "
        "ORDER BY created_at DESC LIMIT 100", [Id]
    ) of
        {ok, _, Rows} ->
            History = [#{id => HId, amount => Amt, balance_after => BA,
                         action => Act, note => N, admin_id => AId,
                         created_at => CA}
                       || {HId, Amt, BA, Act, N, AId, CA} <- Rows],
            reply_ok(#{data => History}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/users/:id/subscriptions — List user subscriptions (T5-25)
handle(<<"GET">>, [<<"users">>, IdBin, <<"subscriptions">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT s.id, s.user_id, s.group_id, s.status, s.starts_at, s.expires_at, "
        "s.daily_usage_usd, s.weekly_usage_usd, s.monthly_usage_usd, "
        "s.created_at, g.name AS group_name "
        "FROM user_subscriptions s "
        "JOIN groups g ON g.id = s.group_id "
        "WHERE s.user_id = $1 ORDER BY s.id", [Id]
    ) of
        {ok, _, Rows} ->
            Subs = [#{id => SId, user_id => UID, group_id => GID,
                       status => St, starts_at => SA, expires_at => EA,
                       daily_usage_usd => DU, weekly_usage_usd => WU,
                       monthly_usage_usd => MU, created_at => CA,
                       group_name => GName}
                    || {SId, UID, GID, St, SA, EA, DU, WU, MU, CA, GName} <- Rows],
            reply_ok(#{data => Subs}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === T6-01: User Extended Operations (3-segment) ===

%% POST /api/v1/admin/users/:id/replace-group — Replace user allowed group
handle(<<"POST">>, [<<"users">>, IdBin, <<"replace-group">>], Req0, State, _Claims) ->
    UserId = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    GroupId = maps:get(<<"group_id">>, Params),
    %% Delete existing allowed groups for this user, then insert new one
    _ = ersub_repo:query(
        "DELETE FROM user_allowed_groups WHERE user_id = $1", [UserId]),
    case ersub_repo:query(
        "INSERT INTO user_allowed_groups (user_id, group_id) VALUES ($1, $2)",
        [UserId, GroupId]
    ) of
        {ok, 1} ->
            reply_ok(#{success => true, user_id => UserId, group_id => GroupId}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% GET /api/v1/admin/users/:id/rpm-status — Get user RPM status
handle(<<"GET">>, [<<"users">>, IdBin, <<"rpm-status">>], Req0, State, _Claims) ->
    UserId = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT rpm_limit FROM users WHERE id = $1 AND deleted_at IS NULL", [UserId]
    ) of
        {ok, _, [{RpmLimit}]} ->
            reply_ok(#{data => #{
                user_id => UserId,
                rpm_limit => RpmLimit,
                current_rpm => 0
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === T6-02: Account Extended Operations (3-segment) ===

%% POST /api/v1/admin/accounts/:id/set-privacy — Set account privacy
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"set-privacy">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    IsPrivate = maps:get(<<"is_private">>, Params),
    PrivateJson = jsx:encode(IsPrivate),
    case ersub_repo:query(
        "UPDATE accounts SET extra = jsonb_set(COALESCE(extra, '{}'), "
        "'{is_private}', $2::jsonb) WHERE id = $1",
        [Id, PrivateJson]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req1, State);
        {ok, 0} -> reply_err(404, not_found, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% POST /api/v1/admin/accounts/:id/refresh-tier — Refresh tier info
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"refresh-tier">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    try
        ok = ersub_token_refresh_srv:trigger_refresh(Id),
        reply_ok(#{success => true, message => <<"refresh_triggered">>}, Req0, State)
    catch
        _:Err ->
            reply_err(500, Err, Req0, State)
    end;

%% POST /api/v1/admin/accounts/:id/schedulable — Set account schedulable
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"schedulable">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE accounts SET status = 'active' WHERE id = $1", [Id]
    ) of
        {ok, 1} ->
            _ = (catch ersub_account_srv:update_status(Id, active)),
            reply_ok(#{success => true}, Req0, State);
        {ok, 0} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === T6-08: OAuth Admin (OpenAI) ===

%% POST /api/v1/admin/openai/generate-auth-url
handle(<<"POST">>, [<<"openai">>, <<"generate-auth-url">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ClientId = ersub_config_srv:get(openai_oauth_client_id, <<>>),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    Url = iolist_to_binary([
        <<"https://auth.openai.com/authorize">>,
        <<"?client_id=">>, uri_string:quote(to_bin(ClientId)),
        <<"&redirect_uri=">>, uri_string:quote(RedirectUri),
        <<"&response_type=code">>,
        <<"&scope=model.read">>
    ]),
    reply_ok(#{data => #{url => Url}}, Req1, State);

%% POST /api/v1/admin/openai/exchange-code
handle(<<"POST">>, [<<"openai">>, <<"exchange-code">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Code = maps:get(<<"code">>, Params),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    ClientId = ersub_config_srv:get(openai_oauth_client_id, <<>>),
    ClientSecret = ersub_config_srv:get(openai_oauth_client_secret, <<>>),
    PostBody = jsx:encode(#{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => to_bin(ClientId),
        <<"client_secret">> => to_bin(ClientSecret),
        <<"code">> => Code,
        <<"redirect_uri">> => RedirectUri
    }),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"POST">>, <<"https://auth.openai.com/token">>,
                                     Headers, PostBody, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            TokenData = jsx:decode(RespBody, [return_maps]),
            AccessToken = maps:get(<<"access_token">>, TokenData, <<>>),
            Attrs = #{
                name => <<"OpenAI OAuth Account">>,
                platform => <<"openai">>,
                account_type => <<"oauth">>,
                credentials => #{<<"api_key">> => AccessToken, <<"source">> => <<"oauth">>,
                                  <<"token_data">> => TokenData},
                priority => 100,
                concurrency => 5
            },
            case ersub_repo:create_account(Attrs) of
                {ok, Account} ->
                    reply_ok(#{data => Account}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end;
        {ok, Status, _, RespBody} ->
            reply_err(502, iolist_to_binary([<<"token_exchange_failed: ">>,
                integer_to_binary(Status), <<" ">>, RespBody]), Req1, State);
        {error, Reason} ->
            reply_err(502, Reason, Req1, State)
    end;

%% POST /api/v1/admin/openai/refresh-token
handle(<<"POST">>, [<<"openai">>, <<"refresh-token">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    RefreshToken = maps:get(<<"refresh_token">>, Params),
    ClientId = ersub_config_srv:get(openai_oauth_client_id, <<>>),
    ClientSecret = ersub_config_srv:get(openai_oauth_client_secret, <<>>),
    PostBody = jsx:encode(#{
        <<"grant_type">> => <<"refresh_token">>,
        <<"client_id">> => to_bin(ClientId),
        <<"client_secret">> => to_bin(ClientSecret),
        <<"refresh_token">> => RefreshToken
    }),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"POST">>, <<"https://auth.openai.com/token">>,
                                     Headers, PostBody, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            TokenData = jsx:decode(RespBody, [return_maps]),
            reply_ok(#{data => TokenData}, Req1, State);
        {ok, Status, _, RespBody} ->
            reply_err(502, iolist_to_binary([<<"refresh_failed: ">>,
                integer_to_binary(Status), <<" ">>, RespBody]), Req1, State);
        {error, Reason} ->
            reply_err(502, Reason, Req1, State)
    end;

%% === T6-08: OAuth Admin (Gemini) ===

%% POST /api/v1/admin/gemini/oauth/auth-url
handle(<<"POST">>, [<<"gemini">>, <<"oauth">>, <<"auth-url">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ClientId = ersub_config_srv:get(gemini_oauth_client_id, <<>>),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    Scope = maps:get(<<"scope">>, Params, <<"https://www.googleapis.com/auth/generative-language">>),
    Url = iolist_to_binary([
        <<"https://accounts.google.com/o/oauth2/v2/auth">>,
        <<"?client_id=">>, uri_string:quote(to_bin(ClientId)),
        <<"&redirect_uri=">>, uri_string:quote(RedirectUri),
        <<"&response_type=code">>,
        <<"&scope=">>, uri_string:quote(Scope),
        <<"&access_type=offline">>
    ]),
    reply_ok(#{data => #{url => Url}}, Req1, State);

%% POST /api/v1/admin/gemini/oauth/exchange-code
handle(<<"POST">>, [<<"gemini">>, <<"oauth">>, <<"exchange-code">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Code = maps:get(<<"code">>, Params),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    ClientId = ersub_config_srv:get(gemini_oauth_client_id, <<>>),
    ClientSecret = ersub_config_srv:get(gemini_oauth_client_secret, <<>>),
    PostBody = jsx:encode(#{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => to_bin(ClientId),
        <<"client_secret">> => to_bin(ClientSecret),
        <<"code">> => Code,
        <<"redirect_uri">> => RedirectUri
    }),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"POST">>, <<"https://oauth2.googleapis.com/token">>,
                                     Headers, PostBody, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            TokenData = jsx:decode(RespBody, [return_maps]),
            AccessToken = maps:get(<<"access_token">>, TokenData, <<>>),
            Attrs = #{
                name => <<"Gemini OAuth Account">>,
                platform => <<"gemini">>,
                account_type => <<"oauth">>,
                credentials => #{<<"api_key">> => AccessToken, <<"source">> => <<"oauth">>,
                                  <<"token_data">> => TokenData},
                priority => 100,
                concurrency => 5
            },
            case ersub_repo:create_account(Attrs) of
                {ok, Account} ->
                    reply_ok(#{data => Account}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end;
        {ok, Status, _, RespBody} ->
            reply_err(502, iolist_to_binary([<<"token_exchange_failed: ">>,
                integer_to_binary(Status), <<" ">>, RespBody]), Req1, State);
        {error, Reason} ->
            reply_err(502, Reason, Req1, State)
    end;

%% GET /api/v1/admin/gemini/oauth/capabilities
handle(<<"GET">>, [<<"gemini">>, <<"oauth">>, <<"capabilities">>], Req0, State, _Claims) ->
    reply_ok(#{data => #{
        models => [<<"gemini-pro">>, <<"gemini-1.5-pro">>],
        features => [<<"streaming">>, <<"vision">>]
    }}, Req0, State);

%% === T6-08: OAuth Admin (Antigravity) ===

%% POST /api/v1/admin/antigravity/oauth/auth-url
handle(<<"POST">>, [<<"antigravity">>, <<"oauth">>, <<"auth-url">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ClientId = ersub_config_srv:get(antigravity_oauth_client_id, <<>>),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    AuthUrl = to_bin(ersub_config_srv:get(antigravity_oauth_auth_url,
        <<"https://auth.antigravity.ai/authorize">>)),
    Url = iolist_to_binary([
        AuthUrl,
        <<"?client_id=">>, uri_string:quote(to_bin(ClientId)),
        <<"&redirect_uri=">>, uri_string:quote(RedirectUri),
        <<"&response_type=code">>,
        <<"&scope=api">>
    ]),
    reply_ok(#{data => #{url => Url}}, Req1, State);

%% POST /api/v1/admin/antigravity/oauth/exchange-code
handle(<<"POST">>, [<<"antigravity">>, <<"oauth">>, <<"exchange-code">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Code = maps:get(<<"code">>, Params),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    ClientId = ersub_config_srv:get(antigravity_oauth_client_id, <<>>),
    ClientSecret = ersub_config_srv:get(antigravity_oauth_client_secret, <<>>),
    TokenUrl = to_bin(ersub_config_srv:get(antigravity_oauth_token_url,
        <<"https://auth.antigravity.ai/token">>)),
    PostBody = jsx:encode(#{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => to_bin(ClientId),
        <<"client_secret">> => to_bin(ClientSecret),
        <<"code">> => Code,
        <<"redirect_uri">> => RedirectUri
    }),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"POST">>, TokenUrl, Headers, PostBody, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            TokenData = jsx:decode(RespBody, [return_maps]),
            AccessToken = maps:get(<<"access_token">>, TokenData, <<>>),
            Attrs = #{
                name => <<"Antigravity OAuth Account">>,
                platform => <<"antigravity">>,
                account_type => <<"oauth">>,
                credentials => #{<<"api_key">> => AccessToken, <<"source">> => <<"oauth">>,
                                  <<"token_data">> => TokenData},
                priority => 100,
                concurrency => 5
            },
            case ersub_repo:create_account(Attrs) of
                {ok, Account} ->
                    reply_ok(#{data => Account}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end;
        {ok, Status, _, RespBody} ->
            reply_err(502, iolist_to_binary([<<"token_exchange_failed: ">>,
                integer_to_binary(Status), <<" ">>, RespBody]), Req1, State);
        {error, Reason} ->
            reply_err(502, Reason, Req1, State)
    end;

%% POST /api/v1/admin/antigravity/oauth/refresh-token
handle(<<"POST">>, [<<"antigravity">>, <<"oauth">>, <<"refresh-token">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    RefreshToken = maps:get(<<"refresh_token">>, Params),
    ClientId = ersub_config_srv:get(antigravity_oauth_client_id, <<>>),
    ClientSecret = ersub_config_srv:get(antigravity_oauth_client_secret, <<>>),
    TokenUrl = to_bin(ersub_config_srv:get(antigravity_oauth_token_url,
        <<"https://auth.antigravity.ai/token">>)),
    PostBody = jsx:encode(#{
        <<"grant_type">> => <<"refresh_token">>,
        <<"client_id">> => to_bin(ClientId),
        <<"client_secret">> => to_bin(ClientSecret),
        <<"refresh_token">> => RefreshToken
    }),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"POST">>, TokenUrl, Headers, PostBody, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            TokenData = jsx:decode(RespBody, [return_maps]),
            reply_ok(#{data => TokenData}, Req1, State);
        {ok, Status, _, RespBody} ->
            reply_err(502, iolist_to_binary([<<"refresh_failed: ">>,
                integer_to_binary(Status), <<" ">>, RespBody]), Req1, State);
        {error, Reason} ->
            reply_err(502, Reason, Req1, State)
    end;

%% === T6-09: Account Setup Token Endpoints ===

%% POST /api/v1/admin/accounts/generate-setup-token-url
handle(<<"POST">>, [<<"accounts">>, <<"generate-setup-token-url">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    RedirectUri = maps:get(<<"redirect_uri">>, Params, <<"http://localhost:3000/oauth/callback">>),
    Url = iolist_to_binary([
        <<"https://console.anthropic.com/setup/token">>,
        <<"?redirect_uri=">>, uri_string:quote(RedirectUri)
    ]),
    reply_ok(#{data => #{url => Url}}, Req1, State);

%% POST /api/v1/admin/accounts/exchange-setup-token-code
handle(<<"POST">>, [<<"accounts">>, <<"exchange-setup-token-code">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Code = maps:get(<<"code">>, Params),
    ClientId = ersub_config_srv:get(anthropic_oauth_client_id, <<>>),
    ClientSecret = ersub_config_srv:get(anthropic_oauth_client_secret, <<>>),
    PostBody = jsx:encode(#{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => to_bin(ClientId),
        <<"client_secret">> => to_bin(ClientSecret),
        <<"code">> => Code
    }),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    case ersub_upstream_pool:request(<<"POST">>, <<"https://api.anthropic.com/oauth/token">>,
                                     Headers, PostBody, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            TokenData = jsx:decode(RespBody, [return_maps]),
            ApiKey = maps:get(<<"access_token">>, TokenData, <<>>),
            Attrs = #{
                name => <<"Anthropic Setup Token Account">>,
                platform => <<"claude">>,
                account_type => <<"setup_token">>,
                credentials => #{<<"api_key">> => ApiKey, <<"source">> => <<"setup_token">>,
                                  <<"token_data">> => TokenData},
                priority => 100,
                concurrency => 5
            },
            case ersub_repo:create_account(Attrs) of
                {ok, Account} ->
                    reply_ok(#{data => Account}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end;
        {ok, Status, _, RespBody} ->
            reply_err(502, iolist_to_binary([<<"setup_token_exchange_failed: ">>,
                integer_to_binary(Status), <<" ">>, RespBody]), Req1, State);
        {error, Reason} ->
            reply_err(502, Reason, Req1, State)
    end;

%% POST /api/v1/admin/accounts/setup-token-cookie-auth
handle(<<"POST">>, [<<"accounts">>, <<"setup-token-cookie-auth">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    SessionKey = maps:get(<<"session_key">>, Params),
    Attrs = #{
        name => <<"Setup Token Cookie Auth">>,
        platform => <<"claude">>,
        account_type => <<"setup_token">>,
        credentials => #{<<"session_key">> => SessionKey,
                          <<"source">> => <<"setup_token_cookie">>},
        priority => 100,
        concurrency => 5
    },
    case ersub_repo:create_account(Attrs) of
        {ok, Account} ->
            reply_ok(#{data => Account}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === T6-18: Account Status Management ===

%% POST /api/v1/admin/accounts/check-mixed-channel
handle(<<"POST">>, [<<"accounts">>, <<"check-mixed-channel">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AccountIds = maps:get(<<"account_ids">>, Params, []),
    case AccountIds of
        [] ->
            reply_ok(#{data => #{mixed => false, platforms => []}}, Req1, State);
        _ ->
            {Placeholders, _} = lists:foldl(fun(_Id, {Acc, I}) ->
                P = iolist_to_binary([<<"$">>, integer_to_binary(I)]),
                {[P | Acc], I + 1}
            end, {[], 1}, AccountIds),
            InClause = iolist_to_binary(lists:join(<<", ">>, lists:reverse(Placeholders))),
            SQL = iolist_to_binary([
                "SELECT DISTINCT platform FROM accounts WHERE id IN (", InClause, ")"
            ]),
            case ersub_repo:query(SQL, AccountIds) of
                {ok, _, Rows} ->
                    Platforms = [P || {P} <- Rows],
                    IsMixed = length(Platforms) > 1,
                    reply_ok(#{data => #{mixed => IsMixed, platforms => Platforms}}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end
    end;

%% GET /api/v1/admin/accounts/antigravity/default-model-mapping
handle(<<"GET">>, [<<"accounts">>, <<"antigravity">>, <<"default-model-mapping">>], Req0, State, _Claims) ->
    Mapping = case ersub_config_srv:get(antigravity_default_model_mapping, undefined) of
        undefined -> #{};
        V when is_map(V) -> V;
        V when is_binary(V) ->
            try jsx:decode(V, [return_maps]) catch _:_ -> #{} end;
        V when is_list(V) ->
            try jsx:decode(list_to_binary(V), [return_maps]) catch _:_ -> #{} end;
        _ -> #{}
    end,
    reply_ok(#{data => Mapping}, Req0, State);

%% === T5-03: Admin Account Detail Management ===
%% (Placed AFTER all existing accounts/today-stats, accounts/batch, etc.)

%% GET /api/v1/admin/accounts/:id
handle(<<"GET">>, [<<"accounts">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, name, platform, account_type, credentials, status, "
        "priority, concurrency, rate_limited_until, overload_until, created_at "
        "FROM accounts WHERE id = $1", [Id]
    ) of
        {ok, _, [{AId, Name, Platform, Type, CredsJson, Status,
                  Priority, Conc, RLUntil, OLUntil, CreatedAt}]} ->
            Creds = case CredsJson of
                null -> #{};
                _ -> jsx:decode(CredsJson, [return_maps])
            end,
            reply_ok(#{data => #{
                id => AId, name => Name, platform => Platform,
                account_type => Type, credentials => Creds,
                status => Status, priority => Priority,
                concurrency => Conc, rate_limited_until => RLUntil,
                overload_until => OLUntil, created_at => CreatedAt
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/accounts/:id
handle(<<"PUT">>, [<<"accounts">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AllowedFields = [<<"name">>, <<"platform">>, <<"priority">>,
                     <<"concurrency">>, <<"status">>],
    Fields0 = maps:fold(fun(K, V, Acc) ->
        case lists:member(K, AllowedFields) of
            true -> maps:put(binary_to_atom(K), V, Acc);
            false -> Acc
        end
    end, #{}, Params),
    Fields = case maps:get(<<"credentials">>, Params, undefined) of
        undefined -> Fields0;
        Creds -> maps:put(credentials, jsx:encode(Creds), Fields0)
    end,
    case maps:size(Fields) of
        0 ->
            reply_err(400, no_fields_provided, Req1, State);
        _ ->
            case ersub_repo:update_account(Id, Fields) of
                {ok, 1} -> reply_ok(#{success => true}, Req1, State);
                {ok, 0} -> reply_err(404, not_found, Req1, State);
                {error, Reason} -> reply_err(500, Reason, Req1, State)
            end
    end;

%% POST /api/v1/admin/accounts/:id/test
handle(<<"POST">>, [<<"accounts">>, IdBin, <<"test">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT base_url, credentials FROM accounts WHERE id = $1", [Id]
    ) of
        {ok, _, [{BaseUrl0, CredsJson}]} ->
            Creds = case CredsJson of
                null -> #{};
                _ -> jsx:decode(CredsJson, [return_maps])
            end,
            BaseUrl = case BaseUrl0 of
                null -> maps:get(<<"base_url">>, Creds, <<"https://api.openai.com">>);
                <<>> -> maps:get(<<"base_url">>, Creds, <<"https://api.openai.com">>);
                _ -> BaseUrl0
            end,
            case parse_proxy_host_port(BaseUrl) of
                {ok, Host, Port} ->
                    T0 = erlang:monotonic_time(millisecond),
                    ConnOpts = #{
                        connect_timeout => 10000,
                        protocols => [http],
                        transport => tls
                    },
                    case gun:open(Host, Port, ConnOpts) of
                        {ok, ConnPid} ->
                            MRef = monitor(process, ConnPid),
                            case gun:await_up(ConnPid, 10000, MRef) of
                                {ok, _} ->
                                    BetaHeader = ersub_config_srv:get(anthropic_beta_header, <<"prompt-caching-2024-07-31">>),
                                    TestHeaders = [{<<"anthropic-beta">>, BetaHeader}],
                                    _StreamRef = gun:get(ConnPid, "/v1/models", TestHeaders),
                                    T1 = erlang:monotonic_time(millisecond),
                                    LatencyMs = T1 - T0,
                                    demonitor(MRef, [flush]),
                                    gun:close(ConnPid),
                                    reply_ok(#{data => #{
                                        account_id => Id,
                                        status => <<"ok">>,
                                        latency_ms => LatencyMs
                                    }}, Req0, State);
                                {error, ConnErr} ->
                                    T1 = erlang:monotonic_time(millisecond),
                                    demonitor(MRef, [flush]),
                                    gun:close(ConnPid),
                                    reply_ok(#{data => #{
                                        account_id => Id,
                                        status => <<"error">>,
                                        latency_ms => T1 - T0,
                                        error => iolist_to_binary(
                                            io_lib:format("~p", [ConnErr]))
                                    }}, Req0, State)
                            end;
                        {error, OpenErr} ->
                            T1 = erlang:monotonic_time(millisecond),
                            reply_ok(#{data => #{
                                account_id => Id,
                                status => <<"error">>,
                                latency_ms => T1 - T0,
                                error => iolist_to_binary(
                                    io_lib:format("~p", [OpenErr]))
                            }}, Req0, State)
                    end;
                {error, ParseErr} ->
                    reply_err(400, ParseErr, Req0, State)
            end;
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/accounts/:id/usage
handle(<<"GET">>, [<<"accounts">>, IdBin, <<"usage">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, request_id, requested_model, input_tokens, output_tokens, "
        "actual_cost, created_at FROM usage_logs WHERE account_id = $1 "
        "ORDER BY created_at DESC LIMIT 100", [Id]
    ) of
        {ok, _, Rows} ->
            Logs = [#{id => LId, request_id => RId, requested_model => M,
                      input_tokens => IT, output_tokens => OT,
                      actual_cost => C, created_at => CA}
                    || {LId, RId, M, IT, OT, C, CA} <- Rows],
            reply_ok(#{data => Logs}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/accounts/:id/models
handle(<<"GET">>, [<<"accounts">>, IdBin, <<"models">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT credentials FROM accounts WHERE id = $1", [Id]
    ) of
        {ok, _, [{CredsJson}]} ->
            Creds = case CredsJson of
                null -> #{};
                _ -> jsx:decode(CredsJson, [return_maps])
            end,
            Models = maps:get(<<"supported_models">>, Creds, []),
            reply_ok(#{data => Models}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/accounts/:id/scheduled-tests
handle(<<"GET">>, [<<"accounts">>, IdBin, <<"scheduled-tests">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, name, account_id, model, interval_s, timeout_ms, "
        "auto_recover, last_result, last_run_at, is_active "
        "FROM scheduled_tests WHERE account_id = $1 ORDER BY id", [Id]) of
        {ok, _, Rows} ->
            Data = [#{id => TId, name => N, account_id => AId, model => M,
                      interval_s => IS, timeout_ms => TM, auto_recover => AR,
                      last_result => LR, last_run_at => LRA, is_active => IA}
                    || {TId, N, AId, M, IS, TM, AR, LR, LRA, IA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === T5-04: Admin Group Complete CRUD ===
%% (Placed AFTER all existing groups/:id/dispatch, groups/:id/stats,
%%  groups/:id/rate-multipliers, groups/sort-order, groups/capacity-summary)

%% GET /api/v1/admin/groups/:id/rate-multipliers (read)
handle(<<"GET">>, [<<"groups">>, IdBin, <<"rate-multipliers">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT input_multiplier, output_multiplier FROM groups WHERE id = $1", [Id]
    ) of
        {ok, _, [{InputMult, OutputMult}]} ->
            reply_ok(#{data => #{
                group_id => Id,
                input_multiplier => InputMult,
                output_multiplier => OutputMult
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% DELETE /api/v1/admin/groups/:id/rate-multipliers (reset to defaults)
handle(<<"DELETE">>, [<<"groups">>, IdBin, <<"rate-multipliers">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE groups SET input_multiplier = 1.0, output_multiplier = 1.0 "
        "WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/groups/:id/rpm-overrides
handle(<<"PUT">>, [<<"groups">>, IdBin, <<"rpm-overrides">>], Req0, State, _Claims) ->
    _Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Overrides = jsx:decode(Body, [return_maps]),
    SettingKey = <<"group_rpm_overrides_", IdBin/binary>>,
    case ersub_repo:upsert_setting(SettingKey, Overrides) of
        {ok, _} -> reply_ok(#{success => true}, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% DELETE /api/v1/admin/groups/:id/rpm-overrides
handle(<<"DELETE">>, [<<"groups">>, IdBin, <<"rpm-overrides">>], Req0, State, _Claims) ->
    _Id = binary_to_integer(IdBin),
    SettingKey = <<"group_rpm_overrides_", IdBin/binary>>,
    case ersub_repo:query("DELETE FROM settings WHERE key = $1", [SettingKey]) of
        {ok, _} -> reply_ok(#{success => true}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/groups/:id/api-keys
handle(<<"GET">>, [<<"groups">>, IdBin, <<"api-keys">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT ak.id, ak.key_prefix, ak.name, ak.is_active, ak.created_at "
        "FROM api_keys ak "
        "JOIN user_allowed_groups uag ON ak.user_id = uag.user_id "
        "WHERE uag.group_id = $1 AND ak.deleted_at IS NULL "
        "ORDER BY ak.created_at DESC", [Id]
    ) of
        {ok, _, Rows} ->
            Keys = [#{id => KId, key_prefix => KP, name => N,
                      is_active => A, created_at => CA}
                    || {KId, KP, N, A, CA} <- Rows],
            reply_ok(#{data => Keys}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/groups/:id/subscriptions — List group subscriptions (T5-25)
handle(<<"GET">>, [<<"groups">>, IdBin, <<"subscriptions">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT s.id, s.user_id, s.group_id, s.status, s.starts_at, s.expires_at, "
        "s.daily_usage_usd, s.weekly_usage_usd, s.monthly_usage_usd, "
        "s.created_at, u.email "
        "FROM user_subscriptions s "
        "JOIN users u ON u.id = s.user_id "
        "WHERE s.group_id = $1 ORDER BY s.id", [Id]
    ) of
        {ok, _, Rows} ->
            Subs = [#{id => SId, user_id => UID, group_id => GID,
                       status => St, starts_at => SA, expires_at => EA,
                       daily_usage_usd => DU, weekly_usage_usd => WU,
                       monthly_usage_usd => MU, created_at => CA,
                       email => Email}
                    || {SId, UID, GID, St, SA, EA, DU, WU, MU, CA, Email} <- Rows],
            reply_ok(#{data => Subs}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/groups/:id
handle(<<"GET">>, [<<"groups">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, name, platform, billing_type, rate_multiplier, "
        "daily_limit_usd, weekly_limit_usd, monthly_limit_usd, "
        "rpm_limit, created_at FROM groups WHERE id = $1", [Id]
    ) of
        {ok, _, [{GId, Name, Platform, BT, RM, DL, WL, ML, RPM, CA}]} ->
            reply_ok(#{data => #{
                id => GId, name => Name, platform => Platform,
                billing_type => BT, rate_multiplier => RM,
                daily_limit_usd => DL, weekly_limit_usd => WL,
                monthly_limit_usd => ML, rpm_limit => RPM,
                created_at => CA
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/groups/:id
handle(<<"PUT">>, [<<"groups">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AllFields = [
        {<<"name">>, <<"name">>},
        {<<"platform">>, <<"platform">>},
        {<<"rate_multiplier">>, <<"rate_multiplier">>},
        {<<"billing_type">>, <<"billing_type">>},
        {<<"daily_limit_usd">>, <<"daily_limit_usd">>},
        {<<"weekly_limit_usd">>, <<"weekly_limit_usd">>},
        {<<"monthly_limit_usd">>, <<"monthly_limit_usd">>}
    ],
    {SetParts, Values, _Idx} = lists:foldl(fun({JsonKey, Col}, {Sets, Vals, I}) ->
        case maps:find(JsonKey, Params) of
            {ok, Val} ->
                SetClause = iolist_to_binary([Col, " = $", integer_to_binary(I)]),
                {[SetClause | Sets], Vals ++ [Val], I + 1};
            error ->
                {Sets, Vals, I}
        end
    end, {[], [], 2}, AllFields),
    case SetParts of
        [] ->
            reply_err(400, no_fields_provided, Req1, State);
        _ ->
            SetStr = iolist_to_binary(lists:join(<<", ">>, lists:reverse(SetParts))),
            SQL = iolist_to_binary([
                "UPDATE groups SET ", SetStr, " WHERE id = $1"
            ]),
            case ersub_repo:query(SQL, [Id | Values]) of
                {ok, 1} -> reply_ok(#{success => true}, Req1, State);
                {ok, 0} -> reply_err(404, not_found, Req1, State);
                {error, Reason} -> reply_err(500, Reason, Req1, State)
            end
    end;

%% DELETE /api/v1/admin/groups/:id
handle(<<"DELETE">>, [<<"groups">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query("DELETE FROM groups WHERE id = $1", [Id]) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === T5-11: Redeem Code Full Management ===

%% GET /api/v1/admin/redeem-codes — List all
handle(<<"GET">>, [<<"redeem-codes">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, code, amount_usd, is_used, used_by, used_at, notes, created_at "
        "FROM redeem_codes ORDER BY id DESC LIMIT 200"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => Id, code => C, amount_usd => A, is_used => IU,
                      used_by => UB, used_at => UA, notes => N, created_at => CA}
                    || {Id, C, A, IU, UB, UA, N, CA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/redeem-codes/stats
handle(<<"GET">>, [<<"redeem-codes">>, <<"stats">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT COUNT(*) as total, "
        "COUNT(*) FILTER (WHERE is_used) as used, "
        "COALESCE(SUM(amount_usd),0) as total_amount, "
        "COALESCE(SUM(amount_usd) FILTER (WHERE is_used),0) as used_amount "
        "FROM redeem_codes"
    ) of
        {ok, _, [{Total, Used, TotalAmount, UsedAmount}]} ->
            reply_ok(#{data => #{
                total => binary_to_integer(Total),
                used => binary_to_integer(Used),
                total_amount => TotalAmount,
                used_amount => UsedAmount
            }}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/redeem-codes/generate
handle(<<"POST">>, [<<"redeem-codes">>, <<"generate">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Count = maps:get(<<"count">>, Params, 10),
    Amount = maps:get(<<"amount">>, Params, 5.0),
    Prefix = maps:get(<<"prefix">>, Params, <<"RC">>),
    Codes = [iolist_to_binary([Prefix, <<"-">>,
              binary:encode_hex(crypto:strong_rand_bytes(4))])
             || _ <- lists:seq(1, Count)],
    {Placeholders, AllParams} = lists:foldl(fun(Code, {PlAcc, PaAcc}) ->
        Idx = length(PaAcc),
        P = iolist_to_binary([
            <<"($">>, integer_to_binary(Idx + 1),
            <<", $">>, integer_to_binary(Idx + 2), <<")">>
        ]),
        {[P | PlAcc], PaAcc ++ [Code, Amount]}
    end, {[], []}, Codes),
    ValuesStr = iolist_to_binary(lists:join(<<", ">>, lists:reverse(Placeholders))),
    SQL = iolist_to_binary([
        "INSERT INTO redeem_codes (code, amount_usd) VALUES ", ValuesStr,
        " RETURNING id, code, amount_usd, created_at"
    ]),
    case ersub_repo:query(SQL, AllParams) of
        {ok, _, _, Rows} ->
            Data = [#{id => Id, code => C, amount_usd => A, created_at => CA}
                    || {Id, C, A, CA} <- Rows],
            reply_ok(#{data => Data}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% POST /api/v1/admin/redeem-codes/batch-delete
handle(<<"POST">>, [<<"redeem-codes">>, <<"batch-delete">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Ids = maps:get(<<"ids">>, Params, []),
    case Ids of
        [] ->
            reply_ok(#{success => true, deleted => 0}, Req1, State);
        _ ->
            {Placeholders, _} = lists:foldl(fun(_Id, {Acc, I}) ->
                P = iolist_to_binary([<<"$">>, integer_to_binary(I)]),
                {[P | Acc], I + 1}
            end, {[], 1}, Ids),
            InClause = iolist_to_binary(lists:join(<<", ">>, lists:reverse(Placeholders))),
            SQL = iolist_to_binary([
                "DELETE FROM redeem_codes WHERE id IN (", InClause, ")"
            ]),
            case ersub_repo:query(SQL, Ids) of
                {ok, N} ->
                    reply_ok(#{success => true, deleted => N}, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end
    end;

%% === T6-07: Redeem Code Completion ===

%% GET /api/v1/admin/redeem-codes/export — CSV export of all redeem codes
handle(<<"GET">>, [<<"redeem-codes">>, <<"export">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, code, amount_usd, is_used, used_by, used_at, notes, created_at "
        "FROM redeem_codes ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Header = <<"id,code,amount_usd,is_used,used_by,used_at,notes,created_at\r\n">>,
            CsvRows = lists:map(fun({Id, Code, Amount, IsUsed, UsedBy, UsedAt, Notes, CA}) ->
                iolist_to_binary([
                    csv_field(Id), <<",">>, csv_field(Code), <<",">>,
                    csv_field(Amount), <<",">>, csv_field(IsUsed), <<",">>,
                    csv_field(UsedBy), <<",">>, csv_field(UsedAt), <<",">>,
                    csv_field(Notes), <<",">>, csv_field(CA), <<"\r\n">>
                ])
            end, Rows),
            CsvBody = iolist_to_binary([Header | CsvRows]),
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/csv">>,
                  <<"content-disposition">> => <<"attachment; filename=\"redeem_codes_export.csv\"">>},
                CsvBody, Req0),
            {ok, Req, State};
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/redeem-codes/create-and-redeem — Create and immediately redeem
handle(<<"POST">>, [<<"redeem-codes">>, <<"create-and-redeem">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Code = maps:get(<<"code">>, Params),
    Amount = maps:get(<<"amount">>, Params),
    UserId = maps:get(<<"user_id">>, Params),
    %% Step 1: Create the redeem code
    case ersub_repo:query(
        "INSERT INTO redeem_codes (code, amount_usd) VALUES ($1, $2) RETURNING id",
        [Code, Amount]
    ) of
        {ok, 1, _, [{CodeId}]} ->
            %% Step 2: Mark as used
            _ = ersub_repo:query(
                "UPDATE redeem_codes SET is_used = TRUE, used_by = $2, used_at = NOW() "
                "WHERE id = $1", [CodeId, UserId]),
            %% Step 3: Add amount to user balance
            case ersub_repo:query(
                "UPDATE users SET balance_usd = balance_usd + $2, updated_at = NOW() "
                "WHERE id = $1 AND deleted_at IS NULL RETURNING balance_usd",
                [UserId, Amount]
            ) of
                {ok, 1, _, [{NewBalance}]} ->
                    reply_ok(#{data => #{
                        code_id => CodeId, code => Code, amount => Amount,
                        user_id => UserId, new_balance => NewBalance
                    }}, Req1, State);
                {ok, 0, _, []} ->
                    reply_err(404, user_not_found, Req1, State);
                {error, Reason} ->
                    reply_err(500, Reason, Req1, State)
            end;
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% GET /api/v1/admin/redeem-codes/:id — Get single redeem code
handle(<<"GET">>, [<<"redeem-codes">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, code, amount_usd, is_used, used_by, used_at, notes, created_at "
        "FROM redeem_codes WHERE id = $1", [Id]
    ) of
        {ok, _, [{RId, Code, Amount, IsUsed, UsedBy, UsedAt, Notes, CA}]} ->
            reply_ok(#{data => #{
                id => RId, code => Code, amount_usd => Amount,
                is_used => IsUsed, used_by => UsedBy, used_at => UsedAt,
                notes => Notes, created_at => CA
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% DELETE /api/v1/admin/redeem-codes/:id
handle(<<"DELETE">>, [<<"redeem-codes">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query("DELETE FROM redeem_codes WHERE id = $1", [Id]) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/redeem-codes/:id/expire
handle(<<"POST">>, [<<"redeem-codes">>, IdBin, <<"expire">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE redeem_codes SET is_used = TRUE, used_at = NOW() WHERE id = $1", [Id]
    ) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === T5-12: Promo Code Full CRUD ===

%% GET /api/v1/admin/promo-codes — List all
handle(<<"GET">>, [<<"promo-codes">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, code, discount_type, discount_value, max_uses, "
        "current_uses, valid_from, valid_until, is_active, created_at "
        "FROM promo_codes ORDER BY id DESC"
    ) of
        {ok, _, Rows} ->
            Data = [#{id => Id, code => C, discount_type => DT,
                      discount_value => DV, max_uses => MU,
                      current_uses => CU, valid_from => VF,
                      valid_until => VU, is_active => IA, created_at => CA}
                    || {Id, C, DT, DV, MU, CU, VF, VU, IA, CA} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/v1/admin/promo-codes — Create
handle(<<"POST">>, [<<"promo-codes">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Code = maps:get(<<"code">>, Params),
    DiscountType = maps:get(<<"discount_type">>, Params),
    DiscountValue = maps:get(<<"discount_value">>, Params),
    MaxUses = maps:get(<<"max_uses">>, Params, null),
    ValidFrom = maps:get(<<"valid_from">>, Params, null),
    ValidUntil = maps:get(<<"valid_until">>, Params, null),
    IsActive = maps:get(<<"is_active">>, Params, true),
    case ersub_repo:query(
        "INSERT INTO promo_codes (code, discount_type, discount_value, "
        "max_uses, valid_from, valid_until, is_active) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7) "
        "RETURNING id, created_at",
        [Code, DiscountType, DiscountValue, MaxUses, ValidFrom, ValidUntil, IsActive]
    ) of
        {ok, 1, _, [{Id, CreatedAt}]} ->
            reply_ok(#{data => #{
                id => Id, code => Code, discount_type => DiscountType,
                discount_value => DiscountValue, max_uses => MaxUses,
                valid_from => ValidFrom, valid_until => ValidUntil,
                is_active => IsActive, created_at => CreatedAt
            }}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% GET /api/v1/admin/promo-codes/:id — Get single
handle(<<"GET">>, [<<"promo-codes">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, code, discount_type, discount_value, max_uses, "
        "current_uses, valid_from, valid_until, is_active, created_at "
        "FROM promo_codes WHERE id = $1", [Id]
    ) of
        {ok, _, [{PId, C, DT, DV, MU, CU, VF, VU, IA, CA}]} ->
            reply_ok(#{data => #{
                id => PId, code => C, discount_type => DT,
                discount_value => DV, max_uses => MU,
                current_uses => CU, valid_from => VF,
                valid_until => VU, is_active => IA, created_at => CA
            }}, Req0, State);
        {ok, _, []} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% PUT /api/v1/admin/promo-codes/:id — Update
handle(<<"PUT">>, [<<"promo-codes">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AllFields = [
        {<<"code">>, <<"code">>},
        {<<"discount_type">>, <<"discount_type">>},
        {<<"discount_value">>, <<"discount_value">>},
        {<<"max_uses">>, <<"max_uses">>},
        {<<"valid_from">>, <<"valid_from">>},
        {<<"valid_until">>, <<"valid_until">>},
        {<<"is_active">>, <<"is_active">>}
    ],
    {SetParts, Values, _Idx} = lists:foldl(fun({JsonKey, Col}, {Sets, Vals, I}) ->
        case maps:find(JsonKey, Params) of
            {ok, Val} ->
                SetClause = iolist_to_binary([Col, " = $", integer_to_binary(I)]),
                {[SetClause | Sets], Vals ++ [Val], I + 1};
            error ->
                {Sets, Vals, I}
        end
    end, {[], [], 2}, AllFields),
    case SetParts of
        [] ->
            reply_err(400, no_fields_provided, Req1, State);
        _ ->
            SetStr = iolist_to_binary(lists:join(<<", ">>, lists:reverse(SetParts))),
            SQL = iolist_to_binary([
                "UPDATE promo_codes SET ", SetStr, " WHERE id = $1"
            ]),
            case ersub_repo:query(SQL, [Id | Values]) of
                {ok, 1} -> reply_ok(#{success => true}, Req1, State);
                {ok, 0} -> reply_err(404, not_found, Req1, State);
                {error, Reason} -> reply_err(500, Reason, Req1, State)
            end
    end;

%% DELETE /api/v1/admin/promo-codes/:id — Delete
handle(<<"DELETE">>, [<<"promo-codes">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query("DELETE FROM promo_codes WHERE id = $1", [Id]) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% GET /api/v1/admin/promo-codes/:id/usages
handle(<<"GET">>, [<<"promo-codes">>, IdBin, <<"usages">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT pu.id, pu.user_id, pu.used_at, u.email "
        "FROM promo_code_usage pu "
        "JOIN users u ON u.id = pu.user_id "
        "WHERE pu.promo_code_id = $1 "
        "ORDER BY pu.used_at DESC", [Id]
    ) of
        {ok, _, Rows} ->
            Data = [#{id => UId, user_id => UID, used_at => UA, email => E}
                    || {UId, UID, UA, E} <- Rows],
            reply_ok(#{data => Data}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% === T7-02: Admin Update API Key ===

%% PUT /api/v1/admin/api-keys/:id — Admin update API key
handle(<<"PUT">>, [<<"api-keys">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AllFields = [
        {<<"group_id">>, <<"group_id">>},
        {<<"user_id">>, <<"user_id">>},
        {<<"is_active">>, <<"is_active">>}
    ],
    {SetParts, Values, _Idx} = lists:foldl(fun({JsonKey, Col}, {Sets, Vals, I}) ->
        case maps:find(JsonKey, Params) of
            {ok, Val} ->
                SetClause = iolist_to_binary([Col, " = $", integer_to_binary(I)]),
                {[SetClause | Sets], Vals ++ [Val], I + 1};
            error ->
                {Sets, Vals, I}
        end
    end, {[], [], 2}, AllFields),
    case SetParts of
        [] ->
            reply_err(400, no_fields_to_update, Req1, State);
        _ ->
            SetStr = iolist_to_binary(lists:join(<<", ">>, lists:reverse(SetParts))),
            SQL = iolist_to_binary([
                "UPDATE api_keys SET ", SetStr, " WHERE id = $1"
            ]),
            case ersub_repo:query(SQL, [Id | Values]) of
                {ok, 1} -> reply_ok(#{success => true}, Req1, State);
                {ok, 0} -> reply_err(404, not_found, Req1, State);
                {error, Reason} -> reply_err(500, Reason, Req1, State)
            end
    end;

%% === T7-08: OpenAI OAuth Admin ===

%% POST /api/v1/admin/openai/accounts/:id/refresh — Trigger refresh for OpenAI account
handle(<<"POST">>, [<<"openai">>, <<"accounts">>, IdBin, <<"refresh">>], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    ok = ersub_token_refresh_srv:trigger_refresh(Id),
    reply_ok(#{success => true, message => <<"refresh_triggered">>}, Req0, State);

%% POST /api/v1/admin/openai/create-from-oauth — Create account from OAuth access token
handle(<<"POST">>, [<<"openai">>, <<"create-from-oauth">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    AccessToken = maps:get(<<"access_token">>, Params),
    Name = maps:get(<<"name">>, Params, <<"OpenAI OAuth Account">>),
    Attrs = #{
        name => Name,
        platform => <<"openai">>,
        account_type => <<"oauth">>,
        credentials => #{<<"api_key">> => AccessToken, <<"source">> => <<"oauth">>},
        priority => 100,
        concurrency => 5
    },
    case ersub_repo:create_account(Attrs) of
        {ok, Account} ->
            _ = case ersub_repo:get_account(maps:get(id, Account)) of
                {ok, FullAcc} -> ersub_platform_sup:start_account(FullAcc);
                _ -> ok
            end,
            reply_ok(#{data => Account}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

handle(_, _, Req0, State, _) ->
    Req = reply_json(404, #{error => #{message => <<"Not found">>}}, Req0),
    {ok, Req, State}.

%%% Internal

verify_admin_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            case ersub_auth_srv:verify_jwt(string:trim(Token)) of
                {ok, #{<<"role">> := <<"admin">>}} = Ok -> Ok;
                {ok, _} -> {error, not_admin};
                Err -> Err
            end;
        _ -> {error, missing_token}
    end.

reply_ok(Body, Req0, State) ->
    Req = reply_json(200, Body, Req0),
    {ok, Req, State}.

reply_err(Status, Reason, Req0, State) ->
    Req = reply_json(Status, #{error => #{
        type => <<"api_error">>,
        message => iolist_to_binary(io_lib:format("~p", [Reason]))
    }}, Req0),
    {ok, Req, State}.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

typed_setting_get(SettingKey, Req0, State) ->
    case ersub_repo:get_setting(SettingKey) of
        {ok, Value} ->
            reply_ok(#{data => #{key => SettingKey, value => Value}}, Req0, State);
        {error, not_found} ->
            reply_err(404, not_found, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end.

typed_setting_put(SettingKey, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Value = maps:get(<<"value">>, Params),
    case ersub_repo:upsert_setting(SettingKey, Value) of
        {ok, _} ->
            ersub_config_srv:set(binary_to_atom(SettingKey), Value),
            ersub_clips_config:reload(),
            reply_ok(#{success => true}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end.

auth_msg(missing_token) -> <<"Missing Authorization header">>;
auth_msg(not_admin) -> <<"Admin role required">>;
auth_msg(token_expired) -> <<"Token expired">>;
auth_msg(_) -> <<"Authentication failed">>.

qs_int(Key, QS, Default) ->
    case proplists:get_value(Key, QS, undefined) of
        undefined -> Default;
        V -> try binary_to_integer(V) catch _:_ -> Default end
    end.

build_usage_filters(UserFilter, ModelFilter) ->
    {Clauses, Params} = lists:foldl(fun
        ({undefined, _}, Acc) -> Acc;
        ({Value, Col}, {Cs, Ps}) ->
            Idx = length(Ps) + 1,
            Clause = iolist_to_binary([" AND ", Col, " = $", integer_to_binary(Idx)]),
            {[Clause | Cs], Ps ++ [Value]}
    end, {[], []}, [
        {UserFilter, "user_id"},
        {ModelFilter, "requested_model"}
    ]),
    WhereClause = case Clauses of
        [] -> <<>>;
        _ -> iolist_to_binary([" WHERE 1=1" | lists:reverse(Clauses)])
    end,
    {WhereClause, Params}.

exchange_oauth_token(PostBody) ->
    case gun:open("api.anthropic.com", 443, #{
        connect_timeout => 10000,
        protocols => [http],
        transport => tls
    }) of
        {ok, ConnPid} ->
            MRef = monitor(process, ConnPid),
            case gun:await_up(ConnPid, 10000, MRef) of
                {ok, _} ->
                    StreamRef = gun:post(ConnPid, "/oauth/token",
                        [{<<"content-type">>, <<"application/json">>}], PostBody),
                    case gun:await(ConnPid, StreamRef, 15000, MRef) of
                        {response, nofin, Status, _Headers} ->
                            {ok, RespBody} = gun:await_body(ConnPid, StreamRef, 15000, MRef),
                            demonitor(MRef, [flush]),
                            gun:close(ConnPid),
                            case Status of
                                200 ->
                                    {ok, jsx:decode(RespBody, [return_maps])};
                                _ ->
                                    {error, iolist_to_binary([
                                        <<"oauth_token_exchange_failed: ">>,
                                        integer_to_binary(Status),
                                        <<" ">>, RespBody
                                    ])}
                            end;
                        {response, fin, Status, _Headers} ->
                            demonitor(MRef, [flush]),
                            gun:close(ConnPid),
                            {error, iolist_to_binary([
                                <<"oauth_token_exchange_failed: ">>,
                                integer_to_binary(Status)
                            ])};
                        {error, Reason} ->
                            demonitor(MRef, [flush]),
                            gun:close(ConnPid),
                            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
                    end;
                {error, ConnErr} ->
                    demonitor(MRef, [flush]),
                    gun:close(ConnPid),
                    {error, iolist_to_binary(io_lib:format("~p", [ConnErr]))}
            end;
        {error, OpenErr} ->
            {error, iolist_to_binary(io_lib:format("~p", [OpenErr]))}
    end.

encode_nullable_json(null) -> null;
encode_nullable_json(undefined) -> null;
encode_nullable_json(V) when is_map(V); is_list(V) -> jsx:encode(V);
encode_nullable_json(V) when is_binary(V) -> V.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

decode_nullable_json(null) -> null;
decode_nullable_json(undefined) -> null;
decode_nullable_json(Json) when is_binary(Json) ->
    try jsx:decode(Json, [return_maps])
    catch _:_ -> Json
    end;
decode_nullable_json(Other) -> Other.

csv_field(null) -> <<>>;
csv_field(undefined) -> <<>>;
csv_field(V) when is_binary(V) ->
    %% Escape double quotes and wrap in quotes if contains comma/quote/newline
    case binary:match(V, [<<",">>, <<"\"">>, <<"\n">>, <<"\r">>]) of
        nomatch -> V;
        _ ->
            Escaped = binary:replace(V, <<"\"">>, <<"\"\"">>, [global]),
            <<"\"", Escaped/binary, "\"">>
    end;
csv_field(V) when is_integer(V) -> integer_to_binary(V);
csv_field(V) when is_float(V) -> float_to_binary(V, [{decimals, 6}, compact]);
csv_field(true) -> <<"true">>;
csv_field(false) -> <<"false">>;
csv_field(V) when is_atom(V) -> atom_to_binary(V);
csv_field(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% Parse proxy URL to extract host (charlist) and port (integer).
%% Uses uri_string:parse/1 for robust URL parsing.
parse_proxy_host_port(Url) when is_binary(Url) ->
    case uri_string:parse(Url) of
        #{host := HostBin} = Parsed ->
            Host = binary_to_list(HostBin),
            Port = case maps:get(port, Parsed, undefined) of
                undefined ->
                    case maps:get(scheme, Parsed, <<"http">>) of
                        <<"https">> -> 443;
                        _ -> 80
                    end;
                P -> P
            end,
            {ok, Host, Port};
        {error, _, _} ->
            {error, invalid_proxy_url};
        _ ->
            {error, invalid_proxy_url}
    end.

%% Check if a module's beam file on disk is newer than the loaded version.
beam_modified(Module, LoadedPath) when is_list(LoadedPath) ->
    case code:which(Module) of
        BeamPath when is_list(BeamPath) ->
            case {filelib:last_modified(LoadedPath), filelib:last_modified(BeamPath)} of
                {0, _} -> false;
                {_, 0} -> false;
                {LoadedTime, DiskTime} -> DiskTime > LoadedTime
            end;
        _ -> false
    end.
