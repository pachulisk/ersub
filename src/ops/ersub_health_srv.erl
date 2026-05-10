-module(ersub_health_srv).
-behaviour(gen_server).

-export([start_link/0, get_score/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(CALC_INTERVAL_MS, 30000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_score() -> map().
get_score() ->
    gen_server:call(?SERVER, get_score).

init([]) ->
    schedule_calc(),
    {ok, #{score => 100, components => #{}}}.

handle_call(get_score, _From, State) ->
    {reply, State, State};
handle_call(_, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info(calc, _State) ->
    Score = calculate_health(),
    schedule_calc(),
    {noreply, Score}.

schedule_calc() ->
    erlang:send_after(?CALC_INTERVAL_MS, self(), calc).

calculate_health() ->
    Db = check_component(fun() -> ersub_repo:squery("SELECT 1") end),
    Clips = check_component(fun() ->
        ersub_clips_pool:with_worker(fun(W) -> ersub_clips_worker:ping(W) end)
    end),
    Accounts = length(ersub_platform_sup:list_accounts()),
    Components = #{database => Db, clips_pool => Clips, active_accounts => Accounts},
    Overall = case {Db, Clips} of
        {healthy, healthy} -> 100;
        {healthy, _} -> 70;
        {_, healthy} -> 50;
        _ -> 20
    end,
    #{score => Overall, components => Components}.

check_component(Fun) ->
    try case Fun() of {ok, _, _} -> healthy; ok -> healthy; _ -> degraded end
    catch _:_ -> unhealthy end.
