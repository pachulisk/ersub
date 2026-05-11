;;; ErSub Error Passthrough Rules
;;; Match upstream errors and decide passthrough or custom behavior
;;; F11: Enhanced with priority ordering, keyword matching, response mapping

;; Extended passthrough-rule template (in core.clp, augmented here)
(deftemplate passthrough-rule-ext
    (slot rule-id (type INTEGER))
    (slot priority (type INTEGER) (default 0))
    (multislot status-codes (type INTEGER))
    (multislot keywords (type STRING))
    (slot match-mode (type SYMBOL) (default exact))  ;; exact | contains | regex
    (slot platform (type SYMBOL) (default any))
    (slot action (type SYMBOL) (default passthrough))  ;; passthrough | custom | remap
    (slot remap-code (type INTEGER) (default 0))       ;; for remap action
    (slot custom-message (type STRING) (default ""))
    (slot skip-monitoring (type SYMBOL) (default FALSE))
)

;; Match by status code (exact match)
(defrule match-passthrough-by-status
    (upstream-error (request-id ?rid) (status-code ?sc) (platform ?plat))
    (passthrough-rule (rule-id ?rule) (status-codes $?codes) (platform ?rplat)
                      (action ?act))
    (test (member$ ?sc $?codes))
    (test (or (eq ?rplat any) (eq ?rplat ?plat)))
    =>
    (assert (error-action (request-id ?rid) (action ?act) (rule-id ?rule)))
)

;; Match by keyword (contains mode)
(defrule match-passthrough-by-keyword
    (upstream-error (request-id ?rid) (status-code ?sc) (platform ?plat)
                    (body-excerpt ?body))
    (passthrough-rule-ext (rule-id ?rule) (keywords $?kws) (platform ?rplat)
                          (match-mode contains) (action ?act))
    (test (or (eq ?rplat any) (eq ?rplat ?plat)))
    (test (> (length$ $?kws) 0))
    =>
    ;; Check if any keyword is in body (simplified — full regex in Erlang)
    (assert (error-action (request-id ?rid) (action ?act) (rule-id ?rule)))
)

;; Response code remapping
(defrule remap-error-code
    (upstream-error (request-id ?rid) (status-code ?sc))
    (passthrough-rule-ext (rule-id ?rule) (status-codes $?codes)
                          (action remap) (remap-code ?rc))
    (test (member$ ?sc $?codes))
    (test (> ?rc 0))
    =>
    (assert (error-action (request-id ?rid) (action remap) (rule-id ?rule)))
)

;; Default: no rule matched → use default error handling
(defrule default-error-handling
    (upstream-error (request-id ?rid))
    (not (error-action (request-id ?rid)))
    =>
    (assert (error-action (request-id ?rid) (action default) (rule-id 0)))
)
