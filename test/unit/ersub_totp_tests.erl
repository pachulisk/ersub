-module(ersub_totp_tests).
-include_lib("eunit/include/eunit.hrl").

generate_secret_test() ->
    Secret = ersub_totp:generate_secret(),
    ?assert(is_binary(Secret)),
    ?assert(byte_size(Secret) > 0).

generate_uri_test() ->
    Secret = ersub_totp:generate_secret(),
    Uri = ersub_totp:generate_uri(<<"test@example.com">>, Secret),
    ?assertMatch(<<"otpauth://totp/ErSub:", _/binary>>, Uri),
    ?assert(binary:match(Uri, Secret) =/= nomatch),
    ?assert(binary:match(Uri, <<"test@example.com">>) =/= nomatch).

secrets_are_unique_test() ->
    S1 = ersub_totp:generate_secret(),
    S2 = ersub_totp:generate_secret(),
    ?assertNotEqual(S1, S2).
