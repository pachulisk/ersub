-module(ersub_easypay).

-export([is_available/0, create_order/4, verify_callback/1, refund/2]).

-spec is_available() -> boolean().
is_available() ->
    try
        ClipsEnabled = case ersub_clips_pool:get_easypay_config() of
            {ok, #{<<"enabled">> := <<"TRUE">>}} -> true;
            _ -> false
        end,
        ClipsEnabled
            andalso get_conf(payment_easypay_pid)  =/= <<>>
            andalso get_conf(payment_easypay_pkey) =/= <<>>
    catch _:_ -> false
    end.

%% Create a payment order via the Easy Pay (易支付) API.
%% PaymentType is <<"alipay">> or <<"wxpay">>.
%% Returns pay_url (popup mode) and/or qr_code (qrcode mode).
-spec create_order(binary(), number(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
create_order(OrderId, AmountCny, PaymentType, Description) ->
    case ersub_clips_pool:get_easypay_config() of
        {ok, ClipsCfg} ->
            Pid       = get_conf(payment_easypay_pid),
            PKey      = get_conf(payment_easypay_pkey),
            ApiBase   = get_gateway(ClipsCfg),
            NotifyUrl = get_conf(payment_easypay_notify_url),
            ReturnUrl = get_conf(payment_easypay_return_url),
            Params0   = #{
                <<"pid">>          => Pid,
                <<"type">>         => PaymentType,
                <<"out_trade_no">> => OrderId,
                <<"notify_url">>   => NotifyUrl,
                <<"return_url">>   => ReturnUrl,
                <<"name">>         => Description,
                <<"money">>        => format_amount(AmountCny)
            },
            Params1 = case get_cid_param(PaymentType) of
                <<>> -> Params0;
                Cid  -> Params0#{<<"param">> => Cid}
            end,
            Sign    = sign_params(Params1, PKey),
            Params2 = Params1#{<<"sign">> => Sign, <<"sign_type">> => <<"MD5">>},
            FormBody = build_form_body(Params2),
            Url      = <<ApiBase/binary, "/api.php">>,
            Headers  = [{<<"content-type">>, <<"application/x-www-form-urlencoded">>},
                        {<<"accept">>,        <<"application/json">>}],
            try
                case ersub_upstream_pool:request(
                        <<"POST">>, Url, Headers, FormBody, #{}, 15000) of
                    {ok, 200, _, RespBody} ->
                        parse_create_response(jsx:decode(RespBody, [return_maps]));
                    {ok, Status, _, RespBody} ->
                        {error, {easypay_http_error, Status, RespBody}};
                    {error, Reason} ->
                        {error, Reason}
                end
            catch C:E ->
                {error, {create_order_error, C, E}}
            end;
        {error, Reason} ->
            {error, {clips_error, Reason}}
    end.

%% Verify Easy Pay async notification signature.
-spec verify_callback(map()) -> {ok, map()} | {error, term()}.
verify_callback(Params) ->
    PKey = get_conf(payment_easypay_pkey),
    case PKey of
        <<>> -> {error, no_pkey};
        _ ->
            GivenSign = maps:get(<<"sign">>, Params, <<>>),
            Stripped  = maps:without([<<"sign">>, <<"sign_type">>], Params),
            Expected  = sign_params(Stripped, PKey),
            SameLen = byte_size(Expected) =:= byte_size(GivenSign),
            case SameLen andalso crypto:hash_equals(Expected, GivenSign) of
                true  -> {ok, Params};
                false -> {error, invalid_signature}
            end
    end.

%% Refund — varies per Easy Pay vendor; left as an extension point.
-spec refund(binary(), number()) -> ok | {error, term()}.
refund(_OutTradeNo, _AmountCny) ->
    {error, not_implemented}.

%%% Internal

sign_params(Params, PKey) ->
    Filtered = maps:filter(
        fun(K, V) -> is_binary(K) andalso is_binary(V) andalso V =/= <<>> end,
        Params),
    Sorted = lists:sort(maps:to_list(Filtered)),
    KVStr  = iolist_to_binary(
        lists:join(<<"&">>, [<<K/binary, "=", V/binary>> || {K, V} <- Sorted])),
    Str    = <<KVStr/binary, PKey/binary>>,
    binary:encode_hex(crypto:hash(md5, Str), lowercase).

build_form_body(Params) ->
    Pairs = [{binary_to_list(K), binary_to_list(V)}
             || {K, V} <- maps:to_list(Params),
                is_binary(K), is_binary(V)],
    list_to_binary(uri_string:compose_query(Pairs)).

parse_create_response(#{<<"code">> := 1} = Resp) ->
    PayUrl = maps:get(<<"payurl">>, Resp, <<>>),
    QrCode = maps:get(<<"qrcode">>, Resp, <<>>),
    case {PayUrl, QrCode} of
        {<<>>, <<>>} ->
            {error, {easypay_no_url, Resp}};
        _ ->
            Mode = decide_mode(PayUrl, QrCode),
            Base = #{payment_mode => Mode},
            R1   = case PayUrl of <<>> -> Base; U -> Base#{pay_url  => U} end,
            R2   = case QrCode of <<>> -> R1;   Q -> R1#{qr_code => Q}   end,
            {ok, R2}
    end;
parse_create_response(#{<<"code">> := Code, <<"msg">> := Msg}) ->
    {error, {easypay_error, Code, Msg}};
parse_create_response(Other) ->
    {error, {easypay_unexpected_response, Other}}.

decide_mode(_, QrCode) when QrCode =/= <<>> -> <<"qrcode">>;
decide_mode(PayUrl, _) when PayUrl  =/= <<>> -> <<"popup">>;
decide_mode(_, _)                            -> <<"popup">>.

get_gateway(ClipsCfg) ->
    Default = get_conf(payment_easypay_api_base),
    maps:get(<<"gateway-url">>, ClipsCfg, Default).

get_cid_param(<<"alipay">>) -> get_conf(payment_easypay_cid_alipay);
get_cid_param(<<"wxpay">>)  -> get_conf(payment_easypay_cid_wxpay);
get_cid_param(_)            -> <<>>.

format_amount(N) when is_float(N)   ->
    iolist_to_binary(io_lib:format("~.2f", [N]));
format_amount(N) when is_integer(N) ->
    iolist_to_binary(io_lib:format("~.2f", [N * 1.0])).

get_conf(Key) ->
    V = ersub_config_srv:get(Key, <<>>),
    ensure_binary(V).

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V)   -> list_to_binary(V);
ensure_binary(_)                   -> <<>>.
