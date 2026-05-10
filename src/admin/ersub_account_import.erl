-module(ersub_account_import).

-export([import_accounts/1]).

%% Bulk import accounts from a list of maps.
%% Validates required fields, deduplicates by name, bulk inserts,
%% and starts account processes.
%%
%% Returns {ok, #{created => N, skipped => M}} | {error, term()}.
-spec import_accounts([map()]) -> {ok, map()} | {error, term()}.
import_accounts(AccountList) when is_list(AccountList) ->
    %% Step 1: Validate and normalize all entries
    {Valid, Invalid} = lists:partition(fun validate_account/1, AccountList),
    SkippedValidation = length(Invalid),

    %% Step 2: Deduplicate by name within the input list (keep first occurrence)
    Deduped = deduplicate_by_name(Valid),
    SkippedDupes = length(Valid) - length(Deduped),

    %% Step 3: Check which names already exist in the database
    {ToInsert, SkippedExisting} = filter_existing(Deduped),

    %% Step 4: Insert and start processes
    {Created, SkippedInsert} = do_bulk_insert(ToInsert),

    TotalSkipped = SkippedValidation + SkippedDupes + SkippedExisting + SkippedInsert,
    {ok, #{created => Created, skipped => TotalSkipped}};

import_accounts(_) ->
    {error, invalid_input}.

%%% Internal

validate_account(Acc) ->
    Name = get_field(Acc, name, <<"name">>),
    Platform = get_field(Acc, platform, <<"platform">>),
    AccountType = get_field(Acc, account_type, <<"account_type">>),
    Creds = get_field(Acc, credentials, <<"credentials">>),
    is_binary(Name) andalso byte_size(Name) > 0 andalso
    is_binary(Platform) andalso byte_size(Platform) > 0 andalso
    is_binary(AccountType) andalso byte_size(AccountType) > 0 andalso
    is_map(Creds).

deduplicate_by_name(Accounts) ->
    {_, Result} = lists:foldl(fun(Acc, {Seen, Kept}) ->
        Name = get_field(Acc, name, <<"name">>),
        case maps:is_key(Name, Seen) of
            true -> {Seen, Kept};
            false -> {Seen#{Name => true}, [Acc | Kept]}
        end
    end, {#{}, []}, Accounts),
    lists:reverse(Result).

filter_existing(Accounts) ->
    case Accounts of
        [] ->
            {[], 0};
        _ ->
            Names = [get_field(A, name, <<"name">>) || A <- Accounts],
            %% Query for existing names
            ExistingNames = case query_existing_names(Names) of
                {ok, Existing} -> Existing;
                {error, _} -> []
            end,
            ExistingSet = sets:from_list(ExistingNames),
            {ToInsert, Skipped} = lists:partition(fun(Acc) ->
                Name = get_field(Acc, name, <<"name">>),
                not sets:is_element(Name, ExistingSet)
            end, Accounts),
            {ToInsert, length(Skipped)}
    end.

query_existing_names(Names) ->
    %% Build parameterized query for name lookup
    {Placeholders, _} = lists:foldl(fun(_, {Acc, Idx}) ->
        P = "$" ++ integer_to_list(Idx),
        {[P | Acc], Idx + 1}
    end, {[], 1}, Names),
    PlaceholderStr = string:join(lists:reverse(Placeholders), ", "),
    SQL = "SELECT name FROM accounts WHERE name IN (" ++ PlaceholderStr ++ ")",
    case ersub_repo:query(SQL, Names) of
        {ok, _, Rows} -> {ok, [N || {N} <- Rows]};
        {error, Reason} -> {error, Reason}
    end.

do_bulk_insert(Accounts) ->
    Results = lists:map(fun(Acc) ->
        Attrs = normalize_attrs(Acc),
        case ersub_repo:create_account(Attrs) of
            {ok, Created} ->
                %% Start account process
                AccountId = maps:get(id, Created),
                case ersub_repo:get_account(AccountId) of
                    {ok, FullAcc} ->
                        catch ersub_platform_sup:start_account(FullAcc);
                    _ ->
                        ok
                end,
                created;
            {error, Reason} ->
                logger:warning("Failed to import account ~s: ~p",
                              [maps:get(name, Attrs), Reason]),
                skipped
        end
    end, Accounts),
    Created = length([x || created <- Results]),
    Skipped = length([x || skipped <- Results]),
    {Created, Skipped}.

normalize_attrs(Acc) ->
    #{
        name => get_field(Acc, name, <<"name">>),
        platform => get_field(Acc, platform, <<"platform">>),
        account_type => get_field(Acc, account_type, <<"account_type">>),
        credentials => get_field(Acc, credentials, <<"credentials">>),
        priority => get_field_default(Acc, priority, <<"priority">>, 100),
        concurrency => get_field_default(Acc, concurrency, <<"concurrency">>, 5)
    }.

%% Get a field value from a map, trying both atom and binary keys.
get_field(Map, AtomKey, BinKey) ->
    case maps:get(AtomKey, Map, undefined) of
        undefined -> maps:get(BinKey, Map, undefined);
        V -> V
    end.

get_field_default(Map, AtomKey, BinKey, Default) ->
    case get_field(Map, AtomKey, BinKey) of
        undefined -> Default;
        V -> V
    end.
