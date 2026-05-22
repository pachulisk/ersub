;;; ErSub Easy Pay (易支付) Configuration
;;; Business-level config — hot-reloadable without restart

(deftemplate easypay-config
    (slot gateway-url
          (type STRING)
          (default "https://your-epay-domain.com"))
    (slot enabled      (type SYMBOL) (default FALSE))
    (slot sandbox-mode (type SYMBOL) (default FALSE))
    (slot usd-to-cny-rate (type FLOAT) (default 7.20))
)

(deffacts default-easypay-config
    (easypay-config)
)
