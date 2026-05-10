-module(ersub_error_passthrough_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test error passthrough rule matching logic

match_status_code_test() ->
    Rule = #{status_codes => [429, 503], keywords => [], platform => any},
    ?assert(matches_rule(429, <<"openai">>, <<>>, Rule)),
    ?assert(matches_rule(503, <<"claude">>, <<>>, Rule)),
    ?assertNot(matches_rule(500, <<"claude">>, <<>>, Rule)).

match_platform_test() ->
    Rule = #{status_codes => [429], keywords => [], platform => <<"openai">>},
    ?assert(matches_rule(429, <<"openai">>, <<>>, Rule)),
    ?assertNot(matches_rule(429, <<"claude">>, <<>>, Rule)).

match_any_platform_test() ->
    Rule = #{status_codes => [429], keywords => [], platform => any},
    ?assert(matches_rule(429, <<"openai">>, <<>>, Rule)),
    ?assert(matches_rule(429, <<"claude">>, <<>>, Rule)).

match_keyword_test() ->
    Rule = #{status_codes => [429], keywords => [<<"rate_limit">>], platform => any},
    ?assert(matches_rule(429, <<"openai">>, <<"rate_limit exceeded">>, Rule)),
    ?assertNot(matches_rule(429, <<"openai">>, <<"server error">>, Rule)).

body_truncation_test() ->
    %% Body should be checked only up to 8KB
    LargeBody = binary:copy(<<"x">>, 16384),
    Rule = #{status_codes => [500], keywords => [<<"needle">>], platform => any},
    %% needle at position > 8KB should not match
    ?assertNot(matches_rule(500, <<"any">>, LargeBody, Rule)).

%%% Internal helper
matches_rule(StatusCode, Platform, Body, Rule) ->
    #{status_codes := Codes, keywords := Keywords, platform := RulePlatform} = Rule,
    CodeMatch = lists:member(StatusCode, Codes),
    PlatformMatch = (RulePlatform =:= any) orelse (RulePlatform =:= Platform),
    KeywordMatch = case Keywords of
        [] -> true;
        _ ->
            CheckBody = binary:part(Body, 0, min(byte_size(Body), 8192)),
            LowerBody = string:lowercase(CheckBody),
            lists:any(fun(KW) ->
                binary:match(LowerBody, string:lowercase(KW)) =/= nomatch
            end, Keywords)
    end,
    CodeMatch andalso PlatformMatch andalso KeywordMatch.
