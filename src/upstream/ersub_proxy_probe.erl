-module(ersub_proxy_probe).

-export([probe/1, probe_all/0]).

%% Probe a proxy endpoint and return latency.
-spec probe(map()) -> {ok, integer()} | {error, term()}.
probe(#{host := Host, port := Port, protocol := Protocol}) ->
    Start = erlang:monotonic_time(millisecond),
    case Protocol of
        <<"http">> ->
            case gen_tcp:connect(binary_to_list(Host), Port, [], 5000) of
                {ok, Socket} ->
                    gen_tcp:close(Socket),
                    Latency = erlang:monotonic_time(millisecond) - Start,
                    {ok, Latency};
                {error, Reason} ->
                    {error, Reason}
            end;
        <<"https">> ->
            case ssl:connect(binary_to_list(Host), Port, [{verify, verify_none}], 5000) of
                {ok, Socket} ->
                    _ = ssl:close(Socket),
                    Latency = erlang:monotonic_time(millisecond) - Start,
                    {ok, Latency};
                {error, Reason} ->
                    {error, Reason}
            end;
        _ ->
            {error, unsupported_protocol}
    end.

%% Probe all active proxies and update their latency in DB.
-spec probe_all() -> ok.
probe_all() ->
    case ersub_repo:squery(
        "SELECT id, host, port, protocol FROM proxies WHERE is_active = TRUE") of
        {ok, _, Rows} ->
            lists:foreach(fun({Id, Host, Port, Protocol}) ->
                Proxy = #{host => Host, port => binary_to_integer(Port),
                          protocol => Protocol},
                case probe(Proxy) of
                    {ok, Latency} ->
                        ersub_repo:query(
                            "UPDATE proxies SET last_probe_ms = $2, "
                            "last_probe_at = NOW() WHERE id = $1",
                            [binary_to_integer(Id), Latency]);
                    {error, _} ->
                        ok
                end
            end, Rows);
        _ -> ok
    end.
