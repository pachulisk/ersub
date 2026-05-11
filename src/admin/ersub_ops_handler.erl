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
    Summary = try ersub_metrics_srv:get_summary() catch _:_ -> #{} end,
    Health = try ersub_health_srv:get_score() catch _:_ -> #{score => 0} end,
    Accounts = length(ersub_platform_sup:list_accounts()),
    Children = length(supervisor:which_children(ersub_sup)),
    Dashboard = #{
        health_score => maps:get(score, Health, 0),
        components => maps:get(components, Health, #{}),
        requests_1h => maps:get(requests_1h, Summary, 0),
        cost_1h => maps:get(cost_1h, Summary, 0),
        avg_duration_ms => maps:get(avg_duration_ms, Summary, 0),
        active_accounts => Accounts,
        supervisor_children => Children
    },
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
    Summary = try ersub_metrics_srv:get_summary() catch _:_ -> #{} end,
    Health = try ersub_health_srv:get_score() catch _:_ -> #{score => 0} end,
    Accounts = length(ersub_platform_sup:list_accounts()),
    Children = length(supervisor:which_children(ersub_sup)),

    %% Throughput (last hour, per-minute)
    Throughput = case ersub_repo:squery(
        "SELECT date_trunc('minute', created_at) AS m, COUNT(*) "
        "FROM usage_logs WHERE created_at > NOW() - INTERVAL '1 hour' "
        "GROUP BY m ORDER BY m") of
        {ok, _, TRows} -> [#{minute => M, count => binary_to_integer(C)} || {M, C} <- TRows];
        _ -> []
    end,

    %% Errors (top models)
    Errors = case ersub_repo:squery(
        "SELECT requested_model, COUNT(*) FROM usage_logs "
        "WHERE actual_cost = 0 AND created_at > NOW() - INTERVAL '1 hour' "
        "GROUP BY requested_model ORDER BY COUNT(*) DESC LIMIT 10") of
        {ok, _, ERows} -> [#{model => M, count => binary_to_integer(C)} || {M, C} <- ERows];
        _ -> []
    end,

    %% Model breakdown (24h)
    Models = case ersub_repo:squery(
        "SELECT requested_model, COUNT(*), COALESCE(SUM(actual_cost::numeric),0) "
        "FROM usage_logs WHERE created_at > NOW() - INTERVAL '24 hours' "
        "GROUP BY requested_model ORDER BY COUNT(*) DESC") of
        {ok, _, MRows} -> [#{model => M, requests => binary_to_integer(C), cost => Co}
                           || {M, C, Co} <- MRows];
        _ -> []
    end,

    Snapshot = #{
        health => Health,
        summary => Summary,
        active_accounts => Accounts,
        supervisor_children => Children,
        throughput => Throughput,
        errors => Errors,
        models => Models
    },
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

handle(<<"DELETE">>, [<<"scheduled-tests">>, IdBin], Req0, State) ->
    ersub_repo:query("DELETE FROM scheduled_tests WHERE id = $1", [binary_to_integer(IdBin)]),
    {ok, reply_json(200, #{success => true}, Req0), State};

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
