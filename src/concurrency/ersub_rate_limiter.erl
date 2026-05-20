-module(ersub_rate_limiter).
-behaviour(gen_server).

-export([start_link/0]).
-export([check_rpm/3, check_endpoint_rate/2, reset/2]).
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

%% Check rate limit for a specific endpoint type (e.g., login, register).
%% Uses a separate ETS key namespace: {endpoint_rate, EndpointType, Identifier}
-spec check_endpoint_rate(atom(), binary()) -> ok | {error, rate_limited}.
check_endpoint_rate(EndpointType, Identifier) ->
    {MaxRequests, WindowSec} = endpoint_limits(EndpointType),
    WindowMs = WindowSec * 1000,
    Now = erlang:monotonic_time(millisecond),
    Key = {endpoint_rate, EndpointType, Identifier},
    case ets:lookup(?TABLE, Key) of
        [{_, Timestamps}] ->
            Active = [T || T <- Timestamps, Now - T < WindowMs],
            case length(Active) >= MaxRequests of
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
        Window = window_for_key(Key),
        Active = [T || T <- Timestamps, Now - T < Window],
        case Active of
            [] -> ets:delete(?TABLE, Key);
            _ -> ets:insert(?TABLE, {Key, Active})
        end,
        Acc
    end, 0, ?TABLE).

%% Per-endpoint-type limits: {MaxRequests, WindowSeconds}
endpoint_limits(login)          -> {10, 300};
endpoint_limits(register)       -> {3, 600};
endpoint_limits(oauth)          -> {10, 300};
endpoint_limits(verify_code)    -> {5, 300};
endpoint_limits(password_reset) -> {3, 600};
endpoint_limits(_Default)       -> {60, 60}.

%% Return the correct window (in ms) for a given ETS key so cleanup
%% does not prune timestamps that are still within the active window.
window_for_key({endpoint_rate, EndpointType, _}) ->
    {_, WindowSec} = endpoint_limits(EndpointType),
    WindowSec * 1000;
window_for_key(_) ->
    ?WINDOW_MS.
