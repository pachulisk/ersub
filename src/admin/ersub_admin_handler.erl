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

%% DELETE /api/v1/admin/proxies/:id
handle(<<"DELETE">>, [<<"proxies">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query("DELETE FROM proxies WHERE id = $1", [Id]) of
        {ok, 1} -> reply_ok(#{success => true}, Req0, State);
        {ok, 0} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
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
