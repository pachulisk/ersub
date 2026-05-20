-module(ersub_dashboard_cache).
-behaviour(gen_server).

%% T4-03: ETS cache for dashboard SQL queries with configurable TTL.
%% Wraps expensive aggregation queries to avoid hammering PostgreSQL.

-export([start_link/0, get/2, invalidate/1, invalidate_all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, ersub_dashboard_cache).
-define(DEFAULT_TTL_MS, 30000). %% 30 seconds
-define(CLEANUP_INTERVAL_MS, 60000). %% 1 minute

%%% Public API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Get a cached value or compute it.
%% Key is any term, ComputeFun is a 0-arity fun returning the value.
-spec get(term(), fun(() -> term())) -> term().
get(Key, ComputeFun) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TABLE, Key) of
        [{_, Value, ExpiresAt}] when ExpiresAt > Now ->
            Value;
        _ ->
            Value = ComputeFun(),
            TTL = ersub_config_srv:get(dashboard_cache_ttl_ms, ?DEFAULT_TTL_MS),
            ets:insert(?TABLE, {Key, Value, Now + TTL}),
            Value
    end.

%% Invalidate a specific cache key.
-spec invalidate(term()) -> ok.
invalidate(Key) ->
    ets:delete(?TABLE, Key),
    ok.

%% Invalidate all cached entries.
-spec invalidate_all() -> ok.
invalidate_all() ->
    ets:delete_all_objects(?TABLE),
    ok.

%%% gen_server callbacks

init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    schedule_cleanup(),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    Now = erlang:monotonic_time(millisecond),
    Expired = ets:foldl(fun({Key, _, ExpiresAt}, Acc) ->
        case ExpiresAt =< Now of
            true -> [Key | Acc];
            false -> Acc
        end
    end, [], ?TABLE),
    lists:foreach(fun(K) -> ets:delete(?TABLE, K) end, Expired),
    schedule_cleanup(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% Internal

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup).
