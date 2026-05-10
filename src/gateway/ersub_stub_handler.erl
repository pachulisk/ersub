-module(ersub_stub_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Body = jsx:encode(#{
        error => <<"not_implemented">>,
        message => <<"This endpoint is not yet implemented">>
    }),
    Req = cowboy_req:reply(501,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req0),
    {ok, Req, State}.
