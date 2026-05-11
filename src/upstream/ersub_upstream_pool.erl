-module(ersub_upstream_pool).
-behaviour(gen_server).

-export([start_link/0]).
-export([request/5, request/6]).
-export([get_connection/3, return_connection/2, pool_stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(POOL_TABLE, ersub_conn_pool).
-define(LRU_TABLE, ersub_conn_lru).
-define(CONNECT_TIMEOUT, 10000).
-define(RESPONSE_TIMEOUT, 600000).
-define(MAX_POOLS, 5000).
-define(MAX_IDLE_PER_HOST, 120).
-define(IDLE_TIMEOUT_MS, 90000).     %% 90s
-define(CLEANUP_INTERVAL_MS, 30000). %% 30s

-record(pool_entry, {
    conn_pid    :: pid(),
    conn_mref   :: reference(),
    in_flight   :: integer(),
    last_used   :: integer(),    %% monotonic ms
    host        :: binary(),
    port        :: integer(),
    scheme      :: atom()
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec request(binary(), binary(), [{binary(), binary()}], binary(), map()) ->
    {ok, integer(), map(), binary()} | {error, term()}.
request(Method, Url, Headers, Body, Opts) ->
    request(Method, Url, Headers, Body, Opts, ?RESPONSE_TIMEOUT).

-spec request(binary(), binary(), [{binary(), binary()}], binary(), map(), integer()) ->
    {ok, integer(), map(), binary()} | {error, term()}.
request(Method, Url, Headers, Body, Opts, Timeout) ->
    case parse_url(Url) of
        {ok, Scheme, Host, Port, Path} ->
            PoolKey = get_pool_key(Opts, Host, Port),
            case get_connection(PoolKey, Scheme, {Host, Port}) of
                {ok, ConnPid} ->
                    StreamRef = send_request(ConnPid, Method, Path, Headers, Body),
                    Result = collect_response(ConnPid, StreamRef, Timeout),
                    %% Return connection to pool (decrement in_flight)
                    return_connection(PoolKey, ConnPid),
                    Result;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, {bad_url, Reason}}
    end.

%% Get a connection from pool (reuse) or create new.
-spec get_connection(binary(), atom(), {binary(), integer()}) ->
    {ok, pid()} | {error, term()}.
get_connection(PoolKey, Scheme, {Host, Port}) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?POOL_TABLE, PoolKey) of
        [{_, #pool_entry{conn_pid = Pid, in_flight = IF} = Entry}] ->
            case is_process_alive(Pid) of
                true ->
                    %% Reuse existing connection, increment in_flight
                    ets:insert(?POOL_TABLE, {PoolKey, Entry#pool_entry{
                        in_flight = IF + 1, last_used = Now}}),
                    ets:insert(?LRU_TABLE, {PoolKey, Now}),
                    {ok, Pid};
                false ->
                    %% Dead connection, remove and create new
                    ets:delete(?POOL_TABLE, PoolKey),
                    open_new_connection(PoolKey, Scheme, Host, Port)
            end;
        [] ->
            %% No pooled connection, check capacity then create
            maybe_evict(),
            open_new_connection(PoolKey, Scheme, Host, Port)
    end.

%% Return connection to pool (decrement in_flight).
-spec return_connection(binary(), pid()) -> ok.
return_connection(PoolKey, _ConnPid) ->
    case ets:lookup(?POOL_TABLE, PoolKey) of
        [{_, #pool_entry{in_flight = IF} = Entry}] when IF > 0 ->
            ets:insert(?POOL_TABLE, {PoolKey, Entry#pool_entry{
                in_flight = IF - 1,
                last_used = erlang:monotonic_time(millisecond)
            }});
        _ ->
            ok
    end,
    ok.

pool_stats() ->
    #{
        total_connections => ets:info(?POOL_TABLE, size),
        max_pools => ?MAX_POOLS
    }.

%%% gen_server callbacks

init([]) ->
    _ = ets:new(?POOL_TABLE, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?LRU_TABLE, [named_table, public, ordered_set]),
    schedule_cleanup(),
    logger:info("Upstream connection pool started (max=~p)", [?MAX_POOLS]),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    cleanup_idle_connections(),
    schedule_cleanup(),
    {noreply, State};

handle_info({'DOWN', _MRef, process, Pid, _Reason}, State) ->
    %% Connection process died, remove from pool
    ets:foldl(fun({Key, #pool_entry{conn_pid = P}}, Acc) when P =:= Pid ->
        ets:delete(?POOL_TABLE, Key),
        ets:delete(?LRU_TABLE, Key),
        Acc;
    (_, Acc) -> Acc
    end, ok, ?POOL_TABLE),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Close all pooled connections
    ets:foldl(fun({_, #pool_entry{conn_pid = Pid}}, _) ->
        catch gun:close(Pid)
    end, ok, ?POOL_TABLE),
    ok.

%%% Internal — Connection management

open_new_connection(PoolKey, Scheme, Host, Port) ->
    TransportOpts = case Scheme of
        https -> #{transport => tls, tls_opts => [{verify, verify_none}]};
        http -> #{}
    end,
    GunOpts = maps:merge(TransportOpts, #{
        connect_timeout => ?CONNECT_TIMEOUT,
        protocols => [http2, http],
        http2_opts => #{max_concurrent_streams => 50}
    }),
    HostStr = case is_binary(Host) of true -> binary_to_list(Host); false -> Host end,
    case gun:open(HostStr, Port, GunOpts) of
        {ok, ConnPid} ->
            MRef = monitor(process, ConnPid),
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT, MRef) of
                {ok, _Protocol} ->
                    Now = erlang:monotonic_time(millisecond),
                    Entry = #pool_entry{
                        conn_pid = ConnPid,
                        conn_mref = MRef,
                        in_flight = 1,
                        last_used = Now,
                        host = iolist_to_binary([Host]),
                        port = Port,
                        scheme = Scheme
                    },
                    ets:insert(?POOL_TABLE, {PoolKey, Entry}),
                    ets:insert(?LRU_TABLE, {PoolKey, Now}),
                    {ok, ConnPid};
                {error, Reason} ->
                    demonitor(MRef, [flush]),
                    gun:close(ConnPid),
                    {error, {connect, Reason}}
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

maybe_evict() ->
    Size = ets:info(?POOL_TABLE, size),
    case Size >= ?MAX_POOLS of
        true -> evict_lru();
        false -> ok
    end.

evict_lru() ->
    %% Find the least recently used connection with 0 in_flight
    case ets:first(?LRU_TABLE) of
        '$end_of_table' -> ok;
        Key ->
            case ets:lookup(?POOL_TABLE, Key) of
                [{_, #pool_entry{in_flight = 0, conn_pid = Pid, conn_mref = MRef}}] ->
                    demonitor(MRef, [flush]),
                    gun:close(Pid),
                    ets:delete(?POOL_TABLE, Key),
                    ets:delete(?LRU_TABLE, Key);
                [{_, #pool_entry{in_flight = _IF}}] ->
                    %% In-flight, skip and try next
                    ets:delete(?LRU_TABLE, Key),
                    evict_lru();
                [] ->
                    ets:delete(?LRU_TABLE, Key)
            end
    end.

cleanup_idle_connections() ->
    Now = erlang:monotonic_time(millisecond),
    Cutoff = Now - ?IDLE_TIMEOUT_MS,
    ets:foldl(fun({Key, #pool_entry{in_flight = 0, last_used = LU,
                                     conn_pid = Pid, conn_mref = MRef}}, Acc)
                  when LU < Cutoff ->
        demonitor(MRef, [flush]),
        gun:close(Pid),
        ets:delete(?POOL_TABLE, Key),
        ets:delete(?LRU_TABLE, Key),
        Acc + 1;
    (_, Acc) -> Acc
    end, 0, ?POOL_TABLE).

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup).

%% Get pool key using CLIPS strategy or default
get_pool_key(Opts, Host, Port) ->
    AccountId = maps:get(account_id, Opts, 0),
    ProxyEndpoint = maps:get(proxy_endpoint, Opts, <<>>),
    %% Use CLIPS pool_strategy.clp to determine pool key
    case ersub_clips_pool:with_worker(fun(W) ->
        gen_server:call(W, {evaluate_pool_strategy, #{
            account_id => AccountId,
            proxy_endpoint => ProxyEndpoint,
            platform => maps:get(platform, Opts, unknown)
        }}, 5000)
    end) of
        {ok, #{<<"pool-key">> := PoolKey}} ->
            PoolKey;
        _ ->
            %% Fallback: account_proxy mode
            iolist_to_binary([<<"acct:">>, integer_to_binary(AccountId),
                              <<":">>, Host, <<":">>, integer_to_binary(Port)])
    end.

%%% Internal — HTTP request/response

send_request(ConnPid, <<"POST">>, Path, Headers, Body) ->
    gun:post(ConnPid, Path, Headers, Body);
send_request(ConnPid, <<"GET">>, Path, Headers, _Body) ->
    gun:get(ConnPid, Path, Headers);
send_request(ConnPid, <<"PUT">>, Path, Headers, Body) ->
    gun:put(ConnPid, Path, Headers, Body);
send_request(ConnPid, <<"DELETE">>, Path, Headers, _Body) ->
    gun:delete(ConnPid, Path, Headers);
send_request(ConnPid, _, Path, Headers, Body) ->
    gun:post(ConnPid, Path, Headers, Body).

collect_response(ConnPid, StreamRef, Timeout) ->
    receive
        {gun_response, ConnPid, StreamRef, fin, Status, RespHeaders} ->
            {ok, Status, maps:from_list(RespHeaders), <<>>};
        {gun_response, ConnPid, StreamRef, nofin, Status, RespHeaders} ->
            collect_body(ConnPid, StreamRef, Status, maps:from_list(RespHeaders), [], Timeout);
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {stream_error, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {conn_error, Reason}};
        {'DOWN', _, process, ConnPid, Reason} ->
            {error, {down, Reason}}
    after Timeout ->
        {error, response_timeout}
    end.

collect_body(ConnPid, StreamRef, Status, Headers, Acc, Timeout) ->
    receive
        {gun_data, ConnPid, StreamRef, fin, Data} ->
            Body = iolist_to_binary(lists:reverse([Data | Acc])),
            {ok, Status, Headers, Body};
        {gun_data, ConnPid, StreamRef, nofin, Data} ->
            collect_body(ConnPid, StreamRef, Status, Headers, [Data | Acc], Timeout);
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {stream_error, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {conn_error, Reason}};
        {'DOWN', _, process, ConnPid, Reason} ->
            {error, {down, Reason}}
    after Timeout ->
        {error, body_timeout}
    end.

parse_url(Url) when is_binary(Url) ->
    parse_url(binary_to_list(Url));
parse_url(Url) ->
    case uri_string:parse(Url) of
        #{scheme := S, host := H} = Parsed ->
            Scheme = list_to_atom(S),
            Port = maps:get(port, Parsed, default_port(Scheme)),
            Path0 = maps:get(path, Parsed, "/"),
            Path = case Path0 of "" -> "/"; _ -> Path0 end,
            Query = maps:get(query, Parsed, ""),
            FullPath = case Query of
                "" -> list_to_binary(Path);
                Q -> list_to_binary(Path ++ "?" ++ Q)
            end,
            {ok, Scheme, list_to_binary(H), Port, FullPath};
        _ ->
            {error, invalid_url}
    end.

default_port(https) -> 443;
default_port(http) -> 80;
default_port(_) -> 443.
