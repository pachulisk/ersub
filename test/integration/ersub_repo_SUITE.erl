-module(ersub_repo_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([create_user_test/1, create_account_test/1, create_api_key_test/1,
         bind_account_group_test/1, settings_test/1]).

all() -> [create_user_test, create_account_test, create_api_key_test,
          bind_account_group_test, settings_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    try ersub_test_helpers:start_app() of
        ok -> Config
    catch _:Reason ->
        {skip, {app_start_failed, Reason}}
    end.

end_per_suite(_Config) ->
    ersub_test_helpers:cleanup_tables(),
    ok.

init_per_testcase(_TC, Config) ->
    ersub_test_helpers:cleanup_tables(),
    Config.

end_per_testcase(_TC, _Config) -> ok.

create_user_test(_Config) ->
    User = ersub_test_fixtures:must_create_user(#{email => <<"repo-test@test.com">>}),
    ?assertMatch(#{id := _, email := <<"repo-test@test.com">>}, User),
    {ok, Fetched} = ersub_repo:get_user(maps:get(id, User)),
    ?assertEqual(<<"repo-test@test.com">>, maps:get(email, Fetched)).

create_account_test(_Config) ->
    Acc = ersub_test_fixtures:must_create_account(#{name => <<"test-acc">>}),
    ?assertMatch(#{id := _, name := <<"test-acc">>}, Acc),
    {ok, Fetched} = ersub_repo:get_account(maps:get(id, Acc)),
    ?assertEqual(<<"test-acc">>, maps:get(name, Fetched)).

create_api_key_test(_Config) ->
    User = ersub_test_fixtures:must_create_user(#{}),
    Key = ersub_test_fixtures:must_create_api_key(#{user_id => maps:get(id, User)}),
    ?assertMatch(#{raw_key := <<"sk-test-", _/binary>>}, Key).

bind_account_group_test(_Config) ->
    Acc = ersub_test_fixtures:must_create_account(#{}),
    Grp = ersub_test_fixtures:must_create_group(#{}),
    ok = ersub_repo:bind_account_to_group(maps:get(id, Acc), maps:get(id, Grp)),
    {ok, Groups} = ersub_repo:list_account_groups(maps:get(id, Acc)),
    ?assertEqual([maps:get(id, Grp)], Groups).

settings_test(_Config) ->
    ersub_repo:upsert_setting(<<"test_key">>, #{value => 42}),
    {ok, Val} = ersub_repo:get_setting(<<"test_key">>),
    ?assertEqual(42, maps:get(<<"value">>, Val)).
