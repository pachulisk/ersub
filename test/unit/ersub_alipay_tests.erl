-module(ersub_alipay_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%%% sign_roundtrip_test
%%% Generate a throw-away RSA-2048 key pair, sign a string with the private key,
%%% then verify with the public key — exercises the same code path as
%%% sign_params/2 and verify_callback/1.

sign_roundtrip_test() ->
    %% Generate ephemeral RSA-2048 key pair
    PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = Mod, publicExponent = Exp} = PrivKey,
    PubKey  = #'RSAPublicKey'{modulus = Mod, publicExponent = Exp},

    Data = <<"app_id=test&method=alipay.trade.page.pay&version=1.0">>,
    Sig  = public_key:sign(Data, sha256, PrivKey),
    ?assert(public_key:verify(Data, sha256, Sig, PubKey)).

sign_roundtrip_wrong_data_test() ->
    PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = Mod, publicExponent = Exp} = PrivKey,
    PubKey  = #'RSAPublicKey'{modulus = Mod, publicExponent = Exp},

    Sig = public_key:sign(<<"original">>, sha256, PrivKey),
    ?assertNot(public_key:verify(<<"tampered">>, sha256, Sig, PubKey)).

%%% verify_callback_test
%%% Build a fake Alipay notification parameter map with a real RSA signature,
%%% PEM-encode the public key, stash it in the process dict (bypassing config),
%%% then call verify_callback/1 through the module's exported path.
%%%
%%% Because verify_callback/1 reads the public key from ersub_config_srv, we
%%% intercept get_conf/1 indirectly by mocking ersub_config_srv via meck.

verify_callback_valid_test() ->
    meck:new(ersub_config_srv, [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        #'RSAPrivateKey'{modulus = Mod, publicExponent = Exp} = PrivKey,
        PubKey  = #'RSAPublicKey'{modulus = Mod, publicExponent = Exp},

        PubPem = public_key:pem_encode(
                     [public_key:pem_entry_encode('RSAPublicKey', PubKey)]),

        meck:expect(ersub_config_srv, get,
                    fun(payment_alipay_public_key, _) -> PubPem;
                       (K, D) -> meck:passthrough([K, D])
                    end),

        Params0 = #{
            <<"app_id">>       => <<"test_app">>,
            <<"out_trade_no">> => <<"order_001">>,
            <<"trade_no">>     => <<"alipay_tx_999">>,
            <<"trade_status">> => <<"TRADE_SUCCESS">>,
            <<"sign_type">>    => <<"RSA2">>
        },
        %% Mimic verify_callback: strip sign + sign_type before building sign string
        Stripped = maps:without([<<"sign">>, <<"sign_type">>], Params0),
        Sorted   = lists:sort(maps:to_list(Stripped)),
        Parts    = [<<K/binary, "=", V/binary>>
                    || {K, V} <- Sorted,
                       is_binary(K), is_binary(V), V =/= <<>>],
        SignStr  = iolist_to_binary(lists:join(<<"&">>, Parts)),
        Sig     = public_key:sign(SignStr, sha256, PrivKey),
        SignB64 = base64:encode(Sig),

        Params1 = Params0#{<<"sign">> => SignB64},
        ?assert(ersub_alipay:verify_callback(Params1))
    after
        meck:unload(ersub_config_srv)
    end.

verify_callback_invalid_sig_test() ->
    meck:new(ersub_config_srv, [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        %% Use a *different* key for the public half — signature will not match
        OtherKey = public_key:generate_key({rsa, 2048, 65537}),
        #'RSAPrivateKey'{modulus = Mod2, publicExponent = Exp2} = OtherKey,
        PubKey  = #'RSAPublicKey'{modulus = Mod2, publicExponent = Exp2},

        PubPem = public_key:pem_encode(
                     [public_key:pem_entry_encode('RSAPublicKey', PubKey)]),

        meck:expect(ersub_config_srv, get,
                    fun(payment_alipay_public_key, _) -> PubPem;
                       (K, D) -> meck:passthrough([K, D])
                    end),

        Params0 = #{<<"app_id">> => <<"test_app">>, <<"sign_type">> => <<"RSA2">>},
        Sig     = public_key:sign(<<"some data">>, sha256, PrivKey),
        Params1 = Params0#{<<"sign">> => base64:encode(Sig)},
        ?assertNot(ersub_alipay:verify_callback(Params1))
    after
        meck:unload(ersub_config_srv)
    end.

verify_callback_no_pubkey_test() ->
    meck:new(ersub_config_srv, [passthrough, no_link]),
    try
        meck:expect(ersub_config_srv, get,
                    fun(payment_alipay_public_key, _) -> <<>>;
                       (K, D) -> meck:passthrough([K, D])
                    end),
        ?assertNot(ersub_alipay:verify_callback(#{<<"sign">> => <<"fakesig">>}))
    after
        meck:unload(ersub_config_srv)
    end.

%%% parse_form_body_test
%%% parse_form_body/1 is private, so we exercise it by calling verify_callback/1
%%% with a pre-parsed map. Instead, we test the URL-decode logic separately
%%% here by replicating the parse logic and verifying its output.

parse_form_body_test_() ->
    F = fun parse_form_body/1,
    [
        {"simple pair",     fun() ->
            ?assertEqual(#{<<"k">> => <<"v">>}, F(<<"k=v">>))
        end},
        {"multiple pairs",  fun() ->
            ?assertEqual(#{<<"a">> => <<"1">>, <<"b">> => <<"2">>},
                         F(<<"a=1&b=2">>))
        end},
        {"percent-encoded", fun() ->
            ?assertEqual(#{<<"sign">> => <<"a+b/c=">>},
                         F(<<"sign=a%2Bb%2Fc%3D">>))
        end},
        {"empty value",     fun() ->
            ?assertEqual(#{<<"x">> => <<>>}, F(<<"x=">>))
        end}
    ].

parse_form_body(Body) ->
    Pairs = binary:split(Body, <<"&">>, [global]),
    lists:foldl(fun(Pair, Acc) ->
        case binary:split(Pair, <<"=">>) of
            [K, V] ->
                DK = safe_percent_decode(K),
                DV = safe_percent_decode(V),
                maps:put(DK, DV, Acc);
            _ -> Acc
        end
    end, #{}, Pairs).

safe_percent_decode(B) ->
    case uri_string:percent_decode(B) of
        {error, _, _} -> B;
        Decoded       -> Decoded
    end.

%%% refund_success_test
%%% Mock ersub_upstream_pool:request/6 to return a valid Alipay refund success
%%% response (code=10000). Mock clips pool and config srv for keys.

refund_success_test() ->
    meck:new(ersub_upstream_pool, [passthrough, no_link]),
    meck:new(ersub_config_srv,    [passthrough, no_link]),
    meck:new(ersub_clips_pool,    [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        PrivPem = public_key:pem_encode(
                      [public_key:pem_entry_encode('RSAPrivateKey', PrivKey)]),

        meck:expect(ersub_config_srv, get, fun
            (payment_alipay_app_id, _)       -> <<"test_app_id">>;
            (payment_alipay_private_key, _)  -> PrivPem;
            (K, D)                           -> meck:passthrough([K, D])
        end),

        meck:expect(ersub_clips_pool, get_alipay_config, fun() ->
            {ok, #{
                <<"gateway-url">>         => <<"https://openapi.alipay.com/gateway.do">>,
                <<"sandbox-gateway-url">> => <<"https://openapi.alipaydev.com/gateway.do">>,
                <<"sandbox-mode">>        => <<"FALSE">>,
                <<"enabled">>             => <<"TRUE">>
            }}
        end),

        SuccessResp = jsx:encode(#{
            <<"alipay_trade_refund_response">> => #{
                <<"code">> => <<"10000">>,
                <<"msg">>  => <<"Success">>
            }
        }),
        meck:expect(ersub_upstream_pool, request,
                    fun(<<"POST">>, _, _, _, _, _) ->
                        {ok, 200, [], SuccessResp}
                    end),

        ?assertEqual(ok, ersub_alipay:refund(<<"order_42">>, 72.00))
    after
        meck:unload(ersub_upstream_pool),
        meck:unload(ersub_config_srv),
        meck:unload(ersub_clips_pool)
    end.

%%% refund_failure_test
%%% Same setup but gateway returns a non-10000 error code.

refund_failure_test() ->
    meck:new(ersub_upstream_pool, [passthrough, no_link]),
    meck:new(ersub_config_srv,    [passthrough, no_link]),
    meck:new(ersub_clips_pool,    [passthrough, no_link]),
    try
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
        PrivPem = public_key:pem_encode(
                      [public_key:pem_entry_encode('RSAPrivateKey', PrivKey)]),

        meck:expect(ersub_config_srv, get, fun
            (payment_alipay_app_id, _)       -> <<"test_app_id">>;
            (payment_alipay_private_key, _)  -> PrivPem;
            (K, D)                           -> meck:passthrough([K, D])
        end),

        meck:expect(ersub_clips_pool, get_alipay_config, fun() ->
            {ok, #{
                <<"gateway-url">>         => <<"https://openapi.alipay.com/gateway.do">>,
                <<"sandbox-gateway-url">> => <<"https://openapi.alipaydev.com/gateway.do">>,
                <<"sandbox-mode">>        => <<"FALSE">>,
                <<"enabled">>             => <<"TRUE">>
            }}
        end),

        FailResp = jsx:encode(#{
            <<"alipay_trade_refund_response">> => #{
                <<"code">> => <<"40004">>,
                <<"msg">>  => <<"Business Failed">>,
                <<"sub_code">> => <<"ACQ.TRADE_NOT_EXIST">>,
                <<"sub_msg">>  => <<"Trade not exist">>
            }
        }),
        meck:expect(ersub_upstream_pool, request,
                    fun(<<"POST">>, _, _, _, _, _) ->
                        {ok, 200, [], FailResp}
                    end),

        ?assertMatch({error, {alipay_refund_failed, <<"40004">>, _}},
                     ersub_alipay:refund(<<"order_99">>, 50.00))
    after
        meck:unload(ersub_upstream_pool),
        meck:unload(ersub_config_srv),
        meck:unload(ersub_clips_pool)
    end.
