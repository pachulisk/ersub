-module(ersub_test_helpers).

-export([start_app/0, stop_app/0, setup_db/0, cleanup_tables/0]).
-export([with_transaction/1]).

%% Start the full application for integration tests.
%% Handles already-started gracefully.
start_app() ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    os:putenv("DB_PASSWORD", os:getenv("DB_PASSWORD", "")),
    case whereis(ersub_sup) of
        Pid when is_pid(Pid) ->
            %% Already running
            ok;
        undefined ->
            {ok, _} = application:ensure_all_started(ersub),
            ok = ersub_migration:run(),
            ok
    end.

stop_app() ->
    application:stop(ersub),
    ok.

%% Set up a clean database state.
setup_db() ->
    cleanup_tables(),
    ok.

%% Delete all data from test tables (order matters for FK constraints).
cleanup_tables() ->
    Tables = [
        "moderation_logs", "announcement_reads", "announcements",
        "error_passthrough_rules",
        "usage_logs", "payment_orders",
        "user_subscriptions",
        "user_allowed_groups", "account_groups",
        "auth_identities", "api_keys",
        "channels", "accounts", "groups", "users",
        "settings"
    ],
    lists:foreach(fun(T) ->
        try ersub_repo:squery("DELETE FROM " ++ T)
        catch _:_ -> ok
        end
    end, Tables).

%% Run a function inside a DB transaction that rolls back on completion.
with_transaction(Fun) ->
    ersub_repo_pool:with_conn(fun(Worker) ->
        gen_server:call(Worker, {squery, "BEGIN"}),
        try
            Result = Fun(),
            gen_server:call(Worker, {squery, "ROLLBACK"}),
            Result
        catch
            Class:Reason:Stack ->
                gen_server:call(Worker, {squery, "ROLLBACK"}),
                erlang:raise(Class, Reason, Stack)
        end
    end).

