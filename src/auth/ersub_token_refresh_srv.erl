-module(ersub_token_refresh_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([trigger_refresh/1, schedule_refresh/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(CHECK_INTERVAL_MS, 60000).  %% check every 60s
-define(REFRESH_BEFORE_S, 300).     %% refresh 5min before expiry
-define(MAX_RETRIES, 3).
-define(COOLDOWN_MS, 600000).       %% 10min cooldown on failure

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Trigger immediate refresh for an account (e.g., on 401).
-spec trigger_refresh(integer()) -> ok.
trigger_refresh(AccountId) ->
    gen_server:cast(?SERVER, {trigger_refresh, AccountId}).

%% Schedule a refresh at a specific time.
-spec schedule_refresh(integer(), integer()) -> ok.
schedule_refresh(AccountId, AfterMs) ->
    erlang:send_after(AfterMs, ?SERVER, {refresh, AccountId}),
    ok.

%%% gen_server callbacks

init([]) ->
    schedule_check(),
    logger:info("Token refresh service started"),
    {ok, #{cooldowns => #{}, retries => #{}}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({trigger_refresh, AccountId}, State) ->
    NewState = do_refresh(AccountId, State),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_expiring, State) ->
    NewState = check_expiring_tokens(State),
    schedule_check(),
    {noreply, NewState};

handle_info({refresh, AccountId}, State) ->
    NewState = do_refresh(AccountId, State),
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

%%% Internal

schedule_check() ->
    erlang:send_after(?CHECK_INTERVAL_MS, self(), check_expiring).

check_expiring_tokens(State) ->
    AccountIds = ersub_platform_sup:list_accounts(),
    Now = erlang:system_time(second),
    lists:foldl(fun(AccountId, AccState) ->
        try
            AccountState = ersub_account_srv:get_state(AccountId),
            case needs_refresh(AccountState, Now) of
                true ->
                    logger:info("Token expiring soon for account ~p, refreshing", [AccountId]),
                    do_refresh(AccountId, AccState);
                false ->
                    AccState
            end
        catch _:_ -> AccState
        end
    end, State, AccountIds).

needs_refresh(AccountState, Now) ->
    case maps:get(account_type, AccountState, <<"api_key">>) of
        <<"oauth">> ->
            case maps:get(credentials, AccountState, #{}) of
                #{<<"token_expires">> := Expires} when is_integer(Expires) ->
                    Expires - Now < ?REFRESH_BEFORE_S;
                _ ->
                    false
            end;
        _ ->
            false
    end.

do_refresh(AccountId, #{cooldowns := Cooldowns, retries := Retries} = State) ->
    Now = erlang:monotonic_time(millisecond),
    %% Check cooldown
    case maps:get(AccountId, Cooldowns, 0) of
        CooldownUntil when CooldownUntil > Now ->
            logger:debug("Account ~p in cooldown, skipping refresh", [AccountId]),
            State;
        _ ->
            try
                AccountState = ersub_account_srv:get_state(AccountId),
                Platform = maps:get(platform, AccountState, <<"unknown">>),
                Creds = maps:get(credentials, AccountState, #{}),
                case refresh_token(Platform, AccountId, Creds) of
                    {ok, NewCreds} ->
                        %% Update account credentials in DB
                        CredsJson = jsx:encode(NewCreds),
                        ersub_repo:query(
                            "UPDATE accounts SET credentials = $2, updated_at = NOW() WHERE id = $1",
                            [AccountId, CredsJson]),
                        %% Update running account process
                        ersub_account_srv:update_status(AccountId, active),
                        logger:info("Token refreshed for account ~p", [AccountId]),
                        State#{retries => maps:remove(AccountId, Retries),
                               cooldowns => maps:remove(AccountId, Cooldowns)};
                    {error, Reason} ->
                        RetryCount = maps:get(AccountId, Retries, 0) + 1,
                        logger:warning("Token refresh failed for account ~p (attempt ~p): ~p",
                                       [AccountId, RetryCount, Reason]),
                        case RetryCount >= ?MAX_RETRIES of
                            true ->
                                %% Mark temp_unschedulable
                                ersub_account_srv:update_status(AccountId, temp_unschedulable),
                                State#{cooldowns => Cooldowns#{AccountId => Now + ?COOLDOWN_MS},
                                       retries => maps:remove(AccountId, Retries)};
                            false ->
                                State#{retries => Retries#{AccountId => RetryCount}}
                        end
                end
            catch _:Error ->
                logger:error("Token refresh crashed for account ~p: ~p", [AccountId, Error]),
                State
            end
    end.

%% Generic token refresh via CLIPS-configured OAuth endpoints
refresh_token(Platform, _AccountId, Creds) ->
    TokenUrl = maps:get(<<"token-url">>, ersub_clips_config:get_oauth_endpoint(Platform), <<>>),
    case TokenUrl of
        <<>> -> {error, {unsupported_platform, Platform}};
        Url -> refresh_oauth(Url, Creds)
    end.

refresh_oauth(TokenUrl, Creds) ->
    RefreshToken = maps:get(<<"refresh_token">>, Creds, undefined),
    case RefreshToken of
        undefined ->
            {error, no_refresh_token};
        _ ->
            Body = jsx:encode(#{
                <<"grant_type">> => <<"refresh_token">>,
                <<"refresh_token">> => RefreshToken
            }),
            Headers = [{<<"content-type">>, <<"application/json">>}],
            case ersub_upstream_pool:request(<<"POST">>, TokenUrl, Headers, Body, #{}, 10000) of
                {ok, 200, _, RespBody} ->
                    Resp = jsx:decode(RespBody, [return_maps]),
                    NewAccessToken = maps:get(<<"access_token">>, Resp),
                    ExpiresIn = maps:get(<<"expires_in">>, Resp, 3600),
                    NewCreds = Creds#{
                        <<"access_token">> => NewAccessToken,
                        <<"token_expires">> => erlang:system_time(second) + ExpiresIn
                    },
                    %% Update refresh_token if rotated
                    NewCreds2 = case maps:get(<<"refresh_token">>, Resp, undefined) of
                        undefined -> NewCreds;
                        NewRT -> NewCreds#{<<"refresh_token">> => NewRT}
                    end,
                    {ok, NewCreds2};
                {ok, Status, _, RespBody} ->
                    {error, {http_error, Status, RespBody}};
                {error, Reason} ->
                    {error, {request_failed, Reason}}
            end
    end.
