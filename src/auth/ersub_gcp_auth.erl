-module(ersub_gcp_auth).

-export([get_access_token/1]).

%% Get an access token for a Google Service Account.
%% Credentials map must contain: client_email, private_key, token_uri.
-spec get_access_token(map()) -> {ok, binary()} | {error, term()}.
get_access_token(Credentials) ->
    Email = maps:get(<<"client_email">>, Credentials, <<>>),
    PrivateKeyPem = maps:get(<<"private_key">>, Credentials, <<>>),
    TokenUri = maps:get(<<"token_uri">>, Credentials,
                        <<"https://oauth2.googleapis.com/token">>),
    Scope = <<"https://www.googleapis.com/auth/cloud-platform">>,

    %% 1. Create JWT assertion
    Now = erlang:system_time(second),
    Header = #{<<"alg">> => <<"RS256">>, <<"typ">> => <<"JWT">>},
    Payload = #{
        <<"iss">> => Email,
        <<"scope">> => Scope,
        <<"aud">> => TokenUri,
        <<"iat">> => Now,
        <<"exp">> => Now + 3600
    },

    %% 2. Sign JWT with RSA private key
    case sign_jwt(Header, Payload, PrivateKeyPem) of
        {ok, Assertion} ->
            %% 3. Exchange JWT for access token
            Body = uri_string:compose_query([
                {"grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"},
                {"assertion", binary_to_list(Assertion)}
            ]),
            Headers = [{<<"content-type">>, <<"application/x-www-form-urlencoded">>}],
            case ersub_upstream_pool:request(<<"POST">>, TokenUri, Headers,
                                             list_to_binary(Body), #{}, 10000) of
                {ok, 200, _, RespBody} ->
                    Resp = jsx:decode(RespBody, [return_maps]),
                    {ok, maps:get(<<"access_token">>, Resp)};
                {ok, Status, _, RespBody} ->
                    {error, {token_exchange_failed, Status, RespBody}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, {jwt_sign_failed, Reason}}
    end.

%%% Internal

sign_jwt(Header, Payload, PrivateKeyPem) ->
    try
        HeaderB64 = base64url_encode(jsx:encode(Header)),
        PayloadB64 = base64url_encode(jsx:encode(Payload)),
        SignInput = <<HeaderB64/binary, ".", PayloadB64/binary>>,
        %% Parse PEM private key
        [Entry | _] = public_key:pem_decode(PrivateKeyPem),
        Key = public_key:pem_entry_decode(Entry),
        Signature = public_key:sign(SignInput, sha256, Key),
        SigB64 = base64url_encode(Signature),
        {ok, <<SignInput/binary, ".", SigB64/binary>>}
    catch
        _:Reason ->
            {error, Reason}
    end.

base64url_encode(Data) ->
    B64 = base64:encode(Data),
    B64_1 = binary:replace(B64, <<"+">>, <<"-">>, [global]),
    B64_2 = binary:replace(B64_1, <<"/">>, <<"_">>, [global]),
    binary:replace(B64_2, <<"=">>, <<>>, [global]).
