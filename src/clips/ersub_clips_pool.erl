-module(ersub_clips_pool).

-export([start_link/0, stop/0]).
-export([with_worker/1, reload_rules/0]).
%% Convenience wrappers for CLIPS decision APIs
-export([select_account/2, calculate_billing/1, check_quota/1,
         evaluate_account_status/1, resolve_model_route/1,
         evaluate_error_passthrough/1]).
%% Extended decision APIs
-export([evaluate_moderation/1, evaluate_refund_transition/1,
         evaluate_messages_dispatch/1]).

-define(POOL, ersub_clips_pool).

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

stop() -> ok.

with_worker(Fun) ->
    Worker = poolboy:checkout(?POOL, true, 5000),
    try Fun(Worker)
    after poolboy:checkin(?POOL, Worker)
    end.

reload_rules() ->
    with_worker(fun(W) -> gen_server:call(W, reload_rules, 10000) end).

%%% CLIPS Decision API Wrappers
%%% Each checks out a worker, calls the decision, checks back in.

%% Score candidates and return ranked account scores.
-spec select_account([map()], map()) -> {ok, [map()]} | {error, term()}.
select_account(Candidates, Weights) ->
    with_worker(fun(W) ->
        ersub_clips_worker:select_account(W, Candidates, Weights)
    end).

%% Calculate billing cost for a usage record.
-spec calculate_billing(map()) -> {ok, map()} | {error, term()}.
calculate_billing(UsageData) ->
    with_worker(fun(W) ->
        ersub_clips_worker:calculate_billing(W, UsageData)
    end).

%% Check subscription quota.
-spec check_quota(map()) -> {ok, map()} | {error, term()}.
check_quota(QuotaData) ->
    with_worker(fun(W) ->
        gen_server:call(W, {check_quota, QuotaData}, 10000)
    end).

%% Evaluate account status transition based on an event.
-spec evaluate_account_status(map()) -> {ok, map()} | {error, term()}.
evaluate_account_status(Event) ->
    with_worker(fun(W) ->
        ersub_clips_worker:evaluate_account_status(W, Event)
    end).

%% Resolve model routing for a group.
-spec resolve_model_route(map()) -> {ok, [integer()]} | {error, term()}.
resolve_model_route(RouteReq) ->
    with_worker(fun(W) ->
        ersub_clips_worker:resolve_model_route(W, RouteReq)
    end).

%% Evaluate error passthrough rules.
-spec evaluate_error_passthrough(map()) -> {ok, map()} | {error, term()}.
evaluate_error_passthrough(ErrorData) ->
    with_worker(fun(W) ->
        gen_server:call(W, {evaluate_error, ErrorData}, 10000)
    end).

%% Evaluate moderation thresholds via moderation.clp rules.
-spec evaluate_moderation(map()) -> {ok, map()} | {error, term()}.
evaluate_moderation(ModerationData) ->
    with_worker(fun(W) ->
        gen_server:call(W, {evaluate_moderation, ModerationData}, 10000)
    end).

%% Evaluate refund state transition via refund.clp rules.
-spec evaluate_refund_transition(map()) -> {ok, map()} | {error, term()}.
evaluate_refund_transition(RefundData) ->
    with_worker(fun(W) ->
        gen_server:call(W, {evaluate_refund, RefundData}, 10000)
    end).

%% Evaluate messages dispatch cross-platform model mapping via dispatch.clp rules.
-spec evaluate_messages_dispatch(map()) -> {ok, map()} | {error, term()}.
evaluate_messages_dispatch(DispatchData) ->
    with_worker(fun(W) ->
        gen_server:call(W, {evaluate_dispatch, DispatchData}, 10000)
    end).
