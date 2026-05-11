-module(ersub_billing_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([check_balance/2, deduct/2, get_cached_balance/1, sync_balance/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(BALANCE_TABLE, ersub_balances).
-define(SYNC_INTERVAL_MS, 5000).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Check if user has sufficient balance for estimated cost.
-spec check_balance(integer(), number()) -> ok | {error, insufficient_balance}.
check_balance(UserId, EstimatedCost) ->
    Balance = get_cached_balance(UserId),
    case Balance >= EstimatedCost of
        true -> ok;
        false -> {error, insufficient_balance}
    end.

%% Deduct cost from user balance (ETS cache, async DB sync).
-spec deduct(integer(), number()) -> ok.
deduct(UserId, Cost) when Cost > 0 ->
    %% Ensure user exists in cache
    _ = get_cached_balance(UserId),
    %% Atomic decrement in ETS
    _ = try
        ets:update_counter(?BALANCE_TABLE, UserId, {2, -trunc(Cost * 1000000)})
    catch
        error:badarg ->
            %% Key not found, load from DB
            _ = get_cached_balance(UserId),
            ets:update_counter(?BALANCE_TABLE, UserId, {2, -trunc(Cost * 1000000)})
    end,
    %% Queue async DB sync
    gen_server:cast(?SERVER, {sync_deduct, UserId, Cost}),
    ok;
deduct(_UserId, _Cost) ->
    ok.

%% Get cached balance (loads from DB on miss).
-spec get_cached_balance(integer()) -> number().
get_cached_balance(UserId) ->
    case ets:lookup(?BALANCE_TABLE, UserId) of
        [{_, MicroBalance}] ->
            MicroBalance / 1000000;
        [] ->
            load_balance_from_db(UserId)
    end.

%% Force sync cached balance to DB.
-spec sync_balance(integer()) -> ok.
sync_balance(UserId) ->
    gen_server:call(?SERVER, {sync_balance, UserId}).

%%% gen_server callbacks

init([]) ->
    _ = ets:new(?BALANCE_TABLE, [named_table, public, set, {write_concurrency, true}]),
    schedule_sync(),
    logger:info("Billing service started"),
    {ok, #{pending_syncs => #{}, circuit => closed, failures => 0}}.

handle_call({sync_balance, UserId}, _From, State) ->
    do_sync_user(UserId),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({sync_deduct, UserId, Cost}, #{pending_syncs := PS} = State) ->
    Current = maps:get(UserId, PS, 0),
    {noreply, State#{pending_syncs => PS#{UserId => Current + Cost}}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sync_timer, #{pending_syncs := PS, circuit := Circuit, failures := Fails} = State) ->
    NewState = case {maps:size(PS), Circuit} of
        {0, _} ->
            State;
        {_, open} when Fails > 0 ->
            %% Circuit open: try one sync (half-open)
            case try_sync_one(PS) of
                ok ->
                    logger:info("Circuit breaker: half-open → closed"),
                    do_sync_all(PS),
                    State#{pending_syncs => #{}, circuit => closed, failures => 0};
                error ->
                    logger:warning("Circuit breaker: still open (failure ~p)", [Fails]),
                    State  %% Keep pending, retry next cycle
            end;
        {_, _} ->
            %% Normal or closed: sync all
            FailCount = do_sync_all(PS),
            case FailCount of
                0 ->
                    State#{pending_syncs => #{}, circuit => closed, failures => 0};
                _ when Fails + FailCount >= 5 ->
                    logger:error("Circuit breaker: closed → open (~p consecutive failures)", [Fails + FailCount]),
                    State#{pending_syncs => #{}, circuit => open, failures => Fails + FailCount};
                _ ->
                    State#{pending_syncs => #{}, failures => Fails + FailCount}
            end
    end,
    schedule_sync(),
    {noreply, NewState}.

%%% Internal

do_sync_all(PS) ->
    maps:fold(fun(UserId, TotalCost, FailAcc) ->
        case ersub_repo:update_user_balance(UserId, -TotalCost) of
            {ok, _} -> FailAcc;
            {error, Reason} ->
                logger:error("Balance sync failed for user ~p: ~p", [UserId, Reason]),
                FailAcc + 1
        end
    end, 0, PS).

try_sync_one(PS) ->
    case maps:to_list(PS) of
        [{UserId, Cost} | _] ->
            case ersub_repo:update_user_balance(UserId, -Cost) of
                {ok, _} -> ok;
                _ -> error
            end;
        [] -> ok
    end.

load_balance_from_db(UserId) ->
    case ersub_repo:get_user_balance(UserId) of
        {ok, Balance} ->
            MicroBalance = balance_to_micro(Balance),
            ets:insert(?BALANCE_TABLE, {UserId, MicroBalance}),
            MicroBalance / 1000000;
        {error, _} ->
            0
    end.

do_sync_user(UserId) ->
    case ets:lookup(?BALANCE_TABLE, UserId) of
        [{_, MicroBalance}] ->
            NewBalance = MicroBalance / 1000000,
            ersub_repo:query(
                "UPDATE users SET balance_usd = $2, updated_at = NOW() WHERE id = $1",
                [UserId, NewBalance]);
        [] ->
            ok
    end.

schedule_sync() ->
    Interval = ersub_config_srv:get(billing_sync_interval_ms, ?SYNC_INTERVAL_MS),
    erlang:send_after(Interval, self(), sync_timer).

balance_to_micro(V) when is_integer(V) -> V * 1000000;
balance_to_micro(V) when is_float(V) -> trunc(V * 1000000);
balance_to_micro(V) when is_binary(V) ->
    case catch binary_to_float(V) of
        F when is_float(F) -> trunc(F * 1000000);
        _ ->
            case catch binary_to_integer(V) of
                I when is_integer(I) -> I * 1000000;
                _ -> 0
            end
    end;
balance_to_micro(_) -> 0.
