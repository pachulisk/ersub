-module(ersub_billing_dedup).

-export([check_and_mark/1, archive_old/0]).

%% Check if a request has already been billed. If not, mark it.
%% Returns ok | {error, already_billed}
-spec check_and_mark(binary()) -> ok | {error, already_billed}.
check_and_mark(RequestId) ->
    case ersub_repo:query(
        "INSERT INTO usage_billing_dedup (request_id) VALUES ($1) "
        "ON CONFLICT (request_id) DO NOTHING RETURNING request_id",
        [RequestId]) of
        {ok, 1, _, _} -> ok;           %% New entry, proceed with billing
        {ok, 0, _, _} -> {error, already_billed}; %% Already exists
        {ok, 0} -> {error, already_billed};
        {error, Reason} ->
            logger:warning("Billing dedup check failed: ~p (allowing)", [Reason]),
            ok %% Fail open
    end.

%% Archive old dedup entries (configurable TTL) to archive table.
-spec archive_old() -> ok.
archive_old() ->
    TtlDays = maps:get(<<"ttl-days">>, ersub_clips_config:get_dedup_config(), 7),
    Interval = iolist_to_binary([integer_to_list(TtlDays), " days"]),
    SelectQ = iolist_to_binary([
        "INSERT INTO usage_billing_dedup_archive (request_id, billed_at) "
        "SELECT request_id, billed_at FROM usage_billing_dedup "
        "WHERE billed_at < NOW() - INTERVAL '", Interval, "' "
        "ON CONFLICT DO NOTHING"]),
    DeleteQ = iolist_to_binary([
        "DELETE FROM usage_billing_dedup "
        "WHERE billed_at < NOW() - INTERVAL '", Interval, "'"]),
    ersub_repo:squery(binary_to_list(SelectQ)),
    ersub_repo:squery(binary_to_list(DeleteQ)),
    ok.
