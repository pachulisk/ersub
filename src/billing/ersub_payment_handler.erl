-module(ersub_payment_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    handle(Method, Path, Req0, State).

%% GET /api/payment/config -- list enabled payment providers (public)
handle(<<"GET">>, [<<"config">>], Req0, State) ->
    Providers = get_enabled_providers(),
    reply_ok(#{data => Providers}, Req0, State);

%% POST /api/payment/orders -- create a payment order (auth required)
handle(<<"POST">>, [<<"orders">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Params = jsx:decode(Body, [return_maps]),
            Provider = maps:get(<<"provider">>, Params, <<>>),
            Amount = maps:get(<<"amount_usd">>, Params, 0),
            case validate_order_params(Provider, Amount) of
                {error, Msg} ->
                    reply_err(400, Msg, Req1, State);
                ok ->
                    AmountFloat = to_float(Amount),
                    case ersub_payment_srv:create_order(UserId, Provider, AmountFloat) of
                        {ok, Order} ->
                            reply_ok(#{data => Order}, Req1, State);
                        {error, Reason2} ->
                            reply_err(500, Reason2, Req1, State)
                    end
            end
    end;

%% GET /api/payment/orders/:id -- get order status (auth required)
handle(<<"GET">>, [<<"orders">>, IdBin], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            OrderId = binary_to_integer(IdBin),
            case ersub_payment_srv:get_order(OrderId) of
                {ok, #{user_id := OrderUserId} = Order} ->
                    %% Ensure the user can only see their own orders
                    case OrderUserId =:= UserId of
                        true ->
                            reply_ok(#{data => Order}, Req0, State);
                        false ->
                            reply_err(403, <<"Access denied">>, Req0, State)
                    end;
                {error, not_found} ->
                    reply_err(404, <<"Order not found">>, Req0, State);
                {error, Reason2} ->
                    reply_err(500, Reason2, Req0, State)
            end
    end;

%% POST /api/payment/webhooks/:provider -- webhook handler (no auth, signature verified)
handle(<<"POST">>, [<<"webhooks">>, Provider], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case handle_webhook(Provider, Body, Req1) of
        ok ->
            reply_ok(#{success => true}, Req1, State);
        {error, Reason} ->
            logger:error("Webhook processing failed for ~s: ~p", [Provider, Reason]),
            reply_err(400, <<"Webhook processing failed">>, Req1, State)
    end;

%% Fallback
handle(_, _, Req0, State) ->
    Req = reply_json(404, #{error => #{message => <<"Not found">>}}, Req0),
    {ok, Req, State}.

%%% Internal

verify_user_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            ersub_auth_srv:verify_jwt(string:trim(Token));
        _ ->
            {error, missing_token}
    end.

get_enabled_providers() ->
    %% Read enabled providers from config
    Providers = ersub_config_srv:get(payment_providers, []),
    case Providers of
        L when is_list(L) ->
            [#{name => to_bin(P)} || P <- L];
        _ ->
            []
    end.

validate_order_params(Provider, Amount) ->
    case Provider of
        <<>> ->
            {error, <<"provider is required">>};
        _ when not is_binary(Provider) ->
            {error, <<"provider must be a string">>};
        _ ->
            case to_float(Amount) of
                F when F > 0 ->
                    ok;
                _ ->
                    {error, <<"amount_usd must be positive">>}
            end
    end.

handle_webhook(Provider, Body, Req) ->
    case jsx:is_json(Body) of
        false ->
            {error, invalid_json};
        true ->
            Payload = jsx:decode(Body, [return_maps]),
            case verify_webhook_signature(Provider, Body, Req) of
                false ->
                    logger:warning("Invalid webhook signature from ~s", [Provider]),
                    {error, invalid_signature};
                true ->
                    process_webhook_event(Provider, Payload)
            end
    end.

verify_webhook_signature(Provider, Body, Req) ->
    Signature = cowboy_req:header(<<"x-webhook-signature">>, Req, <<>>),
    Secret = get_webhook_secret(Provider),
    case {Signature, Secret} of
        {<<>>, <<>>} ->
            %% No signature verification configured, allow in dev
            true;
        {<<>>, _} ->
            false;
        {Sig, Sec} ->
            Expected = binary:encode_hex(
                crypto:mac(hmac, sha256, Sec, Body)),
            crypto:hash_equals(
                string:lowercase(Expected),
                string:lowercase(Sig))
    end.

get_webhook_secret(Provider) ->
    ConfigKey = binary_to_atom(
        <<"payment_webhook_secret_", Provider/binary>>),
    case ersub_config_srv:get(ConfigKey, <<>>) of
        S when is_list(S) -> list_to_binary(S);
        S when is_binary(S) -> S;
        _ -> <<>>
    end.

process_webhook_event(Provider, Payload) ->
    EventType = maps:get(<<"event_type">>, Payload,
                  maps:get(<<"type">>, Payload, <<>>)),
    case EventType of
        <<"payment.completed">> ->
            OrderId = maps:get(<<"order_id">>, Payload, 0),
            ProviderOrderId = maps:get(<<"provider_order_id">>, Payload,
                                maps:get(<<"id">>, Payload, <<>>)),
            case ersub_payment_srv:fulfill_order(
                    to_integer(OrderId), to_bin(ProviderOrderId)) of
                ok -> ok;
                {error, Reason} -> {error, Reason}
            end;
        <<"payment.failed">> ->
            OrderId = maps:get(<<"order_id">>, Payload, 0),
            logger:warning("Payment failed for order ~p via ~s", [OrderId, Provider]),
            ok;
        _ ->
            logger:info("Unhandled webhook event ~s from ~s", [EventType, Provider]),
            ok
    end.

%%% Response helpers

reply_ok(Body, Req0, State) ->
    Req = reply_json(200, Body, Req0),
    {ok, Req, State}.

reply_err(Status, Reason, Req0, State) when is_binary(Reason) ->
    Req = reply_json(Status, #{error => #{message => Reason}}, Req0),
    {ok, Req, State};
reply_err(Status, Reason, Req0, State) ->
    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
    Req = reply_json(Status, #{error => #{message => Msg}}, Req0),
    {ok, Req, State}.

reply_auth_error(missing_token, Req0, State) ->
    Req = reply_json(401, #{error => #{message => <<"Missing Authorization header">>}}, Req0),
    {ok, Req, State};
reply_auth_error(token_expired, Req0, State) ->
    Req = reply_json(401, #{error => #{message => <<"Token expired">>}}, Req0),
    {ok, Req, State};
reply_auth_error(_, Req0, State) ->
    Req = reply_json(401, #{error => #{message => <<"Authentication failed">>}}, Req0),
    {ok, Req, State}.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

to_float(V) when is_float(V) -> V;
to_float(V) when is_integer(V) -> V * 1.0;
to_float(V) when is_binary(V) ->
    case catch binary_to_float(V) of
        F when is_float(F) -> F;
        _ ->
            case catch binary_to_integer(V) of
                I when is_integer(I) -> I * 1.0;
                _ -> 0.0
            end
    end;
to_float(_) -> 0.0.

to_integer(V) when is_integer(V) -> V;
to_integer(V) when is_binary(V) -> binary_to_integer(V);
to_integer(_) -> 0.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
