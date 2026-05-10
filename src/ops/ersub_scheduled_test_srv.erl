-module(ersub_scheduled_test_srv).
-behaviour(gen_server).

-export([start_link/0, run_now/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(CHECK_INTERVAL_MS, 60000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

run_now(TestId) ->
    gen_server:cast(?SERVER, {run, TestId}).

init([]) ->
    schedule_check(),
    logger:info("Scheduled test service started"),
    {ok, #{}}.

handle_call(_, _From, State) -> {reply, ok, State}.
handle_cast({run, TestId}, State) ->
    run_test(TestId),
    {noreply, State};
handle_cast(_, State) -> {noreply, State}.

handle_info(check, State) ->
    check_due_tests(),
    schedule_check(),
    {noreply, State};
handle_info(_, State) -> {noreply, State}.

schedule_check() ->
    erlang:send_after(?CHECK_INTERVAL_MS, self(), check).

check_due_tests() ->
    case ersub_repo:squery(
        "SELECT id FROM scheduled_tests WHERE is_active = TRUE "
        "AND (last_run_at IS NULL OR "
        "last_run_at + (interval_s || ' seconds')::interval < NOW())") of
        {ok, _, Rows} ->
            lists:foreach(fun({Id}) -> run_test(binary_to_integer(Id)) end, Rows);
        _ -> ok
    end.

run_test(TestId) ->
    case ersub_repo:query(
        "SELECT account_id, model, test_prompt, timeout_ms, auto_recover "
        "FROM scheduled_tests WHERE id = $1", [TestId]) of
        {ok, _, [{AccountId, Model, Prompt, TimeoutMs, AutoRecover}]} ->
            %% Simple test: try to forward a small request
            Result = try
                Body = jsx:encode(#{
                    model => Model,
                    max_tokens => 10,
                    messages => [#{role => <<"user">>, content => Prompt}]
                }),
                case ersub_repo:get_account(AccountId) of
                    {ok, Account} ->
                        #{credentials := Creds, base_url := BaseUrl0} = Account,
                        ApiKey = maps:get(<<"api_key">>, Creds, <<>>),
                        BaseUrl = case BaseUrl0 of
                            B when B =:= null; B =:= undefined; B =:= <<>> -> <<"https://api.anthropic.com">>;
                            U -> U
                        end,
                        Url = <<BaseUrl/binary, "/v1/messages">>,
                        Headers = [{<<"content-type">>, <<"application/json">>},
                                   {<<"x-api-key">>, ApiKey},
                                   {<<"anthropic-version">>, <<"2023-06-01">>}],
                        Timeout = case TimeoutMs of
                            T when is_integer(T), T > 0 -> T;
                            T when is_binary(T) -> binary_to_integer(T);
                            _ -> 30000
                        end,
                        case ersub_upstream_pool:request(<<"POST">>, Url, Headers, Body, #{}, Timeout) of
                            {ok, Status, _, _} when Status >= 200, Status < 300 -> pass;
                            _ -> fail
                        end;
                    _ -> fail
                end
            catch _:_ -> fail
            end,
            %% Update result
            ersub_repo:query(
                "UPDATE scheduled_tests SET last_result = $2, last_run_at = NOW() WHERE id = $1",
                [TestId, atom_to_binary(Result)]),
            %% Auto-recover
            case {Result, AutoRecover} of
                {fail, true} ->
                    ersub_account_srv:update_status(AccountId, temp_unschedulable);
                {pass, true} ->
                    catch ersub_account_srv:update_status(AccountId, active);
                _ -> ok
            end;
        _ -> ok
    end.
