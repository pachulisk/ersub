-module(ersub_setup).

-export([check_and_run/0, is_installed/0]).

-define(LOCK_FILE, ".installed").

%% Check if setup has been run; if not, log instructions.
-spec check_and_run() -> ok | {error, term()}.
check_and_run() ->
    case is_installed() of
        true ->
            ok;
        false ->
            logger:notice("=== ErSub First-Run Setup ==="),
            logger:notice("No .installed file found. Running initial setup..."),
            run_setup()
    end.

-spec is_installed() -> boolean().
is_installed() ->
    DataDir = data_dir(),
    LockPath = filename:join(DataDir, ?LOCK_FILE),
    filelib:is_file(LockPath).

%%% Internal

run_setup() ->
    DataDir = data_dir(),
    filelib:ensure_dir(filename:join(DataDir, "dummy")),
    %% Run migrations
    logger:notice("Running database migrations..."),
    ok = ersub_migration:run(),
    %% Check if admin user exists
    case ersub_repo:squery("SELECT COUNT(*) FROM users WHERE role = 'admin'") of
        {ok, _, [{<<"0">>}]} ->
            logger:notice("Creating default admin user..."),
            Hash = ersub_auth_srv:hash_password(<<"admin">>),
            case ersub_repo:create_user(#{
                email => <<"admin@ersub.local">>,
                password_hash => Hash,
                role => <<"admin">>,
                balance_usd => 0
            }) of
                {ok, User} ->
                    {ok, Token} = ersub_auth_srv:generate_jwt(#{
                        <<"user_id">> => maps:get(id, User),
                        <<"role">> => <<"admin">>
                    }),
                    logger:notice("Admin user created: admin@ersub.local / admin"),
                    logger:notice("Admin JWT: ~s", [Token]);
                {error, Reason} ->
                    logger:error("Failed to create admin: ~p", [Reason])
            end;
        _ ->
            logger:notice("Admin user already exists, skipping")
    end,
    %% Write lock file
    LockPath = filename:join(DataDir, ?LOCK_FILE),
    ok = file:write_file(LockPath, <<"installed\n">>),
    logger:notice("Setup complete. Lock file written to ~s", [LockPath]),
    ok.

data_dir() ->
    case os:getenv("DATA_DIR") of
        false ->
            case filelib:is_dir("/app/data") of
                true -> "/app/data";
                false -> "."
            end;
        Dir -> Dir
    end.
