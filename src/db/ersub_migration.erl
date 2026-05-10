-module(ersub_migration).

-export([run/0, run/1]).

-define(MIGRATIONS_DIR, "priv/migrations").

%% Run all pending migrations using the default pool
-spec run() -> ok | {error, term()}.
run() ->
    run(fun(SQL) ->
        ersub_repo_pool:with_conn(fun(Worker) ->
            gen_server:call(Worker, {squery, SQL}, 30000)
        end)
    end).

%% Run all pending migrations using a custom query function
-spec run(fun((string()) -> term())) -> ok | {error, term()}.
run(QueryFun) ->
    ensure_migrations_table(QueryFun),
    Applied = get_applied_migrations(QueryFun),
    MigrationFiles = list_migration_files(),
    Pending = [F || F <- MigrationFiles, not lists:member(filename(F), Applied)],
    case Pending of
        [] ->
            logger:info("No pending migrations"),
            ok;
        _ ->
            logger:info("Running ~p pending migration(s)", [length(Pending)]),
            run_pending(Pending, QueryFun)
    end.

%%% Internal

ensure_migrations_table(QueryFun) ->
    SQL = "CREATE TABLE IF NOT EXISTS schema_migrations ("
          "  version TEXT PRIMARY KEY,"
          "  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()"
          ")",
    QueryFun(SQL).

get_applied_migrations(QueryFun) ->
    case QueryFun("SELECT version FROM schema_migrations ORDER BY version") of
        {ok, _, Rows} ->
            [binary_to_list(V) || {V} <- Rows];
        _ ->
            []
    end.

list_migration_files() ->
    Dir = migrations_dir(),
    case filelib:is_dir(Dir) of
        true ->
            Files = filelib:wildcard(filename:join(Dir, "*.sql")),
            lists:sort(Files);
        false ->
            logger:warning("Migrations directory not found: ~s", [Dir]),
            []
    end.

migrations_dir() ->
    case code:priv_dir(ersub) of
        {error, _} -> ?MIGRATIONS_DIR;
        PrivDir -> filename:join(PrivDir, "migrations")
    end.

filename(Path) ->
    filename:basename(Path).

run_pending([], _QueryFun) ->
    ok;
run_pending([File | Rest], QueryFun) ->
    Name = filename(File),
    logger:info("Applying migration: ~s", [Name]),
    case file:read_file(File) of
        {ok, SQL} ->
            case QueryFun(binary_to_list(SQL)) of
                {error, Reason} ->
                    logger:error("Migration ~s failed: ~p", [Name, Reason]),
                    {error, {migration_failed, Name, Reason}};
                _ ->
                    RecordSQL = io_lib:format(
                        "INSERT INTO schema_migrations (version) VALUES ('~s')",
                        [Name]),
                    QueryFun(lists:flatten(RecordSQL)),
                    logger:info("Migration ~s applied successfully", [Name]),
                    run_pending(Rest, QueryFun)
            end;
        {error, Reason} ->
            logger:error("Failed to read migration file ~s: ~p", [File, Reason]),
            {error, {read_failed, File, Reason}}
    end.
