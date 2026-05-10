-module(ersub_clips_bench).
-export([run/0]).

run() ->
    application:ensure_all_started(yamerl),
    application:ensure_all_started(poolboy),
    case whereis(ersub_config_srv) of
        undefined -> {ok, _} = ersub_config_srv:start_link("config/ersub.yaml");
        _ -> ok
    end,
    case ersub_clips_pool:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,

    Candidates = [#{id => I, priority => I * 10, load_rate => I * 0.05,
                    waiting_count => 0, ewma_error_rate => 0.0,
                    ewma_ttft_ms => 100.0, status => active,
                    platform => claude, supports_model => 1}
                  || I <- lists:seq(1, 20)],
    Weights = #{priority => 1.0, load => 1.0, queue => 0.7,
                error_rate => 0.8, ttft => 0.5},

    %% Warmup
    [ersub_clips_pool:with_worker(fun(W) ->
        ersub_clips_worker:select_account(W, Candidates, Weights)
    end) || _ <- lists:seq(1, 50)],

    %% Benchmark
    N = 500,
    {Time, _} = timer:tc(fun() ->
        [ersub_clips_pool:with_worker(fun(W) ->
            ersub_clips_worker:select_account(W, Candidates, Weights)
        end) || _ <- lists:seq(1, N)]
    end),
    AvgUs = Time / N,
    io:format("CLIPS select_account (20 candidates): ~.1f us/call (~.0f calls/s)~n",
              [AvgUs, 1000000 / AvgUs]).
