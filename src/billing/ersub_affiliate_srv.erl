-module(ersub_affiliate_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_affiliate/1, create_affiliate/2, accrue/3, transfer/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_affiliate(integer()) -> {ok, map()} | {error, not_found}.
get_affiliate(UserId) ->
    gen_server:call(?SERVER, {get, UserId}).

-spec create_affiliate(integer(), float()) -> {ok, map()} | {error, term()}.
create_affiliate(UserId, RebateRate) ->
    gen_server:call(?SERVER, {create, UserId, RebateRate}).

%% Accrue rebate for an inviter when their invitee incurs cost.
-spec accrue(integer(), integer(), float()) -> ok.
accrue(InviteeUserId, InviterUserId, Cost) ->
    gen_server:cast(?SERVER, {accrue, InviteeUserId, InviterUserId, Cost}).

%% Transfer accumulated quota to balance.
-spec transfer(integer(), float()) -> {ok, float()} | {error, term()}.
transfer(UserId, Amount) ->
    gen_server:call(?SERVER, {transfer, UserId, Amount}).

%%% gen_server callbacks

init([]) ->
    logger:info("Affiliate service started"),
    {ok, #{}}.

handle_call({get, UserId}, _From, State) ->
    Reply = case ersub_repo:query(
        "SELECT id, user_id, aff_code, inviter_id, rebate_rate, aff_quota, "
        "aff_history, is_frozen FROM user_affiliates WHERE user_id = $1",
        [UserId]) of
        {ok, _, [{Id, UID, Code, Inv, Rate, Quota, History, Frozen}]} ->
            {ok, #{id => Id, user_id => UID, aff_code => Code,
                   inviter_id => Inv, rebate_rate => Rate,
                   aff_quota => Quota, aff_history => History,
                   is_frozen => Frozen}};
        {ok, _, []} -> {error, not_found};
        {error, R} -> {error, R}
    end,
    {reply, Reply, State};

handle_call({create, UserId, RebateRate}, _From, State) ->
    Code = generate_aff_code(),
    Reply = case ersub_repo:query(
        "INSERT INTO user_affiliates (user_id, aff_code, rebate_rate) "
        "VALUES ($1, $2, $3) RETURNING id, aff_code",
        [UserId, Code, RebateRate]) of
        {ok, 1, _, [{Id, AffCode}]} ->
            {ok, #{id => Id, user_id => UserId, aff_code => AffCode,
                   rebate_rate => RebateRate}};
        {error, R} -> {error, R}
    end,
    {reply, Reply, State};

handle_call({transfer, UserId, Amount}, _From, State) ->
    Reply = case ersub_repo:query(
        "UPDATE user_affiliates SET aff_quota = aff_quota - $2 "
        "WHERE user_id = $1 AND aff_quota >= $2 AND is_frozen = FALSE "
        "RETURNING aff_quota", [UserId, Amount]) of
        {ok, 1, _, [{NewQuota}]} ->
            ersub_repo:update_user_balance(UserId, Amount),
            ersub_repo:query(
                "INSERT INTO user_affiliate_ledger (user_id, action, amount) "
                "VALUES ($1, 'transfer', $2)", [UserId, Amount]),
            {ok, NewQuota};
        {ok, 0, _, []} ->
            {error, insufficient_quota};
        {error, R} -> {error, R}
    end,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({accrue, InviteeUserId, InviterUserId, Cost}, State) ->
    %% Look up inviter's rebate rate
    case ersub_repo:query(
        "SELECT rebate_rate, is_frozen FROM user_affiliates WHERE user_id = $1",
        [InviterUserId]) of
        {ok, _, [{Rate, false}]} ->
            Rebate = Cost * to_float(Rate),
            ersub_repo:query(
                "UPDATE user_affiliates SET aff_quota = aff_quota + $2, "
                "aff_history = aff_history + $2 WHERE user_id = $1",
                [InviterUserId, Rebate]),
            ersub_repo:query(
                "INSERT INTO user_affiliate_ledger "
                "(user_id, action, amount, related_user_id) "
                "VALUES ($1, 'accrue', $2, $3)",
                [InviterUserId, Rebate, InviteeUserId]);
        _ -> ok
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

generate_aff_code() ->
    iolist_to_binary([<<"AFF-">>, binary:encode_hex(crypto:strong_rand_bytes(6))]).

to_float(V) when is_binary(V) ->
    try binary_to_float(V) catch _:_ ->
        try binary_to_integer(V) * 1.0 catch _:_ -> 0.0 end
    end;
to_float(V) when is_float(V) -> V;
to_float(V) when is_integer(V) -> V * 1.0;
to_float(_) -> 0.0.
