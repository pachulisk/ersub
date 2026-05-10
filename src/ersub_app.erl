-module(ersub_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ersub_auth_middleware:init_cache(),
    {ok, _} = ersub_router:start_listener(),
    ersub_sup:start_link().

stop(_State) ->
    ersub_router:stop_listener(),
    ok.
