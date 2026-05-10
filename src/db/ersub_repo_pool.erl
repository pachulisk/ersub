-module(ersub_repo_pool).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_conn/0, return_conn/1, with_conn/1, transaction/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(POOL, ersub_pg_pool).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_conn() -> {ok, pid()} | {error, term()}.
get_conn() ->
    try
        Worker = poolboy:checkout(?POOL, true, 5000),
        {ok, Worker}
    catch
        exit:{timeout, _} -> {error, pool_timeout}
    end.

-spec return_conn(pid()) -> ok.
return_conn(Worker) ->
    poolboy:checkin(?POOL, Worker).

-spec with_conn(fun((pid()) -> T)) -> T when T :: term().
with_conn(Fun) ->
    {ok, Worker} = get_conn(),
    try
        Fun(Worker)
    after
        return_conn(Worker)
    end.

-spec transaction(fun((pid()) -> T)) -> {ok, T} | {error, term()} when T :: term().
transaction(Fun) ->
    with_conn(fun(Worker) ->
        case gen_server:call(Worker, {squery, "BEGIN"}) of
            {ok, _, _} ->
                try
                    Result = Fun(Worker),
                    case gen_server:call(Worker, {squery, "COMMIT"}) of
                        {ok, _, _} -> {ok, Result};
                        Error -> {error, {commit_failed, Error}}
                    end
                catch
                    Class:Reason:Stack ->
                        gen_server:call(Worker, {squery, "ROLLBACK"}),
                        erlang:raise(Class, Reason, Stack)
                end;
            Error ->
                {error, {begin_failed, Error}}
        end
    end).

%%% gen_server callbacks

init([]) ->
    Host = ersub_config_srv:get(database_host, "localhost"),
    Port = ersub_config_srv:get(database_port, 5432),
    User = ersub_config_srv:get(database_user, "postgres"),
    Password = ersub_config_srv:get(database_password, ""),
    Database = ersub_config_srv:get(database_database, "ersub"),
    PoolSize = ersub_config_srv:get(database_pool_size, 20),

    PoolArgs = [
        {name, {local, ?POOL}},
        {worker_module, ersub_pg_worker},
        {size, PoolSize},
        {max_overflow, PoolSize div 2},
        {strategy, fifo}
    ],
    WorkerArgs = [
        {host, Host},
        {port, Port},
        {username, User},
        {password, Password},
        {database, Database},
        {timeout, 10000}
    ],
    case poolboy:start_link(PoolArgs, WorkerArgs) of
        {ok, Pool} ->
            logger:info("PostgreSQL connection pool started: ~s:~p/~s (pool_size=~p)",
                        [Host, Port, Database, PoolSize]),
            {ok, #{pool => Pool}};
        {error, Reason} ->
            logger:error("Failed to start PostgreSQL pool: ~p", [Reason]),
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
