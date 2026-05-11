-module(ersub_repo).

%% User operations
-export([create_user/1, get_user/1, get_user_by_email/1, update_user/2,
         get_user_balance/1, update_user_balance/2]).

%% Account operations
-export([create_account/1, get_account/1, list_accounts/1, update_account/2,
         delete_account/1]).

%% API Key operations
-export([create_api_key/1, get_api_key_by_hash/1, list_api_keys/1,
         update_api_key/2, delete_api_key/1]).

%% Group operations
-export([create_group/1, get_group/1, list_groups/0]).

%% Relations
-export([bind_account_to_group/2, unbind_account_from_group/2,
         list_account_groups/1, list_group_accounts/1]).
-export([add_user_to_group/2, remove_user_from_group/2,
         list_user_groups/1]).

%% Subscription operations
-export([create_subscription/1, get_subscription/2, update_subscription_usage/3]).

%% Channel operations
-export([create_channel/1, list_channels_by_group/1, delete_channel/1]).

%% Settings
-export([get_setting/1, upsert_setting/2]).

%% Generic query helper
-export([query/2, squery/1]).

%%% Query helpers

squery(SQL) ->
    ersub_repo_pool:with_conn(fun(W) ->
        gen_server:call(W, {squery, SQL}, 15000)
    end).

query(SQL, Params) ->
    ersub_repo_pool:with_conn(fun(W) ->
        gen_server:call(W, {equery, SQL, Params}, 15000)
    end).

%%% User operations

create_user(Attrs) ->
    #{email := Email, password_hash := PassHash} = Attrs,
    Role = maps:get(role, Attrs, <<"user">>),
    Balance = maps:get(balance_usd, Attrs, 0),
    MaxConc = maps:get(max_concurrency, Attrs, 5),
    case query(
        "INSERT INTO users (email, password_hash, role, balance_usd, max_concurrency) "
        "VALUES ($1, $2, $3, $4, $5) RETURNING id, created_at",
        [Email, PassHash, Role, Balance, MaxConc]
    ) of
        {ok, 1, _, [{Id, CreatedAt}]} ->
            {ok, Attrs#{id => Id, created_at => CreatedAt}};
        {error, Reason} ->
            {error, Reason}
    end.

get_user(Id) ->
    case query(
        "SELECT id, email, role, balance_usd, max_concurrency, totp_enabled, "
        "rpm_limit, is_banned, created_at, updated_at "
        "FROM users WHERE id = $1 AND deleted_at IS NULL", [Id]
    ) of
        {ok, _, [Row]} -> {ok, user_row_to_map(Row)};
        {ok, _, []} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

get_user_by_email(Email) ->
    case query(
        "SELECT id, email, password_hash, role, balance_usd, max_concurrency, "
        "totp_enabled, totp_secret, rpm_limit, is_banned, created_at "
        "FROM users WHERE email = $1 AND deleted_at IS NULL", [Email]
    ) of
        {ok, _, [Row]} -> {ok, user_auth_row_to_map(Row)};
        {ok, _, []} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

update_user(Id, Fields) ->
    {SetClauses, Params, _} = build_update_clauses(Fields, 2),
    SQL = "UPDATE users SET " ++ SetClauses ++ ", updated_at = NOW() WHERE id = $1",
    query(SQL, [Id | Params]).

get_user_balance(UserId) ->
    case query("SELECT balance_usd FROM users WHERE id = $1", [UserId]) of
        {ok, _, [{Balance}]} -> {ok, Balance};
        {ok, _, []} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

update_user_balance(UserId, Amount) ->
    query("UPDATE users SET balance_usd = balance_usd + $2, updated_at = NOW() "
          "WHERE id = $1", [UserId, Amount]).

%%% Account operations

create_account(Attrs) ->
    #{name := Name, platform := Platform, account_type := Type,
      credentials := Creds} = Attrs,
    Priority = maps:get(priority, Attrs, 100),
    Concurrency = maps:get(concurrency, Attrs, 5),
    CredsJson = jsx:encode(Creds),
    case query(
        "INSERT INTO accounts (name, platform, account_type, credentials, "
        "priority, concurrency) VALUES ($1, $2, $3, $4, $5, $6) "
        "RETURNING id, created_at",
        [Name, Platform, Type, CredsJson, Priority, Concurrency]
    ) of
        {ok, 1, _, [{Id, CreatedAt}]} ->
            {ok, Attrs#{id => Id, created_at => CreatedAt}};
        {error, Reason} ->
            {error, Reason}
    end.

get_account(Id) ->
    case query(
        "SELECT id, name, platform, account_type, credentials, status, "
        "priority, concurrency, load_factor, rate_multiplier, schedulable, "
        "error_message, rate_limited_until, overload_until, base_url, notes, "
        "expires_at, last_used_at, created_at "
        "FROM accounts WHERE id = $1", [Id]
    ) of
        {ok, _, [Row]} -> {ok, account_row_to_map(Row)};
        {ok, _, []} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

list_accounts(Filters) ->
    Platform = maps:get(platform, Filters, undefined),
    Status = maps:get(status, Filters, undefined),
    {Where, Params} = build_account_filters(Platform, Status),
    SQL = "SELECT id, name, platform, account_type, status, priority, "
          "concurrency, schedulable, rate_multiplier, last_used_at, created_at "
          "FROM accounts" ++ Where ++ " ORDER BY priority ASC, id ASC",
    case query(SQL, Params) of
        {ok, _, Rows} -> {ok, [account_list_row_to_map(R) || R <- Rows]};
        {error, Reason} -> {error, Reason}
    end.

update_account(Id, Fields) ->
    {SetClauses, Params, _Idx} = build_update_clauses(Fields, 2),
    SQL = "UPDATE accounts SET " ++ SetClauses ++ ", updated_at = NOW() WHERE id = $1",
    query(SQL, [Id | Params]).

delete_account(Id) ->
    query("DELETE FROM accounts WHERE id = $1", [Id]).

%%% API Key operations

create_api_key(Attrs) ->
    #{user_id := UserId, key_hash := Hash, key_prefix := Prefix} = Attrs,
    Name = maps:get(name, Attrs, null),
    case query(
        "INSERT INTO api_keys (user_id, key_hash, key_prefix, name) "
        "VALUES ($1, $2, $3, $4) RETURNING id, created_at",
        [UserId, Hash, Prefix, Name]
    ) of
        {ok, 1, _, [{Id, CreatedAt}]} ->
            {ok, Attrs#{id => Id, created_at => CreatedAt}};
        {error, Reason} ->
            {error, Reason}
    end.

get_api_key_by_hash(Hash) ->
    case query(
        "SELECT k.id, k.user_id, k.key_prefix, k.name, k.max_concurrency, "
        "k.rpm_limit, k.rate_limit_5h, k.ip_whitelist, k.ip_blacklist, "
        "k.allowed_models, k.is_active, k.expires_at, "
        "u.email, u.role, u.balance_usd, u.max_concurrency AS user_max_concurrency, "
        "u.is_banned, u.rpm_limit AS user_rpm_limit "
        "FROM api_keys k JOIN users u ON k.user_id = u.id "
        "WHERE k.key_hash = $1 AND k.deleted_at IS NULL AND k.is_active = TRUE "
        "AND u.deleted_at IS NULL", [Hash]
    ) of
        {ok, _, [Row]} -> {ok, api_key_with_user_row_to_map(Row)};
        {ok, _, []} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

list_api_keys(UserId) ->
    case query(
        "SELECT id, key_prefix, name, is_active, created_at "
        "FROM api_keys WHERE user_id = $1 AND deleted_at IS NULL "
        "ORDER BY created_at DESC", [UserId]
    ) of
        {ok, _, Rows} ->
            {ok, [#{id => Id, key_prefix => KP, name => N,
                    is_active => A, created_at => C}
                  || {Id, KP, N, A, C} <- Rows]};
        {error, Reason} ->
            {error, Reason}
    end.

update_api_key(Id, Fields) ->
    {SetClauses, Params, _Idx} = build_update_clauses(Fields, 2),
    SQL = "UPDATE api_keys SET " ++ SetClauses ++ " WHERE id = $1",
    query(SQL, [Id | Params]).

delete_api_key(Id) ->
    query("UPDATE api_keys SET deleted_at = NOW() WHERE id = $1", [Id]).

%%% Group operations

create_group(Attrs) ->
    #{name := Name, platform := Platform} = Attrs,
    RateMult = maps:get(rate_multiplier, Attrs, 1.0),
    case query(
        "INSERT INTO groups (name, platform, rate_multiplier) "
        "VALUES ($1, $2, $3) RETURNING id, created_at",
        [Name, Platform, RateMult]
    ) of
        {ok, 1, _, [{Id, CreatedAt}]} ->
            {ok, Attrs#{id => Id, created_at => CreatedAt}};
        {error, Reason} ->
            {error, Reason}
    end.

get_group(Id) ->
    case query("SELECT id, name, platform, billing_type, rate_multiplier, "
               "rpm_limit, claude_code_only, created_at "
               "FROM groups WHERE id = $1", [Id]) of
        {ok, _, [{GId, Name, Platform, BT, RM, RPM, CCO, CA}]} ->
            {ok, #{id => GId, name => Name, platform => Platform,
                   billing_type => BT, rate_multiplier => RM,
                   rpm_limit => RPM, claude_code_only => CCO,
                   created_at => CA}};
        {ok, _, []} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

list_groups() ->
    case squery("SELECT id, name, platform, billing_type, rate_multiplier, "
                "created_at FROM groups ORDER BY sort_order ASC, id ASC") of
        {ok, _, Rows} ->
            {ok, [#{id => Id, name => Name, platform => P,
                    billing_type => BT, rate_multiplier => RM,
                    created_at => CA}
                  || {Id, Name, P, BT, RM, CA} <- Rows]};
        {error, Reason} ->
            {error, Reason}
    end.

%%% Relations

bind_account_to_group(AccountId, GroupId) ->
    case query(
        "INSERT INTO account_groups (account_id, group_id) VALUES ($1, $2) "
        "ON CONFLICT DO NOTHING", [AccountId, GroupId]
    ) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

unbind_account_from_group(AccountId, GroupId) ->
    query("DELETE FROM account_groups WHERE account_id = $1 AND group_id = $2",
          [AccountId, GroupId]).

list_account_groups(AccountId) ->
    case query("SELECT group_id FROM account_groups WHERE account_id = $1",
               [AccountId]) of
        {ok, _, Rows} -> {ok, [GId || {GId} <- Rows]};
        {error, Reason} -> {error, Reason}
    end.

list_group_accounts(GroupId) ->
    case query("SELECT account_id FROM account_groups WHERE group_id = $1",
               [GroupId]) of
        {ok, _, Rows} -> {ok, [AId || {AId} <- Rows]};
        {error, Reason} -> {error, Reason}
    end.

add_user_to_group(UserId, GroupId) ->
    case query(
        "INSERT INTO user_allowed_groups (user_id, group_id) VALUES ($1, $2) "
        "ON CONFLICT DO NOTHING", [UserId, GroupId]
    ) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

remove_user_from_group(UserId, GroupId) ->
    query("DELETE FROM user_allowed_groups WHERE user_id = $1 AND group_id = $2",
          [UserId, GroupId]).

list_user_groups(UserId) ->
    case query(
        "SELECT g.id, g.name, g.platform, g.rate_multiplier "
        "FROM groups g JOIN user_allowed_groups ug ON g.id = ug.group_id "
        "WHERE ug.user_id = $1 ORDER BY g.sort_order ASC", [UserId]
    ) of
        {ok, _, Rows} ->
            {ok, [#{id => Id, name => N, platform => P, rate_multiplier => RM}
                  || {Id, N, P, RM} <- Rows]};
        {error, Reason} ->
            {error, Reason}
    end.

%%% Settings

get_setting(Key) ->
    case query("SELECT value FROM settings WHERE key = $1", [Key]) of
        {ok, _, [{Value}]} -> {ok, jsx:decode(Value, [return_maps])};
        {ok, _, []} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

upsert_setting(Key, Value) ->
    JsonValue = jsx:encode(Value),
    query(
        "INSERT INTO settings (key, value) VALUES ($1, $2) "
        "ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()",
        [Key, JsonValue]).

%%% Subscription operations

create_subscription(Attrs) ->
    #{user_id := UserId, group_id := GroupId, starts_at := StartsAt} = Attrs,
    ExpiresAt = maps:get(expires_at, Attrs, null),
    query(
        "INSERT INTO user_subscriptions (user_id, group_id, starts_at, expires_at) "
        "VALUES ($1, $2, $3, $4) RETURNING id, created_at",
        [UserId, GroupId, StartsAt, ExpiresAt]).

get_subscription(UserId, GroupId) ->
    case query(
        "SELECT id, user_id, group_id, status, daily_usage_usd, weekly_usage_usd, "
        "monthly_usage_usd, starts_at, expires_at FROM user_subscriptions "
        "WHERE user_id = $1 AND group_id = $2 AND status = 'active'",
        [UserId, GroupId]) of
        {ok, _, [Row]} -> {ok, Row};
        {ok, _, []} -> {error, not_found};
        {error, R} -> {error, R}
    end.

update_subscription_usage(SubId, Field, Amount) ->
    SQL = "UPDATE user_subscriptions SET " ++ atom_to_list(Field) ++
          " = " ++ atom_to_list(Field) ++ " + $2 WHERE id = $1",
    query(SQL, [SubId, Amount]).

%%% Channel operations

create_channel(Attrs) ->
    #{name := Name, group_id := GroupId, platform := Platform,
      base_url := BaseUrl} = Attrs,
    ModelMapping = maps:get(model_mapping, Attrs, null),
    MappingJson = case ModelMapping of null -> null; M -> jsx:encode(M) end,
    query(
        "INSERT INTO channels (name, group_id, platform, base_url, model_mapping) "
        "VALUES ($1, $2, $3, $4, $5) RETURNING id, created_at",
        [Name, GroupId, Platform, BaseUrl, MappingJson]).

list_channels_by_group(GroupId) ->
    case query(
        "SELECT id, name, platform, base_url, is_active "
        "FROM channels WHERE group_id = $1 ORDER BY id", [GroupId]) of
        {ok, _, Rows} ->
            {ok, [#{id => Id, name => N, platform => P, base_url => B, is_active => A}
                  || {Id, N, P, B, A} <- Rows]};
        {error, R} -> {error, R}
    end.

delete_channel(Id) ->
    query("DELETE FROM channels WHERE id = $1", [Id]).

%%% Internal helpers

user_row_to_map({Id, Email, Role, Balance, MaxConc, TotpEnabled,
                 RpmLimit, IsBanned, CreatedAt, UpdatedAt}) ->
    #{id => Id, email => Email, role => Role, balance_usd => Balance,
      max_concurrency => MaxConc, totp_enabled => TotpEnabled,
      rpm_limit => RpmLimit, is_banned => IsBanned,
      created_at => CreatedAt, updated_at => UpdatedAt}.

user_auth_row_to_map({Id, Email, PassHash, Role, Balance, MaxConc,
                      TotpEnabled, TotpSecret, RpmLimit, IsBanned, CreatedAt}) ->
    #{id => Id, email => Email, password_hash => PassHash, role => Role,
      balance_usd => Balance, max_concurrency => MaxConc,
      totp_enabled => TotpEnabled, totp_secret => TotpSecret,
      rpm_limit => RpmLimit, is_banned => IsBanned, created_at => CreatedAt}.

account_row_to_map({Id, Name, Platform, Type, CredsJson, Status,
                    Priority, Concurrency, LoadFactor, RateMult, Schedulable,
                    ErrMsg, RLUntil, OLUntil, BaseUrl, Notes,
                    ExpiresAt, LastUsed, CreatedAt}) ->
    Creds = case CredsJson of
        null -> #{};
        _ -> jsx:decode(CredsJson, [return_maps])
    end,
    #{id => Id, name => Name, platform => Platform, account_type => Type,
      credentials => Creds, status => Status, priority => Priority,
      concurrency => Concurrency, load_factor => LoadFactor,
      rate_multiplier => RateMult, schedulable => Schedulable,
      error_message => ErrMsg, rate_limited_until => RLUntil,
      overload_until => OLUntil, base_url => BaseUrl, notes => Notes,
      expires_at => ExpiresAt, last_used_at => LastUsed,
      created_at => CreatedAt}.

account_list_row_to_map({Id, Name, Platform, Type, Status, Priority,
                         Concurrency, Schedulable, RateMult, LastUsed, CreatedAt}) ->
    #{id => Id, name => Name, platform => Platform, account_type => Type,
      status => Status, priority => Priority, concurrency => Concurrency,
      schedulable => Schedulable, rate_multiplier => RateMult,
      last_used_at => LastUsed, created_at => CreatedAt}.

api_key_with_user_row_to_map({KId, UserId, KPrefix, KName, KMaxConc,
                               KRpm, KRate5h, IpWL, IpBL, Models,
                               IsActive, ExpiresAt,
                               UEmail, URole, UBalance, UMaxConc,
                               UIsBanned, URpmLimit}) ->
    #{key_id => KId, user_id => UserId, key_prefix => KPrefix,
      key_name => KName, key_max_concurrency => KMaxConc,
      key_rpm_limit => KRpm, key_rate_limit_5h => KRate5h,
      ip_whitelist => decode_jsonb(IpWL), ip_blacklist => decode_jsonb(IpBL),
      allowed_models => Models, is_active => IsActive,
      expires_at => ExpiresAt,
      user_email => UEmail, user_role => URole,
      user_balance => UBalance, user_max_concurrency => UMaxConc,
      user_is_banned => UIsBanned, user_rpm_limit => URpmLimit}.

decode_jsonb(null) -> [];
decode_jsonb(Json) when is_binary(Json) -> jsx:decode(Json, [return_maps]);
decode_jsonb(Other) -> Other.

build_account_filters(undefined, undefined) ->
    {"", []};
build_account_filters(Platform, undefined) ->
    {" WHERE platform = $1", [Platform]};
build_account_filters(undefined, Status) ->
    {" WHERE status = $1", [Status]};
build_account_filters(Platform, Status) ->
    {" WHERE platform = $1 AND status = $2", [Platform, Status]}.

build_update_clauses(Fields, StartIdx) ->
    {Clauses, Params, FinalIdx} = maps:fold(fun(Key, Value, {C, P, Idx}) ->
        Clause = atom_to_list(Key) ++ " = $" ++ integer_to_list(Idx),
        {[Clause | C], P ++ [Value], Idx + 1}
    end, {[], [], StartIdx}, Fields),
    {string:join(lists:reverse(Clauses), ", "), Params, FinalIdx}.
