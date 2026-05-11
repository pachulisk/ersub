-module(ersub_totp).

-export([generate_secret/0, generate_uri/2, verify_token/2]).

-define(PERIOD, 30).
-define(DIGITS, 6).

%% Generate a random TOTP secret (base32 encoded).
-spec generate_secret() -> binary().
generate_secret() ->
    Raw = crypto:strong_rand_bytes(20),
    base32_encode(Raw).

%% Generate otpauth:// URI for QR code.
-spec generate_uri(binary(), binary()) -> binary().
generate_uri(Email, Secret) ->
    iolist_to_binary([
        <<"otpauth://totp/ErSub:">>, Email,
        <<"?secret=">>, Secret,
        <<"&issuer=ErSub">>,
        <<"&algorithm=SHA1">>,
        <<"&digits=6">>,
        <<"&period=30">>
    ]).

%% Verify a TOTP token against a secret.
%% Allows ±1 time step drift.
-spec verify_token(binary(), binary()) -> boolean().
verify_token(Token, Secret) when is_binary(Token), is_binary(Secret) ->
    TokenInt = try binary_to_integer(Token)
               catch _:_ -> -1
               end,
    case TokenInt of
        -1 -> false;
        _ ->
            RawSecret = base32_decode(Secret),
            Now = erlang:system_time(second),
            TimeStep = Now div ?PERIOD,
            lists:any(fun(Offset) ->
                Expected = generate_otp(RawSecret, TimeStep + Offset),
                Expected =:= TokenInt
            end, [-1, 0, 1])
    end.

%%% Internal

generate_otp(Secret, Counter) ->
    CounterBin = <<Counter:64/big-unsigned-integer>>,
    Hmac = crypto:mac(hmac, sha, Secret, CounterBin),
    <<_:19/binary, LastByte:8>> = Hmac,
    Offset = LastByte band 16#0f,
    <<_:Offset/binary, _:1, Code:31/big-unsigned-integer, _/binary>> = Hmac,
    Code rem trunc(math:pow(10, ?DIGITS)).

%% Base32 encoding/decoding (RFC 4648)
base32_encode(Bin) ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>,
    encode32(Bin, Alphabet, <<>>).

encode32(<<>>, _, Acc) -> Acc;
encode32(Bin, Alpha, Acc) ->
    case Bin of
        <<V:5, Rest/bitstring>> ->
            C = binary:at(Alpha, V),
            encode32(Rest, Alpha, <<Acc/binary, C>>);
        <<V:4>> ->
            C = binary:at(Alpha, V bsl 1),
            <<Acc/binary, C>>;
        <<V:3>> ->
            C = binary:at(Alpha, V bsl 2),
            <<Acc/binary, C>>;
        <<V:2>> ->
            C = binary:at(Alpha, V bsl 3),
            <<Acc/binary, C>>;
        <<V:1>> ->
            C = binary:at(Alpha, V bsl 4),
            <<Acc/binary, C>>
    end.

base32_decode(Bin) ->
    decode32(Bin, <<>>).

decode32(<<>>, Acc) -> Acc;
decode32(<<C, Rest/binary>>, Acc) ->
    V = b32_val(C),
    decode32(Rest, <<Acc/bitstring, V:5>>).

b32_val(C) when C >= $A, C =< $Z -> C - $A;
b32_val(C) when C >= $a, C =< $z -> C - $a;
b32_val(C) when C >= $2, C =< $7 -> C - $2 + 26;
b32_val($=) -> 0;
b32_val(_) -> 0.
