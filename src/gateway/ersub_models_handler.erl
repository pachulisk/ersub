-module(ersub_models_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%% GET /v1/models — list available models (OpenAI compatible)
%% GET /v1/models/:model_id — get single model info

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            PathInfo = cowboy_req:path_info(Req0),
            handle_get(PathInfo, Req0, State);
        _ ->
            Req = reply_json(405, #{error => #{message => <<"Method not allowed">>}}, Req0),
            {ok, Req, State}
    end.

handle_get(undefined, Req0, State) ->
    %% List all models
    AllModels = ersub_pricing_srv:get_all(),
    ModelList = maps:fold(fun(ModelId, Pricing, Acc) ->
        [format_model(ModelId, Pricing) | Acc]
    end, [], AllModels),
    Body = #{
        <<"object">> => <<"list">>,
        <<"data">> => ModelList
    },
    {ok, reply_json(200, Body, Req0), State};

handle_get([ModelId], Req0, State) ->
    %% Get single model
    case ersub_pricing_srv:get_pricing(ModelId) of
        {ok, Pricing} ->
            {ok, reply_json(200, format_model(ModelId, Pricing), Req0), State};
        {error, not_found} ->
            {ok, reply_json(404, #{error => #{
                type => <<"invalid_request_error">>,
                message => <<"Model not found">>
            }}, Req0), State}
    end;

handle_get(_, Req0, State) ->
    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}.

format_model(ModelId, Pricing) ->
    Owner = guess_owner(ModelId),
    #{
        <<"id">> => ModelId,
        <<"object">> => <<"model">>,
        <<"created">> => 1700000000,
        <<"owned_by">> => Owner,
        <<"permission">> => [],
        <<"root">> => ModelId,
        <<"parent">> => null,
        <<"capabilities">> => #{
            <<"supports_prompt_caching">> => maps:get(supports_prompt_caching, Pricing, false)
        }
    }.

guess_owner(<<"claude", _/binary>>) -> <<"anthropic">>;
guess_owner(<<"gpt", _/binary>>) -> <<"openai">>;
guess_owner(<<"gemini", _/binary>>) -> <<"google">>;
guess_owner(<<"dall", _/binary>>) -> <<"openai">>;
guess_owner(_) -> <<"unknown">>.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).
