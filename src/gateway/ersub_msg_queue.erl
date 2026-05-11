-module(ersub_msg_queue).

-export([maybe_throttle/2, release/1]).

-define(LOCK_TABLE, ersub_msg_queue_locks).

%% X01: Apply user message queue mode before processing request.
%% serialize: acquire ETS lock, only one request at a time per user
%% throttle: calculate delay based on RPM, sleep before proceeding
-spec maybe_throttle(integer(), map()) -> ok | {error, serialized_timeout}.

maybe_throttle(UserId, Account) ->
    Mode = maps:get(<<"user_msg_queue_mode">>, maps:get(credentials, Account, #{}),
                    maps:get(user_msg_queue_mode, Account, undefined)),
    case Mode of
        <<"serialize">> ->
            serialize_lock(UserId);
        <<"throttle">> ->
            throttle_delay(UserId, Account);
        _ ->
            ok
    end.

%%% Internal

serialize_lock(UserId) ->
    %% Init table if needed
    _ = case ets:info(?LOCK_TABLE) of
        undefined -> ets:new(?LOCK_TABLE, [named_table, public, set]);
        _ -> ok
    end,
    %% Try to acquire lock
    case ets:insert_new(?LOCK_TABLE, {UserId, self(), erlang:monotonic_time(millisecond)}) of
        true ->
            ok;
        false ->
            %% Wait for lock release (max 30s)
            wait_for_lock(UserId, 30000)
    end.

wait_for_lock(_UserId, Timeout) when Timeout =< 0 ->
    {error, serialized_timeout};
wait_for_lock(UserId, Timeout) ->
    timer:sleep(100),
    case ets:insert_new(?LOCK_TABLE, {UserId, self(), erlang:monotonic_time(millisecond)}) of
        true -> ok;
        false ->
            %% Check for stale lock (>60s)
            case ets:lookup(?LOCK_TABLE, UserId) of
                [{_, _, LockTime}] ->
                    Now = erlang:monotonic_time(millisecond),
                    case Now - LockTime > 60000 of
                        true ->
                            %% Stale lock, force acquire
                            ets:insert(?LOCK_TABLE, {UserId, self(), Now}),
                            ok;
                        false ->
                            wait_for_lock(UserId, Timeout - 100)
                    end;
                [] ->
                    ets:insert(?LOCK_TABLE, {UserId, self(), erlang:monotonic_time(millisecond)}),
                    ok
            end
    end.

throttle_delay(UserId, _Account) ->
    %% RPM-aware delay: if user has high RPM usage, add adaptive delay
    case ersub_rate_limiter:check_rpm(user, UserId, 999999) of
        ok ->
            %% Under limit, minimal delay
            ok;
        {error, rate_limited} ->
            %% At limit, add 1s delay
            timer:sleep(1000),
            ok
    end.

%% Release serialize lock (call after request completes)
release(UserId) ->
    case ets:info(?LOCK_TABLE) of
        undefined -> ok;
        _ -> ets:delete(?LOCK_TABLE, UserId), ok
    end.
