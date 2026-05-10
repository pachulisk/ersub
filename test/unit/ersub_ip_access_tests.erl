-module(ersub_ip_access_tests).
-include_lib("eunit/include/eunit.hrl").

%% CIDR parsing tests
parse_cidr_test_() ->
    [
        {"IPv4 with mask", fun() ->
            {{10,0,0,0}, 8} = ersub_ip_access:parse_cidr(<<"10.0.0.0/8">>)
        end},
        {"IPv4 /32", fun() ->
            {{192,168,1,1}, 32} = ersub_ip_access:parse_cidr(<<"192.168.1.1/32">>)
        end},
        {"IPv4 no mask (defaults to /32)", fun() ->
            {{8,8,8,8}, 32} = ersub_ip_access:parse_cidr(<<"8.8.8.8">>)
        end},
        {"IPv4 /0", fun() ->
            {{0,0,0,0}, 0} = ersub_ip_access:parse_cidr(<<"0.0.0.0/0">>)
        end}
    ].

%% IP in CIDR matching tests
ip_in_cidr_test_() ->
    [
        {"10.x.x.x in 10.0.0.0/8", fun() ->
            ?assert(ersub_ip_access:ip_in_cidr({10,1,2,3},
                ersub_ip_access:parse_cidr(<<"10.0.0.0/8">>)))
        end},
        {"192.168.x.x not in 10.0.0.0/8", fun() ->
            ?assertNot(ersub_ip_access:ip_in_cidr({192,168,1,1},
                ersub_ip_access:parse_cidr(<<"10.0.0.0/8">>)))
        end},
        {"exact /32 match", fun() ->
            ?assert(ersub_ip_access:ip_in_cidr({1,2,3,4},
                ersub_ip_access:parse_cidr(<<"1.2.3.4/32">>)))
        end},
        {"exact /32 non-match", fun() ->
            ?assertNot(ersub_ip_access:ip_in_cidr({1,2,3,5},
                ersub_ip_access:parse_cidr(<<"1.2.3.4/32">>)))
        end},
        {"/0 matches everything", fun() ->
            ?assert(ersub_ip_access:ip_in_cidr({123,45,67,89},
                ersub_ip_access:parse_cidr(<<"0.0.0.0/0">>)))
        end}
    ].

%% Access control tests
access_control_test_() ->
    [
        {"whitelist allow", fun() ->
            ?assertEqual(allow,
                ersub_ip_access:check_ip_access({10,0,0,1}, [<<"10.0.0.0/8">>], []))
        end},
        {"whitelist deny", fun() ->
            ?assertEqual(deny,
                ersub_ip_access:check_ip_access({192,168,1,1}, [<<"10.0.0.0/8">>], []))
        end},
        {"blacklist priority over whitelist", fun() ->
            ?assertEqual(deny,
                ersub_ip_access:check_ip_access({10,0,0,1},
                    [<<"10.0.0.0/8">>], [<<"10.0.0.1/32">>]))
        end},
        {"empty whitelist = allow all", fun() ->
            ?assertEqual(allow,
                ersub_ip_access:check_ip_access({172,16,0,1}, [], []))
        end},
        {"blacklist only", fun() ->
            ?assertEqual(deny,
                ersub_ip_access:check_ip_access({127,0,0,1}, [], [<<"127.0.0.0/8">>]))
        end},
        {"not blacklisted + no whitelist = allow", fun() ->
            ?assertEqual(allow,
                ersub_ip_access:check_ip_access({8,8,8,8}, [], [<<"127.0.0.0/8">>]))
        end}
    ].
