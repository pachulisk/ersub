-module(ersub_sse_ping).

-export([wait_with_ping/3]).

-define(PING_DATA, <<"event: ping\ndata: {\"type\": \"ping\"}\n\n">>).
-define(BASE_INTERVAL_MS, 100).
-define(MAX_INTERVAL_MS, 2000).
-define(BACKOFF_FACTOR, 1.5).
-define(JITTER_RANGE, 0.2).

%% Wait for a concurrency slot while sending SSE pings.
%% Req must already have chunked headers sent.
%% Returns {ok, Ref, Req} | {error, timeout, Req}
-spec wait_with_ping(cowboy_req:req(), integer(), reference()) ->
    {ok, reference(), cowboy_req:req()} | {error, timeout, cowboy_req:req()}.

wait_with_ping(Req, PingIntervalMs, _WaitRef) ->
    Timeout = ersub_config_srv:get(concurrency_wait_timeout_ms, 30000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_loop(Req, PingIntervalMs, Deadline, ?BASE_INTERVAL_MS).

wait_loop(Req, PingInterval, Deadline, CurrentBackoff) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            {error, timeout, Req};
        false ->
            WaitMs = min(CurrentBackoff, PingInterval),
            Jittered = add_jitter(WaitMs),
            receive
                {slot_acquired, Ref} ->
                    {ok, Ref, Req}
            after trunc(Jittered) ->
                %% Send SSE ping
                cowboy_req:stream_body(?PING_DATA, nofin, Req),
                NextBackoff = min(CurrentBackoff * ?BACKOFF_FACTOR, ?MAX_INTERVAL_MS),
                wait_loop(Req, PingInterval, Deadline, NextBackoff)
            end
    end.

%%% Internal

add_jitter(Ms) ->
    Jitter = Ms * ?JITTER_RANGE,
    Ms + (rand:uniform() * 2 * Jitter) - Jitter.
