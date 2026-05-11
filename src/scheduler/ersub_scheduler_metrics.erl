-module(ersub_scheduler_metrics).

-export([init/0, increment/1, get_metrics/0, record_load_skew/1]).

-define(TABLE, ersub_scheduler_metrics).

init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
            lists:foreach(fun(Key) ->
                ets:insert(?TABLE, {Key, 0})
            end, [select_total, sticky_previous_hit, sticky_session_hit,
                  lb_select, account_switch, load_skew_sum, load_skew_count]);
        _ -> ok
    end.

-spec increment(atom()) -> ok.
increment(Key) ->
    try ets:update_counter(?TABLE, Key, 1)
    catch error:badarg -> ets:insert(?TABLE, {Key, 1})
    end,
    ok.

-spec record_load_skew([float()]) -> ok.
record_load_skew(LoadRates) when length(LoadRates) > 1 ->
    Mean = lists:sum(LoadRates) / length(LoadRates),
    Variance = lists:sum([(L - Mean) * (L - Mean) || L <- LoadRates]) / length(LoadRates),
    StdDev = math:sqrt(Variance),
    try
        ets:update_counter(?TABLE, load_skew_sum, trunc(StdDev * 10000)),
        ets:update_counter(?TABLE, load_skew_count, 1)
    catch error:badarg -> ok
    end,
    ok;
record_load_skew(_) -> ok.

-spec get_metrics() -> map().
get_metrics() ->
    All = ets:tab2list(?TABLE),
    Map = maps:from_list(All),
    SkewSum = maps:get(load_skew_sum, Map, 0),
    SkewCount = maps:get(load_skew_count, Map, 1),
    AvgSkew = case SkewCount of
        0 -> 0.0;
        _ -> SkewSum / SkewCount / 10000
    end,
    Map#{avg_load_skew => AvgSkew}.
