-module(ersub_scheduler_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([select_account/1, select_with_failover/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Select the best account for a request.
%% Checks sticky session first, then scores candidates.
-spec select_account(map()) -> {ok, map()} | {error, no_available_account}.
select_account(Req) ->
    #{user_id := UserId} = Req,
    SessionHash = maps:get(session_hash, Req, <<>>),
    ExcludedIds = maps:get(excluded_ids, Req, #{}),

    %% Layer 1: Sticky session check
    case SessionHash =/= <<>> andalso ersub_session_srv:lookup(UserId, SessionHash) of
        {ok, AccountId} when not is_map_key(AccountId, ExcludedIds) ->
            case get_account_if_schedulable(AccountId) of
                {ok, Account} -> {ok, Account};
                _ -> select_by_score(Req)
            end;
        _ ->
            select_by_score(Req)
    end.

%% Select with automatic failover on retriable errors.
-spec select_with_failover(map(), fun((map()) -> {ok, term()} | {error, term()})) ->
    {ok, term()} | {error, term()}.
select_with_failover(Req, ForwardFun) ->
    MaxSwitches = ersub_config_srv:get(gateway_max_account_switches, 10),
    do_failover(Req, ForwardFun, #{}, 0, MaxSwitches).

%%% gen_server callbacks

init([]) ->
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
                {error, {http, Code}} when Code =:= 429; Code =:= 502; Code =:= 503; Code =:= 529 ->
                    %% Retriable error — mark account and try next
                    ersub_account_srv:record_error(AccountId, Code),
                    logger:warning("Account ~p returned ~p, failover attempt ~p/~p",
                                   [AccountId, Code, Attempt + 1, MaxSwitches]),
                    NewExcluded = Excluded#{AccountId => true},
                    do_failover(Req, ForwardFun, NewExcluded, Attempt + 1, MaxSwitches);
                {error, Reason} ->
                    %% Non-retriable error
                    {error, Reason}
            end;
        {error, no_available_account} ->
            {error, no_available_account}
    end.

%% Layer 2: Score-based selection via CLIPS scheduling.clp rules
select_by_score(Req) ->
    Platform = maps:get(platform, Req, undefined),
    ExcludedIds = maps:get(excluded_ids, Req, #{}),
    case ersub_platform_sup:list_accounts() of
        [] ->
            select_from_db(Platform, ExcludedIds);
        AccountIds ->
            Candidates = lists:filtermap(fun(Id) ->
                case is_map_key(Id, ExcludedIds) of
                    true -> false;
                    false ->
                        try
                            Stats = ersub_account_srv:get_stats(Id),
                            case maps:get(status, Stats) =:= active of
                                true -> {true, Stats};
                                false -> false
                            end
                        catch _:_ -> false
                        end
                end
            end, AccountIds),
            select_best_candidate_clips(Candidates, Req)
    end.

select_best_candidate_clips([], _Req) ->
    {error, no_available_account};
select_best_candidate_clips(Candidates, _Req) ->
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

select_from_db(Platform, ExcludedIds) ->
    Filters = case Platform of
        undefined -> #{status => <<"active">>};
        P -> #{status => <<"active">>, platform => P}
    end,
    case ersub_repo:list_accounts(Filters) of
        {ok, Accounts} ->
            Available = [A || A <- Accounts,
                         not is_map_key(maps:get(id, A), ExcludedIds),
                         maps:get(schedulable, A, true) =:= true],
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
            true -> get_full_account(AccountId);
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
