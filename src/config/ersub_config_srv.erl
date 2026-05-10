-module(ersub_config_srv).
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([get/1, get/2, set/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    start_link(default_config_path()).

start_link(ConfigPath) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, ConfigPath, []).

-spec get(atom()) -> term().
get(Key) ->
    persistent_term:get({ersub_config, Key}).

-spec get(atom(), term()) -> term().
get(Key, Default) ->
    try persistent_term:get({ersub_config, Key})
    catch error:badarg -> Default
    end.

-spec set(atom(), term()) -> ok.
set(Key, Value) ->
    gen_server:call(?SERVER, {set, Key, Value}).

%%% gen_server callbacks

init(ConfigPath) ->
    Config = load_config(ConfigPath),
    write_to_persistent_term(Config),
    logger:info("Configuration loaded from ~s", [ConfigPath]),
    {ok, #{config_path => ConfigPath}}.

handle_call({set, Key, Value}, _From, State) ->
    persistent_term:put({ersub_config, Key}, Value),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

default_config_path() ->
    case os:getenv("ERSUB_CONFIG") of
        false -> "config/ersub.yaml";
        Path -> Path
    end.

load_config(Path) ->
    case filelib:is_file(Path) of
        true ->
            [Doc | _] = yamerl:decode_file(Path),
            expand_env_vars(Doc);
        false ->
            logger:warning("Config file not found: ~s, using defaults", [Path]),
            []
    end.

write_to_persistent_term(Config) ->
    Flat = flatten_config(Config, []),
    lists:foreach(fun({Key, Value}) ->
        persistent_term:put({ersub_config, Key}, Value)
    end, Flat).

flatten_config([], _Prefix) ->
    [];
flatten_config([{Key, Value} | Rest], Prefix) when is_list(Value) ->
    case is_proplist(Value) of
        true ->
            flatten_config(Value, Prefix ++ [Key]) ++
            flatten_config(Rest, Prefix);
        false ->
            [{make_key(Prefix, Key), Value} | flatten_config(Rest, Prefix)]
    end;
flatten_config([{Key, Value} | Rest], Prefix) ->
    [{make_key(Prefix, Key), Value} | flatten_config(Rest, Prefix)];
flatten_config(_, _Prefix) ->
    [].

make_key([], Key) ->
    list_to_atom(Key);
make_key(Prefix, Key) ->
    Parts = Prefix ++ [Key],
    list_to_atom(string:join(Parts, "_")).

is_proplist([]) -> true;
is_proplist([{K, _V} | Rest]) when is_list(K) -> is_proplist(Rest);
is_proplist(_) -> false.

expand_env_vars(Value) when is_list(Value) ->
    case is_proplist(Value) of
        true ->
            [{K, expand_env_vars(V)} || {K, V} <- Value];
        false ->
            case is_string(Value) of
                true -> expand_env_string(Value);
                false -> [expand_env_vars(E) || E <- Value]
            end
    end;
expand_env_vars(Other) ->
    Other.

expand_env_string(Str) ->
    case re:run(Str, "\\$\\{([^}]+)\\}", [{capture, all, list}, global]) of
        {match, Matches} ->
            Result = lists:foldl(fun([Full, VarName], Acc) ->
                Replacement = case os:getenv(VarName) of
                    false -> "";
                    Val -> Val
                end,
                string:replace(Acc, Full, Replacement, all)
            end, Str, Matches),
            lists:flatten(Result);
        nomatch ->
            Str
    end.

is_string([]) -> true;
is_string([H | T]) when is_integer(H), H >= 0, H =< 1114111 -> is_string(T);
is_string(_) -> false.
