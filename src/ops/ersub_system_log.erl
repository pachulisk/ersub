-module(ersub_system_log).

-export([log/3, log/4, query_recent/1, log_request_error/1]).

-spec log(binary(), binary(), binary()) -> ok.
log(Level, Source, Message) ->
    log(Level, Source, Message, #{}).

-spec log(binary(), binary(), binary(), map()) -> ok.
log(Level, Source, Message, Metadata) ->
    MetaJson = jsx:encode(Metadata),
    ersub_repo:query(
        "INSERT INTO ops_system_logs (level, source, message, metadata) "
        "VALUES ($1, $2, $3, $4)",
        [Level, Source, Message, MetaJson]),
    ok.

%% Log a gateway error to ops_request_errors table for ops tracking.
%% Spawns to avoid blocking the request path.
-spec log_request_error(map()) -> ok.
log_request_error(ErrorData) ->
    spawn(fun() ->
        try
            ersub_repo:query(
                "INSERT INTO ops_request_errors "
                "(request_id, user_id, account_id, platform, model, status_code, "
                "error_type, error_message) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
                [maps:get(request_id, ErrorData, null),
                 maps:get(user_id, ErrorData, null),
                 maps:get(account_id, ErrorData, null),
                 maps:get(platform, ErrorData, null),
                 maps:get(model, ErrorData, null),
                 maps:get(status_code, ErrorData, 0),
                 maps:get(error_type, ErrorData, <<"upstream">>),
                 maps:get(error_message, ErrorData, <<>>)])
        catch _:_ -> ok
        end
    end),
    ok.

-spec query_recent(integer()) -> {ok, [map()]} | {error, term()}.
query_recent(Limit) ->
    case ersub_repo:query(
        "SELECT id, level, source, message, created_at "
        "FROM ops_system_logs ORDER BY created_at DESC LIMIT $1",
        [Limit]) of
        {ok, _, Rows} ->
            {ok, [#{id => Id, level => L, source => S, message => M, created_at => C}
                  || {Id, L, S, M, C} <- Rows]};
        {error, R} -> {error, R}
    end.
