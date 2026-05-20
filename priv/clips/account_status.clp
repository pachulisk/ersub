;;; ErSub Account Status Rules
;;; Manage account state transitions

(deftemplate account-event
    (slot account-id (type INTEGER))
    (slot event-type (type SYMBOL))   ;; error_429 | error_403 | error_502 | error_503 | error_529 | success | manual
    (slot timestamp (type INTEGER))
    (slot retry-after-ms (type INTEGER) (default 0))  ;; from Retry-After header
)

(deftemplate account-status-update
    (slot account-id (type INTEGER))
    (slot new-status (type SYMBOL))
    (slot cooldown-ms (type INTEGER) (default 0))
)

;; Transient burst rate limit (no retry-after or short <= 10s)
(defrule handle-rate-limit-burst
    (account-event (account-id ?id) (event-type error_429) (retry-after-ms ?ra))
    (test (<= ?ra 10000))
    =>
    (assert (account-status-update (account-id ?id) (new-status rate_limited) (cooldown-ms 5000)))
)

;; Quota exhaustion rate limit (long retry-after > 10s)
(defrule handle-rate-limit-quota
    (account-event (account-id ?id) (event-type error_429) (retry-after-ms ?ra))
    (test (> ?ra 10000))
    =>
    (assert (account-status-update (account-id ?id) (new-status rate_limited) (cooldown-ms ?ra)))
)

;; 403 Forbidden — model/permission error, NOT an account health issue
(defrule handle-forbidden-no-status-change
    (declare (salience 10))  ;; higher priority than generic handlers
    (account-event (account-id ?id) (event-type error_403))
    =>
    (assert (account-status-update (account-id ?id) (new-status active) (cooldown-ms 0)))
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
