;;; ErSub Quota Rules
;;; Daily/weekly/monthly quota checking

(defrule check-daily-exceeded
    (subscription-quota (user-id ?uid) (daily-limit ?dl) (daily-usage ?du)
                        (additional-cost ?ac))
    (test (> ?dl 0))
    (test (> (+ ?du ?ac) ?dl))
    =>
    (assert (quota-violation (user-id ?uid) (type daily)
             (limit ?dl) (usage ?du) (requested ?ac)))
)

(defrule check-weekly-exceeded
    (subscription-quota (user-id ?uid) (weekly-limit ?wl) (weekly-usage ?wu)
                        (additional-cost ?ac))
    (test (> ?wl 0))
    (test (> (+ ?wu ?ac) ?wl))
    =>
    (assert (quota-violation (user-id ?uid) (type weekly)
             (limit ?wl) (usage ?wu) (requested ?ac)))
)

(defrule check-monthly-exceeded
    (subscription-quota (user-id ?uid) (monthly-limit ?ml) (monthly-usage ?mu)
                        (additional-cost ?ac))
    (test (> ?ml 0))
    (test (> (+ ?mu ?ac) ?ml))
    =>
    (assert (quota-violation (user-id ?uid) (type monthly)
             (limit ?ml) (usage ?mu) (requested ?ac)))
)

(defrule quota-ok
    "All quotas pass — no violations found"
    (subscription-quota (user-id ?uid))
    (not (quota-violation (user-id ?uid)))
    =>
    (assert (quota-check-result (user-id ?uid) (allowed TRUE)))
)
