-module(ersub_sse_ping).

-export([wait_with_ping/3, get_ping_config/1]).

%% Get SSE ping configuration for a platform from CLIPS.
-spec get_ping_config(binary()) -> map().
get_ping_config(Platform) ->
    ersub_clips_config:get_sse_ping(Platform).

%% Wait for a concurrency slot while sending SSE pings.
%% Req must already have chunked headers sent.
%% Returns {ok, Ref, Req} | {error, timeout, Req}
-spec wait_with_ping(cowboy_req:req(), integer(), reference()) ->
    {ok, reference(), cowboy_req:req()} | {error, timeout, cowboy_req:req()}.

wait_with_ping(Req, PingIntervalMs, _WaitRef) ->
    PingCfg = get_ping_config(<<"default">>),
    PingData = build_ping_data(PingCfg),
    BaseInterval = maps:get(<<"base-interval-ms">>, PingCfg, 100),
    MaxInterval = maps:get(<<"max-interval-ms">>, PingCfg, 2000),
    BackoffFactor = maps:get(<<"backoff-factor">>, PingCfg, 1.5),
    JitterRange = maps:get(<<"jitter-range">>, PingCfg, 0.2),
    Timeout = ersub_config_srv:get(concurrency_wait_timeout_ms, 30000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_loop(Req, PingIntervalMs, Deadline, BaseInterval,
              #{ping_data => PingData, max_interval => MaxInterval,
                backoff_factor => BackoffFactor, jitter_range => JitterRange}).

wait_loop(Req, PingInterval, Deadline, CurrentBackoff, Cfg) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            {error, timeout, Req};
        false ->
            WaitMs = min(CurrentBackoff, PingInterval),
            JitterRange = maps:get(jitter_range, Cfg, 0.2),
            Jittered = add_jitter(WaitMs, JitterRange),
            receive
                {slot_acquired, Ref} ->
                    {ok, Ref, Req}
            after trunc(Jittered) ->
                PingData = maps:get(ping_data, Cfg),
                cowboy_req:stream_body(PingData, nofin, Req),
                MaxInterval = maps:get(max_interval, Cfg, 2000),
                BackoffFactor = maps:get(backoff_factor, Cfg, 1.5),
                NextBackoff = min(CurrentBackoff * BackoffFactor, MaxInterval),
                wait_loop(Req, PingInterval, Deadline, NextBackoff, Cfg)
            end
    end.

%%% Internal

build_ping_data(PingCfg) ->
    Format = maps:get(<<"format">>, PingCfg, <<"event:ping data:ping">>),
    %% Build a well-formed SSE event from the format string
    <<"event: ping\ndata: ", Format/binary, "\n\n">>.

add_jitter(Ms, JitterRange) ->
    Jitter = Ms * JitterRange,
    Ms + (rand:uniform() * 2 * Jitter) - Jitter.
