-module(ersub_moderation_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([check_content/2, extract_content/2, redact_content/2]).
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
            %% Sampling: only check a percentage of requests
            SampleRate = ersub_config_srv:get(moderation_sample_rate, 100),
            case rand:uniform(100) =< SampleRate of
                true ->
                    gen_server:call(?SERVER, {check, UserId, Content, Mode}, 30000);
                false ->
                    ok  %% Skipped by sampling
            end
    end.

%%% gen_server callbacks

init([]) ->
    _ = ets:new(?DEDUP_TABLE, [named_table, public, set]),
    schedule_cleanup(),
    ApiKeys = load_api_keys(),
    logger:info("Moderation service started (keys=~p)", [length(ApiKeys)]),
    {ok, #{current_key_idx => 0, api_keys => ApiKeys}}.

handle_call({check, UserId, Content, Mode}, _From, State) ->
    ContentHash = content_hash(Content),
    {Result, State2} = case check_dedup(ContentHash) of
        {hit, CachedResult} ->
            %% Already moderated this exact content
            {CachedResult, State};
        miss ->
            %% Call external moderation API (with key rotation)
            {ModerationResult, NewState} = call_moderation_api(Content, State),
            %% Cache the result
            cache_result(ContentHash, ModerationResult),
            {ModerationResult, NewState}
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
    {reply, Reply, State2};

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

call_moderation_api(Content, State) ->
    %% External moderation API call
    %% Configure endpoint via ersub_config_srv
    Endpoint = ersub_config_srv:get(moderation_api_url, undefined),
    case Endpoint of
        undefined ->
            %% No external API configured, pass through
            {clean, State};
        Url when is_list(Url) ->
            call_moderation_api_http(list_to_binary(Url), Content, State);
        Url when is_binary(Url) ->
            call_moderation_api_http(Url, Content, State)
    end.

call_moderation_api_http(Url, Content, State) ->
    ReqBody = jsx:encode(#{content => Content}),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    ApiKey = get_current_api_key(State),
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
            %% M06: Check per-category thresholds
            Result = check_category_thresholds(Resp),
            {Result, State};
        {ok, 429, _, _ErrBody} ->
            %% M03: Rate limited, rotate to next key and retry once
            logger:warning("Moderation API rate limited, rotating key"),
            State2 = rotate_api_key(State),
            NewKey = get_current_api_key(State2),
            RetryHeaders = case NewKey of
                <<>> -> Headers;
                K2 when is_binary(K2) ->
                    [{<<"authorization">>, <<"Bearer ", K2/binary>>} | Headers];
                K2 when is_list(K2) ->
                    K2Bin = list_to_binary(K2),
                    [{<<"authorization">>, <<"Bearer ", K2Bin/binary>>} | Headers]
            end,
            case ersub_upstream_pool:request(<<"POST">>, Url, RetryHeaders, ReqBody, #{}, 10000) of
                {ok, 200, _, RespBody2} ->
                    Resp2 = jsx:decode(RespBody2, [return_maps]),
                    Result2 = check_category_thresholds(Resp2),
                    {Result2, State2};
                {ok, Status2, _, ErrBody2} ->
                    logger:error("Moderation API retry returned ~p: ~s", [Status2, ErrBody2]),
                    {{error, {moderation_api_error, Status2}}, State2};
                {error, Reason2} ->
                    logger:error("Moderation API retry failed: ~p", [Reason2]),
                    {{error, {moderation_api_down, Reason2}}, State2}
            end;
        {ok, Status, _, ErrBody} ->
            logger:error("Moderation API returned ~p: ~s", [Status, ErrBody]),
            {{error, {moderation_api_error, Status}}, State};
        {error, Reason} ->
            logger:error("Moderation API call failed: ~p", [Reason]),
            {{error, {moderation_api_down, Reason}}, State}
    end.

%% M06: Check each category's score against its threshold
check_category_thresholds(Resp) ->
    Thresholds = get_moderation_thresholds(),
    CategoryScores = maps:get(<<"category_scores">>, Resp, #{}),
    %% First check explicit per-category thresholds
    Flagged = maps:fold(fun(Category, Score, Acc) ->
        Threshold = maps:get(Category, Thresholds,
                     maps:get(binary_to_list(Category), Thresholds, 0.5)),
        case Score >= Threshold of
            true -> [{Category, Score} | Acc];
            false -> Acc
        end
    end, [], CategoryScores),
    case Flagged of
        [] ->
            %% Fall back to API's own flagged field
            case maps:get(<<"flagged">>, Resp, false) of
                true ->
                    Reason = maps:get(<<"reason">>, Resp, <<"content_policy_violation">>),
                    {flagged, Reason};
                false ->
                    clean
            end;
        [{TopCat, _} | _] ->
            {flagged, iolist_to_binary([<<"threshold_exceeded:">>, TopCat])}
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
    BanCfg = ersub_clips_config:get_ban_config(),
    Threshold = maps:get(<<"threshold">>, BanCfg, 5),
    Window = maps:get(<<"window-seconds">>, BanCfg, 86400),
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

%% M03: API key rotation helpers

load_api_keys() ->
    case ersub_config_srv:get(moderation_api_keys, undefined) of
        undefined ->
            %% Fall back to single key
            case ersub_config_srv:get(moderation_api_key, <<>>) of
                <<>> -> [];
                Key when is_binary(Key) -> [Key];
                Key when is_list(Key) -> [list_to_binary(Key)]
            end;
        Keys when is_list(Keys) ->
            [ensure_binary(K) || K <- Keys];
        _ ->
            []
    end.

get_current_api_key(#{api_keys := [], current_key_idx := _}) ->
    <<>>;
get_current_api_key(#{api_keys := Keys, current_key_idx := Idx}) ->
    lists:nth((Idx rem length(Keys)) + 1, Keys).

rotate_api_key(#{api_keys := Keys, current_key_idx := Idx} = State) ->
    case length(Keys) of
        0 -> State;
        Len -> State#{current_key_idx => (Idx + 1) rem Len}
    end.

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(_) -> <<>>.

%% M06: Load thresholds from config
get_moderation_thresholds() ->
    case ersub_config_srv:get(moderation_thresholds, #{}) of
        T when is_map(T) -> T;
        _ -> #{}
    end.

%% M01: Content redaction
%% Replace flagged content portions with [REDACTED].
-spec redact_content(binary(), [binary()]) -> binary().
redact_content(Content, []) ->
    Content;
redact_content(Content, FlaggedParts) ->
    lists:foldl(fun(Part, Acc) ->
        binary:replace(Acc, Part, <<"[REDACTED]">>, [global])
    end, Content, FlaggedParts).

%% M07: Multi-protocol content extraction
%% Extract text content from request bodies across different AI platform formats.
-spec extract_content(binary(), binary()) -> binary().
extract_content(<<"claude">>, Body) ->
    extract_claude_content(Body);
extract_content(<<"openai">>, Body) ->
    extract_openai_content(Body);
extract_content(<<"gemini">>, Body) ->
    extract_gemini_content(Body);
extract_content(<<"images">>, Body) ->
    extract_images_content(Body);
extract_content(_, Body) ->
    %% Fallback: try to extract as raw text
    case jsx:is_json(Body) of
        true ->
            Json = jsx:decode(Body, [return_maps]),
            maps:get(<<"content">>, Json, Body);
        false ->
            Body
    end.

%% Claude: messages[].content (text blocks)
extract_claude_content(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        Messages = maps:get(<<"messages">>, Json, []),
        Texts = lists:flatmap(fun(Msg) ->
            Content = maps:get(<<"content">>, Msg, <<>>),
            extract_claude_blocks(Content)
        end, Messages),
        iolist_to_binary(lists:join(<<" ">>, Texts))
    catch _:_ -> Body
    end.

extract_claude_blocks(Content) when is_binary(Content) ->
    [Content];
extract_claude_blocks(Content) when is_list(Content) ->
    [maps:get(<<"text">>, Block, <<>>) || Block <- Content,
     is_map(Block),
     maps:get(<<"type">>, Block, <<>>) =:= <<"text">>];
extract_claude_blocks(_) ->
    [].

%% OpenAI: messages[].content (string)
extract_openai_content(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        Messages = maps:get(<<"messages">>, Json, []),
        Texts = [maps:get(<<"content">>, Msg, <<>>) || Msg <- Messages,
                 is_map(Msg),
                 is_binary(maps:get(<<"content">>, Msg, <<>>))],
        iolist_to_binary(lists:join(<<" ">>, Texts))
    catch _:_ -> Body
    end.

%% Gemini: contents[].parts[].text
extract_gemini_content(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        Contents = maps:get(<<"contents">>, Json, []),
        Texts = lists:flatmap(fun(C) ->
            Parts = maps:get(<<"parts">>, C, []),
            [maps:get(<<"text">>, P, <<>>) || P <- Parts,
             is_map(P),
             maps:is_key(<<"text">>, P)]
        end, Contents),
        iolist_to_binary(lists:join(<<" ">>, Texts))
    catch _:_ -> Body
    end.

%% Images: prompt field
extract_images_content(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        maps:get(<<"prompt">>, Json, <<>>)
    catch _:_ -> Body
    end.
