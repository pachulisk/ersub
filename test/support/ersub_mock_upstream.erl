-module(ersub_mock_upstream).
-behaviour(cowboy_handler).

-export([start/0, start/1, stop/0]).
-export([init/2]).

-define(LISTENER, mock_upstream).
-define(DEFAULT_PORT, 19090).

%% Start a mock upstream API server for testing.
start() -> start(#{}).

start(Opts) ->
    Port = maps:get(port, Opts, ?DEFAULT_PORT),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/v1/messages", ?MODULE, Opts#{endpoint => claude}},
            {"/v1/chat/completions", ?MODULE, Opts#{endpoint => openai}},
            {"/v1/responses", ?MODULE, Opts#{endpoint => responses}},
            {"/v1/images/generations", ?MODULE, Opts#{endpoint => images}},
            {"/v1beta/[...]", ?MODULE, Opts#{endpoint => gemini}}
        ]}
    ]),
    cowboy:start_clear(?LISTENER,
        #{socket_opts => [{port, Port}], num_acceptors => 5},
        #{env => #{dispatch => Dispatch}}).

stop() ->
    cowboy:stop_listener(?LISTENER).

%% Cowboy handler — returns mock responses based on endpoint
init(Req0, Opts) ->
    Delay = maps:get(delay_ms, Opts, 0),
    case Delay > 0 of true -> timer:sleep(Delay); false -> ok end,
    Status = maps:get(status, Opts, 200),
    Endpoint = maps:get(endpoint, Opts, claude),
    Body = maps:get(body, Opts, default_response(Endpoint)),
    Req = cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req0),
    {ok, Req, Opts}.

default_response(claude) ->
    #{type => <<"message">>, role => <<"assistant">>,
      content => [#{type => <<"text">>, text => <<"Hello from mock Claude">>}],
      model => <<"claude-sonnet-4-20250514">>,
      usage => #{input_tokens => 10, output_tokens => 5}};
default_response(openai) ->
    #{id => <<"chatcmpl-mock">>, object => <<"chat.completion">>,
      choices => [#{index => 0, message => #{role => <<"assistant">>,
                    content => <<"Hello from mock OpenAI">>},
                    finish_reason => <<"stop">>}],
      usage => #{prompt_tokens => 10, completion_tokens => 5, total_tokens => 15}};
default_response(responses) ->
    #{id => <<"resp-mock">>, output => [#{type => <<"message">>,
      content => [#{type => <<"output_text">>, text => <<"Hello from mock">>}]}]};
default_response(images) ->
    #{created => 1234567890, data => [#{url => <<"https://mock/image.png">>}]};
default_response(gemini) ->
    #{candidates => [#{content => #{parts => [#{text => <<"Hello from mock Gemini">>}]}}]}.
