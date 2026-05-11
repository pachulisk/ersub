-module(ersub_metrics_srv).
-behaviour(gen_server).

-export([start_link/0, get_summary/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(AGGREGATION_INTERVAL_MS, 300000). %% 5 minutes

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_summary() -> map().
get_summary() ->
    gen_server:call(?SERVER, get_summary).

init([]) ->
    schedule_aggregation(),
    logger:info("Metrics aggregation service started"),
    {ok, #{last_aggregation => undefined}}.

handle_call(get_summary, _From, State) ->
    Summary = case ersub_repo:squery(
        "SELECT COUNT(*), COALESCE(SUM(actual_cost::numeric), 0), "
        "COALESCE(AVG(duration_ms), 0) "
        "FROM usage_logs WHERE created_at > NOW() - INTERVAL '1 hour'"
    ) of
        {ok, _, [{Count, TotalCost, AvgDuration}]} ->
            #{requests_1h => binary_to_integer(Count),
              cost_1h => TotalCost,
              avg_duration_ms => AvgDuration};
        _ ->
            #{requests_1h => 0, cost_1h => 0, avg_duration_ms => 0}
    end,
    {reply, Summary, State};

handle_call(_, _From, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.

handle_info(aggregate, State) ->
    %% O04: Advisory lock to prevent concurrent aggregation across instances
    case acquire_advisory_lock(42001) of
        ok ->
            do_aggregation(),
            release_advisory_lock(42001);
        locked ->
            logger:debug("Metrics aggregation skipped: advisory lock held by another instance")
    end,
    schedule_aggregation(),
    {noreply, State#{last_aggregation => calendar:universal_time()}}.

schedule_aggregation() ->
    erlang:send_after(?AGGREGATION_INTERVAL_MS, self(), aggregate).

do_aggregation() ->
    %% O02: Aggregate per-model metrics for 3 granularities: 5min, 1h, 24h
    %% date_trunc accepts unit names: minute, hour, day
    %% WindowSize is the INTERVAL for window_end offset
    %% Lookback is the INTERVAL for the WHERE clause
    aggregate_window(<<"5min">>, <<"minute">>, <<"5 minutes">>, <<"10 minutes">>),
    aggregate_window(<<"1hour">>, <<"hour">>, <<"1 hour">>, <<"2 hours">>),
    aggregate_window(<<"24hour">>, <<"day">>, <<"1 day">>, <<"25 hours">>).

aggregate_window(Granularity, TruncUnit, WindowSize, Lookback) ->
    Query = iolist_to_binary([
        "INSERT INTO metrics_aggregated "
        "(dimension_type, dimension_id, window_start, window_end, granularity, "
        "request_count, error_count, total_tokens, total_cost_usd) "
        "SELECT 'model', requested_model, "
        "date_trunc('", TruncUnit, "', created_at), "
        "date_trunc('", TruncUnit, "', created_at) + INTERVAL '", WindowSize, "', "
        "'", Granularity, "', COUNT(*), "
        "COUNT(*) FILTER (WHERE actual_cost = 0), "
        "COALESCE(SUM(input_tokens + output_tokens), 0), "
        "COALESCE(SUM(actual_cost::numeric), 0) "
        "FROM usage_logs "
        "WHERE created_at > NOW() - INTERVAL '", Lookback, "' "
        "GROUP BY requested_model, date_trunc('", TruncUnit, "', created_at) "
        "ON CONFLICT DO NOTHING"
    ]),
    case ersub_repo:squery(binary_to_list(Query)) of
        {ok, _, _} -> ok;
        {error, Reason} ->
            logger:warning("Metrics aggregation (~s) failed: ~p",
                           [Granularity, Reason])
    end.

acquire_advisory_lock(LockId) ->
    case ersub_repo:query("SELECT pg_try_advisory_lock($1)", [LockId]) of
        {ok, _, [{true}]} -> ok;
        _ -> locked
    end.

release_advisory_lock(LockId) ->
    ersub_repo:query("SELECT pg_advisory_unlock($1)", [LockId]),
    ok.
