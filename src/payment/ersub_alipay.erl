-module(ersub_alipay).

-export([create_order/3, verify_callback/1, is_available/0]).

%% Alipay integration status: SCAFFOLD — not production-ready.
%% Requires RSA key signing and Alipay gateway API implementation.

-spec is_available() -> boolean().
is_available() -> false.

-spec create_order(integer(), number(), binary()) -> {ok, map()} | {error, term()}.
create_order(_UserId, _AmountCny, _NotifyUrl) ->
    {error, {provider_unavailable, <<"Alipay integration not yet implemented">>}}.

-spec verify_callback(map()) -> boolean().
verify_callback(_Params) -> false.
