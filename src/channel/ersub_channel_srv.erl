-module(ersub_channel_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_channel/1, list_channels/1, get_pricing/3, get_model_mapping/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(PRICING_TABLE, ersub_channel_pricing).
-define(MAPPING_TABLE, ersub_channel_mapping).
-define(CACHE_REFRESH_MS, 30000).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Get a channel by ID.
-spec get_channel(integer()) -> {ok, map()} | {error, not_found}.
get_channel(ChannelId) ->
    gen_server:call(?SERVER, {get_channel, ChannelId}).

%% List channels for a group.
-spec list_channels(integer()) -> {ok, [map()]}.
list_channels(GroupId) ->
    gen_server:call(?SERVER, {list_channels, GroupId}).

%% Get pricing for a model via channel override.
%% Key: {GroupId, Platform, Model}
-spec get_pricing(integer(), binary(), binary()) -> {ok, map()} | miss.
get_pricing(GroupId, Platform, Model) ->
    Key = {GroupId, Platform, Model},
    case ets:lookup(?PRICING_TABLE, Key) of
        [{_, Pricing}] -> {ok, Pricing};
        [] ->
            %% Try wildcard
            lookup_wildcard_pricing(GroupId, Platform, Model)
    end.

%% Get model mapping for a channel.
-spec get_model_mapping(integer()) -> map().
get_model_mapping(ChannelId) ->
    case ets:lookup(?MAPPING_TABLE, ChannelId) of
        [{_, Mapping}] -> Mapping;
        [] -> #{}
    end.

%%% gen_server callbacks

init([]) ->
    _ = ets:new(?PRICING_TABLE, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?MAPPING_TABLE, [named_table, public, set, {read_concurrency, true}]),
    refresh_cache(),
    schedule_refresh(),
    logger:info("Channel service started"),
    {ok, #{}}.

handle_call({get_channel, ChannelId}, _From, State) ->
    Result = ersub_repo:query(
        "SELECT id, name, group_id, platform, base_url, model_mapping, "
        "pricing_override, allowed_models, is_active "
        "FROM channels WHERE id = $1", [ChannelId]),
    Reply = case Result of
        {ok, _, [Row]} -> {ok, channel_row_to_map(Row)};
        {ok, _, []} -> {error, not_found};
        {error, R} -> {error, R}
    end,
    {reply, Reply, State};

handle_call({list_channels, GroupId}, _From, State) ->
    Result = ersub_repo:query(
        "SELECT id, name, group_id, platform, base_url, is_active "
        "FROM channels WHERE group_id = $1 AND is_active = TRUE "
        "ORDER BY id", [GroupId]),
    Reply = case Result of
        {ok, _, Rows} ->
            {ok, [#{id => Id, name => N, group_id => GId, platform => P,
                    base_url => BU, is_active => A}
                  || {Id, N, GId, P, BU, A} <- Rows]};
        {error, R} -> {error, R}
    end,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(refresh, State) ->
    refresh_cache(),
    schedule_refresh(),
    {noreply, State}.

%%% Internal

schedule_refresh() ->
    erlang:send_after(?CACHE_REFRESH_MS, self(), refresh).

refresh_cache() ->
    case ersub_repo:squery(
        "SELECT id, group_id, platform, model_mapping, pricing_override "
        "FROM channels WHERE is_active = TRUE"
    ) of
        {ok, _, Rows} ->
            lists:foreach(fun({Id, GroupId, Platform, MappingJson, PricingJson}) ->
                IdInt = binary_to_integer(Id),
                GroupIdInt = binary_to_integer(GroupId),
                %% Cache model mapping
                Mapping = decode_jsonb(MappingJson),
                ets:insert(?MAPPING_TABLE, {IdInt, Mapping}),
                %% Cache pricing override per {GroupId, Platform, Model}
                Pricing = decode_jsonb(PricingJson),
                maps:foreach(fun(Model, PricingEntry) ->
                    Key = {GroupIdInt, Platform, Model},
                    ets:insert(?PRICING_TABLE, {Key, PricingEntry})
                end, Pricing)
            end, Rows);
        {error, Reason} ->
            logger:warning("Failed to refresh channel cache: ~p", [Reason])
    end.

lookup_wildcard_pricing(GroupId, Platform, Model) ->
    %% Scan pricing table for wildcard patterns matching this model
    Pattern = ets:match_object(?PRICING_TABLE, {{GroupId, Platform, '_'}, '_'}),
    case find_wildcard_match(Model, Pattern) of
        {ok, Pricing} -> {ok, Pricing};
        nomatch -> miss
    end.

find_wildcard_match(_Model, []) ->
    nomatch;
find_wildcard_match(Model, [{{_, _, PatternModel}, Pricing} | Rest]) ->
    case binary:match(PatternModel, <<"*">>) of
        {Pos, 1} ->
            Prefix = binary:part(PatternModel, 0, Pos),
            PrefixLen = byte_size(Prefix),
            case Model of
                <<Prefix:PrefixLen/binary, _/binary>> -> {ok, Pricing};
                _ -> find_wildcard_match(Model, Rest)
            end;
        nomatch ->
            find_wildcard_match(Model, Rest)
    end.

channel_row_to_map({Id, Name, GroupId, Platform, BaseUrl,
                    MappingJson, PricingJson, ModelsJson, IsActive}) ->
    #{id => Id, name => Name, group_id => GroupId, platform => Platform,
      base_url => BaseUrl, model_mapping => decode_jsonb(MappingJson),
      pricing_override => decode_jsonb(PricingJson),
      allowed_models => decode_jsonb(ModelsJson), is_active => IsActive}.

decode_jsonb(null) -> #{};
decode_jsonb(<<>>) -> #{};
decode_jsonb(Json) when is_binary(Json) ->
    try jsx:decode(Json, [return_maps])
    catch _:_ -> #{}
    end;
decode_jsonb(_) -> #{}.
