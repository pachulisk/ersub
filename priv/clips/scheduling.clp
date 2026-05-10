;;; ErSub Scheduling Rules
;;; Multi-factor account scoring for load-aware selection

(defrule calculate-score
    "Score each candidate account based on weighted factors"
    (score-weights (priority-w ?pw) (load-w ?lw) (queue-w ?qw)
                   (error-rate-w ?ew) (ttft-w ?tw))
    (max-values (max-priority ?mp) (max-waiting ?mw) (max-ttft ?mt))
    (candidate-account (id ?id) (priority ?p) (load-rate ?lr)
                       (waiting-count ?wc) (ewma-error-rate ?er)
                       (ewma-ttft-ms ?ttft) (status active)
                       (supports-model 1))
    =>
    (bind ?norm-p (/ (- ?mp ?p) (max ?mp 1)))
    (bind ?norm-l (- 1.0 (min ?lr 1.0)))
    (bind ?norm-q (- 1.0 (/ ?wc (max ?mw 1))))
    (bind ?norm-e (- 1.0 ?er))
    (bind ?norm-t (- 1.0 (/ ?ttft (max ?mt 1.0))))
    (bind ?score (+ (* ?pw ?norm-p) (* ?lw ?norm-l)
                    (* ?qw ?norm-q) (* ?ew ?norm-e)
                    (* ?tw ?norm-t)))
    (assert (account-score (id ?id) (score ?score)))
)

(defrule skip-inactive
    "Do not score inactive accounts"
    (candidate-account (id ?id) (status ?s&~active))
    =>
    (assert (account-score (id ?id) (score -1.0)))
)

(defrule skip-unsupported-model
    "Do not score accounts that don't support the requested model"
    (candidate-account (id ?id) (supports-model 0))
    =>
    (assert (account-score (id ?id) (score -1.0)))
)
