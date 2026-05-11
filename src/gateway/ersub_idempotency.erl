-module(ersub_idempotency).
-behaviour(gen_server).

-export([init_cache/0, check/2, store/4]).
-export([start_processing/2, mark_succeeded/3, mark_failed/2]).
-export([cleanup_expired/0]).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, ersub_idempotency_cache).
-define(TTL_MS, 86400000). %% 24 hours
-define(CLEANUP_INTERVAL_MS, 3600000). %% 1 hour

%% ETS record format:
%% {Key, EntryStatus, HttpStatus, Headers, Body, Expires}
%% EntryStatus = processing | succeeded | failed

%%% Public API

%% Initialize ETS cache (call once at app start, before supervisor).
init_cache() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ -> ?TABLE
    end.

%% Start the cleanup gen_server (managed by supervisor).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Check if a request has been seen before.
%% Returns:
%%   {hit, processing}              - request is currently being processed (409)
%%   {hit, {Status, Headers, Body}} - request succeeded, cached result available
%%   miss                           - no entry or entry is failed (allows retry)
-spec check(integer(), binary()) ->
    {hit, processing} | {hit, {integer(), map(), binary()}} | miss.
check(KeyId, IdempotencyKey) ->
    Key = {KeyId, IdempotencyKey},
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TABLE, Key) of
        [{_, processing, _, _, _, Expires}] when Expires > Now ->
            {hit, processing};
        [{_, succeeded, Status, Headers, Body, Expires}] when Expires > Now ->
            {hit, {Status, Headers, Body}};
        [{_, failed, _, _, _, _}] ->
            %% Failed entries allow retry
            ets:delete(?TABLE, Key),
            miss;
        [{_, _, _, _, _, _}] ->
            %% Expired entry
            ets:delete(?TABLE, Key),
            miss;
        [] ->
            miss
    end.

%% Mark a key as processing (called before forwarding upstream).
-spec start_processing(integer(), binary()) -> ok.
start_processing(KeyId, IdempotencyKey) ->
    Key = {KeyId, IdempotencyKey},
    Expires = erlang:monotonic_time(millisecond) + ?TTL_MS,
    ets:insert(?TABLE, {Key, processing, 0, #{}, <<>>, Expires}),
    ok.

%% Mark a key as succeeded and store the response for replay.
-spec mark_succeeded(integer(), binary(), {integer(), map(), binary()}) -> ok.
mark_succeeded(KeyId, IdempotencyKey, {Status, Headers, Body}) ->
    Key = {KeyId, IdempotencyKey},
    Expires = erlang:monotonic_time(millisecond) + ?TTL_MS,
    ets:insert(?TABLE, {Key, succeeded, Status, Headers, Body, Expires}),
    ok.

%% Mark a key as failed (allows retry on next request).
-spec mark_failed(integer(), binary()) -> ok.
mark_failed(KeyId, IdempotencyKey) ->
    Key = {KeyId, IdempotencyKey},
    Expires = erlang:monotonic_time(millisecond) + ?TTL_MS,
    ets:insert(?TABLE, {Key, failed, 0, #{}, <<>>, Expires}),
    ok.

%% Legacy store function for backward compatibility.
-spec store(integer(), binary(), integer(), binary()) -> ok.
store(KeyId, IdempotencyKey, Status, Body) ->
    mark_succeeded(KeyId, IdempotencyKey, {Status, #{}, Body}).

%% Delete all expired entries from the ETS table.
-spec cleanup_expired() -> non_neg_integer().
cleanup_expired() ->
    Now = erlang:monotonic_time(millisecond),
    %% Fold over the table and collect expired keys
    Expired = ets:foldl(fun({Key, _, _, _, _, Expires}, Acc) ->
        case Expires =< Now of
            true -> [Key | Acc];
            false -> Acc
        end
    end, [], ?TABLE),
    lists:foreach(fun(K) -> ets:delete(?TABLE, K) end, Expired),
    length(Expired).

%%% gen_server callbacks

init([]) ->
    schedule_cleanup(),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    Removed = cleanup_expired(),
    case Removed > 0 of
        true ->
            logger:info("Idempotency cleanup: removed ~p expired entries", [Removed]);
        false ->
            ok
    end,
    schedule_cleanup(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% Internal

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup).
