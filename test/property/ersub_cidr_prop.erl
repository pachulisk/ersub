-module(ersub_cidr_prop).
-include_lib("eunit/include/eunit.hrl").

ten_network_test() ->
    Cidr = ersub_ip_access:parse_cidr(<<"10.0.0.0/8">>),
    [begin
        IP = {10, rand:uniform(256)-1, rand:uniform(256)-1, rand:uniform(256)-1},
        ?assert(ersub_ip_access:ip_in_cidr(IP, Cidr))
    end || _ <- lists:seq(1, 200)].

non_ten_rejected_test() ->
    Cidr = ersub_ip_access:parse_cidr(<<"10.0.0.0/8">>),
    [begin
        A = 11 + rand:uniform(244),
        IP = {A, rand:uniform(256)-1, rand:uniform(256)-1, rand:uniform(256)-1},
        ?assertNot(ersub_ip_access:ip_in_cidr(IP, Cidr))
    end || _ <- lists:seq(1, 200)].

slash32_exact_test() ->
    [begin
        IP = {rand:uniform(256)-1, rand:uniform(256)-1, rand:uniform(256)-1, rand:uniform(256)-1},
        Cidr = ersub_ip_access:parse_cidr(iolist_to_binary(
            io_lib:format("~p.~p.~p.~p/32", tuple_to_list(IP)))),
        ?assert(ersub_ip_access:ip_in_cidr(IP, Cidr))
    end || _ <- lists:seq(1, 100)].
