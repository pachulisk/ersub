-module(ersub_image_limiter).

-export([acquire/0, release/0, init/0]).

-define(COUNTER, ersub_image_conc).
-define(MAX_KEY, ersub_image_max_concurrent).

init() ->
    case persistent_term:get(?COUNTER, undefined) of
        undefined ->
            Ref = counters:new(1, []),
            persistent_term:put(?COUNTER, Ref);
        _ -> ok
    end.

-spec acquire() -> ok | {error, image_concurrency_full}.
acquire() ->
    Ref = persistent_term:get(?COUNTER),
    Max = ersub_config_srv:get(gateway_image_max_concurrent, 10),
    Current = counters:get(Ref, 1),
    case Current < Max of
        true ->
            counters:add(Ref, 1, 1),
            ok;
        false ->
            {error, image_concurrency_full}
    end.

-spec release() -> ok.
release() ->
    Ref = persistent_term:get(?COUNTER),
    counters:sub(Ref, 1, 1),
    ok.
