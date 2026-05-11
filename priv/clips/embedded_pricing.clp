;;; ErSub Embedded Pricing Facts
;;; Fallback model pricing — loaded on startup, overridden by HTTP fetch
;;; Prices in USD per token

(deffacts embedded-model-pricing
    (model-pricing (model "claude-sonnet-4-20250514")
                   (input-price 0.000003) (output-price 0.000015)
                   (cache-read-price 0.0000003) (cache-creation-price 0.00000375))
    (model-pricing (model "claude-opus-4-20250514")
                   (input-price 0.000015) (output-price 0.000075)
                   (cache-read-price 0.0000015) (cache-creation-price 0.00001875))
    (model-pricing (model "claude-haiku-3-5-20241022")
                   (input-price 0.0000008) (output-price 0.000004)
                   (cache-read-price 0.00000008) (cache-creation-price 0.000001))
    (model-pricing (model "gpt-4o")
                   (input-price 0.0000025) (output-price 0.00001)
                   (cache-read-price 0.00000125))
    (model-pricing (model "gpt-4o-mini")
                   (input-price 0.00000015) (output-price 0.0000006))
    (model-pricing (model "gemini-2.5-pro")
                   (input-price 0.00000125) (output-price 0.00001))
)
