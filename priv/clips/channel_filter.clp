;;; ErSub Channel Filter Rules
;;; Filters channels by active status and model availability

(deftemplate channel-candidate
    (slot id)
    (slot group-id)
    (slot platform)
    (slot is-active)
    (slot has-model))

(deftemplate channel-filter-result
    (slot id)
    (slot available))

(defrule filter-active-with-model
    (channel-candidate (id ?id) (is-active TRUE) (has-model TRUE))
    =>
    (assert (channel-filter-result (id ?id) (available TRUE))))

(defrule filter-inactive
    (channel-candidate (id ?id) (is-active FALSE))
    =>
    (assert (channel-filter-result (id ?id) (available FALSE))))
