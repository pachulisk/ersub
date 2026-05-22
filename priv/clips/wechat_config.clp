;;; ErSub WeChat Pay Configuration
;;; Business-level config — hot-reloadable without restart

(deftemplate wechat-config
    (slot gateway-url
          (type STRING)
          (default "https://api.mch.weixin.qq.com"))
    (slot enabled      (type SYMBOL) (default FALSE))
    (slot sandbox-mode (type SYMBOL) (default FALSE))
    (slot usd-to-cny-rate (type FLOAT) (default 7.20))
)

(deffacts default-wechat-config
    (wechat-config)
)
