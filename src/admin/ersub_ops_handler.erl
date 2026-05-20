-module(ersub_ops_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%% Ops dashboard and alert management — /api/v1/admin/ops/[...]

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case verify_admin_jwt(Req0) of
        {error, Reason} ->
            Req = reply_json(401, #{error => #{message => auth_msg(Reason)}}, Req0),
            {ok, Req, State};
        {ok, _Claims} ->
            Path = cowboy_req:path_info(Req0),
            handle(Method, Path, Req0, State)
    end.

%% === Dashboard (T1-05) ===

handle(<<"GET">>, [<<"dashboard">>], Req0, State) ->
    Dashboard = ersub_dashboard_cache:get(ops_dashboard, fun() ->
        Summary = try ersub_metrics_srv:get_summary() catch _:_ -> #{} end,
        Health = try ersub_health_srv:get_score() catch _:_ -> #{score => 0} end,
        Accounts = length(ersub_platform_sup:list_accounts()),
        Children = length(supervisor:which_children(ersub_sup)),
        #{
            health_score => maps:get(score, Health, 0),
            components => maps:get(components, Health, #{}),
            requests_1h => maps:get(requests_1h, Summary, 0),
            cost_1h => maps:get(cost_1h, Summary, 0),
            avg_duration_ms => maps:get(avg_duration_ms, Summary, 0),
            active_accounts => Accounts,
            supervisor_children => Children
        }
    end),
    {ok, reply_json(200, #{data => Dashboard}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"throughput">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT date_trunc('minute', created_at) AS minute, COUNT(*) "
        "FROM usage_logs WHERE created_at > NOW() - INTERVAL '1 hour' "
        "GROUP BY minute ORDER BY minute") of
        {ok, _, Rows} ->
            Data = [#{minute => M, count => binary_to_integer(C)} || {M, C} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"GET">>, [<<"dashboard">>, <<"errors">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT requested_model, COUNT(*) FROM usage_logs "
        "WHERE actual_cost = 0 AND created_at > NOW() - INTERVAL '1 hour' "
        "GROUP BY requested_model ORDER BY COUNT(*) DESC LIMIT 10") of
        {ok, _, Rows} ->
            Data = [#{model => M, errors => binary_to_integer(C)} || {M, C} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"GET">>, [<<"dashboard">>, <<"latency">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT requested_model, AVG(duration_ms)::int, "
        "PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration_ms)::int AS p99 "
        "FROM usage_logs WHERE duration_ms IS NOT NULL "
        "AND created_at > NOW() - INTERVAL '1 hour' "
        "GROUP BY requested_model") of
        {ok, _, Rows} ->
            Data = [#{model => M, avg_ms => A, p99_ms => P} || {M, A, P} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"GET">>, [<<"dashboard">>, <<"tokens">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT requested_model, SUM(input_tokens) AS input, SUM(output_tokens) AS output "
        "FROM usage_logs WHERE created_at > NOW() - INTERVAL '1 hour' "
        "GROUP BY requested_model ORDER BY (SUM(input_tokens)+SUM(output_tokens)) DESC LIMIT 10") of
        {ok, _, Rows} ->
            Data = [#{model => M, input => I, output => O} || {M, I, O} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"GET">>, [<<"dashboard">>, <<"models">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT requested_model, COUNT(*), COALESCE(SUM(actual_cost::numeric),0) "
        "FROM usage_logs WHERE created_at > NOW() - INTERVAL '24 hours' "
        "GROUP BY requested_model ORDER BY COUNT(*) DESC") of
        {ok, _, Rows} ->
            Data = [#{model => M, requests => binary_to_integer(C), cost => Co}
                    || {M, C, Co} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"GET">>, [<<"dashboard">>, <<"accounts">>], Req0, State) ->
    Running = ersub_platform_sup:list_accounts(),
    Data = lists:filtermap(fun(Id) ->
        try
            Stats = ersub_account_srv:get_stats(Id),
            {true, Stats}
        catch _:_ -> false
        end
    end, Running),
    {ok, reply_json(200, #{data => Data}, Req0), State};

%% === Alerts CRUD (T1-06) ===

handle(<<"GET">>, [<<"alerts">>, <<"rules">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, name, condition, severity, notify, cooldown_s, is_active, created_at "
        "FROM ops_alert_rules ORDER BY id") of
        {ok, _, Rows} ->
            Rules = [#{id => Id, name => N, condition => C, severity => S,
                       notify => No, cooldown_s => Co, is_active => A, created_at => CA}
                     || {Id, N, C, S, No, Co, A, CA} <- Rows],
            {ok, reply_json(200, #{data => Rules}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"alerts">>, <<"rules">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "INSERT INTO ops_alert_rules (name, condition, severity, notify, cooldown_s) "
        "VALUES ($1, $2, $3, $4, $5) RETURNING id",
        [maps:get(<<"name">>, P), jsx:encode(maps:get(<<"condition">>, P, #{})),
         maps:get(<<"severity">>, P, <<"warning">>),
         jsx:encode(maps:get(<<"notify">>, P, [<<"email">>])),
         maps:get(<<"cooldown_s">>, P, 300)]) of
        {ok, 1, _, [{Id}]} ->
            {ok, reply_json(201, #{data => #{id => Id}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

handle(<<"PUT">>, [<<"alerts">>, <<"rules">>, IdBin], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Id = binary_to_integer(IdBin),
    ersub_repo:query(
        "UPDATE ops_alert_rules SET name = COALESCE($2, name), "
        "severity = COALESCE($3, severity), is_active = COALESCE($4, is_active) "
        "WHERE id = $1",
        [Id, maps:get(<<"name">>, P, null),
         maps:get(<<"severity">>, P, null),
         maps:get(<<"is_active">>, P, null)]),
    {ok, reply_json(200, #{success => true}, Req1), State};

handle(<<"DELETE">>, [<<"alerts">>, <<"rules">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    ersub_repo:query("DELETE FROM ops_alert_rules WHERE id = $1", [Id]),
    {ok, reply_json(200, #{success => true}, Req0), State};

handle(<<"GET">>, [<<"alerts">>, <<"silences">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, rule_id, until, reason, created_at "
        "FROM ops_alert_silences WHERE until > NOW() ORDER BY id") of
        {ok, _, Rows} ->
            Data = [#{id => Id, rule_id => RId, until => U, reason => R, created_at => C}
                    || {Id, RId, U, R, C} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"alerts">>, <<"silences">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    ersub_repo:query(
        "INSERT INTO ops_alert_silences (rule_id, until, reason) VALUES ($1, $2, $3)",
        [maps:get(<<"rule_id">>, P), maps:get(<<"until">>, P), maps:get(<<"reason">>, P, null)]),
    {ok, reply_json(201, #{success => true}, Req1), State};

handle(<<"GET">>, [<<"logs">>], Req0, State) ->
    Limit = 100,
    case ersub_repo:query(
        "SELECT id, level, source, message, created_at "
        "FROM ops_system_logs ORDER BY created_at DESC LIMIT $1", [Limit]) of
        {ok, _, Rows} ->
            Data = [#{id => Id, level => L, source => S, message => M, created_at => C}
                    || {Id, L, S, M, C} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

%% === F01: Error Passthrough Rules CRUD ===

handle(<<"GET">>, [<<"error-passthrough-rules">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, name, status_codes, keywords, platform, action, sort_order, is_active "
        "FROM error_passthrough_rules ORDER BY sort_order ASC, id ASC") of
        {ok, _, Rows} ->
            Data = [#{id => Id, name => N, status_codes => SC, keywords => KW,
                      platform => P, action => A, sort_order => SO, is_active => IA}
                    || {Id, N, SC, KW, P, A, SO, IA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"error-passthrough-rules">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "INSERT INTO error_passthrough_rules (name, status_codes, keywords, platform, action, sort_order) "
        "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
        [maps:get(<<"name">>, P), maps:get(<<"status_codes">>, P, []),
         maps:get(<<"keywords">>, P, []), maps:get(<<"platform">>, P, null),
         maps:get(<<"action">>, P, <<"passthrough">>), maps:get(<<"sort_order">>, P, 0)]) of
        {ok, 1, _, [{Id}]} ->
            %% Reload CLIPS error_passthrough rules
            ersub_clips_pool:reload_rules(),
            {ok, reply_json(201, #{data => #{id => Id}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

handle(<<"PUT">>, [<<"error-passthrough-rules">>, IdBin], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Id = binary_to_integer(IdBin),
    ersub_repo:query(
        "UPDATE error_passthrough_rules SET name = COALESCE($2, name), "
        "is_active = COALESCE($3, is_active), sort_order = COALESCE($4, sort_order) WHERE id = $1",
        [Id, maps:get(<<"name">>, P, null), maps:get(<<"is_active">>, P, null),
         maps:get(<<"sort_order">>, P, null)]),
    ersub_clips_pool:reload_rules(),
    {ok, reply_json(200, #{success => true}, Req1), State};

handle(<<"DELETE">>, [<<"error-passthrough-rules">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    ersub_repo:query("DELETE FROM error_passthrough_rules WHERE id = $1", [Id]),
    ersub_clips_pool:reload_rules(),
    {ok, reply_json(200, #{success => true}, Req0), State};

%% === F02: Dashboard Snapshot V2 ===

handle(<<"GET">>, [<<"snapshot">>], Req0, State) ->
    Snapshot = ersub_dashboard_cache:get(ops_snapshot, fun() ->
        Summary = try ersub_metrics_srv:get_summary() catch _:_ -> #{} end,
        Health = try ersub_health_srv:get_score() catch _:_ -> #{score => 0} end,
        Accounts = length(ersub_platform_sup:list_accounts()),
        Children = length(supervisor:which_children(ersub_sup)),
        Throughput = case ersub_repo:squery(
            "SELECT date_trunc('minute', created_at) AS m, COUNT(*) "
            "FROM usage_logs WHERE created_at > NOW() - INTERVAL '1 hour' "
            "GROUP BY m ORDER BY m") of
            {ok, _, TRows} -> [#{minute => M, count => binary_to_integer(C)} || {M, C} <- TRows];
            _ -> []
        end,
        Errors = case ersub_repo:squery(
            "SELECT requested_model, COUNT(*) FROM usage_logs "
            "WHERE actual_cost = 0 AND created_at > NOW() - INTERVAL '1 hour' "
            "GROUP BY requested_model ORDER BY COUNT(*) DESC LIMIT 10") of
            {ok, _, ERows} -> [#{model => M, count => binary_to_integer(C)} || {M, C} <- ERows];
            _ -> []
        end,
        Models = case ersub_repo:squery(
            "SELECT requested_model, COUNT(*), COALESCE(SUM(actual_cost::numeric),0) "
            "FROM usage_logs WHERE created_at > NOW() - INTERVAL '24 hours' "
            "GROUP BY requested_model ORDER BY COUNT(*) DESC") of
            {ok, _, MRows} -> [#{model => M, requests => binary_to_integer(C), cost => Co}
                               || {M, C, Co} <- MRows];
            _ -> []
        end,
        #{
            health => Health,
            summary => Summary,
            active_accounts => Accounts,
            supervisor_children => Children,
            throughput => Throughput,
            errors => Errors,
            models => Models
        }
    end),
    {ok, reply_json(200, #{data => Snapshot}, Req0), State};

%% === F06: TLS Fingerprint Profile CRUD ===

handle(<<"GET">>, [<<"tls-profiles">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, name, ja3_hash, user_agent, is_active, created_at "
        "FROM tls_fingerprint_profiles ORDER BY id") of
        {ok, _, Rows} ->
            Data = [#{id => Id, name => N, ja3_hash => J, user_agent => UA,
                      is_active => IA, created_at => CA}
                    || {Id, N, J, UA, IA, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"tls-profiles">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "INSERT INTO tls_fingerprint_profiles (name, ja3_hash, user_agent, headers) "
        "VALUES ($1, $2, $3, $4) RETURNING id",
        [maps:get(<<"name">>, P), maps:get(<<"ja3_hash">>, P, null),
         maps:get(<<"user_agent">>, P, null),
         jsx:encode(maps:get(<<"headers">>, P, #{}))]) of
        {ok, 1, _, [{Id}]} ->
            {ok, reply_json(201, #{data => #{id => Id}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

handle(<<"GET">>, [<<"tls-profiles">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, name, ja3_hash, user_agent, headers, is_active, created_at "
        "FROM tls_fingerprint_profiles WHERE id = $1", [Id]) of
        {ok, _, [{TId, N, J, UA, H, IA, CA}]} ->
            {ok, reply_json(200, #{data => #{
                id => TId, name => N, ja3_hash => J, user_agent => UA,
                headers => H, is_active => IA, created_at => CA}}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        _ ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"tls-profiles">>, IdBin], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Id = binary_to_integer(IdBin),
    Headers = case maps:get(<<"headers">>, P, null) of
        null -> null;
        HV -> jsx:encode(HV)
    end,
    ersub_repo:query(
        "UPDATE tls_fingerprint_profiles SET "
        "name = COALESCE($2, name), "
        "ja3_hash = COALESCE($3, ja3_hash), "
        "user_agent = COALESCE($4, user_agent), "
        "headers = COALESCE($5::jsonb, headers), "
        "is_active = COALESCE($6, is_active) "
        "WHERE id = $1",
        [Id, maps:get(<<"name">>, P, null),
         maps:get(<<"ja3_hash">>, P, null),
         maps:get(<<"user_agent">>, P, null),
         Headers,
         maps:get(<<"is_active">>, P, null)]),
    {ok, reply_json(200, #{success => true}, Req1), State};

handle(<<"DELETE">>, [<<"tls-profiles">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    ersub_repo:query("DELETE FROM tls_fingerprint_profiles WHERE id = $1", [Id]),
    {ok, reply_json(200, #{success => true}, Req0), State};

%% === F16: Channel Monitor Templates CRUD ===

handle(<<"GET">>, [<<"channel-monitor-templates">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, name, method, path, headers, body, created_at "
        "FROM channel_monitor_request_templates ORDER BY id") of
        {ok, _, Rows} ->
            Data = [#{id => Id, name => N, method => M, path => Pa,
                      headers => H, body => B, created_at => CA}
                    || {Id, N, M, Pa, H, B, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"channel-monitor-templates">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "INSERT INTO channel_monitor_request_templates (name, method, path, headers, body) "
        "VALUES ($1, $2, $3, $4, $5) RETURNING id",
        [maps:get(<<"name">>, P), maps:get(<<"method">>, P, <<"POST">>),
         maps:get(<<"path">>, P), jsx:encode(maps:get(<<"headers">>, P, #{})),
         jsx:encode(maps:get(<<"body">>, P, #{}))]) of
        {ok, 1, _, [{Id}]} ->
            {ok, reply_json(201, #{data => #{id => Id}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

handle(<<"GET">>, [<<"channel-monitor-templates">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, name, method, path, headers, body, created_at "
        "FROM channel_monitor_request_templates WHERE id = $1", [Id]) of
        {ok, _, [{TId, N, M, Pa, H, B, CA}]} ->
            {ok, reply_json(200, #{data => #{
                id => TId, name => N, method => M, path => Pa,
                headers => H, body => B, created_at => CA}}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        _ ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"channel-monitor-templates">>, IdBin], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Id = binary_to_integer(IdBin),
    Headers = case maps:get(<<"headers">>, P, null) of
        null -> null;
        HV -> jsx:encode(HV)
    end,
    BodyJson = case maps:get(<<"body">>, P, null) of
        null -> null;
        BV -> jsx:encode(BV)
    end,
    ersub_repo:query(
        "UPDATE channel_monitor_request_templates SET "
        "name = COALESCE($2, name), "
        "method = COALESCE($3, method), "
        "path = COALESCE($4, path), "
        "headers = COALESCE($5::jsonb, headers), "
        "body = COALESCE($6::jsonb, body) "
        "WHERE id = $1",
        [Id, maps:get(<<"name">>, P, null),
         maps:get(<<"method">>, P, null),
         maps:get(<<"path">>, P, null),
         Headers, BodyJson]),
    {ok, reply_json(200, #{success => true}, Req1), State};

handle(<<"DELETE">>, [<<"channel-monitor-templates">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    ersub_repo:query("DELETE FROM channel_monitor_request_templates WHERE id = $1", [Id]),
    {ok, reply_json(200, #{success => true}, Req0), State};

handle(<<"POST">>, [<<"channel-monitor-templates">>, IdBin, <<"apply">>], Req0, State) ->
    _Id = binary_to_integer(IdBin),
    {ok, reply_json(200, #{success => true,
        note => <<"Monitors should reference this template_id directly">>}, Req0), State};

%% === F17: Scheduled Tests CRUD ===

handle(<<"GET">>, [<<"scheduled-tests">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, name, account_id, model, interval_s, timeout_ms, "
        "auto_recover, last_result, last_run_at, is_active "
        "FROM scheduled_tests ORDER BY id") of
        {ok, _, Rows} ->
            Data = [#{id => Id, name => N, account_id => AId, model => M,
                      interval_s => IS, timeout_ms => TM, auto_recover => AR,
                      last_result => LR, last_run_at => LRA, is_active => IA}
                    || {Id, N, AId, M, IS, TM, AR, LR, LRA, IA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"scheduled-tests">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "INSERT INTO scheduled_tests (name, account_id, model, test_prompt, interval_s, auto_recover) "
        "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
        [maps:get(<<"name">>, P), maps:get(<<"account_id">>, P),
         maps:get(<<"model">>, P), maps:get(<<"test_prompt">>, P, <<"hello">>),
         maps:get(<<"interval_s">>, P, 300), maps:get(<<"auto_recover">>, P, false)]) of
        {ok, 1, _, [{Id}]} ->
            {ok, reply_json(201, #{data => #{id => Id}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

handle(<<"PUT">>, [<<"scheduled-tests">>, IdBin], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Id = binary_to_integer(IdBin),
    ersub_repo:query(
        "UPDATE scheduled_tests SET "
        "name = COALESCE($2, name), "
        "model = COALESCE($3, model), "
        "test_prompt = COALESCE($4, test_prompt), "
        "interval_s = COALESCE($5, interval_s), "
        "auto_recover = COALESCE($6, auto_recover), "
        "is_active = COALESCE($7, is_active) "
        "WHERE id = $1",
        [Id, maps:get(<<"name">>, P, null),
         maps:get(<<"model">>, P, null),
         maps:get(<<"test_prompt">>, P, null),
         maps:get(<<"interval_s">>, P, null),
         maps:get(<<"auto_recover">>, P, null),
         maps:get(<<"is_active">>, P, null)]),
    {ok, reply_json(200, #{success => true}, Req1), State};

handle(<<"GET">>, [<<"scheduled-tests">>, IdBin, <<"results">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    TestInfo = case ersub_repo:query(
        "SELECT id, name, last_result, last_run_at "
        "FROM scheduled_tests WHERE id = $1", [Id]) of
        {ok, _, [{TId, N, LR, LRA}]} ->
            #{id => TId, name => N, last_result => LR, last_run_at => LRA};
        {ok, _, []} ->
            not_found;
        _ ->
            error
    end,
    case TestInfo of
        not_found ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        error ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State};
        Info ->
            RecentLogs = case ersub_repo:query(
                "SELECT id, level, source, message, created_at "
                "FROM ops_system_logs WHERE source = 'scheduled_test' "
                "AND message LIKE '%' || $1 || '%' "
                "ORDER BY created_at DESC LIMIT 20", [IdBin]) of
                {ok, _, LogRows} ->
                    [#{id => LId, level => Lv, source => Src,
                       message => Msg, created_at => CA}
                     || {LId, Lv, Src, Msg, CA} <- LogRows];
                _ -> []
            end,
            {ok, reply_json(200, #{data => #{test => Info, recent_logs => RecentLogs}}, Req0), State}
    end;

handle(<<"DELETE">>, [<<"scheduled-tests">>, IdBin], Req0, State) ->
    ersub_repo:query("DELETE FROM scheduled_tests WHERE id = $1", [binary_to_integer(IdBin)]),
    {ok, reply_json(200, #{success => true}, Req0), State};

%% === T4-08: Content Moderation Management ===

handle(<<"GET">>, [<<"moderation">>, <<"config">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT key, value FROM settings WHERE key LIKE 'moderation_%' ORDER BY key") of
        {ok, _, Rows} ->
            Config = maps:from_list([{K, jsx:decode(V, [return_maps])} || {K, V} <- Rows]),
            {ok, reply_json(200, #{data => Config}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => #{}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"moderation">>, <<"config">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Results = maps:fold(fun(Key, Value, Acc) ->
        FullKey = <<"moderation_", Key/binary>>,
        case ersub_repo:upsert_setting(FullKey, Value) of
            {ok, _} ->
                ersub_config_srv:set(binary_to_atom(FullKey), Value),
                Acc;
            {error, R} ->
                [{Key, R} | Acc]
        end
    end, [], Params),
    case Results of
        [] ->
            {ok, reply_json(200, #{success => true}, Req1), State};
        Errors ->
            ErrMap = maps:from_list([{K, iolist_to_binary(io_lib:format("~p", [R]))}
                                     || {K, R} <- Errors]),
            {ok, reply_json(400, #{error => #{message => <<"Some settings failed">>,
                                              details => ErrMap}}, Req1), State}
    end;

handle(<<"GET">>, [<<"moderation">>, <<"status">>], Req0, State) ->
    Mode = ersub_config_srv:get(moderation_mode, <<"off">>),
    SampleRate = ersub_config_srv:get(moderation_sample_rate, 100),
    {ok, reply_json(200, #{data => #{mode => Mode, sample_rate => SampleRate}}, Req0), State};

handle(<<"GET">>, [<<"moderation">>, <<"logs">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, user_id, request_id, content_hash, is_flagged, "
        "categories, action_taken, created_at "
        "FROM moderation_logs ORDER BY created_at DESC LIMIT 100") of
        {ok, _, Rows} ->
            Data = [#{id => Id, user_id => UId, request_id => RId,
                      content_hash => CH, is_flagged => F,
                      categories => Cat, action_taken => Act, created_at => CA}
                    || {Id, UId, RId, CH, F, Cat, Act, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"moderation">>, <<"users">>, UserIdBin, <<"unban">>], Req0, State) ->
    UserId = binary_to_integer(UserIdBin),
    ersub_repo:update_user(UserId, #{is_banned => false}),
    {ok, reply_json(200, #{success => true}, Req0), State};

%% === T4-14: Operations Error Tracking ===

handle(<<"GET">>, [<<"request-errors">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, request_id, user_id, account_id, platform, model, "
        "status_code, error_type, error_message, is_resolved, resolved_at, "
        "resolved_by, created_at "
        "FROM ops_request_errors ORDER BY created_at DESC LIMIT 100") of
        {ok, _, Rows} ->
            Data = [#{id => Id, request_id => RId, user_id => UID,
                      account_id => AId, platform => P, model => M,
                      status_code => SC, error_type => ET, error_message => EM,
                      is_resolved => IR, resolved_at => RA, resolved_by => RB,
                      created_at => CA}
                    || {Id, RId, UID, AId, P, M, SC, ET, EM, IR, RA, RB, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"GET">>, [<<"request-errors">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, request_id, user_id, account_id, platform, model, "
        "status_code, error_type, error_message, is_resolved, resolved_at, "
        "resolved_by, created_at "
        "FROM ops_request_errors WHERE id = $1", [Id]) of
        {ok, _, [{EId, RId, UID, AId, P, M, SC, ET, EM, IR, RA, RB, CA}]} ->
            {ok, reply_json(200, #{data => #{
                id => EId, request_id => RId, user_id => UID,
                account_id => AId, platform => P, model => M,
                status_code => SC, error_type => ET, error_message => EM,
                is_resolved => IR, resolved_at => RA, resolved_by => RB,
                created_at => CA}}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        _ ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State}
    end;

handle(<<"POST">>, [<<"request-errors">>, IdBin, <<"resolve">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE ops_request_errors SET is_resolved = TRUE, resolved_at = NOW() "
        "WHERE id = $1", [Id]) of
        {ok, 1} ->
            {ok, reply_json(200, #{success => true}, Req0), State};
        {ok, 0} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req0), State}
    end;

%% === T4-21: Usage Cleanup Task Management ===

handle(<<"GET">>, [<<"usage-cleanup-tasks">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT key, value FROM settings WHERE key LIKE 'cleanup_task_%' ORDER BY key") of
        {ok, _, Rows} ->
            Tasks = [#{key => K, value => jsx:decode(V, [return_maps])} || {K, V} <- Rows],
            {ok, reply_json(200, #{data => Tasks}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"usage-cleanup-tasks">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    RetentionDays = maps:get(<<"retention_days">>, Params, 90),
    Ts = integer_to_binary(erlang:system_time(second)),
    TaskKey = <<"cleanup_task_", Ts/binary>>,
    case ersub_repo:query(
        "DELETE FROM usage_logs WHERE created_at < NOW() - ($1 || ' days')::interval",
        [integer_to_binary(RetentionDays)]) of
        {ok, Deleted} ->
            TaskInfo = #{status => <<"completed">>, retention_days => RetentionDays,
                         deleted_count => Deleted, completed_at => Ts},
            ersub_repo:upsert_setting(TaskKey, TaskInfo),
            {ok, reply_json(200, #{data => #{task_key => TaskKey,
                                             deleted_count => Deleted}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

handle(<<"POST">>, [<<"usage-cleanup-tasks">>, IdBin, <<"cancel">>], Req0, State) ->
    TaskKey = <<"cleanup_task_", IdBin/binary>>,
    ersub_repo:query("DELETE FROM settings WHERE key = $1", [TaskKey]),
    {ok, reply_json(200, #{success => true}, Req0), State};

%% === T5-13: Channel Monitor Full CRUD ===

handle(<<"GET">>, [<<"channel-monitors">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, channel_id, check_interval_s, request_template_id, "
        "expected_status, timeout_ms, is_active, created_at "
        "FROM channel_monitors ORDER BY id") of
        {ok, _, Rows} ->
            Data = [#{id => Id, channel_id => ChId, check_interval_s => CIS,
                      request_template_id => RTId, expected_status => ES,
                      timeout_ms => TM, is_active => IA, created_at => CA}
                    || {Id, ChId, CIS, RTId, ES, TM, IA, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"channel-monitors">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    case ersub_repo:query(
        "INSERT INTO channel_monitors (channel_id, check_interval_s, "
        "request_template_id, expected_status, timeout_ms) "
        "VALUES ($1, $2, $3, $4, $5) RETURNING id",
        [maps:get(<<"channel_id">>, P),
         maps:get(<<"check_interval_s">>, P, 60),
         maps:get(<<"request_template_id">>, P, null),
         maps:get(<<"expected_status">>, P, 200),
         maps:get(<<"timeout_ms">>, P, 5000)]) of
        {ok, 1, _, [{Id}]} ->
            {ok, reply_json(201, #{data => #{id => Id}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

handle(<<"GET">>, [<<"channel-monitors">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, channel_id, check_interval_s, request_template_id, "
        "expected_status, timeout_ms, is_active, created_at "
        "FROM channel_monitors WHERE id = $1", [Id]) of
        {ok, _, [{MId, ChId, CIS, RTId, ES, TM, IA, CA}]} ->
            {ok, reply_json(200, #{data => #{
                id => MId, channel_id => ChId, check_interval_s => CIS,
                request_template_id => RTId, expected_status => ES,
                timeout_ms => TM, is_active => IA, created_at => CA}}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        _ ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"channel-monitors">>, IdBin], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Id = binary_to_integer(IdBin),
    ersub_repo:query(
        "UPDATE channel_monitors SET "
        "channel_id = COALESCE($2, channel_id), "
        "check_interval_s = COALESCE($3, check_interval_s), "
        "request_template_id = COALESCE($4, request_template_id), "
        "expected_status = COALESCE($5, expected_status), "
        "timeout_ms = COALESCE($6, timeout_ms), "
        "is_active = COALESCE($7, is_active) "
        "WHERE id = $1",
        [Id, maps:get(<<"channel_id">>, P, null),
         maps:get(<<"check_interval_s">>, P, null),
         maps:get(<<"request_template_id">>, P, null),
         maps:get(<<"expected_status">>, P, null),
         maps:get(<<"timeout_ms">>, P, null),
         maps:get(<<"is_active">>, P, null)]),
    {ok, reply_json(200, #{success => true}, Req1), State};

handle(<<"DELETE">>, [<<"channel-monitors">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    ersub_repo:query("DELETE FROM channel_monitors WHERE id = $1", [Id]),
    {ok, reply_json(200, #{success => true}, Req0), State};

handle(<<"POST">>, [<<"channel-monitors">>, IdBin, <<"run">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    ersub_channel_monitor:check_now(Id),
    {ok, reply_json(200, #{data => #{triggered => true, monitor_id => Id}}, Req0), State};

handle(<<"GET">>, [<<"channel-monitors">>, IdBin, <<"history">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, status_code, latency_ms, is_success, error_message, checked_at "
        "FROM channel_monitor_histories WHERE monitor_id = $1 "
        "ORDER BY checked_at DESC LIMIT 50", [Id]) of
        {ok, _, Rows} ->
            Data = [#{id => HId, status_code => SC, latency_ms => LM,
                      is_success => IS, error_message => EM, checked_at => ChAt}
                    || {HId, SC, LM, IS, EM, ChAt} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

%% === T5-15: Dashboard Advanced Endpoints ===

handle(<<"GET">>, [<<"dashboard">>, <<"realtime">>], Req0, State) ->
    %% Fresh data, no cache
    Summary = try ersub_metrics_srv:get_summary() catch _:_ -> #{} end,
    Health = try ersub_health_srv:get_score() catch _:_ -> #{score => 0} end,
    Accounts = length(ersub_platform_sup:list_accounts()),
    Running = ersub_platform_sup:list_accounts(),
    AccountData = lists:filtermap(fun(AccId) ->
        try
            Stats = ersub_account_srv:get_stats(AccId),
            {true, Stats}
        catch _:_ -> false
        end
    end, Running),
    {ok, reply_json(200, #{data => #{
        health => Health,
        summary => Summary,
        active_accounts => Accounts,
        accounts => AccountData
    }}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"groups">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_groups, fun() ->
        case ersub_repo:squery(
            "SELECT g.id, g.name, COUNT(*) as requests, "
            "COALESCE(SUM(ul.actual_cost::numeric),0) as cost "
            "FROM usage_logs ul "
            "JOIN accounts a ON a.id = ul.account_id "
            "JOIN account_groups ag ON ag.account_id = a.id "
            "JOIN groups g ON g.id = ag.group_id "
            "WHERE ul.created_at > NOW() - INTERVAL '24 hours' "
            "GROUP BY g.id, g.name ORDER BY requests DESC") of
            {ok, _, Rows} ->
                [#{id => Id, name => N, requests => binary_to_integer(Req),
                   cost => Co} || {Id, N, Req, Co} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"users-trend">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_users_trend, fun() ->
        case ersub_repo:squery(
            "SELECT date_trunc('day', created_at) AS day, "
            "COUNT(DISTINCT user_id) "
            "FROM usage_logs "
            "WHERE created_at > NOW() - INTERVAL '30 days' "
            "GROUP BY day ORDER BY day") of
            {ok, _, Rows} ->
                [#{day => D, users => binary_to_integer(C)} || {D, C} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"users-ranking">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_users_ranking, fun() ->
        case ersub_repo:squery(
            "SELECT ul.user_id, u.email, COUNT(*) as requests, "
            "COALESCE(SUM(ul.actual_cost::numeric),0) as cost "
            "FROM usage_logs ul "
            "JOIN users u ON u.id = ul.user_id "
            "WHERE ul.created_at > NOW() - INTERVAL '24 hours' "
            "GROUP BY ul.user_id, u.email "
            "ORDER BY cost DESC LIMIT 20") of
            {ok, _, Rows} ->
                [#{user_id => UID, email => E, requests => binary_to_integer(Req),
                   cost => Co} || {UID, E, Req, Co} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"api-keys-trend">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_api_keys_trend, fun() ->
        case ersub_repo:squery(
            "SELECT date_trunc('day', created_at) AS day, COUNT(*) "
            "FROM api_keys "
            "WHERE created_at > NOW() - INTERVAL '30 days' "
            "GROUP BY day ORDER BY day") of
            {ok, _, Rows} ->
                [#{day => D, count => binary_to_integer(C)} || {D, C} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

%% === T5-16: Ops Realtime Signals ===

handle(<<"GET">>, [<<"concurrency">>], Req0, State) ->
    Stats = try
        ActiveSlots = ets:info(ersub_conc_slots, size),
        UserCounts = ets:tab2list(ersub_conc_counts),
        TotalActive = lists:foldl(fun({_, C}, Acc) -> Acc + C end, 0, UserCounts),
        #{active_slots => ActiveSlots, total_active => TotalActive,
          unique_users => length(UserCounts)}
    catch _:_ ->
        #{active_slots => 0, total_active => 0, unique_users => 0}
    end,
    {ok, reply_json(200, #{data => Stats}, Req0), State};

handle(<<"GET">>, [<<"user-concurrency">>], Req0, State) ->
    Stats = try
        UserCounts = ets:tab2list(ersub_conc_counts),
        [#{user_id => UID, active => C} || {UID, C} <- UserCounts]
    catch _:_ -> []
    end,
    {ok, reply_json(200, #{data => Stats}, Req0), State};

handle(<<"GET">>, [<<"account-availability">>], Req0, State) ->
    Running = ersub_platform_sup:list_accounts(),
    Data = lists:filtermap(fun(AccId) ->
        try
            Stats = ersub_account_srv:get_stats(AccId),
            {true, Stats}
        catch _:_ -> false
        end
    end, Running),
    {ok, reply_json(200, #{data => Data}, Req0), State};

handle(<<"GET">>, [<<"realtime-traffic">>], Req0, State) ->
    Summary = try ersub_metrics_srv:get_summary() catch _:_ -> #{} end,
    {ok, reply_json(200, #{data => #{
        realtime => true,
        timestamp => erlang:system_time(second),
        metrics => Summary
    }}, Req0), State};

%% === T5-17: Ops Error Management Enhancement ===

handle(<<"GET">>, [<<"upstream-errors">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, request_id, user_id, account_id, platform, model, "
        "status_code, error_type, error_message, is_resolved, resolved_at, "
        "resolved_by, created_at "
        "FROM ops_request_errors WHERE error_type = 'upstream' "
        "ORDER BY created_at DESC LIMIT 100") of
        {ok, _, Rows} ->
            Data = [#{id => Id, request_id => RId, user_id => UID,
                      account_id => AId, platform => P, model => M,
                      status_code => SC, error_type => ET, error_message => EM,
                      is_resolved => IR, resolved_at => RA, resolved_by => RB,
                      created_at => CA}
                    || {Id, RId, UID, AId, P, M, SC, ET, EM, IR, RA, RB, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"request-errors">>, IdBin, <<"retry">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE ops_request_errors SET is_resolved = FALSE, resolved_at = NULL "
        "WHERE id = $1", [Id]) of
        {ok, 1} ->
            {ok, reply_json(200, #{success => true}, Req0), State};
        {ok, 0} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req0), State}
    end;

handle(<<"GET">>, [<<"system-logs">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, level, source, message, metadata, created_at "
        "FROM ops_system_logs ORDER BY created_at DESC LIMIT 200") of
        {ok, _, Rows} ->
            Data = [#{id => Id, level => L, source => S, message => M,
                      metadata => Meta, created_at => CA}
                    || {Id, L, S, M, Meta, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"system-logs">>, <<"cleanup">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Days = maps:get(<<"older_than_days">>, P, 30),
    case ersub_repo:query(
        "DELETE FROM ops_system_logs WHERE created_at < NOW() - ($1 || ' days')::interval",
        [integer_to_binary(Days)]) of
        {ok, Deleted} ->
            {ok, reply_json(200, #{data => #{deleted_count => Deleted}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

%% === T5-20: Ops Runtime Settings ===

handle(<<"GET">>, [<<"runtime">>, <<"alert">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT key, value FROM settings WHERE key LIKE 'ops_alert_%' ORDER BY key") of
        {ok, _, Rows} ->
            Config = maps:from_list([{K, jsx:decode(V, [return_maps])} || {K, V} <- Rows]),
            {ok, reply_json(200, #{data => Config}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => #{}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"runtime">>, <<"alert">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Results = maps:fold(fun(Key, Value, Acc) ->
        FullKey = <<"ops_alert_", Key/binary>>,
        case ersub_repo:upsert_setting(FullKey, Value) of
            {ok, _} ->
                ersub_config_srv:set(binary_to_atom(FullKey), Value),
                Acc;
            {error, R} ->
                [{Key, R} | Acc]
        end
    end, [], Params),
    case Results of
        [] ->
            {ok, reply_json(200, #{success => true}, Req1), State};
        Errors ->
            ErrMap = maps:from_list([{K, iolist_to_binary(io_lib:format("~p", [R]))}
                                     || {K, R} <- Errors]),
            {ok, reply_json(400, #{error => #{message => <<"Some settings failed">>,
                                              details => ErrMap}}, Req1), State}
    end;

handle(<<"GET">>, [<<"runtime">>, <<"logging">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT key, value FROM settings WHERE key LIKE 'ops_logging_%' ORDER BY key") of
        {ok, _, Rows} ->
            Config = maps:from_list([{K, jsx:decode(V, [return_maps])} || {K, V} <- Rows]),
            {ok, reply_json(200, #{data => Config}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => #{}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"runtime">>, <<"logging">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Results = maps:fold(fun(Key, Value, Acc) ->
        FullKey = <<"ops_logging_", Key/binary>>,
        case ersub_repo:upsert_setting(FullKey, Value) of
            {ok, _} ->
                ersub_config_srv:set(binary_to_atom(FullKey), Value),
                Acc;
            {error, R} ->
                [{Key, R} | Acc]
        end
    end, [], Params),
    case Results of
        [] ->
            {ok, reply_json(200, #{success => true}, Req1), State};
        Errors ->
            ErrMap = maps:from_list([{K, iolist_to_binary(io_lib:format("~p", [R]))}
                                     || {K, R} <- Errors]),
            {ok, reply_json(400, #{error => #{message => <<"Some settings failed">>,
                                              details => ErrMap}}, Req1), State}
    end;

handle(<<"POST">>, [<<"runtime">>, <<"logging">>, <<"reset">>], Req0, State) ->
    case ersub_repo:squery(
        "DELETE FROM settings WHERE key LIKE 'ops_logging_%'") of
        {ok, _, _} ->
            {ok, reply_json(200, #{success => true}, Req0), State};
        {ok, _} ->
            {ok, reply_json(200, #{success => true}, Req0), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req0), State}
    end;

handle(<<"GET">>, [<<"advanced-settings">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT key, value FROM settings WHERE key LIKE 'advanced_%' ORDER BY key") of
        {ok, _, Rows} ->
            Config = maps:from_list([{K, jsx:decode(V, [return_maps])} || {K, V} <- Rows]),
            {ok, reply_json(200, #{data => Config}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => #{}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"advanced-settings">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Results = maps:fold(fun(Key, Value, Acc) ->
        FullKey = <<"advanced_", Key/binary>>,
        case ersub_repo:upsert_setting(FullKey, Value) of
            {ok, _} ->
                ersub_config_srv:set(binary_to_atom(FullKey), Value),
                Acc;
            {error, R} ->
                [{Key, R} | Acc]
        end
    end, [], Params),
    case Results of
        [] ->
            {ok, reply_json(200, #{success => true}, Req1), State};
        Errors ->
            ErrMap = maps:from_list([{K, iolist_to_binary(io_lib:format("~p", [R]))}
                                     || {K, R} <- Errors]),
            {ok, reply_json(400, #{error => #{message => <<"Some settings failed">>,
                                              details => ErrMap}}, Req1), State}
    end;

%% === T6-05: Ops Alert Events ===

handle(<<"GET">>, [<<"alert-events">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, level, source, message, metadata, created_at "
        "FROM ops_system_logs WHERE source LIKE '%alert%' "
        "ORDER BY created_at DESC LIMIT 100") of
        {ok, _, Rows} ->
            Data = [#{id => Id, level => L, source => S, message => M,
                      metadata => Meta, created_at => CA}
                    || {Id, L, S, M, Meta, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"GET">>, [<<"alert-events">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, level, source, message, metadata, created_at "
        "FROM ops_system_logs WHERE id = $1", [Id]) of
        {ok, _, [{EId, L, S, M, Meta, CA}]} ->
            {ok, reply_json(200, #{data => #{
                id => EId, level => L, source => S, message => M,
                metadata => Meta, created_at => CA}}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        _ ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"alert-events">>, IdBin, <<"status">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Id = binary_to_integer(IdBin),
    Status = maps:get(<<"status">>, P, <<"acknowledged">>),
    StatusJson = jsx:encode(#{<<"status">> => Status}),
    case ersub_repo:query(
        "UPDATE ops_system_logs SET metadata = COALESCE(metadata, '{}') || $2::jsonb "
        "WHERE id = $1", [Id, StatusJson]) of
        {ok, 1} ->
            {ok, reply_json(200, #{success => true}, Req1), State};
        {ok, 0} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

%% === T6-06: Ops Dashboard vNext ===

handle(<<"GET">>, [<<"dashboard">>, <<"overview">>], Req0, State) ->
    Overview = ersub_dashboard_cache:get(ops_dashboard_overview, fun() ->
        TotalRequests24h = case ersub_repo:squery(
            "SELECT COUNT(*) FROM usage_logs "
            "WHERE created_at > NOW() - INTERVAL '24 hours'") of
            {ok, _, [{V}]} -> binary_to_integer(V);
            _ -> 0
        end,
        TotalCost24h = case ersub_repo:squery(
            "SELECT COALESCE(SUM(actual_cost::numeric),0) FROM usage_logs "
            "WHERE created_at > NOW() - INTERVAL '24 hours'") of
            {ok, _, [{V2}]} -> V2;
            _ -> <<"0">>
        end,
        ActiveAccounts = case ersub_repo:squery(
            "SELECT COUNT(*) FROM accounts WHERE is_active = true") of
            {ok, _, [{V3}]} -> binary_to_integer(V3);
            _ -> 0
        end,
        ActiveUsers24h = case ersub_repo:squery(
            "SELECT COUNT(DISTINCT user_id) FROM usage_logs "
            "WHERE created_at > NOW() - INTERVAL '24 hours'") of
            {ok, _, [{V4}]} -> binary_to_integer(V4);
            _ -> 0
        end,
        ErrorRate1h = case ersub_repo:squery(
            "SELECT COUNT(*) FILTER (WHERE actual_cost = 0)::float / "
            "GREATEST(COUNT(*), 1) * 100 "
            "FROM usage_logs WHERE created_at > NOW() - INTERVAL '1 hour'") of
            {ok, _, [{V5}]} -> V5;
            _ -> <<"0">>
        end,
        #{
            total_requests_24h => TotalRequests24h,
            total_cost_24h => TotalCost24h,
            active_accounts => ActiveAccounts,
            active_users_24h => ActiveUsers24h,
            error_rate_1h => ErrorRate1h
        }
    end),
    {ok, reply_json(200, #{data => Overview}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"throughput-trend">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_throughput_trend, fun() ->
        case ersub_repo:squery(
            "SELECT date_trunc('hour', created_at) AS hour, COUNT(*) "
            "FROM usage_logs WHERE created_at > NOW() - INTERVAL '24 hours' "
            "GROUP BY hour ORDER BY hour") of
            {ok, _, Rows} ->
                [#{hour => H, count => binary_to_integer(C)} || {H, C} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"latency-histogram">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_latency_histogram, fun() ->
        case ersub_repo:squery(
            "SELECT CASE "
            "WHEN duration_ms < 100 THEN '<100ms' "
            "WHEN duration_ms < 500 THEN '100-500ms' "
            "WHEN duration_ms < 1000 THEN '500-1000ms' "
            "WHEN duration_ms < 5000 THEN '1-5s' "
            "ELSE '>5s' END AS bucket, COUNT(*) "
            "FROM usage_logs WHERE duration_ms IS NOT NULL "
            "AND created_at > NOW() - INTERVAL '1 hour' "
            "GROUP BY bucket") of
            {ok, _, Rows} ->
                [#{bucket => B, count => binary_to_integer(C)} || {B, C} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"error-trend">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_error_trend, fun() ->
        case ersub_repo:squery(
            "SELECT date_trunc('hour', created_at) AS hour, COUNT(*) "
            "FROM ops_request_errors "
            "WHERE created_at > NOW() - INTERVAL '24 hours' "
            "GROUP BY hour ORDER BY hour") of
            {ok, _, Rows} ->
                [#{hour => H, count => binary_to_integer(C)} || {H, C} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

handle(<<"GET">>, [<<"dashboard">>, <<"error-distribution">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_error_distribution, fun() ->
        case ersub_repo:squery(
            "SELECT COALESCE(error_type, 'unknown') AS type, "
            "status_code, COUNT(*) "
            "FROM ops_request_errors "
            "WHERE created_at > NOW() - INTERVAL '24 hours' "
            "GROUP BY type, status_code "
            "ORDER BY COUNT(*) DESC LIMIT 20") of
            {ok, _, Rows} ->
                [#{type => T, status_code => SC, count => binary_to_integer(C)}
                 || {T, SC, C} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

%% === T6-13: Ops Email Notification Config ===

handle(<<"GET">>, [<<"email-notification">>, <<"config">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT key, value FROM settings WHERE key LIKE 'ops_email_%' ORDER BY key") of
        {ok, _, Rows} ->
            Config = maps:from_list([{K, jsx:decode(V, [return_maps])} || {K, V} <- Rows]),
            {ok, reply_json(200, #{data => Config}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => #{}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"email-notification">>, <<"config">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Results = maps:fold(fun(Key, Value, Acc) ->
        FullKey = <<"ops_email_", Key/binary>>,
        case ersub_repo:upsert_setting(FullKey, Value) of
            {ok, _} ->
                ersub_config_srv:set(binary_to_atom(FullKey), Value),
                Acc;
            {error, R} ->
                [{Key, R} | Acc]
        end
    end, [], Params),
    case Results of
        [] ->
            {ok, reply_json(200, #{success => true}, Req1), State};
        Errors ->
            ErrMap = maps:from_list([{K, iolist_to_binary(io_lib:format("~p", [R]))}
                                     || {K, R} <- Errors]),
            {ok, reply_json(400, #{error => #{message => <<"Some settings failed">>,
                                              details => ErrMap}}, Req1), State}
    end;

%% === T6-13: Metric Thresholds ===

handle(<<"GET">>, [<<"settings">>, <<"metric-thresholds">>], Req0, State) ->
    case ersub_repo:query(
        "SELECT value FROM settings WHERE key = $1",
        [<<"ops_metric_thresholds">>]) of
        {ok, _, [{V}]} ->
            {ok, reply_json(200, #{data => jsx:decode(V, [return_maps])}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(200, #{data => #{}}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => #{}}, Req0), State}
    end;

handle(<<"PUT">>, [<<"settings">>, <<"metric-thresholds">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    case ersub_repo:upsert_setting(<<"ops_metric_thresholds">>, Params) of
        {ok, _} ->
            ersub_config_srv:set(ops_metric_thresholds, Params),
            {ok, reply_json(200, #{success => true}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

%% === T6-14: Dashboard Batch Queries ===

handle(<<"POST">>, [<<"dashboard">>, <<"users-usage">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    UserIds = maps:get(<<"user_ids">>, P, []),
    Data = lists:foldl(fun(UID, Acc) ->
        UIdInt = case is_integer(UID) of true -> UID; false -> binary_to_integer(UID) end,
        case ersub_repo:query(
            "SELECT COUNT(*), COALESCE(SUM(actual_cost::numeric),0) "
            "FROM usage_logs WHERE user_id = $1 "
            "AND created_at > NOW() - INTERVAL '24 hours'",
            [UIdInt]) of
            {ok, _, [{Cnt, Cost}]} ->
                Acc#{integer_to_binary(UIdInt) => #{requests => binary_to_integer(Cnt), cost => Cost}};
            _ ->
                Acc#{integer_to_binary(UIdInt) => #{requests => 0, cost => <<"0">>}}
        end
    end, #{}, UserIds),
    {ok, reply_json(200, #{data => Data}, Req1), State};

handle(<<"POST">>, [<<"dashboard">>, <<"api-keys-usage">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    KeyIds = maps:get(<<"key_ids">>, P, []),
    Data = lists:foldl(fun(KID, Acc) ->
        KIdInt = case is_integer(KID) of true -> KID; false -> binary_to_integer(KID) end,
        case ersub_repo:query(
            "SELECT COUNT(*), COALESCE(SUM(ul.actual_cost::numeric),0) "
            "FROM usage_logs ul "
            "JOIN api_keys ak ON ak.id = ul.api_key_id "
            "WHERE ak.id = $1 "
            "AND ul.created_at > NOW() - INTERVAL '24 hours'",
            [KIdInt]) of
            {ok, _, [{Cnt, Cost}]} ->
                Acc#{integer_to_binary(KIdInt) => #{requests => binary_to_integer(Cnt), cost => Cost}};
            _ ->
                Acc#{integer_to_binary(KIdInt) => #{requests => 0, cost => <<"0">>}}
        end
    end, #{}, KeyIds),
    {ok, reply_json(200, #{data => Data}, Req1), State};

handle(<<"GET">>, [<<"dashboard">>, <<"user-breakdown">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT u.email, COUNT(*), SUM(actual_cost::numeric) "
        "FROM usage_logs ul "
        "JOIN users u ON u.id = ul.user_id "
        "WHERE ul.created_at > NOW() - INTERVAL '24 hours' "
        "GROUP BY u.email ORDER BY COUNT(*) DESC LIMIT 50") of
        {ok, _, Rows} ->
            Data = [#{email => E, requests => binary_to_integer(C), cost => Co}
                    || {E, C, Co} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(<<"POST">>, [<<"dashboard">>, <<"aggregation">>, <<"backfill">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    From = maps:get(<<"from">>, P),
    To = maps:get(<<"to">>, P),
    case ersub_repo:query(
        "INSERT INTO metrics_aggregated (period, metric_key, metric_value, recorded_at) "
        "SELECT 'day', requested_model, COUNT(*)::text, date_trunc('day', created_at) "
        "FROM usage_logs "
        "WHERE created_at BETWEEN $1::timestamp AND $2::timestamp "
        "GROUP BY requested_model, date_trunc('day', created_at) "
        "ON CONFLICT DO NOTHING",
        [From, To]) of
        {ok, Inserted} ->
            {ok, reply_json(200, #{success => true, inserted => Inserted}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

%% === T6-17: Channel Monitor Template Monitors ===

handle(<<"GET">>, [<<"channel-monitor-templates">>, IdBin, <<"monitors">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, channel_id, check_interval_s, request_template_id, "
        "expected_status, timeout_ms, is_active, created_at "
        "FROM channel_monitors WHERE request_template_id = $1 ORDER BY id",
        [Id]) of
        {ok, _, Rows} ->
            Data = [#{id => MId, channel_id => ChId, check_interval_s => CIS,
                      request_template_id => RTId, expected_status => ES,
                      timeout_ms => TM, is_active => IA, created_at => CA}
                    || {MId, ChId, CIS, RTId, ES, TM, IA, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

%% === T6-17: System Logs Health ===

handle(<<"GET">>, [<<"system-logs">>, <<"health">>], Req0, State) ->
    LogCount = case ersub_repo:squery(
        "SELECT COUNT(*) FROM ops_system_logs "
        "WHERE created_at > NOW() - INTERVAL '1 hour'") of
        {ok, _, [{V}]} -> binary_to_integer(V);
        _ -> 0
    end,
    OldestUnprocessed = case ersub_repo:squery(
        "SELECT MIN(created_at) FROM ops_system_logs "
        "WHERE metadata IS NULL OR metadata->>'processed' IS NULL") of
        {ok, _, [{null}]} -> null;
        {ok, _, [{V2}]} -> V2;
        _ -> null
    end,
    {ok, reply_json(200, #{data => #{
        logs_last_hour => LogCount,
        oldest_unprocessed => OldestUnprocessed
    }}, Req0), State};

%% === T7-06: OpenAI Token Stats ===

handle(<<"GET">>, [<<"dashboard">>, <<"openai-token-stats">>], Req0, State) ->
    Result = ersub_dashboard_cache:get(ops_dashboard_openai_token_stats, fun() ->
        case ersub_repo:squery(
            "SELECT requested_model, SUM(input_tokens) as input, "
            "SUM(output_tokens) as output, COUNT(*) as requests "
            "FROM usage_logs "
            "WHERE (requested_model LIKE 'gpt%' OR requested_model LIKE 'o1%' "
            "OR requested_model LIKE 'o3%') "
            "AND created_at > NOW() - INTERVAL '24 hours' "
            "GROUP BY requested_model ORDER BY requests DESC") of
            {ok, _, Rows} ->
                [#{model => M, input_tokens => I, output_tokens => O,
                   requests => binary_to_integer(R)}
                 || {M, I, O, R} <- Rows];
            _ -> []
        end
    end),
    {ok, reply_json(200, #{data => Result}, Req0), State};

%% === T7-09: Risk Control Extension ===

%% POST /api/v1/admin/ops/moderation/api-keys/test — Test moderation API key
handle(<<"POST">>, [<<"moderation">>, <<"api-keys">>, <<"test">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    ApiKey = maps:get(<<"api_key">>, P, <<>>),
    %% Validate key format: non-empty, reasonable length
    Valid = byte_size(ApiKey) > 10 andalso byte_size(ApiKey) < 256,
    {ok, reply_json(200, #{data => #{valid => Valid}}, Req1), State};

%% DELETE /api/v1/admin/ops/moderation/hashes/all — Truncate all flagged hashes
handle(<<"DELETE">>, [<<"moderation">>, <<"hashes">>, <<"all">>], Req0, State) ->
    case ersub_repo:squery(
        "DELETE FROM moderation_logs WHERE is_flagged = TRUE") of
        {ok, Deleted} ->
            {ok, reply_json(200, #{data => #{deleted_count => Deleted}}, Req0), State};
        {ok, _, _} ->
            {ok, reply_json(200, #{data => #{deleted_count => 0}}, Req0), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req0), State}
    end;

%% DELETE /api/v1/admin/ops/moderation/hashes — Delete specific flagged hash
handle(<<"DELETE">>, [<<"moderation">>, <<"hashes">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    P = jsx:decode(Body, [return_maps]),
    Hash = maps:get(<<"hash">>, P, <<>>),
    case ersub_repo:query(
        "DELETE FROM moderation_logs WHERE content_hash = $1", [Hash]) of
        {ok, Deleted} ->
            {ok, reply_json(200, #{data => #{deleted_count => Deleted}}, Req1), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req1), State}
    end;

%% === Legacy Error Logs (sub2api compat) ===

%% GET /api/v1/admin/ops/errors — Legacy error log list
handle(<<"GET">>, [<<"errors">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, request_id, user_id, account_id, platform, model, "
        "status_code, error_type, error_message, is_resolved, created_at "
        "FROM ops_request_errors ORDER BY created_at DESC LIMIT 100") of
        {ok, _, Rows} ->
            Data = [#{id => Id, request_id => RId, user_id => UID,
                      account_id => AId, platform => P, model => M,
                      status_code => SC, error_type => ET, error_message => EM,
                      is_resolved => IR, created_at => CA}
                    || {Id, RId, UID, AId, P, M, SC, ET, EM, IR, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

%% GET /api/v1/admin/ops/errors/:id — Legacy error detail
handle(<<"GET">>, [<<"errors">>, IdBin], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, request_id, user_id, account_id, platform, model, "
        "status_code, error_type, error_message, is_resolved, resolved_at, "
        "resolved_by, created_at "
        "FROM ops_request_errors WHERE id = $1", [Id]) of
        {ok, _, [{EId, RId, UID, AId, P, M, SC, ET, EM, IR, RA, RB, CA}]} ->
            {ok, reply_json(200, #{data => #{
                id => EId, request_id => RId, user_id => UID,
                account_id => AId, platform => P, model => M,
                status_code => SC, error_type => ET, error_message => EM,
                is_resolved => IR, resolved_at => RA, resolved_by => RB,
                created_at => CA}}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        _ ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State}
    end;

%% GET /api/v1/admin/ops/errors/:id/retries — Retry history (from system logs)
handle(<<"GET">>, [<<"errors">>, IdBin, <<"retries">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, level, source, message, created_at FROM ops_system_logs "
        "WHERE source = 'error_retry' AND message LIKE '%' || $1 || '%' "
        "ORDER BY created_at DESC LIMIT 20",
        [integer_to_binary(Id)]) of
        {ok, _, Rows} ->
            Data = [#{id => LId, level => L, source => S, message => Msg, created_at => CA}
                    || {LId, L, S, Msg, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

%% POST /api/v1/admin/ops/errors/:id/retry — Retry a failed request
handle(<<"POST">>, [<<"errors">>, IdBin, <<"retry">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    %% Mark as unresolved for re-processing, log the retry attempt
    ersub_repo:query(
        "UPDATE ops_request_errors SET is_resolved = FALSE, resolved_at = NULL WHERE id = $1", [Id]),
    ersub_repo:query(
        "INSERT INTO ops_system_logs (level, source, message) VALUES ('info', 'error_retry', $1)",
        [iolist_to_binary([<<"Retry requested for error ">>, integer_to_binary(Id)])]),
    {ok, reply_json(200, #{success => true}, Req0), State};

%% PUT /api/v1/admin/ops/errors/:id/resolve — Resolve legacy error
handle(<<"PUT">>, [<<"errors">>, IdBin, <<"resolve">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    case ersub_repo:query(
        "UPDATE ops_request_errors SET is_resolved = TRUE, resolved_at = NOW() WHERE id = $1", [Id]) of
        {ok, 1} ->
            {ok, reply_json(200, #{success => true}, Req0), State};
        {ok, 0} ->
            {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State};
        {error, R} ->
            {ok, reply_json(500, #{error => #{message => fmt(R)}}, Req0), State}
    end;

%% GET /api/v1/admin/ops/request-errors/:id/upstream-errors — Upstream errors for a request
handle(<<"GET">>, [<<"request-errors">>, IdBin, <<"upstream-errors">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    %% Get the request_id from the error, then find related upstream errors
    case ersub_repo:query(
        "SELECT request_id FROM ops_request_errors WHERE id = $1", [Id]) of
        {ok, _, [{RequestId}]} ->
            case ersub_repo:query(
                "SELECT id, request_id, account_id, platform, status_code, "
                "error_type, error_message, created_at "
                "FROM ops_request_errors WHERE request_id = $1 AND error_type = 'upstream' "
                "ORDER BY created_at", [RequestId]) of
                {ok, _, Rows} ->
                    Data = [#{id => EId, request_id => RId, account_id => AId,
                              platform => P, status_code => SC, error_type => ET,
                              error_message => EM, created_at => CA}
                            || {EId, RId, AId, P, SC, ET, EM, CA} <- Rows],
                    {ok, reply_json(200, #{data => Data}, Req0), State};
                _ ->
                    {ok, reply_json(200, #{data => []}, Req0), State}
            end;
        _ ->
            {ok, reply_json(404, #{error => #{message => <<"Error not found">>}}, Req0), State}
    end;

%% POST /api/v1/admin/ops/request-errors/:id/retry-client — Retry from client perspective
handle(<<"POST">>, [<<"request-errors">>, IdBin, <<"retry-client">>], Req0, State) ->
    Id = binary_to_integer(IdBin),
    ersub_repo:query(
        "UPDATE ops_request_errors SET is_resolved = FALSE, resolved_at = NULL WHERE id = $1", [Id]),
    ersub_repo:query(
        "INSERT INTO ops_system_logs (level, source, message) VALUES ('info', 'error_retry', $1)",
        [iolist_to_binary([<<"Client retry for error ">>, integer_to_binary(Id)])]),
    {ok, reply_json(200, #{success => true}, Req0), State};

%% GET /api/v1/admin/ops/requests — Request drilldown (recent requests)
handle(<<"GET">>, [<<"requests">>], Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, request_id, user_id, requested_model, input_tokens, "
        "output_tokens, actual_cost, stream, duration_ms, first_token_ms, "
        "created_at FROM usage_logs ORDER BY created_at DESC LIMIT 50") of
        {ok, _, Rows} ->
            Data = [#{id => LId, request_id => RId, user_id => UID,
                      model => M, input_tokens => IT, output_tokens => OT,
                      cost => C, stream => S, duration_ms => D,
                      first_token_ms => FT, created_at => CA}
                    || {LId, RId, UID, M, IT, OT, C, S, D, FT, CA} <- Rows],
            {ok, reply_json(200, #{data => Data}, Req0), State};
        _ ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

handle(_, _, Req0, State) ->
    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}.

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

reply_json(S, B, R) ->
    cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).

fmt(R) -> iolist_to_binary(io_lib:format("~p", [R])).
auth_msg(missing_token) -> <<"Missing Authorization">>;
auth_msg(not_admin) -> <<"Admin required">>;
auth_msg(token_expired) -> <<"Token expired">>;
auth_msg(_) -> <<"Auth failed">>.
