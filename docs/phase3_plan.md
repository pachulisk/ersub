# ErSub Phase 3 — sub2api 剩余功能差距 + CLIPS 最大化利用设计

## Context

Phase 1（165 任务）+ Phase 2（41 任务）已全部完成。77 个 Erlang 模块，9 个 CLIPS 决策路径。本次审计基于最新源码对比，找出仍然缺失的功能。

**当前覆盖率估计：~60%**（核心代理管道完整，但管理/运维/前端层有显著差距）

## 设计原则

**最大化利用 CLIPS 规则引擎。** 以下新功能中所有涉及"决策/判断/策略/匹配/转换"的逻辑，必须通过 CLIPS 规则实现：
- 连接池隔离策略选择 → `pool_strategy.clp`
- 流式 failover 决策 → `failover.clp`
- OAuth 身份采纳决策 → `identity_adoption.clp`
- 订阅分配策略 → `subscription.clp`
- 可用 channel 筛选 → `channel_filter.clp`
- Ops 告警规则评估 → 已有 `account_status.clp`，扩展
- SetupToken 预算窗口 → `budget_window.clp`

---

## Tier 0 — 阻塞级（性能/可用性）

### 1. 连接池：每请求新建连接，无复用

ersub 的 `ersub_upstream_pool` 每次请求都 `gun:open` → 转发 → `gun:close`。sub2api 有三种隔离模式（proxy/account/account_proxy）+ LRU 驱逐 + inFlight 跟踪 + 5000 最大连接 + per-host 240 限制。

**影响：** 3-5x 性能劣势，高并发下连接耗尽。

**CLIPS 设计 — `pool_strategy.clp`：**
```clips
;; 连接池隔离策略选择规则
(deftemplate pool-request
    (slot account-id) (slot proxy-endpoint) (slot platform))
(deftemplate pool-strategy-result
    (slot key-type)    ;; proxy | account | account_proxy
    (slot pool-key))   ;; 用于 ETS 查找的组合键

(defrule select-account-proxy-mode
    "默认：每个 {account, proxy} 组合独立连接池"
    (pool-config (mode account_proxy))
    (pool-request (account-id ?aid) (proxy-endpoint ?pe))
    => (assert (pool-strategy-result (key-type account_proxy)
               (pool-key (str-cat ?aid ":" ?pe)))))
```
Erlang 侧用 ETS 管理连接池，CLIPS 决定 pool key 策略。

### 2. 前端：无 Web UI

sub2api 有完整的 Vue 3 管理界面（用户管理、账户管理、使用统计、仪表盘）。ersub 只有 API 端点 + Markdown 页面，无可视化管理界面。

### 3. 流式 Failover：流中无账户切换

sub2api 的 `failover_loop.go` 在流式传输中检测到错误后可切换到下一个账户继续。ersub 的 `ersub_stream_fsm` 在流开始后绑定单一账户，中途失败直接报错。

**CLIPS 设计 — `failover.clp`：**
```clips
;; 流式 failover 决策规则
(deftemplate stream-error-event
    (slot account-id) (slot error-code) (slot bytes-sent) (slot stream-started))
(deftemplate failover-decision
    (slot action)       ;; retry_same | switch_account | abort
    (slot reason))

(defrule failover-retriable-before-stream
    "流未开始 + 可重试错误 → 切换账户"
    (stream-error-event (error-code ?c&429|502|503|529) (stream-started FALSE))
    => (assert (failover-decision (action switch_account) (reason retriable_pre_stream))))

(defrule failover-mid-stream-abort
    "流已开始 + 错误 → 中止（不能切换，客户端已收到部分数据）"
    (stream-error-event (stream-started TRUE))
    => (assert (failover-decision (action abort) (reason mid_stream_error))))
```

### 4. OAuth 待定会话决策流程

sub2api 有完整的 pending auth session（60K+ 行），含身份采纳决策（头像/昵称选择）、completion code 验证、浏览器会话防 CSRF。ersub 只有基础 OAuth redirect → callback → JWT。

**CLIPS 设计 — `identity_adoption.clp`：**
```clips
;; 身份采纳决策规则
(deftemplate identity-conflict
    (slot provider) (slot existing-email) (slot oauth-email)
    (slot has-display-name) (slot has-avatar))
(deftemplate adoption-decision
    (slot adopt-display-name)  ;; TRUE | FALSE
    (slot adopt-avatar)        ;; TRUE | FALSE
    (slot action)              ;; merge | create_new | reject)

(defrule adopt-new-user-all
    "新用户：采纳所有 OAuth 信息"
    (identity-conflict (existing-email nil) (has-display-name TRUE) (has-avatar TRUE))
    => (assert (adoption-decision (adopt-display-name TRUE) (adopt-avatar TRUE) (action create_new))))

(defrule merge-existing-keep-local
    "已有用户：保留本地信息"
    (identity-conflict (existing-email ?e&~nil))
    => (assert (adoption-decision (adopt-display-name FALSE) (adopt-avatar FALSE) (action merge))))
```

---

## Tier 1 — 应尽快修复

### 5. 管理端点缺失（~20 个）

| 缺失端点 | sub2api 文件 |
|----------|-------------|
| 使用量分析（搜索/统计/清理任务） | `usage_handler.go` |
| 订阅管理 CRUD | `subscription_handler.go` |
| 数据管理（S3 备份/恢复） | `data_management_handler.go` |
| 系统配置/诊断 | `system_handler.go` |
| Ops 仪表盘（6 个指标端点） | `ops_dashboard_handler.go` |
| Ops 实时/快照 | `ops_realtime_handler.go`, `ops_snapshot_v2_handler.go` |
| Ops 告警 CRUD（7 个端点） | `ops_alerts_handler.go` |
| Ops 设置 | `ops_settings_handler.go` |
| 可用 Channel 列表 | `available_channel_handler.go` |
| Channel 监控用户端点 | `channel_monitor_user_handler.go` |
| 分销管理 Handler | `affiliate_handler.go` |

### 6. 计费字段未实际记录

`billing_model_source` 和 `model_mapping_chain` 字段在 usage_logs 表中存在，但实际计费路径（`ersub_billing_helper`）未填充这些字段。

**CLIPS 已有支持：** billing.clp 的 billing-result 可扩展输出 `billing-model-source` 字段。Erlang 侧需将 `resolve_model_chain` 的结果（chain string + source）传入 CLIPS facts，CLIPS 返回时一并输出。

### 7. 用户注册来源追踪

sub2api 追踪 `signup_source`（email/github/google/wechat/linuxdo/oidc）、`last_login_at`、`total_recharged`。ersub 用户表缺少这些字段和逻辑。

**实现：** 新增 migration 添加 `signup_source TEXT`、`last_login_at TIMESTAMPTZ`、`total_recharged NUMERIC(12,6)` 到 users 表。auth_handler 在注册/登录时更新。

---

## Tier 2 — 锦上添花

### 8. 用户 display_name / avatar

sub2api 用户有 username、display_name、avatar URL。ersub 只有 email。

### 9. SetupToken 5 小时窗口预算

sub2api 的 SetupToken 账户类型有 `rate_limit_5h` 滑动窗口预算。ersub 有字段但无实施逻辑。

### 10. 详细运维分析表

sub2api 有：ops_runtime_logging、ops_request_details、ops_account_availability、ops_window_stats、ops_trends、ops_token_stats。ersub 只有 ops_system_logs + metrics_aggregated。

### 11. 缺失 OAuth Provider

sub2api 支持 LinuxDo、WeChat、email 验证。ersub 只支持 GitHub、Google、通用 OIDC。

### 12. 分级定价（Tiered Pricing）

sub2api Channel 支持分级定价（不同用量阶梯不同单价）。ersub Channel 只支持固定定价覆盖。

### 13. 账户 extra JSONB

sub2api 账户有 `extra` JSONB 字段用于平台特定扩展数据。ersub 无此字段。

---

## 新增 CLIPS 规则文件（Phase 3）

Phase 3 将新增以下 CLIPS 规则文件，使 CLIPS 决策路径从 9 个增加到 15+ 个：

| 新规则文件 | 决策类型 | 对应功能 |
|-----------|---------|---------|
| `pool_strategy.clp` | 连接池隔离键计算 | Tier 0 #1 |
| `failover.clp` | 流式 failover 决策（retry/switch/abort） | Tier 0 #3 |
| `identity_adoption.clp` | OAuth 身份采纳（merge/create/reject） | Tier 0 #4 |
| `subscription.clp` | 订阅分配策略（余额优先/配额优先） | Tier 1 #7 |
| `channel_filter.clp` | 可用 channel 筛选（模型/价格/可用性） | Tier 1 #5 |
| `budget_window.clp` | SetupToken 5h 滑动窗口预算 | Tier 2 #9 |

每个规则文件在 `priv/clips/` 下，通过 `ersub_clips_pool` 的 `with_worker` 调用。CLIPS worker 已有通用 assert→run→collect 框架，只需新增 fact builder 函数。

---

## 前端对接方案

sub2api 有完整 Vue 3 前端（`~/Projects/sub2api/frontend/`），API base URL 为 `/api/v1`。

**对接步骤：**
1. 将 sub2api 前端源码复制到 ersub 的 `frontend/` 目录
2. 修改 ersub 路由：所有 `/api/user|admin|auth|...` → `/api/v1/user|admin|auth|...`
3. 补齐前端调用的缺失 API 端点（~30 个）
4. `pnpm build` → 产物复制到 `priv/static/`
5. cowboy_static 已就绪，可直接服务

**路由差异：** sub2api 用 `/api/v1/*`，ersub 用 `/api/*`（缺少 v1 层级）

---

## 数量汇总

| 类别 | sub2api | ersub 已实现 | 缺失 |
|------|---------|------------|------|
| Admin handler 端点 | ~45 | ~15 | ~30 |
| OAuth provider | 7+ | 3 | 4 |
| Ops 分析表 | 6 | 2 | 4 |
| 连接池隔离模式 | 3 | 0 | 3 |
| 前端页面 | 完整 Vue 3 | 可复用 | 需路由对齐 |
| 流式 Failover | 完整 | 无 | 全部 |
