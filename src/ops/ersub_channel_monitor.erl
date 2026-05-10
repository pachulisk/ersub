-module(ersub_channel_monitor).
-behaviour(gen_server).

-export([start_link/0, check_now/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(TICK_INTERVAL_MS, 30000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

check_now(MonitorId) ->
    gen_server:cast(?SERVER, {check, MonitorId}).

init([]) ->
    schedule_tick(),
    logger:info("Channel monitor started"),
    {ok, #{}}.

handle_call(_, _From, State) -> {reply, ok, State}.

handle_cast({check, MonitorId}, State) ->
    do_check(MonitorId),
    {noreply, State};
handle_cast(_, State) -> {noreply, State}.

handle_info(tick, State) ->
    check_due_monitors(),
    schedule_tick(),
    {noreply, State};
handle_info(_, State) -> {noreply, State}.

schedule_tick() ->
    erlang:send_after(?TICK_INTERVAL_MS, self(), tick).

check_due_monitors() ->
    case ersub_repo:squery(
        "SELECT m.id FROM channel_monitors m "
        "LEFT JOIN channel_monitor_histories h ON h.monitor_id = m.id "
        "WHERE m.is_active = TRUE "
        "GROUP BY m.id, m.check_interval_s "
        "HAVING MAX(h.checked_at) IS NULL "
        "OR MAX(h.checked_at) < NOW() - (m.check_interval_s || ' seconds')::interval") of
        {ok, _, Rows} ->
            lists:foreach(fun({Id}) -> do_check(binary_to_integer(Id)) end, Rows);
        _ -> ok
    end.

do_check(MonitorId) ->
    case ersub_repo:query(
        "SELECT m.id, c.base_url, m.expected_status, m.timeout_ms "
        "FROM channel_monitors m JOIN channels c ON m.channel_id = c.id "
        "WHERE m.id = $1", [MonitorId]) of
        {ok, _, [{_MId, BaseUrl, ExpectedStatus, TimeoutMs}]} ->
            Start = erlang:monotonic_time(millisecond),
            Timeout = case TimeoutMs of
                T when is_integer(T) -> T;
                T when is_binary(T) -> binary_to_integer(T);
                _ -> 10000
            end,
            ExpStatus = case ExpectedStatus of
                S when is_integer(S) -> S;
                S when is_binary(S) -> binary_to_integer(S);
                _ -> 200
            end,
            %% Simple HTTP GET to base_url
            Result = try
                case ersub_upstream_pool:request(<<"GET">>, BaseUrl, [], <<>>, #{}, Timeout) of
                    {ok, Status, _, _} ->
                        Latency = erlang:monotonic_time(millisecond) - Start,
                        {Status =:= ExpStatus, Status, Latency};
                    {error, _Reason} ->
                        {false, 0, 0}
                end
            catch _:_ -> {false, 0, 0}
            end,
            {IsSuccess, StatusCode, LatencyMs} = Result,
            %% Record history
            ersub_repo:query(
                "INSERT INTO channel_monitor_histories "
                "(monitor_id, status_code, latency_ms, is_success) "
                "VALUES ($1, $2, $3, $4)",
                [MonitorId, StatusCode, LatencyMs, IsSuccess]),
            %% Update daily rollup
            update_rollup(MonitorId, IsSuccess, LatencyMs);
        _ -> ok
    end.

update_rollup(MonitorId, IsSuccess, LatencyMs) ->
    Today = element(1, calendar:universal_time()),
    {Y, M, D} = Today,
    DateStr = io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D]),
    SuccessInc = case IsSuccess of true -> 1; false -> 0 end,
    ersub_repo:query(
        "INSERT INTO channel_monitor_daily_rollups "
        "(monitor_id, date, total_checks, success_count, avg_latency_ms) "
        "VALUES ($1, $2::date, 1, $3, $4) "
        "ON CONFLICT (monitor_id, date) DO UPDATE SET "
        "total_checks = channel_monitor_daily_rollups.total_checks + 1, "
        "success_count = channel_monitor_daily_rollups.success_count + $3, "
        "avg_latency_ms = (channel_monitor_daily_rollups.avg_latency_ms * "
        "channel_monitor_daily_rollups.total_checks + $4) / "
        "(channel_monitor_daily_rollups.total_checks + 1)",
        [MonitorId, lists:flatten(DateStr), SuccessInc, LatencyMs]).
