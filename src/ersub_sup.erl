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
        #{id => ersub_config_srv,
          start => {ersub_config_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_repo_pool,
          start => {ersub_repo_pool, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_session_srv,
          start => {ersub_session_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_concurrency_srv,
          start => {ersub_concurrency_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_usage_logger,
          start => {ersub_usage_logger, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_rate_limiter,
          start => {ersub_rate_limiter, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_platform_sup,
          start => {ersub_platform_sup, start_link, []},
          restart => permanent,
          type => supervisor},

        #{id => ersub_upstream_pool,
          start => {ersub_upstream_pool, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_billing_srv,
          start => {ersub_billing_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_scheduler_srv,
          start => {ersub_scheduler_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_auth_srv,
          start => {ersub_auth_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_channel_srv,
          start => {ersub_channel_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_quota_srv,
          start => {ersub_quota_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_clips_pool,
          start => {ersub_clips_pool, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_pricing_srv,
          start => {ersub_pricing_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_moderation_srv,
          start => {ersub_moderation_srv, start_link, []},
          restart => permanent,
          type => worker},

        #{id => ersub_ops_alert_srv,
          start => {ersub_ops_alert_srv, start_link, []},
          restart => permanent,
          type => worker}
        %% NOTE: Cowboy listener started in ersub_app:start/2
    ],
    {ok, {SupFlags, Children}}.
