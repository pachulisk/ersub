;;; ErSub Identity Adoption Rules
;;; Decides how to handle OAuth identity conflicts during registration

(deftemplate identity-conflict
    (slot provider (type STRING))
    (slot existing-email (type STRING))     ;; "nil" if new user
    (slot oauth-email (type STRING))
    (slot has-display-name (type SYMBOL))   ;; TRUE | FALSE
    (slot has-avatar (type SYMBOL))         ;; TRUE | FALSE
    (slot existing-has-password (type SYMBOL))  ;; TRUE | FALSE
)

(deftemplate adoption-decision
    (slot adopt-display-name (type SYMBOL))  ;; TRUE | FALSE
    (slot adopt-avatar (type SYMBOL))        ;; TRUE | FALSE
    (slot action (type SYMBOL))              ;; create_new | merge | link | reject
    (slot reason (type STRING))
)

;; New user: adopt all OAuth info, create account
(defrule adopt-new-user-all
    (identity-conflict (existing-email "nil") (has-display-name TRUE) (has-avatar TRUE))
    =>
    (assert (adoption-decision (adopt-display-name TRUE) (adopt-avatar TRUE)
             (action create_new) (reason "new_user_full_adoption")))
)

;; New user without avatar: adopt name only
(defrule adopt-new-user-name-only
    (identity-conflict (existing-email "nil") (has-display-name TRUE) (has-avatar FALSE))
    =>
    (assert (adoption-decision (adopt-display-name TRUE) (adopt-avatar FALSE)
             (action create_new) (reason "new_user_name_only")))
)

;; New user without any info: create with defaults
(defrule adopt-new-user-minimal
    (identity-conflict (existing-email "nil") (has-display-name FALSE))
    =>
    (assert (adoption-decision (adopt-display-name FALSE) (adopt-avatar FALSE)
             (action create_new) (reason "new_user_minimal")))
)

;; Existing user: link OAuth identity, keep local info
(defrule merge-existing-user
    (identity-conflict (existing-email ?e&~"nil") (existing-has-password TRUE))
    =>
    (assert (adoption-decision (adopt-display-name FALSE) (adopt-avatar FALSE)
             (action merge) (reason "existing_user_link")))
)

;; Existing user without password: link and adopt OAuth info
(defrule merge-existing-no-password
    (identity-conflict (existing-email ?e&~"nil") (existing-has-password FALSE)
                       (has-display-name TRUE))
    =>
    (assert (adoption-decision (adopt-display-name TRUE) (adopt-avatar TRUE)
             (action link) (reason "existing_no_password_adopt")))
)
