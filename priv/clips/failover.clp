;;; ErSub Failover Rules
;;; Determines failover action during streaming/non-streaming errors

(deftemplate stream-error-event
    (slot account-id (type INTEGER))
    (slot error-code (type INTEGER))
    (slot bytes-sent (type INTEGER) (default 0))
    (slot stream-started (type SYMBOL) (default FALSE))  ;; TRUE | FALSE
    (slot attempt (type INTEGER) (default 0))
    (slot max-switches (type INTEGER) (default 10))
    (slot pool-mode (type SYMBOL) (default FALSE))
    (slot pool-retry-count (type INTEGER) (default 3))
    (slot pool-attempt (type INTEGER) (default 0))
)

(deftemplate failover-decision
    (slot action (type SYMBOL))   ;; retry_same | switch_account | abort | reject
    (slot reason (type STRING))
)

;; Pool mode: retry same account before switching
(defrule pool-mode-retry
    (stream-error-event (pool-mode TRUE) (pool-attempt ?pa) (pool-retry-count ?prc)
                        (error-code ?c&429|502|503|529) (stream-started FALSE))
    (test (< ?pa ?prc))
    =>
    (assert (failover-decision (action retry_same) (reason "pool_mode_retry")))
)

;; Retriable error before stream started: switch account
(defrule failover-retriable-pre-stream
    (stream-error-event (error-code ?c&429|502|503|529) (stream-started FALSE)
                        (attempt ?a) (max-switches ?m))
    (test (< ?a ?m))
    (not (failover-decision))  ;; pool-mode-retry takes priority
    =>
    (assert (failover-decision (action switch_account) (reason "retriable_pre_stream")))
)

;; Mid-stream error: abort (cannot switch, client already received data)
(defrule failover-mid-stream-abort
    (stream-error-event (stream-started TRUE))
    =>
    (assert (failover-decision (action abort) (reason "mid_stream_error")))
)

;; Max switches exceeded
(defrule failover-max-exceeded
    (stream-error-event (attempt ?a) (max-switches ?m) (stream-started FALSE))
    (test (>= ?a ?m))
    =>
    (assert (failover-decision (action reject) (reason "max_switches_exceeded")))
)

;; Non-retriable error: reject
(defrule failover-non-retriable
    (stream-error-event (error-code ?c&~429&~502&~503&~529) (stream-started FALSE))
    (not (failover-decision))
    =>
    (assert (failover-decision (action reject) (reason "non_retriable_error")))
)
