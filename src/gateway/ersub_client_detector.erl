-module(ersub_client_detector).

-export([detect_client/2, enforce_client_restriction/2,
         is_codex_cli/1, check_codex_enforcement/2, detect_warmup/1]).

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

%% F15/T4-18: Enhanced CodexCLI detection.
%% Accepts a User-Agent binary and returns true if it contains "codex" or "Codex"
%% (case-insensitive check), or matches known CLI patterns.
-spec is_codex_cli(binary()) -> boolean().
is_codex_cli(UA) when is_binary(UA) ->
    case re:run(UA, <<"(?i)codex">>) of
        {match, _} -> true;
        nomatch -> false
    end;
is_codex_cli(_) ->
    false.

%% T4-18: Check CodexCLI enforcement for a group.
%% If force_codex_cli is true in GroupConfig, the request must come from a CodexCLI client.
-spec check_codex_enforcement(cowboy_req:req(), map()) -> ok | {error, codex_cli_required}.
check_codex_enforcement(Req, GroupConfig) ->
    case maps:get(<<"force_codex_cli">>, GroupConfig, false) of
        true ->
            UA = cowboy_req:header(<<"user-agent">>, Req, <<>>),
            case is_codex_cli(UA) of
                true -> ok;
                false -> {error, codex_cli_required}
            end;
        _ ->
            ok
    end.

%% F20: Detect warmup/ping requests
-spec detect_warmup(binary()) -> boolean().
detect_warmup(Body) when is_binary(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        Messages = maps:get(<<"messages">>, Json, []),
        case Messages of
            [#{<<"content">> := Content} | _] when is_binary(Content) ->
                binary:match(Content, <<"Warmup">>) =/= nomatch orelse
                binary:match(Content, <<"warmup">>) =/= nomatch;
            _ -> false
        end
    catch _:_ -> false
    end;
detect_warmup(_) -> false.
