-module(ersub_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([health_check_test/1, claude_no_auth_test/1, claude_invalid_key_test/1]).

all() ->
    case os:getenv("ERSUB_E2E_ENABLED") of
        false -> [health_check_test, claude_no_auth_test, claude_invalid_key_test];
        _ -> [health_check_test, claude_no_auth_test, claude_invalid_key_test]
    end.

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    ersub_test_helpers:start_app(),
    timer:sleep(1000),
    Config.

end_per_suite(_Config) -> ok.

health_check_test(_Config) ->
    {ok, ConnPid} = gun:open("localhost", 8080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Json = jsx:decode(Body, [return_maps]),
    ?assertMatch(#{<<"status">> := _}, Json),
    gun:close(ConnPid).

claude_no_auth_test(_Config) ->
    {ok, ConnPid} = gun:open("localhost", 8080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}],
        <<"{}">>/utf8),
    {response, nofin, 401, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

claude_invalid_key_test(_Config) ->
    {ok, ConnPid} = gun:open("localhost", 8080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>},
         {<<"x-api-key">>, <<"sk-invalid">>}],
        <<"{}">>/utf8),
    {response, nofin, 401, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).
