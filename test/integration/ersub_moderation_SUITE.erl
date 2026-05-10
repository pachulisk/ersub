-module(ersub_moderation_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([off_mode_test/1, service_running_test/1, check_content_off_test/1]).

all() -> [off_mode_test, service_running_test, check_content_off_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    try ersub_test_helpers:start_app() of
        ok -> Config
    catch _:Reason ->
        {skip, {app_start_failed, Reason}}
    end.

end_per_suite(_Config) -> ok.

off_mode_test(_Config) ->
    %% Default mode should be 'off'
    Mode = ersub_config_srv:get(moderation_mode, <<"off">>),
    ?assertEqual(<<"off">>, Mode).

service_running_test(_Config) ->
    ?assert(is_pid(whereis(ersub_moderation_srv))).

check_content_off_test(_Config) ->
    %% In off mode, check_content should pass everything through
    Result = ersub_moderation_srv:check_content(1, <<"test content">>),
    ?assertEqual(ok, Result).
