-module(ersub_payment_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([create_order/3, get_order/1, fulfill_order/2,
         redeem_code/2, apply_promo/2]).
-export([request_refund/1, process_refund/1]).
-export([generate_resume_token/1, verify_resume_token/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Create a payment order.
-spec create_order(integer(), binary(), number()) -> {ok, map()} | {error, term()}.
create_order(UserId, Provider, AmountUsd) ->
    gen_server:call(?SERVER, {create_order, UserId, Provider, AmountUsd}, 30000).

%% Get order status.
-spec get_order(integer()) -> {ok, map()} | {error, not_found}.
get_order(OrderId) ->
    gen_server:call(?SERVER, {get_order, OrderId}).

%% Fulfill a payment (credit user balance).
-spec fulfill_order(integer(), binary()) -> ok | {error, term()}.
fulfill_order(OrderId, ProviderOrderId) ->
    gen_server:call(?SERVER, {fulfill, OrderId, ProviderOrderId}).

%% Redeem a code for balance credit.
-spec redeem_code(integer(), binary()) -> {ok, number()} | {error, term()}.
redeem_code(UserId, Code) ->
    gen_server:call(?SERVER, {redeem, UserId, Code}).

%% Apply a promo code discount.
-spec apply_promo(integer(), binary()) -> {ok, map()} | {error, term()}.
apply_promo(UserId, Code) ->
    gen_server:call(?SERVER, {promo, UserId, Code}).

%% P02: Request a refund — transitions paid→refund_requested.
-spec request_refund(integer()) -> ok | {error, term()}.
request_refund(OrderId) ->
    gen_server:call(?SERVER, {request_refund, OrderId}).

%% P02: Process a refund — transitions refund_requested→refunding→refunded.
-spec process_refund(integer()) -> ok | {error, term()}.
process_refund(OrderId) ->
    gen_server:call(?SERVER, {process_refund, OrderId}).

%% P03: Generate a resume token for an order (HMAC-SHA256 signed).
-spec generate_resume_token(integer()) -> {ok, binary()}.
generate_resume_token(OrderId) ->
    Timestamp = integer_to_binary(erlang:system_time(second)),
    OrderIdBin = integer_to_binary(OrderId),
    Payload = <<OrderIdBin/binary, ":", Timestamp/binary>>,
    Secret = get_jwt_secret(),
    Sig = crypto:mac(hmac, sha256, Secret, Payload),
    SigHex = binary:encode_hex(Sig),
    Token = <<Payload/binary, ":", SigHex/binary>>,
    {ok, Token}.

%% P03: Verify a resume token. Returns {ok, OrderId} or {error, Reason}.
-spec verify_resume_token(binary()) -> {ok, integer()} | {error, term()}.
verify_resume_token(Token) ->
    case binary:split(Token, <<":">>, [global]) of
        [OrderIdBin, Timestamp, SigHex] ->
            Payload = <<OrderIdBin/binary, ":", Timestamp/binary>>,
            Secret = get_jwt_secret(),
            ExpectedSig = crypto:mac(hmac, sha256, Secret, Payload),
            ExpectedHex = binary:encode_hex(ExpectedSig),
            case crypto:hash_equals(ExpectedHex, SigHex) of
                true ->
                    %% Check expiry (1 hour)
                    Now = erlang:system_time(second),
                    TS = binary_to_integer(Timestamp),
                    case Now - TS < 3600 of
                        true -> {ok, binary_to_integer(OrderIdBin)};
                        false -> {error, token_expired}
                    end;
                false ->
                    {error, invalid_signature}
            end;
        _ ->
            {error, invalid_token_format}
    end.

%%% gen_server callbacks

init([]) ->
    logger:info("Payment service started"),
    {ok, #{}}.

handle_call({create_order, UserId, Provider, Amount}, _From, State) ->
    Result = ersub_repo:query(
        "INSERT INTO payment_orders (user_id, provider, amount_usd) "
        "VALUES ($1, $2, $3) RETURNING id, status, created_at",
        [UserId, Provider, Amount]),
    Reply = case Result of
        {ok, 1, _, [{Id, Status, CreatedAt}]} ->
            Order0 = #{id => Id, user_id => UserId, provider => Provider,
                       amount_usd => Amount, status => Status,
                       created_at => CreatedAt},
            {CheckoutUrl, Order1} = maybe_init_checkout(Id, Provider, Amount, Order0),
            {ok, Order1#{checkout_url => CheckoutUrl}};
        {error, Reason} -> {error, Reason}
    end,
    {reply, Reply, State};

handle_call({get_order, OrderId}, _From, State) ->
    Result = ersub_repo:query(
        "SELECT id, user_id, provider, amount_usd, status, provider_order_id, "
        "created_at FROM payment_orders WHERE id = $1", [OrderId]),
    Reply = case Result of
        {ok, _, [{Id, UID, Prov, Amt, St, POId, CA}]} ->
            {ok, #{id => Id, user_id => UID, provider => Prov,
                   amount_usd => Amt, status => St,
                   provider_order_id => POId, created_at => CA}};
        {ok, _, []} -> {error, not_found};
        {error, R} -> {error, R}
    end,
    {reply, Reply, State};

handle_call({fulfill, OrderId, ProviderOrderId}, _From, State) ->
    %% Update order status and credit balance
    Reply = case ersub_repo:query(
        "UPDATE payment_orders SET status = 'paid', provider_order_id = $2, "
        "updated_at = NOW() WHERE id = $1 AND status = 'pending' "
        "RETURNING user_id, amount_usd", [OrderId, ProviderOrderId])
    of
        {ok, 1, _, [{UserId, Amount}]} ->
            AmtFloat = to_float(Amount),
            ersub_repo:update_user_balance(UserId, AmtFloat),
            %% Invalidate cached balance
            ersub_billing_srv:sync_balance(UserId),
            logger:info("Order ~p fulfilled: user=~p amount=~p", [OrderId, UserId, AmtFloat]),
            ok;
        {ok, 0, _, []} ->
            {error, order_not_pending};
        {error, R} ->
            {error, R}
    end,
    {reply, Reply, State};

handle_call({redeem, UserId, Code}, _From, State) ->
    Reply = case ersub_repo:query(
        "UPDATE redeem_codes SET is_used = TRUE, used_by = $1, used_at = NOW() "
        "WHERE code = $2 AND is_used = FALSE RETURNING amount_usd",
        [UserId, Code])
    of
        {ok, 1, _, [{Amount}]} ->
            AmtFloat = to_float(Amount),
            ersub_repo:update_user_balance(UserId, AmtFloat),
            ersub_billing_srv:sync_balance(UserId),
            logger:info("Redeem code ~s: user=~p amount=~p", [Code, UserId, AmtFloat]),
            {ok, AmtFloat};
        {ok, 0, _, []} ->
            {error, invalid_or_used_code};
        {error, R} ->
            {error, R}
    end,
    {reply, Reply, State};

handle_call({promo, UserId, Code}, _From, State) ->
    Reply = case ersub_repo:query(
        "SELECT id, discount_type, discount_value, max_uses, current_uses, "
        "valid_from, valid_until, is_active FROM promo_codes WHERE code = $1",
        [Code])
    of
        {ok, _, [{PId, DType, DVal, MaxUses, CurUses, _VFrom, _VUntil, IsActive}]} ->
            case IsActive andalso (MaxUses =:= 0 orelse CurUses < MaxUses) of
                true ->
                    %% Check if already used by this user
                    case ersub_repo:query(
                        "SELECT 1 FROM promo_code_usage WHERE promo_code_id = $1 AND user_id = $2",
                        [PId, UserId])
                    of
                        {ok, _, []} ->
                            %% Record usage
                            ersub_repo:query(
                                "INSERT INTO promo_code_usage (promo_code_id, user_id) VALUES ($1, $2)",
                                [PId, UserId]),
                            ersub_repo:query(
                                "UPDATE promo_codes SET current_uses = current_uses + 1 WHERE id = $1",
                                [PId]),
                            {ok, #{discount_type => DType, discount_value => DVal}};
                        {ok, _, [_]} ->
                            {error, already_used};
                        {error, R} ->
                            {error, R}
                    end;
                false ->
                    {error, code_inactive_or_exhausted}
            end;
        {ok, _, []} ->
            {error, not_found};
        {error, R} ->
            {error, R}
    end,
    {reply, Reply, State};

%% P02: Request refund — paid→refund_requested (via CLIPS rules)
handle_call({request_refund, OrderId}, _From, State) ->
    Reply = case ersub_repo:query(
        "SELECT id, status, amount_usd, user_id FROM payment_orders WHERE id = $1",
        [OrderId])
    of
        {ok, _, [{_Id, Status, Amount, _UserId}]} ->
            StatusBin = ensure_binary(Status),
            AmtFloat = to_float(Amount),
            %% Use CLIPS to evaluate refund transition
            case ersub_clips_pool:evaluate_refund_transition(#{
                order_id => OrderId,
                current_status => StatusBin,
                requested_action => <<"request_refund">>,
                amount => AmtFloat
            }) of
                {ok, #{<<"allowed">> := true}} ->
                    case ersub_repo:query(
                        "UPDATE payment_orders SET status = 'refund_requested', "
                        "updated_at = NOW() WHERE id = $1 AND status = 'paid' "
                        "RETURNING id", [OrderId])
                    of
                        {ok, 1, _, [_]} -> ok;
                        {ok, 0, _, []} -> {error, invalid_status_transition};
                        {error, R} -> {error, R}
                    end;
                {ok, #{<<"allowed">> := false, <<"reason">> := Reason}} ->
                    {error, {refund_denied, Reason}};
                {ok, _} ->
                    %% Fallback: allow if status is paid
                    case StatusBin of
                        <<"paid">> ->
                            case ersub_repo:query(
                                "UPDATE payment_orders SET status = 'refund_requested', "
                                "updated_at = NOW() WHERE id = $1 AND status = 'paid' "
                                "RETURNING id", [OrderId])
                            of
                                {ok, 1, _, [_]} -> ok;
                                {ok, 0, _, []} -> {error, invalid_status_transition};
                                {error, R} -> {error, R}
                            end;
                        _ -> {error, invalid_status_transition}
                    end;
                {error, ClipsErr} ->
                    logger:error("CLIPS refund evaluation failed: ~p", [ClipsErr]),
                    {error, {clips_error, ClipsErr}}
            end;
        {ok, _, []} ->
            {error, not_found};
        {error, R} ->
            {error, R}
    end,
    {reply, Reply, State};

%% P02: Process refund — refund_requested→refunding→refunded (via CLIPS rules)
handle_call({process_refund, OrderId}, _From, State) ->
    Reply = case ersub_repo:query(
        "SELECT id, status, amount_usd, user_id FROM payment_orders WHERE id = $1",
        [OrderId])
    of
        {ok, _, [{_Id, Status, Amount, UserId}]} ->
            StatusBin = ensure_binary(Status),
            AmtFloat = to_float(Amount),
            case ersub_clips_pool:evaluate_refund_transition(#{
                order_id => OrderId,
                current_status => StatusBin,
                requested_action => <<"process_refund">>,
                amount => AmtFloat
            }) of
                {ok, #{<<"allowed">> := true}} ->
                    do_process_refund(OrderId, UserId, AmtFloat);
                {ok, #{<<"allowed">> := false, <<"reason">> := Reason}} ->
                    {error, {refund_denied, Reason}};
                {ok, _} ->
                    %% Fallback: allow if status is refund_requested
                    case StatusBin of
                        <<"refund_requested">> ->
                            do_process_refund(OrderId, UserId, AmtFloat);
                        _ ->
                            {error, invalid_status_transition}
                    end;
                {error, ClipsErr} ->
                    logger:error("CLIPS refund evaluation failed: ~p", [ClipsErr]),
                    {error, {clips_error, ClipsErr}}
            end;
        {ok, _, []} ->
            {error, not_found};
        {error, R} ->
            {error, R}
    end,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

to_float(V) when is_binary(V) ->
    try binary_to_float(V) catch _:_ ->
        try binary_to_integer(V) * 1.0 catch _:_ -> 0.0 end
    end;
to_float(V) when is_float(V) -> V;
to_float(V) when is_integer(V) -> V * 1.0;
to_float(_) -> 0.0.

maybe_init_checkout(OrderId, <<"alipay">>, AmountUsd, Order) ->
    case ersub_alipay:is_available() of
        false -> {null, Order};
        true  ->
            Cfg = case ersub_clips_pool:get_alipay_config() of
                {ok, C} -> C;
                _       -> #{}
            end,
            Rate     = get_float(maps:get(<<"usd-to-cny-rate">>, Cfg, 7.20)),
            AmtCny   = to_float(AmountUsd) * Rate,
            Meta     = jsx:encode(#{cny_amount => AmtCny, cny_rate => Rate}),
            ersub_repo:query(
                "UPDATE payment_orders SET metadata = $2 WHERE id = $1",
                [OrderId, Meta]),
            case ersub_alipay:create_page_pay(
                    integer_to_binary(OrderId), AmtCny, <<"ErSub Balance Top-up">>) of
                {ok, #{checkout_url := Url}} -> {Url, Order};
                {error, _}                  -> {null, Order}
            end
    end;
maybe_init_checkout(OrderId, <<"stripe">>, AmountUsd, Order) ->
    UserId     = maps:get(user_id, Order, 0),
    SuccessUrl = ersub_config_srv:get(payment_stripe_success_url, <<>>),
    case ersub_stripe:create_checkout_session(UserId, to_float(AmountUsd), ensure_binary(SuccessUrl)) of
        {ok, #{session_id := SessionId, url := Url}} ->
            ersub_repo:query(
                "UPDATE payment_orders SET provider_order_id = $2 WHERE id = $1",
                [OrderId, SessionId]),
            {Url, Order};
        {error, _} ->
            {null, Order}
    end;
maybe_init_checkout(OrderId, <<"wechat">>, AmountUsd, Order) ->
    case ersub_wechat:is_available() of
        false -> {null, Order};
        true  ->
            Cfg = case ersub_clips_pool:get_wechat_config() of
                {ok, C} -> C;
                _       -> #{}
            end,
            Rate     = get_float(maps:get(<<"usd-to-cny-rate">>, Cfg, 7.20)),
            AmtCny   = to_float(AmountUsd) * Rate,
            AmtFen   = round(AmtCny * 100),
            Meta     = jsx:encode(#{cny_amount => AmtCny, cny_rate => Rate,
                                    fen => AmtFen}),
            ersub_repo:query(
                "UPDATE payment_orders SET metadata = $2 WHERE id = $1",
                [OrderId, Meta]),
            case ersub_wechat:create_native_order(
                    integer_to_binary(OrderId), AmtFen,
                    <<"ErSub Balance Top-up">>) of
                {ok, #{code_url := Url}} -> {Url, Order};
                {error, _}              -> {null, Order}
            end
    end;
maybe_init_checkout(_OrderId, _Provider, _Amount, Order) ->
    {null, Order}.

do_process_refund(OrderId, UserId, AmtFloat) ->
    ProviderResult = ersub_repo:query(
        "SELECT provider, metadata FROM payment_orders WHERE id = $1",
        [OrderId]),
    case ProviderResult of
        {ok, _, [{Provider, Meta}]} ->
            ProviderBin = ensure_binary(Provider),
            case ProviderBin of
                <<"alipay">> ->
                    MetaMap  = safe_decode_meta(Meta),
                    AmtCny   = get_float(maps:get(<<"cny_amount">>, MetaMap,
                                                  AmtFloat * 7.20)),
                    case ersub_alipay:refund(integer_to_binary(OrderId), AmtCny) of
                        ok              -> do_internal_refund(OrderId, UserId, AmtFloat);
                        {error, Reason} -> {error, Reason}
                    end;
                <<"wechat">> ->
                    MetaMap = safe_decode_meta(Meta),
                    Rate    = get_float(maps:get(<<"cny_rate">>, MetaMap, 7.20)),
                    AmtFen  = case maps:get(<<"fen">>, MetaMap, undefined) of
                        undefined -> round(AmtFloat * Rate * 100);
                        F         -> round(get_float(F))
                    end,
                    case ersub_wechat:refund(integer_to_binary(OrderId), AmtFen) of
                        ok              -> do_internal_refund(OrderId, UserId, AmtFloat);
                        {error, Reason} -> {error, Reason}
                    end;
                _ ->
                    do_internal_refund(OrderId, UserId, AmtFloat)
            end;
        _ ->
            do_internal_refund(OrderId, UserId, AmtFloat)
    end.

do_internal_refund(OrderId, UserId, AmtFloat) ->
    case ersub_repo:query(
        "UPDATE payment_orders SET status = 'refunding', updated_at = NOW() "
        "WHERE id = $1 AND status = 'refund_requested' RETURNING id",
        [OrderId])
    of
        {ok, 1, _, [_]} ->
            ersub_repo:update_user_balance(UserId, AmtFloat),
            ersub_billing_srv:sync_balance(UserId),
            case ersub_repo:query(
                "UPDATE payment_orders SET status = 'refunded', updated_at = NOW() "
                "WHERE id = $1 AND status = 'refunding' RETURNING id",
                [OrderId])
            of
                {ok, 1, _, [_]} ->
                    logger:info("Refund completed: order=~p user=~p amount=~p",
                                [OrderId, UserId, AmtFloat]),
                    ok;
                {ok, 0, _, []} -> {error, refund_finalize_failed};
                {error, R}     -> {error, R}
            end;
        {ok, 0, _, []} -> {error, invalid_status_transition};
        {error, R}     -> {error, R}
    end.

safe_decode_meta(null) -> #{};
safe_decode_meta(undefined) -> #{};
safe_decode_meta(Meta) when is_binary(Meta) ->
    try jsx:decode(Meta, [return_maps])
    catch _:_ -> #{}
    end;
safe_decode_meta(_) -> #{}.

get_float(V) when is_float(V)   -> V;
get_float(V) when is_integer(V) -> V * 1.0;
get_float(V) when is_binary(V)  ->
    try binary_to_float(V)
    catch _:_ -> try binary_to_integer(V) * 1.0 catch _:_ -> 7.20 end
    end;
get_float(_) -> 7.20.

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V)   -> list_to_binary(V);
ensure_binary(V) when is_atom(V)   -> atom_to_binary(V);
ensure_binary(_)                   -> <<>>.

get_jwt_secret() ->
    case ersub_config_srv:get(auth_jwt_secret, <<>>) of
        <<>> -> error({fatal_config, jwt_secret_not_set});
        S when is_list(S)   -> list_to_binary(S);
        S when is_binary(S) -> S
    end.

