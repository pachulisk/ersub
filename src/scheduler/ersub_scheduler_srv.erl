-module(ersub_scheduler_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([select_account/1, select_with_failover/2]).
-export([get_metrics/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(METRICS_TABLE, ersub_scheduler_metrics).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Return runtime scheduler metrics.
-spec get_metrics() -> map().
get_metrics() ->
    Keys = [select_total, sticky_hit, lb_select, account_switch],
    maps:from_list([{K, read_counter(K)} || K <- Keys]).

%% CL03: Select account using CLIPS-driven selection layer ordering.
%% The selection layers (previous_response_id, session_hash, clips_score)
%% are defined as CLIPS facts and can be reordered/disabled at runtime.
-spec select_account(map()) -> {ok, map()} | {error, no_available_account}.
select_account(Req) ->
    _ = bump_counter(select_total),
    %% Get ordered selection layers from CLIPS
    Layers = case ersub_clips_pool:get_selection_layers() of
        {ok, L} when is_list(L), length(L) > 0 -> L;
        _ ->
            %% Fallback: default order if CLIPS unavailable
            [#{type => <<"previous_response_id">>, priority => 0},
             #{type => <<"session_hash">>, priority => 1},
             #{type => <<"clips_score">>, priority => 2}]
    end,
    execute_selection_layers(Layers, Req).

execute_selection_layers([], Req) ->
    %% All layers exhausted, fall back to CLIPS scoring
    select_by_score(Req);
execute_selection_layers([#{type := Type} | Rest], Req) ->
    #{user_id := UserId} = Req,
    ExcludedIds = maps:get(excluded_ids, Req, #{}),
    case try_selection_layer(Type, UserId, ExcludedIds, Req) of
        {ok, Account} ->
            _ = bump_counter(sticky_hit),
            {ok, Account};
        miss ->
            execute_selection_layers(Rest, Req)
    end.

try_selection_layer(<<"previous_response_id">>, UserId, ExcludedIds, Req) ->
    PrevRespId = maps:get(previous_response_id, Req, <<>>),
    case PrevRespId =/= <<>> andalso ersub_session_srv:lookup(UserId, PrevRespId) of
        {ok, AccountId} when not is_map_key(AccountId, ExcludedIds) ->
            case get_account_if_schedulable(AccountId) of
                {ok, Account} ->
                    UserGroups = get_user_group_ids(UserId),
                    case account_matches_user_groups(AccountId, UserGroups) of
                        true -> {ok, Account};
                        false -> miss
                    end;
                _ -> miss
            end;
        _ -> miss
    end;
try_selection_layer(<<"session_hash">>, UserId, ExcludedIds, Req) ->
    SessionHash = maps:get(session_hash, Req, <<>>),
    case SessionHash =/= <<>> andalso ersub_session_srv:lookup(UserId, SessionHash) of
        {ok, AccountId} when not is_map_key(AccountId, ExcludedIds) ->
            case get_account_if_schedulable(AccountId) of
                {ok, Account} ->
                    UserGroups = get_user_group_ids(UserId),
                    case account_matches_user_groups(AccountId, UserGroups) of
                        true -> {ok, Account};
                        false -> miss
                    end;
                _ -> miss
            end;
        _ -> miss
    end;
try_selection_layer(<<"clips_score">>, _UserId, _ExcludedIds, Req) ->
    %% This layer delegates to CLIPS scheduling.clp scoring
    select_by_score(Req);
try_selection_layer(_, _, _, _) ->
    miss.

%% Select with automatic failover on retriable errors.
-spec select_with_failover(map(), fun((map()) -> {ok, term()} | {error, term()})) ->
    {ok, term()} | {error, term()}.
select_with_failover(Req, ForwardFun) ->
    MaxSwitches = ersub_config_srv:get(gateway_max_account_switches, 10),
    do_failover(Req, ForwardFun, #{}, 0, MaxSwitches).

%%% gen_server callbacks

init([]) ->
    case ets:info(?METRICS_TABLE) of
        undefined ->
            _ = ets:new(?METRICS_TABLE, [named_table, public, set, {write_concurrency, true}]),
            lists:foreach(fun(K) ->
                ets:insert(?METRICS_TABLE, {K, 0})
            end, [select_total, sticky_hit, lb_select, account_switch]);
        _ -> ok
    end,
    logger:info("Scheduler service started"),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

do_failover(_Req, _ForwardFun, _Excluded, Attempt, MaxSwitches)
  when Attempt > MaxSwitches ->
    {error, max_switches_exceeded};
do_failover(Req, ForwardFun, Excluded, Attempt, MaxSwitches) ->
    case select_account(Req#{excluded_ids => Excluded}) of
        {ok, Account} ->
            AccountId = maps:get(id, Account),
            case ForwardFun(Account) of
                {ok, Result} ->
                    %% Success — update sticky session
                    UserId = maps:get(user_id, Req),
                    SessionHash = maps:get(session_hash, Req, <<>>),
                    case SessionHash of
                        <<>> -> ok;
                        _ -> ersub_session_srv:store(UserId, SessionHash, AccountId)
                    end,
                    ersub_account_srv:record_success(AccountId, 0),
                    {ok, Result};
                {error, {http, Code}} ->
                    %% CL02: Check CLIPS retriable-code rules (replaces hardcoded 429/502/503/529)
                    %% Also covers X04: custom retryable codes from account credentials
                    CustomCodes = maps:get(<<"retryable_error_codes">>,
                        maps:get(credentials, Account, #{}), []),
                    IsRetriable = ersub_clips_pool:check_retriable(Code)
                        orelse lists:member(Code, CustomCodes),
                    case IsRetriable of
                        true ->
                            ersub_account_srv:record_error(AccountId, Code),
                            PoolMode = maps:get(pool_mode, Account, false),
                            PoolRetries = maps:get(pool_retry_count, Account, 3),
                            PoolAttempt = maps:get({pool_attempt, AccountId}, Excluded, 0),
                            case PoolMode =:= true andalso PoolAttempt < PoolRetries of
                                true ->
                                    logger:warning("Account ~p pool_mode retry ~p/~p (code ~p)",
                                                   [AccountId, PoolAttempt + 1, PoolRetries, Code]),
                                    NewExcluded = Excluded#{{pool_attempt, AccountId} => PoolAttempt + 1},
                                    do_failover(Req, ForwardFun, NewExcluded, Attempt + 1, MaxSwitches);
                                false ->
                                    _ = bump_counter(account_switch),
                                    logger:warning("Account ~p returned ~p, switching (attempt ~p/~p)",
                                                   [AccountId, Code, Attempt + 1, MaxSwitches]),
                                    NewExcluded = Excluded#{AccountId => true},
                                    do_failover(Req, ForwardFun, NewExcluded, Attempt + 1, MaxSwitches)
                            end;
                        false ->
                            {error, {http, Code}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, no_available_account} ->
            {error, no_available_account}
    end.

%% Layer 2: Score-based selection via CLIPS scheduling.clp rules
select_by_score(Req) ->
    _ = bump_counter(lb_select),
    Platform = maps:get(platform, Req, undefined),
    ExcludedIds = maps:get(excluded_ids, Req, #{}),
    UserId = maps:get(user_id, Req, undefined),
    UserGroups = get_user_group_ids(UserId),
    case ersub_platform_sup:list_accounts() of
        [] ->
            select_from_db(Platform, ExcludedIds, UserGroups);
        AccountIds ->
            Candidates = lists:filtermap(fun(Id) ->
                case is_map_key(Id, ExcludedIds) of
                    true -> false;
                    false ->
                        case account_matches_user_groups(Id, UserGroups) of
                            false -> false;
                            true ->
                                try
                                    Stats = ersub_account_srv:get_stats(Id),
                                    case maps:get(status, Stats) =:= active of
                                        true -> {true, Stats};
                                        false -> false
                                    end
                                catch _:_ -> false
                                end
                        end
                end
            end, AccountIds),
            select_best_candidate_clips(Candidates, Req)
    end.

select_best_candidate_clips([], _Req) ->
    {error, no_available_account};
select_best_candidate_clips(Candidates, _Req) ->
    %% S03: Check if advanced scheduler is enabled (DB setting, 5s cache)
    AdvancedEnabled = ersub_config_srv:get(advanced_scheduler_enabled, true),
    case AdvancedEnabled of
        false ->
            %% Fallback: simple priority sort
            Sorted = lists:sort(fun(A, B) ->
                maps:get(priority, A, 100) =< maps:get(priority, B, 100)
            end, Candidates),
            [Best | _] = Sorted,
            get_full_account(maps:get(id, Best));
        _ ->
            select_via_clips(Candidates)
    end.

select_via_clips(Candidates) ->
    %% Score all candidates via CLIPS scheduling.clp rules
    Weights = #{
        priority => ersub_config_srv:get(scheduling_score_weights_priority, 1.0),
        load => ersub_config_srv:get(scheduling_score_weights_load, 1.0),
        queue => ersub_config_srv:get(scheduling_score_weights_queue, 0.7),
        error_rate => ersub_config_srv:get(scheduling_score_weights_error_rate, 0.8),
        ttft => ersub_config_srv:get(scheduling_score_weights_ttft, 0.5)
    },
    case ersub_clips_pool:select_account(Candidates, Weights) of
        {ok, Scores} when length(Scores) > 0 ->
            %% Pick best from CLIPS scores (top-k weighted random)
            ValidScores = [{maps:get(<<"score">>, S, 0.0), maps:get(<<"id">>, S, 0)}
                           || S <- Scores, maps:get(<<"score">>, S, -1) >= 0],
            case ValidScores of
                [] -> {error, no_available_account};
                _ ->
                    Sorted = lists:reverse(lists:keysort(1, ValidScores)),
                    TopK = min(ersub_config_srv:get(scheduling_top_k, 7), length(Sorted)),
                    Top = lists:sublist(Sorted, TopK),
                    {_, SelectedId} = pick_weighted_random(Top),
                    get_full_account(SelectedId)
            end;
        _ ->
            {error, no_available_account}
    end.

select_from_db(Platform, ExcludedIds, UserGroups) ->
    Filters = case Platform of
        undefined -> #{status => <<"active">>};
        P -> #{status => <<"active">>, platform => P}
    end,
    case ersub_repo:list_accounts(Filters) of
        {ok, Accounts} ->
            Available = [A || A <- Accounts,
                         not is_map_key(maps:get(id, A), ExcludedIds),
                         maps:get(schedulable, A, true) =:= true,
                         not ersub_repo:has_disabled_proxy(maps:get(id, A)),
                         account_matches_user_groups(maps:get(id, A), UserGroups)],
            case Available of
                [] -> {error, no_available_account};
                [First | _] -> ersub_repo:get_account(maps:get(id, First))
            end;
        {error, _} ->
            {error, no_available_account}
    end.

get_account_if_schedulable(AccountId) ->
    try
        case ersub_account_srv:is_schedulable(AccountId) of
            true ->
                %% Skip accounts whose proxy is disabled
                case ersub_repo:has_disabled_proxy(AccountId) of
                    true -> {error, proxy_disabled};
                    false -> get_full_account(AccountId)
                end;
            false -> {error, not_schedulable}
        end
    catch _:_ ->
        %% Process not running, try DB
        ersub_repo:get_account(AccountId)
    end.

get_full_account(AccountId) ->
    try
        State = ersub_account_srv:get_state(AccountId),
        {ok, State}
    catch _:_ ->
        ersub_repo:get_account(AccountId)
    end.

pick_weighted_random([{_Score, C}]) ->
    {0, C};
pick_weighted_random(Candidates) ->
    %% Simple: uniform random from top-k
    Idx = rand:uniform(length(Candidates)),
    lists:nth(Idx, Candidates).

%% Get group IDs that a user is allowed to access.
get_user_group_ids(undefined) -> [];
get_user_group_ids(UserId) ->
    case ersub_repo:list_user_groups(UserId) of
        {ok, Groups} -> [maps:get(id, G) || G <- Groups];
        _ -> []
    end.

%% Check if an account belongs to at least one of the user's allowed groups.
%% If user has no groups (empty list), no account matches.
%% If account has no group bindings, it also does not match.
account_matches_user_groups(_AccountId, []) -> false;
account_matches_user_groups(AccountId, UserGroupIds) ->
    case ersub_repo:list_account_groups(AccountId) of
        {ok, AccountGroupIds} ->
            lists:any(fun(G) -> lists:member(G, UserGroupIds) end, AccountGroupIds);
        _ -> false
    end.

bump_counter(Key) ->
    try ets:update_counter(?METRICS_TABLE, Key, {2, 1})
    catch error:badarg -> 0
    end.

read_counter(Key) ->
    try ets:lookup_element(?METRICS_TABLE, Key, 2)
    catch error:badarg -> 0
    end.
