# Fix Plan 5 — sub2api 前端对接 + CRUD 补全

> Fix Plan 4 后 ersub ~130 端点 vs sub2api ~300 端点  
> 本轮目标：补全前端必须的 CRUD 端点 + 用户面向功能，30 个任务  
> 原则：CLIPS 规则引擎优先，CLIPS 无法实现时使用 Erlang

---

## Phase 1: P0 — 前端对接必须（Tasks 1-10）

### T5-01: Admin User 详情管理
- **端点**: `GET/PUT/DELETE /api/v1/admin/users/:id`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: GET 返回完整用户信息, PUT 更新字段(role/max_concurrency/is_banned), DELETE 软删除
- **CLIPS**: 无

### T5-02: Admin User 余额+密钥+用量
- **端点**: `POST users/:id/balance`, `GET users/:id/api-keys`, `GET users/:id/usage`, `GET users/:id/balance-history`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 余额增减记录到 balance_history, 查询关联 api_keys 和 usage_logs
- **DB**: 新表 `balance_history` (migration 010)
- **CLIPS**: 无

### T5-03: Admin Account 详情管理
- **端点**: `GET/PUT accounts/:id`, `POST accounts/:id/test`, `GET accounts/:id/usage`, `GET accounts/:id/models`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: GET 单个账户, PUT 更新字段, test 发送简单请求测试连通性, usage 查询 usage_logs, models 查询账户支持的模型列表
- **CLIPS**: 无

### T5-04: Admin Group 完整 CRUD
- **端点**: `GET/PUT/DELETE groups/:id`, `GET groups/:id/rate-multipliers`, `DELETE groups/:id/rate-multipliers`, `PUT/DELETE groups/:id/rpm-overrides`, `GET groups/:id/api-keys`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 补全 GET 单个/PUT 更新/DELETE 删除 + 乘数管理 + RPM 覆盖 + 关联密钥查询
- **CLIPS**: 无

### T5-05: Channel 完整 CRUD
- **端点**: `GET/POST/PUT/DELETE /api/v1/admin/channels/:id`, `GET channels/model-pricing`
- **文件**: `src/admin/ersub_channel_handler.erl` (扩展)
- **实现**: 管理 channels 表，model-pricing 查询默认定价
- **CLIPS**: 无

### T5-06: Auth 会话管理
- **端点**: `POST auth/refresh`, `POST auth/logout`, `GET auth/me`, `POST auth/login/2fa`
- **文件**: `src/admin/ersub_auth_handler.erl`
- **实现**: refresh 重新签发 JWT, logout 加入黑名单(ETS), me 从 JWT 返回用户信息, 2fa 验证 TOTP
- **CLIPS**: 无

### T5-07: User Subscriptions 端点
- **端点**: `GET /api/v1/subscriptions`, `GET .../subscriptions/active`, `GET .../subscriptions/progress`, `GET .../subscriptions/summary`
- **文件**: `src/admin/ersub_user_handler.erl`
- **路由**: 需在 router 添加 `/api/v1/subscriptions/[...]` 路由
- **CLIPS**: 无

### T5-08: User Redeem 端点
- **端点**: `POST /api/v1/redeem`, `GET /api/v1/redeem/history`
- **文件**: `src/admin/ersub_user_handler.erl`
- **路由**: 需在 router 添加 `/api/v1/redeem/[...]` 路由
- **实现**: 验证兑换码有效性, 增加余额, 记录历史
- **CLIPS**: 无

### T5-09: User Groups 端点
- **端点**: `GET /api/v1/groups/available`, `GET /api/v1/groups/rates`
- **文件**: `src/admin/ersub_channel_handler.erl` 或新 handler
- **路由**: 需在 router 添加
- **CLIPS**: `channel_filter.clp` — 利用已有规则过滤可用 group

### T5-10: TOTP 2FA 用户端点
- **端点**: `GET totp/status`, `POST totp/setup`, `POST totp/enable`, `POST totp/disable`
- **文件**: `src/admin/ersub_user_handler.erl`
- **路由**: 需在 router 添加 `/api/v1/user/totp/[...]`
- **实现**: 复用 `ersub_totp` 模块，暴露为 API
- **CLIPS**: 无

---

## Phase 2: P1 — 管理功能（Tasks 11-20）

### T5-11: Redeem Code 完整管理
- **端点**: `GET/POST/DELETE admin/redeem-codes`, `POST .../generate`, `GET .../stats`, `POST .../batch-delete`, `POST .../:id/expire`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 完整 redeem_codes 表管理，generate 批量生成随机码
- **CLIPS**: 无

### T5-12: Promo Code 完整 CRUD
- **端点**: `GET/POST admin/promo-codes`, `GET/PUT/DELETE .../promo-codes/:id`, `GET .../:id/usages`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: promo_codes 表 CRUD + promo_code_usage 表查询
- **CLIPS**: 无

### T5-13: Channel Monitor 完整 CRUD
- **端点**: `GET/POST/PUT/DELETE admin/channel-monitors/:id`, `POST .../:id/run`, `GET .../:id/history`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **实现**: channel_monitors 表 CRUD, run 触发即时检查, history 查询 channel_monitor_histories
- **CLIPS**: 无

### T5-14: Payment Admin 管理
- **端点**: `GET admin/payment/orders`, `POST .../orders/:id/cancel`, `POST .../orders/:id/refund`, `GET/POST/PUT/DELETE admin/payment/providers`, `GET admin/payment/dashboard`
- **文件**: `src/billing/ersub_payment_handler.erl`
- **实现**: 订单管理 + 退款 + 提供商 CRUD + 仪表盘
- **DB**: 利用现有 payment_orders + payment_provider_instances 表
- **CLIPS**: 无

### T5-15: Admin Dashboard 高级端点
- **端点**: `GET dashboard/realtime`, `GET dashboard/groups`, `GET dashboard/api-keys-trend`, `GET dashboard/users-trend`, `GET dashboard/users-ranking`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **实现**: SQL 聚合查询 + ersub_dashboard_cache 包装
- **CLIPS**: 无

### T5-16: Ops 实时信号
- **端点**: `GET ops/concurrency`, `GET ops/user-concurrency`, `GET ops/account-availability`, `GET ops/realtime-traffic`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **实现**: 从 ersub_concurrency_srv/ersub_account_srv/ersub_metrics_srv 读取实时数据
- **CLIPS**: 无

### T5-17: Ops 错误管理增强
- **端点**: `GET ops/upstream-errors`, `POST ops/request-errors/:id/retry`, `GET ops/system-logs`, `POST ops/system-logs/cleanup`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **DB**: 复用 ops_request_errors + ops_system_logs 表
- **CLIPS**: 无

### T5-18: User Email/Identity 绑定
- **端点**: `POST user/account-bindings/email`, `DELETE user/account-bindings/:provider`, `POST user/auth-identities/bind/start`
- **文件**: `src/admin/ersub_user_handler.erl`
- **实现**: 操作 auth_identities 表, email 绑定更新 users.email
- **CLIPS**: `identity_adoption.clp` — 利用已有身份收养规则

### T5-19: Account OAuth 管理（Claude）
- **端点**: `POST admin/accounts/generate-auth-url`, `POST .../exchange-code`, `POST .../cookie-auth`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 生成 Anthropic OAuth URL, 交换授权码获取 token, 创建/更新账户
- **CLIPS**: 无

### T5-20: Ops Runtime 设置
- **端点**: `GET/PUT ops/runtime/alert`, `GET/PUT ops/runtime/logging`, `POST ops/runtime/logging/reset`, `GET/PUT ops/advanced-settings`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **实现**: 通过 settings 表存储 + ersub_config_srv 运行时更新
- **CLIPS**: 无

---

## Phase 3: P2 — CRUD 补全（Tasks 21-30）

### T5-21: Proxy 扩展
- **端点**: `PUT proxies/:id`, `GET proxies/:id/stats`, `POST proxies/batch`, `POST proxies/batch-delete`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **CLIPS**: 无

### T5-22: Channel Monitor 模板扩展
- **端点**: `GET/PUT/DELETE channel-monitor-templates/:id`, `POST .../:id/apply`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **CLIPS**: 无

### T5-23: Scheduled Tests 扩展
- **端点**: `PUT scheduled-tests/:id`, `GET scheduled-tests/:id/results`, `GET accounts/:id/scheduled-tests`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **CLIPS**: 无

### T5-24: TLS Profile 扩展
- **端点**: `GET tls-profiles/:id`, `PUT tls-profiles/:id`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **CLIPS**: 无

### T5-25: Subscription 扩展
- **端点**: `GET subscriptions/:id`, `GET groups/:id/subscriptions`, `GET users/:id/subscriptions`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **CLIPS**: 无

### T5-26: Affiliate Admin 扩展
- **端点**: `GET affiliates/users`, `GET affiliates/users/:id/overview`, `PUT affiliates/users/:id`, `DELETE affiliates/users/:id`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **CLIPS**: 无

### T5-27: Announcement 扩展
- **端点**: `GET announcements/:id`, `GET announcements/:id/read-status`, `POST announcements` (admin create 增强)
- **文件**: `src/admin/ersub_announcement_handler.erl`
- **CLIPS**: 无

### T5-28: Admin Settings 扩展
- **端点**: `GET/POST admin-api-key`, `POST admin-api-key/regenerate`, `DELETE admin-api-key`, `GET/PUT rectifier`, `GET/PUT beta-policy`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **CLIPS**: 无

### T5-29: Rate Limiting 按端点类型
- **文件**: `src/concurrency/ersub_rate_limiter.erl`, 各 handler
- **实现**: 为 login/register/OAuth/verify-code 添加独立限流窗口
- **CLIPS**: `priv/clips/rate_limit_policy.clp` — 新规则
  - 规则：按端点类型决定限流策略（窗口大小/最大次数）

### T5-30: Gateway 路由别名
- **文件**: `src/ersub_router.erl`
- **实现**: 添加 `/chat/completions` → openai handler, `/responses` → responses handler, `/backend-api/codex/responses` → responses handler
- **CLIPS**: 无

---

## 执行策略

1. 每完成 3-4 个任务执行 `rebar3 compile` 验证构建
2. 每完成一个 Phase 执行 `rebar3 dialyzer` 验证类型
3. CSV 驱动执行，按 task_id 顺序
