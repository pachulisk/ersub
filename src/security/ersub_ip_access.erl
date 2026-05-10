-module(ersub_ip_access).

-export([check_ip_access/3, parse_cidr/1, ip_in_cidr/2]).

%% Check if a client IP is allowed based on whitelist/blacklist.
%% Blacklist takes priority over whitelist.
%% Empty whitelist = allow all (unless blacklisted).
-spec check_ip_access(inet:ip_address(), [binary()], [binary()]) -> allow | deny.

check_ip_access(ClientIP, Whitelist, Blacklist) ->
    case match_cidr_list(ClientIP, Blacklist) of
        true ->
            deny;
        false ->
            case Whitelist of
                [] -> allow;
                null -> allow;
                _ ->
                    case match_cidr_list(ClientIP, Whitelist) of
                        true -> allow;
                        false -> deny
                    end
            end
    end.

%% Parse a CIDR string like "10.0.0.0/8" or plain IP "192.168.1.1"
-spec parse_cidr(binary()) -> {inet:ip_address(), non_neg_integer()} | {error, term()}.

parse_cidr(CIDR) when is_binary(CIDR) ->
    parse_cidr(binary_to_list(CIDR));
parse_cidr(CIDR) when is_list(CIDR) ->
    case string:split(CIDR, "/") of
        [IPStr, MaskStr] ->
            case inet:parse_address(IPStr) of
                {ok, IP} ->
                    Mask = list_to_integer(MaskStr),
                    MaxBits = case tuple_size(IP) of
                        4 -> 32;
                        8 -> 128
                    end,
                    case Mask >= 0 andalso Mask =< MaxBits of
                        true -> {IP, Mask};
                        false -> {error, invalid_mask}
                    end;
                {error, _} = Err ->
                    Err
            end;
        [IPStr] ->
            case inet:parse_address(IPStr) of
                {ok, IP} ->
                    MaxBits = case tuple_size(IP) of
                        4 -> 32;
                        8 -> 128
                    end,
                    {IP, MaxBits};
                {error, _} = Err ->
                    Err
            end
    end.

%% Check if an IP address falls within a CIDR range
-spec ip_in_cidr(inet:ip_address(), {inet:ip_address(), non_neg_integer()}) -> boolean().

ip_in_cidr(IP, {NetAddr, PrefixLen}) when tuple_size(IP) =:= tuple_size(NetAddr) ->
    IPBits = ip_to_integer(IP),
    NetBits = ip_to_integer(NetAddr),
    TotalBits = case tuple_size(IP) of
        4 -> 32;
        8 -> 128
    end,
    ShiftBy = TotalBits - PrefixLen,
    (IPBits bsr ShiftBy) =:= (NetBits bsr ShiftBy);
ip_in_cidr(_, _) ->
    false.

%%% Internal

match_cidr_list(_IP, []) -> false;
match_cidr_list(_IP, null) -> false;
match_cidr_list(IP, [CIDR | Rest]) ->
    case parse_cidr(CIDR) of
        {error, _} ->
            match_cidr_list(IP, Rest);
        Parsed ->
            case ip_in_cidr(IP, Parsed) of
                true -> true;
                false -> match_cidr_list(IP, Rest)
            end
    end.

ip_to_integer({A, B, C, D}) ->
    (A bsl 24) bor (B bsl 16) bor (C bsl 8) bor D;
ip_to_integer({A, B, C, D, E, F, G, H}) ->
    (A bsl 112) bor (B bsl 96) bor (C bsl 80) bor (D bsl 64) bor
    (E bsl 48) bor (F bsl 32) bor (G bsl 16) bor H.
