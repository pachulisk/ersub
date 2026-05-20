;;; ErSub Alipay Payment Configuration
;;; Business-level config — hot-reloadable via POST /api/admin/clips/reload
;;;
;;; Sensitive credentials (app_id, private_key, public_key) stay in config/ersub.yaml
;;; and environment variables. Only non-secret business config lives here.

(deftemplate alipay-config
    (slot gateway-url
          (type STRING)
          (default "https://openapi.alipay.com/gateway.do"))
    (slot sandbox-gateway-url
          (type STRING)
          (default "https://openapi.alipaydev.com/gateway.do"))
    (slot enabled (type SYMBOL) (default FALSE))
    (slot sandbox-mode (type SYMBOL) (default FALSE))
    (slot usd-to-cny-rate (type FLOAT) (default 7.20))
)

(deffacts default-alipay-config
    (alipay-config)
)
