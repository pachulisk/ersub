;;; CodexCLI Enforcement Rule
(deftemplate codex-check
    (slot group-id (type INTEGER))
    (slot force-codex (type SYMBOL))
    (slot client-type (type STRING))
)
(deftemplate codex-result
    (slot group-id (type INTEGER))
    (slot allowed (type SYMBOL))
    (slot reason (type STRING) (default ""))
)
(defrule enforce-codex-required
    (codex-check (group-id ?gid) (force-codex TRUE) (client-type ?ct))
    (test (neq ?ct "codex"))
    =>
    (assert (codex-result (group-id ?gid) (allowed FALSE) (reason "CodexCLI required for this group")))
)
(defrule allow-codex-present
    (codex-check (group-id ?gid) (force-codex TRUE) (client-type "codex"))
    =>
    (assert (codex-result (group-id ?gid) (allowed TRUE)))
)
(defrule allow-no-codex-restriction
    (declare (salience -10))
    (codex-check (group-id ?gid) (force-codex FALSE))
    (not (codex-result (group-id ?gid)))
    =>
    (assert (codex-result (group-id ?gid) (allowed TRUE)))
)
