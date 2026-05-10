-module(ersub_client_detector).

-export([detect_client/2, enforce_client_restriction/2]).

%% Detect client type from request headers and body.
%% Returns {claude_code, Version} | {official, Type} | unknown.
-spec detect_client(map(), map()) ->
    {claude_code, binary()} | {official, atom()} | unknown.

detect_client(Headers, Body) ->
    UA = maps:get(<<"user-agent">>, Headers, <<>>),
    case detect_claude_cli(UA) of
        {ok, Version} ->
            {claude_code, Version};
        nomatch ->
            case detect_metadata(Body) of
                {ok, claude_code} ->
                    {claude_code, <<"unknown">>};
                nomatch ->
                    check_official_client(Headers)
            end
    end.

%% Enforce claude_code_only restriction on a group.
-spec enforce_client_restriction(map(), term()) -> ok | {error, codex_cli_only}.

enforce_client_restriction(#{claude_code_only := false}, _ClientType) ->
    ok;
enforce_client_restriction(#{claude_code_only := CCO}, _ClientType) when CCO =:= false; CCO =:= undefined ->
    ok;
enforce_client_restriction(#{claude_code_only := true}, {claude_code, _}) ->
    ok;
enforce_client_restriction(#{claude_code_only := true}, {official, _}) ->
    ok;
enforce_client_restriction(#{claude_code_only := true}, _) ->
    {error, codex_cli_only};
enforce_client_restriction(_, _) ->
    ok.

%%% Internal

%% Detect "claude-cli/X.Y.Z" in User-Agent (case-insensitive)
detect_claude_cli(UA) when is_binary(UA) ->
    case re:run(UA, <<"(?i)claude-cli/([0-9]+\\.[0-9]+\\.[0-9]+)">>,
                [{capture, [1], binary}]) of
        {match, [Version]} -> {ok, Version};
        nomatch -> nomatch
    end;
detect_claude_cli(_) ->
    nomatch.

%% Detect claude-code originator in request body metadata
detect_metadata(Body) when is_map(Body) ->
    case maps:get(<<"metadata">>, Body, undefined) of
        #{<<"originator">> := <<"claude-code">>} -> {ok, claude_code};
        _ -> nomatch
    end;
detect_metadata(_) ->
    nomatch.

%% Check for OpenAI official client patterns
check_official_client(Headers) ->
    UA = maps:get(<<"user-agent">>, Headers, <<>>),
    Originator = maps:get(<<"originator">>, Headers, <<>>),
    OfficialUAs = [<<"OpenAI/">>, <<"openai-python/">>, <<"openai-node/">>],
    case lists:any(fun(Prefix) ->
        case UA of
            <<Prefix:(byte_size(Prefix))/binary, _/binary>> -> true;
            _ -> false
        end
    end, OfficialUAs) of
        true -> {official, user_agent};
        false ->
            case Originator of
                <<"openai">> -> {official, originator};
                _ -> unknown
            end
    end.
