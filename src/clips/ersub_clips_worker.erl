-module(ersub_clips_worker).
-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1]).
%% Decision APIs — each does full assert→run→parse cycle
-export([select_account/3, calculate_billing/2, check_quota/1,
         evaluate_account_status/2, resolve_model_route/2,
         evaluate_error_passthrough/1]).
%% Utility APIs
-export([ping/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PORT_TIMEOUT, 10000).

%%% poolboy_worker callback

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%%% Decision APIs — each performs: retract_all → assert facts → run → parse results

%% 1. Account selection scoring via scheduling.clp
-spec select_account(pid(), [map()], map()) -> {ok, [map()]} | {error, term()}.
select_account(Worker, Candidates, Weights) ->
    gen_server:call(Worker, {select_account, Candidates, Weights}, ?PORT_TIMEOUT).

%% 2. Billing cost calculation via billing.clp
-spec calculate_billing(pid(), map()) -> {ok, map()} | {error, term()}.
calculate_billing(Worker, UsageData) ->
    gen_server:call(Worker, {calculate_billing, UsageData}, ?PORT_TIMEOUT).

%% 3. Quota checking via quota.clp
-spec check_quota(pid()) -> {ok, map()} | {error, term()}.
check_quota(Worker) ->
    gen_server:call(Worker, check_quota, ?PORT_TIMEOUT).

%% 4. Account status transition via account_status.clp
-spec evaluate_account_status(pid(), map()) -> {ok, map()} | {error, term()}.
evaluate_account_status(Worker, Event) ->
    gen_server:call(Worker, {evaluate_status, Event}, ?PORT_TIMEOUT).

%% 5. Model routing via model_routing.clp
-spec resolve_model_route(pid(), map()) -> {ok, [integer()]} | {error, term()}.
resolve_model_route(Worker, RouteReq) ->
    gen_server:call(Worker, {resolve_route, RouteReq}, ?PORT_TIMEOUT).

%% 6. Error passthrough via error_passthrough.clp
-spec evaluate_error_passthrough(pid()) -> {ok, map()} | {error, term()}.
evaluate_error_passthrough(Worker) ->
    gen_server:call(Worker, evaluate_error_passthrough, ?PORT_TIMEOUT).

%% Heartbeat
-spec ping(pid()) -> ok | {error, term()}.
ping(Worker) ->
    gen_server:call(Worker, ping, 5000).

%%% gen_server callbacks

init(_Args) ->
    RulesDir = ersub_config_srv:get(clips_rules_dir, "priv/clips"),
    PortPath = clips_executable_path(),
    case filelib:is_file(PortPath) of
        true ->
            Port = open_port({spawn_executable, PortPath},
                             [{args, [RulesDir]},
                              {line, 1048576},
                              binary, use_stdio, exit_status]),
            {ok, #{port => Port, buffer => <<>>}};
        false ->
            logger:error("CLIPS executable not found: ~s", [PortPath]),
            {stop, {clips_not_found, PortPath}}
    end.

handle_call(ping, _From, #{port := Port} = State) ->
    case port_command_json(Port, #{<<"op">> => <<"ping">>}, State) of
        {ok, #{<<"op">> := <<"pong">>}, NewState} ->
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% === 1. ACCOUNT SELECTION (scheduling.clp) ===
handle_call({select_account, Candidates, Weights}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    AllFacts = build_weight_facts(Weights) ++ build_candidate_facts(Candidates),
    {ok, _, S2} = assert_facts(Port, AllFacts, S1),
    case run_and_collect(Port, S2) of
        {ok, Facts, S3} ->
            Scores = [F || F <- Facts,
                      maps:get(<<"template">>, F, <<>>) =:= <<"account-score">>],
            {reply, {ok, Scores}, S3};
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 2. BILLING CALCULATION (billing.clp) ===
handle_call({calculate_billing, UsageData}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_billing_facts(UsageData),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"billing-result">>],
            case Results of
                [R | _] -> {reply, {ok, R}, S3};
                [] -> {reply, {error, no_billing_result}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 3. QUOTA CHECK (quota.clp) ===
handle_call({check_quota, QuotaData}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_quota_facts(QuotaData),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Violations = [F || F <- AllFacts,
                          maps:get(<<"template">>, F, <<>>) =:= <<"quota-violation">>],
            CheckResults = [F || F <- AllFacts,
                            maps:get(<<"template">>, F, <<>>) =:= <<"quota-check-result">>],
            {reply, {ok, #{violations => Violations, results => CheckResults}}, S3};
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 4. ACCOUNT STATUS TRANSITION (account_status.clp) ===
handle_call({evaluate_status, Event}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_account_event_facts(Event),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Updates = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"account-status-update">>],
            case Updates of
                [U | _] -> {reply, {ok, U}, S3};
                [] -> {reply, {ok, #{<<"new-status">> => <<"active">>, <<"cooldown-ms">> => 0}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 5. MODEL ROUTING (model_routing.clp) ===
handle_call({resolve_route, RouteReq}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_routing_facts(RouteReq),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"routing-result">>],
            {reply, {ok, Results}, S3};
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 6. ERROR PASSTHROUGH (error_passthrough.clp) ===
handle_call({evaluate_error, ErrorData}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_error_facts(ErrorData),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Actions = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"error-action">>],
            case Actions of
                [A | _] -> {reply, {ok, A}, S3};
                [] -> {reply, {ok, #{<<"action">> => <<"default">>}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 7. MODERATION (moderation.clp) ===
handle_call({evaluate_moderation, ModerationData}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_moderation_facts(ModerationData),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"moderation-result">>],
            case Results of
                [R | _] -> {reply, {ok, R}, S3};
                [] -> {reply, {ok, #{<<"action">> => <<"pass">>}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 8. REFUND STATE TRANSITION (refund.clp) ===
handle_call({evaluate_refund, RefundData}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_refund_facts(RefundData),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Updates = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"refund-result">>],
            case Updates of
                [U | _] -> {reply, {ok, U}, S3};
                [] -> {reply, {ok, #{<<"allowed">> => false, <<"reason">> => <<"no_rule_matched">>}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 9. MESSAGES DISPATCH (dispatch.clp) ===
handle_call({evaluate_dispatch, DispatchData}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_dispatch_facts(DispatchData),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"dispatch-result">>],
            case Results of
                [R | _] -> {reply, {ok, R}, S3};
                [] -> {reply, {ok, #{<<"target_model">> => maps:get(model, DispatchData, <<>>)}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 10. POOL STRATEGY (pool_strategy.clp) ===
handle_call({evaluate_pool_strategy, Data}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Mode = ersub_config_srv:get(upstream_pool_isolation, <<"account_proxy">>),
    AID = maps:get(account_id, Data, 0),
    PE = maps:get(proxy_endpoint, Data, <<>>),
    Platform = maps:get(platform, Data, unknown),
    Facts = [
        iolist_to_binary(io_lib:format("(pool-config (mode ~s))", [Mode])),
        iolist_to_binary(io_lib:format(
            "(pool-request (account-id ~p) (proxy-endpoint \"~s\") (platform ~s))",
            [AID, PE, Platform]))
    ],
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"pool-strategy-result">>],
            case Results of
                [R | _] -> {reply, {ok, R}, S3};
                [] -> {reply, {ok, #{<<"pool-key">> => <<"default">>}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 11. FAILOVER DECISION (failover.clp) ===
handle_call({evaluate_failover, Data}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    AID = maps:get(account_id, Data, 0),
    EC = maps:get(error_code, Data, 500),
    BS = maps:get(bytes_sent, Data, 0),
    SS = maps:get(stream_started, Data, false),
    Attempt = maps:get(attempt, Data, 0),
    MaxSw = maps:get(max_switches, Data, 10),
    PM = maps:get(pool_mode, Data, false),
    PRC = maps:get(pool_retry_count, Data, 3),
    PA = maps:get(pool_attempt, Data, 0),
    Facts = [iolist_to_binary(io_lib:format(
        "(stream-error-event (account-id ~p) (error-code ~p) (bytes-sent ~p) "
        "(stream-started ~s) (attempt ~p) (max-switches ~p) "
        "(pool-mode ~s) (pool-retry-count ~p) (pool-attempt ~p))",
        [AID, EC, BS, bool_sym(SS), Attempt, MaxSw, bool_sym(PM), PRC, PA]))],
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Decisions = [F || F <- AllFacts,
                         maps:get(<<"template">>, F, <<>>) =:= <<"failover-decision">>],
            case Decisions of
                [D | _] -> {reply, {ok, D}, S3};
                [] -> {reply, {ok, #{<<"action">> => <<"reject">>, <<"reason">> => <<"no_rule">>}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 12. IDENTITY ADOPTION (identity_adoption.clp) ===
handle_call({evaluate_identity, Data}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Provider = maps:get(provider, Data, <<>>),
    ExEmail = maps:get(existing_email, Data, <<"nil">>),
    OEmail = maps:get(oauth_email, Data, <<>>),
    HasDN = maps:get(has_display_name, Data, false),
    HasAv = maps:get(has_avatar, Data, false),
    HasPw = maps:get(existing_has_password, Data, false),
    Facts = [iolist_to_binary(io_lib:format(
        "(identity-conflict (provider \"~s\") (existing-email \"~s\") "
        "(oauth-email \"~s\") (has-display-name ~s) (has-avatar ~s) "
        "(existing-has-password ~s))",
        [Provider, ExEmail, OEmail, bool_sym(HasDN), bool_sym(HasAv), bool_sym(HasPw)]))],
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Decisions = [F || F <- AllFacts,
                         maps:get(<<"template">>, F, <<>>) =:= <<"adoption-decision">>],
            case Decisions of
                [D | _] -> {reply, {ok, D}, S3};
                [] -> {reply, {ok, #{<<"action">> => <<"create_new">>}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 13. SUBSCRIPTION VALIDATION (subscription.clp) ===
handle_call({evaluate_subscription, Data}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_subscription_facts(Data),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"subscription-result">>],
            case Results of
                [R | _] -> {reply, {ok, R}, S3};
                [] -> {reply, {ok, #{<<"allowed">> => false, <<"reason">> => <<"no_rule_matched">>}}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 14. CHANNEL FILTER (channel_filter.clp) ===
handle_call({filter_channels, Candidates}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = build_channel_filter_facts(Candidates),
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"channel-filter-result">>],
            {reply, {ok, Results}, S3};
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 13. PLATFORM CONFIG LOOKUP ===
handle_call({get_platform_config, Platform}, _From, #{port := Port} = State) ->
    %% Query platform-config deffacts (loaded at startup, no assert needed — just run)
    %% deffacts are persistent across retract_all, so we can query them directly
    case run_and_collect(Port, State) of
        {ok, AllFacts, S1} ->
            Configs = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"platform-config">>,
                       maps:get(<<"platform">>, F, <<>>) =:= Platform],
            case Configs of
                [C | _] -> {reply, {ok, C}, S1};
                [] -> {reply, {error, not_found}, S1}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% === 14. CHECK RETRIABLE CODE ===
handle_call({check_retriable, Code}, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = [iolist_to_binary(io_lib:format("(error-check-request (code ~p))", [Code]))],
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Results = [F || F <- AllFacts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"error-check-result">>],
            case Results of
                [#{<<"retriable">> := <<"TRUE">>} | _] -> {reply, {ok, true}, S3};
                _ -> {reply, {ok, false}, S3}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 15. GET SELECTION LAYERS (CL03) ===
handle_call(get_selection_layers, _From, #{port := Port} = State) ->
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    Facts = [<<"(selection-layer-request)">>],
    {ok, _, S2} = assert_facts(Port, Facts, S1),
    case run_and_collect(Port, S2) of
        {ok, AllFacts, S3} ->
            Layers = [#{type => maps:get(<<"type">>, F),
                        priority => maps:get(<<"priority">>, F)}
                      || F <- AllFacts,
                         maps:get(<<"template">>, F, <<>>) =:= <<"selection-layer-result">>],
            Sorted = lists:sort(fun(A, B) ->
                maps:get(priority, A) =< maps:get(priority, B)
            end, Layers),
            {reply, {ok, Sorted}, S3};
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

%% === 16. GET ALL DEFFACTS (for config loading) ===
handle_call({get_all_facts}, _From, #{port := Port} = State) ->
    %% Reset triggers deffacts re-assertion, then run collects all facts
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    case run_and_collect(Port, S1) of
        {ok, AllFacts, S2} ->
            {reply, {ok, AllFacts}, S2};
        {error, Reason} ->
            {reply, {error, Reason}, S1}
    end;

%% === RELOAD RULES ===
handle_call(reload_rules, _From, #{port := Port} = State) ->
    RulesDir = ersub_config_srv:get(clips_rules_dir, "priv/clips"),
    Cmd = #{<<"op">> => <<"reload">>, <<"dir">> => list_to_binary(RulesDir)},
    case port_command_json(Port, Cmd, State) of
        {ok, _, NewState} ->
            logger:info("CLIPS rules reloaded on worker ~p", [self()]),
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, {eol, _Line}}}, #{port := Port} = State) ->
    {noreply, State};
handle_info({Port, {exit_status, Status}}, #{port := Port} = State) ->
    logger:error("CLIPS port exited with status ~p", [Status]),
    {stop, {port_exit, Status}, State#{port => undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{port := Port}) when Port =/= undefined ->
    catch port_close(Port),
    ok;
terminate(_Reason, _State) ->
    ok.

%%% Internal — Port communication

clips_executable_path() ->
    case code:priv_dir(ersub) of
        {error, _} -> "priv/ersub_clips";
        PrivDir -> filename:join(PrivDir, "ersub_clips")
    end.

port_command_json(Port, Cmd, State) ->
    Json = jsx:encode(Cmd),
    port_command(Port, [Json, <<"\n">>]),
    receive_line(Port, State).

receive_line(Port, State) ->
    receive
        {Port, {data, {eol, Line}}} ->
            case jsx:is_json(Line) of
                true -> {ok, jsx:decode(Line, [return_maps]), State};
                false -> {error, {invalid_json, Line}}
            end;
        {Port, {data, {noeol, _}}} ->
            receive_line(Port, State);
        {Port, {exit_status, Status}} ->
            {error, {port_exit, Status}}
    after ?PORT_TIMEOUT ->
        {error, timeout}
    end.

assert_facts(Port, FactStrings, State) ->
    Cmd = #{<<"op">> => <<"assert">>,
            <<"facts">> => [#{<<"assert_string">> => F} || F <- FactStrings]},
    port_command_json(Port, Cmd, State).

run_and_collect(Port, State) ->
    case port_command_json(Port, #{<<"op">> => <<"run">>}, State) of
        {ok, #{<<"facts">> := Facts}, NewState} ->
            {ok, Facts, NewState};
        {ok, #{<<"op">> := <<"result">>} = R, NewState} ->
            {ok, maps:get(<<"facts">>, R, []), NewState};
        {error, Reason} ->
            {error, Reason}
    end.

%%% Fact builders

build_weight_facts(Weights) ->
    PW = maps:get(priority, Weights, 1.0),
    LW = maps:get(load, Weights, 1.0),
    QW = maps:get(queue, Weights, 0.7),
    EW = maps:get(error_rate, Weights, 0.8),
    TW = maps:get(ttft, Weights, 0.5),
    [
        iolist_to_binary(io_lib:format(
            "(score-weights (priority-w ~.1f) (load-w ~.1f) (queue-w ~.1f) "
            "(error-rate-w ~.1f) (ttft-w ~.1f))", [PW, LW, QW, EW, TW])),
        <<"(max-values (max-priority 100) (max-waiting 20) (max-ttft 5000.0))">>,
        <<"(select-config (top-k 7))">>
    ].

build_candidate_facts(Candidates) ->
    lists:map(fun(C) ->
        iolist_to_binary(io_lib:format(
            "(candidate-account (id ~p) (priority ~p) (load-rate ~.4f) "
            "(waiting-count ~p) (ewma-error-rate ~.4f) (ewma-ttft-ms ~.1f) "
            "(status ~s) (platform ~s) (supports-model ~p))",
            [maps:get(id, C), maps:get(priority, C, 100),
             maps:get(load_rate, C, 0.0), maps:get(waiting_count, C, 0),
             maps:get(ewma_error_rate, C, 0.0), maps:get(ewma_ttft_ms, C, 0.0),
             maps:get(status, C, active), maps:get(platform, C, claude),
             maps:get(supports_model, C, 1)]))
    end, Candidates).

build_billing_facts(U) ->
    Model = maps:get(model, U, <<"unknown">>),
    IT = maps:get(input_tokens, U, 0),
    OT = maps:get(output_tokens, U, 0),
    CRT = maps:get(cache_read_tokens, U, 0),
    C5T = maps:get(cache_5m_tokens, U, 0),
    C1T = maps:get(cache_1h_tokens, U, 0),
    IOT = maps:get(image_output_tokens, U, 0),
    Tier = maps:get(service_tier, U, standard),
    ARM = maps:get(account_rate_mult, U, 1.0),
    GRM = maps:get(group_rate_mult, U, 1.0),
    TotalInput = maps:get(total_input_tokens, U, IT),
    BillingMode = maps:get(billing_mode, U, token),
    %% Lookup pricing from ETS
    PricingFact = case ersub_pricing_srv:get_pricing(Model) of
        {ok, P} ->
            iolist_to_binary(io_lib:format(
                "(model-pricing (model \"~s\") (input-price ~.10f) (output-price ~.10f) "
                "(cache-read-price ~.10f) (cache-creation-price ~.10f) "
                "(cache-5m-price ~.10f) (cache-1h-price ~.10f) "
                "(image-output-price ~.10f))",
                [Model,
                 maps:get(input_price, P, 0.0), maps:get(output_price, P, 0.0),
                 maps:get(cache_read_price, P, 0.0), maps:get(cache_creation_price, P, 0.0),
                 maps:get(cache_5m_price, P, 0.0), maps:get(cache_1h_price, P, 0.0),
                 maps:get(image_output_price, P, 0.0)]));
        {error, _} ->
            iolist_to_binary(io_lib:format(
                "(model-pricing (model \"~s\") (input-price 0.000003) (output-price 0.000015))",
                [Model]))
    end,
    UsageFact = iolist_to_binary(io_lib:format(
        "(usage (model \"~s\") (input-tokens ~p) (output-tokens ~p) "
        "(cache-read-tokens ~p) (cache-5m-tokens ~p) (cache-1h-tokens ~p) "
        "(image-output-tokens ~p) (service-tier ~s) "
        "(account-rate-mult ~.4f) (group-rate-mult ~.4f) (total-input-tokens ~p))",
        [Model, IT, OT, CRT, C5T, C1T, IOT, Tier, ARM, GRM, TotalInput])),
    ModeFact = iolist_to_binary(io_lib:format("(billing-mode (mode ~s))", [BillingMode])),
    [PricingFact, UsageFact, ModeFact].

build_quota_facts(Q) ->
    UID = maps:get(user_id, Q),
    GID = maps:get(group_id, Q),
    DL = maps:get(daily_limit, Q, 0.0),
    DU = maps:get(daily_usage, Q, 0.0),
    WL = maps:get(weekly_limit, Q, 0.0),
    WU = maps:get(weekly_usage, Q, 0.0),
    ML = maps:get(monthly_limit, Q, 0.0),
    MU = maps:get(monthly_usage, Q, 0.0),
    AC = maps:get(additional_cost, Q, 0.0),
    [iolist_to_binary(io_lib:format(
        "(subscription-quota (user-id ~p) (group-id ~p) "
        "(daily-limit ~.6f) (daily-usage ~.6f) "
        "(weekly-limit ~.6f) (weekly-usage ~.6f) "
        "(monthly-limit ~.6f) (monthly-usage ~.6f) "
        "(additional-cost ~.6f))",
        [UID, GID, DL, DU, WL, WU, ML, MU, AC]))].

build_account_event_facts(E) ->
    AID = maps:get(account_id, E),
    EventType = maps:get(event_type, E, success),
    TS = maps:get(timestamp, E, erlang:system_time(second)),
    [iolist_to_binary(io_lib:format(
        "(account-event (account-id ~p) (event-type ~s) (timestamp ~p))",
        [AID, EventType, TS]))].

build_routing_facts(R) ->
    GID = maps:get(group_id, R),
    Model = maps:get(model, R, <<>>),
    Routes = maps:get(routes, R, []),
    RequestFact = iolist_to_binary(io_lib:format(
        "(routing-request (group-id ~p) (model \"~s\"))", [GID, Model])),
    RouteFacts = lists:map(fun(Route) ->
        RGID = maps:get(group_id, Route),
        Pattern = maps:get(model_pattern, Route, <<>>),
        AccountIds = maps:get(account_ids, Route, []),
        AidsStr = string:join([integer_to_list(A) || A <- AccountIds], " "),
        iolist_to_binary(io_lib:format(
            "(model-route (group-id ~p) (model-pattern \"~s\") (target-account-ids ~s))",
            [RGID, Pattern, AidsStr]))
    end, Routes),
    [RequestFact | RouteFacts].

build_error_facts(E) ->
    RID = maps:get(request_id, E, <<>>),
    SC = maps:get(status_code, E, 500),
    Platform = maps:get(platform, E, unknown),
    Body = maps:get(body_excerpt, E, <<>>),
    Rules = maps:get(rules, E, []),
    ErrorFact = iolist_to_binary(io_lib:format(
        "(upstream-error (request-id \"~s\") (status-code ~p) "
        "(platform ~s) (body-excerpt \"~s\"))",
        [RID, SC, Platform, truncate(Body, 200)])),
    RuleFacts = lists:map(fun(Rule) ->
        RuleId = maps:get(rule_id, Rule, 0),
        Codes = maps:get(status_codes, Rule, []),
        Keywords = maps:get(keywords, Rule, []),
        RPlatform = maps:get(platform, Rule, any),
        Action = maps:get(action, Rule, passthrough),
        CodesStr = string:join([integer_to_list(C) || C <- Codes], " "),
        KwStr = string:join([binary_to_list(K) || K <- Keywords], " "),
        iolist_to_binary(io_lib:format(
            "(passthrough-rule (rule-id ~p) (status-codes ~s) "
            "(keywords ~s) (platform ~s) (action ~s))",
            [RuleId, CodesStr, KwStr, RPlatform, Action]))
    end, Rules),
    [ErrorFact | RuleFacts].

truncate(Bin, MaxLen) when byte_size(Bin) > MaxLen ->
    binary:part(Bin, 0, MaxLen);
truncate(Bin, _) ->
    Bin.

build_moderation_facts(M) ->
    Categories = maps:get(categories, M, #{}),
    Thresholds = maps:get(thresholds, M, #{}),
    CatFacts = maps:fold(fun(Cat, Score, Acc) ->
        Threshold = maps:get(Cat, Thresholds, 0.5),
        Fact = iolist_to_binary(io_lib:format(
            "(moderation-category (name \"~s\") (score ~.6f) (threshold ~.6f))",
            [Cat, Score, Threshold])),
        [Fact | Acc]
    end, [], Categories),
    Content = maps:get(content, M, <<>>),
    ContentFact = iolist_to_binary(io_lib:format(
        "(moderation-request (content-hash \"~s\"))",
        [truncate(Content, 64)])),
    [ContentFact | CatFacts].

build_refund_facts(R) ->
    OrderId = maps:get(order_id, R, 0),
    CurrentStatus = maps:get(current_status, R, <<"paid">>),
    RequestedAction = maps:get(requested_action, R, <<"refund">>),
    Amount = maps:get(amount, R, 0.0),
    [iolist_to_binary(io_lib:format(
        "(refund-request (order-id ~p) (current-status \"~s\") "
        "(requested-action \"~s\") (amount ~.2f))",
        [OrderId, CurrentStatus, RequestedAction, Amount]))].

build_dispatch_facts(D) ->
    Model = maps:get(model, D, <<>>),
    SourcePlatform = maps:get(source_platform, D, <<>>),
    TargetPlatform = maps:get(target_platform, D, <<>>),
    ModelConfig = maps:get(model_config, D, #{}),
    RequestFact = iolist_to_binary(io_lib:format(
        "(dispatch-request (model \"~s\") (source-platform \"~s\") "
        "(target-platform \"~s\"))",
        [Model, SourcePlatform, TargetPlatform])),
    ConfigFacts = maps:fold(fun(FromModel, ToModel, Acc) ->
        Fact = iolist_to_binary(io_lib:format(
            "(dispatch-mapping (from-model \"~s\") (to-model \"~s\"))",
            [FromModel, ToModel])),
        [Fact | Acc]
    end, [], ModelConfig),
    [RequestFact | ConfigFacts].

build_subscription_facts(Data) ->
    UID = maps:get(user_id, Data, 0),
    GID = maps:get(group_id, Data, 0),
    BT = maps:get(billing_type, Data, 0),
    [iolist_to_binary(io_lib:format(
        "(subscription-request (user-id ~p) (group-id ~p) (billing-type ~p))",
        [UID, GID, BT]))].

build_channel_filter_facts(Candidates) ->
    lists:map(fun(C) ->
        Id = maps:get(id, C, 0),
        GID = maps:get(group_id, C, 0),
        Platform = maps:get(platform, C, unknown),
        IsActive = maps:get(is_active, C, false),
        HasModel = maps:get(has_model, C, false),
        iolist_to_binary(io_lib:format(
            "(channel-candidate (id ~p) (group-id ~p) (platform ~s) "
            "(is-active ~s) (has-model ~s))",
            [Id, GID, Platform, bool_sym(IsActive), bool_sym(HasModel)]))
    end, Candidates).

bool_sym(true) -> "TRUE";
bool_sym(false) -> "FALSE";
bool_sym(<<"true">>) -> "TRUE";
bool_sym(<<"false">>) -> "FALSE";
bool_sym(_) -> "FALSE".
