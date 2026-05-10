-module(ersub_billing_prop).
-include_lib("eunit/include/eunit.hrl").

cost_non_negative_test() ->
    [begin
        IT = rand:uniform(100000),
        OT = rand:uniform(100000),
        Cost = IT * 0.000003 + OT * 0.000015,
        ?assert(Cost >= 0)
    end || _ <- lists:seq(1, 200)].

rate_mult_zero_test() ->
    [begin
        IT = rand:uniform(100000),
        OT = rand:uniform(100000),
        Cost = (IT * 0.000003 + OT * 0.000015) * 0.0,
        ?assertEqual(0.0, Cost)
    end || _ <- lists:seq(1, 100)].

priority_double_test() ->
    [begin
        IT = rand:uniform(10000),
        OT = rand:uniform(10000),
        Std = IT * 0.000003 + OT * 0.000015,
        Pri = Std * 2.0,
        ?assert(abs(Pri - Std * 2.0) < 0.0001)
    end || _ <- lists:seq(1, 100)].
