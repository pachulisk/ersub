# ErSub Phase 2 — 功能补全设计文档

基于 sub2api vs ersub 功能差距审计，本文档定义 ersub 第二阶段需要补全的所有功能的设计方案。

---

## 一、网关端点补全

### 1.1 GET /v1/models — 模型列表端点

从 `ersub_pricing_srv` ETS 表读取所有已知模型，返回 OpenAI 兼容格式。

```erlang
%% ersub_models_handler.erl
%% GET /v1/models — 返回可用模型列表
%% GET /v1/models/:model_id — 返回单个模型信息
%%
%% 响应格式 (OpenAI 兼容):
%% {"object":"list","data":[{"id":"claude-sonnet-4","object":"model","owned_by":"anthropic"},...]}
```

**数据源：** `ersub_pricing_srv:get_all()` 获取所有模型 + 按 group 过滤用户可用模型。

### 1.2 POST /v1/images/edits — 图片编辑

与 images/generations 同构，转发到 OpenAI `/v1/images/edits`，支持 multipart/form-data。

### 1.3 Idempotency-Key 中间件

在所有 gateway handler 前置检查 `Idempotency-Key` header：
- 命中缓存 → 直接返回上次结果
- 未命中 → 正常处理，响应后写入缓存（ETS，TTL 24h）

```erlang
%% ersub_idempotency.erl
-export([check/1, store/3, init_cache/0]).
%% ETS table: ersub_idempotency_cache
%% Key: {ApiKeyId, IdempotencyKey}
%% Value: {StatusCode, Headers, Body, ExpireTime}
```

### 1.4 图片并发限制器

独立于用户级并发控制的图片生成并发限制。

```erlang
%% ersub_image_limiter.erl — 全局图片生成并发槽
%% 配置: gateway.image_max_concurrent (默认 10)
```

---

## 二、账户类型扩展

### 2.1 Bedrock (AWS SigV4)

新增 `ersub_aws_signer.erl` 模块，实现 AWS Signature Version 4：

```erlang
%% ersub_aws_signer.erl
-export([sign_request/5]).
%% sign_request(Method, Url, Headers, Body, Credentials) ->
%%   在 Headers 中添加 Authorization, x-amz-date, x-amz-content-sha256
%% Credentials: #{access_key, secret_key, region, service}
```

`ersub_account_srv` 识别 `account_type = <<"bedrock">>` 时，调用 signer 对请求签名。

### 2.2 ServiceAccount (Google Vertex AI)

新增 `ersub_gcp_auth.erl`，实现 Google Service Account JWT→Access Token 流程：

```erlang
%% ersub_gcp_auth.erl
-export([get_access_token/1]).
%% 从 credentials.service_account_json 生成 JWT，换取 access_token
```

### 2.3 Account pool_mode

在 `ersub_scheduler_srv` 的 failover 逻辑中，当 `account.pool_mode = true` 时，同一账户内重试（401/403/429），最多 `pool_retry_count` 次，再切换下一账户。

### 2.4 Privacy 模式 / Session ID 伪装 / TLS 指纹绑定

在 `ersub_request_transform` 中：
- Privacy: 向 OpenAI 上游注入 `openai-privacy: true` header
- Session ID: 为 Anthropic 请求生成随机 session-id
- TLS 指纹: 从 `tls_fingerprint_profiles` 表读取 profile，在 gun 连接选项中设置

---

## 三、计费增强

### 3.1 图片分级定价

在 `ersub_billing_helper:record_non_streaming_usage/4` 中解析图片响应的 `size` 字段，按 1K/2K/4K/HD 查询 group 的 `image_price_*` 字段计费。

### 3.2 长上下文溢价

在 `ersub_billing_helper:calculate_cost/2` 中：
- 从 pricing 表读取 `long_ctx_threshold`
- 当 total_input_tokens > threshold 时，input × `long_ctx_input_mult`，output × `long_ctx_output_mult`

### 3.3 服务等级 (service_tier)

Gateway handler 从上游响应 header 提取 `x-service-tier` 或响应体 `service_tier` 字段，传入 billing helper，乘以对应乘数 (priority=2x, flex=0.5x)。

### 3.4 Cache 分级

解析响应 usage 中的 `cache_creation_input_tokens` 区分 5m/1h cache，使用不同价格。已有 CLIPS 规则和 DB 字段，需在 `ersub_billing_helper` 中分拆。

### 3.5 计费 Circuit Breaker

在 `ersub_billing_srv` 中增加熔断器：
- 连续 N 次 DB sync 失败 → 进入 open 状态（拒绝新请求 or 降级放行）
- open 状态持续 T 秒后 → half-open（尝试一次 sync）
- 成功 → closed

---

## 四、调度增强

### 4.1 PreviousResponseID 粘滞

`ersub_scheduler_srv:select_account/1` 新增 Layer 0：从请求 body 中提取 `previous_response_id`，查 ETS 映射到上次使用的 account_id。

### 4.2 调度器指标

在 `ersub_scheduler_srv` state 中增加 counters：
- `select_total`, `sticky_hit`, `lb_select`, `account_switch`
- 暴露 `get_metrics/0` API，供 admin dashboard 查询

### 4.3 调度器 DB 开关

从 `settings` 表读取 `advanced_scheduler_enabled`（5s ETS 缓存），为 false 时退化为简单 priority 排序。

### 4.4 Load skew 跟踪

每次选择后计算 load 分布的标准差，记录到 metrics 中。

---

## 五、内容审核增强

### 5.1 内容脱敏

`ersub_moderation_srv` 审核后，对 flagged 内容替换敏感部分为 `[REDACTED]`，返回脱敏后的内容。

### 5.2 邮件通知

新增 `ersub_email.erl` 模块（基于 `gen_smtp_client`），审核命中后发送邮件到管理员。

### 5.3 API Key 轮换

`ersub_moderation_srv` 支持多个 moderation API key（列表），rate_limit 时自动切换下一个。

### 5.4 采样率

请求进入审核前，按 `moderation_sample_rate`（0-100）概率采样，降低 API 调用量。

### 5.5 Worker 池 + 队列

将 `ersub_moderation_srv` 的 `observe` 模式改为异步：poolboy worker 池 + gen_server mailbox 队列。

### 5.6 13 类风险阈值

配置 `moderation_thresholds` 为 map，每个分类（harassment, hate, sexual, violence 等）独立阈值。

### 5.7 多协议内容提取

按平台格式提取审核内容：
- Claude: `messages[].content`
- OpenAI: `messages[].content`
- Gemini: `contents[].parts[].text`
- Images: prompt 文本

---

## 六、支付系统（标记为 Phase 3，需外部凭证）

Alipay/WeChat/EasyPay 需要商户密钥，标记为 Phase 3。当前设计：
- `ersub_payment_srv` 增加 `is_provider_available/1` 检查
- 不可用 provider 返回 `{error, provider_not_configured}` + 明确提示
- 退款流程: 状态机 `pending → refund_requested → refunding → refunded`
- 支付恢复: resume_token 生成 + 验证

---

## 七、运维观测增强

### 7.1 实时 WebSocket 仪表板

新增 `ersub_ops_ws_handler.erl` (cowboy_websocket)：
- 每秒推送 QPS、错误率、活跃连接数
- 数据源：`ersub_metrics_srv:get_summary()`

### 7.2 多粒度窗口统计

`ersub_metrics_srv` 扩展为 5m/1h/24h 三个聚合粒度。

### 7.3 数据导出

`GET /api/admin/export/usage` — 返回 CSV 格式使用记录。
`GET /api/admin/export/users` — 返回 CSV 格式用户列表。

### 7.4 Advisory Lock

聚合任务执行前获取 PostgreSQL advisory lock，防止多实例重复聚合。

---

## 八、用户系统增强

### 8.1 多 OAuth Provider

扩展 `ersub_auth_handler:get_oauth_config/1` 支持 Google、OIDC 通用协议。

### 8.2 Pending Auth Sessions

注册时生成 pending session，发送验证邮件/码，确认后激活用户。

### 8.3 用户属性 API

`GET/PUT /api/user/attributes` — 按 `user_attribute_definitions` schema 读写用户自定义属性。

---

## 九、高级特性

### 9.1 user_msg_queue_mode

在 gateway handler 入口，根据 account 的 `user_msg_queue_mode`：
- `serialize`: 用 ETS lock 串行化同一用户的请求
- `throttle`: 根据 RPM 计算延迟，`timer:sleep` 后继续

### 9.2 messages_dispatch

在 `ersub_request_transform` 中，按 group 配置的 `messages_dispatch_model_config` 做跨平台模型映射（如 Claude opus → GPT-5.4）。

### 9.3 自定义 Markdown 页面

路由 `GET /pages/:slug` 到 `ersub_page_handler`：
- 从 `data/pages/{slug}/` 读取 `index.md`
- Slug 校验防路径遍历
- 1MB 大小限制

### 9.4 自定义错误码过滤

账户 credentials 中增加 `retryable_error_codes` 列表，failover 时只重试这些错误码。
