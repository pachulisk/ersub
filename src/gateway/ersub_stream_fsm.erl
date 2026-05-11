-module(ersub_stream_fsm).
-behaviour(gen_statem).

-export([start/4, stop/1]).
-export([init/1, callback_mode/0, terminate/3]).
-export([connecting/3, streaming/3, done/3]).

-record(data, {
    caller        :: pid(),
    req           :: cowboy_req:req() | undefined,
    conn_pid      :: pid() | undefined,
    conn_mref     :: reference() | undefined,
    stream_ref    :: reference() | undefined,
    buffer        :: binary(),
    accumulated   :: map(),
    start_time    :: integer(),
    first_token   :: integer() | undefined,
    account_id    :: integer(),
    request_id    :: binary(),
    model         :: binary()
}).

%%% API

%% Start streaming: opens gun connection, sends request, streams SSE back.
%% Caller must have already sent chunked response headers via cowboy.
%% Returns {ok, Pid} — the FSM process. It sends chunks to caller as messages:
%%   {stream_chunk, Pid, Data}
%%   {stream_done, Pid, Accumulated}
%%   {stream_error, Pid, Reason}
-spec start(map(), [{binary(), binary()}], binary(), map()) ->
    {ok, pid()} | {error, term()}.
start(ConnInfo, Headers, Body, Opts) ->
    gen_statem:start(?MODULE, {self(), ConnInfo, Headers, Body, Opts}, []).

stop(Pid) ->
    gen_statem:stop(Pid).

%%% gen_statem callbacks

callback_mode() -> state_functions.

init({Caller, ConnInfo, Headers, Body, Opts}) ->
    #{scheme := Scheme, host := Host, port := Port, path := Path} = ConnInfo,
    TransportOpts = case Scheme of
        https -> #{transport => tls, tls_opts => [{verify, verify_none}]};
        http -> #{}
    end,
    GunOpts = maps:merge(TransportOpts, #{
        connect_timeout => 10000,
        protocols => [http2, http]
    }),
    case gun:open(binary_to_list(Host), Port, GunOpts) of
        {ok, ConnPid} ->
            MRef = monitor(process, ConnPid),
            Data = #data{
                caller = Caller,
                conn_pid = ConnPid,
                conn_mref = MRef,
                buffer = <<>>,
                accumulated = #{
                    input_tokens => 0,
                    output_tokens => 0,
                    cache_read_tokens => 0,
                    cache_creation_tokens => 0
                },
                start_time = erlang:monotonic_time(millisecond),
                account_id = maps:get(account_id, Opts, 0),
                request_id = maps:get(request_id, Opts, <<>>),
                model = maps:get(model, Opts, <<>>)
            },
            %% Wait for connection up, then send the request
            case gun:await_up(ConnPid, 10000, MRef) of
                {ok, _} ->
                    StreamRef = gun:post(ConnPid, Path, Headers, Body),
                    {ok, connecting, Data#data{stream_ref = StreamRef}};
                {error, Reason} ->
                    gun:close(ConnPid),
                    Caller ! {stream_error, self(), {connect_failed, Reason}},
                    {stop, normal}
            end;
        {error, Reason} ->
            Caller ! {stream_error, self(), {open_failed, Reason}},
            {stop, normal}
    end.

%% CONNECTING — waiting for upstream response headers
connecting(info, {gun_response, ConnPid, StreamRef, nofin, Status, RespHeaders},
           #data{conn_pid = ConnPid, stream_ref = StreamRef, caller = Caller} = Data)
  when Status >= 200, Status < 300 ->
    %% Success — start streaming
    Caller ! {stream_headers, self(), Status, RespHeaders},
    {next_state, streaming, Data};

connecting(info, {gun_response, ConnPid, StreamRef, nofin, Status, RespHeaders},
           #data{conn_pid = ConnPid, stream_ref = StreamRef, caller = Caller} = Data) ->
    %% Non-2xx: consult CLIPS failover rules
    case evaluate_failover(Status, Data) of
        switch_account ->
            Caller ! {stream_failover, self(), {switch, Status, maps:from_list(RespHeaders)}},
            cleanup(Data),
            {stop, normal};
        _ ->
            collect_error_body(ConnPid, StreamRef, Status, RespHeaders, Caller, Data)
    end;

connecting(info, {gun_response, ConnPid, StreamRef, fin, Status, RespHeaders},
           #data{conn_pid = ConnPid, stream_ref = StreamRef, caller = Caller} = Data) ->
    case evaluate_failover(Status, Data) of
        switch_account ->
            Caller ! {stream_failover, self(), {switch, Status, maps:from_list(RespHeaders)}},
            cleanup(Data),
            {stop, normal};
        _ ->
            Caller ! {stream_error, self(), {upstream_error, Status, maps:from_list(RespHeaders), <<>>}},
            cleanup(Data),
            {stop, normal}
    end;

connecting(info, {gun_error, ConnPid, _StreamRef, Reason},
           #data{conn_pid = ConnPid, caller = Caller} = Data) ->
    Caller ! {stream_error, self(), {gun_error, Reason}},
    cleanup(Data),
    {stop, normal};

connecting(info, {'DOWN', MRef, process, ConnPid, Reason},
           #data{conn_pid = ConnPid, conn_mref = MRef, caller = Caller} = Data) ->
    Caller ! {stream_error, self(), {conn_down, Reason}},
    {stop, normal, Data#data{conn_pid = undefined}}.

%% STREAMING — forwarding SSE chunks
streaming(info, {gun_data, ConnPid, StreamRef, nofin, Chunk},
          #data{conn_pid = ConnPid, stream_ref = StreamRef} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, Chunk/binary>>,
    {Events, Remaining} = parse_sse_events(NewBuffer),
    Data2 = forward_and_accumulate(Events, Data#data{buffer = Remaining}),
    {keep_state, Data2};

streaming(info, {gun_data, ConnPid, StreamRef, fin, Chunk},
          #data{conn_pid = ConnPid, stream_ref = StreamRef, caller = Caller} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, Chunk/binary>>,
    {Events, _} = parse_sse_events(NewBuffer),
    Data2 = forward_and_accumulate(Events, Data),
    Caller ! {stream_done, self(), Data2#data.accumulated},
    cleanup(Data2),
    {next_state, done, Data2, [{next_event, internal, finalize}]};

streaming(info, {gun_error, ConnPid, _StreamRef, Reason},
          #data{conn_pid = ConnPid, caller = Caller} = Data) ->
    Caller ! {stream_error, self(), {mid_stream_error, Reason}},
    cleanup(Data),
    {stop, normal};

streaming(info, {'DOWN', MRef, process, ConnPid, Reason},
          #data{conn_pid = ConnPid, conn_mref = MRef, caller = Caller} = Data) ->
    Caller ! {stream_error, self(), {conn_down_mid_stream, Reason}},
    {stop, normal, Data#data{conn_pid = undefined}}.

%% DONE
done(internal, finalize, Data) ->
    Duration = erlang:monotonic_time(millisecond) - Data#data.start_time,
    %% Log usage asynchronously
    ersub_usage_logger:log(maps:merge(Data#data.accumulated, #{
        account_id => Data#data.account_id,
        request_id => Data#data.request_id,
        requested_model => Data#data.model,
        duration_ms => Duration,
        first_token_ms => Data#data.first_token,
        stream => true,
        request_type => 2  %% stream
    })),
    {stop, normal}.

terminate(_Reason, _State, Data) ->
    cleanup(Data),
    ok.

%%% Internal

cleanup(#data{conn_pid = undefined}) -> ok;
cleanup(#data{conn_pid = ConnPid, conn_mref = MRef}) ->
    demonitor(MRef, [flush]),
    gun:close(ConnPid).

forward_and_accumulate([], Data) ->
    Data;
forward_and_accumulate([Event | Rest], Data) ->
    %% Forward raw SSE event to caller
    Data#data.caller ! {stream_chunk, self(), Event},
    %% Track first token time
    Data2 = case Data#data.first_token of
        undefined ->
            Data#data{first_token = erlang:monotonic_time(millisecond) - Data#data.start_time};
        _ ->
            Data
    end,
    %% Try to extract token usage from the event
    Data3 = try_accumulate_tokens(Event, Data2),
    %% G05: Inject x-ersub-tokens SSE comment with accumulated counts
    _ = maybe_inject_token_comment(Data3),
    forward_and_accumulate(Rest, Data3).

maybe_inject_token_comment(#data{caller = Caller, accumulated = Acc}) ->
    TokenInfo = jsx:encode(#{
        input_tokens => maps:get(input_tokens, Acc, 0),
        output_tokens => maps:get(output_tokens, Acc, 0),
        cache_read_tokens => maps:get(cache_read_tokens, Acc, 0),
        cache_creation_tokens => maps:get(cache_creation_tokens, Acc, 0)
    }),
    Comment = <<": x-ersub-tokens ", TokenInfo/binary, "\n\n">>,
    _ = Caller ! {stream_chunk, self(), Comment}.

try_accumulate_tokens(Event, Data) ->
    %% Parse SSE data line for token usage
    case extract_json_from_sse(Event) of
        {ok, Json} ->
            case maps:get(<<"usage">>, Json, undefined) of
                undefined -> Data;
                Usage ->
                    Acc = Data#data.accumulated,
                    NewAcc = Acc#{
                        input_tokens => maps:get(input_tokens, Acc, 0) +
                            maps:get(<<"input_tokens">>, Usage, 0),
                        output_tokens => maps:get(output_tokens, Acc, 0) +
                            maps:get(<<"output_tokens">>, Usage, 0),
                        cache_read_tokens => maps:get(cache_read_tokens, Acc, 0) +
                            maps:get(<<"cache_read_input_tokens">>, Usage, 0),
                        cache_creation_tokens => maps:get(cache_creation_tokens, Acc, 0) +
                            maps:get(<<"cache_creation_input_tokens">>, Usage, 0)
                    },
                    Data#data{accumulated = NewAcc}
            end;
        _ ->
            Data
    end.

extract_json_from_sse(Event) ->
    %% SSE event: "data: {json}\n\n" — extract the JSON part
    Lines = binary:split(Event, <<"\n">>, [global]),
    DataLines = [D || <<"data: ", D/binary>> <- Lines],
    case DataLines of
        [] -> error;
        _ ->
            Combined = iolist_to_binary(lists:join(<<>>, DataLines)),
            case jsx:is_json(Combined) of
                true -> {ok, jsx:decode(Combined, [return_maps])};
                false -> error
            end
    end.

%% Parse SSE events from a binary buffer.
%% Returns {[Event], RemainingBuffer}
parse_sse_events(Buffer) ->
    parse_sse_events(Buffer, []).

parse_sse_events(Buffer, Acc) ->
    case binary:match(Buffer, <<"\n\n">>) of
        {Pos, 2} ->
            Event = binary:part(Buffer, 0, Pos + 2),
            Rest = binary:part(Buffer, Pos + 2, byte_size(Buffer) - Pos - 2),
            parse_sse_events(Rest, [Event | Acc]);
        nomatch ->
            {lists:reverse(Acc), Buffer}
    end.

collect_error_body(ConnPid, StreamRef, Status, RespHeaders, Caller, Data) ->
    collect_error_body(ConnPid, StreamRef, Status, RespHeaders, Caller, Data, []).

collect_error_body(ConnPid, StreamRef, Status, RespHeaders, Caller, Data, Acc) ->
    receive
        {gun_data, ConnPid, StreamRef, fin, Chunk} ->
            Body = iolist_to_binary(lists:reverse([Chunk | Acc])),
            Caller ! {stream_error, self(), {upstream_error, Status, maps:from_list(RespHeaders), Body}},
            cleanup(Data),
            {stop, normal};
        {gun_data, ConnPid, StreamRef, nofin, Chunk} ->
            collect_error_body(ConnPid, StreamRef, Status, RespHeaders, Caller, Data, [Chunk | Acc])
    after 30000 ->
        Caller ! {stream_error, self(), {upstream_error, Status, maps:from_list(RespHeaders), <<>>}},
        cleanup(Data),
        {stop, normal}
    end.

%% Consult CLIPS failover.clp for stream error decisions
evaluate_failover(StatusCode, Data) ->
    FailoverData = #{
        account_id => Data#data.account_id,
        error_code => StatusCode,
        bytes_sent => 0,
        stream_started => false,
        attempt => 0,
        max_switches => 10
    },
    case ersub_clips_pool:with_worker(fun(W) ->
        gen_server:call(W, {evaluate_failover, FailoverData}, 5000)
    end) of
        {ok, #{<<"action">> := <<"switch_account">>}} -> switch_account;
        {ok, #{<<"action">> := <<"retry_same">>}} -> retry_same;
        _ -> abort
    end.
