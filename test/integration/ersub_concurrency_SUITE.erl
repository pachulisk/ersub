-module(ersub_concurrency_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([acquire_release_test/1, queue_full_test/1, process_crash_release_test/1]).

all() -> [acquire_release_test, queue_full_test, process_crash_release_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    try ersub_test_helpers:start_app() of
        ok -> Config
    catch _:Reason ->
        {skip, {app_start_failed, Reason}}
    end.

end_per_suite(_Config) -> ok.

acquire_release_test(_Config) ->
    {ok, Ref} = ersub_concurrency_srv:acquire(99999, 5),
    ?assert(is_reference(Ref)),
    ok = ersub_concurrency_srv:release(99999, Ref).

queue_full_test(_Config) ->
    UserId = 88888,
    MaxConc = 1,
    %% Acquire the only slot
    {ok, Ref1} = ersub_concurrency_srv:acquire(UserId, MaxConc),
    %% Fill the wait queue (default extra=20)
    _Pids = [spawn(fun() ->
        ersub_concurrency_srv:acquire(UserId, MaxConc),
        receive after infinity -> ok end
    end) || _ <- lists:seq(1, 20)],
    timer:sleep(100),
    %% 21st should be rejected
    ?assertEqual({rejected, queue_full},
        ersub_concurrency_srv:acquire(UserId, MaxConc)),
    %% Release
    ersub_concurrency_srv:release(UserId, Ref1).

process_crash_release_test(_Config) ->
    UserId = 77777,
    %% Spawn a process that acquires and then crashes
    Self = self(),
    _Pid = spawn(fun() ->
        {ok, _Ref} = ersub_concurrency_srv:acquire(UserId, 2),
        Self ! acquired,
        exit(crash)
    end),
    receive acquired -> ok after 1000 -> ct:fail(timeout) end,
    timer:sleep(200),
    %% Slot should be auto-released via DOWN monitor
    {ok, Ref2} = ersub_concurrency_srv:acquire(UserId, 2),
    ersub_concurrency_srv:release(UserId, Ref2).
