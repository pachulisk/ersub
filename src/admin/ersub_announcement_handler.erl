-module(ersub_announcement_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    handle(Method, Path, Req0, State).

%% GET /api/announcements — list announcements (public, needs API key)
%% Supports ?status=active|draft|archived filter
handle(<<"GET">>, undefined, Req0, State) ->
    QS = cowboy_req:parse_qs(Req0),
    case proplists:get_value(<<"status">>, QS, undefined) of
        undefined ->
            %% Default: only active announcements
            case ersub_repo:squery(
                "SELECT id, title, content, notify_mode, created_at "
                "FROM announcements WHERE is_active = TRUE "
                "ORDER BY sort_order ASC, id DESC"
            ) of
                {ok, _, Rows} ->
                    Announcements = [#{id => Id, title => T, content => C,
                                      notify_mode => NM, created_at => CA}
                                    || {Id, T, C, NM, CA} <- Rows],
                    {ok, reply_json(200, #{data => Announcements}, Req0), State};
                {error, _} ->
                    {ok, reply_json(200, #{data => []}, Req0), State}
            end;
        Status ->
            %% Filter by status: active maps to is_active=true,
            %% draft/archived map to is_active=false (or use status column if present)
            IsActive = case Status of
                <<"active">> -> <<"TRUE">>;
                _ -> <<"FALSE">>
            end,
            SQL = iolist_to_binary([
                "SELECT id, title, content, notify_mode, created_at "
                "FROM announcements WHERE is_active = ", IsActive,
                " ORDER BY sort_order ASC, id DESC"
            ]),
            case ersub_repo:squery(binary_to_list(SQL)) of
                {ok, _, Rows} ->
                    Announcements = [#{id => Id, title => T, content => C,
                                      notify_mode => NM, created_at => CA}
                                    || {Id, T, C, NM, CA} <- Rows],
                    {ok, reply_json(200, #{data => Announcements}, Req0), State};
                {error, _} ->
                    {ok, reply_json(200, #{data => []}, Req0), State}
            end
    end;

%% GET /api/announcements/:id — get single announcement (public, needs API key)
handle(<<"GET">>, [IdBin], Req0, State) ->
    AnnId = binary_to_integer(IdBin),
    case ersub_repo:query(
        "SELECT id, title, content, severity, notify_mode, is_pinned, "
        "is_active, sort_order, created_at, updated_at "
        "FROM announcements WHERE id = $1", [AnnId]) of
        {ok, _, [{Id, T, C, Sev, NM, IP, IA, SO, CA, UA}]} ->
            {ok, reply_json(200, #{data => #{
                id => Id, title => T, content => C, severity => Sev,
                notify_mode => NM, is_pinned => IP, is_active => IA,
                sort_order => SO, created_at => CA, updated_at => UA}}, Req0), State};
        {ok, _, []} ->
            {ok, reply_json(404, #{error => #{message => <<"Announcement not found">>}}, Req0), State};
        _ ->
            {ok, reply_json(500, #{error => #{message => <<"Query failed">>}}, Req0), State}
    end;

%% GET /api/announcements/:id/read-status — get read status (admin only)
handle(<<"GET">>, [IdBin, <<"read-status">>], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {ok, _Claims} ->
            AnnId = binary_to_integer(IdBin),
            case ersub_repo:query(
                "SELECT user_id, read_at FROM announcement_reads "
                "WHERE announcement_id = $1 ORDER BY read_at DESC", [AnnId]) of
                {ok, _, Rows} ->
                    Data = [#{user_id => UID, read_at => RA} || {UID, RA} <- Rows],
                    {ok, reply_json(200, #{data => Data}, Req0), State};
                _ ->
                    {ok, reply_json(200, #{data => []}, Req0), State}
            end;
        {error, _} ->
            {ok, reply_json(401, #{error => #{message => <<"Admin auth required">>}}, Req0), State}
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

%% PUT /api/announcements/:id — update announcement (admin only)
handle(<<"PUT">>, [Id], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {ok, _Claims} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Params = jsx:decode(Body, [return_maps]),
            %% Map JSON field names to DB column names
            FieldMap = [
                {<<"title">>,    "title"},
                {<<"body">>,     "content"},
                {<<"severity">>, "severity"},
                {<<"is_pinned">>, "is_pinned"},
                {<<"status">>,   "status"}
            ],
            {SetParts, Values, _NextIdx} = lists:foldl(
                fun({JsonKey, DbCol}, {Sets, Vals, Idx}) ->
                    case maps:get(JsonKey, Params, undefined) of
                        undefined -> {Sets, Vals, Idx};
                        V ->
                            Part = iolist_to_binary([DbCol, " = $",
                                                     integer_to_binary(Idx)]),
                            {[Part | Sets], [V | Vals], Idx + 1}
                    end
                end,
                {[], [], 2},
                FieldMap
            ),
            case SetParts of
                [] ->
                    {ok, reply_json(400, #{error => #{message => <<"No fields to update">>}}, Req1), State};
                _ ->
                    SetClause = lists:join(<<", ">>, lists:reverse(SetParts)),
                    AnnId = binary_to_integer(Id),
                    SQL = iolist_to_binary([
                        "UPDATE announcements SET ",
                        SetClause,
                        ", updated_at = NOW() WHERE id = $1"
                    ]),
                    AllValues = [AnnId | lists:reverse(Values)],
                    case ersub_repo:query(binary_to_list(SQL), AllValues) of
                        {ok, 0} ->
                            {ok, reply_json(404, #{error => #{message => <<"Announcement not found">>}}, Req1), State};
                        {ok, _} ->
                            {ok, reply_json(200, #{success => true}, Req1), State};
                        {error, _Reason} ->
                            {ok, reply_json(500, #{error => #{message => <<"Update failed">>}}, Req1), State}
                    end
            end;
        {error, _} ->
            {ok, reply_json(401, #{error => #{message => <<"Admin auth required">>}}, Req0), State}
    end;

%% DELETE /api/announcements/:id — delete announcement (admin only)
handle(<<"DELETE">>, [Id], Req0, State) ->
    case verify_admin_jwt(Req0) of
        {ok, _Claims} ->
            AnnId = binary_to_integer(Id),
            case ersub_repo:query(
                "DELETE FROM announcements WHERE id = $1", [AnnId]) of
                {ok, 0} ->
                    {ok, reply_json(404, #{error => #{message => <<"Announcement not found">>}}, Req0), State};
                {ok, _} ->
                    {ok, reply_json(200, #{success => true}, Req0), State};
                {error, _Reason} ->
                    {ok, reply_json(500, #{error => #{message => <<"Delete failed">>}}, Req0), State}
            end;
        {error, _} ->
            {ok, reply_json(401, #{error => #{message => <<"Admin auth required">>}}, Req0), State}
    end;

handle(_, _, Req0, State) ->
    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}.

verify_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", T/binary>> -> ersub_auth_srv:verify_jwt(string:trim(T));
        _ -> {error, missing}
    end.

verify_admin_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            case ersub_auth_srv:verify_jwt(string:trim(Token)) of
                {ok, #{<<"role">> := <<"admin">>}} = Ok -> Ok;
                {ok, _} -> {error, not_admin};
                Err -> Err
            end;
        _ -> {error, missing_token}
    end.

reply_json(S, B, R) ->
    cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).
