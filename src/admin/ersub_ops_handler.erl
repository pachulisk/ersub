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
