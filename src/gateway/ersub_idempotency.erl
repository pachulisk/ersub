-module(ersub_idempotency).

-export([init_cache/0, check/2, store/4]).

-define(TABLE, ersub_idempotency_cache).
-define(TTL_MS, 86400000). %% 24 hours

%% Initialize ETS cache (call once at app start).
init_cache() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ -> ?TABLE
    end.

%% Check if a request has been seen before.
%% Returns {hit, {Status, Headers, Body}} | miss.
-spec check(integer(), binary()) -> {hit, {integer(), map(), binary()}} | miss.
check(KeyId, IdempotencyKey) ->
    Key = {KeyId, IdempotencyKey},
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TABLE, Key) of
        [{_, Status, Headers, Body, Expires}] when Expires > Now ->
            {hit, {Status, Headers, Body}};
        [{_, _, _, _, _}] ->
            ets:delete(?TABLE, Key),
            miss;
        [] ->
            miss
    end.

%% Store a response for future idempotent replay.
-spec store(integer(), binary(), integer(), binary()) -> ok.
store(KeyId, IdempotencyKey, Status, Body) ->
    Key = {KeyId, IdempotencyKey},
    Expires = erlang:monotonic_time(millisecond) + ?TTL_MS,
    ets:insert(?TABLE, {Key, Status, #{}, Body, Expires}),
    ok.
