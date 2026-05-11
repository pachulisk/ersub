-module(ersub_wechat).

-export([create_order/3, verify_callback/1, is_available/0]).

%% WeChat Pay integration status: SCAFFOLD — not production-ready.
%% Requires API v3 key signing and WeChat Pay API implementation.

-spec is_available() -> false.
is_available() -> false.

-spec create_order(integer(), number(), binary()) -> {error, term()}.
create_order(_UserId, _AmountCny, _NotifyUrl) ->
    {error, {provider_unavailable, <<"WeChat Pay integration not yet implemented">>}}.

-spec verify_callback(map()) -> false.
verify_callback(_Params) -> false.
