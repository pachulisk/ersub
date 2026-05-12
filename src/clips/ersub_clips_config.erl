-module(ersub_clips_config).

%% Loads all CLIPS deffacts into persistent_term at app startup.
%% Subsequent reads are zero-cost (no Port call).
%% Reload via POST /api/admin/clips/reload triggers refresh.

-export([load/0, reload/0]).
-export([get_platform/1, get_oauth_endpoint/1, get_account_timing/0,
         get_cors_config/0, get_ban_config/0, get_circuit_breaker/0,
         get_request_config/0, get_dedup_config/0, get_sse_ping/1,
         get_csp_directives/0, get_private_ip_ranges/0]).

%% Load all CLIPS deffacts into persistent_term.
-spec load() -> ok.
load() ->
    ersub_clips_pool:with_worker(fun(W) ->
        %% Run with no assertions — deffacts are auto-asserted after Reset
        case gen_server:call(W, {get_all_facts}, 10000) of
            {ok, Facts} ->
                store_facts(Facts);
            _ ->
                logger:warning("CLIPS config load failed, using defaults")
        end
    end),
    ok.

reload() -> load().

%% === Query APIs (zero-cost persistent_term reads) ===

-spec get_platform(binary()) -> map().
get_platform(Platform) ->
    persistent_term:get({clips_cfg, platform, Platform}, #{
        <<"base-url">> => <<"https://api.example.com">>,
        <<"api-version">> => <<>>,
        <<"auth-type">> => <<"api_key">>,
        <<"auth-header">> => <<"x-api-key">>
    }).

-spec get_oauth_endpoint(binary()) -> map().
get_oauth_endpoint(Platform) ->
    persistent_term:get({clips_cfg, oauth, Platform}, #{
        <<"token-url">> => <<>>
    }).

-spec get_account_timing() -> map().
get_account_timing() ->
    persistent_term:get({clips_cfg, account_timing}, #{
        <<"ewma-alpha">> => 0.2,
        <<"rate-limit-cooldown-ms">> => 60000,
        <<"overload-cooldown-ms">> => 30000,
        <<"temp-unsched-ms">> => 600000,
        <<"status-check-interval-ms">> => 10000
    }).

-spec get_cors_config() -> map().
get_cors_config() ->
    persistent_term:get({clips_cfg, cors}, #{
        <<"allowed-methods">> => <<"GET, POST, PUT, DELETE, OPTIONS">>,
        <<"allowed-headers">> => <<"Content-Type, Authorization, x-api-key">>,
        <<"max-age">> => <<"86400">>,
        <<"allow-credentials">> => <<"TRUE">>
    }).

-spec get_ban_config() -> map().
get_ban_config() ->
    persistent_term:get({clips_cfg, ban}, #{
        <<"threshold">> => 5,
        <<"window-seconds">> => 86400
    }).

-spec get_circuit_breaker() -> map().
get_circuit_breaker() ->
    persistent_term:get({clips_cfg, circuit_breaker}, #{
        <<"failure-threshold">> => 5,
        <<"half-open-timeout-ms">> => 30000
    }).

-spec get_request_config() -> map().
get_request_config() ->
    persistent_term:get({clips_cfg, request}, #{
        <<"max-body-size">> => 268435456,
        <<"stream-timeout-ms">> => 600000,
        <<"connect-timeout-ms">> => 10000,
        <<"min-balance-precheck">> => 0.001
    }).

-spec get_dedup_config() -> map().
get_dedup_config() ->
    persistent_term:get({clips_cfg, dedup}, #{
        <<"ttl-days">> => 7
    }).

-spec get_sse_ping(binary()) -> map().
get_sse_ping(Platform) ->
    persistent_term:get({clips_cfg, sse_ping, Platform},
        persistent_term:get({clips_cfg, sse_ping, <<"default">>}, #{
            <<"format">> => <<"event:ping data:ping">>,
            <<"base-interval-ms">> => 100,
            <<"max-interval-ms">> => 2000,
            <<"backoff-factor">> => 1.5,
            <<"jitter-range">> => 0.2
        })).

-spec get_csp_directives() -> [map()].
get_csp_directives() ->
    persistent_term:get({clips_cfg, csp_directives}, []).

-spec get_private_ip_ranges() -> [map()].
get_private_ip_ranges() ->
    persistent_term:get({clips_cfg, private_ip_ranges}, []).

%%% Internal — parse CLIPS facts into persistent_term

store_facts(Facts) ->
    lists:foreach(fun(F) ->
        Template = maps:get(<<"template">>, F, <<>>),
        store_by_template(Template, F)
    end, Facts).

store_by_template(<<"platform-config">>, F) ->
    Platform = maps:get(<<"platform">>, F, <<>>),
    persistent_term:put({clips_cfg, platform, Platform}, F);

store_by_template(<<"oauth-endpoint">>, F) ->
    Platform = maps:get(<<"platform">>, F, <<>>),
    persistent_term:put({clips_cfg, oauth, Platform}, F);

store_by_template(<<"account-timing-config">>, F) ->
    persistent_term:put({clips_cfg, account_timing}, F);

store_by_template(<<"cors-config">>, F) ->
    persistent_term:put({clips_cfg, cors}, F);

store_by_template(<<"ban-config">>, F) ->
    persistent_term:put({clips_cfg, ban}, F);

store_by_template(<<"circuit-breaker-config">>, F) ->
    persistent_term:put({clips_cfg, circuit_breaker}, F);

store_by_template(<<"request-config">>, F) ->
    persistent_term:put({clips_cfg, request}, F);

store_by_template(<<"dedup-config">>, F) ->
    persistent_term:put({clips_cfg, dedup}, F);

store_by_template(<<"sse-ping-config">>, F) ->
    Platform = maps:get(<<"platform">>, F, <<"default">>),
    persistent_term:put({clips_cfg, sse_ping, Platform}, F);

store_by_template(<<"csp-directive">>, F) ->
    Existing = persistent_term:get({clips_cfg, csp_directives}, []),
    persistent_term:put({clips_cfg, csp_directives}, [F | Existing]);

store_by_template(<<"private-ip-range">>, F) ->
    Existing = persistent_term:get({clips_cfg, private_ip_ranges}, []),
    persistent_term:put({clips_cfg, private_ip_ranges}, [F | Existing]);

store_by_template(_, _) ->
    ok.
