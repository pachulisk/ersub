-module(ersub_admin_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case verify_admin_jwt(Req0) of
        {error, Reason} ->
            Req = reply_json(401, #{error => #{
                type => <<"authentication_error">>,
                message => auth_msg(Reason)
            }}, Req0),
            {ok, Req, State};
        {ok, Claims} ->
            Path = cowboy_req:path_info(Req0),
            handle(Method, Path, Req0, State, Claims)
    end.

%% === Users ===

%% GET /api/admin/users
handle(<<"GET">>, [<<"users">>], Req0, State, _Claims) ->
    case ersub_repo:squery(
        "SELECT id, email, role, balance_usd, max_concurrency, is_banned, "
        "created_at FROM users WHERE deleted_at IS NULL ORDER BY id"
    ) of
        {ok, _, Rows} ->
            Users = [#{id => Id, email => E, role => R, balance_usd => B,
                       max_concurrency => MC, is_banned => IB, created_at => CA}
                     || {Id, E, R, B, MC, IB, CA} <- Rows],
            reply_ok(#{data => Users}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/users
handle(<<"POST">>, [<<"users">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Email = maps:get(<<"email">>, Params),
    Password = maps:get(<<"password">>, Params),
    Role = maps:get(<<"role">>, Params, <<"user">>),
    Hash = ersub_auth_srv:hash_password(Password),
    case ersub_repo:create_user(#{email => Email, password_hash => Hash, role => Role}) of
        {ok, User} ->
            reply_ok(#{data => maps:without([password_hash], User)}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === Accounts ===

%% GET /api/admin/accounts
handle(<<"GET">>, [<<"accounts">>], Req0, State, _Claims) ->
    case ersub_repo:list_accounts(#{}) of
        {ok, Accounts} ->
            reply_ok(#{data => Accounts}, Req0, State);
        {error, Reason} ->
            reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/accounts
handle(<<"POST">>, [<<"accounts">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Attrs = #{
        name => maps:get(<<"name">>, Params),
        platform => maps:get(<<"platform">>, Params),
        account_type => maps:get(<<"account_type">>, Params),
        credentials => maps:get(<<"credentials">>, Params, #{}),
        priority => maps:get(<<"priority">>, Params, 100),
        concurrency => maps:get(<<"concurrency">>, Params, 5)
    },
    case ersub_repo:create_account(Attrs) of
        {ok, Account} ->
            %% Start account process
            case ersub_repo:get_account(maps:get(id, Account)) of
                {ok, FullAcc} -> ersub_platform_sup:start_account(FullAcc);
                _ -> ok
            end,
            reply_ok(#{data => Account}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% DELETE /api/admin/accounts/:id
handle(<<"DELETE">>, [<<"accounts">>, IdBin], Req0, State, _Claims) ->
    Id = binary_to_integer(IdBin),
    ersub_platform_sup:stop_account(Id),
    case ersub_repo:delete_account(Id) of
        {ok, _} -> reply_ok(#{success => true}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% === Groups ===

%% GET /api/admin/groups
handle(<<"GET">>, [<<"groups">>], Req0, State, _Claims) ->
    case ersub_repo:list_groups() of
        {ok, Groups} -> reply_ok(#{data => Groups}, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/groups
handle(<<"POST">>, [<<"groups">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    Attrs = #{
        name => maps:get(<<"name">>, Params),
        platform => maps:get(<<"platform">>, Params),
        rate_multiplier => maps:get(<<"rate_multiplier">>, Params, 1.0)
    },
    case ersub_repo:create_group(Attrs) of
        {ok, Group} -> reply_ok(#{data => Group}, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% === Account-Group Binding ===

%% POST /api/admin/account-groups
handle(<<"POST">>, [<<"account-groups">>], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"account_id">> := AId, <<"group_id">> := GId} =
        jsx:decode(Body, [return_maps]),
    case ersub_repo:bind_account_to_group(AId, GId) of
        ok -> reply_ok(#{success => true}, Req1, State);
        {error, Reason} -> reply_err(500, Reason, Req1, State)
    end;

%% === Settings ===

%% GET /api/admin/settings/:key
handle(<<"GET">>, [<<"settings">>, Key], Req0, State, _Claims) ->
    case ersub_repo:get_setting(Key) of
        {ok, Value} -> reply_ok(#{data => #{key => Key, value => Value}}, Req0, State);
        {error, not_found} -> reply_err(404, not_found, Req0, State);
        {error, Reason} -> reply_err(500, Reason, Req0, State)
    end;

%% POST /api/admin/settings/:key
handle(<<"POST">>, [<<"settings">>, Key], Req0, State, _Claims) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Value = jsx:decode(Body, [return_maps]),
    case ersub_repo:upsert_setting(Key, Value) of
        {ok, _} ->
            %% Also update runtime config
            ersub_config_srv:set(binary_to_atom(Key), Value),
            reply_ok(#{success => true}, Req1, State);
        {error, Reason} ->
            reply_err(500, Reason, Req1, State)
    end;

%% === Dashboard ===

%% GET /api/admin/dashboard
handle(<<"GET">>, [<<"dashboard">>], Req0, State, _Claims) ->
    %% Basic dashboard stats
    {ok, _, [{UserCount}]} = ersub_repo:squery(
        "SELECT COUNT(*) FROM users WHERE deleted_at IS NULL"),
    {ok, _, [{AccountCount}]} = ersub_repo:squery(
        "SELECT COUNT(*) FROM accounts WHERE status = 'active'"),
    {ok, _, [{KeyCount}]} = ersub_repo:squery(
        "SELECT COUNT(*) FROM api_keys WHERE deleted_at IS NULL AND is_active = TRUE"),
    RunningAccounts = length(ersub_platform_sup:list_accounts()),
    Dashboard = #{
        users => binary_to_integer(UserCount),
        active_accounts => binary_to_integer(AccountCount),
        running_accounts => RunningAccounts,
        active_keys => binary_to_integer(KeyCount)
    },
    reply_ok(#{data => Dashboard}, Req0, State);

%% === Reload accounts ===

%% POST /api/admin/accounts/reload
handle(<<"POST">>, [<<"accounts">>, <<"reload">>], Req0, State, _Claims) ->
    ersub_platform_sup:load_all_accounts(),
    reply_ok(#{success => true, running => length(ersub_platform_sup:list_accounts())},
             Req0, State);

%% POST /api/admin/clips/reload
handle(<<"POST">>, [<<"clips">>, <<"reload">>], Req0, State, _Claims) ->
    ersub_clips_pool:reload_rules(),
    reply_ok(#{success => true}, Req0, State);

handle(_, _, Req0, State, _) ->
    Req = reply_json(404, #{error => #{message => <<"Not found">>}}, Req0),
    {ok, Req, State}.

%%% Internal

verify_admin_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            case ersub_auth_srv:verify_jwt(string:trim(Token)) of
                {ok, #{<<"role">> := <<"admin">>}} = Ok -> Ok;
                {ok, _} -> {error, not_admin};
                Err -> Err
            end;
        _ -> {error, missing_token}
    end.

reply_ok(Body, Req0, State) ->
    Req = reply_json(200, Body, Req0),
    {ok, Req, State}.

reply_err(Status, Reason, Req0, State) ->
    Req = reply_json(Status, #{error => #{
        type => <<"api_error">>,
        message => iolist_to_binary(io_lib:format("~p", [Reason]))
    }}, Req0),
    {ok, Req, State}.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

auth_msg(missing_token) -> <<"Missing Authorization header">>;
auth_msg(not_admin) -> <<"Admin role required">>;
auth_msg(token_expired) -> <<"Token expired">>;
auth_msg(_) -> <<"Authentication failed">>.
