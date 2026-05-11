# ErSub 项目全面排查 — 未实现内容与卡点清单

## Context

ErSub 项目 165 个任务已标记完成，但经过三路并行深度审计（代码占位符扫描、运行时集成检查、测试覆盖分析），发现大量实现是**脚手架/占位符级别**，距离生产可用有显著差距。以下是按严重程度分类的完整清单。

---

## 🔴 CRITICAL — 不修复无法运行/存在严重缺陷

### C1. 7 个 gen_server 未加入 Supervision Tree（永远不会启动）

模块存在但 `ersub_sup.erl` 中未注册，调用时会 `{noproc, ...}` 崩溃：

| 模块 | 功能 | 影响 |
|------|------|------|
| `ersub_affiliate_srv` | 分销返佣 | `accrue/3`, `transfer/2` 调用崩溃 |
| `ersub_balance_notify_srv` | 余额通知 | 低余额不会触发通知 |
| `ersub_health_srv` | 健康评分 | `/health` 只返回基础状态，无评分 |
| `ersub_metrics_srv` | 指标聚合 | `metrics_aggregated` 表永远为空 |
| `ersub_usage_cleanup_srv` | 使用记录清理 | `usage_logs` 表无限增长 |
| `ersub_scheduled_test_srv` | 定时健康检测 | 账户可用性不会被自动检测 |
| `ersub_channel_monitor` | Channel 监控 | Channel 可用性不被监控 |

**文件：** `src/ersub_sup.erl`

### C2. 非流式请求完全没有计费扣款和使用日志

所有 gateway handler（Claude/OpenAI/Gemini/Antigravity/Images/Responses）的**非流式路径**：
- 只做了余额预检 `check_balance(UserId, 0.001)` 
- 转发上游后**直接返回**，从不调用 `ersub_billing_srv:deduct/2` 或 `ersub_usage_logger:log/1`
- 流式路径通过 `ersub_stream_fsm` 有日志记录，但非流式完全跳过

**影响：** 非流式请求免费使用，使用量不被追踪，收入损失。

**涉及文件：**
- `src/gateway/ersub_claude_handler.erl` — 非流式分支 (约 line 155)
- `src/gateway/ersub_openai_handler.erl` — 非流式分支 (约 line 131)
- `src/gateway/ersub_gemini_handler.erl` — 非流式分支 (约 line 79)
- `src/gateway/ersub_antigravity_handler.erl` — 非流式分支
- `src/gateway/ersub_openai_images_handler.erl` — 全部（图片生成无流式）
- `src/gateway/ersub_openai_responses_handler.erl` — 非流式分支

### C3. CLIPS Worker 缺少 `reload_rules` handler

`ersub_clips_pool:reload_rules/0` 遍历 worker 调用 `gen_server:call(Worker, reload_rules)` ，但 `ersub_clips_worker` 的 `handle_call` 没有匹配 `reload_rules` 的子句，会落入兜底返回 `{error, unknown_request}`。

**影响：** 管理员调用 `POST /api/admin/clips/reload` 静默失败，规则永远不会热更新。

**文件：** `src/clips/ersub_clips_worker.erl` — 缺少 `handle_call({reload_rules, ...}, ...)` 子句

### C4. 密码哈希使用 SHA-256（非 bcrypt/argon2）

`ersub_auth_srv:hash_password/1` 使用 `crypto:hash(sha256, ...)` ，代码中有显式 TODO 注释。SHA-256 不抗暴力破解。

**文件：** `src/auth/ersub_auth_srv.erl:52` — `%% TODO: Use bcrypt/argon2 for production.`

---

## 🟠 HIGH — 核心功能缺失或为脚手架

### H1. Alipay 支付 — 纯脚手架

`ersub_alipay.erl:create_order/3` 返回 mock 数据，**未调用支付宝网关 API**。注释明确写 `%% In production: sign with RSA private key, call alipay gateway`。`verify_callback/1` 不验证签名。

**文件：** `src/payment/ersub_alipay.erl`

### H2. WeChat Pay — 纯脚手架

同上，`ersub_wechat.erl:create_order/3` 返回 mock 数据，未调用微信支付 API。

**文件：** `src/payment/ersub_wechat.erl`

### H3. 定价表自动更新 — `fetch_and_parse` 未实现

`ersub_pricing_srv.erl` 的 `fetch_and_parse/1` 直接返回 `{error, not_implemented}`。定价只能从硬编码 fallback 获取（6 个模型），无法从 LiteLLM JSON 自动更新。

**文件：** `src/billing/ersub_pricing_srv.erl:75-78`

### H4. OAuth redirect_uri 硬编码

`ersub_auth_handler.erl` 中 GitHub OAuth 的 `redirect_uri` 硬编码为 `http://localhost:8080/...`，非 localhost 环境 OAuth 无法工作。

**文件：** `src/admin/ersub_auth_handler.erl:112`

### H5. 余额通知只打日志，不发邮件

`ersub_balance_notify_srv` 检测到低余额后只 `logger:info`，没有实际邮件发送实现。

**文件：** `src/billing/ersub_balance_notify_srv.erl:57-58`

### H6. 配置文件覆盖不完整

`config/ersub.yaml` 缺少以下代码中实际读取的配置项（共 ~20 个）：
- `moderation_*`（mode, api_url, api_key, ban_threshold, ban_window_seconds）
- `payment_*`（stripe_secret_key, stripe_webhook_secret, alipay_app_id, wechat_mch_id）
- `auth_oauth_providers_github_*`
- `security_*`（url_allowlist_enabled, upstream_hosts, allow_http, cors_allowed_origins）
- `ops_*`（usage_cleanup_retention_days, run_at_hour, alert_eval_interval_ms）
- `backend_mode`

---

## 🟡 MEDIUM — 功能不完整或质量问题

### M1. Stripe Webhook 签名验证不完整

简化 HMAC 检查，未解析完整 `Stripe-Signature` 头格式（含 timestamp），缺少防重放攻击保护。

**文件：** `src/payment/ersub_stripe.erl:51`

### M2. 内容审核 API 错误静默吞掉

`ersub_moderation_srv` 在 Moderation API 返回非 200 或失败时，默认放行（`clean`），仅打 warning 日志。

**文件：** `src/moderation/ersub_moderation_srv.erl:158-164`

### M3. 数据库 Repo 覆盖不完整

以下表有 migration DDL 但**无对应 Repo 函数**：
- `user_subscriptions` — 无 CRUD
- `payment_orders` — 无直接 CRUD（只通过 `ersub_payment_srv` 的 raw SQL）
- `channels` — 无 create/update/delete（只通过 `ersub_channel_srv` 的 raw SQL）
- `redeem_codes`, `promo_codes` — 无直接 CRUD
- 其余 20+ 扩展表（affiliate, proxy, scheduled_tests, monitors 等）

### M4. `ersub_billing_dedup` 未被调用

`ersub_billing_dedup:check_and_mark/1` 已实现但**没有任何地方调用它**。计费去重功能形同虚设。

**文件：** `src/billing/ersub_billing_dedup.erl`

### M5. Mock Upstream 服务器已实现但从未使用

`test/support/ersub_mock_upstream.erl` 可启动模拟 Claude/OpenAI/Gemini 服务器，但**零个测试引用它**。不支持 SSE streaming 和错误模拟（429/502）。

### M6. E2E 测试只验证认证拒绝

5 个 E2E 测试全部只测试"无 API Key 返回 401"，**没有测试实际的 API 代理功能**（成功请求、流式传输、错误透传、failover）。

### M7. 属性测试是伪装的随机单元测试

`test/property/` 下的 3 个文件使用 `rand:uniform()` + 循环，**未使用 PropEr 库**（虽然是依赖项）。没有 generator、shrinking、property specification。

---

## 🟢 LOW — 锦上添花

### L1. `ersub_stub_handler` 仍存在但未使用

路由器中已全部替换为真实 handler，但 stub 模块文件和 `_Stub` 变量仍留存。

### L2. OAuth 只支持 GitHub

`get_oauth_config/1` 对非 GitHub provider 直接返回 `{error, not_configured}`。

### L3. Setup Wizard 只创建 admin 用户

不 seed 默认账户、定价数据、示例分组等。

### L4. 测试 Fixture 缺少 Channel/Subscription/Payment

`ersub_test_fixtures.erl` 只有 user/account/group/api_key 四种，缺少 channel、subscription、payment_order 等。

### L5. 40+ 源模块无对应测试

包括所有 gateway handler、scheduler、billing、auth handler、ops 服务等核心模块。

---

## 修复优先级建议

| 优先级 | 编号 | 工作量 | 说明 |
|--------|------|--------|------|
| P0 立即 | C1 | S | 7 个 gen_server 加入 supervisor |
| P0 立即 | C2 | M | 所有 handler 非流式路径增加计费扣款+日志 |
| P0 立即 | C3 | S | CLIPS worker 增加 reload_rules handler |
| P0 立即 | C4 | S | 密码哈希替换为 bcrypt（加 erlang-bcrypt 依赖） |
| P1 紧急 | H1-H2 | L | Alipay/WeChat 实际 API 对接或标记为不可用 |
| P1 紧急 | H3 | M | 实现 LiteLLM 定价 JSON fetch+parse |
| P1 紧急 | H4 | S | OAuth redirect_uri 从 config 读取 |
| P1 紧急 | H6 | S | 补全 ersub.yaml 缺失的配置项 |
| P2 重要 | M1 | M | 完善 Stripe webhook 签名解析 |
| P2 重要 | M4 | S | 在计费路径中调用 billing_dedup |
| P2 重要 | M5-M6 | L | 基于 mock upstream 实现真实 E2E 测试 |

---

## 验证方案

修复后需验证：
1. `rebar3 compile` 零 warning
2. `rebar3 as test eunit` 全部通过
3. `rebar3 as test ct --dir=test/integration` 全部通过
4. 启动应用 → `supervisor:which_children(ersub_sup)` 确认所有服务运行
5. 发送非流式 Claude 请求 → 确认 `usage_logs` 表有记录
6. 调用 `POST /api/admin/clips/reload` → 确认成功
7. 创建用户 → 验证密码使用 bcrypt hash
