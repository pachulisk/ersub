# Fix Plan 7 — 最终缺口补齐（~30 端点）

> Fix Plan 4-6 完成后 ersub ~363 端点 vs sub2api ~300 端点  
> 剩余 ~30 个边缘端点，本轮全部补齐  
> 原则：CLIPS 规则引擎优先，CLIPS 无法实现时使用 Erlang

---

## Phase 1: HIGH 优先级（Tasks 1-4）

### T7-01: Payment 验证/退款补全
- `POST /payment/orders/verify` — 校验订单支付状态
- `GET /payment/orders/refund-eligible-providers` — 可退款提供商
- `POST /payment/public/orders/verify` — 公开验证（无 auth）
- `POST /payment/public/orders/resolve` — Resume token 恢复
- `POST /admin/payment/orders/:id/retry` — 管理员重试履约
- 文件: `src/billing/ersub_payment_handler.erl`
- CLIPS: 无

### T7-02: 单项资源 GET 补全
- `GET /keys/:id` — 单个 API key 详情
- `GET /usage/:id` — 单条 usage 记录
- `GET /proxies/:id` — 单个代理详情
- `PUT /admin/api-keys/:id` — 管理员改 key 组
- 文件: `ersub_keys_handler.erl` + `ersub_user_handler.erl` + `ersub_admin_handler.erl`
- CLIPS: 无

### T7-03: Admin Usage 搜索
- `GET /admin/usage/search-users` — 用量按用户搜索
- `GET /admin/usage/search-api-keys` — 用量按 key 搜索
- 文件: `ersub_admin_handler.erl`
- CLIPS: 无

### T7-04: User Email Bind 验证码
- `POST /user/account-bindings/email/send-code` — 邮箱绑定验证码
- 文件: `ersub_user_handler.erl`
- CLIPS: 无

## Phase 2: MEDIUM 优先级（Tasks 5-8）

### T7-05: OAuth Bind 专用流程
- `GET /auth/oauth/:provider/bind/start` — 绑定 OAuth 开始
- `POST /auth/oauth/pending/send-verify-code` — Pending 验证码
- `POST /auth/oauth/bind-token` — OAuth 绑定 token
- 文件: `ersub_auth_handler.erl`
- CLIPS: 无

### T7-06: Admin Group/Dashboard 补充
- `GET /admin/groups/all` — 含非 active
- `GET /admin/groups/usage-summary` — Group 用量汇总
- `GET /admin/ops/dashboard/openai-token-stats` — OpenAI token 统计
- 文件: `ersub_admin_handler.erl` + `ersub_ops_handler.erl`
- CLIPS: 无

### T7-07: User 面向端点补全
- `GET /channel-monitors` (user) — 用户只读监控
- `GET /channel-monitors/:id/status` (user)
- `POST /usage/dashboard/api-keys-usage` (user)
- 文件: `ersub_user_handler.erl` + `ersub_router.erl`
- CLIPS: 无

### T7-08: OpenAI OAuth Admin 补充
- `POST /admin/openai/accounts/:id/refresh` — 刷新单个 token
- `POST /admin/openai/create-from-oauth` — OAuth 创建账户
- 文件: `ersub_admin_handler.erl`
- CLIPS: 无

## Phase 3: LOW 优先级（Tasks 9-11）

### T7-09: Risk Control 扩展
- `POST /admin/risk-control/api-keys/test` — 测试审核 key
- `DELETE /admin/risk-control/hashes` — 删除标记 hash
- `DELETE /admin/risk-control/hashes/all` — 清空标记
- 文件: `ersub_ops_handler.erl`
- CLIPS: 无

### T7-10: TOTP 补充
- `GET /user/totp/verification-method`
- `POST /user/totp/send-code`
- 文件: `ersub_user_handler.erl`
- CLIPS: 无

### T7-11: WeChat Payment OAuth + misc
- `GET /auth/oauth/wechat/payment/start`
- `GET /auth/oauth/wechat/payment/callback`
- 文件: `ersub_auth_handler.erl`
- CLIPS: 无
