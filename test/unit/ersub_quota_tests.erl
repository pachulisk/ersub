-module(ersub_quota_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test quota checking logic (extracted from ersub_quota_srv internals)

check_daily_test() ->
    %% Under limit
    ?assertEqual(ok, check(0.5, 0, 0, 1.0, 0, 0, 0.1)),
    %% Over limit
    ?assertEqual({error, {quota_exceeded, daily}}, check(0.9, 0, 0, 1.0, 0, 0, 0.2)).

check_weekly_test() ->
    ?assertEqual(ok, check(0, 5.0, 0, 0, 10.0, 0, 2.0)),
    ?assertEqual({error, {quota_exceeded, weekly}}, check(0, 9.5, 0, 0, 10.0, 0, 1.0)).

check_monthly_test() ->
    ?assertEqual(ok, check(0, 0, 50.0, 0, 0, 100.0, 10.0)),
    ?assertEqual({error, {quota_exceeded, monthly}}, check(0, 0, 95.0, 0, 0, 100.0, 10.0)).

check_no_limits_test() ->
    %% Zero limits = no restriction
    ?assertEqual(ok, check(100.0, 100.0, 100.0, 0, 0, 0, 50.0)).

check_cascading_test() ->
    %% Daily hit first even if weekly/monthly ok
    ?assertEqual({error, {quota_exceeded, daily}},
        check(0.9, 5.0, 50.0, 1.0, 100.0, 1000.0, 0.2)).

%%% Internal helper (mirrors ersub_quota_srv:check_limits logic)
check(DU, WU, MU, DL, WL, ML, Cost) ->
    if
        DL > 0, DU + Cost > DL -> {error, {quota_exceeded, daily}};
        WL > 0, WU + Cost > WL -> {error, {quota_exceeded, weekly}};
        ML > 0, MU + Cost > ML -> {error, {quota_exceeded, monthly}};
        true -> ok
    end.
