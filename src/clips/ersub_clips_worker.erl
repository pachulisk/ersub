-module(ersub_clips_worker).
-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1]).
-export([select_account/3, calculate_billing/1, check_quota/1, ping/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PORT_TIMEOUT, 10000).

%%% poolboy_worker callback

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%%% API (called via poolboy checkout)

%% Score candidate accounts and return ranked results.
-spec select_account(pid(), [map()], map()) -> {ok, map()} | {error, term()}.
select_account(Worker, Candidates, Weights) ->
    gen_server:call(Worker, {select_account, Candidates, Weights}, ?PORT_TIMEOUT).

%% Calculate billing cost for a usage record.
-spec calculate_billing(pid()) -> {ok, map()} | {error, term()}.
calculate_billing(Worker) ->
    gen_server:call(Worker, calculate_billing, ?PORT_TIMEOUT).

%% Check subscription quota.
-spec check_quota(pid()) -> {ok, map()} | {error, term()}.
check_quota(Worker) ->
    gen_server:call(Worker, check_quota, ?PORT_TIMEOUT).

%% Heartbeat check.
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

handle_call({select_account, Candidates, Weights}, _From, #{port := Port} = State) ->
    %% 1. Retract all previous facts
    {ok, _, S1} = port_command_json(Port, #{<<"op">> => <<"retract_all">>}, State),
    %% 2. Assert weight and config facts
    WeightFacts = build_weight_facts(Weights),
    CandidateFacts = build_candidate_facts(Candidates),
    AllFacts = WeightFacts ++ CandidateFacts,
    AssertCmd = #{<<"op">> => <<"assert">>,
                  <<"facts">> => [#{<<"assert_string">> => F} || F <- AllFacts]},
    {ok, _, S2} = port_command_json(Port, AssertCmd, S1),
    %% 3. Run rules
    case port_command_json(Port, #{<<"op">> => <<"run">>}, S2) of
        {ok, #{<<"facts">> := Facts}, S3} ->
            Scores = [F || F <- Facts, maps:get(<<"template">>, F, <<>>) =:= <<"account-score">>],
            {reply, {ok, Scores}, S3};
        {error, Reason} ->
            {reply, {error, Reason}, S2}
    end;

handle_call(calculate_billing, _From, #{port := Port} = State) ->
    case port_command_json(Port, #{<<"op">> => <<"run">>}, State) of
        {ok, #{<<"facts">> := Facts}, NewState} ->
            Results = [F || F <- Facts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"billing-result">>],
            case Results of
                [R | _] -> {reply, {ok, R}, NewState};
                [] -> {reply, {error, no_billing_result}, NewState}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(check_quota, _From, #{port := Port} = State) ->
    case port_command_json(Port, #{<<"op">> => <<"run">>}, State) of
        {ok, #{<<"facts">> := Facts}, NewState} ->
            Results = [F || F <- Facts,
                       maps:get(<<"template">>, F, <<>>) =:= <<"quota-check-result">>],
            Violations = [F || F <- Facts,
                         maps:get(<<"template">>, F, <<>>) =:= <<"quota-violation">>],
            {reply, {ok, #{results => Results, violations => Violations}}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, {eol, Line}}}, #{port := Port, buffer := _Buf} = State) ->
    %% Line data from port — stored for synchronous reads
    {noreply, State#{last_line => Line}};

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

%%% Internal

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
                true ->
                    Decoded = jsx:decode(Line, [return_maps]),
                    {ok, Decoded, State};
                false ->
                    {error, {invalid_json, Line}}
            end;
        {Port, {data, {noeol, _Partial}}} ->
            %% Incomplete line, wait for more
            receive_line(Port, State);
        {Port, {exit_status, Status}} ->
            {error, {port_exit, Status}}
    after ?PORT_TIMEOUT ->
        {error, timeout}
    end.

build_weight_facts(Weights) ->
    PW = maps:get(priority, Weights, 1.0),
    LW = maps:get(load, Weights, 1.0),
    QW = maps:get(queue, Weights, 0.7),
    EW = maps:get(error_rate, Weights, 0.8),
    TW = maps:get(ttft, Weights, 0.5),
    [
        iolist_to_binary(io_lib:format(
            "(score-weights (priority-w ~.1f) (load-w ~.1f) (queue-w ~.1f) "
            "(error-rate-w ~.1f) (ttft-w ~.1f))",
            [PW, LW, QW, EW, TW])),
        <<"(max-values (max-priority 100) (max-waiting 20) (max-ttft 5000.0))">>,
        <<"(select-config (top-k 7))">>
    ].

build_candidate_facts(Candidates) ->
    lists:map(fun(C) ->
        iolist_to_binary(io_lib:format(
            "(candidate-account (id ~p) (priority ~p) (load-rate ~.4f) "
            "(waiting-count ~p) (ewma-error-rate ~.4f) (ewma-ttft-ms ~.1f) "
            "(status ~s) (platform ~s) (supports-model ~p))",
            [maps:get(id, C),
             maps:get(priority, C, 100),
             maps:get(load_rate, C, 0.0),
             maps:get(waiting_count, C, 0),
             maps:get(ewma_error_rate, C, 0.0),
             maps:get(ewma_ttft_ms, C, 0.0),
             maps:get(status, C, active),
             maps:get(platform, C, claude),
             maps:get(supports_model, C, 1)]))
    end, Candidates).
