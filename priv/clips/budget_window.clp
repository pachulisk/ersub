;;; ErSub Budget Window Rules
;;; SetupToken 5-hour sliding window budget enforcement

(deftemplate budget-request
    (slot account-id (type INTEGER))
    (slot account-type (type STRING))
    (slot window-hours (type INTEGER) (default 5))
    (slot usage-in-window (type FLOAT))      ;; total cost in current window
    (slot budget-limit (type FLOAT))          ;; rate_limit_5h from API key
    (slot additional-cost (type FLOAT))       ;; estimated cost of this request
)

(deftemplate budget-result
    (slot allowed (type SYMBOL))             ;; TRUE | FALSE
    (slot remaining (type FLOAT))
    (slot reason (type STRING))
)

;; SetupToken with budget limit: check if within window
(defrule check-setup-token-budget
    (budget-request (account-type "setup_token")
                    (usage-in-window ?usage) (budget-limit ?limit)
                    (additional-cost ?cost))
    (test (> ?limit 0))
    (test (<= (+ ?usage ?cost) ?limit))
    =>
    (assert (budget-result (allowed TRUE)
             (remaining (- ?limit (+ ?usage ?cost)))
             (reason "within_budget")))
)

;; SetupToken budget exceeded
(defrule check-setup-token-exceeded
    (budget-request (account-type "setup_token")
                    (usage-in-window ?usage) (budget-limit ?limit)
                    (additional-cost ?cost))
    (test (> ?limit 0))
    (test (> (+ ?usage ?cost) ?limit))
    =>
    (assert (budget-result (allowed FALSE)
             (remaining (- ?limit ?usage))
             (reason "budget_exceeded")))
)

;; Non-SetupToken or no limit: always allow
(defrule allow-non-setup-token
    (budget-request (account-type ?t&~"setup_token"))
    =>
    (assert (budget-result (allowed TRUE) (remaining 999999.0) (reason "no_budget_limit")))
)

;; SetupToken with zero limit: always allow
(defrule allow-zero-limit
    (budget-request (account-type "setup_token") (budget-limit ?l))
    (test (<= ?l 0))
    =>
    (assert (budget-result (allowed TRUE) (remaining 999999.0) (reason "no_limit_set")))
)
