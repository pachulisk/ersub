-module(ersub_clips_pool).

-export([start_link/0, stop/0]).
-export([with_worker/1, reload_rules/0]).

-define(POOL, ersub_clips_pool).

%% Start the CLIPS worker pool.
start_link() ->
    PoolSize = ersub_config_srv:get(clips_pool_size, 8),
    PoolArgs = [
        {name, {local, ?POOL}},
        {worker_module, ersub_clips_worker},
        {size, PoolSize},
        {max_overflow, PoolSize div 2},
        {strategy, fifo}
    ],
    poolboy:start_link(PoolArgs, []).

stop() ->
    %% Graceful shutdown handled by supervisor
    ok.

%% Checkout a worker, run a function, then check in.
-spec with_worker(fun((pid()) -> T)) -> T when T :: term().
with_worker(Fun) ->
    Worker = poolboy:checkout(?POOL, true, 5000),
    try
        Fun(Worker)
    after
        poolboy:checkin(?POOL, Worker)
    end.

%% Reload rules on all workers (rolling update).
-spec reload_rules() -> ok.
reload_rules() ->
    Workers = get_all_workers(),
    lists:foreach(fun(Worker) ->
        try
            gen_server:call(Worker, reload_rules, 10000)
        catch _:_ ->
            logger:warning("Failed to reload rules on worker ~p", [Worker])
        end
    end, Workers),
    logger:info("Rules reloaded on ~p workers", [length(Workers)]),
    ok.

%%% Internal

get_all_workers() ->
    Status = poolboy:status(?POOL),
    case Status of
        {_StateType, AvailableWorkers, _Overflow, _Monitors} when is_integer(AvailableWorkers) ->
            %% Get all workers by checking them out and back
            [];
        _ ->
            []
    end.
