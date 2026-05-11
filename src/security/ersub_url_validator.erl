-module(ersub_url_validator).

-export([validate_upstream_url/1, validate_resolved_ip/1, is_private_ip/1]).

%% Validate an upstream URL for safety (SSRF prevention).
-spec validate_upstream_url(binary() | string()) -> ok | {error, atom()}.

validate_upstream_url(Url) when is_binary(Url) ->
    validate_upstream_url(binary_to_list(Url));
validate_upstream_url(Url) when is_list(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = Parsed ->
            Port = maps:get(port, Parsed, default_port(Scheme)),
            validate_chain(Scheme, Host, Port);
        _ ->
            {error, invalid_url}
    end.

%% Validate a resolved IP address (DNS rebinding prevention).
-spec validate_resolved_ip(inet:ip_address()) -> ok | {error, atom()}.

validate_resolved_ip(IP) ->
    case is_private_ip(IP) orelse is_loopback(IP) orelse
         is_link_local(IP) orelse is_multicast(IP) orelse is_unspecified(IP) of
        true -> {error, dns_rebinding_blocked};
        false -> ok
    end.

%% Check if an IP is in a private range.
-spec is_private_ip(inet:ip_address()) -> boolean().

is_private_ip({10, _, _, _}) -> true;
is_private_ip({172, B, _, _}) when B >= 16, B =< 31 -> true;
is_private_ip({192, 168, _, _}) -> true;
is_private_ip({0, _, _, _}) -> true;
%% IPv6 private ranges
is_private_ip({16#FC00, _, _, _, _, _, _, _}) -> true;
is_private_ip({16#FD00, _, _, _, _, _, _, _}) -> true;
is_private_ip(_) -> false.

%%% Internal

validate_chain(Scheme, Host, _Port) ->
    case validate_scheme(Scheme) of
        ok ->
            case validate_host(Host) of
                ok -> ok;
                Err -> Err
            end;
        Err -> Err
    end.

validate_scheme("https") -> ok;
validate_scheme("http") ->
    case ersub_config_srv:get(security_url_allowlist_allow_http, false) of
        true -> ok;
        _ -> {error, https_required}
    end;
validate_scheme(_) -> {error, invalid_scheme}.

validate_host(Host) ->
    %% Check allowlist if enabled
    case ersub_config_srv:get(security_url_allowlist_enabled, false) of
        true ->
            AllowedHosts = ersub_config_srv:get(security_url_allowlist_upstream_hosts, []),
            case is_host_allowed(Host, AllowedHosts) of
                true -> validate_host_not_private(Host);
                false -> {error, host_not_allowed}
            end;
        false ->
            validate_host_not_private(Host)
    end.

validate_host_not_private(Host) ->
    case inet:parse_address(Host) of
        {ok, IP} ->
            %% Direct IP — check if private
            case is_private_ip(IP) orelse is_loopback(IP) of
                true -> {error, private_ip_blocked};
                false -> ok
            end;
        {error, _} ->
            %% Hostname — resolve and check
            case inet:getaddr(Host, inet) of
                {ok, IP} ->
                    case is_private_ip(IP) orelse is_loopback(IP) of
                        true -> {error, private_ip_blocked};
                        false -> ok
                    end;
                {error, _} ->
                    ok %% DNS resolution failure is not a security issue here
            end
    end.

is_host_allowed(_Host, []) -> false;
is_host_allowed(Host, [Pattern | Rest]) ->
    PatternStr = case is_binary(Pattern) of
        true -> binary_to_list(Pattern);
        false -> Pattern
    end,
    case PatternStr of
        [$* , $. | Domain] ->
            %% Wildcard: *.example.com matches foo.example.com
            Suffix = "." ++ Domain,
            case lists:suffix(Suffix, Host) of
                true -> true;
                false -> is_host_allowed(Host, Rest)
            end;
        Exact ->
            case Host =:= Exact of
                true -> true;
                false -> is_host_allowed(Host, Rest)
            end
    end.

is_loopback({127, _, _, _}) -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback(_) -> false.

is_link_local({169, 254, _, _}) -> true;
is_link_local({16#FE80, _, _, _, _, _, _, _}) -> true;
is_link_local(_) -> false.

is_multicast({A, _, _, _}) when A >= 224, A =< 239 -> true;
is_multicast({16#FF00, _, _, _, _, _, _, _}) -> true;
is_multicast(_) -> false.

is_unspecified({0, 0, 0, 0}) -> true;
is_unspecified({0, 0, 0, 0, 0, 0, 0, 0}) -> true;
is_unspecified(_) -> false.

default_port("https") -> 443;
default_port("http") -> 80;
default_port(_) -> 443.
