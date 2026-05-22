-module(ersub_easypay_tests).

-include_lib("eunit/include/eunit.hrl").

%%% verify_callback tests

verify_callback_no_pkey_test() ->
    meck:new(ersub_config_srv, [passthrough]),
    try
        meck:expect(ersub_config_srv, get, fun(payment_easypay_pkey, _) -> <<>> end),
        Result = ersub_easypay:verify_callback(#{}),
        ?assertEqual({error, no_pkey}, Result)
    after
        meck:unload(ersub_config_srv)
    end.

verify_callback_invalid_sign_test() ->
    meck:new(ersub_config_srv, [passthrough]),
    try
        meck:expect(ersub_config_srv, get, fun(payment_easypay_pkey, _) -> <<"secret">> end),
        Params = #{
            <<"pid">>          => <<"1">>,
            <<"out_trade_no">> => <<"100">>,
            <<"sign">>         => <<"badhash">>,
            <<"sign_type">>    => <<"MD5">>
        },
        Result = ersub_easypay:verify_callback(Params),
        ?assertEqual({error, invalid_signature}, Result)
    after
        meck:unload(ersub_config_srv)
    end.

verify_callback_valid_sign_test() ->
    PKey   = <<"mysecret">>,
    KVStr  = <<"out_trade_no=100&pid=1&trade_status=TRADE_SUCCESS">>,
    Sign   = binary:encode_hex(crypto:hash(md5, <<KVStr/binary, PKey/binary>>), lowercase),
    Params = #{
        <<"pid">>          => <<"1">>,
        <<"out_trade_no">> => <<"100">>,
        <<"trade_status">> => <<"TRADE_SUCCESS">>,
        <<"sign">>         => Sign,
        <<"sign_type">>    => <<"MD5">>
    },
    meck:new(ersub_config_srv, [passthrough]),
    try
        meck:expect(ersub_config_srv, get, fun(payment_easypay_pkey, _) -> PKey end),
        Result = ersub_easypay:verify_callback(Params),
        ?assertMatch({ok, _}, Result)
    after
        meck:unload(ersub_config_srv)
    end.

verify_callback_empty_values_excluded_test() ->
    %% Empty values must be excluded from the sign string
    PKey   = <<"k">>,
    KVStr  = <<"name=test&pid=1">>,
    Sign   = binary:encode_hex(crypto:hash(md5, <<KVStr/binary, PKey/binary>>), lowercase),
    Params = #{
        <<"pid">>       => <<"1">>,
        <<"param">>     => <<>>,
        <<"name">>      => <<"test">>,
        <<"sign">>      => Sign,
        <<"sign_type">> => <<"MD5">>
    },
    meck:new(ersub_config_srv, [passthrough]),
    try
        meck:expect(ersub_config_srv, get, fun(payment_easypay_pkey, _) -> PKey end),
        Result = ersub_easypay:verify_callback(Params),
        ?assertMatch({ok, _}, Result)
    after
        meck:unload(ersub_config_srv)
    end.

%%% is_available tests

is_available_clips_disabled_test() ->
    meck:new(ersub_clips_pool, [passthrough]),
    try
        meck:expect(ersub_clips_pool, get_easypay_config,
                    fun() -> {ok, #{<<"enabled">> => <<"FALSE">>}} end),
        ?assertEqual(false, ersub_easypay:is_available())
    after
        meck:unload(ersub_clips_pool)
    end.

is_available_missing_pid_test() ->
    meck:new(ersub_clips_pool, [passthrough]),
    meck:new(ersub_config_srv, [passthrough]),
    try
        meck:expect(ersub_clips_pool, get_easypay_config,
                    fun() -> {ok, #{<<"enabled">> => <<"TRUE">>}} end),
        meck:expect(ersub_config_srv, get,
                    fun(payment_easypay_pid,  _) -> <<>>;
                       (payment_easypay_pkey, _) -> <<"key">>;
                       (K, D) -> meck:passthrough([K, D])
                    end),
        ?assertEqual(false, ersub_easypay:is_available())
    after
        meck:unload(ersub_clips_pool),
        meck:unload(ersub_config_srv)
    end.

is_available_missing_pkey_test() ->
    meck:new(ersub_clips_pool, [passthrough]),
    meck:new(ersub_config_srv, [passthrough]),
    try
        meck:expect(ersub_clips_pool, get_easypay_config,
                    fun() -> {ok, #{<<"enabled">> => <<"TRUE">>}} end),
        meck:expect(ersub_config_srv, get,
                    fun(payment_easypay_pid,  _) -> <<"pid1">>;
                       (payment_easypay_pkey, _) -> <<>>;
                       (K, D) -> meck:passthrough([K, D])
                    end),
        ?assertEqual(false, ersub_easypay:is_available())
    after
        meck:unload(ersub_clips_pool),
        meck:unload(ersub_config_srv)
    end.

is_available_all_ok_test() ->
    meck:new(ersub_clips_pool, [passthrough]),
    meck:new(ersub_config_srv, [passthrough]),
    try
        meck:expect(ersub_clips_pool, get_easypay_config,
                    fun() -> {ok, #{<<"enabled">> => <<"TRUE">>}} end),
        meck:expect(ersub_config_srv, get,
                    fun(payment_easypay_pid,  _) -> <<"pid1">>;
                       (payment_easypay_pkey, _) -> <<"key1">>;
                       (K, D) -> meck:passthrough([K, D])
                    end),
        ?assertEqual(true, ersub_easypay:is_available())
    after
        meck:unload(ersub_clips_pool),
        meck:unload(ersub_config_srv)
    end.
