;;; ErSub Model Routing Rules
;;; Route model requests to specific account groups

(deftemplate model-route
    (slot group-id (type INTEGER))
    (slot model-pattern (type STRING))
    (multislot target-account-ids (type INTEGER))
)

(deftemplate routing-request
    (slot group-id (type INTEGER))
    (slot model (type STRING))
)

(deftemplate routing-result
    (slot group-id (type INTEGER))
    (slot model (type STRING))
    (multislot account-ids (type INTEGER))
)

(defrule exact-model-route
    "Route by exact model name match"
    (routing-request (group-id ?gid) (model ?m))
    (model-route (group-id ?gid) (model-pattern ?m) (target-account-ids $?aids))
    =>
    (assert (routing-result (group-id ?gid) (model ?m) (account-ids $?aids)))
)
