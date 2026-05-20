;;; ErSub Web Search Emulation Rules
;;; Detect web_search tool use and rewrite to internal reasoning

(deftemplate web-search-request
    (slot request-id (type STRING))
    (slot has-web-search (type SYMBOL))   ;; TRUE | FALSE
    (slot query-text (type STRING) (default ""))
    (slot emulation-mode (type SYMBOL) (default rewrite))  ;; rewrite | block | passthrough
)

(deftemplate web-search-result
    (slot request-id (type STRING))
    (slot action (type SYMBOL))     ;; rewrite | block | passthrough
    (slot rewritten-query (type STRING) (default ""))
    (slot reason (type STRING) (default ""))
)

;; Rule: Web search detected, mode is rewrite — transform to internal reasoning
(defrule rewrite-web-search
    (web-search-request (request-id ?rid) (has-web-search TRUE)
                        (query-text ?q) (emulation-mode rewrite))
    (not (web-search-result (request-id ?rid)))
    =>
    (assert (web-search-result (request-id ?rid) (action rewrite)
                               (rewritten-query ?q)
                               (reason "Web search emulated via internal reasoning")))
)

;; Rule: Web search detected, mode is block — reject
(defrule block-web-search
    (web-search-request (request-id ?rid) (has-web-search TRUE) (emulation-mode block))
    (not (web-search-result (request-id ?rid)))
    =>
    (assert (web-search-result (request-id ?rid) (action block)
                               (reason "Web search is disabled")))
)

;; Rule: Web search detected, mode is passthrough — let it through
(defrule passthrough-web-search
    (web-search-request (request-id ?rid) (has-web-search TRUE) (emulation-mode passthrough))
    (not (web-search-result (request-id ?rid)))
    =>
    (assert (web-search-result (request-id ?rid) (action passthrough)))
)

;; Rule: No web search in request — passthrough
(defrule no-web-search
    (declare (salience -10))
    (web-search-request (request-id ?rid) (has-web-search FALSE))
    (not (web-search-result (request-id ?rid)))
    =>
    (assert (web-search-result (request-id ?rid) (action passthrough)))
)
