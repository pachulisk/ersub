-module(ersub_session_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([lookup/2, store/3, remove/2, cleanup_expired/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(TABLE, ersub_sticky_sessions).
-define(CLEANUP_INTERVAL_MS, 60000). %% cleanup every 60s

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Look up sticky session: returns {ok, AccountId} or miss.
-spec lookup(integer(), binary()) -> {ok, integer()} | miss.
lookup(UserId, SessionHash) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TABLE, {UserId, SessionHash}) of
        [{_, AccountId, ExpiresAt}] when ExpiresAt > Now ->
            %% Refresh TTL on hit
            TTL = ersub_config_srv:get(scheduling_sticky_session_ttl_s, 3600),
            NewExpires = Now + (TTL * 1000),
            ets:update_element(?TABLE, {UserId, SessionHash}, {3, NewExpires}),
            {ok, AccountId};
        [{_, _, _}] ->
            %% Expired, delete
            ets:delete(?TABLE, {UserId, SessionHash}),
            miss;
        [] ->
            miss
    end.

%% Store a sticky session mapping.
-spec store(integer(), binary(), integer()) -> ok.
store(UserId, SessionHash, AccountId) ->
    TTL = ersub_config_srv:get(scheduling_sticky_session_ttl_s, 3600),
    ExpiresAt = erlang:monotonic_time(millisecond) + (TTL * 1000),
    ets:insert(?TABLE, {{UserId, SessionHash}, AccountId, ExpiresAt}),
    ok.

%% Remove a sticky session (e.g., when account becomes incompatible).
-spec remove(integer(), binary()) -> ok.
remove(UserId, SessionHash) ->
    ets:delete(?TABLE, {UserId, SessionHash}),
    ok.

%% Force cleanup of expired entries.
-spec cleanup_expired() -> non_neg_integer().
cleanup_expired() ->
    Now = erlang:monotonic_time(millisecond),
    %% Use ets:select_delete for atomic batch removal
    ets:select_delete(?TABLE, [
        {{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}
    ]).

%%% gen_server callbacks

init([]) ->
    ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    schedule_cleanup(),
    logger:info("Session sticky cache started"),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    Deleted = cleanup_expired(),
    case Deleted > 0 of
        true -> logger:debug("Cleaned ~p expired sticky sessions", [Deleted]);
        false -> ok
    end,
    schedule_cleanup(),
    {noreply, State}.

%%% Internal

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup).
