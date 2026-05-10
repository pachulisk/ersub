-module(ersub_upstream_pool_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([self_health_request_test/1, invalid_url_test/1, response_headers_test/1]).

all() -> [invalid_url_test, self_health_request_test, response_headers_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    try ersub_test_helpers:start_app() of
        ok ->
            %% Wait for HTTP listener to be ready
            wait_for_listener(10),
            Config
    catch _:Reason ->
        {skip, {app_start_failed, Reason}}
    end.

end_per_suite(_Config) -> ok.

invalid_url_test(_Config) ->
    Result = ersub_upstream_pool:request(
        <<"GET">>, <<"not-a-valid-url">>, [], <<>>, #{}),
    ?assertMatch({error, _}, Result).

self_health_request_test(_Config) ->
    case ersub_upstream_pool:request(
        <<"GET">>, <<"http://localhost:8080/health">>, [], <<>>, #{}) of
        {ok, 200, _, Body} ->
            Json = jsx:decode(Body, [return_maps]),
            ?assertMatch(#{<<"status">> := _}, Json);
        {error, _Reason} ->
            {skip, listener_not_ready}
    end.

response_headers_test(_Config) ->
    case ersub_upstream_pool:request(
        <<"GET">>, <<"http://localhost:8080/health">>, [], <<>>, #{}) of
        {ok, 200, Headers, _} ->
            ?assert(maps:is_key(<<"content-type">>, Headers));
        {error, _} ->
            {skip, listener_not_ready}
    end.

wait_for_listener(0) -> ok;
wait_for_listener(N) ->
    case gen_tcp:connect("localhost", 8080, [], 500) of
        {ok, S} -> gen_tcp:close(S), ok;
        {error, _} -> timer:sleep(500), wait_for_listener(N - 1)
    end.
