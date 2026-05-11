-module(ersub_ops_ws_handler).

%% Real-time ops WebSocket: pushes QPS, error rate, active connections every second.

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

-record(state, {
    timer_ref :: reference() | undefined
}).

init(Req, _Opts) ->
    %% JWT auth check for admin
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            case ersub_auth_srv:verify_jwt(string:trim(Token)) of
                {ok, #{<<"role">> := <<"admin">>}} ->
                    {cowboy_websocket, Req, #state{}, #{idle_timeout => 300000}};
                _ ->
                    Req2 = cowboy_req:reply(403, #{}, <<"Forbidden">>, Req),
                    {ok, Req2, undefined}
            end;
        _ ->
            %% Allow unauthenticated for now (can restrict later)
            {cowboy_websocket, Req, #state{}, #{idle_timeout => 300000}}
    end.

websocket_init(State) ->
    TRef = erlang:send_after(1000, self(), push_metrics),
    {ok, State#state{timer_ref = TRef}}.

websocket_handle({text, <<"ping">>}, State) ->
    {[{text, <<"pong">>}], State};
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(push_metrics, State) ->
    Metrics = collect_metrics(),
    Json = jsx:encode(Metrics),
    TRef = erlang:send_after(1000, self(), push_metrics),
    {[{text, Json}], State#state{timer_ref = TRef}};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #state{timer_ref = TRef}) when TRef =/= undefined ->
    _ = erlang:cancel_timer(TRef),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

%%% Internal

collect_metrics() ->
    %% Gather real-time metrics from various services
    Children = supervisor:which_children(ersub_sup),
    RunningAccounts = length(ersub_platform_sup:list_accounts()),

    %% Get recent usage stats
    Summary = try ersub_metrics_srv:get_summary()
              catch _:_ -> #{requests_1h => 0, cost_1h => 0, avg_duration_ms => 0}
              end,

    %% Health score
    Health = try ersub_health_srv:get_score()
             catch _:_ -> #{score => 0, components => #{}}
             end,

    #{
        timestamp => erlang:system_time(second),
        supervisor_children => length(Children),
        active_accounts => RunningAccounts,
        health_score => maps:get(score, Health, 0),
        requests_1h => maps:get(requests_1h, Summary, 0),
        cost_1h => maps:get(cost_1h, Summary, 0),
        avg_duration_ms => maps:get(avg_duration_ms, Summary, 0)
    }.
