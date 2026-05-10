-module(ersub_wechat).

-export([create_order/3, verify_callback/1]).

%% Create a WeChat Pay order.
-spec create_order(integer(), number(), binary()) -> {ok, map()} | {error, term()}.
create_order(UserId, AmountCny, _NotifyUrl) ->
    MchId = ersub_config_srv:get(payment_wechat_mch_id, <<>>),
    case MchId of
        <<>> -> {error, not_configured};
        _ ->
            OrderNo = generate_order_no(),
            AmountFen = trunc(AmountCny * 100),
            %% In production: sign with API v3 key, call WeChat Pay API
            {ok, #{
                order_no => OrderNo,
                amount_fen => AmountFen,
                user_id => UserId,
                prepay_url => <<"https://api.mch.weixin.qq.com/v3/pay/transactions/native">>,
                status => <<"pending">>
            }}
    end.

%% Verify WeChat Pay callback.
-spec verify_callback(map()) -> boolean().
verify_callback(Params) ->
    %% In production: verify with WeChat Pay certificate
    maps:get(<<"result_code">>, Params, <<>>) =:= <<"SUCCESS">>.

generate_order_no() ->
    TS = integer_to_binary(erlang:system_time(millisecond)),
    Rand = binary:encode_hex(crypto:strong_rand_bytes(4)),
    <<"WX-", TS/binary, "-", Rand/binary>>.
