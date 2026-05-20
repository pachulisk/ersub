-module(ersub_usage_cleanup_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    schedule_cleanup(),
    logger:info("Usage cleanup service started"),
    {ok, #{}}.

handle_call(_, _From, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.

handle_info(cleanup, State) ->
    Days = ersub_config_srv:get(ops_usage_cleanup_retention_days, 90),
    case ersub_repo:query(
        "DELETE FROM usage_logs WHERE created_at < NOW() - $1::int * INTERVAL '1 day' "
        "RETURNING id", [Days]) of
        {ok, N, _, _} when N > 0 ->
            logger:info("Cleaned ~p usage logs older than ~p days", [N, Days]);
        {ok, 0, _, _} -> ok;
        {ok, _, _} -> ok;
        {error, Reason} ->
            logger:error("Usage cleanup failed: ~p", [Reason])
    end,
    %% Clean billing dedup archive
    ersub_repo:squery(
        "DELETE FROM usage_billing_dedup WHERE billed_at < NOW() - INTERVAL '7 days'"),
    %% Clean system logs, request errors, and channel monitor histories
    DaysStr = integer_to_list(Days),
    DaysInterval = list_to_binary(DaysStr ++ " days"),
    lists:foreach(fun({Table, Col}) ->
        Q = iolist_to_binary([
            "DELETE FROM ", Table,
            " WHERE ", Col, " < NOW() - '", DaysInterval, "'::interval"
        ]),
        case ersub_repo:squery(binary_to_list(Q)) of
            {ok, Deleted, _, _} when is_integer(Deleted), Deleted > 0 ->
                logger:info("Cleaned ~p rows from ~s older than ~p days", [Deleted, Table, Days]);
            _ -> ok
        end
    end, [
        {<<"ops_system_logs">>, <<"created_at">>},
        {<<"ops_request_errors">>, <<"created_at">>},
        {<<"channel_monitor_histories">>, <<"checked_at">>}
    ]),
    schedule_cleanup(),
    {noreply, State}.

schedule_cleanup() ->
    Hour = ersub_config_srv:get(ops_usage_cleanup_run_at_hour, 3),
    Ms = ms_until_hour(Hour),
    erlang:send_after(Ms, self(), cleanup).

ms_until_hour(TargetH) ->
    {_, {H, M, S}} = calendar:universal_time(),
    Secs = ((TargetH - H + 24) rem 24) * 3600 - M * 60 - S,
    erlang:max(60000, Secs * 1000).
