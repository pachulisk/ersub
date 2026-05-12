-module(ersub_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    _ = ersub_auth_middleware:init_cache(),
    _ = ersub_idempotency:init_cache(),
    ersub_scheduler_metrics:init(),
    ersub_image_limiter:init(),
    {ok, Pid} = ersub_sup:start_link(),
    %% Post-supervisor setup: load CLIPS config facts into persistent_term
    ersub_clips_config:load(),
    ersub_setup:check_and_run(),
    {ok, _} = ersub_router:start_listener(),
    {ok, Pid}.

stop(_State) ->
    _ = ersub_router:stop_listener(),
    ok.
