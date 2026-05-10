-module(ersub_test_fixtures).

-export([must_create_user/1, must_create_account/1, must_create_group/1,
         must_create_api_key/1, must_bind_account_to_group/2]).

%% Create a user or fail the test.
must_create_user(Overrides) ->
    Defaults = #{
        email => unique_email(),
        password_hash => <<"$test$hash">>,
        role => <<"user">>,
        balance_usd => 100.0,
        max_concurrency => 5
    },
    Attrs = maps:merge(Defaults, Overrides),
    case ersub_repo:create_user(Attrs) of
        {ok, User} -> User;
        {error, Reason} -> error({create_user_failed, Reason})
    end.

%% Create an account or fail.
must_create_account(Overrides) ->
    Defaults = #{
        name => unique_name(<<"account">>),
        platform => <<"claude">>,
        account_type => <<"api_key">>,
        credentials => #{<<"api_key">> => <<"sk-test">>},
        priority => 100,
        concurrency => 5
    },
    Attrs = maps:merge(Defaults, Overrides),
    case ersub_repo:create_account(Attrs) of
        {ok, Account} -> Account;
        {error, Reason} -> error({create_account_failed, Reason})
    end.

%% Create a group or fail.
must_create_group(Overrides) ->
    Defaults = #{
        name => unique_name(<<"group">>),
        platform => <<"claude">>,
        rate_multiplier => 1.0
    },
    Attrs = maps:merge(Defaults, Overrides),
    case ersub_repo:create_group(Attrs) of
        {ok, Group} -> Group;
        {error, Reason} -> error({create_group_failed, Reason})
    end.

%% Create an API key or fail.
must_create_api_key(Overrides) ->
    RawKey = <<"sk-test-", (binary:encode_hex(crypto:strong_rand_bytes(16)))/binary>>,
    Defaults = #{
        key_hash => ersub_auth_middleware:hash_api_key(RawKey),
        key_prefix => binary:part(RawKey, 0, 12),
        name => <<"test-key">>
    },
    Attrs = maps:merge(Defaults, Overrides),
    case ersub_repo:create_api_key(Attrs) of
        {ok, Key} -> Key#{raw_key => RawKey};
        {error, Reason} -> error({create_api_key_failed, Reason})
    end.

%% Bind account to group or fail.
must_bind_account_to_group(AccountId, GroupId) ->
    case ersub_repo:bind_account_to_group(AccountId, GroupId) of
        ok -> ok;
        {error, Reason} -> error({bind_failed, Reason})
    end.

%%% Internal

unique_email() ->
    N = erlang:unique_integer([positive]),
    iolist_to_binary([<<"test-">>, integer_to_binary(N), <<"@ersub.test">>]).

unique_name(Prefix) ->
    N = erlang:unique_integer([positive]),
    iolist_to_binary([Prefix, <<"-">>, integer_to_binary(N)]).
