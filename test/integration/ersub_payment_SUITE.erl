-module(ersub_payment_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([create_order_test/1]).

all() -> [create_order_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    ersub_test_helpers:start_app(),
    Config.

end_per_suite(_Config) ->
    ersub_test_helpers:cleanup_tables(),
    ok.

init_per_testcase(_, Config) ->
    ersub_test_helpers:cleanup_tables(),
    Config.

end_per_testcase(_, _Config) -> ok.

create_order_test(_Config) ->
    User = ersub_test_fixtures:must_create_user(#{}),
    UserId = maps:get(id, User),
    {ok, Order} = ersub_payment_srv:create_order(UserId, <<"stripe">>, 10.0),
    ?assertMatch(#{id := _, status := <<"pending">>}, Order).
