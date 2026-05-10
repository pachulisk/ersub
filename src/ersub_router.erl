-module(ersub_router).

-export([routes/0, start_listener/0, stop_listener/0]).

routes() ->
    Stub = ersub_stub_handler,
    [
        {'_', [
            %% Gateway endpoints
            {"/v1/messages", ersub_claude_handler, []},
            {"/openai/v1/chat/completions", ersub_openai_handler, []},
            {"/openai/v1/responses", ersub_openai_responses_handler, []},
            {"/openai/v1/images/generations", ersub_openai_images_handler, []},
            {"/gemini/v1beta/[...]", ersub_gemini_handler, []},
            {"/antigravity/v1/messages", Stub, []},  %% P3-05

            %% Management API (stubs until implemented)
            {"/api/user/[...]", ersub_user_handler, []},
            {"/api/keys/[...]", ersub_keys_handler, []},
            {"/api/usage/[...]", Stub, []},
            {"/api/admin/[...]", ersub_admin_handler, []},
            {"/api/payment/[...]", Stub, []},
            {"/api/auth/[...]", Stub, []},
            {"/api/announcements/[...]", ersub_announcement_handler, []},

            %% Health check (implemented)
            {"/health", ersub_health_handler, []},

            %% Static files (frontend)
            {"/[...]", cowboy_static, {priv_dir, ersub, "static"}}
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
