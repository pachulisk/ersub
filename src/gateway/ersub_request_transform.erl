-module(ersub_request_transform).

-export([transform_claude_request/2, build_upstream_headers/2,
         resolve_model_mapping/2, match_wildcard/2]).

%% Transform a Claude API request body before forwarding upstream.
%% Handles model passthrough, system prompt preservation, metadata stripping.
-spec transform_claude_request(map(), map()) -> {ok, binary()} | {error, term()}.

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
