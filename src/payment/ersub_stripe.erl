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

%% Verify Stripe webhook signature (Stripe-Signature header format).
%% Header: t=timestamp,v1=signature[,v1=signature...]
%% Verifies HMAC-SHA256 and checks timestamp within 5-minute tolerance.
-spec verify_webhook(binary(), binary()) -> boolean().
verify_webhook(Payload, SignatureHeader) ->
    WebhookSecret = ersub_config_srv:get(payment_stripe_webhook_secret, <<>>),
    case WebhookSecret of
        <<>> -> false;
        Secret ->
            case parse_stripe_signature(SignatureHeader) of
                {ok, Timestamp, Signatures} ->
                    %% Check timestamp within 5 minutes (anti-replay)
                    Now = erlang:system_time(second),
                    case abs(Now - Timestamp) =< 300 of
                        false -> false;
                        true ->
                            %% Compute expected signature: HMAC-SHA256(secret, "timestamp.payload")
                            SignedPayload = <<(integer_to_binary(Timestamp))/binary, ".", Payload/binary>>,
                            Expected = string:lowercase(binary:encode_hex(
                                crypto:mac(hmac, sha256, Secret, SignedPayload))),
                            lists:any(fun(Sig) ->
                                crypto:hash_equals(Expected, string:lowercase(Sig))
                            end, Signatures)
                    end;
                error ->
                    false
            end
    end.

parse_stripe_signature(Header) ->
    Parts = binary:split(Header, <<",">>, [global]),
    {Timestamps, Sigs} = lists:foldl(fun(Part, {Ts, Ss}) ->
        case binary:split(Part, <<"=">>) of
            [<<"t">>, V] -> {[binary_to_integer(V) | Ts], Ss};
            [<<"v1">>, V] -> {Ts, [V | Ss]};
            _ -> {Ts, Ss}
        end
    end, {[], []}, Parts),
    case {Timestamps, Sigs} of
        {[T | _], [_ | _]} -> {ok, T, Sigs};
        _ -> error
    end.
