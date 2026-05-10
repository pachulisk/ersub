-module(ersub_health_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Body = jsx:encode(#{
        status => <<"ok">>,
        version => <<"0.1.0">>,
        timestamp => erlang:system_time(second)
    }),
    Req = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req0),
    {ok, Req, State}.
