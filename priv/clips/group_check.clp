;;; ErSub Group Assignment Authorization
;;; Validates that a user's API key has an active group binding
;;; before allowing gateway requests through.

(deftemplate group-auth-request
    (slot user-id (type INTEGER))
    (slot platform (type SYMBOL))    ;; claude | openai | gemini
    (slot model (type STRING) (default ""))
)

(deftemplate group-binding
    (slot user-id (type INTEGER))
    (slot group-id (type INTEGER))
    (slot platform (type SYMBOL))
    (slot is-active (type SYMBOL) (default TRUE))
)

(deftemplate group-auth-result
    (slot user-id (type INTEGER))
    (slot allowed (type SYMBOL))     ;; TRUE | FALSE
    (slot reason (type STRING) (default ""))
    (slot group-id (type INTEGER) (default 0))
)

;; Rule: User has an active group binding for the requested platform
(defrule allow-group-with-platform-match
    (group-auth-request (user-id ?uid) (platform ?plat))
    (group-binding (user-id ?uid) (group-id ?gid) (platform ?plat) (is-active TRUE))
    (not (group-auth-result (user-id ?uid)))
    =>
    (assert (group-auth-result (user-id ?uid) (allowed TRUE) (group-id ?gid)))
)

;; Rule: User has an active group binding for "any" platform (wildcard group)
(defrule allow-group-with-any-platform
    (group-auth-request (user-id ?uid) (platform ?plat))
    (group-binding (user-id ?uid) (group-id ?gid) (platform any) (is-active TRUE))
    (not (group-auth-result (user-id ?uid)))
    =>
    (assert (group-auth-result (user-id ?uid) (allowed TRUE) (group-id ?gid)))
)

;; Rule: No active group binding found — deny
(defrule deny-no-group-binding
    (declare (salience -10))
    (group-auth-request (user-id ?uid))
    (not (group-auth-result (user-id ?uid)))
    =>
    (assert (group-auth-result (user-id ?uid) (allowed FALSE)
                               (reason "No active group assignment")))
)
