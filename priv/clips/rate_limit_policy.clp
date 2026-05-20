;;; ErSub Rate Limit Policy Rules
;;; Determines rate limit parameters per endpoint type

(deftemplate rate-limit-request
    (slot endpoint-type (type SYMBOL))  ;; login | register | oauth | verify-code | api-request | password-reset
    (slot user-id (type INTEGER) (default 0))
)

(deftemplate rate-limit-policy
    (slot endpoint-type (type SYMBOL))
    (slot window-seconds (type INTEGER))
    (slot max-requests (type INTEGER))
    (slot fail-mode (type SYMBOL) (default close))  ;; close | open
)

;; Login: 10 requests per 5 minutes
(defrule login-rate-limit
    (declare (salience 10))
    (rate-limit-request (endpoint-type login))
    =>
    (assert (rate-limit-policy (endpoint-type login) (window-seconds 300) (max-requests 10) (fail-mode close)))
)

;; Register: 3 requests per 10 minutes
(defrule register-rate-limit
    (declare (salience 10))
    (rate-limit-request (endpoint-type register))
    =>
    (assert (rate-limit-policy (endpoint-type register) (window-seconds 600) (max-requests 3) (fail-mode close)))
)

;; OAuth: 10 requests per 5 minutes
(defrule oauth-rate-limit
    (declare (salience 10))
    (rate-limit-request (endpoint-type oauth))
    =>
    (assert (rate-limit-policy (endpoint-type oauth) (window-seconds 300) (max-requests 10) (fail-mode close)))
)

;; Verify code: 5 requests per 5 minutes
(defrule verify-code-rate-limit
    (declare (salience 10))
    (rate-limit-request (endpoint-type verify-code))
    =>
    (assert (rate-limit-policy (endpoint-type verify-code) (window-seconds 300) (max-requests 5) (fail-mode close)))
)

;; Password reset: 3 requests per 10 minutes
(defrule password-reset-rate-limit
    (declare (salience 10))
    (rate-limit-request (endpoint-type password-reset))
    =>
    (assert (rate-limit-policy (endpoint-type password-reset) (window-seconds 600) (max-requests 3) (fail-mode close)))
)

;; Default API request: use configured RPM (fallback)
(defrule default-api-rate-limit
    (declare (salience -10))
    (rate-limit-request (endpoint-type ?et))
    (not (rate-limit-policy (endpoint-type ?et)))
    =>
    (assert (rate-limit-policy (endpoint-type ?et) (window-seconds 60) (max-requests 60) (fail-mode open)))
)
