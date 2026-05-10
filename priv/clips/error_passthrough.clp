;;; ErSub Error Passthrough Rules
;;; Match upstream errors and decide passthrough or custom behavior

(defrule match-passthrough-by-status
    "Match error by status code and platform"
    (upstream-error (request-id ?rid) (status-code ?sc) (platform ?plat))
    (passthrough-rule (rule-id ?rule) (status-codes $?codes) (platform ?rplat)
                      (action ?act))
    (test (member$ ?sc $?codes))
    (test (or (eq ?rplat any) (eq ?rplat ?plat)))
    =>
    (assert (error-action (request-id ?rid) (action ?act) (rule-id ?rule)))
)
