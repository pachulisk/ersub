-module(ersub_rate_limiter).
-behaviour(gen_server).

-export([start_link/0]).
-export([check_rpm/3, reset/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(TABLE, ersub_rate_windows).
-define(WINDOW_MS, 60000).       %% 1 minute sliding window
-define(CLEANUP_INTERVAL_MS, 30000). %% cleanup every 30s

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Check if request is within RPM limit.
%% Type: user | api_key | group
%% Returns ok | {error, rate_limited}
-spec check_rpm(atom(), integer(), integer()) -> ok | {error, rate_limited}.
check_rpm(_Type, _Id, 0) ->
    ok; %% 0 = unlimited
check_rpm(_Type, _Id, undefined) ->
    ok;
check_rpm(_Type, _Id, null) ->
    ok;
check_rpm(Type, Id, Limit) ->
    Now = erlang:monotonic_time(millisecond),
    Key = {Type, Id},
    case ets:lookup(?TABLE, Key) of
        [{_, Timestamps}] ->
            %% Filter to current window
            Active = [T || T <- Timestamps, Now - T < ?WINDOW_MS],
            case length(Active) >= Limit of
                true ->
                    {error, rate_limited};
                false ->
                    ets:insert(?TABLE, {Key, [Now | Active]}),
                    ok
            end;
        [] ->
            ets:insert(?TABLE, {Key, [Now]}),
            ok
    end.

%% Reset rate limit for a specific entity.
-spec reset(atom(), integer()) -> ok.
reset(Type, Id) ->
    ets:delete(?TABLE, {Type, Id}),
    ok.

%%% gen_server callbacks

init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
    schedule_cleanup(),
    logger:info("Rate limiter started"),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    cleanup_expired(),
    schedule_cleanup(),
    {noreply, State}.

%%% Internal

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup).

cleanup_expired() ->
    Now = erlang:monotonic_time(millisecond),
    %% Iterate all entries and remove stale timestamps
    ets:foldl(fun({Key, Timestamps}, Acc) ->
        Active = [T || T <- Timestamps, Now - T < ?WINDOW_MS],
        case Active of
            [] -> ets:delete(?TABLE, Key);
            _ -> ets:insert(?TABLE, {Key, Active})
        end,
        Acc
    end, 0, ?TABLE).
