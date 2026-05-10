-module(ersub_alipay).

-export([create_order/3, verify_callback/1]).

%% Create an Alipay payment order.
-spec create_order(integer(), number(), binary()) -> {ok, map()} | {error, term()}.
create_order(UserId, AmountCny, _NotifyUrl) ->
    AppId = ersub_config_srv:get(payment_alipay_app_id, <<>>),
    case AppId of
        <<>> -> {error, not_configured};
        _ ->
            OrderNo = generate_order_no(),
            %% In production: sign with RSA private key, call alipay gateway
            {ok, #{
                order_no => OrderNo,
                amount_cny => AmountCny,
                user_id => UserId,
                pay_url => <<"https://openapi.alipay.com/gateway.do">>,
                status => <<"pending">>
            }}
    end.

%% Verify Alipay async callback signature.
-spec verify_callback(map()) -> boolean().
verify_callback(Params) ->
    %% In production: verify RSA signature with Alipay public key
    maps:get(<<"trade_status">>, Params, <<>>) =:= <<"TRADE_SUCCESS">>.

generate_order_no() ->
    TS = integer_to_binary(erlang:system_time(millisecond)),
    Rand = binary:encode_hex(crypto:strong_rand_bytes(4)),
    <<"ERSUB-", TS/binary, "-", Rand/binary>>.
