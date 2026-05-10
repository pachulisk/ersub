-module(ersub_platform_sup).
-behaviour(supervisor).

-export([start_link/0, start_account/1, stop_account/1, list_accounts/0,
         load_all_accounts/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 20,
        period => 60
    },
    {ok, {SupFlags, []}}.

%% Dynamically start an account process.
-spec start_account(map()) -> {ok, pid()} | {error, term()}.
start_account(AccountData) ->
    Id = maps:get(id, AccountData),
    ChildSpec = #{
        id => {account, Id},
        start => {ersub_account_srv, start_link, [AccountData]},
        restart => transient,
        shutdown => 5000,
        type => worker
    },
    case supervisor:start_child(?SERVER, ChildSpec) of
        {ok, Pid} ->
            logger:info("Started account process ~p (platform=~s)",
                        [Id, maps:get(platform, AccountData, <<"unknown">>)]),
            {ok, Pid};
        {error, {already_started, Pid}} ->
            {ok, Pid};
        {error, Reason} ->
            logger:error("Failed to start account ~p: ~p", [Id, Reason]),
            {error, Reason}
    end.

%% Stop an account process.
-spec stop_account(integer()) -> ok | {error, term()}.
stop_account(Id) ->
    case supervisor:terminate_child(?SERVER, {account, Id}) of
        ok ->
            supervisor:delete_child(?SERVER, {account, Id}),
            ok;
        {error, not_found} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%% List all running account process IDs.
-spec list_accounts() -> [integer()].
list_accounts() ->
    Children = supervisor:which_children(?SERVER),
    [Id || {{account, Id}, Pid, _, _} <- Children, is_pid(Pid)].

load_all_accounts() ->
    case ersub_repo:list_accounts(#{status => <<"active">>}) of
        {ok, Accounts} ->
            Results = lists:map(fun(Acc) ->
                case ersub_repo:get_account(maps:get(id, Acc)) of
                    {ok, FullAcc} -> start_account(FullAcc);
                    {error, _} = Err -> Err
                end
            end, Accounts),
            Started = length([ok || {ok, _} <- Results]),
            logger:info("Loaded ~p/~p active accounts", [Started, length(Accounts)]),
            ok;
        {error, Reason} ->
            logger:error("Failed to load accounts: ~p", [Reason]),
            {error, Reason}
    end.
