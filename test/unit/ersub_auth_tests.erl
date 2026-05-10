-module(ersub_auth_tests).
-include_lib("eunit/include/eunit.hrl").

password_hash_test() ->
    Hash = ersub_auth_srv:hash_password(<<"testpassword">>),
    ?assertMatch(<<"sha256:", _/binary>>, Hash),
    ?assert(ersub_auth_srv:verify_password(<<"testpassword">>, Hash)),
    ?assertNot(ersub_auth_srv:verify_password(<<"wrongpassword">>, Hash)).

password_hash_unique_test() ->
    H1 = ersub_auth_srv:hash_password(<<"same">>),
    H2 = ersub_auth_srv:hash_password(<<"same">>),
    %% Different salts produce different hashes
    ?assertNotEqual(H1, H2),
    %% But both verify correctly
    ?assert(ersub_auth_srv:verify_password(<<"same">>, H1)),
    ?assert(ersub_auth_srv:verify_password(<<"same">>, H2)).

jwt_roundtrip_test_() ->
    {setup,
     fun() ->
         application:ensure_all_started(jose),
         application:ensure_all_started(yamerl),
         case whereis(ersub_config_srv) of
             undefined ->
                 application:ensure_all_started(yamerl),
                 ersub_config_srv:start_link("config/ersub.yaml");
             _ -> ok
         end
     end,
     fun(_) -> ok end,
     [
         {"generate and verify", fun() ->
             {ok, Token} = ersub_auth_srv:generate_jwt(#{<<"user_id">> => 42, <<"role">> => <<"admin">>}),
             ?assert(is_binary(Token)),
             {ok, Claims} = ersub_auth_srv:verify_jwt(Token),
             ?assertEqual(42, maps:get(<<"user_id">>, Claims)),
             ?assertEqual(<<"admin">>, maps:get(<<"role">>, Claims))
         end},
         {"invalid token rejected", fun() ->
             Result = ersub_auth_srv:verify_jwt(<<"invalid.token.here">>),
             ?assertMatch({error, _}, Result)
         end}
     ]}.

api_key_hash_test() ->
    Key = <<"sk-test-1234567890">>,
    Hash = ersub_auth_middleware:hash_api_key(Key),
    ?assert(is_binary(Hash)),
    ?assertEqual(64, byte_size(Hash)), %% SHA-256 = 32 bytes = 64 hex chars
    %% Same key produces same hash
    ?assertEqual(Hash, ersub_auth_middleware:hash_api_key(Key)),
    %% Different key produces different hash
    ?assertNotEqual(Hash, ersub_auth_middleware:hash_api_key(<<"sk-other">>)).
