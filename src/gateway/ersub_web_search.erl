-module(ersub_web_search).
-export([detect_web_search/1, emulate_search_result/1]).

%% Detect if a parsed request body contains web_search tool usage.
-spec detect_web_search(map()) -> {boolean(), binary()}.
detect_web_search(Parsed) ->
    Tools = maps:get(<<"tools">>, Parsed, []),
    case find_web_search_tool(Tools) of
        {true, Query} -> {true, Query};
        false -> {false, <<>>}
    end.

%% Generate a synthesized web search result block for emulation.
-spec emulate_search_result(binary()) -> map().
emulate_search_result(Query) ->
    #{
        <<"type">> => <<"tool_result">>,
        <<"tool_use_id">> => <<"web_search_emulated">>,
        <<"content">> => iolist_to_binary([
            <<"[Web search emulated] Query: ">>, Query,
            <<"\nNote: Web search is emulated. The model should use its internal knowledge to answer this query.">>
        ])
    }.

%%% Internal

find_web_search_tool([]) -> false;
find_web_search_tool([#{<<"name">> := <<"web_search">>} = Tool | _]) ->
    Input = maps:get(<<"input">>, Tool, #{}),
    Query = maps:get(<<"query">>, Input, <<>>),
    {true, Query};
find_web_search_tool([#{<<"type">> := <<"web_search">>} | _]) ->
    {true, <<>>};
find_web_search_tool([_ | Rest]) ->
    find_web_search_tool(Rest).
