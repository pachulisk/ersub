-module(ersub_router).

-export([routes/0, start_listener/0, stop_listener/0]).

routes() ->
    [
        {'_', [
            %% Gateway endpoints (no /api/v1 prefix — these are the proxy)
            {"/v1/models/[...]", ersub_models_handler, []},
            {"/v1/models", ersub_models_handler, []},
            {"/v1/messages/count_tokens", ersub_claude_handler, [count_tokens]},
            {"/v1/messages", ersub_claude_handler, []},
            {"/openai/v1/chat/completions", ersub_openai_handler, []},
            {"/openai/v1/responses", ersub_openai_responses_handler, []},
            {"/openai/v1/responses/compact", ersub_openai_responses_handler, []},
            {"/openai/v1/realtime", ersub_openai_ws_handler, []},
            {"/openai/v1/images/generations", ersub_openai_images_handler, []},
            {"/openai/v1/images/edits", ersub_openai_images_handler, []},
            {"/gemini/v1beta/[...]", ersub_gemini_handler, []},
            {"/antigravity/v1/messages", ersub_antigravity_handler, []},
            {"/antigravity/v1beta/[...]", ersub_gemini_handler, []},
            {"/antigravity/models", ersub_models_handler, []},
            {"/antigravity/v1/models", ersub_models_handler, []},
            {"/antigravity/v1/usage", ersub_user_handler, []},

            %% Gateway route aliases (sub2api compatibility)
            {"/chat/completions", ersub_openai_handler, []},
            {"/responses", ersub_openai_responses_handler, []},
            {"/responses/[...]", ersub_openai_responses_handler, []},
            {"/v1/chat/completions", ersub_openai_handler, []},
            {"/v1/images/generations", ersub_openai_images_handler, []},
            {"/v1/images/edits", ersub_openai_images_handler, []},
            {"/backend-api/codex/responses", ersub_openai_responses_handler, []},
            {"/backend-api/codex/responses/[...]", ersub_openai_responses_handler, []},

            %% Management API — /api/v1 prefix (sub2api frontend compatible)
            {"/api/v1/user/[...]", ersub_user_handler, []},
            {"/api/v1/keys/[...]", ersub_keys_handler, []},
            {"/api/v1/usage/[...]", ersub_user_handler, []},
            {"/api/v1/subscriptions/[...]", ersub_user_handler, []},
            {"/api/v1/redeem/[...]", ersub_user_handler, []},
            {"/api/v1/groups/[...]", ersub_user_handler, []},
            {"/api/v1/admin/[...]", ersub_admin_handler, []},
            {"/api/v1/payment/[...]", ersub_payment_handler, []},
            {"/api/v1/auth/[...]", ersub_auth_handler, []},
            {"/api/v1/announcements/[...]", ersub_announcement_handler, []},
            {"/api/v1/channels/available", ersub_channel_handler, []},
            {"/api/v1/channels/[...]", ersub_admin_handler, []},
            {"/api/v1/admin/ops/[...]", ersub_ops_handler, []},

            %% Legacy routes (backward compat, redirect to /api/v1)
            {"/api/user/[...]", ersub_user_handler, []},
            {"/api/admin/[...]", ersub_admin_handler, []},
            {"/api/auth/[...]", ersub_auth_handler, []},

            %% Ops WebSocket
            {"/api/v1/admin/ops/ws/qps", ersub_ops_ws_handler, []},
            {"/api/ops/ws", ersub_ops_ws_handler, []},

            %% Custom Markdown pages
            {"/pages/:slug", ersub_page_handler, []},

            %% Event logging batch (stub)
            {"/api/event_logging/batch", ersub_health_handler, [event_logging]},

            %% Health check
            {"/health", ersub_health_handler, []},

            %% Static assets (Vite build output — hashed filenames, long-lived)
            {"/assets/[...]", cowboy_static, {priv_dir, ersub, "static/assets"}},

            %% SPA root and all history-mode routes → index.html
            {"/", cowboy_static, {priv_file, ersub, "static/index.html"}},
            {"/[...]", cowboy_static, {priv_file, ersub, "static/index.html"}}
        ]}
    ].

start_listener() ->
    Dispatch = cowboy_router:compile(routes()),
    Host = ersub_config_srv:get(server_host, "0.0.0.0"),
    Port = ersub_config_srv:get(server_port, 8080),
    MaxConns = ersub_config_srv:get(server_max_connections, 10000),
    TransportOpts = #{
        socket_opts => [{ip, parse_ip(Host)}, {port, Port}],
        num_acceptors => 100,
        max_connections => MaxConns
    },
    ProtocolOpts = #{
        env => #{dispatch => Dispatch},
        stream_handlers => [cowboy_stream_h],
        idle_timeout => 600000,
        request_timeout => 600000,
        max_request_line_length => 16384,
        max_header_name_length => 256,
        max_header_value_length => 16384,
        max_headers => 100
    },
    Result = cowboy:start_clear(ersub_http_listener, TransportOpts, ProtocolOpts),
    case Result of
        {ok, Pid} ->
            logger:info("ErSub HTTP listener started on ~s:~p", [Host, Port]),
            {ok, Pid};
        {error, _} = Err ->
            Err
    end.

stop_listener() ->
    cowboy:stop_listener(ersub_http_listener).

%%% Internal

parse_ip(Host) when is_list(Host) ->
    case inet:parse_address(Host) of
        {ok, IP} -> IP;
        {error, _} -> {0, 0, 0, 0}
    end;
parse_ip(Host) when is_binary(Host) ->
    parse_ip(binary_to_list(Host)).
