-module(ersub_secret_store).

-export([get/1, put/3, delete/1, list/0]).

-spec get(binary()) -> {ok, binary()} | {error, not_found}.
get(Name) ->
    case ersub_repo:query(
        "SELECT value FROM security_secrets WHERE name = $1", [Name]) of
        {ok, _, [{Value}]} -> {ok, Value};
        {ok, _, []} -> {error, not_found};
        {error, R} -> {error, R}
    end.

-spec put(binary(), binary(), binary()) -> ok | {error, term()}.
put(Name, SecretType, Value) ->
    case ersub_repo:query(
        "INSERT INTO security_secrets (name, secret_type, value) "
        "VALUES ($1, $2, $3) "
        "ON CONFLICT (name) DO UPDATE SET value = $3, updated_at = NOW()",
        [Name, SecretType, Value]) of
        {ok, _} -> ok;
        {ok, _, _, _} -> ok;
        {error, R} -> {error, R}
    end.

-spec delete(binary()) -> ok.
delete(Name) ->
    ersub_repo:query("DELETE FROM security_secrets WHERE name = $1", [Name]),
    ok.

-spec list() -> {ok, [map()]}.
list() ->
    case ersub_repo:squery(
        "SELECT name, secret_type, created_at FROM security_secrets ORDER BY name") of
        {ok, _, Rows} ->
            {ok, [#{name => N, type => T, created_at => C} || {N, T, C} <- Rows]};
        _ -> {ok, []}
    end.
