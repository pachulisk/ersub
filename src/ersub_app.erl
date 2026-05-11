-module(ersub_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ersub_auth_middleware:init_cache(),
    ersub_idempotency:init_cache(),
    ersub_scheduler_metrics:init(),
    ersub_image_limiter:init(),
    {ok, Pid} = ersub_sup:start_link(),
    %% Post-supervisor setup
    ersub_setup:check_and_run(),
    {ok, _} = ersub_router:start_listener(),
    {ok, Pid}.

stop(_State) ->
    ersub_router:stop_listener(),
    ok.
