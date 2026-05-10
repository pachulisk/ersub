-module(ersub_clips_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([port_lifecycle_test/1, scheduling_rule_test/1, retract_and_rerun_test/1]).

all() -> [port_lifecycle_test, scheduling_rule_test, retract_and_rerun_test].

init_per_suite(Config) ->
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
    Config.

end_per_suite(_Config) -> ok.

port_lifecycle_test(_Config) ->
    ersub_clips_pool:with_worker(fun(W) ->
        ok = ersub_clips_worker:ping(W)
    end).

scheduling_rule_test(_Config) ->
    ersub_clips_pool:with_worker(fun(W) ->
        Candidates = [
            #{id => 1, priority => 10, load_rate => 0.2, waiting_count => 0,
              ewma_error_rate => 0.01, ewma_ttft_ms => 100.0,
              status => active, platform => claude, supports_model => 1},
            #{id => 2, priority => 50, load_rate => 0.8, waiting_count => 5,
              ewma_error_rate => 0.1, ewma_ttft_ms => 500.0,
              status => active, platform => claude, supports_model => 1}
        ],
        Weights = #{priority => 1.0, load => 1.0, queue => 0.7,
                    error_rate => 0.8, ttft => 0.5},
        {ok, Scores} = ersub_clips_worker:select_account(W, Candidates, Weights),
        ?assert(length(Scores) >= 2)
    end).

retract_and_rerun_test(_Config) ->
    ersub_clips_pool:with_worker(fun(W) ->
        C1 = [#{id => 1, priority => 1, load_rate => 0.0, waiting_count => 0,
                ewma_error_rate => 0.0, ewma_ttft_ms => 0.0,
                status => active, platform => claude, supports_model => 1}],
        W1 = #{priority => 1.0, load => 1.0, queue => 0.7, error_rate => 0.8, ttft => 0.5},
        {ok, S1} = ersub_clips_worker:select_account(W, C1, W1),
        ?assert(length(S1) >= 1),
        %% Run again with different candidates — should retract previous
        C2 = [#{id => 99, priority => 99, load_rate => 0.9, waiting_count => 10,
                ewma_error_rate => 0.5, ewma_ttft_ms => 4000.0,
                status => active, platform => claude, supports_model => 1}],
        {ok, S2} = ersub_clips_worker:select_account(W, C2, W1),
        ?assert(length(S2) >= 1)
    end).
