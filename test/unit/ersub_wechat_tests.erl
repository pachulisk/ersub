-module(ersub_wechat_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%%% sign_roundtrip_test
%%% RSA-SHA256 sign then verify with the same key pair — exercises
%%% the same code path used by build_authorization and verify_callback.

sign_roundtrip_test() ->
    PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = Mod, publicExponent = Exp} = PrivKey,
    PubKey  = #'RSAPublicKey'{modulus = Mod, publicExponent = Exp},

    Data = <<"POST\n/v3/pay/transactions/native\n1234567890\nABCDEF\nbody\n">>,
    Sig  = public_key:sign(Data, sha256, PrivKey),
    ?assert(public_key:verify(Data, sha256, Sig, PubKey)).

sign_roundtrip_wrong_data_test() ->
    PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = Mod, publicExponent = Exp} = PrivKey,
    PubKey  = #'RSAPublicKey'{modulus = Mod, publicExponent = Exp},

    Sig = public_key:sign(<<"original">>, sha256, PrivKey),
    ?assertNot(public_key:verify(<<"tampered">>, sha256, Sig, PubKey)).

%%% verify_callback_valid_test
%%% Full end-to-end: RSA signature verification + AES-256-GCM decryption.

verify_callback_valid_test() ->
    meck:new(ersub_config_srv, [passthrough, no_link]),
    try
        %% Generate ephemeral RSA key pair for platform key
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        #'RSAPrivateKey'{modulus = Mod, publicExponent = Exp} = PrivKey,
        PubKey  = #'RSAPublicKey'{modulus = Mod, publicExponent = Exp},

        PubPem = public_key:pem_encode(
                     [public_key:pem_entry_encode('RSAPublicKey', PubKey)]),

        %% 32-byte api_v3_key
        ApiV3Key = crypto:strong_rand_bytes(32),

        %% Plaintext payload (what WeChat would encrypt)
        PlainText = jsx:encode(#{
            <<"transaction_id">> => <<"wx_test_tx_001">>,
            <<"out_trade_no">>   => <<"42">>,
            <<"trade_state">>    => <<"SUCCESS">>
        }),

        %% Encrypt with AES-256-GCM (12-byte nonce, matching WeChat spec)
        Nonce12 = <<"wechatnonce1">>,     %% exactly 12 bytes
        AAD     = <<"transaction">>,
        {CipherText, Tag} = crypto:crypto_one_time_aead(
            aes_256_gcm, ApiV3Key, Nonce12, PlainText, AAD, true),
        CipherB64 = base64:encode(<<CipherText/binary, Tag/binary>>),

        %% Build the resource wrapper WeChat sends
        Resource = #{
            <<"algorithm">>       => <<"AEAD_AES_256_GCM">>,
            <<"ciphertext">>      => CipherB64,
            <<"nonce">>           => Nonce12,
            <<"associated_data">> => AAD
        },
        Body = jsx:encode(#{<<"resource">> => Resource}),

        %% Build WeChat callback signature headers
        Timestamp = <<"1700000000">>,
        Nonce32   = <<"abcdef1234567890abcdef1234567890">>,
        SignStr   = <<Timestamp/binary, "\n", Nonce32/binary, "\n", Body/binary, "\n">>,
        Sig       = public_key:sign(SignStr, sha256, PrivKey),
        SigB64    = base64:encode(Sig),

        Headers = [
            {<<"wechatpay-timestamp">>, Timestamp},
            {<<"wechatpay-nonce">>,     Nonce32},
            {<<"wechatpay-signature">>, SigB64}
        ],

        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_platform_public_key, _) -> PubPem;
            (payment_wechat_api_v3_key, _)          -> ApiV3Key;
            (K, D)                                  -> meck:passthrough([K, D])
        end),

        Result = ersub_wechat:verify_callback(Headers, Body),
        ?assertMatch({ok, #{<<"trade_state">> := <<"SUCCESS">>}}, Result)
    after
        meck:unload(ersub_config_srv)
    end.

%%% verify_callback_invalid_sig_test

verify_callback_invalid_sig_test() ->
    meck:new(ersub_config_srv, [passthrough, no_link]),
    try
        PrivKey   = public_key:generate_key({rsa, 2048, 65537}),
        OtherKey  = public_key:generate_key({rsa, 2048, 65537}),
        #'RSAPrivateKey'{modulus = M2, publicExponent = E2} = OtherKey,
        PubKey    = #'RSAPublicKey'{modulus = M2, publicExponent = E2},
        PubPem    = public_key:pem_encode(
                        [public_key:pem_entry_encode('RSAPublicKey', PubKey)]),

        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_platform_public_key, _) -> PubPem;
            (K, D)                                  -> meck:passthrough([K, D])
        end),

        Body   = <<"{}">>,
        Sig    = public_key:sign(<<"data">>, sha256, PrivKey),
        SigB64 = base64:encode(Sig),
        Headers = [
            {<<"wechatpay-timestamp">>, <<"1700000000">>},
            {<<"wechatpay-nonce">>,     <<"nonce">>},
            {<<"wechatpay-signature">>, SigB64}
        ],
        ?assertEqual({error, invalid_signature},
                     ersub_wechat:verify_callback(Headers, Body))
    after
        meck:unload(ersub_config_srv)
    end.

%%% verify_callback_no_platform_key_test

verify_callback_no_platform_key_test() ->
    meck:new(ersub_config_srv, [passthrough, no_link]),
    try
        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_platform_public_key, _) -> <<>>;
            (K, D)                                  -> meck:passthrough([K, D])
        end),
        Headers = [{<<"wechatpay-timestamp">>, <<"1">>},
                   {<<"wechatpay-nonce">>,     <<"n">>},
                   {<<"wechatpay-signature">>, <<"s">>}],
        ?assertEqual({error, no_platform_key},
                     ersub_wechat:verify_callback(Headers, <<"{}">>))
    after
        meck:unload(ersub_config_srv)
    end.

%%% decrypt_resource_test
%%% Encrypt known plaintext with a test key, verify decrypt_resource works.
%%% Tested via verify_callback with signature mocked away by using valid sig.

decrypt_resource_aes_test() ->
    ApiV3Key  = crypto:strong_rand_bytes(32),
    PlainText = jsx:encode(#{<<"status">> => <<"ok">>}),
    Nonce12   = <<"testnonce123">>,
    AAD       = <<"test">>,
    {CT, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, ApiV3Key, Nonce12, PlainText, AAD, true),
    CipherB64 = base64:encode(<<CT/binary, Tag/binary>>),
    Resource  = #{
        <<"algorithm">>       => <<"AEAD_AES_256_GCM">>,
        <<"ciphertext">>      => CipherB64,
        <<"nonce">>           => Nonce12,
        <<"associated_data">> => AAD
    },
    meck:new(ersub_config_srv, [passthrough, no_link]),
    try
        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_api_v3_key, _) -> ApiV3Key;
            (K, D)                         -> meck:passthrough([K, D])
        end),
        %% Call the internal decrypt path via a helper module call
        %% (decrypt_resource is private, so we use verify_callback with
        %%  a matching RSA key to reach the decrypt step)
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        #'RSAPrivateKey'{modulus = Mod, publicExponent = Exp} = PrivKey,
        PubKey  = #'RSAPublicKey'{modulus = Mod, publicExponent = Exp},
        PubPem  = public_key:pem_encode(
                      [public_key:pem_entry_encode('RSAPublicKey', PubKey)]),
        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_platform_public_key, _) -> PubPem;
            (payment_wechat_api_v3_key, _)          -> ApiV3Key;
            (K, D)                                  -> meck:passthrough([K, D])
        end),
        Body    = jsx:encode(#{<<"resource">> => Resource}),
        Ts      = <<"1700000001">>,
        Nonce32 = <<"00000000000000000000000000000000">>,
        SignStr = <<Ts/binary, "\n", Nonce32/binary, "\n", Body/binary, "\n">>,
        Sig     = public_key:sign(SignStr, sha256, PrivKey),
        Headers = [
            {<<"wechatpay-timestamp">>, Ts},
            {<<"wechatpay-nonce">>,     Nonce32},
            {<<"wechatpay-signature">>, base64:encode(Sig)}
        ],
        ?assertMatch({ok, #{<<"status">> := <<"ok">>}},
                     ersub_wechat:verify_callback(Headers, Body))
    after
        meck:unload(ersub_config_srv)
    end.

%%% create_native_order_success_test

create_native_order_success_test() ->
    meck:new(ersub_upstream_pool, [passthrough, no_link]),
    meck:new(ersub_config_srv,    [passthrough, no_link]),
    meck:new(ersub_clips_pool,    [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        PrivPem = public_key:pem_encode(
                      [public_key:pem_entry_encode('RSAPrivateKey', PrivKey)]),

        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_mch_id, _)                -> <<"mch_001">>;
            (payment_wechat_private_key, _)           -> PrivPem;
            (payment_wechat_certificate_serial_no, _) -> <<"SERIAL123">>;
            (payment_wechat_notify_url, _)            -> <<"https://example.com/notify">>;
            (K, D)                                    -> meck:passthrough([K, D])
        end),
        meck:expect(ersub_clips_pool, get_wechat_config, fun() ->
            {ok, #{<<"gateway-url">> => <<"https://api.mch.weixin.qq.com">>,
                   <<"enabled">>     => <<"TRUE">>}}
        end),

        RespBody = jsx:encode(#{<<"code_url">> => <<"weixin://wxpay/test">>}),
        meck:expect(ersub_upstream_pool, request,
                    fun(<<"POST">>, _, _, _, _, _) -> {ok, 200, [], RespBody} end),

        ?assertMatch({ok, #{code_url := <<"weixin://wxpay/test">>}},
                     ersub_wechat:create_native_order(<<"42">>, 7200,
                                                      <<"ErSub Balance Top-up">>))
    after
        meck:unload(ersub_upstream_pool),
        meck:unload(ersub_config_srv),
        meck:unload(ersub_clips_pool)
    end.

%%% create_native_order_error_test

create_native_order_error_test() ->
    meck:new(ersub_upstream_pool, [passthrough, no_link]),
    meck:new(ersub_config_srv,    [passthrough, no_link]),
    meck:new(ersub_clips_pool,    [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        PrivPem = public_key:pem_encode(
                      [public_key:pem_entry_encode('RSAPrivateKey', PrivKey)]),

        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_mch_id, _)                -> <<"mch_001">>;
            (payment_wechat_private_key, _)           -> PrivPem;
            (payment_wechat_certificate_serial_no, _) -> <<"SERIAL123">>;
            (payment_wechat_notify_url, _)            -> <<"https://example.com/notify">>;
            (K, D)                                    -> meck:passthrough([K, D])
        end),
        meck:expect(ersub_clips_pool, get_wechat_config, fun() ->
            {ok, #{<<"gateway-url">> => <<"https://api.mch.weixin.qq.com">>,
                   <<"enabled">>     => <<"TRUE">>}}
        end),
        meck:expect(ersub_upstream_pool, request,
                    fun(<<"POST">>, _, _, _, _, _) ->
                        {ok, 400, [], <<"error">>}
                    end),

        ?assertMatch({error, {wechat_http_error, 400, _}},
                     ersub_wechat:create_native_order(<<"99">>, 5000,
                                                      <<"Top-up">>))
    after
        meck:unload(ersub_upstream_pool),
        meck:unload(ersub_config_srv),
        meck:unload(ersub_clips_pool)
    end.

%%% refund_success_test

refund_success_test() ->
    meck:new(ersub_upstream_pool, [passthrough, no_link]),
    meck:new(ersub_config_srv,    [passthrough, no_link]),
    meck:new(ersub_clips_pool,    [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        PrivPem = public_key:pem_encode(
                      [public_key:pem_entry_encode('RSAPrivateKey', PrivKey)]),

        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_mch_id, _)                -> <<"mch_001">>;
            (payment_wechat_private_key, _)           -> PrivPem;
            (payment_wechat_certificate_serial_no, _) -> <<"SERIAL123">>;
            (K, D)                                    -> meck:passthrough([K, D])
        end),
        meck:expect(ersub_clips_pool, get_wechat_config, fun() ->
            {ok, #{<<"gateway-url">> => <<"https://api.mch.weixin.qq.com">>,
                   <<"enabled">>     => <<"TRUE">>}}
        end),

        SuccessResp = jsx:encode(#{<<"status">> => <<"SUCCESS">>,
                                   <<"refund_id">> => <<"ref_001">>}),
        meck:expect(ersub_upstream_pool, request,
                    fun(<<"POST">>, _, _, _, _, _) -> {ok, 200, [], SuccessResp} end),

        ?assertEqual(ok, ersub_wechat:refund(<<"42">>, 7200))
    after
        meck:unload(ersub_upstream_pool),
        meck:unload(ersub_config_srv),
        meck:unload(ersub_clips_pool)
    end.

%%% refund_failure_test

refund_failure_test() ->
    meck:new(ersub_upstream_pool, [passthrough, no_link]),
    meck:new(ersub_config_srv,    [passthrough, no_link]),
    meck:new(ersub_clips_pool,    [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        PrivPem = public_key:pem_encode(
                      [public_key:pem_entry_encode('RSAPrivateKey', PrivKey)]),

        meck:expect(ersub_config_srv, get, fun
            (payment_wechat_mch_id, _)                -> <<"mch_001">>;
            (payment_wechat_private_key, _)           -> PrivPem;
            (payment_wechat_certificate_serial_no, _) -> <<"SERIAL123">>;
            (K, D)                                    -> meck:passthrough([K, D])
        end),
        meck:expect(ersub_clips_pool, get_wechat_config, fun() ->
            {ok, #{<<"gateway-url">> => <<"https://api.mch.weixin.qq.com">>,
                   <<"enabled">>     => <<"TRUE">>}}
        end),

        FailResp = jsx:encode(#{<<"status">> => <<"ABNORMAL">>,
                                <<"message">> => <<"Order not exist">>}),
        meck:expect(ersub_upstream_pool, request,
                    fun(<<"POST">>, _, _, _, _, _) -> {ok, 200, [], FailResp} end),

        ?assertMatch({error, {wechat_refund_failed, <<"ABNORMAL">>, _}},
                     ersub_wechat:refund(<<"99">>, 5000))
    after
        meck:unload(ersub_upstream_pool),
        meck:unload(ersub_config_srv),
        meck:unload(ersub_clips_pool)
    end.
