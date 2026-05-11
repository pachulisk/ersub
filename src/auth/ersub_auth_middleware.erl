-module(ersub_auth_middleware).

-export([authenticate/1, hash_api_key/1, init_cache/0, reply_error/3,
         check_group_assignment/1]).

%% ETS table for API key cache
-define(KEY_CACHE, ersub_api_key_cache).
-define(CACHE_TTL_MS, 60000). %% 60 seconds

init_cache() ->
    case ets:info(?KEY_CACHE) of
        undefined ->
            ets:new(?KEY_CACHE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ?KEY_CACHE
    end.

%% Authenticate a request by extracting and validating the API key.
%% Returns {ok, AuthContext} or {error, Reason}.
-spec authenticate(cowboy_req:req()) ->
    {ok, map()} | {error, missing_key | invalid_key | key_expired | user_banned | key_inactive}.

authenticate(Req) ->
    case extract_api_key(Req) of
        undefined ->
            {error, missing_key};
        RawKey ->
            Hash = hash_api_key(RawKey),
            case lookup_key(Hash) of
                {ok, AuthCtx} ->
                    validate_auth_context(AuthCtx);
                {error, _} = Err ->
                    Err
            end
    end.

%% Hash an API key using SHA-256
-spec hash_api_key(binary()) -> binary().
hash_api_key(Key) ->
    Digest = crypto:hash(sha256, Key),
    bin_to_hex(Digest).

%%% Internal

%% Extract API key from request headers.
%% Supports: x-api-key header, Authorization: Bearer <key>
extract_api_key(Req) ->
    case cowboy_req:header(<<"x-api-key">>, Req) of
        undefined ->
            case cowboy_req:header(<<"authorization">>, Req) of
                undefined ->
                    undefined;
                Auth ->
                    parse_bearer_token(Auth)
            end;
        Key ->
            Key
    end.

parse_bearer_token(<<"Bearer ", Token/binary>>) ->
    case Token of
        <<>> -> undefined;
        _ -> string:trim(Token)
    end;
parse_bearer_token(<<"bearer ", Token/binary>>) ->
    case Token of
        <<>> -> undefined;
        _ -> string:trim(Token)
    end;
parse_bearer_token(_) ->
    undefined.

%% Look up key: check ETS cache first, then DB
lookup_key(Hash) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?KEY_CACHE, Hash) of
        [{_, AuthCtx, ExpiresAt}] when ExpiresAt > Now ->
            {ok, AuthCtx};
        _ ->
            lookup_key_from_db(Hash, Now)
    end.

lookup_key_from_db(Hash, Now) ->
    case ersub_repo:get_api_key_by_hash(Hash) of
        {ok, KeyData} ->
            AuthCtx = build_auth_context(KeyData),
            ets:insert(?KEY_CACHE, {Hash, AuthCtx, Now + ?CACHE_TTL_MS}),
            {ok, AuthCtx};
        {error, not_found} ->
            {error, invalid_key};
        {error, Reason} ->
            logger:error("API key lookup failed: ~p", [Reason]),
            {error, invalid_key}
    end.

build_auth_context(KeyData) ->
    #{
        key_id => maps:get(key_id, KeyData),
        user_id => maps:get(user_id, KeyData),
        user_email => maps:get(user_email, KeyData),
        user_role => maps:get(user_role, KeyData),
        user_balance => maps:get(user_balance, KeyData),
        user_max_concurrency => maps:get(user_max_concurrency, KeyData),
        user_is_banned => maps:get(user_is_banned, KeyData),
        user_rpm_limit => maps:get(user_rpm_limit, KeyData),
        key_prefix => maps:get(key_prefix, KeyData),
        key_max_concurrency => maps:get(key_max_concurrency, KeyData),
        key_rpm_limit => maps:get(key_rpm_limit, KeyData),
        key_rate_limit_5h => maps:get(key_rate_limit_5h, KeyData),
        ip_whitelist => maps:get(ip_whitelist, KeyData),
        ip_blacklist => maps:get(ip_blacklist, KeyData),
        allowed_models => maps:get(allowed_models, KeyData),
        is_active => maps:get(is_active, KeyData),
        expires_at => maps:get(expires_at, KeyData)
    }.

validate_auth_context(#{user_is_banned := true}) ->
    {error, user_banned};
validate_auth_context(#{is_active := false}) ->
    {error, key_inactive};
validate_auth_context(#{expires_at := ExpiresAt} = Ctx) when ExpiresAt =/= null ->
    Now = calendar:universal_time(),
    case ExpiresAt > Now of
        true -> {ok, Ctx};
        false -> {error, key_expired}
    end;
validate_auth_context(Ctx) ->
    {ok, Ctx}.

%% Check if a user has at least one group assignment via user_allowed_groups.
%% Returns ok if assigned, {error, no_group_assigned} otherwise.
-spec check_group_assignment(integer()) -> ok | {error, no_group_assigned}.
check_group_assignment(UserId) ->
    case ersub_repo:query(
        "SELECT 1 FROM user_allowed_groups WHERE user_id = $1 LIMIT 1",
        [UserId]
    ) of
        {ok, _, [_|_]} -> ok;
        {ok, _, []} -> {error, no_group_assigned};
        {error, _Reason} -> {error, no_group_assigned}
    end.

reply_error(Req, StatusCode, Message) ->
    Body = jsx:encode(#{
        error => #{
            type => <<"authentication_error">>,
            message => Message
        }
    }),
    cowboy_req:reply(StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req).

bin_to_hex(Bin) ->
    list_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
