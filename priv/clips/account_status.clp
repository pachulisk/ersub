;;; ErSub Account Status Rules
;;; Manage account state transitions

(deftemplate account-event
    (slot account-id (type INTEGER))
    (slot event-type (type SYMBOL))   ;; error_429 | error_502 | error_503 | error_529 | success | manual
    (slot timestamp (type INTEGER))
)

(deftemplate account-status-update
    (slot account-id (type INTEGER))
    (slot new-status (type SYMBOL))
    (slot cooldown-ms (type INTEGER) (default 0))
)

(defrule handle-rate-limit
    (account-event (account-id ?id) (event-type error_429))
    =>
    (assert (account-status-update (account-id ?id) (new-status rate_limited) (cooldown-ms 60000)))
)

(defrule handle-overload
    (account-event (account-id ?id) (event-type ?e&error_502|error_503|error_529))
    =>
    (assert (account-status-update (account-id ?id) (new-status overloaded) (cooldown-ms 30000)))
)

(defrule handle-success
    (account-event (account-id ?id) (event-type success))
    =>
    (assert (account-status-update (account-id ?id) (new-status active) (cooldown-ms 0)))
)
