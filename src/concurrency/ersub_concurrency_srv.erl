-module(ersub_concurrency_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([acquire/2, release/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Acquire a concurrency slot for a user.
%% Returns {ok, Ref} | {wait, WaitRef} | {rejected, queue_full}.
-spec acquire(integer(), integer()) ->
    {ok, reference()} | {wait, reference()} | {rejected, queue_full}.
acquire(UserId, MaxConcurrency) ->
    gen_server:call(?SERVER, {acquire, UserId, MaxConcurrency}, 30000).

%% Release a concurrency slot.
-spec release(integer(), reference()) -> ok.
release(UserId, Ref) ->
    gen_server:cast(?SERVER, {release, UserId, Ref}).

%%% gen_server callbacks

init([]) ->
    %% ETS table tracking active slots per user
    %% Key: {UserId, Ref}, Value: MonitorRef
    ets:new(ersub_conc_slots, [named_table, public, set]),
    %% ETS table counting active slots per user
    %% Key: UserId, Value: Count
    ets:new(ersub_conc_counts, [named_table, public, set]),
    logger:info("Concurrency control service started"),
    {ok, #{wait_queues => #{}}}.

handle_call({acquire, UserId, MaxConc}, From, #{wait_queues := WQ} = State) ->
    Current = get_count(UserId),
    WaitQueueExtra = ersub_config_srv:get(concurrency_wait_queue_extra, 20),
    if
        Current < MaxConc ->
            %% Slot available
            Ref = make_ref(),
            {CallerPid, _} = From,
            MRef = monitor(process, CallerPid),
            ets:insert(ersub_conc_slots, {{UserId, Ref}, MRef, CallerPid}),
            increment_count(UserId),
            {reply, {ok, Ref}, State};
        true ->
            %% Check wait queue size
            Queue = maps:get(UserId, WQ, queue:new()),
            WaitSize = queue:len(Queue),
            if
                WaitSize >= WaitQueueExtra ->
                    {reply, {rejected, queue_full}, State};
                true ->
                    %% Add to wait queue
                    WaitRef = make_ref(),
                    NewQueue = queue:in({From, WaitRef, MaxConc}, Queue),
                    NewWQ = maps:put(UserId, NewQueue, WQ),
                    {noreply, State#{wait_queues => NewWQ}}
            end
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({release, UserId, Ref}, State) ->
    case ets:lookup(ersub_conc_slots, {UserId, Ref}) of
        [{{_, _}, MRef, _Pid}] ->
            demonitor(MRef, [flush]),
            ets:delete(ersub_conc_slots, {UserId, Ref}),
            decrement_count(UserId),
            NewState = try_dequeue(UserId, State),
            {noreply, NewState};
        [] ->
            {noreply, State}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, Pid, _Reason}, State) ->
    %% Process crashed — find and release its slot
    case ets:match_object(ersub_conc_slots, {'_', MRef, Pid}) of
        [{{UserId, Ref}, _, _}] ->
            ets:delete(ersub_conc_slots, {UserId, Ref}),
            decrement_count(UserId),
            NewState = try_dequeue(UserId, State),
            {noreply, NewState};
        [] ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

%%% Internal

get_count(UserId) ->
    case ets:lookup(ersub_conc_counts, UserId) of
        [{_, Count}] -> Count;
        [] -> 0
    end.

increment_count(UserId) ->
    case ets:lookup(ersub_conc_counts, UserId) of
        [{_, _}] ->
            ets:update_counter(ersub_conc_counts, UserId, {2, 1});
        [] ->
            ets:insert(ersub_conc_counts, {UserId, 1}),
            1
    end.

decrement_count(UserId) ->
    case ets:lookup(ersub_conc_counts, UserId) of
        [{_, Count}] when Count > 1 ->
            ets:update_counter(ersub_conc_counts, UserId, {2, -1});
        [{_, _}] ->
            ets:delete(ersub_conc_counts, UserId);
        [] ->
            0
    end.

try_dequeue(UserId, #{wait_queues := WQ} = State) ->
    case maps:get(UserId, WQ, undefined) of
        undefined -> State;
        Queue ->
            case queue:out(Queue) of
                {{value, {From, _WaitRef, MaxConc}}, NewQueue} ->
                    Current = get_count(UserId),
                    if
                        Current < MaxConc ->
                            Ref = make_ref(),
                            {CallerPid, _} = From,
                            MRef = monitor(process, CallerPid),
                            ets:insert(ersub_conc_slots, {{UserId, Ref}, MRef, CallerPid}),
                            increment_count(UserId),
                            gen_server:reply(From, {ok, Ref}),
                            NewWQ = case queue:is_empty(NewQueue) of
                                true -> maps:remove(UserId, WQ);
                                false -> maps:put(UserId, NewQueue, WQ)
                            end,
                            State#{wait_queues => NewWQ};
                        true ->
                            State
                    end;
                {empty, _} ->
                    State#{wait_queues => maps:remove(UserId, WQ)}
            end
    end.
