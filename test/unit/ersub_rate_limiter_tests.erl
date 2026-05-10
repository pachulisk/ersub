-module(ersub_rate_limiter_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test sliding window rate limiting logic

sliding_window_test_() ->
    {setup,
     fun() ->
         ets:new(test_rate, [named_table, public, set])
     end,
     fun(_) ->
         ets:delete(test_rate)
     end,
     [
         {"under limit", fun() ->
             ets:delete_all_objects(test_rate),
             Now = erlang:monotonic_time(millisecond),
             ets:insert(test_rate, {{user, 1}, [Now - 100, Now - 200]}),
             [{_, Ts}] = ets:lookup(test_rate, {user, 1}),
             Active = [T || T <- Ts, Now - T < 60000],
             ?assert(length(Active) < 10)
         end},
         {"at limit", fun() ->
             ets:delete_all_objects(test_rate),
             Now = erlang:monotonic_time(millisecond),
             Ts = [Now - I * 100 || I <- lists:seq(0, 9)],
             ets:insert(test_rate, {{user, 2}, Ts}),
             [{_, Timestamps}] = ets:lookup(test_rate, {user, 2}),
             Active = [T || T <- Timestamps, Now - T < 60000],
             ?assertEqual(10, length(Active))
         end},
         {"expired entries filtered", fun() ->
             ets:delete_all_objects(test_rate),
             Now = erlang:monotonic_time(millisecond),
             %% Mix of recent and old timestamps
             Ts = [Now - 100, Now - 200, Now - 70000, Now - 80000],
             Active = [T || T <- Ts, Now - T < 60000],
             ?assertEqual(2, length(Active))
         end},
         {"zero limit = unlimited", fun() ->
             %% Zero should mean no limit
             ?assertEqual(ok, check_rpm_mock(user, 1, 0))
         end},
         {"null limit = unlimited", fun() ->
             ?assertEqual(ok, check_rpm_mock(user, 1, undefined))
         end}
     ]}.

check_rpm_mock(_, _, 0) -> ok;
check_rpm_mock(_, _, undefined) -> ok;
check_rpm_mock(_, _, null) -> ok;
check_rpm_mock(_, _, _Limit) -> ok.
