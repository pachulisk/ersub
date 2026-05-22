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
%% Configuration query APIs
-export([get_platform_config/1, check_retriable/1, get_selection_layers/0,
         get_alipay_config/0, get_wechat_config/0]).
%% Channel filter API
-export([filter_channels/1]).
%% Subscription validation API
-export([evaluate_subscription/1]).
%% Group authorization API
-export([check_group_auth/1]).

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

%% Filter channels by availability via channel_filter.clp rules.
-spec filter_channels([map()]) -> {ok, [map()]} | {error, term()}.
filter_channels(Candidates) ->
    with_worker(fun(W) ->
        gen_server:call(W, {filter_channels, Candidates}, 10000)
    end).

%% Evaluate subscription request via subscription.clp rules.
-spec evaluate_subscription(map()) -> {ok, map()} | {error, term()}.
evaluate_subscription(SubData) ->
    with_worker(fun(W) ->
        gen_server:call(W, {evaluate_subscription, SubData}, 10000)
    end).

%% T4-02: Check group authorization via CLIPS group_check.clp rules.
-spec check_group_auth(map()) -> {ok, map()} | {error, term()}.
check_group_auth(AuthData) ->
    with_worker(fun(W) ->
        gen_server:call(W, {check_group_auth, AuthData}, 10000)
    end).

%% Get platform configuration from CLIPS facts.
-spec get_platform_config(binary()) -> {ok, map()} | {error, term()}.
get_platform_config(Platform) ->
    with_worker(fun(W) ->
        gen_server:call(W, {get_platform_config, Platform}, 5000)
    end).

%% Check if an HTTP error code is retriable via CLIPS rules.
-spec check_retriable(integer()) -> boolean().
check_retriable(Code) ->
    case with_worker(fun(W) ->
        gen_server:call(W, {check_retriable, Code}, 5000)
    end) of
        {ok, true} -> true;
        _ -> false
    end.

%% CL03: Get ordered selection layers from CLIPS.
-spec get_selection_layers() -> {ok, [map()]} | {error, term()}.
get_selection_layers() ->
    with_worker(fun(W) ->
        gen_server:call(W, get_selection_layers, 5000)
    end).

%% Get Alipay business configuration (gateway URL, rate, enabled flag).
-spec get_alipay_config() -> {ok, map()} | {error, term()}.
get_alipay_config() ->
    with_worker(fun(W) ->
        gen_server:call(W, get_alipay_config, 5000)
    end).

%% Get WeChat Pay business configuration (gateway URL, rate, enabled flag).
-spec get_wechat_config() -> {ok, map()} | {error, term()}.
get_wechat_config() ->
    with_worker(fun(W) ->
        gen_server:call(W, get_wechat_config, 5000)
    end).
