-module(ersub_balance_notify_srv).
-behaviour(gen_server).

-export([start_link/0, check_and_notify/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(CHECK_INTERVAL_MS, 300000). %% 5 minutes
-define(NOTIFIED_TABLE, ersub_balance_notified).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Check a user's balance against their notification threshold.
-spec check_and_notify(integer()) -> ok | not_configured | already_notified.
check_and_notify(UserId) ->
    gen_server:cast(?SERVER, {check, UserId}).

init([]) ->
    ets:new(?NOTIFIED_TABLE, [named_table, public, set]),
    logger:info("Balance notify service started"),
    {ok, #{}}.

handle_call(_, _From, State) -> {reply, ok, State}.

handle_cast({check, UserId}, State) ->
    do_check(UserId),
    {noreply, State};
handle_cast(_, State) -> {noreply, State}.

handle_info(_, State) -> {noreply, State}.

do_check(UserId) ->
    case ersub_repo:query(
        "SELECT balance_usd, balance_notify_enabled, balance_notify_threshold, "
        "balance_notify_type, notify_emails "
        "FROM users WHERE id = $1 AND deleted_at IS NULL", [UserId]) of
        {ok, _, [{Balance, true, Threshold, Type, EmailsJson}]}
          when Threshold =/= null ->
            BalanceFloat = to_float(Balance),
            ThresholdFloat = to_float(Threshold),
            ShouldNotify = case Type of
                <<"percentage">> -> BalanceFloat =< ThresholdFloat / 100.0 * BalanceFloat;
                _ -> BalanceFloat =< ThresholdFloat
            end,
            case ShouldNotify of
                true ->
                    %% Dedup: max once per day
                    Today = element(1, calendar:universal_time()),
                    case ets:lookup(?NOTIFIED_TABLE, {UserId, Today}) of
                        [] ->
                            ets:insert(?NOTIFIED_TABLE, {{UserId, Today}, true}),
                            Emails = case EmailsJson of
                                null -> [];
                                _ -> try jsx:decode(EmailsJson) catch _:_ -> [] end
                            end,
                            logger:info("Balance notification: user=~p balance=~p threshold=~p emails=~p",
                                       [UserId, BalanceFloat, ThresholdFloat, Emails]);
                        _ ->
                            ok
                    end;
                false -> ok
            end;
        _ -> ok
    end.

to_float(V) when is_binary(V) ->
    try binary_to_float(V) catch _:_ ->
        try binary_to_integer(V) * 1.0 catch _:_ -> 0.0 end end;
to_float(V) when is_float(V) -> V;
to_float(V) when is_integer(V) -> V * 1.0;
to_float(_) -> 0.0.
