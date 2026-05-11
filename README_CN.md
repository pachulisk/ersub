# ErSub — 基于 Erlang/OTP + CLIPS 的 AI API 网关

[English](README.md)

---

## 项目简介

ErSub 是一个 AI API 网关平台，将上游 AI 订阅（Claude、OpenAI、Gemini 等）的 API 配额分发给多个用户，提供认证、计费、负载均衡和请求代理功能。项目对标 [sub2api](https://github.com/Wei-Shaw/sub2api)（Go 实现），使用 Erlang/OTP 重新实现，并引入 CLIPS 规则引擎作为核心决策层。

### 为什么选择 Erlang + CLIPS？

| 维度 | Go (sub2api) | Erlang/OTP + CLIPS (ersub) |
|------|-------------|---------------------------|
| 并发模型 | goroutine + mutex + Redis | process-per-connection，原生隔离 |
| 容错性 | 手动 recovery | OTP supervision tree，let-it-crash |
| 业务规则 | 源码硬编码 | CLIPS 规则文件，支持热更新 |
| 状态管理 | Redis（外部依赖） | ETS/counters/gen_server（内置） |
| 流式处理 | SSE scanner + buffer pool | gen_statem 状态机 |
| 热更新 | 需要重启 | 热代码替换 + 规则热重载 API |

### 核心设计原则

**不做 MVP，不走捷径。** 所有业务决策（调度评分、计费计算、配额检查、状态转换、模型路由、错误透传）必须通过 CLIPS 规则引擎实现，Erlang 只负责基础设施（并发控制、流式传输、连接管理）。

---

## 架构概览

```
客户端 → Cowboy HTTP/WS → 认证中间件 → 限速器 → 并发控制
    → CLIPS 调度器（账户选择） → 请求转换（模型映射）
    → 上游连接池（gun HTTP/2） → SSE 流式状态机 / 非流式转发
    → CLIPS 计费（成本计算） → 使用日志 → 响应
```

### CLIPS 规则引擎集成

所有业务决策通过 Erlang Port 协议调用 CLIPS 引擎：

```
Erlang (gen_server) → poolboy checkout → CLIPS Port worker
    → retract_all → assert facts → run rules → parse results
    → poolboy checkin → 返回决策结果
```

**9 个决策路径全部经过 CLIPS：**

| 决策 | 规则文件 | 说明 |
|------|---------|------|
| 账户选择评分 | `scheduling.clp` | 多因子加权评分（优先级、负载、队列、错误率、TTFT） |
| 计费计算 | `billing.clp` | token/per_request/image 三模式，tier 乘数，长上下文溢价 |
| 配额检查 | `quota.clp` | 日/周/月配额检查与违规断言 |
| 账户状态转换 | `account_status.clp` | 429→rate_limited, 502/503→overloaded |
| 模型路由 | `model_routing.clp` | 分组级模型→账户映射 |
| 错误透传 | `error_passthrough.clp` | 状态码+平台+关键词匹配 |
| 内容审核 | 通过 CLIPS 池 | 13 类风险阈值评估 |
| 退款验证 | 通过 CLIPS 池 | 退款状态机转换验证 |
| 模型分发 | 通过 CLIPS 池 | 跨平台模型族映射（Claude↔OpenAI） |

规则文件位于 `priv/clips/*.clp`，可通过 `POST /api/admin/clips/reload` 热重载。

---

## 功能特性

### 网关端点

| 端点 | 协议 | 平台 |
|------|------|------|
| `POST /v1/messages` | Anthropic Messages API | Claude |
| `POST /openai/v1/chat/completions` | OpenAI Chat API | OpenAI |
| `POST /openai/v1/responses` | OpenAI Responses API | Codex CLI |
| `WS /openai/v1/realtime` | WebSocket v2 双向中继 | OpenAI Realtime |
| `POST /openai/v1/images/generations` | 图片生成 | DALL-E |
| `POST /openai/v1/images/edits` | 图片编辑 | DALL-E |
| `POST /gemini/v1beta/[...]` | Gemini API | Google Gemini |
| `POST /antigravity/v1/messages` | Antigravity 协议 | Claude Pro |
| `GET /v1/models` | 模型列表 | 全平台 |

### 账户类型

- **API Key** — Claude、OpenAI、Gemini 静态凭证
- **OAuth** — 自动 Token 刷新（Claude、OpenAI、Gemini）
- **Setup Token** — 仅推理范围（Anthropic）
- **Bedrock** — AWS SigV4 签名（Amazon Bedrock）
- **Service Account** — Google Vertex AI JWT 认证
- **Upstream** — 中继到其他网关

### 计费系统（CLIPS 驱动）

- Token / 按请求 / 图片三种计费模式
- 服务等级乘数（priority 2x、flex 0.5x）
- 长上下文溢价（>272K tokens，input×2 output×1.5）
- Cache 分级定价（5 分钟 vs 1 小时）
- 图片分辨率分档（1K/2K/4K/HD）
- 计费熔断器（连续 5 次 DB 失败→open→half-open→closed）
- 计费去重（幂等性保证）

### 调度系统（CLIPS 驱动）

- 多因子评分：优先级、负载率、队列深度、错误率、首 Token 延迟
- 三层选择：PreviousResponseID → 会话粘滞 → CLIPS 评分
- 账户 pool_mode（同账户内重试后再切换）
- Top-K 加权随机选择
- 运行时指标（选择次数、命中率、负载偏斜度）
- 调度器 DB 开关（可运行时关闭高级调度）

### 安全

- API Key 认证（SHA-256 + ETS 缓存）
- JWT 令牌（HS256，可配过期时间）
- PBKDF2-SHA256 密码哈希（100K 迭代）
- TOTP 双因素认证（QR 码生成）
- IP 黑白名单（CIDR 表示法）
- SSRF 防护（私有 IP 阻断、DNS Rebinding 防护）
- CSP 安全头（动态 nonce）
- 内容审核（13 类风险、采样率、API Key 轮换、内容脱敏）
- Idempotency-Key 幂等性支持
- Privacy 模式（training opt-out）
- Session ID 伪装（防关联追踪）

### 运维观测

- 实时 WebSocket 仪表板（`/api/ops/ws`，每秒推送）
- 多粒度指标聚合（5 分钟 / 1 小时 / 24 小时）
- 健康评分（DB + CLIPS + 账户组件）
- 告警系统（规则评估 + 静默规则）
- 定时账户健康检测（自动恢复）
- Channel 可用性监控（日聚合）
- 使用记录定时清理
- CSV 数据导出（使用记录、用户列表）
- PostgreSQL Advisory Lock 防重复聚合

### 支付

- Stripe 集成（Checkout Session + Webhook 签名验证）
- Alipay / WeChat Pay（架构就绪，需商户凭证）
- 兑换码 + 促销码系统
- 退款状态机（CLIPS 验证状态转换）
- 支付恢复 Token（HMAC 签名，1 小时有效）
- 分销返佣系统（ledger 追踪）

### 用户系统

- 多 OAuth Provider（GitHub、Google、通用 OIDC）
- 用户自定义属性 API
- 余额通知（阈值检测 + 系统日志）
- 公告系统（已读追踪）

### 高级特性

- 用户消息队列模式（serialize 串行化 / throttle 节流）
- 跨平台模型映射（Claude opus→GPT-5.4，CLIPS 驱动）
- 自定义 Markdown 页面（`/pages/:slug`）
- 自定义可重试错误码（per-account 配置）
- 自定义错误码过滤

---

## 快速开始

### 环境要求

- Erlang/OTP 26+
- PostgreSQL 15+
- CLIPS 6.4+（自动从源码构建）

### 构建运行

```bash
git clone https://github.com/pachulisk/ersub.git
cd ersub

# 构建 CLIPS 引擎
cd c_src && make && cd ..

# 编译
rebar3 compile

# 配置
export DB_USER=your_user
export JWT_SECRET=your_secret

# 运行
make run
# 服务启动在 http://localhost:8080
```

### Docker 部署

```bash
cd deploy
docker compose up -d
```

### 首次运行

首次启动时，ErSub 自动：
1. 执行数据库迁移（39 张表）
2. 创建管理员用户（`admin@ersub.local` / `admin`）
3. 生成管理员 JWT Token（输出到控制台）

---

## OTP Supervision Tree

26 个受监督子进程，自动重启：

```
ersub_sup (one_for_one)
├── ersub_config_srv          # 配置管理（persistent_term）
├── ersub_repo_pool           # PostgreSQL 连接池（poolboy）
├── ersub_session_srv         # 会话粘滞缓存（ETS）
├── ersub_concurrency_srv     # 用户并发槽（counters）
├── ersub_usage_logger        # 异步使用日志写入
├── ersub_rate_limiter        # RPM 滑动窗口（ETS）
├── ersub_platform_sup        # 动态 per-account 进程
├── ersub_upstream_pool       # gun HTTP 连接管理
├── ersub_billing_srv         # 余额缓存 + 熔断器
├── ersub_scheduler_srv       # CLIPS 驱动的账户选择
├── ersub_auth_srv            # JWT + 密码哈希
├── ersub_channel_srv         # Channel 定价缓存
├── ersub_quota_srv           # CLIPS 驱动的配额检查
├── ersub_clips_pool          # CLIPS Port 工作池（poolboy）
├── ersub_pricing_srv         # 模型定价（ETS + 自动更新）
├── ersub_moderation_srv      # 内容审核管道
├── ersub_ops_alert_srv       # 告警规则评估
├── ersub_payment_srv         # 支付订单生命周期
├── ersub_token_refresh_srv   # OAuth Token 自动刷新
├── ersub_affiliate_srv       # 分销返佣管理
├── ersub_balance_notify_srv  # 余额通知
├── ersub_health_srv          # 健康评分计算
├── ersub_metrics_srv         # 多粒度指标聚合
├── ersub_usage_cleanup_srv   # 使用记录定时清理
├── ersub_scheduled_test_srv  # 账户健康检测
└── ersub_channel_monitor     # Channel 可用性探测
```

---

## 项目数据

| 指标 | 数值 |
|------|------|
| Erlang 源模块 | 77 |
| 测试文件 | 33 |
| 代码行数 | ~12,000 行 Erlang + 220 行 C + 535 行 SQL |
| CLIPS 规则 | 18 条规则，23 个模板，7 个规则文件 |
| 数据库表 | 39 张（5 个 migration） |
| Supervisor 子进程 | 26 个 |
| 单元测试 | 88 个（0 失败） |
| API 端点 | 20 个（7 网关 + 13 管理） |

---

## 测试

```bash
# 单元 + 属性测试
rebar3 as test eunit --dir=test/unit --dir=test/property

# 集成测试（需要 PostgreSQL）
rebar3 as test ct --dir=test/integration

# 端到端测试（需要运行中的服务）
rebar3 as test ct --dir=test/e2e

# 全部测试
make test
```

---

## 设计文档

- [DESIGN.md](docs/DESIGN.md) — 完整系统设计文档（4000+ 行）
- [ersub_plan.md](docs/ersub_plan.md) — Phase 2 功能补全设计
- [plan.md](docs/plan.md) — 质量审计报告

---

## 致谢

- [sub2api](https://github.com/Wei-Shaw/sub2api) — Go 参考实现
- [CLIPS](https://www.clipsrules.net/) — 规则引擎（6.4）
- [Cowboy](https://github.com/ninenines/cowboy) — HTTP 服务器
- [gun](https://github.com/ninenines/gun) — HTTP 客户端
- [poolboy](https://github.com/devinus/poolboy) — 工作池

## 许可证

Apache-2.0
