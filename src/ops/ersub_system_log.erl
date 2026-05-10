-module(ersub_system_log).

-export([log/3, log/4, query_recent/1]).

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
