-module(ersub_payment_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([create_order/3, get_order/1, fulfill_order/2,
         redeem_code/2, apply_promo/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Create a payment order.
-spec create_order(integer(), binary(), number()) -> {ok, map()} | {error, term()}.
create_order(UserId, Provider, AmountUsd) ->
    gen_server:call(?SERVER, {create_order, UserId, Provider, AmountUsd}).

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
            {ok, #{id => Id, user_id => UserId, provider => Provider,
                   amount_usd => Amount, status => Status, created_at => CreatedAt}};
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
