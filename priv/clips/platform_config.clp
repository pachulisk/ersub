;;; ErSub Platform Configuration Facts
;;; All platform-specific constants as CLIPS facts — hot-reloadable

;; === CL01: Platform Base URLs ===

(deftemplate platform-config
    (slot platform (type STRING))
    (slot base-url (type STRING))
    (slot api-version (type STRING) (default ""))
    (slot auth-type (type SYMBOL) (default api_key))  ;; api_key | bearer | sigv4
    (slot auth-header (type STRING) (default "x-api-key"))
)

(deffacts default-platform-configs
    (platform-config (platform "claude") (base-url "https://api.anthropic.com")
                     (api-version "2023-06-01") (auth-type api_key) (auth-header "x-api-key"))
    (platform-config (platform "openai") (base-url "https://api.openai.com")
                     (api-version "") (auth-type bearer) (auth-header "authorization"))
    (platform-config (platform "gemini") (base-url "https://generativelanguage.googleapis.com")
                     (api-version "") (auth-type api_key) (auth-header "key"))
    (platform-config (platform "antigravity") (base-url "https://api.anthropic.com")
                     (api-version "2023-06-01") (auth-type bearer) (auth-header "authorization"))
    (platform-config (platform "bedrock") (base-url "https://bedrock-runtime.us-east-1.amazonaws.com")
                     (api-version "") (auth-type sigv4) (auth-header "authorization"))
)

;; === CL02: Retriable Error Codes ===

(deftemplate retriable-code
    (slot code (type INTEGER))
    (slot reason (type STRING))
)

(deffacts default-retriable-codes
    (retriable-code (code 429) (reason "rate_limited"))
    (retriable-code (code 502) (reason "bad_gateway"))
    (retriable-code (code 503) (reason "service_unavailable"))
    (retriable-code (code 529) (reason "overloaded"))
)

;; Rule: check if a given error code is retriable
(deftemplate error-check-request (slot code (type INTEGER)))
(deftemplate error-check-result (slot retriable (type SYMBOL)) (slot reason (type STRING)))

(defrule check-retriable-code
    (error-check-request (code ?c))
    (retriable-code (code ?c) (reason ?r))
    =>
    (assert (error-check-result (retriable TRUE) (reason ?r)))
)

(defrule check-non-retriable-code
    (error-check-request (code ?c))
    (not (retriable-code (code ?c)))
    =>
    (assert (error-check-result (retriable FALSE) (reason "non_retriable")))
)

;; === CL04: Status Code → Event Mapping ===

(deftemplate error-code-mapping
    (slot code (type INTEGER))
    (slot event-type (type SYMBOL))
    (slot cooldown-ms (type INTEGER))
)

(deffacts default-error-code-mappings
    (error-code-mapping (code 429) (event-type rate_limited) (cooldown-ms 60000))
    (error-code-mapping (code 502) (event-type overloaded) (cooldown-ms 30000))
    (error-code-mapping (code 503) (event-type overloaded) (cooldown-ms 30000))
    (error-code-mapping (code 529) (event-type overloaded) (cooldown-ms 30000))
)

;; === CL05: Circuit Breaker Config ===

(deftemplate circuit-breaker-config
    (slot failure-threshold (type INTEGER) (default 5))
    (slot half-open-timeout-ms (type INTEGER) (default 30000))
    (slot reset-on-success (type SYMBOL) (default TRUE))
)

(deffacts default-circuit-breaker
    (circuit-breaker-config (failure-threshold 5) (half-open-timeout-ms 30000))
)

;; === CL07: SSRF Private IP Ranges ===

(deftemplate private-ip-range
    (slot network (type STRING))
    (slot prefix-len (type INTEGER))
    (slot version (type SYMBOL) (default ipv4))
)

(deffacts default-private-ranges
    (private-ip-range (network "10.0.0.0") (prefix-len 8) (version ipv4))
    (private-ip-range (network "172.16.0.0") (prefix-len 12) (version ipv4))
    (private-ip-range (network "192.168.0.0") (prefix-len 16) (version ipv4))
    (private-ip-range (network "127.0.0.0") (prefix-len 8) (version ipv4))
    (private-ip-range (network "0.0.0.0") (prefix-len 8) (version ipv4))
    (private-ip-range (network "169.254.0.0") (prefix-len 16) (version ipv4))
)

;; === CL11: Privacy Headers ===

(deftemplate privacy-rule
    (slot platform (type STRING))
    (slot header-name (type STRING))
    (slot header-value (type STRING))
)

(deffacts default-privacy-rules
    (privacy-rule (platform "openai") (header-name "openai-privacy") (header-value "true"))
    (privacy-rule (platform "antigravity") (header-name "x-training-opt-out") (header-value "true"))
)

;; === CL12: OAuth Token Endpoints ===

(deftemplate oauth-endpoint
    (slot platform (type STRING))
    (slot token-url (type STRING))
    (slot refresh-grant-type (type STRING) (default "refresh_token"))
)

(deffacts default-oauth-endpoints
    (oauth-endpoint (platform "claude") (token-url "https://console.anthropic.com/v1/oauth/token"))
    (oauth-endpoint (platform "openai") (token-url "https://auth0.openai.com/oauth/token"))
    (oauth-endpoint (platform "gemini") (token-url "https://oauth2.googleapis.com/token"))
)

;; === CL14: Account EWMA & Cooldown Config ===

(deftemplate account-timing-config
    (slot ewma-alpha (type FLOAT) (default 0.2))
    (slot rate-limit-cooldown-ms (type INTEGER) (default 60000))
    (slot overload-cooldown-ms (type INTEGER) (default 30000))
    (slot temp-unsched-ms (type INTEGER) (default 600000))
    (slot status-check-interval-ms (type INTEGER) (default 10000))
)

(deffacts default-account-timing
    (account-timing-config)
)

;; === CL15: SSE Ping Config ===

(deftemplate sse-ping-config
    (slot platform (type STRING) (default "default"))
    (slot format (type STRING) (default "event:ping data:ping"))
    (slot base-interval-ms (type INTEGER) (default 100))
    (slot max-interval-ms (type INTEGER) (default 2000))
    (slot backoff-factor (type FLOAT) (default 1.5))
    (slot jitter-range (type FLOAT) (default 0.2))
)

(deffacts default-sse-config
    (sse-ping-config (platform "default"))
    (sse-ping-config (platform "claude") (format "data:ping"))
    (sse-ping-config (platform "openai") (format ":"))
)

;; === CL16: Moderation Ban Config ===

(deftemplate ban-config
    (slot threshold (type INTEGER) (default 5))
    (slot window-seconds (type INTEGER) (default 86400))
)

(deffacts default-ban-config
    (ban-config (threshold 5) (window-seconds 86400))
)

;; === CL08: Content Extraction Rules ===

(deftemplate content-extraction-rule
    (slot platform (type STRING))
    (slot message-field (type STRING))
    (slot content-field (type STRING))
    (slot content-type (type SYMBOL) (default text))  ;; text | blocks | parts
)

(deffacts default-content-extraction
    (content-extraction-rule (platform "claude") (message-field "messages") (content-field "content") (content-type blocks))
    (content-extraction-rule (platform "openai") (message-field "messages") (content-field "content") (content-type text))
    (content-extraction-rule (platform "gemini") (message-field "contents") (content-field "parts") (content-type parts))
    (content-extraction-rule (platform "images") (message-field "") (content-field "prompt") (content-type text))
)

;; === CL18/CL19: Request & Billing Precheck Config ===

(deftemplate request-config
    (slot max-body-size (type INTEGER) (default 268435456))
    (slot stream-timeout-ms (type INTEGER) (default 600000))
    (slot connect-timeout-ms (type INTEGER) (default 10000))
    (slot min-balance-precheck (type FLOAT) (default 0.001))
)

(deffacts default-request-config
    (request-config)
)

;; === CL20: Billing Dedup Config ===

(deftemplate dedup-config
    (slot ttl-days (type INTEGER) (default 7))
    (slot archive-enabled (type SYMBOL) (default TRUE))
)

(deffacts default-dedup-config
    (dedup-config)
)
