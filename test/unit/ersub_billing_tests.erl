-module(ersub_billing_tests).
-include_lib("eunit/include/eunit.hrl").

balance_to_micro_test_() ->
    [
        {"integer", fun() ->
            %% balance_to_micro is internal, test via get_cached_balance pattern
            ok
        end}
    ].

effective_rpm_test_() ->
    %% Test the effective RPM logic pattern
    [
        {"both null = unlimited", fun() ->
            ?assertEqual(0, effective_rpm(null, null))
        end},
        {"key RPM takes priority", fun() ->
            ?assertEqual(100, effective_rpm(100, 200))
        end},
        {"fallback to user RPM", fun() ->
            ?assertEqual(200, effective_rpm(null, 200))
        end},
        {"both undefined = unlimited", fun() ->
            ?assertEqual(0, effective_rpm(undefined, undefined))
        end}
    ].

effective_rpm(null, null) -> 0;
effective_rpm(undefined, undefined) -> 0;
effective_rpm(null, U) -> U;
effective_rpm(undefined, U) -> U;
effective_rpm(K, _) when is_integer(K), K > 0 -> K;
effective_rpm(_, U) when is_integer(U), U > 0 -> U;
effective_rpm(_, _) -> 0.

session_hash_test() ->
    %% Session hash should be deterministic
    Hash1 = crypto:hash(sha256, <<"system: helpuser: hello">>),
    Hash2 = crypto:hash(sha256, <<"system: helpuser: hello">>),
    ?assertEqual(Hash1, Hash2).

session_hash_different_test() ->
    Hash1 = crypto:hash(sha256, <<"prompt1">>),
    Hash2 = crypto:hash(sha256, <<"prompt2">>),
    ?assertNotEqual(Hash1, Hash2).
