# Fix Plan 4 — sub2api 功能对齐

> 基于 sub2api 完整源码扫描 vs ersub 当前实现的功能差距  
> 范围：25 个可落地任务，按 P0→P3 优先级排序  
> 原则：CLIPS 规则引擎优先，CLIPS 无法实现时使用 Erlang

---

## 已完成功能（Fix Plan 1-3 已实现，本轮不含）

- 错误透传规则 CRUD（ersub_ops_handler）
- Dashboard Snapshot V2（ersub_ops_handler /snapshot）
- messages_dispatch 配置（ersub_admin_handler groups/:id/dispatch）
- Account today-stats 缓存（ersub_admin_handler accounts/today-stats）
- TLS 指纹 Profile CRUD（ersub_ops_handler）
- 批量兑换/促销（ersub_admin_handler redeem/batch, promo/batch）
- Channel Monitor 模板 CRUD（ersub_ops_handler）
- 定时测试计划 CRUD（ersub_ops_handler）
- Proxy CRUD（ersub_admin_handler）
- 账户临时不可调度（ersub_admin_handler）
- 账户 Notes（ersub_admin_handler）
- OAuth（GitHub/LinuxDo/WeChat/Google/OIDC — ersub_auth_handler）
- Alert CRUD + Silences（ersub_ops_handler）
- Idempotency 自动清理（ersub_idempotency gen_server 1h 周期）

---

## 明确延后（架构差异或需外部依赖）

| 功能 | 原因 |
|------|------|
| Redis 缓存层 | ersub 设计为零外部状态依赖（ETS 替代 Redis）|
| ClickHouse 系统日志 | PostgreSQL 已满足需求 |
| S3 数据备份 | 需引入 AWS SDK 依赖，独立 Plan |
| 系统在线更新/回滚 | 部署运维关注点，非应用功能 |
| SMTP 邮件服务 | 需引入 gen_smtp 依赖，独立 Plan |
| 前端 (Vue 3) | 复用 sub2api 前端（scripts/build-frontend.sh）|

---

## Phase 1: P0 — 阻塞生产使用（Tasks 1-3）

### T4-01: Token 计数代理端点
- **端点**: `POST /v1/messages/count_tokens`
- **实现**: Erlang handler — 透传请求到上游 Anthropic API
- **文件**: `src/gateway/ersub_claude_handler.erl` + `src/ersub_router.erl`
- **逻辑**: 复用现有认证 + 账户调度 + 请求转发链路，但不计费、不记 usage
- **CLIPS**: 无（纯代理透传）

### T4-02: Group 分配检查中间件
- **位置**: `src/auth/ersub_auth_middleware.erl`
- **实现**: 在 API key 认证后检查用户是否绑定了 group
- **CLIPS**: `priv/clips/group_check.clp` — 新规则文件
  - 规则：`check-group-assignment` — 验证 key 对应 user 有活跃的 group 绑定
  - 规则：`deny-no-group` — 无 group 绑定时拒绝
- **逻辑**: CLIPS 评估 key→user→group 链，返回 allow/deny

### T4-03: Dashboard 查询缓存
- **位置**: `src/ops/ersub_dashboard_cache.erl`（新模块）
- **实现**: ETS 缓存 + 30s TTL，包装 ersub_ops_handler 的 SQL 查询
- **文件**: 新 gen_server，注册到 ersub_sup
- **CLIPS**: 无（纯缓存基础设施，ETS read_concurrency）

---

## Phase 2: P1 — 重要功能缺失（Tasks 4-12）

### T4-04: API Key 更新端点
- **端点**: `PUT /api/v1/keys/:id`
- **文件**: `src/admin/ersub_keys_handler.erl`
- **实现**: 允许更新 name, rpm_limit, concurrency_limit, ip_whitelist, ip_blacklist, expires_at
- **CLIPS**: 无（纯 CRUD）

### T4-05: 密码重置流程
- **端点**: `POST /api/v1/auth/forgot-password`, `POST /api/v1/auth/reset-password`
- **文件**: `src/admin/ersub_auth_handler.erl`
- **实现**: 生成重置 token（HMAC 签名 + 过期时间）存入 DB, 验证后更新密码
- **CLIPS**: 无（安全流程，不适合规则引擎）

### T4-06: 账户批量操作
- **端点**: `POST /api/v1/admin/accounts/batch`（批量创建）, `POST .../batch-update`, `POST .../batch-clear-error`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 接收列表，逐条执行现有逻辑，返回汇总结果
- **CLIPS**: 无（批量包装器）

### T4-07: 订阅管理增强
- **端点**: `POST .../subscriptions/:id/extend`, `POST .../subscriptions/bulk-assign`, `POST .../subscriptions/:id/reset-quota`, `GET .../subscriptions/:id/progress`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **CLIPS**: `priv/clips/subscription.clp` — 扩展现有规则
  - 规则：`validate-subscription-extend` — 验证续期合法性
  - 规则：`reset-quota-allowed` — 验证配额重置权限

### T4-08: Content Moderation 管理 API
- **端点**: `GET/PUT /api/v1/admin/moderation/config`, `GET .../moderation/status`, `GET .../moderation/logs`, `POST .../moderation/users/:id/unban`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **实现**: 配置读写 via settings，日志查询 moderation_logs 表，解封更新 moderation_bans
- **CLIPS**: 无（管理端点）

### T4-09: 用户仪表盘增强
- **端点**: `GET /api/v1/usage/stats`, `GET .../usage/dashboard/trend`, `GET .../usage/dashboard/models`
- **文件**: `src/admin/ersub_user_handler.erl`
- **实现**: 按时间聚合、按模型分组的用户级 usage 统计
- **CLIPS**: 无（纯 SQL 聚合）

### T4-10: Settings 管理增强
- **端点**: `GET/PUT /api/v1/admin/settings/overload-cooldown`, `.../rate-limit-cooldown`, `.../stream-timeout`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 类型化 settings 端点，更新后同步到 ersub_config_srv + CLIPS config
- **CLIPS**: `ersub_clips_config:reload()` — 更新 CLIPS 运行时参数

### T4-11: 账户凭证生命周期
- **端点**: `POST .../accounts/:id/refresh`, `POST .../accounts/:id/clear-rate-limit`, `POST .../accounts/:id/reset-quota`, `GET .../accounts/:id/stats`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **CLIPS**: `account_status.clp` — 利用现有状态转换规则

### T4-12: Group 管理增强
- **端点**: `GET .../groups/:id/stats`, `PUT .../groups/sort-order`, `GET .../groups/capacity-summary`, `PUT .../groups/:id/rate-multipliers`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **CLIPS**: 无（纯 CRUD + SQL 聚合）

---

## Phase 3: P2 — 功能完善（Tasks 13-20）

### T4-13: 公告管理增强
- **端点**: `PUT .../announcements/:id`, `DELETE .../announcements/:id`, `POST .../announcements/:id/read`, `GET .../announcements (status filter)`
- **文件**: `src/admin/ersub_announcement_handler.erl`
- **实现**: 状态管理（draft/active/archived）+ 阅读跟踪
- **CLIPS**: 无

### T4-14: 操作错误跟踪
- **端点**: `GET .../ops/request-errors`, `GET .../ops/request-errors/:id`, `POST .../ops/request-errors/:id/resolve`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **DB**: 新表 `ops_request_errors`（migration 009）
- **CLIPS**: 无

### T4-15: 用户属性定义管理
- **端点**: `GET/POST /api/v1/admin/user-attributes`, `PUT/DELETE .../user-attributes/:id`, `PUT .../user-attributes/reorder`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: Admin CRUD for user_attribute_definitions 表
- **CLIPS**: 无

### T4-16: Affiliate 管理增强
- **端点**: `GET .../admin/affiliates/invites`, `GET .../admin/affiliates/rebates`, `GET .../admin/affiliates/transfers`, `POST .../admin/affiliates/batch-rate`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 查询 user_affiliate_ledger 按 action 分类
- **CLIPS**: 无

### T4-17: Proxy 测试端点
- **端点**: `POST /api/v1/admin/proxies/:id/test`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 通过代理发送 HTTP 请求测试连通性和延迟
- **CLIPS**: 无

### T4-18: CodexCLI 强制执行
- **文件**: `src/gateway/ersub_client_detector.erl` + 各 handler
- **实现**: 增强 UA 检测，读取 group 的 force_codex_cli 标记
- **CLIPS**: `priv/clips/channel_filter.clp` — 新规则
  - 规则：`enforce-codex-cli-only` — 当 group 标记 force_codex_cli 且客户端非 CodexCLI 时拒绝

### T4-19: Backend Mode Guard 增强
- **文件**: `src/auth/ersub_auth_middleware.erl`
- **实现**: 读取 backend_mode 配置，在 backend 模式下限制用户端点、放行 admin 端点
- **CLIPS**: 无（中间件逻辑）

### T4-20: Client Request ID 中间件
- **文件**: `src/gateway/ersub_request_id.erl`（新模块）
- **实现**: 为每个请求生成 UUID 并注入 X-Request-Id header
- **CLIPS**: 无

---

## Phase 4: P3 — 边缘场景（Tasks 21-25）

### T4-21: Usage 清理任务管理 API
- **端点**: `GET/POST /api/v1/admin/usage/cleanup-tasks`, `POST .../cleanup-tasks/:id/cancel`
- **文件**: `src/admin/ersub_ops_handler.erl`
- **实现**: 手动触发 usage 清理任务，管理清理历史
- **CLIPS**: 无

### T4-22: Payment Plan 管理 CRUD
- **端点**: `GET/POST /api/v1/admin/payment/plans`, `PUT/DELETE .../plans/:id`
- **文件**: `src/billing/ersub_payment_handler.erl`
- **DB**: 新表 `payment_plans`（migration 009）
- **CLIPS**: 无

### T4-23: 系统版本信息端点
- **端点**: `GET /api/v1/admin/system/version`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 返回 OTP 版本、应用版本、编译时间、CLIPS 版本
- **CLIPS**: 无

### T4-24: Web Search 仿真
- **文件**: `priv/clips/web_search_emulation.clp`（新规则文件）
- **实现**: CLIPS 规则驱动查询改写 + `src/gateway/ersub_web_search.erl` 响应合成
- **CLIPS**: 
  - 规则：`detect-web-search-tool` — 检测 tool_use 中的 web_search
  - 规则：`rewrite-search-query` — 将 web_search 转为模型内部推理
  - 规则：`synthesize-search-result` — 生成模拟搜索结果

### T4-25: Codex Session 导入
- **端点**: `POST /api/v1/admin/accounts/import/codex-session`
- **文件**: `src/admin/ersub_admin_handler.erl`
- **实现**: 解析 Codex session cookie/token，创建 account 记录
- **CLIPS**: 无

---

## 执行策略

1. 每完成 3-4 个任务执行 `make compile` 验证构建
2. CSV 驱动执行，按 task_id 顺序
3. 完成一个任务立即标记 status=done
4. 遇到阻塞性问题记录到 CSV notes 列
