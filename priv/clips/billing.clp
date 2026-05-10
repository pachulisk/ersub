;;; ErSub Billing Rules
;;; Token-based, per-request, and image billing modes

;; Resolve service tier multiplier
(defrule resolve-tier-multiplier
    (usage (service-tier ?tier))
    (not (tier-multiplier))
    =>
    (if (eq ?tier priority)
     then (assert (tier-multiplier (value 2.0)))
     else (if (eq ?tier flex)
           then (assert (tier-multiplier (value 0.5)))
           else (assert (tier-multiplier (value 1.0)))))
)

;; Resolve long context multipliers
(defrule resolve-long-context
    (usage (model ?m) (total-input-tokens ?total))
    (model-pricing (model ?m) (long-ctx-threshold ?th)
                   (long-ctx-input-mult ?im) (long-ctx-output-mult ?om))
    (not (long-ctx-input-mult))
    =>
    (if (and (> ?th 0) (> ?total ?th))
     then
        (assert (long-ctx-input-mult (value ?im)))
        (assert (long-ctx-output-mult (value ?om)))
     else
        (assert (long-ctx-input-mult (value 1.0)))
        (assert (long-ctx-output-mult (value 1.0))))
)

;; Default long context multipliers when no pricing entry
(defrule default-long-context
    (usage (model ?m))
    (not (model-pricing (model ?m)))
    (not (long-ctx-input-mult))
    =>
    (assert (long-ctx-input-mult (value 1.0)))
    (assert (long-ctx-output-mult (value 1.0)))
)

;; Calculate token-mode cost
(defrule calculate-token-cost
    (billing-mode (mode token))
    (usage (model ?m) (input-tokens ?it) (output-tokens ?ot)
           (cache-read-tokens ?crt) (cache-5m-tokens ?c5)
           (cache-1h-tokens ?c1) (image-output-tokens ?iot)
           (account-rate-mult ?arm) (group-rate-mult ?grm))
    (model-pricing (model ?m) (input-price ?ip) (output-price ?op)
                   (cache-read-price ?crp) (cache-5m-price ?c5p)
                   (cache-1h-price ?c1p) (image-output-price ?iop))
    (tier-multiplier (value ?tm))
    (long-ctx-input-mult (value ?lim))
    (long-ctx-output-mult (value ?lom))
    =>
    (bind ?input-cost (* ?it ?ip ?tm ?lim))
    (bind ?output-cost (* ?ot ?op ?tm ?lom))
    (bind ?cache-read-cost (* ?crt ?crp ?tm))
    (bind ?cache-creation-cost (+ (* ?c5 ?c5p ?tm) (* ?c1 ?c1p ?tm)))
    (bind ?image-cost (* ?iot ?iop ?tm))
    (bind ?total (+ ?input-cost ?output-cost ?cache-read-cost
                    ?cache-creation-cost ?image-cost))
    (bind ?actual (* ?total ?arm ?grm))
    (assert (billing-result
        (input-cost ?input-cost) (output-cost ?output-cost)
        (cache-read-cost ?cache-read-cost) (cache-creation-cost ?cache-creation-cost)
        (image-cost ?image-cost) (total-cost ?total) (actual-cost ?actual)))
)

;; Calculate per-request cost
(defrule calculate-per-request-cost
    (billing-mode (mode per_request))
    (per-request-pricing (model ?m) (fixed-price ?fp))
    (usage (model ?m) (account-rate-mult ?arm) (group-rate-mult ?grm))
    =>
    (assert (billing-result
        (input-cost 0.0) (output-cost 0.0)
        (cache-read-cost 0.0) (cache-creation-cost 0.0)
        (image-cost 0.0) (total-cost ?fp)
        (actual-cost (* ?fp ?arm ?grm))))
)

;; Calculate image cost
(defrule calculate-image-cost
    (billing-mode (mode image))
    (image-request (image-count ?cnt) (image-size ?sz)
                   (account-rate-mult ?arm) (group-rate-mult ?grm)
                   (group-image-rate-mult ?girm)
                   (group-image-rate-independent ?indep))
    (image-size-pricing (size ?sz) (price ?p))
    =>
    (bind ?base (* ?cnt ?p))
    (bind ?rate-mult (if (= ?indep 1) then ?girm else ?grm))
    (bind ?actual (* ?base ?arm ?rate-mult))
    (assert (billing-result
        (input-cost 0.0) (output-cost 0.0)
        (cache-read-cost 0.0) (cache-creation-cost 0.0)
        (image-cost ?actual) (total-cost ?base) (actual-cost ?actual)))
)
