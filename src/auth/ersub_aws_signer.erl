-module(ersub_aws_signer).

-export([sign_request/5]).

%% Sign an HTTP request using AWS Signature Version 4.
%% Returns updated Headers list with Authorization, x-amz-date, x-amz-content-sha256.
-spec sign_request(binary(), binary(), [{binary(), binary()}], binary(), map()) ->
    [{binary(), binary()}].

sign_request(Method, Url, Headers, Body, Credentials) ->
    #{access_key := AccessKey, secret_key := SecretKey,
      region := Region, service := Service} = Credentials,

    %% 1. Create canonical request
    Now = calendar:universal_time(),
    {Date, Time} = Now,
    DateStamp = format_date(Date),
    AmzDate = format_amz_date(Date, Time),
    BodyHash = hex(crypto:hash(sha256, Body)),

    {Host, Path, Query} = parse_url_parts(Url),

    HeadersWithHost = [{<<"host">>, Host},
                       {<<"x-amz-date">>, AmzDate},
                       {<<"x-amz-content-sha256">>, BodyHash}
                       | Headers],

    SortedHeaders = lists:sort(fun({K1, _}, {K2, _}) ->
        string:lowercase(K1) =< string:lowercase(K2)
    end, HeadersWithHost),

    SignedHeaderNames = iolist_to_binary(
        lists:join(<<";"/utf8>>,
            [string:lowercase(K) || {K, _} <- SortedHeaders])),

    CanonicalHeaders = iolist_to_binary(
        [io_lib:format("~s:~s\n", [string:lowercase(K), string:trim(V)])
         || {K, V} <- SortedHeaders]),

    CanonicalRequest = iolist_to_binary([
        Method, <<"\n">>,
        Path, <<"\n">>,
        Query, <<"\n">>,
        CanonicalHeaders, <<"\n">>,
        SignedHeaderNames, <<"\n">>,
        BodyHash
    ]),

    %% 2. Create string to sign
    CredentialScope = iolist_to_binary([
        DateStamp, <<"/">>, Region, <<"/">>, Service, <<"/aws4_request">>
    ]),

    StringToSign = iolist_to_binary([
        <<"AWS4-HMAC-SHA256\n">>,
        AmzDate, <<"\n">>,
        CredentialScope, <<"\n">>,
        hex(crypto:hash(sha256, CanonicalRequest))
    ]),

    %% 3. Calculate signature
    DateKey = crypto:mac(hmac, sha256, <<"AWS4", SecretKey/binary>>, DateStamp),
    RegionKey = crypto:mac(hmac, sha256, DateKey, Region),
    ServiceKey = crypto:mac(hmac, sha256, RegionKey, Service),
    SigningKey = crypto:mac(hmac, sha256, ServiceKey, <<"aws4_request">>),
    Signature = hex(crypto:mac(hmac, sha256, SigningKey, StringToSign)),

    %% 4. Build Authorization header
    AuthHeader = iolist_to_binary([
        <<"AWS4-HMAC-SHA256 Credential=">>,
        AccessKey, <<"/">>, CredentialScope,
        <<", SignedHeaders=">>, SignedHeaderNames,
        <<", Signature=">>, Signature
    ]),

    [{<<"authorization">>, AuthHeader} | HeadersWithHost].

%%% Internal

format_date({Y, M, D}) ->
    iolist_to_binary(io_lib:format("~4..0B~2..0B~2..0B", [Y, M, D])).

format_amz_date({Y, M, D}, {H, Mi, S}) ->
    iolist_to_binary(io_lib:format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ",
                                    [Y, M, D, H, Mi, S])).

hex(Bin) ->
    string:lowercase(binary:encode_hex(Bin)).

parse_url_parts(Url) when is_binary(Url) ->
    parse_url_parts(binary_to_list(Url));
parse_url_parts(Url) ->
    case uri_string:parse(Url) of
        #{host := H} = P ->
            Path = case maps:get(path, P, "/") of "" -> "/"; Pa -> Pa end,
            Query = maps:get(query, P, ""),
            {list_to_binary(H), list_to_binary(Path), list_to_binary(Query)};
        _ ->
            {<<>>, <<"/">>, <<>>}
    end.
