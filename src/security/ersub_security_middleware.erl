-module(ersub_security_middleware).

-export([apply_security_headers/1, apply_cors_headers/2, handle_preflight/1,
         check_backend_mode/1, check_backend_mode/2, check_content_length/2]).

%% Apply security headers to a response.
-spec apply_security_headers(cowboy_req:req()) -> cowboy_req:req().

apply_security_headers(Req) ->
    Nonce = generate_nonce(),
    CSP = build_csp(Nonce),
    cowboy_req:set_resp_headers(#{
        <<"content-security-policy">> => CSP,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"x-frame-options">> => <<"DENY">>,
        <<"x-xss-protection">> => <<"1; mode=block">>,
        <<"referrer-policy">> => <<"strict-origin-when-cross-origin">>,
        <<"x-csp-nonce">> => Nonce
    }, Req).

%% Apply CORS headers based on origin.
-spec apply_cors_headers(cowboy_req:req(), [binary()]) -> cowboy_req:req().

apply_cors_headers(Req, AllowedOrigins) ->
    Origin = cowboy_req:header(<<"origin">>, Req, <<>>),
    case is_allowed_origin(Origin, AllowedOrigins) of
        true ->
            cowboy_req:set_resp_headers(#{
                <<"access-control-allow-origin">> => Origin,
                <<"access-control-allow-methods">> => <<"GET, POST, PUT, DELETE, OPTIONS">>,
                <<"access-control-allow-headers">> => <<"Content-Type, Authorization, x-api-key, anthropic-version, anthropic-beta">>,
                <<"access-control-max-age">> => <<"86400">>,
                <<"access-control-allow-credentials">> => <<"true">>
            }, Req);
        false ->
            Req
    end.

%% Handle OPTIONS preflight request.
-spec handle_preflight(cowboy_req:req()) -> cowboy_req:req().

handle_preflight(Req0) ->
    AllowedOrigins = get_allowed_origins(),
    Req = apply_cors_headers(Req0, AllowedOrigins),
    cowboy_req:reply(204, #{}, <<>>, Req).

%% Check if backend is in read-only mode.
%% Accepts either a binary method or {Method, IsAdmin} tuple.
%% Admin users always bypass read-only mode.
%% Whitelisted paths (/health, /api/v1/auth/*) are always allowed.
-spec check_backend_mode(binary() | {binary(), boolean()}) -> ok | {error, read_only}.

check_backend_mode({_Method, true}) -> ok;
check_backend_mode({Method, false}) -> check_backend_mode(Method);
check_backend_mode(<<"GET">>) -> ok;
check_backend_mode(<<"HEAD">>) -> ok;
check_backend_mode(<<"OPTIONS">>) -> ok;
check_backend_mode(_Method) ->
    case ersub_config_srv:get(backend_mode, <<"standard">>) of
        <<"read_only">> -> {error, read_only};
        _ -> ok
    end.

%% Check backend mode with path-based whitelist.
%% Whitelisted paths (/health, /api/v1/auth/*) are always allowed regardless of mode.
-spec check_backend_mode(binary() | {binary(), boolean()}, binary()) ->
    ok | {error, read_only}.

check_backend_mode(_MethodOrTuple, <<"/health", _/binary>>) -> ok;
check_backend_mode(_MethodOrTuple, <<"/api/v1/auth/", _/binary>>) -> ok;
check_backend_mode({_Method, true}, _Path) -> ok;
check_backend_mode({Method, false}, Path) -> check_backend_mode(Method, Path);
check_backend_mode(Method, _Path) -> check_backend_mode(Method).

%% Check Content-Length header against maximum allowed size.
%% MaxBytes is the maximum allowed content length in bytes.
-spec check_content_length(cowboy_req:req(), non_neg_integer()) ->
    ok | {error, payload_too_large}.

check_content_length(Req, MaxBytes) ->
    case cowboy_req:header(<<"content-length">>, Req) of
        undefined -> ok;
        LenBin ->
            try binary_to_integer(LenBin) of
                Len when Len =< MaxBytes -> ok;
                _ -> {error, payload_too_large}
            catch
                _:_ -> ok
            end
    end.

%%% Internal

generate_nonce() ->
    base64:encode(crypto:strong_rand_bytes(16)).

build_csp(Nonce) ->
    iolist_to_binary([
        <<"default-src 'self'; ">>,
        <<"script-src 'self' 'nonce-">>, Nonce, <<"' https://challenges.cloudflare.com; ">>,
        <<"style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; ">>,
        <<"img-src 'self' data: https:; ">>,
        <<"font-src 'self' data:; ">>,
        <<"frame-src https://challenges.cloudflare.com https://*.stripe.com; ">>,
        <<"frame-ancestors 'none'; ">>,
        <<"form-action 'self'; ">>,
        <<"base-uri 'self'">>
    ]).

is_allowed_origin(<<>>, _) -> false;
is_allowed_origin(_, []) -> false;
is_allowed_origin(Origin, Origins) ->
    lists:member(Origin, Origins) orelse lists:member(<<"*">>, Origins).

get_allowed_origins() ->
    case ersub_config_srv:get(security_cors_allowed_origins, []) of
        L when is_list(L) -> L;
        _ -> []
    end.
