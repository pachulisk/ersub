-module(ersub_moderation_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([check_content/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(DEDUP_TABLE, ersub_moderation_dedup).
-define(DEDUP_CLEANUP_INTERVAL_MS, 300000).  %% 5 minutes
-define(DEDUP_TTL_SECONDS, 3600).            %% 1 hour
-define(DEFAULT_BAN_THRESHOLD, 5).
-define(DEFAULT_BAN_WINDOW_SECONDS, 86400).  %% 24 hours

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Check content against moderation rules.
%% Returns ok | {blocked, Reason} depending on mode.
-spec check_content(integer(), binary()) -> ok | {blocked, binary()}.
check_content(UserId, Content) ->
    Mode = get_mode(),
    case Mode of
        off ->
            ok;
        _ ->
            gen_server:call(?SERVER, {check, UserId, Content, Mode}, 30000)
    end.

%%% gen_server callbacks

init([]) ->
    ets:new(?DEDUP_TABLE, [named_table, public, set]),
    schedule_cleanup(),
    logger:info("Moderation service started"),
    {ok, #{}}.

handle_call({check, UserId, Content, Mode}, _From, State) ->
    ContentHash = content_hash(Content),
    Result = case check_dedup(ContentHash) of
        {hit, CachedResult} ->
            %% Already moderated this exact content
            CachedResult;
        miss ->
            %% Call external moderation API
            ModerationResult = call_moderation_api(Content),
            %% Cache the result
            cache_result(ContentHash, ModerationResult),
            ModerationResult
    end,
    %% Record to moderation_logs
    record_log(UserId, ContentHash, Result),
    %% Handle based on mode and result
    Reply = case {Mode, Result} of
        {observe, _} ->
            %% Observe mode: log but never block
            maybe_auto_ban(UserId),
            ok;
        {pre_block, {flagged, Reason}} ->
            maybe_auto_ban(UserId),
            {blocked, Reason};
        {pre_block, clean} ->
            ok
    end,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup_dedup, State) ->
    cleanup_expired_entries(),
    schedule_cleanup(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%% Internal

get_mode() ->
    case ersub_config_srv:get(moderation_mode, <<"off">>) of
        <<"off">> -> off;
        "off" -> off;
        off -> off;
        <<"observe">> -> observe;
        "observe" -> observe;
        observe -> observe;
        <<"pre_block">> -> pre_block;
        "pre_block" -> pre_block;
        pre_block -> pre_block;
        _ -> off
    end.

content_hash(Content) ->
    binary:encode_hex(crypto:hash(sha256, Content)).

check_dedup(Hash) ->
    case ets:lookup(?DEDUP_TABLE, Hash) of
        [{_, Result, Timestamp}] ->
            Now = erlang:system_time(second),
            case Now - Timestamp < ?DEDUP_TTL_SECONDS of
                true -> {hit, Result};
                false ->
                    ets:delete(?DEDUP_TABLE, Hash),
                    miss
            end;
        [] ->
            miss
    end.

cache_result(Hash, Result) ->
    Now = erlang:system_time(second),
    ets:insert(?DEDUP_TABLE, {Hash, Result, Now}).

call_moderation_api(Content) ->
    %% External moderation API call
    %% Configure endpoint via ersub_config_srv
    Endpoint = ersub_config_srv:get(moderation_api_url, undefined),
    case Endpoint of
        undefined ->
            %% No external API configured, pass through
            clean;
        Url when is_list(Url) ->
            call_moderation_api_http(list_to_binary(Url), Content);
        Url when is_binary(Url) ->
            call_moderation_api_http(Url, Content)
    end.

call_moderation_api_http(Url, Content) ->
    ReqBody = jsx:encode(#{content => Content}),
    Headers = [
        {<<"content-type">>, <<"application/json">>}
    ],
    ApiKey = ersub_config_srv:get(moderation_api_key, <<>>),
    FullHeaders = case ApiKey of
        <<>> -> Headers;
        Key when is_binary(Key) ->
            [{<<"authorization">>, <<"Bearer ", Key/binary>>} | Headers];
        Key when is_list(Key) ->
            KeyBin = list_to_binary(Key),
            [{<<"authorization">>, <<"Bearer ", KeyBin/binary>>} | Headers]
    end,
    case ersub_upstream_pool:request(<<"POST">>, Url, FullHeaders, ReqBody, #{}, 10000) of
        {ok, 200, _, RespBody} ->
            Resp = jsx:decode(RespBody, [return_maps]),
            case maps:get(<<"flagged">>, Resp, false) of
                true ->
                    Reason = maps:get(<<"reason">>, Resp, <<"content_policy_violation">>),
                    {flagged, Reason};
                false ->
                    clean
            end;
        {ok, Status, _, ErrBody} ->
            logger:error("Moderation API returned ~p: ~s", [Status, ErrBody]),
            {error, {moderation_api_error, Status}};
        {error, Reason} ->
            logger:error("Moderation API call failed: ~p", [Reason]),
            {error, {moderation_api_down, Reason}}
    end.

record_log(UserId, ContentHash, Result) ->
    {Flagged, Reason} = case Result of
        clean -> {false, null};
        {flagged, R} -> {true, R}
    end,
    case ersub_repo:query(
        "INSERT INTO moderation_logs (user_id, content_hash, flagged, reason) "
        "VALUES ($1, $2, $3, $4)",
        [UserId, ContentHash, Flagged, Reason])
    of
        {ok, _} -> ok;
        {error, DbReason} ->
            logger:error("Failed to record moderation log: ~p", [DbReason])
    end.

maybe_auto_ban(UserId) ->
    Threshold = ersub_config_srv:get(moderation_ban_threshold, ?DEFAULT_BAN_THRESHOLD),
    Window = ersub_config_srv:get(moderation_ban_window_seconds, ?DEFAULT_BAN_WINDOW_SECONDS),
    WindowInterval = integer_to_list(Window) ++ " seconds",
    case ersub_repo:query(
        "SELECT COUNT(*) FROM moderation_logs "
        "WHERE user_id = $1 AND flagged = TRUE "
        "AND created_at > NOW() - CAST($2 AS INTERVAL)",
        [UserId, list_to_binary(WindowInterval)])
    of
        {ok, _, [{Count}]} ->
            ViolationCount = case Count of
                C when is_binary(C) -> binary_to_integer(C);
                C when is_integer(C) -> C
            end,
            case ViolationCount >= Threshold of
                true ->
                    logger:warning("Auto-banning user ~p: ~p violations in window",
                                   [UserId, ViolationCount]),
                    ersub_repo:update_user(UserId, #{is_banned => true});
                false ->
                    ok
            end;
        {error, Reason} ->
            logger:error("Failed to check auto-ban for user ~p: ~p", [UserId, Reason])
    end.

schedule_cleanup() ->
    erlang:send_after(?DEDUP_CLEANUP_INTERVAL_MS, self(), cleanup_dedup).

cleanup_expired_entries() ->
    Now = erlang:system_time(second),
    %% Scan and delete expired entries
    ets:foldl(fun({Hash, _Result, Timestamp}, Acc) ->
        case Now - Timestamp >= ?DEDUP_TTL_SECONDS of
            true -> ets:delete(?DEDUP_TABLE, Hash);
            false -> ok
        end,
        Acc
    end, ok, ?DEDUP_TABLE).
