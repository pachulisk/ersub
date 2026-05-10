-module(ersub_ops_alert_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_active_alerts/0, evaluate_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(EVAL_INTERVAL_MS, 60000).  %% 60 seconds

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Return the list of currently active (un-resolved) alerts.
-spec get_active_alerts() -> [map()].
get_active_alerts() ->
    gen_server:call(?SERVER, get_active_alerts).

%% Force immediate evaluation.
-spec evaluate_now() -> ok.
evaluate_now() ->
    gen_server:cast(?SERVER, evaluate).

%%% gen_server callbacks

init([]) ->
    schedule_eval(),
    logger:info("Ops alert service started"),
    {ok, #{active_alerts => []}}.

handle_call(get_active_alerts, _From, #{active_alerts := Alerts} = State) ->
    {reply, Alerts, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(evaluate, State) ->
    NewAlerts = do_evaluate(),
    {noreply, State#{active_alerts => NewAlerts}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(eval_timer, State) ->
    NewAlerts = do_evaluate(),
    schedule_eval(),
    {noreply, State#{active_alerts => NewAlerts}};

handle_info(_Info, State) ->
    {noreply, State}.

%%% Internal

schedule_eval() ->
    Interval = ersub_config_srv:get(ops_alert_eval_interval_ms, ?EVAL_INTERVAL_MS),
    erlang:send_after(Interval, self(), eval_timer).

do_evaluate() ->
    Rules = load_rules(),
    Silences = load_silences(),
    lists:filtermap(fun(Rule) ->
        RuleId = maps:get(id, Rule),
        RuleName = maps:get(name, Rule),
        case is_silenced(RuleId, Silences) of
            true ->
                false;
            false ->
                case evaluate_condition(Rule) of
                    {true, Value} ->
                        Alert = #{
                            rule_id => RuleId,
                            rule_name => RuleName,
                            severity => maps:get(severity, Rule, <<"warning">>),
                            message => format_alert_message(Rule, Value),
                            value => Value,
                            triggered_at => calendar:universal_time()
                        },
                        record_alert(Alert),
                        {true, Alert};
                    false ->
                        false
                end
        end
    end, Rules).

load_rules() ->
    case ersub_repo:squery(
        "SELECT id, name, condition, severity, notify, cooldown_s, is_active "
        "FROM ops_alert_rules WHERE is_active = TRUE")
    of
        {ok, _, Rows} ->
            lists:map(fun({Id, Name, CondJson, Severity, Notify, Cooldown, _IsActive}) ->
                Condition = try jsx:decode(CondJson, [return_maps])
                            catch _:_ -> #{} end,
                #{id => to_integer(Id),
                  name => Name,
                  condition => Condition,
                  severity => Severity,
                  notify => Notify,
                  cooldown_s => to_integer(Cooldown)}
            end, Rows);
        {error, Reason} ->
            logger:error("Failed to load alert rules: ~p", [Reason]),
            []
    end.

load_silences() ->
    case ersub_repo:squery(
        "SELECT rule_id, until, reason "
        "FROM ops_alert_silences WHERE until > NOW()")
    of
        {ok, _, Rows} ->
            [#{rule_id => to_integer(RId), until => Until, reason => R}
             || {RId, Until, R} <- Rows];
        {error, Reason} ->
            logger:error("Failed to load alert silences: ~p", [Reason]),
            []
    end.

is_silenced(RuleId, Silences) ->
    lists:any(fun(#{rule_id := SilencedId}) ->
        SilencedId =:= RuleId
    end, Silences).

evaluate_condition(#{condition := Condition}) ->
    Type = maps:get(<<"type">>, Condition, <<>>),
    Threshold = parse_number(maps:get(<<"threshold">>, Condition, 0)),
    case get_metric_value(Type) of
        {ok, Value} ->
            Op = maps:get(<<"op">>, Condition, <<">">>),
            case check_op(Op, Value, Threshold) of
                true -> {true, Value};
                false -> false
            end;
        {error, _} ->
            false
    end.

get_metric_value(<<"error_rate">>) ->
    case ersub_repo:squery(
        "SELECT COUNT(*) FILTER (WHERE actual_cost = 0)::float / "
        "GREATEST(COUNT(*), 1) "
        "FROM usage_logs WHERE created_at > NOW() - INTERVAL '5 minutes'")
    of
        {ok, _, [{Value}]} -> {ok, parse_number(Value)};
        {error, Reason} -> {error, Reason}
    end;

get_metric_value(<<"request_count_5m">>) ->
    case ersub_repo:squery(
        "SELECT COUNT(*) FROM usage_logs "
        "WHERE created_at > NOW() - INTERVAL '5 minutes'")
    of
        {ok, _, [{Value}]} -> {ok, parse_number(Value)};
        {error, Reason} -> {error, Reason}
    end;

get_metric_value(<<"active_accounts">>) ->
    Count = length(ersub_platform_sup:list_accounts()),
    {ok, Count * 1.0};

get_metric_value(<<"avg_latency_5m">>) ->
    case ersub_repo:squery(
        "SELECT COALESCE(AVG(duration_ms), 0) FROM usage_logs "
        "WHERE created_at > NOW() - INTERVAL '5 minutes'")
    of
        {ok, _, [{Value}]} -> {ok, parse_number(Value)};
        {error, Reason} -> {error, Reason}
    end;

get_metric_value(Type) ->
    logger:warning("Unknown metric type: ~s", [Type]),
    {error, unknown_metric}.

check_op(<<">">>, Value, Threshold) -> Value > Threshold;
check_op(<<">=">>, Value, Threshold) -> Value >= Threshold;
check_op(<<"<">>, Value, Threshold) -> Value < Threshold;
check_op(<<"<=">>, Value, Threshold) -> Value =< Threshold;
check_op(<<"=">>, Value, Threshold) -> Value =:= Threshold;
check_op(_, _, _) -> false.

format_alert_message(Rule, Value) ->
    Name = maps:get(name, Rule),
    Condition = maps:get(condition, Rule),
    Threshold = parse_number(maps:get(<<"threshold">>, Condition, 0)),
    iolist_to_binary(io_lib:format(
        "Alert ~s: value ~.2f exceeds threshold ~.2f",
        [Name, Value, Threshold])).

record_alert(Alert) ->
    #{rule_name := RuleName, severity := Severity, message := Message,
      value := Value} = Alert,
    case ersub_repo:query(
        "INSERT INTO ops_alert_log (rule_name, severity, message, metric_value) "
        "VALUES ($1, $2, $3, $4)",
        [RuleName, Severity, Message, Value])
    of
        {ok, _} ->
            logger:notice("OPS ALERT [~s] ~s: ~s",
                          [Severity, RuleName, Message]);
        {error, Reason} ->
            %% Log error but still emit the alert to logger
            logger:error("Failed to record alert to DB: ~p", [Reason]),
            logger:notice("OPS ALERT [~s] ~s: ~s (DB write failed)",
                          [Severity, RuleName, Message])
    end.

to_integer(V) when is_integer(V) -> V;
to_integer(V) when is_binary(V) -> binary_to_integer(V);
to_integer(V) when is_list(V) -> list_to_integer(V);
to_integer(_) -> 0.

parse_number(V) when is_float(V) -> V;
parse_number(V) when is_integer(V) -> V * 1.0;
parse_number(V) when is_binary(V) ->
    case catch binary_to_float(V) of
        F when is_float(F) -> F;
        _ ->
            case catch binary_to_integer(V) of
                I when is_integer(I) -> I * 1.0;
                _ -> 0.0
            end
    end;
parse_number(_) -> 0.0.
