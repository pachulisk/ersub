;;; ErSub Core Templates
;;; Base deftemplate definitions shared across all rule files

;; === Scheduling Templates ===

(deftemplate candidate-account
    (slot id (type INTEGER))
    (slot priority (type INTEGER))
    (slot load-rate (type FLOAT))
    (slot waiting-count (type INTEGER))
    (slot ewma-error-rate (type FLOAT))
    (slot ewma-ttft-ms (type FLOAT))
    (slot status (type SYMBOL))
    (slot platform (type SYMBOL))
    (slot supports-model (type INTEGER))
)

(deftemplate score-weights
    (slot priority-w (type FLOAT) (default 1.0))
    (slot load-w (type FLOAT) (default 1.0))
    (slot queue-w (type FLOAT) (default 0.7))
    (slot error-rate-w (type FLOAT) (default 0.8))
    (slot ttft-w (type FLOAT) (default 0.5))
)

(deftemplate max-values
    (slot max-priority (type INTEGER) (default 100))
    (slot max-waiting (type INTEGER) (default 20))
    (slot max-ttft (type FLOAT) (default 5000.0))
)

(deftemplate select-config
    (slot top-k (type INTEGER) (default 7))
)

(deftemplate account-score
    (slot id (type INTEGER))
    (slot score (type FLOAT))
)

(deftemplate selection-result
    (slot account-id (type INTEGER))
)

;; === Billing Templates ===

(deftemplate model-pricing
    (slot model (type STRING))
    (slot input-price (type FLOAT))
    (slot output-price (type FLOAT))
    (slot cache-read-price (type FLOAT) (default 0.0))
    (slot cache-creation-price (type FLOAT) (default 0.0))
    (slot cache-5m-price (type FLOAT) (default 0.0))
    (slot cache-1h-price (type FLOAT) (default 0.0))
    (slot image-output-price (type FLOAT) (default 0.0))
    (slot long-ctx-threshold (type INTEGER) (default 0))
    (slot long-ctx-input-mult (type FLOAT) (default 1.0))
    (slot long-ctx-output-mult (type FLOAT) (default 1.0))
)

(deftemplate usage
    (slot model (type STRING))
    (slot input-tokens (type INTEGER))
    (slot output-tokens (type INTEGER))
    (slot cache-read-tokens (type INTEGER) (default 0))
    (slot cache-5m-tokens (type INTEGER) (default 0))
    (slot cache-1h-tokens (type INTEGER) (default 0))
    (slot image-output-tokens (type INTEGER) (default 0))
    (slot service-tier (type SYMBOL) (default standard))
    (slot account-rate-mult (type FLOAT) (default 1.0))
    (slot group-rate-mult (type FLOAT) (default 1.0))
    (slot total-input-tokens (type INTEGER) (default 0))
)

(deftemplate billing-mode
    (slot mode (type SYMBOL) (default token))
)

(deftemplate tier-multiplier
    (slot value (type FLOAT))
)

(deftemplate long-ctx-input-mult
    (slot value (type FLOAT))
)

(deftemplate long-ctx-output-mult
    (slot value (type FLOAT))
)

(deftemplate billing-result
    (slot input-cost (type FLOAT))
    (slot output-cost (type FLOAT))
    (slot cache-read-cost (type FLOAT))
    (slot cache-creation-cost (type FLOAT))
    (slot image-cost (type FLOAT))
    (slot total-cost (type FLOAT))
    (slot actual-cost (type FLOAT))
)

;; === Quota Templates ===

(deftemplate subscription-quota
    (slot user-id (type INTEGER))
    (slot group-id (type INTEGER))
    (slot daily-limit (type FLOAT))
    (slot daily-usage (type FLOAT))
    (slot weekly-limit (type FLOAT))
    (slot weekly-usage (type FLOAT))
    (slot monthly-limit (type FLOAT))
    (slot monthly-usage (type FLOAT))
    (slot additional-cost (type FLOAT))
)

(deftemplate quota-violation
    (slot user-id (type INTEGER))
    (slot type (type SYMBOL))
    (slot limit (type FLOAT))
    (slot usage (type FLOAT))
    (slot requested (type FLOAT))
)

(deftemplate quota-check-result
    (slot user-id (type INTEGER))
    (slot allowed (type SYMBOL))
)

;; === Per-Request / Image Billing Templates ===

(deftemplate per-request-pricing
    (slot model (type STRING))
    (slot fixed-price (type FLOAT))
)

(deftemplate image-request
    (slot model (type STRING))
    (slot image-count (type INTEGER))
    (slot image-size (type SYMBOL))
    (slot account-rate-mult (type FLOAT))
    (slot group-rate-mult (type FLOAT))
    (slot group-image-rate-mult (type FLOAT) (default 1.0))
    (slot group-image-rate-independent (type INTEGER) (default 0))
)

(deftemplate image-size-pricing
    (slot size (type SYMBOL))
    (slot price (type FLOAT))
)

;; === Error Passthrough Templates ===

(deftemplate upstream-error
    (slot request-id (type STRING))
    (slot status-code (type INTEGER))
    (slot platform (type SYMBOL))
    (slot body-excerpt (type STRING))
)

(deftemplate passthrough-rule
    (slot rule-id (type INTEGER))
    (multislot status-codes (type INTEGER))
    (multislot keywords (type STRING))
    (slot platform (type SYMBOL))
    (slot action (type SYMBOL))
)

(deftemplate error-action
    (slot request-id (type STRING))
    (slot action (type SYMBOL))
    (slot rule-id (type INTEGER))
)
