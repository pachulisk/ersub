-module(ersub_alipay).

-export([is_available/0, create_page_pay/3, verify_callback/1, refund/2]).
-export([create_order/3]).

-spec is_available() -> boolean().
is_available() ->
    try
        ClipsEnabled = case ersub_clips_pool:get_alipay_config() of
            {ok, #{<<"enabled">> := <<"TRUE">>}} -> true;
            _ -> false
        end,
        ClipsEnabled
            andalso ersub_config_srv:get(payment_alipay_app_id, <<>>) =/= <<>>
            andalso ersub_config_srv:get(payment_alipay_private_key, <<>>) =/= <<>>
    catch _:_ -> false
    end.

%% Build a trade.page.pay redirect URL for the given order.
-spec create_page_pay(binary(), number(), binary()) ->
    {ok, #{checkout_url := binary()}} | {error, term()}.
create_page_pay(OrderId, AmountCny, Subject) ->
    case ersub_clips_pool:get_alipay_config() of
        {ok, ClipsCfg} ->
            AppId      = get_conf(payment_alipay_app_id),
            PrivKeyPem = get_conf(payment_alipay_private_key),
            NotifyUrl  = get_conf(payment_alipay_notify_url),
            ReturnUrl  = get_conf(payment_alipay_return_url),
            GatewayUrl = pick_gateway(ClipsCfg),
            BizContent = jsx:encode(#{
                <<"out_trade_no">> => OrderId,
                <<"product_code">> => <<"FAST_INSTANT_TRADE_PAY">>,
                <<"total_amount">> => format_amount(AmountCny),
                <<"subject">>      => Subject
            }),
            BaseP  = base_params(AppId, <<"alipay.trade.page.pay">>),
            Params = BaseP#{
                <<"notify_url">>  => NotifyUrl,
                <<"return_url">>  => ReturnUrl,
                <<"biz_content">> => BizContent
            },
            try
                Sign = sign_params(Params, PrivKeyPem),
                AllParams = Params#{<<"sign">> => Sign},
                QueryStr = list_to_binary(
                    uri_string:compose_query(maps_to_pairs(AllParams))),
                {ok, #{checkout_url => <<GatewayUrl/binary, "?", QueryStr/binary>>}}
            catch
                C:E -> {error, {signing_failed, C, E}}
            end;
        {error, Reason} ->
            {error, {clips_error, Reason}}
    end.

%% Verify an Alipay async notification callback (form-encoded POST body).
-spec verify_callback(map()) -> boolean().
verify_callback(Params) ->
    PubKeyPem = get_conf(payment_alipay_public_key),
    case PubKeyPem of
        <<>> -> false;
        _ ->
            try
                SignB64 = maps:get(<<"sign">>, Params, <<>>),
                Sig     = base64:decode(SignB64),
                Stripped = maps:without([<<"sign">>, <<"sign_type">>], Params),
                Data    = build_sign_string(Stripped),
                {ok, PubKey} = load_pem_key(PubKeyPem),
                public_key:verify(Data, sha256, Sig, PubKey)
            catch _:_ -> false
            end
    end.

%% Call alipay.trade.refund (synchronous). Returns ok or {error, Reason}.
-spec refund(binary(), number()) -> ok | {error, term()}.
refund(OutTradeNo, RefundAmountCny) ->
    case ersub_clips_pool:get_alipay_config() of
        {ok, ClipsCfg} ->
            AppId      = get_conf(payment_alipay_app_id),
            PrivKeyPem = get_conf(payment_alipay_private_key),
            GatewayUrl = pick_gateway(ClipsCfg),
            BizContent = jsx:encode(#{
                <<"out_trade_no">>  => OutTradeNo,
                <<"refund_amount">> => format_amount(RefundAmountCny)
            }),
            BaseP  = base_params(AppId, <<"alipay.trade.refund">>),
            Params = BaseP#{<<"biz_content">> => BizContent},
            try
                Sign = sign_params(Params, PrivKeyPem),
                AllParams = Params#{<<"sign">> => Sign},
                FormBody = list_to_binary(
                    uri_string:compose_query(maps_to_pairs(AllParams))),
                Headers = [{<<"content-type">>,
                            <<"application/x-www-form-urlencoded">>}],
                case ersub_upstream_pool:request(
                        <<"POST">>, GatewayUrl, Headers, FormBody, #{}, 15000) of
                    {ok, 200, _, RespBody} ->
                        parse_refund_response(jsx:decode(RespBody, [return_maps]));
                    {ok, Status, _, RespBody} ->
                        {error, {alipay_http_error, Status, RespBody}};
                    {error, Reason} ->
                        {error, Reason}
                end
            catch C:E ->
                {error, {refund_error, C, E}}
            end;
        {error, Reason} ->
            {error, {clips_error, Reason}}
    end.

%% Backward-compat stub — callers should migrate to create_page_pay/3.
-spec create_order(integer(), number(), binary()) ->
    {ok, #{checkout_url := binary()}} | {error, term()}.
create_order(_UserId, AmountCny, _NotifyUrl) ->
    create_page_pay(<<>>, AmountCny, <<"Top-up">>).

%%% Internal

base_params(AppId, Method) ->
    #{<<"app_id">>    => ensure_binary(AppId),
      <<"method">>    => Method,
      <<"format">>    => <<"JSON">>,
      <<"charset">>   => <<"utf-8">>,
      <<"sign_type">> => <<"RSA2">>,
      <<"timestamp">> => format_timestamp(),
      <<"version">>   => <<"1.0">>}.

pick_gateway(ClipsCfg) ->
    case maps:get(<<"sandbox-mode">>, ClipsCfg, <<"FALSE">>) of
        <<"TRUE">> -> maps:get(<<"sandbox-gateway-url">>, ClipsCfg,
                               <<"https://openapi.alipaydev.com/gateway.do">>);
        _          -> maps:get(<<"gateway-url">>, ClipsCfg,
                               <<"https://openapi.alipay.com/gateway.do">>)
    end.

sign_params(Params, PrivKeyPem) ->
    {ok, PrivKey} = load_pem_key(PrivKeyPem),
    Data = build_sign_string(maps:without([<<"sign">>, <<"sign_type">>], Params)),
    Sig  = public_key:sign(Data, sha256, PrivKey),
    base64:encode(Sig).

build_sign_string(Params) ->
    Sorted = lists:sort(maps:to_list(Params)),
    Parts  = [<<K/binary, "=", V/binary>>
              || {K, V} <- Sorted,
                 is_binary(K), is_binary(V), V =/= <<>>],
    iolist_to_binary(lists:join(<<"&">>, Parts)).

maps_to_pairs(Params) ->
    [{binary_to_list(K), binary_to_list(V)}
     || {K, V} <- maps:to_list(Params),
        is_binary(K), is_binary(V)].

load_pem_key(<<>>) ->
    {error, empty_key};
load_pem_key(Pem) ->
    Normalized = binary:replace(Pem, <<"\\n">>, <<"\n">>, [global]),
    case public_key:pem_decode(Normalized) of
        [Entry | _] -> {ok, public_key:pem_entry_decode(Entry)};
        []          -> {error, invalid_pem}
    end.

format_amount(N) when is_float(N)   ->
    iolist_to_binary(io_lib:format("~.2f", [N]));
format_amount(N) when is_integer(N) ->
    iolist_to_binary(io_lib:format("~.2f", [N * 1.0])).

format_timestamp() ->
    {{Y, Mo, D}, {H, Mi, S}} = erlang:localtime(),
    iolist_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
                      [Y, Mo, D, H, Mi, S])).

parse_refund_response(Resp) ->
    case maps:get(<<"alipay_trade_refund_response">>, Resp, #{}) of
        #{<<"code">> := <<"10000">>} ->
            ok;
        #{<<"code">> := Code, <<"msg">> := Msg} ->
            {error, {alipay_refund_failed, Code, Msg}};
        _ ->
            {error, {alipay_refund_failed, <<"unknown">>, <<"unexpected response">>}}
    end.

get_conf(Key) ->
    V = ersub_config_srv:get(Key, <<>>),
    ensure_binary(V).

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V)   -> list_to_binary(V);
ensure_binary(_)                   -> <<>>.
