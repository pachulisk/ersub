-module(ersub_wechat).

-export([is_available/0, create_native_order/3, verify_callback/2, refund/2]).
-export([create_order/3]).

-spec is_available() -> boolean().
is_available() ->
    try
        ClipsEnabled = case ersub_clips_pool:get_wechat_config() of
            {ok, #{<<"enabled">> := <<"TRUE">>}} -> true;
            _ -> false
        end,
        ClipsEnabled
            andalso get_conf(payment_wechat_mch_id) =/= <<>>
            andalso get_conf(payment_wechat_private_key) =/= <<>>
    catch C:E ->
        logger:debug("ersub_wechat:is_available/0 failed: ~p:~p", [C, E]),
        false
    end.

%% Create a WeChat Native Pay order. Returns the code_url to render as QR code.
-spec create_native_order(binary(), integer(), binary()) ->
    {ok, #{code_url := binary()}} | {error, term()}.
create_native_order(OrderId, AmountFen, Description) ->
    case ersub_clips_pool:get_wechat_config() of
        {ok, ClipsCfg} ->
            MchId      = get_conf(payment_wechat_mch_id),
            PrivKeyPem = get_conf(payment_wechat_private_key),
            SerialNo   = get_conf(payment_wechat_certificate_serial_no),
            NotifyUrl  = get_conf(payment_wechat_notify_url),
            GwUrl      = maps:get(<<"gateway-url">>, ClipsCfg,
                                  <<"https://api.mch.weixin.qq.com">>),
            UrlPath = <<"/v3/pay/transactions/native">>,
            Body = jsx:encode(#{
                <<"mchid">>        => MchId,
                <<"out_trade_no">> => OrderId,
                <<"description">>  => Description,
                <<"notify_url">>   => NotifyUrl,
                <<"amount">>       => #{<<"total">>    => AmountFen,
                                       <<"currency">> => <<"CNY">>}
            }),
            try
                Auth    = build_authorization(<<"POST">>, UrlPath, Body,
                                              MchId, PrivKeyPem, SerialNo),
                Headers = [{<<"content-type">>,  <<"application/json">>},
                           {<<"authorization">>, Auth},
                           {<<"accept">>,        <<"application/json">>}],
                FullUrl = <<GwUrl/binary, UrlPath/binary>>,
                case ersub_upstream_pool:request(
                        <<"POST">>, FullUrl, Headers, Body, #{}, 15000) of
                    {ok, 200, _, RespBody} ->
                        Decoded = jsx:decode(RespBody, [return_maps]),
                        case maps:get(<<"code_url">>, Decoded, undefined) of
                            undefined -> {error, {wechat_no_code_url, Decoded}};
                            CodeUrl   -> {ok, #{code_url => CodeUrl}}
                        end;
                    {ok, Status, _, RespBody} ->
                        {error, {wechat_http_error, Status, RespBody}};
                    {error, Reason} ->
                        {error, Reason}
                end
            catch C:E ->
                {error, {create_order_error, C, E}}
            end;
        {error, Reason} ->
            {error, {clips_error, Reason}}
    end.

%% Verify WeChat async callback signature and decrypt the resource payload.
%% Headers is a [{binary(), binary()}] proplist (from cowboy_req:headers/1 → maps:to_list/1).
-spec verify_callback([{binary(), binary()}], binary()) ->
    {ok, map()} | {error, term()}.
verify_callback(Headers, Body) ->
    Timestamp = proplists:get_value(<<"wechatpay-timestamp">>, Headers, <<>>),
    Nonce     = proplists:get_value(<<"wechatpay-nonce">>,     Headers, <<>>),
    SigB64    = proplists:get_value(<<"wechatpay-signature">>, Headers, <<>>),
    case {Timestamp, Nonce, SigB64} of
        {<<>>, _, _} -> {error, {missing_header, <<"wechatpay-timestamp">>}};
        {_, <<>>, _} -> {error, {missing_header, <<"wechatpay-nonce">>}};
        {_, _, <<>>} -> {error, {missing_header, <<"wechatpay-signature">>}};
        _ ->
            case is_timestamp_fresh(Timestamp, 300) of
                false -> {error, stale_timestamp};
                true  ->
                    PubKeyPem = get_conf(payment_wechat_platform_public_key),
                    case PubKeyPem of
                        <<>> -> {error, no_platform_key};
                        _ ->
                            SignStr = <<Timestamp/binary, "\n",
                                       Nonce/binary,     "\n",
                                       Body/binary,      "\n">>,
                            case verify_rsa(SignStr, SigB64, PubKeyPem) of
                                false -> {error, invalid_signature};
                                true  ->
                                    Decoded = jsx:decode(Body, [return_maps]),
                                    decrypt_resource(Decoded)
                            end
                    end
            end
    end.

%% Call WeChat Pay v3 refund API. AmountFen is in CNY fen (integer).
-spec refund(binary(), integer()) -> ok | {error, term()}.
refund(OutTradeNo, RefundAmountFen) ->
    case ersub_clips_pool:get_wechat_config() of
        {ok, ClipsCfg} ->
            MchId      = get_conf(payment_wechat_mch_id),
            PrivKeyPem = get_conf(payment_wechat_private_key),
            SerialNo   = get_conf(payment_wechat_certificate_serial_no),
            GwUrl      = maps:get(<<"gateway-url">>, ClipsCfg,
                                  <<"https://api.mch.weixin.qq.com">>),
            UrlPath  = <<"/v3/refund/domestic/refunds">>,
            %% Unique suffix per attempt — prevents "refund already exists" on retry.
            RefundNo = <<OutTradeNo/binary, "-r-",
                         (integer_to_binary(erlang:system_time(millisecond)))/binary>>,
            Body = jsx:encode(#{
                <<"out_trade_no">>  => OutTradeNo,
                <<"out_refund_no">> => RefundNo,
                <<"amount">>        => #{<<"refund">>   => RefundAmountFen,
                                        <<"total">>    => RefundAmountFen,
                                        <<"currency">> => <<"CNY">>}
            }),
            try
                Auth    = build_authorization(<<"POST">>, UrlPath, Body,
                                              MchId, PrivKeyPem, SerialNo),
                Headers = [{<<"content-type">>,  <<"application/json">>},
                           {<<"authorization">>, Auth},
                           {<<"accept">>,        <<"application/json">>}],
                FullUrl = <<GwUrl/binary, UrlPath/binary>>,
                case ersub_upstream_pool:request(
                        <<"POST">>, FullUrl, Headers, Body, #{}, 15000) of
                    {ok, S, _, RespBody} when S =:= 200; S =:= 201 ->
                        parse_refund_response(jsx:decode(RespBody, [return_maps]));
                    {ok, Status, _, RespBody} ->
                        {error, {wechat_http_error, Status, RespBody}};
                    {error, Reason} ->
                        {error, Reason}
                end
            catch C:E ->
                {error, {refund_error, C, E}}
            end;
        {error, Reason} ->
            {error, {clips_error, Reason}}
    end.

%% Backward-compat stub — callers should migrate to create_native_order/3.
-spec create_order(integer(), number(), binary()) ->
    {ok, #{code_url := binary()}} | {error, term()}.
create_order(_UserId, AmountCny, _NotifyUrl) ->
    create_native_order(<<>>, round(AmountCny * 100), <<"ErSub Balance Top-up">>).

%%% Internal

build_authorization(Method, UrlPath, Body, MchId, PrivKeyPem, SerialNo) ->
    Timestamp = integer_to_binary(erlang:system_time(second)),
    Nonce     = make_nonce(),
    SignStr   = iolist_to_binary([Method, "\n", UrlPath, "\n",
                                  Timestamp, "\n", Nonce, "\n", Body, "\n"]),
    SigB64    = sign_rsa(SignStr, PrivKeyPem),
    <<"WECHATPAY2-SHA256-RSA2048 ",
      "mchid=\"",     MchId/binary,     "\",",
      "nonce_str=\"", Nonce/binary,     "\",",
      "timestamp=\"", Timestamp/binary, "\",",
      "serial_no=\"", SerialNo/binary,  "\",",
      "signature=\"", SigB64/binary,    "\"">>.

sign_rsa(Data, PrivKeyPem) ->
    case load_pem_key(PrivKeyPem) of
        {ok, PrivKey} ->
            base64:encode(public_key:sign(Data, sha256, PrivKey));
        {error, Reason} ->
            erlang:error({wechat_private_key, Reason})
    end.

verify_rsa(Data, SigB64, PubKeyPem) ->
    try
        Sig = base64:decode(SigB64),
        {ok, PubKey} = load_pem_key(PubKeyPem),
        public_key:verify(Data, sha256, Sig, PubKey)
    catch _:_ -> false
    end.

%% AEAD_AES_256_GCM decrypt. associated_data is optional per WeChat spec.
decrypt_resource(#{<<"resource">> := #{
        <<"algorithm">>  := <<"AEAD_AES_256_GCM">>,
        <<"ciphertext">> := CipherB64,
        <<"nonce">>      := Nonce
    } = R}) ->
    AAD      = maps:get(<<"associated_data">>, R, <<>>),
    ApiV3Key = get_conf(payment_wechat_api_v3_key),
    case byte_size(ApiV3Key) of
        32 ->
            Cipher = base64:decode(CipherB64),
            CLen   = byte_size(Cipher),
            CT     = binary:part(Cipher, 0, CLen - 16),
            Tag    = binary:part(Cipher, CLen - 16, 16),
            case crypto:crypto_one_time_aead(aes_256_gcm, ApiV3Key, Nonce, CT, AAD, Tag, false) of
                error     -> {error, decrypt_failed};
                PlainText -> {ok, jsx:decode(PlainText, [return_maps])}
            end;
        Len ->
            {error, {invalid_api_v3_key_length, Len}}
    end;
decrypt_resource(_) -> {error, unexpected_resource_format}.

parse_refund_response(Resp) ->
    case maps:get(<<"status">>, Resp, undefined) of
        <<"SUCCESS">>    -> ok;
        <<"PROCESSING">> -> {error, {wechat_refund_pending, Resp}};
        Status           -> {error, {wechat_refund_failed, Status, Resp}}
    end.

is_timestamp_fresh(<<>>, _) -> false;
is_timestamp_fresh(TsBin, MaxSkewSec) ->
    try
        Ts  = binary_to_integer(TsBin),
        Now = erlang:system_time(second),
        abs(Now - Ts) =< MaxSkewSec
    catch _:_ -> false
    end.

load_pem_key(<<>>) -> {error, empty_key};
load_pem_key(Pem) ->
    Normalized = binary:replace(Pem, <<"\\n">>, <<"\n">>, [global]),
    case public_key:pem_decode(Normalized) of
        [Entry | _] -> {ok, public_key:pem_entry_decode(Entry)};
        []          -> {error, invalid_pem}
    end.

make_nonce() ->
    iolist_to_binary(
        [io_lib:format("~2.16.0B", [B]) || <<B>> <= crypto:strong_rand_bytes(16)]).

get_conf(Key) ->
    ensure_binary(ersub_config_srv:get(Key, <<>>)).

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V)   -> list_to_binary(V);
ensure_binary(_)                   -> <<>>.
