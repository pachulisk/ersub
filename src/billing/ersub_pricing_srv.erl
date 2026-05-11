-module(ersub_pricing_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_pricing/1, get_all/0, update_from_url/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(TABLE, ersub_pricing_table).
-define(UPDATE_INTERVAL_MS, 3600000). %% 1 hour

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_pricing(binary()) -> {ok, map()} | {error, not_found}.
get_pricing(Model) ->
    case ets:lookup(?TABLE, Model) of
        [{_, Pricing}] -> {ok, Pricing};
        [] -> {error, not_found}
    end.

-spec get_all() -> map().
get_all() ->
    maps:from_list([{K, V} || {K, V} <- ets:tab2list(?TABLE)]).

-spec update_from_url() -> ok | {error, term()}.
update_from_url() ->
    gen_server:call(?SERVER, update, 30000).

%%% gen_server callbacks

init([]) ->
    ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    load_embedded_fallback(),
    schedule_update(),
    logger:info("Pricing service started with ~p models", [ets:info(?TABLE, size)]),
    {ok, #{}}.

handle_call(update, _From, State) ->
    Result = do_update(),
    {reply, Result, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(update_timer, State) ->
    do_update(),
    schedule_update(),
    {noreply, State}.

%%% Internal

schedule_update() ->
    erlang:send_after(?UPDATE_INTERVAL_MS, self(), update_timer).

do_update() ->
    case ersub_config_srv:get(billing_pricing_update_url, undefined) of
        undefined -> ok;
        Url when is_list(Url); is_binary(Url) ->
            case fetch_and_parse(Url) of
                {ok, Count} ->
                    logger:info("Pricing updated: ~p models", [Count]),
                    ok;
                {error, Reason} ->
                    logger:warning("Pricing update failed: ~p", [Reason]),
                    {error, Reason}
            end;
        _ -> ok
    end.

fetch_and_parse(Url) when is_list(Url) ->
    fetch_and_parse(list_to_binary(Url));
fetch_and_parse(Url) when is_binary(Url) ->
    case ersub_upstream_pool:request(<<"GET">>, Url, [], <<>>, #{}, 15000) of
        {ok, 200, _, Body} ->
            parse_litellm_pricing(Body);
        {ok, Status, _, _} ->
            {error, {http_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

parse_litellm_pricing(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        Count = maps:fold(fun(ModelName, Info, Acc) when is_map(Info) ->
            Pricing = #{
                input_price => maps:get(<<"input_cost_per_token">>, Info, 0),
                output_price => maps:get(<<"output_cost_per_token">>, Info, 0),
                cache_read_price => maps:get(<<"cache_read_input_token_cost">>, Info, 0),
                cache_creation_price => maps:get(<<"cache_creation_input_token_cost">>, Info, 0),
                supports_prompt_caching => maps:get(<<"supports_prompt_caching">>, Info, false)
            },
            ets:insert(?TABLE, {ModelName, Pricing}),
            Acc + 1;
        (_, _, Acc) -> Acc
        end, 0, Json),
        {ok, Count}
    catch _:Reason ->
        {error, {parse_failed, Reason}}
    end.

load_embedded_fallback() ->
    Fallback = embedded_pricing(),
    maps:foreach(fun(Model, Pricing) ->
        ets:insert(?TABLE, {Model, Pricing})
    end, Fallback).

embedded_pricing() ->
    #{
        <<"claude-sonnet-4-20250514">> => #{
            input_price => 0.000003,
            output_price => 0.000015,
            cache_read_price => 0.0000003,
            cache_creation_price => 0.00000375,
            supports_prompt_caching => true
        },
        <<"claude-opus-4-20250514">> => #{
            input_price => 0.000015,
            output_price => 0.000075,
            cache_read_price => 0.0000015,
            cache_creation_price => 0.00001875,
            supports_prompt_caching => true
        },
        <<"claude-haiku-3-5-20241022">> => #{
            input_price => 0.0000008,
            output_price => 0.000004,
            cache_read_price => 0.00000008,
            cache_creation_price => 0.000001,
            supports_prompt_caching => true
        },
        <<"gpt-4o">> => #{
            input_price => 0.0000025,
            output_price => 0.00001,
            cache_read_price => 0.00000125,
            supports_prompt_caching => true
        },
        <<"gpt-4o-mini">> => #{
            input_price => 0.00000015,
            output_price => 0.0000006,
            supports_prompt_caching => false
        },
        <<"gemini-2.5-pro">> => #{
            input_price => 0.00000125,
            output_price => 0.00001,
            supports_prompt_caching => true
        }
    }.
