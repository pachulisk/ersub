-module(ersub_request_transform_tests).
-include_lib("eunit/include/eunit.hrl").

exact_mapping_test() ->
    Mapping = #{<<"gpt-4">> => <<"gpt-4-turbo">>,
                <<"claude-3">> => <<"claude-sonnet-4">>},
    ?assertEqual(<<"gpt-4-turbo">>,
        ersub_request_transform:resolve_model_mapping(<<"gpt-4">>, Mapping)),
    ?assertEqual(<<"claude-sonnet-4">>,
        ersub_request_transform:resolve_model_mapping(<<"claude-3">>, Mapping)).

wildcard_mapping_test() ->
    Mapping = #{<<"gpt-*">> => <<"gpt-4o">>},
    ?assertEqual(<<"gpt-4o">>,
        ersub_request_transform:resolve_model_mapping(<<"gpt-4o-mini">>, Mapping)),
    ?assertEqual(<<"gpt-4o">>,
        ersub_request_transform:resolve_model_mapping(<<"gpt-5">>, Mapping)).

no_match_passthrough_test() ->
    Mapping = #{<<"gpt-*">> => <<"gpt-4o">>},
    ?assertEqual(<<"claude-sonnet-4">>,
        ersub_request_transform:resolve_model_mapping(<<"claude-sonnet-4">>, Mapping)).

empty_mapping_test() ->
    ?assertEqual(<<"any-model">>,
        ersub_request_transform:resolve_model_mapping(<<"any-model">>, #{})).

model_chain_test() ->
    Account = #{credentials => #{<<"model_mapping">> =>
        #{<<"gpt-4-turbo">> => <<"gpt-4-turbo-2025">>}}},
    ChannelMapping = #{<<"gpt-4">> => <<"gpt-4-turbo">>},
    {FinalModel, Chain, Source} =
        ersub_request_transform:resolve_model_chain(<<"gpt-4">>, Account, ChannelMapping),
    ?assertEqual(<<"gpt-4-turbo-2025">>, FinalModel),
    ?assertEqual(<<"upstream">>, Source),
    ?assert(binary:match(Chain, <<"gpt-4">>) =/= nomatch).

chain_no_mapping_test() ->
    Account = #{credentials => #{}},
    {Model, Chain, Source} =
        ersub_request_transform:resolve_model_chain(<<"claude-sonnet-4">>, Account, #{}),
    ?assertEqual(<<"claude-sonnet-4">>, Model),
    ?assertEqual(<<"claude-sonnet-4">>, Chain),
    ?assertEqual(<<"original">>, Source).

chain_channel_only_test() ->
    Account = #{credentials => #{}},
    ChannelMapping = #{<<"old-model">> => <<"new-model">>},
    {Model, _Chain, Source} =
        ersub_request_transform:resolve_model_chain(<<"old-model">>, Account, ChannelMapping),
    ?assertEqual(<<"new-model">>, Model),
    ?assertEqual(<<"channel_mapped">>, Source).
