-module(ersub_auth_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([generate_jwt/1, verify_jwt/1, hash_password/1, verify_password/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SERVER, ?MODULE).

%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Generate a JWT token for a user.
-spec generate_jwt(map()) -> {ok, binary()}.
generate_jwt(Claims) ->
    Secret = get_jwt_secret(),
    ExpireHours = ersub_config_srv:get(auth_jwt_expire_hours, 24),
    Now = erlang:system_time(second),
    Exp = Now + (ExpireHours * 3600),
    Payload = maps:merge(Claims, #{
        <<"iat">> => Now,
        <<"exp">> => Exp
    }),
    Jwk = jose_jwk:from_oct(Secret),
    Jws = #{<<"alg">> => <<"HS256">>},
    {_, Token} = jose_jws:compact(jose_jwt:sign(Jwk, Jws, Payload)),
    {ok, Token}.

%% Verify and decode a JWT token.
-spec verify_jwt(binary()) -> {ok, map()} | {error, term()}.
verify_jwt(Token) ->
    Secret = get_jwt_secret(),
    Jwk = jose_jwk:from_oct(Secret),
    case jose_jwt:verify(Jwk, Token) of
        {true, {jose_jwt, Claims}, _Jws} ->
            Now = erlang:system_time(second),
            Exp = maps:get(<<"exp">>, Claims, 0),
            case Exp > Now of
                true -> {ok, Claims};
                false -> {error, token_expired}
            end;
        {false, _, _} ->
            {error, invalid_signature}
    end.

%% Hash a password using SHA-256 with salt (simple for MVP).
%% TODO: Use bcrypt/argon2 for production.
-spec hash_password(binary()) -> binary().
hash_password(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    Hash = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
    SaltHex = binary:encode_hex(Salt),
    HashHex = binary:encode_hex(Hash),
    <<"sha256:", SaltHex/binary, ":", HashHex/binary>>.

%% Verify a password against a stored hash.
-spec verify_password(binary(), binary()) -> boolean().
verify_password(Password, <<"sha256:", Rest/binary>>) ->
    case binary:split(Rest, <<":">>) of
        [SaltHex, HashHex] ->
            Salt = binary:decode_hex(SaltHex),
            Expected = binary:decode_hex(HashHex),
            Actual = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
            crypto:hash_equals(Expected, Actual);
        _ ->
            false
    end;
verify_password(_, _) ->
    false.

%%% gen_server callbacks

init([]) ->
    logger:info("Auth service started"),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

get_jwt_secret() ->
    case ersub_config_srv:get(auth_jwt_secret, <<>>) of
        <<>> -> <<"ersub-default-jwt-secret-change-me">>;
        S when is_list(S) -> list_to_binary(S);
        S when is_binary(S) -> S
    end.
