;;; ErSub Pool Strategy Rules
;;; Determines connection pool isolation key based on configuration

(deftemplate pool-config
    (slot mode (type SYMBOL))  ;; proxy | account | account_proxy
)

(deftemplate pool-request
    (slot account-id (type INTEGER))
    (slot proxy-endpoint (type STRING))
    (slot platform (type SYMBOL))
)

(deftemplate pool-strategy-result
    (slot key-type (type SYMBOL))
    (slot pool-key (type STRING))
)

(defrule select-proxy-mode
    "Shared pool per proxy endpoint"
    (pool-config (mode proxy))
    (pool-request (proxy-endpoint ?pe))
    =>
    (assert (pool-strategy-result (key-type proxy) (pool-key ?pe)))
)

(defrule select-account-mode
    "Isolated pool per account"
    (pool-config (mode account))
    (pool-request (account-id ?aid))
    =>
    (bind ?key (str-cat "acct:" ?aid))
    (assert (pool-strategy-result (key-type account) (pool-key ?key)))
)

(defrule select-account-proxy-mode
    "Isolated pool per {account, proxy} combination (default, most granular)"
    (pool-config (mode account_proxy))
    (pool-request (account-id ?aid) (proxy-endpoint ?pe))
    =>
    (bind ?key (str-cat "acct:" ?aid ":proxy:" ?pe))
    (assert (pool-strategy-result (key-type account_proxy) (pool-key ?key)))
)
