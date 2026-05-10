-module(ersub_openai_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([openai_no_auth_test/1]).

all() -> [openai_no_auth_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    ersub_test_helpers:start_app(),
    timer:sleep(1000),
    Config.

end_per_suite(_Config) -> ok.

openai_no_auth_test(_Config) ->
    {ok, ConnPid} = gun:open("localhost", 8080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:post(ConnPid, "/openai/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}],
        <<"{}">>),
    {response, nofin, 401, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).
