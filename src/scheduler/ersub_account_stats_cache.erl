-module(ersub_account_stats_cache).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_today_stats/1, get_batch_stats/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, ersub_account_stats_cache).
-define(TTL_MS, 30000). %% 30 seconds
-define(CLEANUP_INTERVAL_MS, 30000). %% 30 seconds

%%% Public API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Get today's stats for a single account.
%% Returns {ok, StatsMap} where StatsMap has request_count, total_cost, avg_latency_ms.
-spec get_today_stats(integer()) -> {ok, map()} | {error, term()}.
get_today_stats(AccountId) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TABLE, AccountId) of
        [{_, Stats, Expires}] when Expires > Now ->
            {ok, Stats};
        _ ->
            compute_and_cache(AccountId, Now)
    end.

%% Get today's stats for multiple accounts in batch.
-spec get_batch_stats([integer()]) -> {ok, [map()]}.
get_batch_stats(AccountIds) ->
    Results = lists:map(fun(AccId) ->
        case get_today_stats(AccId) of
            {ok, Stats} -> Stats#{account_id => AccId};
            {error, _} -> #{account_id => AccId, request_count => 0,
                            total_cost => <<"0">>, avg_latency_ms => <<"0">>}
        end
    end, AccountIds),
    {ok, Results}.

%%% gen_server callbacks

init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    schedule_cleanup(),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    Now = erlang:monotonic_time(millisecond),
    Expired = ets:foldl(fun({Key, _, Expires}, Acc) ->
        case Expires =< Now of
            true -> [Key | Acc];
            false -> Acc
        end
    end, [], ?TABLE),
    lists:foreach(fun(K) -> ets:delete(?TABLE, K) end, Expired),
    schedule_cleanup(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% Internal

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup).

compute_and_cache(AccountId, Now) ->
    SQL = "SELECT COUNT(*), COALESCE(SUM(actual_cost), 0), "
          "COALESCE(AVG(duration_ms), 0) "
          "FROM usage_logs "
          "WHERE account_id = $1 AND created_at >= CURRENT_DATE",
    case ersub_repo:query(SQL, [AccountId]) of
        {ok, _, [{ReqCount, TotalCost, AvgLatency}]} ->
            Stats = #{
                request_count => ReqCount,
                total_cost => TotalCost,
                avg_latency_ms => AvgLatency
            },
            Expires = Now + ?TTL_MS,
            ets:insert(?TABLE, {AccountId, Stats, Expires}),
            {ok, Stats};
        {ok, _, []} ->
            EmptyStats = #{request_count => 0, total_cost => <<"0">>,
                           avg_latency_ms => <<"0">>},
            Expires = Now + ?TTL_MS,
            ets:insert(?TABLE, {AccountId, EmptyStats, Expires}),
            {ok, EmptyStats};
        {error, Reason} ->
            {error, Reason}
    end.
