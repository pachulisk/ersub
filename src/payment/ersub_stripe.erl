-module(ersub_stripe).

-export([create_checkout_session/3, verify_webhook/2]).

%% Create a Stripe checkout session.
-spec create_checkout_session(integer(), number(), binary()) ->
    {ok, map()} | {error, term()}.
create_checkout_session(UserId, AmountUsd, SuccessUrl) ->
    SecretKey = ersub_config_srv:get(payment_stripe_secret_key, <<>>),
    case SecretKey of
        <<>> -> {error, not_configured};
        _ ->
            AmountCents = trunc(AmountUsd * 100),
            Body = uri_string:compose_query([
                {"mode", "payment"},
                {"payment_method_types[]", "card"},
                {"line_items[0][price_data][currency]", "usd"},
                {"line_items[0][price_data][unit_amount]", integer_to_list(AmountCents)},
                {"line_items[0][price_data][product_data][name]", "ErSub Balance Top-up"},
                {"line_items[0][quantity]", "1"},
                {"success_url", binary_to_list(SuccessUrl)},
                {"metadata[user_id]", integer_to_list(UserId)}
            ]),
            Headers = [
                {<<"authorization">>, <<"Bearer ", SecretKey/binary>>},
                {<<"content-type">>, <<"application/x-www-form-urlencoded">>}
            ],
            case ersub_upstream_pool:request(<<"POST">>,
                <<"https://api.stripe.com/v1/checkout/sessions">>,
                Headers, list_to_binary(Body), #{}, 15000) of
                {ok, 200, _, RespBody} ->
                    Session = jsx:decode(RespBody, [return_maps]),
                    {ok, #{
                        session_id => maps:get(<<"id">>, Session),
                        url => maps:get(<<"url">>, Session, <<>>)
                    }};
                {ok, Status, _, RespBody} ->
                    {error, {stripe_error, Status, RespBody}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% Verify Stripe webhook signature.
-spec verify_webhook(binary(), binary()) -> boolean().
verify_webhook(Payload, Signature) ->
    WebhookSecret = ersub_config_srv:get(payment_stripe_webhook_secret, <<>>),
    case WebhookSecret of
        <<>> -> false;
        Secret ->
            %% Simple HMAC check (production should parse Stripe-Signature header fully)
            Expected = crypto:mac(hmac, sha256, Secret, Payload),
            ExpHex = binary:encode_hex(Expected),
            case binary:match(Signature, ExpHex) of
                nomatch -> false;
                _ -> true
            end
    end.
