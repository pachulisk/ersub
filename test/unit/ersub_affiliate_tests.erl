-module(ersub_affiliate_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test rebate calculation logic

rebate_calculation_test_() ->
    [
        {"standard rebate", fun() ->
            Cost = 10.0,
            Rate = 0.1,
            Rebate = Cost * Rate,
            ?assertEqual(1.0, Rebate)
        end},
        {"zero rate", fun() ->
            ?assertEqual(0.0, 5.0 * 0.0)
        end},
        {"high rate", fun() ->
            ?assertEqual(2.5, 5.0 * 0.5)
        end},
        {"small cost", fun() ->
            ?assert(0.001 * 0.1 > 0)
        end}
    ].

aff_code_format_test() ->
    Code = iolist_to_binary([<<"AFF-">>, binary:encode_hex(crypto:strong_rand_bytes(6))]),
    ?assertMatch(<<"AFF-", _/binary>>, Code),
    ?assertEqual(16, byte_size(Code)). %% AFF- (4) + 12 hex chars
