-module(ersub_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    Children = [
        %% Phase 1: Config server (must start first)
        %% #{id => ersub_config_srv,
        %%   start => {ersub_config_srv, start_link, []},
        %%   restart => permanent,
        %%   type => worker}

        %% Additional children added as modules are implemented:
        %% - ersub_db_sup (rest_for_one: repo_pool + migration)
        %% - ersub_clips_pool_sup (poolboy)
        %% - ersub_platform_sup
        %% - ersub_concurrency_sup
        %% - ersub_session_srv
        %% - ersub_billing_sup
        %% - ersub_scheduler_srv
        %% - ersub_auth_srv
        %% - cowboy_listener
    ],
    {ok, {SupFlags, Children}}.
