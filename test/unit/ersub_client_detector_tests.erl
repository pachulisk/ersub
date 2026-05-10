-module(ersub_client_detector_tests).
-include_lib("eunit/include/eunit.hrl").

detect_claude_cli_test_() ->
    [
        {"standard UA", fun() ->
            ?assertMatch({claude_code, <<"1.2.3">>},
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"claude-cli/1.2.3">>}, #{}))
        end},
        {"case insensitive", fun() ->
            ?assertMatch({claude_code, <<"4.5.6">>},
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"Claude-CLI/4.5.6 extra">>}, #{}))
        end},
        {"with suffix", fun() ->
            ?assertMatch({claude_code, <<"10.0.1">>},
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"Mozilla/5.0 claude-cli/10.0.1">>}, #{}))
        end}
    ].

detect_metadata_test_() ->
    [
        {"originator in body", fun() ->
            ?assertMatch({claude_code, <<"unknown">>},
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"curl/7">>},
                    #{<<"metadata">> => #{<<"originator">> => <<"claude-code">>}}))
        end},
        {"no originator", fun() ->
            ?assertEqual(unknown,
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"curl/7">>},
                    #{<<"metadata">> => #{<<"other">> => <<"value">>}}))
        end}
    ].

detect_official_client_test_() ->
    [
        {"OpenAI SDK UA", fun() ->
            ?assertMatch({official, user_agent},
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"OpenAI/1.0">>}, #{}))
        end},
        {"openai-python UA", fun() ->
            ?assertMatch({official, user_agent},
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"openai-python/1.5.0">>}, #{}))
        end},
        {"unknown client", fun() ->
            ?assertEqual(unknown,
                ersub_client_detector:detect_client(
                    #{<<"user-agent">> => <<"curl/7.88">>}, #{}))
        end}
    ].

enforce_restriction_test_() ->
    [
        {"claude_code_only=true, claude_code client", fun() ->
            ?assertEqual(ok,
                ersub_client_detector:enforce_client_restriction(
                    #{claude_code_only => true}, {claude_code, <<"1.0">>}))
        end},
        {"claude_code_only=true, unknown client", fun() ->
            ?assertEqual({error, codex_cli_only},
                ersub_client_detector:enforce_client_restriction(
                    #{claude_code_only => true}, unknown))
        end},
        {"claude_code_only=false, any client", fun() ->
            ?assertEqual(ok,
                ersub_client_detector:enforce_client_restriction(
                    #{claude_code_only => false}, unknown))
        end},
        {"claude_code_only=true, official client allowed", fun() ->
            ?assertEqual(ok,
                ersub_client_detector:enforce_client_restriction(
                    #{claude_code_only => true}, {official, user_agent}))
        end}
    ].
