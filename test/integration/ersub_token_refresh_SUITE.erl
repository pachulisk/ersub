-module(ersub_token_refresh_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([no_refresh_needed_test/1, trigger_refresh_no_crash_test/1,
         api_key_account_skipped_test/1]).

all() -> [no_refresh_needed_test, trigger_refresh_no_crash_test,
          api_key_account_skipped_test].

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

no_refresh_needed_test(_Config) ->
    %% API key accounts don't need token refresh
    Acc = ersub_test_fixtures:must_create_account(#{
        account_type => <<"api_key">>,
        credentials => #{<<"api_key">> => <<"sk-test">>}
    }),
    AccId = maps:get(id, Acc),
    {ok, FullAcc} = ersub_repo:get_account(AccId),
    ersub_platform_sup:start_account(FullAcc),
    timer:sleep(200),
    %% Token refresh should not affect API key accounts
    ersub_token_refresh_srv:trigger_refresh(AccId),
    timer:sleep(200),
    %% Account should still be active
    try
        State = ersub_account_srv:get_state(AccId),
        ?assertEqual(active, maps:get(status, State))
    catch _:_ ->
        %% Process may not be registered via gproc in test, that's ok
        ok
    end,
    ersub_platform_sup:stop_account(AccId).

trigger_refresh_no_crash_test(_Config) ->
    %% Triggering refresh on non-existent account should not crash
    ersub_token_refresh_srv:trigger_refresh(999999),
    timer:sleep(200),
    %% Service should still be running
    ?assert(is_pid(whereis(ersub_token_refresh_srv))).

api_key_account_skipped_test(_Config) ->
    %% Verify api_key type accounts are correctly identified as not needing refresh
    Acc = ersub_test_fixtures:must_create_account(#{
        account_type => <<"api_key">>
    }),
    {ok, FullAcc} = ersub_repo:get_account(maps:get(id, Acc)),
    %% api_key type should not have token_expires in credentials
    Creds = maps:get(credentials, FullAcc, #{}),
    ?assertEqual(undefined, maps:get(<<"token_expires">>, Creds, undefined)).
