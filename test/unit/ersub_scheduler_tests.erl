-module(ersub_scheduler_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test scoring helpers extracted from scheduler logic

normalize_priority_test_() ->
    [
        {"lowest priority number = highest score", fun() ->
            ?assert(normalize(1, 100) > normalize(50, 100))
        end},
        {"max priority = 0 score", fun() ->
            ?assertEqual(0.0, normalize(100, 100))
        end},
        {"zero priority = max score", fun() ->
            ?assertEqual(1.0, normalize(0, 100))
        end}
    ].

normalize(Priority, MaxPriority) ->
    (MaxPriority - Priority) / my_max(MaxPriority, 1).

load_score_test_() ->
    [
        {"zero load = max score", fun() ->
            ?assertEqual(1.0, 1.0 - my_min(0.0, 1.0))
        end},
        {"full load = zero score", fun() ->
            ?assertEqual(0.0, 1.0 - my_min(1.0, 1.0))
        end},
        {"over-loaded capped", fun() ->
            ?assertEqual(0.0, 1.0 - my_min(1.5, 1.0))
        end}
    ].

combined_score_test() ->
    %% Account with low priority number, low load, zero errors should score highest
    PW = 1.0, LW = 1.0, QW = 0.7, EW = 0.8, TW = 0.5,
    MaxP = 100, MaxW = 20, MaxT = 5000.0,

    ScoreA = score(10, 0.2, 0, 0.01, 100.0, PW, LW, QW, EW, TW, MaxP, MaxW, MaxT),
    ScoreB = score(50, 0.8, 5, 0.1, 500.0, PW, LW, QW, EW, TW, MaxP, MaxW, MaxT),
    ScoreC = score(5, 0.1, 0, 0.0, 50.0, PW, LW, QW, EW, TW, MaxP, MaxW, MaxT),

    ?assert(ScoreC > ScoreA),
    ?assert(ScoreA > ScoreB).

score(P, LR, WC, ER, TTFT, PW, LW, QW, EW, TW, MP, MW, MT) ->
    NP = (MP - P) / my_max(MP, 1),
    NL = 1.0 - my_min(LR, 1.0),
    NQ = 1.0 - WC / my_max(MW, 1),
    NE = 1.0 - ER,
    NT = 1.0 - TTFT / my_max(MT, 1.0),
    PW * NP + LW * NL + QW * NQ + EW * NE + TW * NT.

my_max(A, B) when A > B -> A;
my_max(_, B) -> B.

my_min(A, B) when A < B -> A;
my_min(_, B) -> B.
