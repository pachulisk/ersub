-module(ersub_request_id).
-export([ensure_request_id/1]).

%% Ensure a request has an X-Request-Id header.
%% If the client sent one, use it. Otherwise generate a UUID v4.
-spec ensure_request_id(cowboy_req:req()) -> {binary(), cowboy_req:req()}.
ensure_request_id(Req) ->
    case cowboy_req:header(<<"x-request-id">>, Req) of
        undefined ->
            Id = generate_uuid_v4(),
            Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, Id, Req),
            {Id, Req1};
        Existing ->
            Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, Existing, Req),
            {Existing, Req1}
    end.

generate_uuid_v4() ->
    <<A:32, B:16, _:4, C:12, _:2, D:62>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~1.16.0b~15.16.0b",
        [A, B, C, (D bsr 60) bor 8, D band 16#0FFFFFFFFFFFFFFF])).
