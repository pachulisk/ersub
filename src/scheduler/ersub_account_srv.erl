-module(ersub_account_srv).
-behaviour(gen_server).

-export([start_link/1]).
-export([get_state/1, get_stats/1, record_success/2, record_error/2,
         update_status/2, is_schedulable/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(EWMA_ALPHA, 0.2).
-define(RATE_LIMIT_COOLDOWN_MS, 60000).    %% 60s
-define(OVERLOAD_COOLDOWN_MS, 30000).      %% 30s
-define(TEMP_UNSCHED_MS, 600000).          %% 10min
-define(STATUS_CHECK_INTERVAL_MS, 10000).  %% check recovery every 10s

-record(state, {
    id              :: integer(),
    platform        :: binary(),
    account_type    :: binary(),
    credentials     :: map(),
    status          :: active | rate_limited | overloaded | error | temp_unschedulable,
    priority        :: integer(),
    concurrency     :: integer(),
    load_factor     :: integer() | undefined,
    rate_multiplier :: float() | undefined,
    base_url        :: binary() | undefined,
    %% EWMA stats
    ewma_error_rate :: float(),
    ewma_ttft_ms    :: float(),
    current_load    :: integer(),
    %% Recovery timestamps (monotonic ms)
    rate_limited_until :: integer() | undefined,
    overload_until     :: integer() | undefined,
    temp_unsched_until :: integer() | undefined
}).

%%% API

start_link(AccountData) ->
    Id = maps:get(id, AccountData),
    gen_server:start_link({via, gproc, {n, l, {account, Id}}}, ?MODULE, AccountData, []).

get_state(Id) ->
    gen_server:call(via(Id), get_state).

get_stats(Id) ->
    gen_server:call(via(Id), get_stats).

%% Record a successful request with first-token latency.
record_success(Id, TtftMs) ->
    gen_server:cast(via(Id), {success, TtftMs}).

%% Record a failed request with HTTP status code.
record_error(Id, StatusCode) ->
    gen_server:cast(via(Id), {error, StatusCode}).

%% Manually update status.
update_status(Id, NewStatus) ->
    gen_server:call(via(Id), {update_status, NewStatus}).

%% Check if account is currently schedulable (no blocking state).
is_schedulable(Id) ->
    gen_server:call(via(Id), is_schedulable).

%%% gen_server callbacks

init(Data) ->
    State = #state{
        id = maps:get(id, Data),
        platform = maps:get(platform, Data),
        account_type = maps:get(account_type, Data),
        credentials = maps:get(credentials, Data, #{}),
        status = binary_to_status(maps:get(status, Data, <<"active">>)),
        priority = maps:get(priority, Data, 100),
        concurrency = maps:get(concurrency, Data, 5),
        load_factor = maps:get(load_factor, Data, undefined),
        rate_multiplier = maps:get(rate_multiplier, Data, undefined),
        base_url = maps:get(base_url, Data, undefined),
        ewma_error_rate = 0.0,
        ewma_ttft_ms = 0.0,
        current_load = 0,
        rate_limited_until = undefined,
        overload_until = undefined,
        temp_unsched_until = undefined
    },
    schedule_status_check(),
    {ok, State}.

handle_call(get_state, _From, State) ->
    {reply, state_to_map(State), State};

handle_call(get_stats, _From, State) ->
    Stats = #{
        id => State#state.id,
        status => State#state.status,
        priority => State#state.priority,
        ewma_error_rate => State#state.ewma_error_rate,
        ewma_ttft_ms => State#state.ewma_ttft_ms,
        current_load => State#state.current_load,
        load_rate => load_rate(State),
        concurrency => State#state.concurrency,
        platform => State#state.platform,
        rate_multiplier => State#state.rate_multiplier
    },
    {reply, Stats, State};

handle_call(is_schedulable, _From, State) ->
    Now = erlang:monotonic_time(millisecond),
    Schedulable = (State#state.status =:= active) andalso
                  not is_cooldown_active(State, Now),
    {reply, Schedulable, State};

handle_call({update_status, NewStatus}, _From, State) ->
    {reply, ok, State#state{status = NewStatus}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({success, TtftMs}, State) ->
    NewEwmaError = ewma(State#state.ewma_error_rate, 0.0, ?EWMA_ALPHA),
    NewEwmaTtft = ewma(State#state.ewma_ttft_ms, to_float(TtftMs), ?EWMA_ALPHA),
    NewLoad = max(0, State#state.current_load - 1),
    {noreply, State#state{
        ewma_error_rate = NewEwmaError,
        ewma_ttft_ms = NewEwmaTtft,
        current_load = NewLoad
    }};

handle_cast({error, StatusCode}, State) ->
    NewEwmaError = ewma(State#state.ewma_error_rate, 1.0, ?EWMA_ALPHA),
    NewLoad = max(0, State#state.current_load - 1),
    Now = erlang:monotonic_time(millisecond),
    NewState = case StatusCode of
        429 ->
            State#state{
                status = rate_limited,
                rate_limited_until = Now + ?RATE_LIMIT_COOLDOWN_MS,
                ewma_error_rate = NewEwmaError,
                current_load = NewLoad
            };
        529 ->
            State#state{
                status = overloaded,
                overload_until = Now + ?OVERLOAD_COOLDOWN_MS,
                ewma_error_rate = NewEwmaError,
                current_load = NewLoad
            };
        Code when Code =:= 502; Code =:= 503 ->
            State#state{
                status = overloaded,
                overload_until = Now + ?OVERLOAD_COOLDOWN_MS,
                ewma_error_rate = NewEwmaError,
                current_load = NewLoad
            };
        _ ->
            State#state{
                ewma_error_rate = NewEwmaError,
                current_load = NewLoad
            }
    end,
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_status, State) ->
    Now = erlang:monotonic_time(millisecond),
    NewState = maybe_recover(State, Now),
    schedule_status_check(),
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

%%% Internal

via(Id) ->
    {via, gproc, {n, l, {account, Id}}}.

schedule_status_check() ->
    erlang:send_after(?STATUS_CHECK_INTERVAL_MS, self(), check_status).

ewma(OldValue, NewSample, Alpha) ->
    Alpha * NewSample + (1.0 - Alpha) * OldValue.

to_float(V) when is_integer(V) -> V * 1.0;
to_float(V) when is_float(V) -> V.

load_rate(#state{current_load = Load, concurrency = Conc, load_factor = LF}) ->
    EffectiveMax = case LF of
        undefined -> Conc;
        F when is_integer(F), F > 0 -> F;
        _ -> Conc
    end,
    case EffectiveMax of
        0 -> 0.0;
        Max -> min(1.0, Load / Max)
    end.

is_cooldown_active(State, Now) ->
    check_until(State#state.rate_limited_until, Now) orelse
    check_until(State#state.overload_until, Now) orelse
    check_until(State#state.temp_unsched_until, Now).

check_until(undefined, _Now) -> false;
check_until(Until, Now) -> Now < Until.

maybe_recover(State, Now) ->
    S1 = case State#state.status of
        rate_limited ->
            case check_until(State#state.rate_limited_until, Now) of
                false ->
                    logger:info("Account ~p recovered from rate_limited", [State#state.id]),
                    State#state{status = active, rate_limited_until = undefined};
                true -> State
            end;
        overloaded ->
            case check_until(State#state.overload_until, Now) of
                false ->
                    logger:info("Account ~p recovered from overloaded", [State#state.id]),
                    State#state{status = active, overload_until = undefined};
                true -> State
            end;
        temp_unschedulable ->
            case check_until(State#state.temp_unsched_until, Now) of
                false ->
                    logger:info("Account ~p recovered from temp_unschedulable", [State#state.id]),
                    State#state{status = active, temp_unsched_until = undefined};
                true -> State
            end;
        _ -> State
    end,
    S1.

state_to_map(S) ->
    #{
        id => S#state.id,
        platform => S#state.platform,
        account_type => S#state.account_type,
        credentials => S#state.credentials,
        status => S#state.status,
        priority => S#state.priority,
        concurrency => S#state.concurrency,
        load_factor => S#state.load_factor,
        rate_multiplier => S#state.rate_multiplier,
        base_url => S#state.base_url,
        ewma_error_rate => S#state.ewma_error_rate,
        ewma_ttft_ms => S#state.ewma_ttft_ms,
        current_load => S#state.current_load,
        load_rate => load_rate(S)
    }.

binary_to_status(<<"active">>) -> active;
binary_to_status(<<"rate_limited">>) -> rate_limited;
binary_to_status(<<"overloaded">>) -> overloaded;
binary_to_status(<<"error">>) -> error;
binary_to_status(<<"temp_unschedulable">>) -> temp_unschedulable;
binary_to_status(active) -> active;
binary_to_status(S) when is_atom(S) -> S;
binary_to_status(_) -> active.
