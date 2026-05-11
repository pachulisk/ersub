-module(ersub_billing_helper).

-export([record_non_streaming_usage/4]).

%% Record usage and deduct billing for a non-streaming response.
%% Parses the upstream response body for token usage, logs to usage_logs,
%% and deducts from user balance.
-spec record_non_streaming_usage(map(), integer(), binary(), binary()) -> ok.

record_non_streaming_usage(AuthCtx, AccountId, ResponseBody, RequestedModel) ->
    #{user_id := UserId, key_id := KeyId} = AuthCtx,
    Usage = extract_usage(ResponseBody),
    InputTokens = maps:get(input_tokens, Usage, 0),
    OutputTokens = maps:get(output_tokens, Usage, 0),
    CacheReadTokens = maps:get(cache_read_tokens, Usage, 0),
    CacheCreationTokens = maps:get(cache_creation_tokens, Usage, 0),

    %% Calculate cost from pricing table
    ActualCost = calculate_cost(RequestedModel, Usage),

    %% Deduct balance
    case ActualCost > 0 of
        true -> ersub_billing_srv:deduct(UserId, ActualCost);
        false -> ok
    end,

    %% Check billing dedup
    RequestId = generate_request_id(),
    case ersub_billing_dedup:check_and_mark(RequestId) of
        {error, already_billed} -> ok;
        ok ->
            %% Log usage record
            ersub_usage_logger:log(#{
                user_id => UserId,
                api_key_id => KeyId,
                account_id => AccountId,
                request_id => RequestId,
                requested_model => RequestedModel,
                input_tokens => InputTokens,
                output_tokens => OutputTokens,
                cache_read_tokens => CacheReadTokens,
                cache_creation_tokens => CacheCreationTokens,
                total_cost => ActualCost,
                actual_cost => ActualCost,
                stream => false,
                request_type => 1  %% sync
            })
    end,
    ok.

%%% Internal

extract_usage(Body) when is_binary(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        extract_usage_from_json(Json)
    catch _:_ ->
        #{}
    end;
extract_usage(_) ->
    #{}.

%% Anthropic format
extract_usage_from_json(#{<<"usage">> := U}) when is_map(U) ->
    #{
        input_tokens => maps:get(<<"input_tokens">>, U, 0),
        output_tokens => maps:get(<<"output_tokens">>, U, 0),
        cache_read_tokens => maps:get(<<"cache_read_input_tokens">>, U, 0),
        cache_creation_tokens => maps:get(<<"cache_creation_input_tokens">>, U, 0)
    };
%% OpenAI format
extract_usage_from_json(#{<<"usage">> := #{<<"prompt_tokens">> := PT,
                                           <<"completion_tokens">> := CT}}) ->
    #{input_tokens => PT, output_tokens => CT};
extract_usage_from_json(_) ->
    #{}.

calculate_cost(Model, Usage) ->
    InputTokens = maps:get(input_tokens, Usage, 0),
    OutputTokens = maps:get(output_tokens, Usage, 0),
    case ersub_pricing_srv:get_pricing(Model) of
        {ok, Pricing} ->
            IP = maps:get(input_price, Pricing, 0),
            OP = maps:get(output_price, Pricing, 0),
            InputTokens * IP + OutputTokens * OP;
        {error, _} ->
            0
    end.

generate_request_id() ->
    iolist_to_binary([<<"req-">>, binary:encode_hex(crypto:strong_rand_bytes(8))]).
