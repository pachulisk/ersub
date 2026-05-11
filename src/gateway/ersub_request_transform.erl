-module(ersub_request_transform).

-export([transform_claude_request/2, build_upstream_headers/2,
         resolve_model_mapping/2, match_wildcard/2,
         resolve_model_chain/3,
         apply_privacy_headers/2, apply_session_id/2,
         apply_messages_dispatch/2]).

%% Transform a Claude API request body before forwarding upstream.
%% Handles model passthrough, system prompt preservation, metadata stripping.
-spec transform_claude_request(map(), map()) -> {ok, binary()}.

transform_claude_request(Body, _Opts) ->
    %% For MVP: pass through with minimal transformation
    %% Strip internal metadata, preserve everything else
    Cleaned = maps:without([<<"internal_metadata">>, <<"ersub_context">>], Body),
    {ok, jsx:encode(Cleaned)}.

%% Build upstream request headers from account credentials.
-spec build_upstream_headers(map(), map()) -> [{binary(), binary()}].

build_upstream_headers(Account, Opts) ->
    #{credentials := Creds} = Account,
    ApiKey = maps:get(<<"api_key">>, Creds, maps:get(api_key, Creds, <<>>)),
    BaseHeaders = [
        {<<"content-type">>, <<"application/json">>},
        {<<"x-api-key">>, ApiKey},
        {<<"anthropic-version">>, maps:get(anthropic_version, Opts, <<"2023-06-01">>)}
    ],
    %% Add beta features header if present in original request
    case maps:get(anthropic_beta, Opts, undefined) of
        undefined -> BaseHeaders;
        Beta -> [{<<"anthropic-beta">>, Beta} | BaseHeaders]
    end.

%% Resolve model name through a mapping table.
%% Supports exact match and wildcard prefix matching (e.g., "gpt-*").
-spec resolve_model_mapping(binary(), map()) -> binary() | undefined.

resolve_model_mapping(Model, Mapping) when map_size(Mapping) =:= 0 ->
    Model;
resolve_model_mapping(Model, Mapping) ->
    case maps:get(Model, Mapping, undefined) of
        undefined ->
            %% Try wildcard matching
            case match_wildcard(Model, maps:to_list(Mapping)) of
                undefined -> Model;
                Target -> Target
            end;
        Target ->
            Target
    end.

%% Three-level model mapping chain: Channel → Account → Group.
%% Returns {FinalModel, MappingChain, BillingModelSource}.
-spec resolve_model_chain(binary(), map(), map()) ->
    {binary(), binary(), binary()}.

resolve_model_chain(OriginalModel, Account, ChannelMapping) ->
    %% Level 1: Channel mapping
    {Model1, Source1} = case map_size(ChannelMapping) of
        0 -> {OriginalModel, <<"original">>};
        _ ->
            case resolve_model_mapping(OriginalModel, ChannelMapping) of
                OriginalModel -> {OriginalModel, <<"original">>};
                Mapped -> {Mapped, <<"channel_mapped">>}
            end
    end,
    %% Level 2: Account-level mapping (from credentials.model_mapping)
    AccMapping = maps:get(<<"model_mapping">>,
        maps:get(credentials, Account, #{}), #{}),
    {Model2, Source2} = case map_size(AccMapping) of
        0 -> {Model1, Source1};
        _ ->
            case resolve_model_mapping(Model1, AccMapping) of
                Model1 -> {Model1, Source1};
                Mapped2 -> {Mapped2, <<"upstream">>}
            end
    end,
    %% Build chain string
    Chain = case Model2 =:= OriginalModel of
        true -> OriginalModel;
        false ->
            Parts = lists:filter(fun(P) -> P =/= <<>> end,
                [OriginalModel,
                 case Model1 =/= OriginalModel of true -> Model1; false -> <<>> end,
                 case Model2 =/= Model1 of true -> Model2; false -> <<>> end]),
            iolist_to_binary(lists:join(<<"→"/utf8>>, Parts))
    end,
    {Model2, Chain, Source2}.

%% Match a model name against wildcard patterns (e.g., "gpt-*" matches "gpt-4o").
-spec match_wildcard(binary(), [{binary(), binary()}]) -> binary() | undefined.

match_wildcard(_Model, []) ->
    undefined;
match_wildcard(Model, [{Pattern, Target} | Rest]) ->
    case binary:match(Pattern, <<"*">>) of
        {Pos, 1} ->
            Prefix = binary:part(Pattern, 0, Pos),
            PrefixLen = byte_size(Prefix),
            case Model of
                <<Prefix:PrefixLen/binary, _/binary>> -> Target;
                _ -> match_wildcard(Model, Rest)
            end;
        nomatch ->
            match_wildcard(Model, Rest)
    end.

%% A04: Privacy mode — inject training opt-out headers
-spec apply_privacy_headers([{binary(), binary()}], map()) -> [{binary(), binary()}].
apply_privacy_headers(Headers, Account) ->
    Privacy = maps:get(<<"privacy_mode">>, maps:get(credentials, Account, #{}), false),
    Platform = maps:get(platform, Account, <<>>),
    case Privacy of
        true ->
            case Platform of
                <<"openai">> ->
                    [{<<"openai-privacy">>, <<"true">>} | Headers];
                <<"antigravity">> ->
                    [{<<"x-training-opt-out">>, <<"true">>} | Headers];
                _ ->
                    Headers
            end;
        _ ->
            Headers
    end.

%% A05: Session ID masking — generate random session-id for Anthropic
-spec apply_session_id([{binary(), binary()}], map()) -> [{binary(), binary()}].
apply_session_id(Headers, Account) ->
    Platform = maps:get(platform, Account, <<>>),
    SessionMask = maps:get(<<"session_id_mask">>, maps:get(credentials, Account, #{}), false),
    case Platform =:= <<"claude">> andalso SessionMask =:= true of
        true ->
            FakeSessionId = binary:encode_hex(crypto:strong_rand_bytes(16)),
            [{<<"x-session-id">>, FakeSessionId} | Headers];
        false ->
            Headers
    end.

%% X02: Cross-platform model mapping via messages_dispatch.
%% Reads group's messages_dispatch_model_config from DB/config.
%% Maps model families: Claude opus->GPT-5.4, sonnet->GPT-5.3, haiku->GPT-5.4-mini (and reverse).
-spec apply_messages_dispatch(binary(), map()) -> {binary(), binary()}.
apply_messages_dispatch(Model, GroupConfig) ->
    ModelConfig = maps:get(<<"messages_dispatch_model_config">>, GroupConfig,
                   maps:get(messages_dispatch_model_config, GroupConfig, #{})),
    TargetPlatform = maps:get(<<"target_platform">>, GroupConfig,
                      maps:get(target_platform, GroupConfig, <<>>)),
    SourcePlatform = maps:get(<<"source_platform">>, GroupConfig,
                      maps:get(source_platform, GroupConfig, <<>>)),
    %% Use CLIPS dispatch rules for model mapping decisions
    case ersub_clips_pool:evaluate_messages_dispatch(#{
        model => Model,
        source_platform => SourcePlatform,
        target_platform => TargetPlatform,
        model_config => ModelConfig
    }) of
        {ok, #{<<"target_model">> := TargetModel}} when TargetModel =/= <<>> ->
            {TargetModel, TargetPlatform};
        {ok, _} ->
            %% Fallback: use built-in family mapping
            dispatch_model_family(Model, ModelConfig, TargetPlatform);
        {error, _} ->
            dispatch_model_family(Model, ModelConfig, TargetPlatform)
    end.

dispatch_model_family(Model, ModelConfig, TargetPlatform) ->
    %% Check explicit config first
    case maps:get(Model, ModelConfig, undefined) of
        undefined ->
            %% Built-in family mapping
            Mapped = map_model_family(Model),
            {Mapped, TargetPlatform};
        ExplicitTarget ->
            {ExplicitTarget, TargetPlatform}
    end.

map_model_family(Model) ->
    %% Default cross-platform model family mappings
    Families = [
        %% Claude → OpenAI
        {<<"opus">>, <<"gpt-5.4">>},
        {<<"sonnet">>, <<"gpt-5.3">>},
        {<<"haiku">>, <<"gpt-5.4-mini">>},
        %% OpenAI → Claude (reverse)
        {<<"gpt-5.4-mini">>, <<"claude-haiku">>},
        {<<"gpt-5.4">>, <<"claude-opus">>},
        {<<"gpt-5.3">>, <<"claude-sonnet">>}
    ],
    match_model_family(Model, Families).

match_model_family(Model, []) ->
    Model;
match_model_family(Model, [{Pattern, Target} | Rest]) ->
    case binary:match(Model, Pattern) of
        nomatch -> match_model_family(Model, Rest);
        _ -> Target
    end.
