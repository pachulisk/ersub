-module(ersub_security_middleware).

-export([apply_security_headers/1, apply_cors_headers/2, handle_preflight/1]).

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
