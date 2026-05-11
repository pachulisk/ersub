-module(ersub_billing_helper).

-export([record_non_streaming_usage/4]).

%% Record usage and deduct billing for a non-streaming response.
%% Uses CLIPS billing.clp rules for cost calculation.
-spec record_non_streaming_usage(map(), integer(), binary(), binary()) -> ok.

record_non_streaming_usage(AuthCtx, AccountId, ResponseBody, RequestedModel) ->
    #{user_id := UserId, key_id := KeyId} = AuthCtx,
    Usage = extract_usage(ResponseBody),
    InputTokens = maps:get(input_tokens, Usage, 0),
    OutputTokens = maps:get(output_tokens, Usage, 0),
    CacheReadTokens = maps:get(cache_read_tokens, Usage, 0),
    CacheCreationTokens = maps:get(cache_creation_tokens, Usage, 0),

    %% Calculate cost via CLIPS billing.clp rules
    ActualCost = calculate_cost_clips(RequestedModel, Usage),

    case ActualCost > 0 of
        true -> ersub_billing_srv:deduct(UserId, ActualCost);
        false -> ok
    end,

    RequestId = generate_request_id(),
    case ersub_billing_dedup:check_and_mark(RequestId) of
        {error, already_billed} -> ok;
        ok ->
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
                request_type => 1
            })
    end,
    ok.

%%% Internal

extract_usage(Body) when is_binary(Body) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        extract_usage_from_json(Json)
    catch _:_ -> #{}
    end;
extract_usage(_) -> #{}.

extract_usage_from_json(#{<<"usage">> := U} = Json) when is_map(U) ->
    ServiceTier = case maps:get(<<"service_tier">>, Json, undefined) of
        undefined -> standard;
        <<"priority">> -> priority;
        <<"flex">> -> flex;
        _ -> standard
    end,
    %% Image size detection from response data
    ImageSize = case maps:get(<<"data">>, Json, undefined) of
        [#{<<"size">> := S} | _] -> S;
        _ -> undefined
    end,
    #{
        input_tokens => maps:get(<<"input_tokens">>, U, 0),
        output_tokens => maps:get(<<"output_tokens">>, U, 0),
        cache_read_tokens => maps:get(<<"cache_read_input_tokens">>, U, 0),
        cache_creation_tokens => maps:get(<<"cache_creation_input_tokens">>, U, 0),
        cache_5m_tokens => maps:get(<<"cache_creation_5m_tokens">>, U, 0),
        cache_1h_tokens => maps:get(<<"cache_creation_1h_tokens">>, U, 0),
        service_tier => ServiceTier,
        image_size => ImageSize
    };
extract_usage_from_json(#{<<"usage">> := #{<<"prompt_tokens">> := PT,
                                           <<"completion_tokens">> := CT}}) ->
    #{input_tokens => PT, output_tokens => CT};
extract_usage_from_json(_) -> #{}.

%% Calculate cost via CLIPS billing.clp rules engine
calculate_cost_clips(Model, Usage) ->
    ClipsUsage = #{
        model => Model,
        input_tokens => maps:get(input_tokens, Usage, 0),
        output_tokens => maps:get(output_tokens, Usage, 0),
        cache_read_tokens => maps:get(cache_read_tokens, Usage, 0),
        cache_5m_tokens => maps:get(cache_5m_tokens, Usage, 0),
        cache_1h_tokens => maps:get(cache_1h_tokens, Usage, 0),
        image_output_tokens => maps:get(image_output_tokens, Usage, 0),
        service_tier => maps:get(service_tier, Usage, standard),
        account_rate_mult => maps:get(account_rate_mult, Usage, 1.0),
        group_rate_mult => maps:get(group_rate_mult, Usage, 1.0),
        total_input_tokens => maps:get(input_tokens, Usage, 0),
        billing_mode => maps:get(billing_mode, Usage, token)
    },
    case ersub_clips_pool:calculate_billing(ClipsUsage) of
        {ok, Result} ->
            maps:get(<<"actual-cost">>, Result, 0.0);
        {error, _Reason} ->
            0
    end.

generate_request_id() ->
    iolist_to_binary([<<"req-">>, binary:encode_hex(crypto:strong_rand_bytes(8))]).
