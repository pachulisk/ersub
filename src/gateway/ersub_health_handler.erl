-module(ersub_health_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, [event_logging]) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                jsx:encode(#{ok => true}), Req0),
            {ok, Req, [event_logging]};
        _ ->
            Req = cowboy_req:reply(405,
                #{<<"content-type">> => <<"application/json">>},
                jsx:encode(#{error => <<"Method not allowed">>}), Req0),
            {ok, Req, [event_logging]}
    end;

init(Req0, State) ->
    DbStatus = check_db(),
    ClipsStatus = check_clips(),
    Overall = case {DbStatus, ClipsStatus} of
        {ok, ok} -> <<"ok">>;
        {ok, _} -> <<"degraded">>;
        _ -> <<"unhealthy">>
    end,
    StatusCode = case Overall of
        <<"ok">> -> 200;
        <<"degraded">> -> 200;
        _ -> 503
    end,
    Body = jsx:encode(#{
        status => Overall,
        version => <<"0.1.0">>,
        timestamp => erlang:system_time(second),
        components => #{
            database => status_to_bin(DbStatus),
            clips_pool => status_to_bin(ClipsStatus)
        }
    }),
    Req = cowboy_req:reply(StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req0),
    {ok, Req, State}.

check_db() ->
    try
        case ersub_repo:squery("SELECT 1") of
            {ok, _, _} -> ok;
            _ -> error
        end
    catch _:_ -> error
    end.

check_clips() ->
    try
        ersub_clips_pool:with_worker(fun(W) ->
            ersub_clips_worker:ping(W)
        end)
    catch _:_ -> error
    end.

status_to_bin(ok) -> <<"healthy">>;
status_to_bin(_) -> <<"unhealthy">>.
