-module(ersub_pg_worker).
-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%%% poolboy_worker callback

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%%% gen_server callbacks

init(Args) ->
    Host = proplists:get_value(host, Args, "localhost"),
    Port = proplists:get_value(port, Args, 5432),
    User = proplists:get_value(username, Args, "postgres"),
    Pass = proplists:get_value(password, Args, ""),
    DB = proplists:get_value(database, Args, "ersub"),
    Timeout = proplists:get_value(timeout, Args, 10000),
    case epgsql:connect(#{
        host => Host,
        port => Port,
        username => User,
        password => Pass,
        database => DB,
        timeout => Timeout
    }) of
        {ok, Conn} ->
            {ok, #{conn => Conn}};
        {error, Reason} ->
            {stop, {connection_failed, Reason}}
    end.

handle_call({squery, SQL}, _From, #{conn := Conn} = State) ->
    Result = epgsql:squery(Conn, SQL),
    {reply, Result, State};

handle_call({equery, SQL, Params}, _From, #{conn := Conn} = State) ->
    Result = epgsql:equery(Conn, SQL, Params),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{conn := Conn}) ->
    epgsql:close(Conn),
    ok;
terminate(_Reason, _State) ->
    ok.
