-module(ersub_ets_bench).
-export([run/0]).

run() ->
    Tab = ets:new(bench_test, [set, public]),
    N = 100000,

    %% Write benchmark
    {WriteTime, _} = timer:tc(fun() ->
        [ets:insert(Tab, {I, #{value => I, data => <<"test">>}})
         || I <- lists:seq(1, N)]
    end),

    %% Read benchmark
    {ReadTime, _} = timer:tc(fun() ->
        [ets:lookup(Tab, rand:uniform(N))
         || _ <- lists:seq(1, N)]
    end),

    io:format("ETS write: ~.0f ops/s (~.1f us/op)~n",
              [N * 1000000 / WriteTime, WriteTime / N]),
    io:format("ETS read:  ~.0f ops/s (~.1f us/op)~n",
              [N * 1000000 / ReadTime, ReadTime / N]),

    ets:delete(Tab).
