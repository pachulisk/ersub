# Fix Plan 6 — 最终缺口补齐

> 目标：补齐 sub2api 剩余 ~20 个功能区域缺口  
> 范围：20 个任务，纯增量 CRUD 端点  
> 说明：S3 备份/SMTP/系统在线更新 依赖外部组件，不在本轮范围

---

## Phase 1: P0 — 前端必须（Tasks 1-7）

### T6-01: Admin User 扩展操作
- users/:id/replace-group, users/batch-concurrency, users/:id/rpm-status
- 文件: ersub_admin_handler.erl

### T6-02: Admin Account 扩展操作
- accounts/:id/set-privacy, accounts/:id/refresh-tier, accounts/:id/schedulable, accounts/data GET/POST, accounts/batch-refresh, accounts/batch-update-credentials
- 文件: ersub_admin_handler.erl

### T6-03: Auth 补全
- send-verify-code, validate-promo-code, validate-invitation-code, revoke-all-sessions
- 文件: ersub_auth_handler.erl

### T6-04: Payment User 端点
- checkout-info, plans (user), channels, limits, orders/my, orders/:id/cancel, orders/:id/refund-request
- 文件: ersub_payment_handler.erl

### T6-05: Ops Alert Events
- alert-events GET list, GET/:id, PUT/:id/status
- 文件: ersub_ops_handler.erl

### T6-06: Ops Dashboard vNext
- dashboard/overview, throughput-trend, latency-histogram, error-trend, error-distribution
- 文件: ersub_ops_handler.erl

### T6-07: Redeem Code 补全
- GET/:id, export, create-and-redeem
- 文件: ersub_admin_handler.erl

## Phase 2: P1 — 管理增强（Tasks 8-14）

### T6-08: OAuth Admin (OpenAI/Gemini/Antigravity)
- openai generate-auth-url/exchange-code/refresh-token
- gemini oauth auth-url/exchange-code/capabilities
- antigravity oauth auth-url/exchange-code/refresh-token
- 文件: ersub_admin_handler.erl

### T6-09: Account Setup Token 端点
- generate-setup-token-url, exchange-setup-token-code, setup-token-cookie-auth
- 文件: ersub_admin_handler.erl

### T6-10: User Notify Email
- notify-email/send-code, verify, toggle, remove
- 文件: ersub_user_handler.erl

### T6-11: User Affiliate
- GET /user/aff, POST /user/aff/transfer
- 文件: ersub_user_handler.erl

### T6-12: Settings 扩展
- web-search-emulation GET/PUT/test/reset-usage, settings/public
- 文件: ersub_admin_handler.erl + ersub_auth_handler.erl

### T6-13: Ops Email Notification + Metric Thresholds
- email-notification/config GET/PUT, settings/metric-thresholds GET/PUT
- 文件: ersub_ops_handler.erl

### T6-14: Admin Dashboard 批量查询
- users-usage (batch), api-keys-usage (batch), user-breakdown, aggregation/backfill
- 文件: ersub_ops_handler.erl

## Phase 3: P2 — 边缘补全（Tasks 15-20）

### T6-15: Antigravity 扩展路由
- /antigravity/v1beta/*, /antigravity/models, /antigravity/v1/usage
- 文件: ersub_router.erl + ersub_antigravity_handler.erl

### T6-16: OAuth Per-Provider 完整流程
- complete-registration, bind-login, create-account (per provider), pending flow
- 文件: ersub_auth_handler.erl

### T6-17: Misc 端点补全
- affiliates/users/lookup, channel-monitor-templates/:id/monitors, accounts/:id/scheduled-tests, redeem-codes/export, user-attributes/batch, system-logs/health
- 文件: 多个 handler

### T6-18: Account 状态管理
- check-mixed-channel, antigravity/default-model-mapping, GET temp-unschedulable, DELETE temp-unschedulable
- 文件: ersub_admin_handler.erl

### T6-19: Event Logging + Pages
- POST /api/event_logging/batch (stub), GET settings/public, pages GET
- 文件: ersub_router.erl + 新 handler

### T6-20: Proxy 扩展
- proxies/all, proxies/data GET/POST, proxies/:id/quality-check, proxies/:id/accounts
- 文件: ersub_admin_handler.erl
