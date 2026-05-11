-module(ersub_usage_logger).
-behaviour(gen_server).

-export([start_link/0]).
-export([log/1, flush/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(FLUSH_INTERVAL_MS, 5000).
-define(MAX_BATCH_SIZE, 100).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Asynchronously log a usage record.
-spec log(map()) -> ok.
log(UsageRecord) ->
    gen_server:cast(?SERVER, {log, UsageRecord}).

%% Force flush pending records to database.
-spec flush() -> ok.
flush() ->
    gen_server:call(?SERVER, flush, 15000).

%%% gen_server callbacks

init([]) ->
    schedule_flush(),
    {ok, #{buffer => [], count => 0}}.

handle_call(flush, _From, State) ->
    NewState = do_flush(State),
    {reply, ok, NewState};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({log, Record}, #{buffer := Buf, count := Count} = State) ->
    NewState = State#{buffer => [Record | Buf], count => Count + 1},
    case Count + 1 >= ?MAX_BATCH_SIZE of
        true -> {noreply, do_flush(NewState)};
        false -> {noreply, NewState}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(flush_timer, State) ->
    NewState = do_flush(State),
    schedule_flush(),
    {noreply, NewState}.

terminate(_Reason, State) ->
    do_flush(State),
    ok.

%%% Internal

schedule_flush() ->
    erlang:send_after(?FLUSH_INTERVAL_MS, self(), flush_timer).

do_flush(#{buffer := [], count := 0} = State) ->
    State;
do_flush(#{buffer := Buf, count := Count} = State) ->
    Records = lists:reverse(Buf),
    case insert_usage_records(Records) of
        ok ->
            logger:debug("Flushed ~p usage records", [Count]);
        {error, Reason} ->
            logger:error("Failed to flush ~p usage records: ~p", [Count, Reason])
    end,
    State#{buffer => [], count => 0}.

insert_usage_records([]) ->
    ok;
insert_usage_records([Record | Rest]) ->
    case insert_single_record(Record) of
        ok -> insert_usage_records(Rest);
        {error, _} = Err -> Err
    end.

insert_single_record(R) ->
    SQL = "INSERT INTO usage_logs ("
          "user_id, api_key_id, account_id, group_id, request_id, "
          "requested_model, upstream_model, "
          "input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, "
          "input_cost, output_cost, cache_read_cost, cache_creation_cost, "
          "total_cost, actual_cost, rate_multiplier, "
          "service_tier, billing_mode, request_type, stream, "
          "duration_ms, first_token_ms, user_agent, ip_address, "
          "model_mapping_chain, billing_model_source"
          ") VALUES ("
          "$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, "
          "$12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, "
          "$23, $24, $25, $26::inet, $27, $28"
          ")",
    Params = [
        maps:get(user_id, R),
        maps:get(api_key_id, R, null),
        maps:get(account_id, R),
        maps:get(group_id, R, null),
        maps:get(request_id, R),
        maps:get(requested_model, R),
        maps:get(upstream_model, R, null),
        maps:get(input_tokens, R, 0),
        maps:get(output_tokens, R, 0),
        maps:get(cache_read_tokens, R, 0),
        maps:get(cache_creation_tokens, R, 0),
        maps:get(input_cost, R, 0),
        maps:get(output_cost, R, 0),
        maps:get(cache_read_cost, R, 0),
        maps:get(cache_creation_cost, R, 0),
        maps:get(total_cost, R, 0),
        maps:get(actual_cost, R, 0),
        maps:get(rate_multiplier, R, null),
        maps:get(service_tier, R, null),
        maps:get(billing_mode, R, null),
        maps:get(request_type, R, 0),
        maps:get(stream, R, false),
        maps:get(duration_ms, R, null),
        maps:get(first_token_ms, R, null),
        maps:get(user_agent, R, null),
        maps:get(ip_address, R, null),
        maps:get(model_mapping_chain, R, null),
        maps:get(billing_model_source, R, null)
    ],
    case ersub_repo:query(SQL, Params) of
        {ok, 1} -> ok;
        {ok, 1, _, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.
