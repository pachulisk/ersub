-module(ersub_quota_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([check_quota/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Check if a user's subscription quota allows an additional cost.
%% Returns ok | {error, {quota_exceeded, daily|weekly|monthly}}.
-spec check_quota(integer(), integer(), number()) ->
    ok | {error, {quota_exceeded, atom()}}.
check_quota(UserId, GroupId, AdditionalCost) ->
    case ersub_repo:query(
        "SELECT s.id, s.daily_usage_usd, s.weekly_usage_usd, s.monthly_usage_usd, "
        "g.daily_limit_usd, g.weekly_limit_usd, g.monthly_limit_usd "
        "FROM user_subscriptions s JOIN groups g ON s.group_id = g.id "
        "WHERE s.user_id = $1 AND s.group_id = $2 AND s.status = 'active'",
        [UserId, GroupId]
    ) of
        {ok, _, [{_SubId, DUsage, WUsage, MUsage, DLimit, WLimit, MLimit}]} ->
            check_limits(AdditionalCost,
                         to_num(DUsage), to_num(WUsage), to_num(MUsage),
                         to_num(DLimit), to_num(WLimit), to_num(MLimit));
        {ok, _, []} ->
            ok; %% No subscription = no quota limits (balance-based)
        {error, _} ->
            ok %% On error, fail open
    end.

%%% gen_server callbacks

init([]) ->
    schedule_daily_reset(),
    schedule_weekly_reset(),
    schedule_monthly_reset(),
    logger:info("Quota service started"),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(daily_reset, State) ->
    reset_daily_quotas(),
    schedule_daily_reset(),
    {noreply, State};

handle_info(weekly_reset, State) ->
    reset_weekly_quotas(),
    schedule_weekly_reset(),
    {noreply, State};

handle_info(monthly_reset, State) ->
    reset_monthly_quotas(),
    schedule_monthly_reset(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%% Internal

check_limits(Cost, DUsage, _WUsage, _MUsage, DLimit, _WLimit, _MLimit)
  when DLimit =/= null, DLimit > 0, DUsage + Cost > DLimit ->
    {error, {quota_exceeded, daily}};
check_limits(Cost, _DUsage, WUsage, _MUsage, _DLimit, WLimit, _MLimit)
  when WLimit =/= null, WLimit > 0, WUsage + Cost > WLimit ->
    {error, {quota_exceeded, weekly}};
check_limits(Cost, _DUsage, _WUsage, MUsage, _DLimit, _WLimit, MLimit)
  when MLimit =/= null, MLimit > 0, MUsage + Cost > MLimit ->
    {error, {quota_exceeded, monthly}};
check_limits(_, _, _, _, _, _, _) ->
    ok.

reset_daily_quotas() ->
    case ersub_repo:squery(
        "UPDATE user_subscriptions SET daily_usage_usd = 0, "
        "daily_window_start = NOW() WHERE status = 'active'"
    ) of
        {ok, _, _} -> logger:info("Daily quotas reset");
        _ -> ok
    end.

reset_weekly_quotas() ->
    case ersub_repo:squery(
        "UPDATE user_subscriptions SET weekly_usage_usd = 0, "
        "weekly_window_start = NOW() WHERE status = 'active'"
    ) of
        {ok, _, _} -> logger:info("Weekly quotas reset");
        _ -> ok
    end.

reset_monthly_quotas() ->
    case ersub_repo:squery(
        "UPDATE user_subscriptions SET monthly_usage_usd = 0, "
        "monthly_window_start = NOW() WHERE status = 'active'"
    ) of
        {ok, _, _} -> logger:info("Monthly quotas reset");
        _ -> ok
    end.

schedule_daily_reset() ->
    Ms = ms_until_next_hour(0),
    erlang:send_after(Ms, self(), daily_reset).

schedule_weekly_reset() ->
    %% Reset on Monday at midnight — approximate with 7 days
    erlang:send_after(ms_until_next_hour(0), self(), weekly_reset).

schedule_monthly_reset() ->
    %% Reset on 1st at midnight — approximate with 30 days
    erlang:send_after(ms_until_next_hour(0), self(), monthly_reset).

ms_until_next_hour(TargetHour) ->
    {_, {H, M, S}} = calendar:universal_time(),
    SecsRemaining = case TargetHour of
        0 -> (24 - H - 1) * 3600 + (60 - M - 1) * 60 + (60 - S);
        _ -> max(1, (TargetHour - H) * 3600 - M * 60 - S)
    end,
    max(60000, SecsRemaining * 1000).

to_num(null) -> null;
to_num(V) when is_binary(V) ->
    try binary_to_float(V) catch _:_ ->
        try binary_to_integer(V) * 1.0 catch _:_ -> 0.0 end
    end;
to_num(V) when is_integer(V) -> V * 1.0;
to_num(V) when is_float(V) -> V;
to_num(_) -> 0.0.
