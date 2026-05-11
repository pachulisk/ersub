-module(ersub_channel_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case verify_jwt(Req0) of
        {error, Reason} ->
            Req = reply_json(401, #{error => #{
                type => <<"authentication_error">>,
                message => auth_msg(Reason)
            }}, Req0),
            {ok, Req, State};
        {ok, Claims} ->
            UserId = maps:get(<<"user_id">>, Claims),
            handle(Method, Req0, State, UserId)
    end.

%% GET /api/v1/channels/available (exact route, no path_info)
handle(<<"GET">>, Req0, State, UserId) ->
    %% Get user's groups
    case ersub_repo:query(
        "SELECT group_id FROM user_allowed_groups WHERE user_id = $1",
        [UserId]
    ) of
        {ok, _, GroupRows} ->
            GroupIds = [GId || {GId} <- GroupRows],
            Channels = lists:flatmap(fun(GId) ->
                fetch_group_channels(GId)
            end, GroupIds),
            %% Filter via CLIPS channel_filter.clp
            case filter_with_clips(Channels) of
                {ok, Filtered} ->
                    Req = reply_json(200, #{data => Filtered}, Req0),
                    {ok, Req, State};
                {error, _Reason} ->
                    %% Fallback: return all active channels without CLIPS
                    Active = [C || C <- Channels, maps:get(is_active, C, false) =:= true],
                    Req = reply_json(200, #{data => Active}, Req0),
                    {ok, Req, State}
            end;
        {error, Reason} ->
            Req = reply_json(500, #{error => #{
                type => <<"api_error">>,
                message => iolist_to_binary(io_lib:format("~p", [Reason]))
            }}, Req0),
            {ok, Req, State}
    end;

handle(_, Req0, State, _) ->
    Req = reply_json(405, #{error => #{message => <<"Method not allowed">>}}, Req0),
    {ok, Req, State}.

%%% Internal

fetch_group_channels(GroupId) ->
    case ersub_repo:query(
        "SELECT id, name, group_id, platform, base_url, model_mapping, "
        "allowed_models, is_active, created_at "
        "FROM channels WHERE group_id = $1",
        [GroupId]
    ) of
        {ok, _, Rows} ->
            [#{id => Id, name => Name, group_id => GId, platform => P,
               base_url => BUrl, model_mapping => MM,
               allowed_models => AM, is_active => IA,
               created_at => CA}
             || {Id, Name, GId, P, BUrl, MM, AM, IA, CA} <- Rows];
        {error, _} ->
            []
    end.

filter_with_clips(Channels) ->
    Candidates = lists:map(fun(C) ->
        #{id => maps:get(id, C),
          group_id => maps:get(group_id, C),
          platform => maps:get(platform, C),
          is_active => maps:get(is_active, C, false),
          has_model => maps:get(allowed_models, C, null) =/= null}
    end, Channels),
    case ersub_clips_pool:filter_channels(Candidates) of
        {ok, Results} ->
            AvailableIds = [maps:get(<<"id">>, R)
                            || R <- Results,
                               maps:get(<<"available">>, R, false) =:= true
                                   orelse maps:get(<<"available">>, R, false) =:= <<"TRUE">>],
            Filtered = [C || C <- Channels,
                         lists:member(maps:get(id, C), AvailableIds)],
            {ok, Filtered};
        {error, _} = Err ->
            Err
    end.

verify_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            ersub_auth_srv:verify_jwt(string:trim(Token));
        _ -> {error, missing_token}
    end.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body), Req).

auth_msg(missing_token) -> <<"Missing Authorization header">>;
auth_msg(token_expired) -> <<"Token expired">>;
auth_msg(_) -> <<"Authentication failed">>.
