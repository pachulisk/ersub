-module(ersub_page_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%% GET /pages/:slug — serve custom Markdown pages from data/pages/{slug}/index.md

-define(MAX_FILE_SIZE, 1048576). %% 1MB

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            handle_get(Req0, State);
        _ ->
            Req = cowboy_req:reply(405,
                #{<<"content-type">> => <<"application/json">>},
                jsx:encode(#{error => #{message => <<"Method not allowed">>}}),
                Req0),
            {ok, Req, State}
    end.

handle_get(Req0, State) ->
    Slug = cowboy_req:binding(slug, Req0, <<>>),
    case validate_slug(Slug) of
        false ->
            Req = cowboy_req:reply(400,
                #{<<"content-type">> => <<"application/json">>},
                jsx:encode(#{error => #{message => <<"Invalid slug">>}}),
                Req0),
            {ok, Req, State};
        true ->
            FilePath = page_file_path(Slug),
            case filelib:is_regular(FilePath) of
                false ->
                    Req = cowboy_req:reply(404,
                        #{<<"content-type">> => <<"application/json">>},
                        jsx:encode(#{error => #{message => <<"Page not found">>}}),
                        Req0),
                    {ok, Req, State};
                true ->
                    case filelib:file_size(FilePath) of
                        Size when Size > ?MAX_FILE_SIZE ->
                            Req = cowboy_req:reply(413,
                                #{<<"content-type">> => <<"application/json">>},
                                jsx:encode(#{error => #{message => <<"File too large">>}}),
                                Req0),
                            {ok, Req, State};
                        _ ->
                            case file:read_file(FilePath) of
                                {ok, Content} ->
                                    Req = cowboy_req:reply(200,
                                        #{<<"content-type">> => <<"text/markdown; charset=utf-8">>},
                                        Content, Req0),
                                    {ok, Req, State};
                                {error, _Reason} ->
                                    Req = cowboy_req:reply(500,
                                        #{<<"content-type">> => <<"application/json">>},
                                        jsx:encode(#{error => #{message => <<"Read error">>}}),
                                        Req0),
                                    {ok, Req, State}
                            end
                    end
            end
    end.

%% Validate slug: alphanumeric, dash, underscore only
validate_slug(<<>>) -> false;
validate_slug(Slug) when is_binary(Slug) ->
    case re:run(Slug, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> true;
        nomatch -> false
    end;
validate_slug(_) -> false.

page_file_path(Slug) ->
    filename:join(["data", "pages", binary_to_list(Slug), "index.md"]).
