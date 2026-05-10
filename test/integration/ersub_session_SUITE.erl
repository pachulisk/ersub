-module(ersub_session_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([store_lookup_test/1, ttl_expiry_test/1, remove_test/1]).

all() -> [store_lookup_test, ttl_expiry_test, remove_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    ersub_test_helpers:start_app(),
    Config.

end_per_suite(_Config) -> ok.

store_lookup_test(_Config) ->
    ersub_session_srv:store(1, <<"hash1">>, 42),
    ?assertMatch({ok, 42}, ersub_session_srv:lookup(1, <<"hash1">>)),
    ?assertEqual(miss, ersub_session_srv:lookup(1, <<"other">>)),
    ?assertEqual(miss, ersub_session_srv:lookup(2, <<"hash1">>)).

ttl_expiry_test(_Config) ->
    %% Store with very short TTL by manipulating config
    ersub_config_srv:set(scheduling_sticky_session_ttl_s, 0),
    ersub_session_srv:store(3, <<"exp">>, 99),
    timer:sleep(100),
    ?assertEqual(miss, ersub_session_srv:lookup(3, <<"exp">>)),
    %% Restore default
    ersub_config_srv:set(scheduling_sticky_session_ttl_s, 3600).

remove_test(_Config) ->
    ersub_session_srv:store(4, <<"rem">>, 55),
    ?assertMatch({ok, 55}, ersub_session_srv:lookup(4, <<"rem">>)),
    ersub_session_srv:remove(4, <<"rem">>),
    ?assertEqual(miss, ersub_session_srv:lookup(4, <<"rem">>)).
