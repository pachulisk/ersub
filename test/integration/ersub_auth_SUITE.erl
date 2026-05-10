-module(ersub_auth_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([jwt_roundtrip_test/1, password_verify_test/1]).

all() -> [jwt_roundtrip_test, password_verify_test].

init_per_suite(Config) ->
    os:putenv("DB_USER", os:getenv("DB_USER", "shikun")),
    try ersub_test_helpers:start_app() of
        ok -> Config
    catch _:Reason ->
        {skip, {app_start_failed, Reason}}
    end.

end_per_suite(_Config) -> ok.

jwt_roundtrip_test(_Config) ->
    {ok, Token} = ersub_auth_srv:generate_jwt(#{<<"user_id">> => 1, <<"role">> => <<"admin">>}),
    {ok, Claims} = ersub_auth_srv:verify_jwt(Token),
    ?assertEqual(1, maps:get(<<"user_id">>, Claims)).

password_verify_test(_Config) ->
    Hash = ersub_auth_srv:hash_password(<<"testpass">>),
    ?assert(ersub_auth_srv:verify_password(<<"testpass">>, Hash)),
    ?assertNot(ersub_auth_srv:verify_password(<<"wrong">>, Hash)).
