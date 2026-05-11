;;; ErSub Subscription Rules
;;; Validates subscription requests based on billing type

(deftemplate subscription-request
    (slot user-id)
    (slot group-id)
    (slot billing-type))

(deftemplate subscription-result
    (slot allowed)
    (slot reason))

(defrule allow-balance-subscription
    (subscription-request (billing-type 0))
    =>
    (assert (subscription-result (allowed TRUE) (reason "balance_mode"))))

(defrule allow-quota-subscription
    (subscription-request (billing-type 1))
    =>
    (assert (subscription-result (allowed TRUE) (reason "quota_mode"))))
