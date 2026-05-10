-module(ersub_upstream_pool_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([placeholder_test/1]).

all() -> [placeholder_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    ersub_test_helpers:start_app(),
    Config.

end_per_suite(_Config) -> ok.

placeholder_test(_Config) ->
    ?assert(true).
