-module(ersub_announcement_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    handle(Method, Path, Req0, State).

%% GET /api/announcements — list active announcements (public, needs API key)
handle(<<"GET">>, undefined, Req0, State) ->
    case ersub_repo:squery(
        "SELECT id, title, content, notify_mode, created_at "
        "FROM announcements WHERE is_active = TRUE ORDER BY sort_order ASC, id DESC"
    ) of
        {ok, _, Rows} ->
            Announcements = [#{id => Id, title => T, content => C,
                              notify_mode => NM, created_at => CA}
                            || {Id, T, C, NM, CA} <- Rows],
            {ok, reply_json(200, #{data => Announcements}, Req0), State};
        {error, _} ->
            {ok, reply_json(200, #{data => []}, Req0), State}
    end;

%% POST /api/announcements/:id/read — mark read (needs JWT)
handle(<<"POST">>, [Id, <<"read">>], Req0, State) ->
    case verify_jwt(Req0) of
        {ok, #{<<"user_id">> := UserId}} ->
            AnnId = binary_to_integer(Id),
            ersub_repo:query(
                "INSERT INTO announcement_reads (user_id, announcement_id) "
                "VALUES ($1, $2) ON CONFLICT DO NOTHING", [UserId, AnnId]),
            {ok, reply_json(200, #{success => true}, Req0), State};
        {error, _} ->
            {ok, reply_json(401, #{error => #{message => <<"Auth required">>}}, Req0), State}
    end;

handle(_, _, Req0, State) ->
    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}.

verify_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", T/binary>> -> ersub_auth_srv:verify_jwt(string:trim(T));
        _ -> {error, missing}
    end.

reply_json(S, B, R) ->
    cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).
