-module(ersub_scheduler_prop).
-include_lib("eunit/include/eunit.hrl").

score_bounded_test() ->
    [begin
        P = rand:uniform(100),
        LR = rand:uniform() * 1.0,
        WC = rand:uniform(20) - 1,
        ER = rand:uniform() * 1.0,
        TTFT = rand:uniform() * 5000.0,
        NP = (100 - P) / 100,
        NL = 1.0 - erlang:min(LR, 1.0),
        NQ = 1.0 - WC / 20,
        NE = 1.0 - ER,
        NT = 1.0 - TTFT / 5000.0,
        Score = 1.0 * NP + 1.0 * NL + 0.7 * NQ + 0.8 * NE + 0.5 * NT,
        ?assert(Score >= -1.0),
        ?assert(Score =< 5.0)
    end || _ <- lists:seq(1, 500)].

lower_priority_wins_test() ->
    %% Account with lower priority number should score higher (all else equal)
    [begin
        LR = 0.5, WC = 0, ER = 0.0, TTFT = 100.0,
        S_low = score(5, LR, WC, ER, TTFT),
        S_high = score(95, LR, WC, ER, TTFT),
        ?assert(S_low > S_high)
    end || _ <- lists:seq(1, 50)].

score(P, LR, WC, ER, TTFT) ->
    NP = (100 - P) / 100,
    NL = 1.0 - erlang:min(LR, 1.0),
    NQ = 1.0 - WC / 20,
    NE = 1.0 - ER,
    NT = 1.0 - TTFT / 5000.0,
    1.0 * NP + 1.0 * NL + 0.7 * NQ + 0.8 * NE + 0.5 * NT.
