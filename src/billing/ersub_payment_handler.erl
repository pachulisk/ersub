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
            Provider    = maps:get(<<"provider">>,     Params, <<>>),
            Amount      = maps:get(<<"amount_usd">>,   Params, 0),
            PaymentType = maps:get(<<"payment_type">>, Params, <<"alipay">>),
            case validate_order_params(Provider, Amount) of
                {error, Msg} ->
                    reply_err(400, Msg, Req1, State);
                ok ->
                    AmountFloat = to_float(Amount),
                    Opts = #{payment_type => PaymentType},
                    case ersub_payment_srv:create_order(UserId, Provider, AmountFloat, Opts) of
                        {ok, Order} ->
                            reply_ok(#{data => Order}, Req1, State);
                        {error, Reason2} ->
                            reply_err(500, Reason2, Req1, State)
                    end
            end
    end;

%% POST /api/payment/orders/verify -- verify an order's payment status (auth required)
handle(<<"POST">>, [<<"orders">>, <<"verify">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Params = jsx:decode(Body, [return_maps]),
            OrderId = maps:get(<<"order_id">>, Params, 0),
            case ersub_payment_srv:get_order(to_integer(OrderId)) of
                {ok, #{user_id := OrderUserId, status := Status}} ->
                    case OrderUserId =:= UserId of
                        true ->
                            Verified = Status =:= <<"paid">>,
                            reply_ok(#{verified => Verified, status => Status}, Req1, State);
                        false ->
                            reply_err(403, <<"Access denied">>, Req1, State)
                    end;
                {error, not_found} ->
                    reply_err(404, <<"Order not found">>, Req1, State)
            end
    end;

%% GET /api/payment/orders/my -- list user's own orders
handle(<<"GET">>, [<<"orders">>, <<"my">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            case ersub_repo:query(
                "SELECT id, provider, amount_usd, status, created_at "
                "FROM payment_orders WHERE user_id = $1 "
                "ORDER BY created_at DESC LIMIT 50",
                [UserId])
            of
                {ok, _, Rows} ->
                    Data = [#{id => Id, provider => Prov, amount_usd => Amt,
                              status => St, created_at => CA}
                            || {Id, Prov, Amt, St, CA} <- Rows],
                    reply_ok(#{data => Data}, Req0, State);
                _ ->
                    reply_ok(#{data => []}, Req0, State)
            end
    end;

%% GET /api/payment/orders/refund-eligible-providers -- providers that support refund
handle(<<"GET">>, [<<"orders">>, <<"refund-eligible-providers">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            case ersub_repo:query(
                "SELECT DISTINCT provider FROM payment_orders "
                "WHERE user_id = $1 AND status = 'paid'",
                [UserId])
            of
                {ok, _, Rows} ->
                    Providers = [Prov || {Prov} <- Rows],
                    reply_ok(#{data => Providers}, Req0, State);
                _ ->
                    reply_ok(#{data => []}, Req0, State)
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
                    reply_err(404, <<"Order not found">>, Req0, State)
            end
    end;

%% POST /api/payment/webhooks/:provider -- webhook handler (no auth, signature verified)
handle(<<"POST">>, [<<"webhooks">>, Provider], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => 65536, period => 5000}),
    case handle_webhook(Provider, Body, Req1) of
        ok when Provider =:= <<"easypay">> ->
            %% Easy Pay protocol requires plain-text "success" in the response body.
            Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>},
                                    <<"success">>, Req1),
            {ok, Req2, State};
        ok ->
            Req2 = reply_json(200,
                #{<<"code">> => <<"SUCCESS">>, <<"message">> => <<"OK">>}, Req1),
            {ok, Req2, State};
        {error, Reason} ->
            logger:error("Webhook processing failed for ~s: ~p", [Provider, Reason]),
            Req2 = reply_json(500,
                #{<<"code">> => <<"FAIL">>, <<"message">> => <<"processing error">>}, Req1),
            {ok, Req2, State}
    end;

%% === T4-22: Payment Plan Management CRUD (admin-only) ===

%% GET /api/v1/payment/plans — List all payment plans
handle(<<"GET">>, [<<"plans">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, _} ->
            case ersub_repo:squery(
                "SELECT id, name, amount_usd, description, features, "
                "validity_days, sort_order, is_active, created_at "
                "FROM payment_plans ORDER BY sort_order ASC, id ASC") of
                {ok, _, Rows} ->
                    Plans = [#{id => Id, name => N, amount_usd => A,
                               description => D, features => F,
                               validity_days => VD, sort_order => SO,
                               is_active => IA, created_at => CA}
                             || {Id, N, A, D, F, VD, SO, IA, CA} <- Rows],
                    reply_ok(#{data => Plans}, Req0, State);
                _ ->
                    reply_ok(#{data => []}, Req0, State)
            end
    end;

%% POST /api/v1/payment/plans — Create a payment plan
handle(<<"POST">>, [<<"plans">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, _} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            P = jsx:decode(Body, [return_maps]),
            case ersub_repo:query(
                "INSERT INTO payment_plans (name, amount_usd, description, features, "
                "validity_days, sort_order) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
                [maps:get(<<"name">>, P),
                 maps:get(<<"amount_usd">>, P),
                 maps:get(<<"description">>, P, null),
                 jsx:encode(maps:get(<<"features">>, P, [])),
                 maps:get(<<"validity_days">>, P, 30),
                 maps:get(<<"sort_order">>, P, 0)]) of
                {ok, 1, _, [{Id}]} ->
                    reply_ok(#{data => #{id => Id}}, Req1, State);
                {error, R} ->
                    reply_err(500, R, Req1, State)
            end
    end;

%% PUT /api/v1/payment/plans/:id — Update a payment plan
handle(<<"PUT">>, [<<"plans">>, IdBin], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            P = jsx:decode(Body, [return_maps]),
            Features = case maps:get(<<"features">>, P, null) of
                null -> null;
                F -> jsx:encode(F)
            end,
            case ersub_repo:query(
                "UPDATE payment_plans SET "
                "name = COALESCE($2, name), "
                "amount_usd = COALESCE($3, amount_usd), "
                "description = COALESCE($4, description), "
                "features = COALESCE($5, features), "
                "validity_days = COALESCE($6, validity_days), "
                "sort_order = COALESCE($7, sort_order), "
                "is_active = COALESCE($8, is_active) "
                "WHERE id = $1",
                [Id,
                 maps:get(<<"name">>, P, null),
                 maps:get(<<"amount_usd">>, P, null),
                 maps:get(<<"description">>, P, null),
                 Features,
                 maps:get(<<"validity_days">>, P, null),
                 maps:get(<<"sort_order">>, P, null),
                 maps:get(<<"is_active">>, P, null)]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req1, State);
                {ok, 0} ->
                    reply_err(404, <<"Plan not found">>, Req1, State);
                {error, R} ->
                    reply_err(500, R, Req1, State)
            end
    end;

%% DELETE /api/v1/payment/plans/:id — Delete a payment plan
handle(<<"DELETE">>, [<<"plans">>, IdBin], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            case ersub_repo:query("DELETE FROM payment_plans WHERE id = $1", [Id]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req0, State);
                {ok, 0} ->
                    reply_err(404, <<"Plan not found">>, Req0, State);
                {error, R} ->
                    reply_err(500, R, Req0, State)
            end
    end;

%% === T5-14: Payment Admin Management ===

%% GET /api/v1/payment/admin/orders — Admin list all orders
handle(<<"GET">>, [<<"admin">>, <<"orders">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            case ersub_repo:squery(
                "SELECT id, user_id, provider, amount_usd, status, created_at "
                "FROM payment_orders ORDER BY created_at DESC LIMIT 100") of
                {ok, _, Rows} ->
                    Data = [#{id => Id, user_id => UId, provider => Prov,
                              amount_usd => Amt, status => St, created_at => CA}
                            || {Id, UId, Prov, Amt, St, CA} <- Rows],
                    reply_ok(#{data => Data}, Req0, State);
                _ ->
                    reply_ok(#{data => []}, Req0, State)
            end
    end;

%% POST /api/v1/payment/admin/orders/:id/cancel — Cancel order
handle(<<"POST">>, [<<"admin">>, <<"orders">>, IdBin, <<"cancel">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            case ersub_repo:query(
                "UPDATE payment_orders SET status = 'cancelled' WHERE id = $1",
                [Id]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req0, State);
                {ok, 0} ->
                    reply_err(404, <<"Order not found">>, Req0, State);
                {error, R2} ->
                    reply_err(500, R2, Req0, State)
            end
    end;

%% POST /api/v1/payment/admin/orders/:id/retry — Retry order fulfillment
handle(<<"POST">>, [<<"admin">>, <<"orders">>, IdBin, <<"retry">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            case ersub_repo:query(
                "UPDATE payment_orders SET status = 'pending', updated_at = NOW() "
                "WHERE id = $1",
                [Id]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req0, State);
                {ok, 0} ->
                    reply_err(404, <<"Order not found">>, Req0, State);
                {error, R2} ->
                    reply_err(500, R2, Req0, State)
            end
    end;

%% POST /api/v1/payment/admin/orders/:id/refund — Refund order
handle(<<"POST">>, [<<"admin">>, <<"orders">>, IdBin, <<"refund">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            _Params = jsx:decode(Body, [return_maps]),
            case ersub_repo:query(
                "UPDATE payment_orders SET status = 'refunded' WHERE id = $1",
                [Id]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req1, State);
                {ok, 0} ->
                    reply_err(404, <<"Order not found">>, Req1, State);
                {error, R2} ->
                    reply_err(500, R2, Req1, State)
            end
    end;

%% GET /api/v1/payment/admin/providers — List payment providers
handle(<<"GET">>, [<<"admin">>, <<"providers">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            case ersub_repo:squery(
                "SELECT id, provider_type, name, is_active, created_at "
                "FROM payment_provider_instances ORDER BY id") of
                {ok, _, Rows} ->
                    Data = [#{id => Id, provider_type => PT, name => N,
                              is_active => IA, created_at => CA}
                            || {Id, PT, N, IA, CA} <- Rows],
                    reply_ok(#{data => Data}, Req0, State);
                _ ->
                    reply_ok(#{data => []}, Req0, State)
            end
    end;

%% POST /api/v1/payment/admin/providers — Create payment provider
handle(<<"POST">>, [<<"admin">>, <<"providers">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            P = jsx:decode(Body, [return_maps]),
            Config = case maps:get(<<"config">>, P, #{}) of
                C when is_map(C) -> jsx:encode(C);
                C -> C
            end,
            case ersub_repo:query(
                "INSERT INTO payment_provider_instances "
                "(provider_type, name, config, weight, is_active) "
                "VALUES ($1, $2, $3, $4, $5) RETURNING id",
                [maps:get(<<"provider_type">>, P),
                 maps:get(<<"name">>, P),
                 Config,
                 maps:get(<<"weight">>, P, 1),
                 maps:get(<<"is_active">>, P, true)]) of
                {ok, 1, _, [{Id}]} ->
                    reply_ok(#{data => #{id => Id}}, Req1, State);
                {error, R2} ->
                    reply_err(500, R2, Req1, State)
            end
    end;

%% PUT /api/v1/payment/admin/providers/:id — Update payment provider
handle(<<"PUT">>, [<<"admin">>, <<"providers">>, IdBin], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            P = jsx:decode(Body, [return_maps]),
            Config = case maps:get(<<"config">>, P, null) of
                null -> null;
                C when is_map(C) -> jsx:encode(C);
                C -> C
            end,
            case ersub_repo:query(
                "UPDATE payment_provider_instances SET "
                "provider_type = COALESCE($2, provider_type), "
                "name = COALESCE($3, name), "
                "config = COALESCE($4, config), "
                "weight = COALESCE($5, weight), "
                "is_active = COALESCE($6, is_active) "
                "WHERE id = $1",
                [Id,
                 maps:get(<<"provider_type">>, P, null),
                 maps:get(<<"name">>, P, null),
                 Config,
                 maps:get(<<"weight">>, P, null),
                 maps:get(<<"is_active">>, P, null)]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req1, State);
                {ok, 0} ->
                    reply_err(404, <<"Provider not found">>, Req1, State);
                {error, R2} ->
                    reply_err(500, R2, Req1, State)
            end
    end;

%% DELETE /api/v1/payment/admin/providers/:id — Delete payment provider
handle(<<"DELETE">>, [<<"admin">>, <<"providers">>, IdBin], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            case ersub_repo:query(
                "DELETE FROM payment_provider_instances WHERE id = $1",
                [Id]) of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req0, State);
                {ok, 0} ->
                    reply_err(404, <<"Provider not found">>, Req0, State);
                {error, R2} ->
                    reply_err(500, R2, Req0, State)
            end
    end;

%% GET /api/v1/payment/admin/dashboard — Payment dashboard
handle(<<"GET">>, [<<"admin">>, <<"dashboard">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            case ersub_repo:squery(
                "SELECT status, COUNT(*), COALESCE(SUM(amount_usd),0) "
                "FROM payment_orders GROUP BY status") of
                {ok, _, Rows} ->
                    Data = [#{status => St, count => Cnt, total_usd => Total}
                            || {St, Cnt, Total} <- Rows],
                    reply_ok(#{data => Data}, Req0, State);
                _ ->
                    reply_ok(#{data => []}, Req0, State)
            end
    end;

%% === T6-04: Payment User Endpoints ===

%% GET /api/v1/payment/admin/config — Admin payment configuration
handle(<<"GET">>, [<<"admin">>, <<"config">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            case ersub_repo:squery(
                "SELECT key, value FROM settings WHERE key LIKE 'payment_%' ORDER BY key") of
                {ok, _, Rows} ->
                    Config = maps:from_list(
                        [{K, jsx:decode(V, [return_maps])} || {K, V} <- Rows]),
                    reply_ok(#{data => Config}, Req0, State);
                _ ->
                    reply_ok(#{data => #{}}, Req0, State)
            end
    end;

%% PUT /api/v1/payment/admin/config — Update payment configuration
handle(<<"PUT">>, [<<"admin">>, <<"config">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Params = jsx:decode(Body, [return_maps]),
            Results = maps:fold(fun(Key, Value, Acc) ->
                FullKey = <<"payment_", Key/binary>>,
                case ersub_repo:upsert_setting(FullKey, Value) of
                    {ok, _} ->
                        ersub_config_srv:set(binary_to_atom(FullKey), Value),
                        Acc;
                    {error, R2} -> [{Key, R2} | Acc]
                end
            end, [], Params),
            case Results of
                [] -> reply_ok(#{success => true}, Req1, State);
                Errors ->
                    ErrMap = maps:from_list(
                        [{K, iolist_to_binary(io_lib:format("~p", [R2]))} || {K, R2} <- Errors]),
                    reply_err(400, ErrMap, Req1, State)
            end
    end;

%% GET /api/v1/payment/admin/orders/:id — Admin get single order
handle(<<"GET">>, [<<"admin">>, <<"orders">>, IdBin], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {error, R} -> reply_auth_error(R, Req0, State);
        {ok, _} ->
            OrderId = binary_to_integer(IdBin),
            case ersub_payment_srv:get_order(OrderId) of
                {ok, Order} ->
                    reply_ok(#{data => Order}, Req0, State);
                {error, not_found} ->
                    reply_err(404, <<"Order not found">>, Req0, State)
            end
    end;

%% GET /api/payment/checkout-info — enabled providers + user balance
handle(<<"GET">>, [<<"checkout-info">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            Providers = get_enabled_providers(),
            Balance = ersub_billing_srv:get_cached_balance(UserId),
            reply_ok(#{providers => Providers, balance => Balance}, Req0, State)
    end;

%% GET /api/payment/user-plans — list active payment plans for users
handle(<<"GET">>, [<<"user-plans">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, _} ->
            case ersub_repo:squery(
                "SELECT id, name, amount_usd, description, features, validity_days "
                "FROM payment_plans WHERE is_active = TRUE ORDER BY sort_order ASC") of
                {ok, _, Rows} ->
                    Plans = [#{id => Id, name => N, amount_usd => A,
                               description => D, features => F,
                               validity_days => VD}
                             || {Id, N, A, D, F, VD} <- Rows],
                    reply_ok(#{data => Plans}, Req0, State);
                _ ->
                    reply_ok(#{data => []}, Req0, State)
            end
    end;

%% GET /api/payment/channels — list payment channels/methods
handle(<<"GET">>, [<<"channels">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, _} ->
            Providers = get_enabled_providers(),
            reply_ok(#{data => Providers}, Req0, State)
    end;

%% GET /api/payment/limits — payment limits from settings
handle(<<"GET">>, [<<"limits">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, _} ->
            MinAmount = ersub_config_srv:get(payment_min_amount, 1.0),
            MaxAmount = ersub_config_srv:get(payment_max_amount, 10000.0),
            reply_ok(#{data => #{
                min_amount => MinAmount,
                max_amount => MaxAmount
            }}, Req0, State)
    end;

%% POST /api/payment/orders/:id/cancel — user cancel own pending order
handle(<<"POST">>, [<<"orders">>, IdBin, <<"cancel">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            OrderId = binary_to_integer(IdBin),
            case ersub_repo:query(
                "UPDATE payment_orders SET status = 'cancelled' "
                "WHERE id = $1 AND user_id = $2 AND status = 'pending'",
                [OrderId, UserId])
            of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req0, State);
                {ok, 0} ->
                    reply_err(404, <<"Order not found or not cancellable">>, Req0, State);
                {error, R} ->
                    reply_err(500, R, Req0, State)
            end
    end;

%% POST /api/payment/orders/:id/refund-request — user request refund
handle(<<"POST">>, [<<"orders">>, IdBin, <<"refund-request">>], Req0, State) ->
    case verify_user_jwt(Req0) of
        {error, Reason} ->
            reply_auth_error(Reason, Req0, State);
        {ok, #{<<"user_id">> := UserId}} ->
            OrderId = binary_to_integer(IdBin),
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            _Params = jsx:decode(Body, [return_maps]),
            case ersub_repo:query(
                "UPDATE payment_orders SET status = 'refund_requested' "
                "WHERE id = $1 AND user_id = $2 AND status = 'completed'",
                [OrderId, UserId])
            of
                {ok, 1} ->
                    reply_ok(#{success => true}, Req1, State);
                {ok, 0} ->
                    reply_err(404, <<"Order not found or not refundable">>, Req1, State);
                {error, R} ->
                    reply_err(500, R, Req1, State)
            end
    end;

%% === T7-01: Public Payment Verification & Resolve ===

%% POST /api/payment/public/orders/verify -- public order verification (no auth)
handle(<<"POST">>, [<<"public">>, <<"orders">>, <<"verify">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    OrderId = maps:get(<<"order_id">>, Params, 0),
    _Provider = maps:get(<<"provider">>, Params, <<>>),
    case ersub_payment_srv:get_order(to_integer(OrderId)) of
        {ok, #{status := Status}} ->
            Verified = Status =:= <<"paid">>,
            reply_ok(#{verified => Verified, status => Status}, Req1, State);
        {error, not_found} ->
            reply_err(404, <<"Order not found">>, Req1, State)
    end;

%% POST /api/payment/public/orders/resolve -- resolve order by resume token (no auth)
handle(<<"POST">>, [<<"public">>, <<"orders">>, <<"resolve">>], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = jsx:decode(Body, [return_maps]),
    ResumeToken = maps:get(<<"resume_token">>, Params, <<>>),
    case ersub_payment_srv:verify_resume_token(ResumeToken) of
        {ok, OrderId} ->
            case ersub_payment_srv:get_order(OrderId) of
                {ok, Order} ->
                    %% Strip sensitive fields, return safe subset
                    SafeOrder = maps:with(
                        [id, provider, amount_usd, status, created_at], Order),
                    reply_ok(#{data => SafeOrder}, Req1, State);
                {error, not_found} ->
                    reply_err(404, <<"Order not found">>, Req1, State)
            end;
        {error, token_expired} ->
            reply_err(400, <<"Resume token expired">>, Req1, State);
        {error, _} ->
            reply_err(400, <<"Invalid resume token">>, Req1, State)
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

verify_admin_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            case ersub_auth_srv:verify_jwt(string:trim(Token)) of
                {ok, #{<<"role">> := <<"admin">>}} = Ok -> Ok;
                {ok, _} -> {error, not_admin};
                Err -> Err
            end;
        _ -> {error, missing_token}
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
    ContentType  = cowboy_req:header(<<"content-type">>, Req, <<>>),
    IsForm       = binary:match(ContentType,
                                <<"application/x-www-form-urlencoded">>) =/= nomatch,
    WxTimestamp  = cowboy_req:header(<<"wechatpay-timestamp">>, Req, <<>>),
    IsWechat     = Provider =:= <<"wechat">> andalso WxTimestamp =/= <<>>,
    case {Provider, IsForm, IsWechat} of
        {<<"alipay">>, true, _} ->
            handle_alipay_notify(Body);
        {<<"wechat">>, _, true} ->
            handle_wechat_notify(Body, Req);
        {<<"easypay">>, true, _} ->
            handle_easypay_notify(Body);
        _ ->
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
            end
    end.

handle_wechat_notify(Body, Req) ->
    Headers = maps:to_list(cowboy_req:headers(Req)),
    case ersub_wechat:verify_callback(Headers, Body) of
        {error, Reason} ->
            logger:warning("WeChat notify verify failed: ~p", [Reason]),
            {error, Reason};
        {ok, Payload} ->
            TransactionId = maps:get(<<"transaction_id">>, Payload, <<>>),
            OutTradeNo    = maps:get(<<"out_trade_no">>,   Payload, <<>>),
            TradeState    = maps:get(<<"trade_state">>,    Payload, <<>>),
            OrderId       = to_integer(OutTradeNo),
            case TradeState of
                <<"SUCCESS">> ->
                    %% Primary idempotency: order status. Audit log is for trail only.
                    case ersub_payment_srv:get_order(OrderId) of
                        {ok, #{status := <<"paid">>}} ->
                            ok;
                        {ok, _} ->
                            case ersub_payment_srv:fulfill_order(OrderId, TransactionId) of
                                ok ->
                                    ersub_repo:query(
                                        "INSERT INTO payment_audit_logs "
                                        "(order_id, action, idempotency_key) "
                                        "VALUES ($1, 'wechat_notify', $2) "
                                        "ON CONFLICT (idempotency_key) DO NOTHING",
                                        [OrderId, TransactionId]),
                                    ok;
                                {error, order_not_pending} ->
                                    %% Concurrent notify already fulfilled this order.
                                    logger:info("WeChat notify: concurrent fulfill, order=~s",
                                                [OutTradeNo]),
                                    ok;
                                {error, FulfillReason} ->
                                    {error, FulfillReason}
                            end;
                        {error, not_found} ->
                            {error, order_not_found}
                    end;
                _ ->
                    logger:info("WeChat notify: state=~s order=~s", [TradeState, OutTradeNo]),
                    ok
            end
    end.

handle_alipay_notify(Body) ->
    Params = parse_form_body(Body),
    case ersub_alipay:verify_callback(Params) of
        false ->
            logger:warning("Alipay notify: invalid signature"),
            {error, invalid_signature};
        true ->
            NotifyId    = maps:get(<<"notify_id">>,   Params, <<>>),
            TradeStatus = maps:get(<<"trade_status">>, Params, <<>>),
            OutTradeNo  = maps:get(<<"out_trade_no">>, Params, <<>>),
            TradeNo     = maps:get(<<"trade_no">>,     Params, <<>>),
            OrderId     = to_integer(OutTradeNo),
            IdempotencyRes = ersub_repo:query(
                "INSERT INTO payment_audit_logs "
                "(order_id, action, idempotency_key) "
                "VALUES ($1, 'alipay_notify', $2) "
                "ON CONFLICT (idempotency_key) DO NOTHING RETURNING id",
                [OrderId, NotifyId]),
            case IdempotencyRes of
                {ok, 0, _, []} ->
                    ok;
                _ when TradeStatus =:= <<"TRADE_SUCCESS">>;
                       TradeStatus =:= <<"TRADE_FINISHED">> ->
                    case ersub_payment_srv:fulfill_order(OrderId, TradeNo) of
                        ok             -> ok;
                        {error, Reason} -> {error, Reason}
                    end;
                _ ->
                    logger:info("Alipay notify: status=~s order=~s",
                                [TradeStatus, OutTradeNo]),
                    ok
            end
    end.

handle_easypay_notify(Body) ->
    Params = parse_form_body(Body),
    case ersub_easypay:verify_callback(Params) of
        {error, Reason} ->
            logger:warning("EasyPay notify: verify failed: ~p", [Reason]),
            {error, invalid_signature};
        {ok, Verified} ->
            OutTradeNo  = maps:get(<<"out_trade_no">>,  Verified, <<>>),
            TradeNo     = maps:get(<<"trade_no">>,      Verified, <<>>),
            TradeStatus = maps:get(<<"trade_status">>,  Verified, <<>>),
            OrderId     = to_integer(OutTradeNo),
            case {TradeStatus, OrderId, TradeNo} of
                {_, 0, _} ->
                    logger:warning("EasyPay notify: invalid out_trade_no=~s", [OutTradeNo]),
                    {error, invalid_order_id};
                {_, _, <<>>} ->
                    logger:warning("EasyPay notify: empty trade_no order=~s", [OutTradeNo]),
                    {error, missing_trade_no};
                {<<"TRADE_SUCCESS">>, _, _} ->
                    IdempotencyRes = ersub_repo:query(
                        "INSERT INTO payment_audit_logs "
                        "(order_id, action, idempotency_key) "
                        "VALUES ($1, 'easypay_notify', $2) "
                        "ON CONFLICT (idempotency_key) DO NOTHING RETURNING id",
                        [OrderId, TradeNo]),
                    case IdempotencyRes of
                        {ok, 0, _, []} ->
                            ok;
                        _ ->
                            case ersub_payment_srv:fulfill_order(OrderId, TradeNo) of
                                ok              -> ok;
                                {error, order_not_pending} -> ok;
                                {error, FulfillReason} -> {error, FulfillReason}
                            end
                    end;
                _ ->
                    logger:info("EasyPay notify: status=~s order=~s",
                                [TradeStatus, OutTradeNo]),
                    ok
            end
    end.

parse_form_body(Body) ->
    Pairs = binary:split(Body, <<"&">>, [global]),
    lists:foldl(fun(Pair, Acc) ->
        case binary:split(Pair, <<"=">>) of
            [K, V] ->
                DK = safe_percent_decode(K),
                DV = safe_percent_decode(V),
                maps:put(DK, DV, Acc);
            _ ->
                Acc
        end
    end, #{}, Pairs).

safe_percent_decode(B) ->
    case uri_string:percent_decode(B) of
        Decoded when is_binary(Decoded) -> Decoded;
        {error, _, _}                   -> B;
        Decoded                         -> list_to_binary(Decoded)
    end.

verify_webhook_signature(Provider, Body, Req) ->
    Signature = cowboy_req:header(<<"x-webhook-signature">>, Req, <<>>),
    Secret = get_webhook_secret(Provider),
    case {Signature, Secret} of
        {<<>>, <<>>} ->
            false;  %% fail-closed: no signature + no secret → deny
        {<<>>, _} ->
            false;
        {_, <<>>} ->
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
    logger:warning("Payment handler error ~p: ~p", [Status, Reason]),
    Req = reply_json(Status, #{error => #{message => <<"Internal error">>}}, Req0),
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
to_integer(V) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> 0 end;
to_integer(_) -> 0.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
