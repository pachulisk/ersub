-module(ersub_upstream_pool).
-behaviour(gen_server).

-export([start_link/0]).
-export([request/5, request/6]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(CONNECT_TIMEOUT, 10000).
-define(RESPONSE_TIMEOUT, 600000). %% 10 min for LLM

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Make an HTTP request through the pool.
%% Returns {ok, Status, Headers, Body} | {error, Reason}
-spec request(binary(), binary(), [{binary(), binary()}], binary(), map()) ->
    {ok, integer(), map(), binary()} | {error, term()}.
request(Method, Url, Headers, Body, Opts) ->
    request(Method, Url, Headers, Body, Opts, ?RESPONSE_TIMEOUT).

-spec request(binary(), binary(), [{binary(), binary()}], binary(), map(), integer()) ->
    {ok, integer(), map(), binary()} | {error, term()}.
request(Method, Url, Headers, Body, _Opts, Timeout) ->
    case parse_url(Url) of
        {ok, Scheme, Host, Port, Path} ->
            do_request(Method, Scheme, Host, Port, Path, Headers, Body, Timeout);
        {error, Reason} ->
            {error, {bad_url, Reason}}
    end.

%%% gen_server callbacks

init([]) ->
    logger:info("Upstream connection pool started"),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% Internal — direct gun request (pool reuse deferred to P2-17 full impl)

do_request(Method, Scheme, Host, Port, Path, Headers, Body, Timeout) ->
    TransportOpts = case Scheme of
        https -> #{transport => tls, tls_opts => [{verify, verify_none}]};
        http -> #{}
    end,
    GunOpts = maps:merge(TransportOpts, #{
        connect_timeout => ?CONNECT_TIMEOUT,
        protocols => [http2, http],
        http2_opts => #{
            max_concurrent_streams => 50
        }
    }),
    case gun:open(binary_to_list(Host), Port, GunOpts) of
        {ok, ConnPid} ->
            MRef = monitor(process, ConnPid),
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT, MRef) of
                {ok, _Protocol} ->
                    StreamRef = send_request(ConnPid, Method, Path, Headers, Body),
                    Result = collect_response(ConnPid, StreamRef, MRef, Timeout),
                    demonitor(MRef, [flush]),
                    gun:close(ConnPid),
                    Result;
                {error, Reason} ->
                    demonitor(MRef, [flush]),
                    gun:close(ConnPid),
                    {error, {connect, Reason}}
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

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

collect_response(ConnPid, StreamRef, MRef, Timeout) ->
    receive
        {gun_response, ConnPid, StreamRef, fin, Status, RespHeaders} ->
            {ok, Status, maps:from_list(RespHeaders), <<>>};
        {gun_response, ConnPid, StreamRef, nofin, Status, RespHeaders} ->
            collect_body(ConnPid, StreamRef, MRef, Status,
                         maps:from_list(RespHeaders), [], Timeout);
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {stream_error, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {conn_error, Reason}};
        {'DOWN', MRef, process, ConnPid, Reason} ->
            {error, {down, Reason}}
    after Timeout ->
        {error, response_timeout}
    end.

collect_body(ConnPid, StreamRef, MRef, Status, Headers, Acc, Timeout) ->
    receive
        {gun_data, ConnPid, StreamRef, fin, Data} ->
            Body = iolist_to_binary(lists:reverse([Data | Acc])),
            {ok, Status, Headers, Body};
        {gun_data, ConnPid, StreamRef, nofin, Data} ->
            collect_body(ConnPid, StreamRef, MRef, Status, Headers,
                         [Data | Acc], Timeout);
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {stream_error, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {conn_error, Reason}};
        {'DOWN', MRef, process, ConnPid, Reason} ->
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
            Path = case Path0 of
                "" -> "/";
                _ -> Path0
            end,
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
