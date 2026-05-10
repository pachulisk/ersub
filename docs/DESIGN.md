# ErSub - Design Document

基于 Erlang/OTP + CLIPS 的 AI API 网关平台，功能对标 [sub2api](https://github.com/Wei-Shaw/sub2api)。

## 1. 动机与目标

sub2api 是一个用 Go 实现的 AI API 网关，核心功能：将上游 AI 订阅（Claude、OpenAI、Gemini 等）的 API 配额分发给多个用户，包含认证、计费、负载均衡、请求转发、流式响应等能力。

**为什么用 Erlang + CLIPS 重新实现？**

| 维度 | Go (sub2api) | Erlang/OTP + CLIPS (ersub) |
|------|-------------|---------------------------|
| 并发模型 | goroutine + mutex/atomic + Redis | process-per-connection，原生隔离 |
| 容错性 | 手动 recovery + Redis 队列 | OTP supervision tree，let-it-crash |
| 流式处理 | SSE scanner + buffer pool | gen_statem 状态机，天然适配 |
| 决策引擎 | 硬编码评分算法 | CLIPS 规则引擎，规则可热更新 |
| 状态管理 | Redis (外部依赖) | ETS/Mnesia (内置，零运维) |
| 热更新 | 重启部署 | hot code reload |

**核心目标：**

1. API 兼容 sub2api（客户端无感切换）
2. 用 CLIPS 规则引擎替代硬编码的调度/计费/配额逻辑，支持运行时规则热更新
3. 用 BEAM 原语替代 Redis，减少外部依赖
4. 充分发挥 OTP 的并发与容错优势

---

## 2. CLIPS 集成策略

### 2.1 集成方式选型

| 方式 | 延迟 | 隔离性 | 复杂度 | 适用场景 |
|------|------|--------|--------|----------|
| **Port (stdin/stdout)** | ~1-5ms | 崩溃隔离 | 低 | 每请求决策 |
| NIF | ~10μs | 无隔离，可崩 VM | 高 | 每包决策 |
| C Node | ~0.5ms | 进程隔离 | 中 | 高频+隔离 |

**选择：Port 方式。**

理由：
- CLIPS 决策发生在**请求级别**（账户选择、计费计算），不在数据包级别（SSE chunk 流转）
- 每请求 1-5ms 的序列化开销完全可接受（上游 API 延迟 100ms-10s）
- Port 崩溃不会影响 BEAM VM，符合 let-it-crash 哲学
- 实现简单，调试方便

### 2.2 CLIPS Engine Pool

```
┌─────────────────────────────────────┐
│         clips_pool_sup              │
│      (poolboy supervisor)           │
│                                     │
│  ┌──────────┐ ┌──────────┐ ┌─────┐ │
│  │ clips_w1 │ │ clips_w2 │ │ ... │ │
│  │ (port)   │ │ (port)   │ │     │ │
│  └──────────┘ └──────────┘ └─────┘ │
└─────────────────────────────────────┘
```

- 使用 `poolboy` 管理 CLIPS Port 进程池
- 每个 worker 是一个 `gen_server`，持有一个 CLIPS Port 进程
- 池大小可配置（默认 = schedulers_online × 2）
- Worker 崩溃自动重启，规则文件自动重新加载

### 2.3 通信协议

Erlang ↔ CLIPS Port 使用 JSON-line 协议（NDJSON）：

```
→ {"op":"assert","facts":[{"type":"account","id":1,"priority":2,"load":35,"error_rate":0.02},...]}
→ {"op":"run"}
← {"op":"result","selected_account_id":3,"score":0.87,"reason":"lowest_load"}
→ {"op":"retract_all"}
```

CLIPS 端编译为独立可执行文件 `ersub_clips`，启动时加载规则文件，循环读取 stdin 指令。

### 2.4 CLIPS 职责边界

**CLIPS 负责（规则驱动的决策）：**

| 领域 | 说明 |
|------|------|
| 账户选择评分 | 多因子加权评分：priority、load、queue、error_rate、ttft |
| 计费规则解析 | tier 乘数、cache 分级定价、长上下文溢价、图片定价模式 |
| 配额策略执行 | 日/周/月配额检查与重置判定 |
| 账户状态转换 | active → rate_limited → overloaded → temp_unschedulable 的规则化管理 |
| 模型路由 | 基于 group 的 model pattern → account list 映射决策 |

**Erlang 原生处理（不经过 CLIPS）：**

| 领域 | 说明 | BEAM 原语 |
|------|------|-----------|
| 并发控制 | per-user / per-account 并发槽 | process count / `counters` |
| 流式响应 | SSE/WebSocket 流转发 | `gen_statem` per-stream |
| 会话粘滞 | session hash → account 映射 | ETS with TTL |
| 健康检查 | 端口存活、上游连通性 | supervisor + monitor |
| 配置缓存 | 热读配置 | `persistent_term` |
| 请求排队 | 等待并发槽释放 | gen_server mailbox |

---

## 3. 系统架构

### 3.1 总体架构

```
                         Client (curl / SDK / Frontend)
                                    │
                                    ▼
                        ┌───────────────────────┐
                        │   Cowboy HTTP Server   │
                        │  (HTTP/1.1 + HTTP/2)   │
                        └───────────┬───────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
            ┌──────────┐   ┌──────────────┐  ┌──────────┐
            │ Gateway   │   │ Admin/User   │  │ Payment  │
            │ Handlers  │   │ Handlers     │  │ Handlers │
            └─────┬────┘   └──────┬───────┘  └────┬─────┘
                  │               │                │
                  ▼               ▼                ▼
            ┌──────────────────────────────────────────┐
            │            Service Layer                  │
            │                                          │
            │  ┌────────────┐  ┌──────────────────┐   │
            │  │ Scheduler  │  │ Billing Service   │   │
            │  │ Service    │  │                   │   │
            │  │  ┌──────┐  │  │  ┌──────┐        │   │
            │  │  │CLIPS │  │  │  │CLIPS │        │   │
            │  │  │Engine│  │  │  │Engine│        │   │
            │  │  └──────┘  │  │  └──────┘        │   │
            │  └────────────┘  └──────────────────┘   │
            │                                          │
            │  ┌───────────┐  ┌──────────┐            │
            │  │Concurrency│  │ Session   │            │
            │  │ Manager   │  │ Manager   │            │
            │  │(counters) │  │ (ETS)     │            │
            │  └───────────┘  └──────────┘            │
            └──────────────────┬───────────────────────┘
                               │
                    ┌──────────┼──────────┐
                    ▼          ▼          ▼
              ┌─────────┐ ┌───────┐ ┌──────────┐
              │PostgreSQL│ │ ETS / │ │ Upstream │
              │ (持久化)  │ │Mnesia │ │ APIs     │
              └─────────┘ └───────┘ └──────────┘
```

### 3.2 OTP Supervision Tree

```
ersub_app (application)
│
└── ersub_sup (one_for_one)
    │
    ├── ersub_config_srv (gen_server)
    │   配置加载与 persistent_term 写入
    │
    ├── ersub_db_sup (rest_for_one)
    │   ├── ersub_repo_pool (poolboy → PostgreSQL 连接池)
    │   └── ersub_migration_srv (启动时执行 migration)
    │
    ├── ersub_clips_pool_sup (poolboy)
    │   ├── ersub_clips_worker_1 (gen_server + port)
    │   ├── ersub_clips_worker_2
    │   └── ...
    │
    ├── ersub_platform_sup (one_for_one)
    │   ├── ersub_claude_pool_sup (one_for_one)
    │   │   └── 每个 Claude 账户一个 gen_server（状态、EWMA 统计）
    │   ├── ersub_openai_pool_sup
    │   │   └── 每个 OpenAI 账户一个 gen_server
    │   ├── ersub_gemini_pool_sup
    │   │   └── 每个 Gemini 账户一个 gen_server
    │   └── ersub_antigravity_pool_sup
    │       └── 每个 Antigravity 账户一个 gen_server
    │
    ├── ersub_concurrency_sup (one_for_one)
    │   ├── ersub_user_concurrency_srv (gen_server, counters)
    │   └── ersub_account_concurrency_srv (gen_server, counters)
    │
    ├── ersub_session_srv (gen_server)
    │   会话粘滞管理，ETS 存储 session_hash → account_id
    │
    ├── ersub_billing_sup (one_for_one)
    │   ├── ersub_billing_srv (gen_server, 实时计费)
    │   └── ersub_usage_logger (gen_server, 异步写入 usage_logs)
    │
    ├── ersub_scheduler_srv (gen_server)
    │   调度入口，组合 CLIPS 评分 + 粘滞 + 并发检查
    │
    ├── ersub_payment_sup (one_for_one, 按需启动)
    │   ├── ersub_stripe_srv
    │   ├── ersub_alipay_srv
    │   └── ersub_wechat_srv
    │
    ├── ersub_auth_srv (gen_server)
    │   JWT 签发/验证、OAuth 流程、TOTP
    │
    ├── ersub_moderation_sup (one_for_one, 可选)
    │   ├── ersub_moderation_srv (gen_server, 入口)
    │   ├── ersub_moderation_worker_pool (poolboy, 4-32 workers)
    │   └── ersub_moderation_cache (gen_server, SHA256 去重)
    │
    ├── ersub_token_refresh_srv (gen_server)
    │   OAuth token 定时刷新 + 401 触发刷新
    │
    ├── ersub_rate_limiter (gen_server)
    │   RPM 滑动窗口限速（ETS）
    │
    ├── ersub_ops_sup (one_for_one)
    │   ├── ersub_health_srv (健康评分)
    │   ├── ersub_metrics_srv (指标聚合)
    │   ├── ersub_usage_cleanup_srv (定时清理)
    │   └── ersub_ops_alert_srv (告警评估)
    │
    ├── ersub_pricing_srv (gen_server)
    │   定价表管理 + 定时更新
    │
    ├── ersub_affiliate_srv (gen_server)
    │   分销返佣管理
    │
    ├── ersub_scheduled_test_sup (one_for_one, 可选)
    │   ├── ersub_scheduled_test_srv (定时检测调度)
    │   └── ersub_scheduled_test_runner (检测执行)
    │
    ├── ersub_channel_monitor_sup (one_for_one, 可选)
    │   ├── ersub_channel_monitor_runner (定时触发)
    │   ├── ersub_channel_monitor_checker (执行检查)
    │   └── ersub_channel_monitor_aggregator (日聚合)
    │
    ├── ersub_proxy_srv (gen_server)
    │   代理配置 + 延迟探测
    │
    ├── ersub_balance_notify_srv (gen_server)
    │   余额通知检查 + 邮件发送
    │
    ├── ersub_backup_srv (gen_server, 可选)
    │   S3 备份任务调度
    │
    └── cowboy_listener (ranch)
        HTTP listener，每连接一个 cowboy_handler 进程
```

### 3.3 请求处理流程

```
Client POST /v1/messages
        │
        ▼
[cowboy_handler] ── 每连接一个 Erlang 进程
        │
        ├─ 0. 安全前置：
        │      IP 黑白名单检查（CIDR 匹配）
        │      请求体大小校验（max_body_size）
        │      RPM 限速检查（滑动窗口）
        │
        ├─ 1. 认证：从 header 提取 API Key → ETS 查找 → 获取 user/group
        │      Claude Code 客户端检测（User-Agent / metadata）
        │      claude_code_only 分组限制执行
        │
        ├─ 2. 内容审核（可选）：
        │      模式：off / observe（异步记录）/ pre_block（阻断）
        │      SHA256 去重 → OpenAI Moderation API → 13类风险评分
        │      超阈值 → 记录 + 可选自动封号
        │
        ├─ 3. 并发检查：ersub_concurrency_srv:acquire(UserId)
        │      成功 → 继续
        │      队列满 → 429
        │      需等待 → 进入等待状态（streaming 时发送 ping）
        │
        ├─ 4. 计费预检：ersub_billing_srv:check_balance(UserId, EstimatedCost)
        │      配额检查（日/周/月限额，CLIPS 规则）
        │
        ├─ 5. 账户选择：ersub_scheduler_srv:select_account(Req)
        │      │
        │      ├─ PreviousResponseID 粘滞（OpenAI Responses）
        │      ├─ SessionHash 粘滞：ETS lookup
        │      │   命中 → 使用粘滞账户
        │      │
        │      └─ CLIPS 评分：
        │          模型路由过滤 → assert(候选账户 facts) → run → top-k 加权随机
        │
        ├─ 6. 请求转换：
        │      模型名映射（Channel → Account → Group 三级链）
        │      通配符匹配（gpt-* → 具体模型）
        │      system prompt 处理
        │      cache_control block 注入
        │      工具定义改写
        │      映射链记录（billing_model_source）
        │
        ├─ 7. 上游 URL 安全校验：
        │      scheme 强制（HTTPS）、主机白名单、私有 IP 阻断
        │      DNS Rebinding 防护（解析后二次校验）
        │
        ├─ 8. 上游调用：gun HTTP client（连接池隔离）
        │      │
        │      ├─ 成功 → 流式转发
        │      │   gen_statem: idle → streaming → accumulating → done
        │      │   每个 SSE chunk → 转发给客户端 + 累计 token
        │      │
        │      └─ 失败 → 错误处理
        │          错误透传规则匹配（CLIPS）→ 透传/自定义
        │          429/502/503 → 账户状态更新 → failover 下一账户
        │          401/403 → OAuth token 刷新 → 重试
        │          最多 max_account_switches 次
        │
        ├─ 9. 计费记录：
        │      CLIPS 计算 cost（含 tier/multiplier/cache 分级/图片分级）
        │      计费模式选择（token / per_request / image）
        │      ersub_billing_srv:deduct(UserId, ActualCost)
        │      ersub_usage_logger:log(UsageRecord)  (异步)
        │
        └─ 10. 释放：ersub_concurrency_srv:release(UserId)
```

---

## 4. 核心模块设计

### 4.1 账户管理（Account Process）

每个上游账户对应一个 `gen_server` 进程，负责：

```erlang
-record(account_state, {
    id              :: integer(),
    platform        :: claude | openai | gemini | antigravity,
    account_type    :: oauth | setup_token | api_key | upstream | bedrock,
    credentials     :: map(),          % 凭证（加密存储）
    status          :: active | rate_limited | overloaded | error | temp_unschedulable,
    priority        :: integer(),      % 越小优先级越高
    concurrency     :: integer(),      % 最大并发
    load_factor     :: integer() | undefined,
    rate_multiplier :: float() | undefined,

    %% EWMA 运行时统计
    ewma_error_rate :: float(),        % alpha=0.2
    ewma_ttft_ms    :: float(),        % 首 token 延迟
    current_load    :: integer(),      % 当前并发数
    waiting_count   :: integer(),      % 排队数

    %% 状态恢复时间戳
    rate_limited_until   :: integer() | undefined,  % unix ms
    overload_until       :: integer() | undefined,
    temp_unsched_until   :: integer() | undefined,

    %% OAuth token 管理
    access_token    :: binary() | undefined,
    token_expires   :: integer() | undefined
}).
```

状态转换规则（由 CLIPS 驱动）：

```
                    ┌─── 401/403 ──→ [refresh token]
                    │                    │
                    │              success/fail
                    │               │       │
     ┌──────┐  429 │   ┌───────────▼──┐    └──→ [error]
     │active │──────┼──→│rate_limited  │
     │      │  529  │   └──────┬───────┘
     │      │───────┘          │ cooldown 过期
     │      │◀─────────────────┘
     │      │
     │      │  502/503
     │      │──────────→ [overloaded] ──cooldown──→ [active]
     │      │
     │      │  手动标记
     │      │──────────→ [temp_unschedulable] ──TTL──→ [active]
     └──────┘
```

### 4.2 调度器（Scheduler）

`ersub_scheduler_srv` 是调度入口，三层选择策略：

**Layer 1: 粘滞会话**
```erlang
%% ETS table: ersub_sticky_sessions
%% Key: {UserId, SessionHash}
%% Value: {AccountId, ExpireTime}
case ets:lookup(ersub_sticky_sessions, {UserId, SessionHash}) of
    [{_, {AccountId, Expire}}] when Expire > Now ->
        {sticky, AccountId};
    _ ->
        proceed_to_clips
end
```

**Layer 2: CLIPS 评分选择**
```clips
;; 账户候选 fact
(deftemplate candidate-account
    (slot id (type INTEGER))
    (slot priority (type INTEGER))
    (slot load-rate (type FLOAT))        ;; 0.0 - 1.0+
    (slot waiting-count (type INTEGER))
    (slot ewma-error-rate (type FLOAT))  ;; 0.0 - 1.0
    (slot ewma-ttft-ms (type FLOAT))
    (slot status (type SYMBOL))          ;; active
    (slot platform (type SYMBOL))
    (slot supports-model (type INTEGER)) ;; 1 or 0
)

;; 评分权重配置
(deftemplate score-weights
    (slot priority-w (type FLOAT) (default 1.0))
    (slot load-w (type FLOAT) (default 1.0))
    (slot queue-w (type FLOAT) (default 0.7))
    (slot error-rate-w (type FLOAT) (default 0.8))
    (slot ttft-w (type FLOAT) (default 0.5))
)

;; 评分计算规则
(defrule calculate-score
    (score-weights (priority-w ?pw) (load-w ?lw) (queue-w ?qw)
                   (error-rate-w ?ew) (ttft-w ?tw))
    (max-values (max-priority ?mp) (max-waiting ?mw) (max-ttft ?mt))
    ?acc <- (candidate-account (id ?id) (priority ?p) (load-rate ?lr)
                               (waiting-count ?wc) (ewma-error-rate ?er)
                               (ewma-ttft-ms ?ttft) (status active)
                               (supports-model 1))
    =>
    (bind ?norm-p (/ (- ?mp ?p) (max ?mp 1)))
    (bind ?norm-l (- 1.0 (min ?lr 1.0)))
    (bind ?norm-q (- 1.0 (/ ?wc (max ?mw 1))))
    (bind ?norm-e (- 1.0 ?er))
    (bind ?norm-t (- 1.0 (/ ?ttft (max ?mt 1))))
    (bind ?score (+ (* ?pw ?norm-p) (* ?lw ?norm-l)
                    (* ?qw ?norm-q) (* ?ew ?norm-e)
                    (* ?tw ?norm-t)))
    (assert (account-score (id ?id) (score ?score)))
)

;; 选择最优（top-k 随机）
(defrule select-best
    (select-config (top-k ?k))
    ;; 收集所有评分后触发
    =>
    ;; 取 top-k，加权随机选一个
    (bind ?results (sort-by-score (find-all-facts ((?s account-score)) TRUE)))
    (bind ?selected (weighted-random-pick (subseq$ ?results 1 ?k)))
    (assert (selection-result (account-id ?selected)))
)
```

**Layer 3: Failover**
```erlang
select_with_failover(Req, ExcludedIds, Attempt) when Attempt =< MaxSwitches ->
    case select_account(Req#{excluded_ids => ExcludedIds}) of
        {ok, AccountId} ->
            case forward_request(AccountId, Req) of
                {ok, Response} ->
                    {ok, Response};
                {error, {http, Code}} when Code =:= 429; Code =:= 502; Code =:= 503 ->
                    update_account_status(AccountId, Code),
                    select_with_failover(Req, ExcludedIds#{AccountId => true}, Attempt + 1);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, no_available_account} ->
            {error, no_available_account}
    end;
select_with_failover(_, _, _) ->
    {error, max_switches_exceeded}.
```

### 4.3 并发控制

**不使用 Redis，改用 BEAM 原语：**

```erlang
%% ersub_concurrency_srv

-record(conc_state, {
    %% counters ref，每个 user/account 一个 slot
    user_slots    :: counters:counters_ref(),
    account_slots :: counters:counters_ref(),

    %% user_id → {max_concurrency, slot_index} 映射
    user_map      :: ets:tid(),
    account_map   :: ets:tid(),

    %% 等待队列：{UserId, From} 列表
    wait_queues   :: #{integer() => queue:queue()}
}).

%% 获取并发槽
acquire(UserId) ->
    gen_server:call(ersub_concurrency_srv, {acquire, UserId}, 30_000).

%% 释放并发槽（通过 monitor 自动释放保底）
release(UserId, Ref) ->
    gen_server:cast(ersub_concurrency_srv, {release, UserId, Ref}).
```

等待机制与流式 ping：

```erlang
%% cowboy handler 中
case ersub_concurrency_srv:acquire(UserId) of
    {ok, Ref} ->
        proceed(Req, Ref);
    {wait, WaitRef} when IsStreaming ->
        %% 先发送 SSE headers
        send_sse_headers(Req),
        %% 每 10s 发送 ping，等待通知
        wait_with_ping(WaitRef, Req, PingInterval);
    {wait, _} ->
        %% 非流式，同步等待
        receive
            {slot_acquired, Ref} -> proceed(Req, Ref)
        after 30_000 ->
            reply_429(Req)
        end;
    {rejected, queue_full} ->
        reply_429(Req)
end.
```

### 4.4 计费系统

**CLIPS 规则驱动的计费计算：**

```clips
;; 定价 fact（从 pricing table 加载）
(deftemplate model-pricing
    (slot model (type STRING))
    (slot input-price (type FLOAT))
    (slot output-price (type FLOAT))
    (slot cache-read-price (type FLOAT))
    (slot cache-creation-price (type FLOAT))
    (slot cache-5m-price (type FLOAT))
    (slot cache-1h-price (type FLOAT))
    (slot image-output-price (type FLOAT))
    (slot long-ctx-threshold (type INTEGER) (default 0))
    (slot long-ctx-input-mult (type FLOAT) (default 1.0))
    (slot long-ctx-output-mult (type FLOAT) (default 1.0))
)

;; 使用量 fact（每次请求构造）
(deftemplate usage
    (slot model (type STRING))
    (slot input-tokens (type INTEGER))
    (slot output-tokens (type INTEGER))
    (slot cache-read-tokens (type INTEGER))
    (slot cache-5m-tokens (type INTEGER))
    (slot cache-1h-tokens (type INTEGER))
    (slot image-output-tokens (type INTEGER))
    (slot service-tier (type SYMBOL))      ;; standard | priority | flex
    (slot account-rate-mult (type FLOAT))
    (slot group-rate-mult (type FLOAT))
    (slot total-input-tokens (type INTEGER)) ;; 用于长上下文判定
)

;; 服务等级乘数
(defrule resolve-tier-multiplier
    (usage (service-tier ?tier))
    =>
    (bind ?mult (if (eq ?tier priority) then 2.0
                 else (if (eq ?tier flex) then 0.5
                 else 1.0)))
    (assert (tier-multiplier (value ?mult)))
)

;; 长上下文乘数
(defrule resolve-long-context
    (usage (model ?m) (total-input-tokens ?total))
    (model-pricing (model ?m) (long-ctx-threshold ?th)
                   (long-ctx-input-mult ?im) (long-ctx-output-mult ?om))
    =>
    (if (and (> ?th 0) (> ?total ?th))
     then
        (assert (long-ctx-input-mult (value ?im)))
        (assert (long-ctx-output-mult (value ?om)))
     else
        (assert (long-ctx-input-mult (value 1.0)))
        (assert (long-ctx-output-mult (value 1.0))))
)

;; 最终成本计算
(defrule calculate-cost
    (usage (model ?m) (input-tokens ?it) (output-tokens ?ot)
           (cache-read-tokens ?crt) (cache-5m-tokens ?c5)
           (cache-1h-tokens ?c1) (image-output-tokens ?iot)
           (account-rate-mult ?arm) (group-rate-mult ?grm))
    (model-pricing (model ?m) (input-price ?ip) (output-price ?op)
                   (cache-read-price ?crp) (cache-5m-price ?c5p)
                   (cache-1h-price ?c1p) (image-output-price ?iop))
    (tier-multiplier (value ?tm))
    (long-ctx-input-mult (value ?lim))
    (long-ctx-output-mult (value ?lom))
    =>
    (bind ?input-cost (* ?it ?ip ?tm ?lim))
    (bind ?output-cost (* ?ot ?op ?tm ?lom))
    (bind ?cache-read-cost (* ?crt ?crp ?tm))
    (bind ?cache-creation-cost (+ (* ?c5 ?c5p ?tm) (* ?c1 ?c1p ?tm)))
    (bind ?image-cost (* ?iot ?iop ?tm))
    (bind ?total (+ ?input-cost ?output-cost ?cache-read-cost
                    ?cache-creation-cost ?image-cost))
    (bind ?actual (* ?total ?arm ?grm))
    (assert (billing-result
        (input-cost ?input-cost) (output-cost ?output-cost)
        (cache-read-cost ?cache-read-cost) (cache-creation-cost ?cache-creation-cost)
        (image-cost ?image-cost) (total-cost ?total) (actual-cost ?actual)))
)

;; === 多计费模式支持 ===

;; Per-Request 计费模式（固定单价，不按 token）
(deftemplate per-request-pricing
    (slot model (type STRING))
    (slot fixed-price (type FLOAT))
)

(defrule calculate-per-request-cost
    (billing-mode (mode per_request))
    (per-request-pricing (model ?m) (fixed-price ?fp))
    (usage (model ?m) (account-rate-mult ?arm) (group-rate-mult ?grm))
    =>
    (assert (billing-result
        (input-cost 0.0) (output-cost 0.0)
        (cache-read-cost 0.0) (cache-creation-cost 0.0)
        (image-cost 0.0) (total-cost ?fp)
        (actual-cost (* ?fp ?arm ?grm))))
)

;; 图片生成计费模式（按尺寸分级）
(deftemplate image-request
    (slot model (type STRING))
    (slot image-count (type INTEGER))
    (slot image-size (type SYMBOL))    ;; s1K | s2K | s4K | HD
    (slot account-rate-mult (type FLOAT))
    (slot group-rate-mult (type FLOAT))
    (slot group-image-rate-mult (type FLOAT))
    (slot group-image-rate-independent (type INTEGER))  ;; 1=独立乘数
)

(deftemplate image-size-pricing
    (slot size (type SYMBOL))
    (slot price (type FLOAT))
)

(defrule calculate-image-cost
    (billing-mode (mode image))
    (image-request (image-count ?cnt) (image-size ?sz)
                   (account-rate-mult ?arm) (group-rate-mult ?grm)
                   (group-image-rate-mult ?girm)
                   (group-image-rate-independent ?indep))
    (image-size-pricing (size ?sz) (price ?p))
    =>
    (bind ?base (* ?cnt ?p))
    (bind ?rate-mult (if (= ?indep 1)
                      then ?girm       ;; 独立图片乘数
                      else ?grm))      ;; 使用 group 通用乘数
    (bind ?actual (* ?base ?arm ?rate-mult))
    (assert (billing-result
        (input-cost 0.0) (output-cost 0.0)
        (cache-read-cost 0.0) (cache-creation-cost 0.0)
        (image-cost ?actual) (total-cost ?base) (actual-cost ?actual)))
)
```

**余额管理（Erlang 侧）：**

```erlang
%% ersub_billing_srv - gen_server
%% 用户余额缓存在 ETS，定期与 PostgreSQL 同步

%% 预检
check_balance(UserId, EstimatedCost) ->
    case ets:lookup(ersub_balances, UserId) of
        [{_, Balance}] when Balance >= EstimatedCost -> ok;
        [{_, _}] -> {error, insufficient_balance};
        [] ->
            %% 从 DB 加载
            Balance = ersub_repo:get_user_balance(UserId),
            ets:insert(ersub_balances, {UserId, Balance}),
            check_balance(UserId, EstimatedCost)
    end.

%% 扣费（原子操作）
deduct(UserId, ActualCost) ->
    ets:update_counter(ersub_balances, UserId, {2, -ActualCost}).
    %% 异步同步到 DB
    ersub_usage_logger:enqueue({deduct, UserId, ActualCost}).
```

### 4.5 流式响应处理

使用 `gen_statem` 管理每个流式请求的生命周期：

```erlang
%% ersub_stream_fsm

-behaviour(gen_statem).

%% 状态：idle → connecting → streaming → accumulating → done

%% 状态数据
-record(stream_data, {
    req_ref       :: reference(),
    client_pid    :: pid(),      % cowboy handler 进程
    upstream_conn :: pid(),      % gun connection
    stream_ref    :: reference(),
    accumulated   :: #{
        input_tokens  => integer(),
        output_tokens => integer(),
        cache_read    => integer(),
        cache_create  => integer()
    },
    first_token_time :: integer() | undefined,
    start_time       :: integer(),
    ping_timer       :: reference() | undefined,
    buffer           :: binary()
}).

%% 状态转换
idle({call, From}, {start, UpstreamUrl, Headers, Body}, Data) ->
    {ok, ConnPid} = gun:open(Host, Port, Opts),
    StreamRef = gun:post(ConnPid, Path, Headers, Body),
    {next_state, connecting, Data#{upstream_conn => ConnPid, stream_ref => StreamRef},
     [{reply, From, ok}]};

connecting(info, {gun_response, ConnPid, StreamRef, nofin, 200, Headers}, Data) ->
    %% 开始流式传输
    forward_headers(Data#stream_data.client_pid, Headers),
    {next_state, streaming, Data};

streaming(info, {gun_data, ConnPid, StreamRef, nofin, Chunk}, Data) ->
    %% 解析 SSE event，转发给客户端，累计 token
    {Events, NewBuffer} = parse_sse(<<(Data#stream_data.buffer)/binary, Chunk/binary>>),
    NewAccum = lists:foldl(fun accumulate_tokens/2, Data#stream_data.accumulated, Events),
    forward_events(Data#stream_data.client_pid, Events),
    {keep_state, Data#stream_data{buffer = NewBuffer, accumulated = NewAccum}};

streaming(info, {gun_data, ConnPid, StreamRef, fin, LastChunk}, Data) ->
    %% 流结束
    {Events, _} = parse_sse(<<(Data#stream_data.buffer)/binary, LastChunk/binary>>),
    FinalAccum = lists:foldl(fun accumulate_tokens/2, Data#stream_data.accumulated, Events),
    forward_events(Data#stream_data.client_pid, Events),
    {next_state, done, Data#stream_data{accumulated = FinalAccum},
     [{next_event, internal, finalize}]};

done(internal, finalize, Data) ->
    %% 触发计费
    Duration = erlang:monotonic_time(millisecond) - Data#stream_data.start_time,
    ersub_billing_srv:record_usage(Data#stream_data.accumulated, Duration),
    {stop, normal}.
```

### 4.6 配额管理

**CLIPS 规则驱动的配额检查：**

```clips
;; 订阅配额 fact
(deftemplate subscription-quota
    (slot user-id (type INTEGER))
    (slot group-id (type INTEGER))
    (slot daily-limit (type FLOAT))
    (slot daily-usage (type FLOAT))
    (slot weekly-limit (type FLOAT))
    (slot weekly-usage (type FLOAT))
    (slot monthly-limit (type FLOAT))
    (slot monthly-usage (type FLOAT))
    (slot additional-cost (type FLOAT))
)

;; 配额检查规则
(defrule check-daily-exceeded
    (subscription-quota (user-id ?uid) (daily-limit ?dl) (daily-usage ?du)
                        (additional-cost ?ac))
    (test (> (+ ?du ?ac) ?dl))
    (test (> ?dl 0))
    =>
    (assert (quota-violation (user-id ?uid) (type daily)
             (limit ?dl) (usage ?du) (requested ?ac)))
)

(defrule check-weekly-exceeded
    (subscription-quota (user-id ?uid) (weekly-limit ?wl) (weekly-usage ?wu)
                        (additional-cost ?ac))
    (test (> (+ ?wu ?ac) ?wl))
    (test (> ?wl 0))
    =>
    (assert (quota-violation (user-id ?uid) (type weekly)
             (limit ?wl) (usage ?wu) (requested ?ac)))
)

(defrule check-monthly-exceeded
    (subscription-quota (user-id ?uid) (monthly-limit ?ml) (monthly-usage ?mu)
                        (additional-cost ?ac))
    (test (> (+ ?mu ?ac) ?ml))
    (test (> ?ml 0))
    =>
    (assert (quota-violation (user-id ?uid) (type monthly)
             (limit ?ml) (usage ?mu) (requested ?ac)))
)

;; 全部通过
(defrule quota-ok
    (subscription-quota (user-id ?uid))
    (not (quota-violation (user-id ?uid)))
    =>
    (assert (quota-check-result (user-id ?uid) (allowed TRUE)))
)
```

**配额窗口重置（Erlang 定时器）：**

```erlang
%% ersub_quota_srv
%% 定时检查并重置配额窗口
init(_) ->
    schedule_daily_reset(),
    schedule_weekly_reset(),
    schedule_monthly_reset(),
    {ok, #{}}.

handle_info(daily_reset, State) ->
    ersub_repo:reset_daily_quotas(),
    schedule_daily_reset(),
    {noreply, State}.

schedule_daily_reset() ->
    MsUntilMidnight = ms_until_next_midnight(),
    erlang:send_after(MsUntilMidnight, self(), daily_reset).
```

### 4.7 内容审核系统

对标 sub2api 的 `content_moderation.go`，三种运行模式：

```erlang
%% ersub_moderation_sup (one_for_one)
%%   ├── ersub_moderation_srv (gen_server, 入口)
%%   ├── ersub_moderation_worker_pool (poolboy, 4-32 workers)
%%   └── ersub_moderation_cache (gen_server, SHA256 去重缓存)

-record(moderation_config, {
    mode            :: off | observe | pre_block,
    api_base_url    :: binary(),
    model           :: binary(),           % "omni-moderation-latest"
    timeout_ms      :: integer(),          % 默认 3000，最大 30000
    sample_rate     :: float(),            % 0.0-1.0，哈希确定性采样
    max_input_runes :: integer(),          % 12000
    %% 13 类风险阈值
    thresholds      :: #{atom() => float()},  % harassment => 0.7, hate => 0.8, ...
    %% 自动封号
    auto_ban_enabled     :: boolean(),
    auto_ban_threshold   :: integer(),     % 违规次数
    auto_ban_window_s    :: integer(),     % 时间窗口
    %% 日志保留
    flagged_retention_days    :: integer(),  % 180
    non_flagged_retention_days :: integer()  % 3
}).
```

**工作流程：**

```
请求 → SHA256(内容)
         │
         ├─ 命中去重缓存 → 直接使用缓存结果
         │
         └─ 未命中 → 采样率检查
              │
              ├─ pre_block 模式 → 同步调用 Moderation API
              │   ├─ 通过 → 继续请求
              │   └─ 违规 → 429 拒绝 + 记录 + 封号检查
              │
              └─ observe 模式 → 异步提交到 worker pool
                  └─ worker 调用 Moderation API → 记录结果
```

**CLIPS 审核规则（扩展点）：**

```clips
;; 可通过 CLIPS 规则自定义审核策略
(deftemplate moderation-result
    (slot request-id (type STRING))
    (slot category (type SYMBOL))
    (slot score (type FLOAT))
    (slot threshold (type FLOAT))
)

(defrule escalate-high-risk
    (moderation-result (category ?cat) (score ?s) (threshold ?th))
    (test (> ?s ?th))
    =>
    (assert (moderation-action (action block) (category ?cat) (score ?s)))
)
```

### 4.8 Channel 系统与模型映射

**Channel 概念：** 连接 Group 与上游服务端点的配置层，承载定价覆盖和模型映射。

```erlang
-record(channel, {
    id              :: integer(),
    name            :: binary(),
    group_id        :: integer(),
    platform        :: claude | openai | gemini | antigravity,
    base_url        :: binary(),             % 上游端点
    %% 模型映射（三级链第一层）
    model_mapping   :: #{binary() => binary()},  % "gpt-4" => "gpt-4-turbo"
    %% 定价覆盖
    pricing_override :: #{binary() => pricing_entry()},  % per-model
    %% 模型限制
    allowed_models  :: [binary()] | all,
    is_active       :: boolean()
}).
```

**三级模型映射链：**

```
客户端请求 model="gpt-4"
    │
    ├─ Level 1: Channel 映射
    │   channel.model_mapping: "gpt-4" → "gpt-4-turbo"
    │
    ├─ Level 2: Account 映射
    │   account.credentials.model_mapping: "gpt-4-turbo" → "gpt-4-turbo-2025"
    │
    └─ Level 3: Group 默认模型
        group.default_model (fallback)

映射链记录: "gpt-4→gpt-4-turbo→gpt-4-turbo-2025"
计费模型来源: billing_model_source = channel_mapped | upstream | original
```

**通配符匹配：**

```erlang
%% 支持前缀通配符 "gpt-*" 匹配 "gpt-4", "gpt-4-turbo" 等
resolve_model_mapping(Model, Mapping) ->
    case maps:get(Model, Mapping, undefined) of
        undefined ->
            %% 尝试通配符匹配
            match_wildcard(Model, maps:to_list(Mapping));
        Target ->
            Target
    end.

match_wildcard(Model, [{Pattern, Target} | Rest]) ->
    case binary:match(Pattern, <<"*">>) of
        {Pos, 1} ->
            Prefix = binary:part(Pattern, 0, Pos),
            case binary:match(Model, Prefix) of
                {0, _} -> Target;
                _ -> match_wildcard(Model, Rest)
            end;
        nomatch ->
            match_wildcard(Model, Rest)
    end;
match_wildcard(_, []) ->
    undefined.
```

**Channel 定价缓存（ETS 热路径）：**

```erlang
%% 复合 key 防止跨平台名称冲突
%% Key: {GroupId, Platform, Model}
%% Value: pricing_entry()
ets:insert(ersub_channel_pricing, {{GroupId, Platform, Model}, PricingEntry}).

%% 通配符定价 fallback
lookup_pricing(GroupId, Platform, Model) ->
    case ets:lookup(ersub_channel_pricing, {GroupId, Platform, Model}) of
        [{_, Entry}] -> {ok, Entry};
        [] -> lookup_wildcard_pricing(GroupId, Platform, Model)
    end.
```

### 4.9 错误透传规则引擎

```erlang
-record(error_passthrough_rule, {
    id          :: integer(),
    name        :: binary(),
    %% 匹配条件
    status_codes :: [integer()],         % [429, 503]
    keywords     :: [binary()],          % [<<"rate_limit">>, <<"overloaded">>]
    platform     :: atom() | any,        % openai | any
    %% 匹配范围
    body_check_limit :: integer(),       % 只检查前 8KB
    %% 行为
    action      :: passthrough | custom,
    custom_body :: map() | undefined
}).
```

**CLIPS 错误透传规则：**

```clips
(deftemplate upstream-error
    (slot request-id (type STRING))
    (slot status-code (type INTEGER))
    (slot platform (type SYMBOL))
    (slot body-excerpt (type STRING))  ;; 前 8KB
)

(deftemplate passthrough-rule
    (slot rule-id (type INTEGER))
    (multislot status-codes (type INTEGER))
    (multislot keywords (type STRING))
    (slot platform (type SYMBOL))      ;; openai | any
    (slot action (type SYMBOL))        ;; passthrough | custom
)

(defrule match-passthrough
    (upstream-error (request-id ?rid) (status-code ?sc)
                    (platform ?plat) (body-excerpt ?body))
    (passthrough-rule (rule-id ?rule) (status-codes $?codes)
                      (keywords $?kws) (platform ?rplat) (action ?act))
    (test (or (eq ?rplat any) (eq ?rplat ?plat)))
    (test (member$ ?sc $?codes))
    =>
    (assert (error-action (request-id ?rid) (action ?act) (rule-id ?rule)))
)
```

### 4.10 OAuth Token 刷新服务

```erlang
%% ersub_token_refresh_srv (gen_server)
%% 纳入 supervision tree: ersub_platform_sup 下

-record(refresh_state, {
    refresh_timers :: #{AccountId => reference()},
    cooldowns      :: #{AccountId => integer()}   % temp_unschedulable 到期时间
}).
```

**刷新流程：**

```
                    ┌─ 定时触发（token_expires 前 5 分钟）
                    │
                    ├─ 401/403 响应触发（请求级别）
                    │
                    ▼
        ersub_token_refresh_srv
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   Claude       OpenAI      Gemini
   Refresher    Refresher   Refresher
        │           │           │
        ▼           ▼           ▼
   OAuth2 Token Exchange
        │
        ├─ 成功 → 更新 account_srv state
        │         更新 ETS 调度缓存
        │         可选：执行 training opt-out（OpenAI）
        │
        └─ 失败 → 重试（指数退避，max 3 次）
                   全部失败 → 标记 temp_unschedulable（10min cooldown）
                   通知 account_srv 更新状态
```

```erlang
%% 平台特定刷新器 behaviour
-callback refresh_token(AccountId :: integer(), Credentials :: map()) ->
    {ok, NewCredentials :: map()} | {error, Reason :: term()}.

%% Claude refresher
-module(ersub_claude_refresher).
-behaviour(ersub_token_refresher).

refresh_token(AccountId, #{<<"refresh_token">> := RefreshToken} = Creds) ->
    case ersub_http:post(<<"https://console.anthropic.com/v1/oauth/token">>,
                         #{grant_type => <<"refresh_token">>,
                           refresh_token => RefreshToken}) of
        {ok, 200, #{<<"access_token">> := NewToken, <<"expires_in">> := ExpiresIn}} ->
            {ok, Creds#{<<"access_token">> => NewToken,
                        <<"token_expires">> => now_s() + ExpiresIn}};
        {ok, Status, Body} ->
            {error, {http, Status, Body}};
        {error, Reason} ->
            {error, Reason}
    end.
```

### 4.11 连接池管理

**三种隔离策略：**

```erlang
%% 连接池隔离模式
-type pool_isolation() :: proxy | account | account_proxy.

%% account_proxy（默认，最精细）：每个 {AccountId, ProxyEndpoint} 独立连接池
%% account：每个 AccountId 独立连接池
%% proxy：每个 ProxyEndpoint 共享连接池
```

```erlang
%% ersub_upstream_pool (gen_server)
%% 管理 gun 连接池，LRU + idle-time 双驱逐

-record(pool_state, {
    isolation    :: pool_isolation(),
    pools        :: #{pool_key() => pool_entry()},
    max_pools    :: integer(),          % 5000
    idle_ttl_ms  :: integer(),          % 15 分钟
    lru_queue    :: queue:queue()       % 最近使用排序
}).

-record(pool_entry, {
    conn_pid     :: pid(),             % gun connection 进程
    in_flight    :: integer(),         % 活跃请求数，>0 时不驱逐
    last_used    :: integer(),         % 最后使用时间
    max_idle     :: integer(),         % 240（HTTP/2 多路复用优化）
    max_per_host :: integer(),         % 120 idle, 240 total
    idle_timeout :: integer()          % 90s (< upstream LB timeout)
}).

%% 获取连接（自动建立或复用）
get_connection(AccountId, UpstreamUrl, ProxyConfig) ->
    PoolKey = make_pool_key(AccountId, UpstreamUrl, ProxyConfig),
    case ets:lookup(ersub_conn_pools, PoolKey) of
        [{_, #pool_entry{conn_pid = Pid} = Entry}] ->
            %% 增加 in_flight，更新 LRU
            {ok, Pid};
        [] ->
            %% 新建连接
            open_new_connection(PoolKey, UpstreamUrl, ProxyConfig)
    end.
```

**gun 连接配置（对标 sub2api 的 http_upstream）：**

```erlang
gun_opts() ->
    #{
        protocols => [http2, http],       % 优先 HTTP/2
        http2_opts => #{
            max_concurrent_streams => 50, % H2C max concurrent streams
            idle_timeout => 75000
        },
        connect_timeout => 10000,
        %% 响应头超时 5 分钟（LLM 排队延迟）
        response_timeout => 300000,
        supervise => false                % 由 pool 管理生命周期
    }.
```

### 4.12 RPM 限速

**替代 Redis Lua 脚本的 BEAM 方案：**

```erlang
%% ersub_rate_limiter (gen_server)
%% 滑动窗口限速，ETS 实现

-record(rate_state, {
    %% ETS table: ersub_rate_windows
    %% Key: {user | api_key | group, Id}
    %% Value: {[Timestamp], WindowMs}
    fail_mode :: fail_open | fail_close  % ETS 异常时的行为
}).

check_rpm(Type, Id, Limit) ->
    Now = erlang:monotonic_time(millisecond),
    WindowMs = 60_000,  % 1 分钟窗口
    Key = {Type, Id},
    case ets:lookup(ersub_rate_windows, Key) of
        [{_, Timestamps}] ->
            %% 清理过期时间戳
            Active = [T || T <- Timestamps, Now - T < WindowMs],
            case length(Active) >= Limit of
                true -> {error, rate_limited};
                false ->
                    ets:insert(ersub_rate_windows, {Key, [Now | Active]}),
                    ok
            end;
        [] ->
            ets:insert(ersub_rate_windows, {Key, [Now]}),
            ok
    end.
```

**五小时滑动窗口（长期趋势限制）：**

```erlang
%% 独立于 RPM 的五小时窗口，用于检测异常使用模式
check_5h_window(ApiKeyId, Limit5h) ->
    FiveHoursAgo = calendar:universal_time() - 18000,
    Count = ersub_repo:count_usage_since(ApiKeyId, FiveHoursAgo),
    Count < Limit5h.
```

### 4.13 IP 黑白名单

```erlang
%% 支持 CIDR 表示法
%% ip_whitelist: ["10.0.0.0/8", "192.168.1.100"]
%% ip_blacklist: ["0.0.0.0/0"]  (黑名单优先于白名单)

-spec check_ip_access(ClientIP :: inet:ip_address(),
                      Whitelist :: [binary()],
                      Blacklist :: [binary()]) ->
    allow | deny.

check_ip_access(ClientIP, Whitelist, Blacklist) ->
    case match_cidr_list(ClientIP, Blacklist) of
        true -> deny;                         % 黑名单优先
        false ->
            case Whitelist of
                [] -> allow;                  % 无白名单 = 全部放行
                _ ->
                    case match_cidr_list(ClientIP, Whitelist) of
                        true -> allow;
                        false -> deny
                    end
            end
    end.

match_cidr_list(IP, CIDRList) ->
    lists:any(fun(CIDR) -> ip_in_cidr(IP, parse_cidr(CIDR)) end, CIDRList).
```

### 4.14 URL 安全校验（SSRF 防护）

```erlang
%% ersub_url_validator

-spec validate_upstream_url(URL :: binary()) ->
    ok | {error, Reason :: atom()}.

validate_upstream_url(URL) ->
    {Scheme, Host, Port, _Path} = parse_url(URL),
    %% 1. Scheme 检查
    case Scheme of
        <<"https">> -> ok;
        <<"http">> ->
            case get_config(allow_http_upstream) of
                true -> ok;
                false -> {error, https_required}
            end;
        _ -> {error, invalid_scheme}
    end,
    %% 2. 主机白名单
    case check_host_allowlist(Host) of
        ok -> ok;
        deny -> {error, host_not_allowed}
    end,
    %% 3. 私有 IP 阻断
    case resolve_and_check(Host) of
        {ok, IP} ->
            case is_private_ip(IP) of
                true -> {error, private_ip_blocked};
                false -> ok
            end;
        {error, _} = Err -> Err
    end.

%% DNS Rebinding 防护：请求时二次校验
-spec validate_resolved_ip(inet:ip_address()) -> ok | {error, atom()}.
validate_resolved_ip(IP) ->
    case is_private_ip(IP) orelse is_loopback(IP) orelse
         is_link_local(IP) orelse is_multicast(IP) of
        true -> {error, dns_rebinding_blocked};
        false -> ok
    end.

is_private_ip({10, _, _, _}) -> true;
is_private_ip({172, B, _, _}) when B >= 16, B =< 31 -> true;
is_private_ip({192, 168, _, _}) -> true;
is_private_ip(_) -> false.
```

### 4.15 Claude Code 客户端检测

```erlang
%% ersub_client_detector

-spec detect_client(Headers :: map(), Body :: map()) ->
    {claude_code, Version :: binary()} | {official, Type :: atom()} | unknown.

detect_client(Headers, Body) ->
    UA = maps:get(<<"user-agent">>, Headers, <<>>),
    %% 1. Claude CLI 检测: "claude-cli/X.Y.Z" (case-insensitive)
    case re:run(UA, <<"(?i)claude-cli/([0-9]+\\.[0-9]+\\.[0-9]+)">>,
                [{capture, [1], binary}]) of
        {match, [Version]} ->
            {claude_code, Version};
        nomatch ->
            %% 2. Metadata 检测
            case maps:get(<<"metadata">>, Body, undefined) of
                #{<<"originator">> := <<"claude-code">>} ->
                    {claude_code, <<"unknown">>};
                _ ->
                    %% 3. OpenAI 官方客户端白名单
                    check_official_client(Headers)
            end
    end.

%% claude_code_only 分组限制
enforce_client_restriction(Group, ClientType) ->
    case Group#group.claude_code_only of
        false -> ok;
        true ->
            case ClientType of
                {claude_code, _} -> ok;
                {official, _} -> ok;        % 官方客户端放行
                unknown -> {error, codex_cli_only}
            end
    end.
```

### 4.16 安全响应头与 CORS

**安全响应头中间件：**

```erlang
%% ersub_security_middleware

security_headers(Req) ->
    Nonce = base64:encode(crypto:strong_rand_bytes(16)),
    CSP = iolist_to_binary([
        <<"default-src 'self'; ">>,
        <<"script-src 'self' 'nonce-">>, Nonce, <<"' https://challenges.cloudflare.com; ">>,
        <<"style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; ">>,
        <<"img-src 'self' data: https:; ">>,
        <<"font-src 'self' data:; ">>,
        <<"frame-src https://challenges.cloudflare.com https://*.stripe.com; ">>,
        <<"frame-ancestors 'none'; ">>,
        <<"form-action 'self'; ">>,
        <<"base-uri 'self'">>
    ]),
    cowboy_req:set_resp_headers(#{
        <<"content-security-policy">> => CSP,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"x-frame-options">> => <<"DENY">>,
        <<"x-xss-protection">> => <<"1; mode=block">>,
        <<"referrer-policy">> => <<"strict-origin-when-cross-origin">>,
        <<"x-csp-nonce">> => Nonce
    }, Req).
```

**CORS 中间件：**

```erlang
%% ersub_cors_middleware

cors_headers(Req, Config) ->
    Origin = cowboy_req:header(<<"origin">>, Req, <<>>),
    case is_allowed_origin(Origin, Config#cors.allowed_origins) of
        true ->
            cowboy_req:set_resp_headers(#{
                <<"access-control-allow-origin">> => Origin,
                <<"access-control-allow-methods">> => <<"GET, POST, PUT, DELETE, OPTIONS">>,
                <<"access-control-allow-headers">> => <<"Content-Type, Authorization, x-api-key">>,
                <<"access-control-max-age">> => <<"86400">>,
                <<"access-control-allow-credentials">> => <<"true">>
            }, Req);
        false ->
            Req  % 不设置 CORS header
    end.

%% OPTIONS 预检请求短路
handle_preflight(Req) ->
    {ok, cors_headers(Req, get_cors_config()), <<>>}.
```

### 4.17 公告系统

```erlang
%% 公告管理（轻量，无需独立 gen_server）
%% 通过 ersub_admin_handler 提供 CRUD

-record(announcement, {
    id          :: integer(),
    title       :: binary(),
    content     :: binary(),
    notify_mode :: banner | modal | silent,
    sort_order  :: integer(),
    is_active   :: boolean(),
    created_at  :: calendar:datetime(),
    updated_at  :: calendar:datetime()
}).

%% API 端点
%% GET  /api/announcements          — 用户获取活跃公告
%% POST /api/announcements/:id/read — 标记已读
%% POST /api/admin/announcements    — 管理员创建/编辑
```

### 4.18 可观测性系统

```erlang
%% ersub_ops_sup (one_for_one)
%%   ├── ersub_health_srv (gen_server)
%%   ├── ersub_metrics_srv (gen_server, 指标聚合)
%%   └── ersub_usage_cleanup_srv (gen_server, 定时清理)

-record(health_score, {
    overall     :: 0..100,
    components  :: #{
        database    => healthy | degraded | down,
        clips_pool  => healthy | degraded | down,
        upstream    => #{Platform => healthy | degraded | down}
    },
    %% 计算因子
    error_rate_1m  :: float(),
    avg_latency_ms :: float(),
    active_accounts :: integer(),
    quota_available :: float()    % 0.0-1.0
}).
```

**结构化日志（slog 风格）：**

```erlang
%% 使用 logger（OTP 内置），结构化格式
logger:info(#{
    event => request_completed,
    request_id => ReqId,
    user_id => UserId,
    account_id => AccountId,
    model => Model,
    duration_ms => Duration,
    tokens => #{input => InputTokens, output => OutputTokens},
    cost_usd => ActualCost
}).

%% 配置：JSON 格式输出（生产环境）
%% logger:set_handler_config(default, formatter,
%%     {logger_formatter, #{template => [msg], single_line => true}}).
```

**指标聚合（替代 Ops 仪表板）：**

```erlang
%% ersub_metrics_srv 定时聚合并写入 metrics 表
%% 聚合维度：per-model、per-account、per-user、per-group
%% 聚合粒度：1min / 5min / 1hour / 1day

-record(metric_bucket, {
    dimension    :: {model | account | user | group, term()},
    window       :: {calendar:datetime(), calendar:datetime()},
    request_count :: integer(),
    error_count   :: integer(),
    total_tokens  :: integer(),
    total_cost    :: float(),
    avg_ttft_ms   :: float(),
    p99_latency_ms :: float()
}).
```

**使用记录自动清理：**

```erlang
%% ersub_usage_cleanup_srv
%% 按保留策略清理旧记录

init(_) ->
    schedule_cleanup(),
    {ok, #{retention_days => 90}}.

handle_info(cleanup, #{retention_days := Days} = State) ->
    Cutoff = calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(calendar:universal_time()) - Days * 86400),
    {ok, Deleted} = ersub_repo:delete_usage_logs_before(Cutoff),
    logger:info(#{event => usage_cleanup, deleted => Deleted, cutoff => Cutoff}),
    schedule_cleanup(),
    {noreply, State}.

schedule_cleanup() ->
    %% 每天凌晨 3 点执行
    erlang:send_after(ms_until_3am(), self(), cleanup).
```

### 4.19 Setup Wizard（首次运行向导）

```erlang
%% ersub_setup
%% 首次运行时交互式配置

-spec check_and_run_setup(DataDir :: string()) -> ok | {error, term()}.

check_and_run_setup(DataDir) ->
    LockFile = filename:join(DataDir, ".installed"),
    case filelib:is_file(LockFile) of
        true ->
            ok;  % 已安装，跳过
        false ->
            %% 数据目录检测优先级:
            %% 1. DATA_DIR 环境变量
            %% 2. /app/data (Docker)
            %% 3. 当前目录
            run_interactive_setup(DataDir),
            file:write_file(LockFile, <<"installed">>)
    end.
```

**向导步骤：**

```
1. 数据库连接配置 → 测试连接 → 执行 migration
2. 管理员账户创建 → 生成 JWT
3. 服务器配置（端口、并发数、运行模式 standard/simple）
4. 生成 config/ersub.yaml
5. 写入 .installed 锁文件
```

### 4.20 定价表管理

```erlang
%% ersub_pricing (gen_server)

-record(pricing_state, {
    %% 全量定价表缓存
    pricing_table :: #{ModelName => model_pricing()},
    %% 内嵌 fallback（编译时打包）
    embedded_fallback :: #{ModelName => model_pricing()},
    %% 更新定时器
    update_timer :: reference()
}).

-record(model_pricing, {
    model                     :: binary(),
    input_price               :: float(),
    output_price              :: float(),
    cache_read_price          :: float(),
    cache_creation_price      :: float(),
    cache_5m_price            :: float(),
    cache_1h_price            :: float(),
    image_output_price        :: float(),
    %% 长上下文
    long_ctx_threshold        :: integer(),    % e.g., 272000
    long_ctx_input_mult       :: float(),      % 2.0
    long_ctx_output_mult      :: float(),      % 1.5
    %% 能力标记
    supports_prompt_caching   :: boolean(),
    supports_vision           :: boolean(),
    %% 图片生成分级定价
    image_prices              :: #{binary() => float()}  % "1K" => 0.02, "2K" => 0.04, ...
}).
```

**更新流程：**

```erlang
%% 定时从 LiteLLM 格式 JSON 更新
update_pricing() ->
    case fetch_pricing_json(get_config(pricing_update_url)) of
        {ok, Json} ->
            NewTable = parse_litellm_pricing(Json),
            persistent_term:put({ersub_config, pricing_table}, NewTable),
            logger:info(#{event => pricing_updated, models => maps:size(NewTable)});
        {error, _} ->
            %% 使用内嵌 fallback
            logger:warning(#{event => pricing_update_failed, using => embedded_fallback})
    end.

%% 硬编码 fallback（关键模型）
embedded_fallback() ->
    #{
        <<"claude-sonnet-4-20250514">> => #model_pricing{...},
        <<"gpt-4o">> => #model_pricing{...},
        <<"gemini-2.5-pro">> => #model_pricing{...}
    }.
```

### 4.21 WebSocket v2 详细设计（OpenAI Responses）

```erlang
%% ersub_openai_ws_handler
%% 基于 cowboy_websocket behaviour

-behaviour(cowboy_websocket).

-record(ws_state, {
    user_id        :: integer(),
    account_id     :: integer(),
    upstream_ws    :: pid(),           % gun websocket 连接
    stream_ref     :: reference(),
    protocol       :: v1 | v2,        % 协议版本自动检测
    session_id     :: binary(),       % ingress session 跟踪
    metrics        :: #{
        frames_in   => integer(),
        frames_out  => integer(),
        start_time  => integer(),
        errors      => integer()
    }
}).

%% 双向帧级中继
websocket_handle({text, Frame}, State) ->
    %% 客户端 → 上游
    gun:ws_send(State#ws_state.upstream_ws,
                State#ws_state.stream_ref,
                {text, Frame}),
    NewMetrics = maps:update_with(frames_in, fun(V) -> V + 1 end,
                                  State#ws_state.metrics),
    {ok, State#ws_state{metrics = NewMetrics}};

websocket_info({gun_ws, _, _, {text, Frame}}, State) ->
    %% 上游 → 客户端
    %% 检查 RateLimit 信号
    State2 = maybe_handle_rate_limit(Frame, State),
    NewMetrics = maps:update_with(frames_out, fun(V) -> V + 1 end,
                                  State2#ws_state.metrics),
    {[{text, Frame}], State2#ws_state{metrics = NewMetrics}};

websocket_info({gun_ws, _, _, close}, State) ->
    %% 上游关闭 → 关闭客户端连接
    record_ws_metrics(State),
    {[close], State}.
```

**连接池（per-account）：**

```erlang
%% 每账户最大 128 个 WebSocket 连接
%% 空闲连接 4-12 个保持热备
-record(ws_pool_config, {
    max_conns_per_account :: integer(),    % 128
    min_idle              :: integer(),    % 4
    max_idle              :: integer(),    % 12
    idle_timeout_ms       :: integer()     % 300000 (5min)
}).
```

### 4.22 软删除

```erlang
%% 软删除 mixin（应用于 user_subscriptions, users, api_keys）
%% PostgreSQL 实现

%% 建表时添加 deleted_at 字段
%% deleted_at TIMESTAMPTZ DEFAULT NULL

%% partial unique index 支持重新注册
%% CREATE UNIQUE INDEX idx_users_email_active ON users(email) WHERE deleted_at IS NULL;
%% CREATE UNIQUE INDEX idx_api_keys_hash_active ON api_keys(key_hash) WHERE deleted_at IS NULL;
```

```erlang
%% 数据访问层自动过滤
soft_delete(Table, Id) ->
    ersub_repo:query(
        "UPDATE ~s SET deleted_at = NOW(), updated_at = NOW() WHERE id = $1",
        [Table, Id]).

%% 所有查询默认排除已删除记录
find_active(Table, Conditions) ->
    ersub_repo:query(
        "SELECT * FROM ~s WHERE deleted_at IS NULL AND ~s",
        [Table, build_where(Conditions)]).
```

### 4.23 分销返佣系统（Affiliate）

```erlang
%% ersub_affiliate_srv (gen_server)

-record(affiliate, {
    user_id        :: integer(),
    aff_code       :: binary(),         % 唯一推广码
    inviter_id     :: integer(),        % 上级邀请人
    rebate_rate    :: float(),          % 返佣比例 0.0-1.0
    aff_quota      :: float(),          % 当前累计返佣额度
    aff_history    :: float(),          % 历史总返佣
    is_frozen      :: boolean(),        % 返佣冻结
    custom_settings :: map()            % 自定义返佣规则
}).
```

**返佣流程：**
```
用户 B 通过 aff_code 注册 → 关联 inviter_id = A
    │
    B 使用 API 产生费用 $X
    │
    ├─ 计费完成后 → ersub_affiliate_srv:accrue(B, Cost)
    │   计算 rebate = Cost × A.rebate_rate
    │   写入 affiliate_ledger (action=accrue)
    │   增加 A.aff_quota
    │
    └─ A 提取返佣 → ersub_affiliate_srv:transfer(A, Amount)
        从 aff_quota 转入 A.balance_usd
        写入 affiliate_ledger (action=transfer)
```

### 4.24 兑换码与促销码

```erlang
%% 兑换码（Redeem Code）
-record(redeem_code, {
    id          :: integer(),
    code        :: binary(),          % 唯一兑换码
    amount_usd  :: float(),           % 充值金额
    is_used     :: boolean(),
    used_by     :: integer() | undefined,
    used_at     :: calendar:datetime() | undefined,
    notes       :: binary(),
    created_at  :: calendar:datetime()
}).

%% 促销码（Promo Code）
-record(promo_code, {
    id              :: integer(),
    code            :: binary(),
    discount_type   :: percentage | fixed,
    discount_value  :: float(),
    max_uses        :: integer(),
    current_uses    :: integer(),
    valid_from      :: calendar:datetime(),
    valid_until     :: calendar:datetime(),
    is_active       :: boolean()
}).
```

### 4.25 代理管理与 TLS 指纹

```erlang
%% ersub_proxy_srv (gen_server)
%% 管理上游代理配置 + 延迟探测

-record(proxy, {
    id           :: integer(),
    name         :: binary(),
    protocol     :: http | https | socks5,
    host         :: binary(),
    port         :: integer(),
    auth         :: {binary(), binary()} | undefined,  % user:pass
    is_active    :: boolean(),
    %% 延迟探测
    last_probe_ms   :: integer() | undefined,
    probe_interval  :: integer()     % ms
}).

%% TLS 指纹伪装配置
-record(tls_fingerprint_profile, {
    id          :: integer(),
    name        :: binary(),
    ja3_hash    :: binary(),         % JA3 指纹
    user_agent  :: binary(),
    headers     :: [{binary(), binary()}],
    is_active   :: boolean()
}).
```

### 4.26 定时健康检测（Scheduled Test）

```erlang
%% ersub_scheduled_test_srv (gen_server)
%% 定期发送测试请求，验证账户/模型可用性

-record(scheduled_test, {
    id              :: integer(),
    name            :: binary(),
    account_id      :: integer(),
    model           :: binary(),
    test_prompt     :: binary(),
    interval_s      :: integer(),       % 检测间隔
    timeout_ms      :: integer(),
    auto_recover    :: boolean(),       % 失败时自动标记账户不可调度
    last_result     :: pass | fail | undefined,
    last_run_at     :: calendar:datetime() | undefined
}).
```

**自动恢复：** 检测失败 → 标记 `temp_unschedulable`；检测恢复 → 标记 `active`。

### 4.27 Channel 监控系统

独立于 Channel 配置的监控子系统：

```erlang
%% ersub_channel_monitor_sup (one_for_one)
%%   ├── ersub_channel_monitor_runner (gen_server, 定时触发)
%%   ├── ersub_channel_monitor_checker (gen_server, 执行检查)
%%   └── ersub_channel_monitor_aggregator (gen_server, 日聚合)

-record(channel_monitor, {
    id                :: integer(),
    channel_id        :: integer(),
    check_interval_s  :: integer(),
    request_template  :: map(),        % 复用的请求模板
    expected_status   :: integer(),
    timeout_ms        :: integer(),
    is_active         :: boolean()
}).

%% 检查历史 → 日聚合 → 可视化
%% channel_monitor_histories → channel_monitor_daily_rollups
```

### 4.28 余额通知

```erlang
%% 用户余额低于阈值时发送邮件通知
%% 扩展 users 表字段

-record(balance_notify_config, {
    enabled        :: boolean(),
    threshold      :: float(),
    threshold_type :: percentage | fixed,  % 百分比 vs 固定金额
    notify_emails  :: [binary()]           % 通知邮箱列表
}).
```

在每次计费扣款后检查：余额 < threshold → 发送邮件（去重，每天最多一封）。

### 4.29 用户消息队列模式

```erlang
%% 针对高并发用户的请求排队策略

-type msg_queue_mode() :: none | serialize | throttle.

%% serialize: 同一用户的请求严格串行化（前一个完成才处理下一个）
%% throttle: 限制并发但允许一定并行度
%% 在账户级别配置: account.user_msg_queue_mode
```

### 4.30 后端只读模式（Backend Mode Guard）

```erlang
%% 灾备模式：仅允许读操作，拒绝所有写入
%% 通过 settings 表中 backend_mode 键控制

-spec check_backend_mode(Method :: binary()) -> ok | {error, read_only}.
check_backend_mode(<<"GET">>) -> ok;
check_backend_mode(<<"HEAD">>) -> ok;
check_backend_mode(<<"OPTIONS">>) -> ok;
check_backend_mode(_) ->
    case get_config(backend_mode) of
        <<"read_only">> -> {error, read_only};
        _ -> ok
    end.
```

### 4.31 自定义页面系统

```erlang
%% 从 data/pages/{slug}/ 目录提供 Markdown 页面
%% 支持图片资源、可见性控制

%% API 端点
%% GET /pages/:slug          — 渲染 Markdown 页面
%% GET /pages/:slug/images/* — 页面图片资源

%% 可见性通过 settings 表中 custom_menu_items 配置
%% Slug 校验防止路径遍历，内容大小限制 1MB
```

### 4.32 使用计费去重

```erlang
%% 防止重试/重放导致的重复计费
%% usage_billing_dedup 表：request_id → 已计费标记
%% 定期归档到 usage_billing_dedup_archive

deduct_with_dedup(RequestId, UserId, Cost) ->
    case ersub_repo:check_billing_dedup(RequestId) of
        already_billed -> {ok, skipped};
        not_found ->
            ersub_repo:insert_billing_dedup(RequestId),
            deduct(UserId, Cost)
    end.
```

### 4.33 Ops 告警系统

```erlang
%% ersub_ops_alert_srv (gen_server)
%% 基于规则的运维告警 + 静默策略

-record(ops_alert_rule, {
    id          :: integer(),
    name        :: binary(),
    condition   :: map(),          % 触发条件（error_rate > X, latency > Y）
    severity    :: critical | warning | info,
    notify      :: [email | webhook],
    cooldown_s  :: integer()       % 告警冷却
}).

-record(ops_alert_silence, {
    id          :: integer(),
    rule_id     :: integer(),
    until       :: calendar:datetime(),
    reason      :: binary()
}).
```

### 4.34 数据备份系统

```erlang
%% ersub_backup_srv (gen_server)
%% S3 备份 + PostgreSQL dump + 定时任务

-record(backup_config, {
    s3_profiles :: [s3_profile()],     % 支持多个 S3 存储桶
    schedule    :: binary(),           % cron 表达式
    retention   :: integer(),          % 保留天数
    source      :: postgresql | full   % 备份范围
}).

-record(s3_profile, {
    name        :: binary(),
    endpoint    :: binary(),
    bucket      :: binary(),
    access_key  :: binary(),
    secret_key  :: binary(),
    region      :: binary()
}).
```

### 4.35 账户批量导入

```erlang
%% 支持从 Codex 格式批量导入账户
%% POST /api/admin/accounts/import

%% 导入格式：JSON 数组
%% [{platform, account_type, credentials, priority, ...}, ...]
%% 校验 → 去重 → 批量插入 → 返回成功/失败统计
```

---

## 5. 数据层设计

### 5.1 存储分层

| 数据类别 | 存储 | 理由 |
|---------|------|------|
| 用户、账户、API Key、分组 | PostgreSQL | 持久化，ACID，关系查询 |
| 使用日志、支付记录 | PostgreSQL | 持久化，审计，聚合查询 |
| 配置/设置 | PostgreSQL + `persistent_term` | 持久化 + 热读 |
| 并发计数 | `counters` (BEAM 内置) | 高性能原子操作 |
| 会话粘滞缓存 | ETS (set, TTL 过期) | 内存高速，进程隔离 |
| 用户余额缓存 | ETS + PostgreSQL 定期同步 | 热路径性能 |
| 账户运行时状态 | 每账户 gen_server state | 天然隔离，EWMA 统计 |
| 临时请求上下文 | 进程字典 / 进程 state | 请求结束即销毁 |

### 5.2 数据库 Schema（PostgreSQL）

核心表与 sub2api 保持兼容：

```sql
-- 用户
CREATE TABLE users (
    id              BIGSERIAL PRIMARY KEY,
    email           TEXT UNIQUE NOT NULL,
    password_hash   TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'user',  -- user | admin
    balance_usd     NUMERIC(12,6) NOT NULL DEFAULT 0,
    max_concurrency INTEGER NOT NULL DEFAULT 5,
    totp_secret     TEXT,
    totp_enabled    BOOLEAN NOT NULL DEFAULT FALSE,
    rpm_limit       INTEGER,                         -- 用户级 RPM 限制
    is_banned       BOOLEAN NOT NULL DEFAULT FALSE,  -- 自动封号标记
    ban_reason      TEXT,
    -- 余额通知
    balance_notify_enabled    BOOLEAN NOT NULL DEFAULT FALSE,
    balance_notify_threshold  NUMERIC(12,6),
    balance_notify_type       TEXT,                  -- percentage | fixed
    notify_emails             JSONB,                 -- ["a@b.com", ...]
    deleted_at      TIMESTAMPTZ,                     -- 软删除
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_users_email_active ON users(email) WHERE deleted_at IS NULL;

-- 上游账户
CREATE TABLE accounts (
    id                  BIGSERIAL PRIMARY KEY,
    name                TEXT NOT NULL,
    platform            TEXT NOT NULL,  -- claude | openai | gemini | antigravity
    account_type        TEXT NOT NULL,  -- oauth | setup_token | api_key | upstream | bedrock
    credentials         JSONB NOT NULL, -- 加密存储
    status              TEXT NOT NULL DEFAULT 'active',
    priority            INTEGER NOT NULL DEFAULT 100,
    concurrency         INTEGER NOT NULL DEFAULT 5,
    load_factor         INTEGER,
    rate_multiplier     NUMERIC(8,4),
    schedulable         BOOLEAN NOT NULL DEFAULT TRUE,
    error_message       TEXT,
    rate_limited_until  TIMESTAMPTZ,
    overload_until      TIMESTAMPTZ,
    base_url            TEXT,                -- 自定义上游 API 端点
    notes               TEXT,                -- 管理员备注
    expires_at          TIMESTAMPTZ,         -- 账户到期时间
    user_msg_queue_mode TEXT,                -- serialize | throttle | null
    last_used_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- API Keys
CREATE TABLE api_keys (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),
    key_hash        TEXT UNIQUE NOT NULL,
    key_prefix      TEXT NOT NULL,           -- 前 8 位，用于展示
    name            TEXT,
    max_concurrency INTEGER,
    rpm_limit       INTEGER,
    rate_limit_5h   INTEGER,                 -- 五小时滑动窗口限额
    ip_whitelist    JSONB,                   -- CIDR 表示法 ["10.0.0.0/8"]
    ip_blacklist    JSONB,                   -- 黑名单优先于白名单
    allowed_models  TEXT[],
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    expires_at      TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,             -- 软删除
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_api_keys_hash_active ON api_keys(key_hash) WHERE deleted_at IS NULL;

-- 分组
CREATE TABLE groups (
    id                      BIGSERIAL PRIMARY KEY,
    name                    TEXT NOT NULL,
    platform                TEXT NOT NULL,
    billing_type            SMALLINT NOT NULL DEFAULT 0,  -- 0=balance, 1=subscription
    rate_multiplier         NUMERIC(8,4) NOT NULL DEFAULT 1.0,
    daily_limit_usd         NUMERIC(12,6),
    weekly_limit_usd        NUMERIC(12,6),
    monthly_limit_usd       NUMERIC(12,6),
    rpm_limit               INTEGER DEFAULT 0,
    model_routing           JSONB,
    model_routing_enabled   BOOLEAN NOT NULL DEFAULT FALSE,
    claude_code_only        BOOLEAN NOT NULL DEFAULT FALSE,
    fallback_group_id       BIGINT REFERENCES groups(id),
    -- 图片生成
    allow_image_generation  BOOLEAN NOT NULL DEFAULT FALSE,
    image_rate_independent  BOOLEAN NOT NULL DEFAULT FALSE,
    image_rate_multiplier   NUMERIC(8,4) DEFAULT 1.0,
    image_price_1k          NUMERIC(12,6),  -- 1024x1024 单价
    image_price_2k          NUMERIC(12,6),  -- 2048x2048 单价
    image_price_4k          NUMERIC(12,6),  -- 4096x4096 单价
    -- 高级控制
    sort_order              INTEGER DEFAULT 0,
    account_filter          JSONB,                  -- 账户过滤规则
    messages_dispatch       TEXT,                   -- 消息分发模式
    messages_dispatch_model_config JSONB,            -- per-model 分发配置
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 账户-分组关联
CREATE TABLE account_groups (
    account_id  BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    group_id    BIGINT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    PRIMARY KEY (account_id, group_id)
);

-- 用户-分组关联
CREATE TABLE user_allowed_groups (
    user_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    group_id  BIGINT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, group_id)
);

-- 用户订阅
CREATE TABLE user_subscriptions (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id),
    group_id            BIGINT NOT NULL REFERENCES groups(id),
    status              TEXT NOT NULL DEFAULT 'active',
    starts_at           TIMESTAMPTZ NOT NULL,
    expires_at          TIMESTAMPTZ,
    daily_usage_usd     NUMERIC(12,6) NOT NULL DEFAULT 0,
    weekly_usage_usd    NUMERIC(12,6) NOT NULL DEFAULT 0,
    monthly_usage_usd   NUMERIC(12,6) NOT NULL DEFAULT 0,
    daily_window_start  TIMESTAMPTZ,
    weekly_window_start TIMESTAMPTZ,
    monthly_window_start TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 使用日志
CREATE TABLE usage_logs (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             BIGINT NOT NULL,
    api_key_id          BIGINT,
    account_id          BIGINT NOT NULL,
    group_id            BIGINT,
    subscription_id     BIGINT,
    request_id          TEXT NOT NULL,
    requested_model     TEXT NOT NULL,
    upstream_model      TEXT,
    input_tokens        INTEGER NOT NULL DEFAULT 0,
    output_tokens       INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    input_cost          NUMERIC(12,8) NOT NULL DEFAULT 0,
    output_cost         NUMERIC(12,8) NOT NULL DEFAULT 0,
    cache_read_cost     NUMERIC(12,8) NOT NULL DEFAULT 0,
    cache_creation_cost NUMERIC(12,8) NOT NULL DEFAULT 0,
    total_cost          NUMERIC(12,8) NOT NULL DEFAULT 0,
    actual_cost         NUMERIC(12,8) NOT NULL DEFAULT 0,
    rate_multiplier     NUMERIC(8,4),
    account_rate_multiplier NUMERIC(8,4),  -- 快照（历史一致性）
    service_tier        TEXT,               -- priority | flex | null
    billing_mode        TEXT,               -- token | per_request | image
    billing_type        SMALLINT NOT NULL DEFAULT 0,  -- 0=balance, 1=subscription
    billing_model_source TEXT,              -- original | upstream | channel_mapped
    model_mapping_chain TEXT,              -- "gpt-4→gpt-4-turbo→gpt-4-turbo-2025"
    request_type        SMALLINT NOT NULL DEFAULT 0,  -- 0=unknown,1=sync,2=stream,3=ws_v2
    stream              BOOLEAN NOT NULL DEFAULT FALSE,
    openai_ws_mode      BOOLEAN NOT NULL DEFAULT FALSE,
    duration_ms         INTEGER,
    first_token_ms      INTEGER,
    -- 图片生成
    image_count         INTEGER DEFAULT 0,
    image_size          TEXT,               -- "1K" | "2K" | "4K"
    image_output_cost   NUMERIC(12,8) DEFAULT 0,
    -- 网络上下文
    user_agent          TEXT,
    ip_address          INET,
    inbound_endpoint    TEXT,               -- "/v1/messages"
    upstream_endpoint   TEXT,               -- 规范化的上游路径
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 使用日志索引
CREATE INDEX idx_usage_logs_user_created ON usage_logs(user_id, created_at DESC);
CREATE INDEX idx_usage_logs_account_created ON usage_logs(account_id, created_at DESC);
CREATE INDEX idx_usage_logs_created ON usage_logs(created_at DESC);

-- 支付订单
CREATE TABLE payment_orders (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),
    provider        TEXT NOT NULL,       -- stripe | alipay | wechat
    amount_usd      NUMERIC(12,6) NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    provider_order_id TEXT,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 全局设置
CREATE TABLE settings (
    key         TEXT PRIMARY KEY,
    value       JSONB NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- OAuth 身份
CREATE TABLE auth_identities (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(id),
    provider    TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(provider, provider_id)
);

-- Channel（上游端点配置 + 定价覆盖）
CREATE TABLE channels (
    id                  BIGSERIAL PRIMARY KEY,
    name                TEXT NOT NULL,
    group_id            BIGINT NOT NULL REFERENCES groups(id),
    platform            TEXT NOT NULL,
    base_url            TEXT NOT NULL,
    model_mapping       JSONB,              -- {"gpt-4": "gpt-4-turbo", "gpt-*": "gpt-4o"}
    pricing_override    JSONB,              -- per-model 定价覆盖
    allowed_models      JSONB,              -- 模型白名单，null=全部
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 公告
CREATE TABLE announcements (
    id              BIGSERIAL PRIMARY KEY,
    title           TEXT NOT NULL,
    content         TEXT NOT NULL,
    notify_mode     TEXT NOT NULL DEFAULT 'banner',  -- banner | modal | silent
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 公告已读追踪
CREATE TABLE announcement_reads (
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    announcement_id BIGINT NOT NULL REFERENCES announcements(id) ON DELETE CASCADE,
    read_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, announcement_id)
);

-- 内容审核日志
CREATE TABLE moderation_logs (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL,
    api_key_id      BIGINT,
    request_id      TEXT NOT NULL,
    content_hash    TEXT NOT NULL,           -- SHA256 去重
    is_flagged      BOOLEAN NOT NULL,
    categories      JSONB NOT NULL,          -- {"harassment": 0.85, "hate": 0.02, ...}
    action_taken    TEXT,                    -- blocked | logged | auto_banned
    content_excerpt TEXT,                    -- 前 240 rune
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_moderation_logs_user ON moderation_logs(user_id, created_at DESC);
CREATE INDEX idx_moderation_logs_hash ON moderation_logs(content_hash);

-- 错误透传规则
CREATE TABLE error_passthrough_rules (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    status_codes    INTEGER[] NOT NULL,      -- {429, 503}
    keywords        TEXT[],                  -- {"rate_limit", "overloaded"}
    platform        TEXT,                    -- null = any
    body_check_limit INTEGER NOT NULL DEFAULT 8192,  -- 8KB
    action          TEXT NOT NULL DEFAULT 'passthrough',  -- passthrough | custom
    custom_body     JSONB,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 指标聚合表（预计算）
CREATE TABLE metrics_aggregated (
    id              BIGSERIAL PRIMARY KEY,
    dimension_type  TEXT NOT NULL,            -- model | account | user | group
    dimension_id    TEXT NOT NULL,
    window_start    TIMESTAMPTZ NOT NULL,
    window_end      TIMESTAMPTZ NOT NULL,
    granularity     TEXT NOT NULL,            -- 1min | 5min | 1hour | 1day
    request_count   INTEGER NOT NULL DEFAULT 0,
    error_count     INTEGER NOT NULL DEFAULT 0,
    total_tokens    BIGINT NOT NULL DEFAULT 0,
    total_cost_usd  NUMERIC(12,8) NOT NULL DEFAULT 0,
    avg_ttft_ms     NUMERIC(10,2),
    p99_latency_ms  NUMERIC(10,2),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_metrics_dim_window ON metrics_aggregated(dimension_type, dimension_id, window_start DESC);

-- 分销返佣
CREATE TABLE user_affiliates (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT UNIQUE NOT NULL REFERENCES users(id),
    aff_code        TEXT UNIQUE NOT NULL,
    inviter_id      BIGINT REFERENCES users(id),
    rebate_rate     NUMERIC(6,4) NOT NULL DEFAULT 0,
    aff_quota       NUMERIC(12,6) NOT NULL DEFAULT 0,
    aff_history     NUMERIC(12,6) NOT NULL DEFAULT 0,
    is_frozen       BOOLEAN NOT NULL DEFAULT FALSE,
    custom_settings JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_affiliate_ledger (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),
    action          TEXT NOT NULL,          -- accrue | transfer | adjust
    amount          NUMERIC(12,6) NOT NULL,
    related_user_id BIGINT,                -- 关联下线用户
    related_usage_id BIGINT,               -- 关联使用记录
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 兑换码
CREATE TABLE redeem_codes (
    id          BIGSERIAL PRIMARY KEY,
    code        TEXT UNIQUE NOT NULL,
    amount_usd  NUMERIC(12,6) NOT NULL,
    is_used     BOOLEAN NOT NULL DEFAULT FALSE,
    used_by     BIGINT REFERENCES users(id),
    used_at     TIMESTAMPTZ,
    notes       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 促销码
CREATE TABLE promo_codes (
    id              BIGSERIAL PRIMARY KEY,
    code            TEXT UNIQUE NOT NULL,
    discount_type   TEXT NOT NULL,          -- percentage | fixed
    discount_value  NUMERIC(12,6) NOT NULL,
    max_uses        INTEGER NOT NULL DEFAULT 0,
    current_uses    INTEGER NOT NULL DEFAULT 0,
    valid_from      TIMESTAMPTZ NOT NULL,
    valid_until     TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE promo_code_usage (
    id              BIGSERIAL PRIMARY KEY,
    promo_code_id   BIGINT NOT NULL REFERENCES promo_codes(id),
    user_id         BIGINT NOT NULL REFERENCES users(id),
    order_id        BIGINT REFERENCES payment_orders(id),
    used_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(promo_code_id, user_id)
);

-- 代理
CREATE TABLE proxies (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    protocol        TEXT NOT NULL,          -- http | https | socks5
    host            TEXT NOT NULL,
    port            INTEGER NOT NULL,
    auth_user       TEXT,
    auth_pass       TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_probe_ms   INTEGER,
    last_probe_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- TLS 指纹配置
CREATE TABLE tls_fingerprint_profiles (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    ja3_hash    TEXT,
    user_agent  TEXT,
    headers     JSONB,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 定时健康检测
CREATE TABLE scheduled_tests (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    account_id      BIGINT NOT NULL REFERENCES accounts(id),
    model           TEXT NOT NULL,
    test_prompt     TEXT NOT NULL,
    interval_s      INTEGER NOT NULL DEFAULT 300,
    timeout_ms      INTEGER NOT NULL DEFAULT 30000,
    auto_recover    BOOLEAN NOT NULL DEFAULT FALSE,
    last_result     TEXT,                  -- pass | fail
    last_run_at     TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Channel 监控
CREATE TABLE channel_monitors (
    id                  BIGSERIAL PRIMARY KEY,
    channel_id          BIGINT NOT NULL REFERENCES channels(id),
    check_interval_s    INTEGER NOT NULL DEFAULT 60,
    request_template_id BIGINT,
    expected_status     INTEGER NOT NULL DEFAULT 200,
    timeout_ms          INTEGER NOT NULL DEFAULT 10000,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE channel_monitor_histories (
    id              BIGSERIAL PRIMARY KEY,
    monitor_id      BIGINT NOT NULL REFERENCES channel_monitors(id),
    status_code     INTEGER,
    latency_ms      INTEGER,
    is_success      BOOLEAN NOT NULL,
    error_message   TEXT,
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE channel_monitor_daily_rollups (
    id              BIGSERIAL PRIMARY KEY,
    monitor_id      BIGINT NOT NULL REFERENCES channel_monitors(id),
    date            DATE NOT NULL,
    total_checks    INTEGER NOT NULL DEFAULT 0,
    success_count   INTEGER NOT NULL DEFAULT 0,
    avg_latency_ms  NUMERIC(10,2),
    p99_latency_ms  NUMERIC(10,2),
    UNIQUE(monitor_id, date)
);

CREATE TABLE channel_monitor_request_templates (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    method      TEXT NOT NULL DEFAULT 'POST',
    path        TEXT NOT NULL,
    headers     JSONB,
    body        JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 使用计费去重
CREATE TABLE usage_billing_dedup (
    request_id  TEXT PRIMARY KEY,
    billed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE usage_billing_dedup_archive (
    request_id  TEXT PRIMARY KEY,
    billed_at   TIMESTAMPTZ NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ops 告警
CREATE TABLE ops_alert_rules (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    condition   JSONB NOT NULL,
    severity    TEXT NOT NULL DEFAULT 'warning',
    notify      JSONB NOT NULL DEFAULT '["email"]',
    cooldown_s  INTEGER NOT NULL DEFAULT 300,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE ops_alert_silences (
    id          BIGSERIAL PRIMARY KEY,
    rule_id     BIGINT REFERENCES ops_alert_rules(id),
    until       TIMESTAMPTZ NOT NULL,
    reason      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ops 系统日志
CREATE TABLE ops_system_logs (
    id          BIGSERIAL PRIMARY KEY,
    level       TEXT NOT NULL,
    source      TEXT NOT NULL,
    message     TEXT NOT NULL,
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_ops_system_logs_created ON ops_system_logs(created_at DESC);

-- 支付审计日志
CREATE TABLE payment_audit_logs (
    id              BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES payment_orders(id),
    action          TEXT NOT NULL,
    idempotency_key TEXT UNIQUE,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 支付服务商实例
CREATE TABLE payment_provider_instances (
    id              BIGSERIAL PRIMARY KEY,
    provider_type   TEXT NOT NULL,         -- stripe | alipay | wechat | easypay
    name            TEXT NOT NULL,
    config          JSONB NOT NULL,        -- 加密的服务商配置
    weight          INTEGER NOT NULL DEFAULT 1,  -- 负载均衡权重
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 用户自定义属性
CREATE TABLE user_attribute_definitions (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT UNIQUE NOT NULL,
    data_type   TEXT NOT NULL,             -- string | number | boolean | json
    is_required BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_attribute_values (
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    attribute_id    BIGINT NOT NULL REFERENCES user_attribute_definitions(id) ON DELETE CASCADE,
    value           JSONB NOT NULL,
    PRIMARY KEY (user_id, attribute_id)
);

-- 安全密钥存储
CREATE TABLE security_secrets (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT UNIQUE NOT NULL,
    secret_type TEXT NOT NULL,             -- tls_cert | proxy_auth | api_key
    value       BYTEA NOT NULL,            -- 加密存储
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### 5.3 sub2api Redis 用途 → BEAM 替代方案

| sub2api Redis 用途 | BEAM 替代 | 说明 |
|-------------------|-----------|------|
| 并发槽 (sorted set) | `counters` + process monitor | 进程结束自动释放，无需 TTL 清理 |
| 等待计数 (INCR/DECR) | gen_server state / `counters` | 原子操作，进程监控保证释放 |
| 会话粘滞缓存 | ETS set + 定时清理 | `erlang:send_after` 驱动 TTL |
| 设置缓存 + singleflight | `persistent_term` + 单 gen_server | 读零开销，写通过单进程序列化 |
| 异步任务队列 | gen_server mailbox | 天然消息队列 |
| 账户状态临时标记 | 账户 gen_server state | 状态机内管理 |

---

## 6. API 兼容性

### 6.1 网关端点（对客户端完全兼容）

```
POST /v1/messages                     — Anthropic Claude 兼容
POST /openai/v1/chat/completions      — OpenAI Chat 兼容
POST /openai/v1/responses             — OpenAI Responses (Codex)
POST /openai/v1/images/generations    — OpenAI 图片生成
POST /gemini/v1beta/models/*          — Google Gemini 兼容
POST /antigravity/v1/messages         — Antigravity Claude Pro
```

**路由实现（Cowboy）：**

```erlang
%% ersub_router.erl
routes() ->
    [
        {"/v1/messages", ersub_claude_handler, []},
        {"/openai/v1/chat/completions", ersub_openai_handler, []},
        {"/openai/v1/responses", ersub_openai_responses_handler, []},
        {"/openai/v1/images/generations", ersub_openai_images_handler, []},
        {"/gemini/v1beta/[...]", ersub_gemini_handler, []},
        {"/antigravity/v1/messages", ersub_antigravity_handler, []},

        %% 管理 API
        {"/api/user/[...]", ersub_user_handler, []},
        {"/api/keys/[...]", ersub_keys_handler, []},
        {"/api/usage/[...]", ersub_usage_handler, []},
        {"/api/admin/[...]", ersub_admin_handler, []},
        {"/api/payment/[...]", ersub_payment_handler, []},
        {"/api/auth/[...]", ersub_auth_handler, []},

        %% 健康检查
        {"/health", ersub_health_handler, []},

        %% 静态文件（前端）
        {"/[...]", cowboy_static, {priv_dir, ersub, "static"}}
    ].
```

### 6.2 认证方式

与 sub2api 保持一致：

- 网关端点：`x-api-key` 或 `Authorization: Bearer sk-xxx` header
- 管理端点：JWT token（`Authorization: Bearer eyJ...`）
- OAuth 登录：GitHub / Google / 自定义 provider

### 6.3 请求/响应格式

完全兼容 sub2api 的请求体和响应体格式，包括：
- Anthropic Messages API 格式
- OpenAI Chat Completions 格式
- SSE 流式事件格式（`data: {...}\n\n`）
- 错误响应格式（HTTP status code + JSON body）

---

## 7. 前端策略

**方案：复用 sub2api 的 Vue 3 前端，仅替换后端。**

理由：
- ersub 的核心价值在后端（Erlang + CLIPS 引擎），前端无需重写
- sub2api 前端已有完善的 i18n、Dashboard、Admin 管理界面
- API 端点保持兼容，前端无需修改即可对接

实现方式：
1. 构建时将 sub2api 前端 `pnpm build` 产物复制到 `priv/static/`
2. Cowboy 通过 `cowboy_static` handler 提供静态文件服务
3. 前端通过相对路径 `/api/*` 访问后端 API

后续可考虑用 LiveView 重写管理界面，但不在 MVP 范围内。

---

## 8. CLIPS 规则管理

### 8.1 规则文件组织

```
priv/clips/
├── core.clp              # 基础 deftemplate 定义
├── scheduling.clp         # 账户选择评分规则
├── billing.clp            # 计费计算规则
├── quota.clp              # 配额检查规则
├── account_status.clp     # 账户状态转换规则
├── model_routing.clp      # 模型路由规则
└── custom/                # 用户自定义规则（运行时加载）
    └── *.clp
```

### 8.2 规则热更新

```erlang
%% 通过 admin API 触发规则重载
%% POST /api/admin/clips/reload

reload_rules() ->
    %% 1. 加载新规则文件
    NewRules = read_rule_files("priv/clips/"),
    %% 2. 逐个 worker 重载（滚动更新，不中断服务）
    poolboy:transaction(clips_pool, fun(Worker) ->
        gen_server:call(Worker, {reload_rules, NewRules})
    end).
```

### 8.3 CLIPS 可执行文件

```c
/* ersub_clips.c - CLIPS Port 包装器 */
/* 编译: gcc -o ersub_clips ersub_clips.c -lclips -ljson-c */

int main() {
    Environment *env = CreateEnvironment();

    /* 加载规则文件 */
    BatchStar(env, "priv/clips/core.clp");
    BatchStar(env, "priv/clips/scheduling.clp");
    BatchStar(env, "priv/clips/billing.clp");
    BatchStar(env, "priv/clips/quota.clp");
    BatchStar(env, "priv/clips/account_status.clp");

    /* 主循环：读 NDJSON 指令，执行，输出结果 */
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), stdin)) {
        json_object *cmd = json_tokener_parse(line);
        const char *op = json_object_get_string(
            json_object_object_get(cmd, "op"));

        if (strcmp(op, "assert") == 0) {
            assert_facts(env, cmd);
        } else if (strcmp(op, "run") == 0) {
            Run(env, -1);
            json_object *result = collect_results(env);
            printf("%s\n", json_object_to_json_string(result));
            fflush(stdout);
        } else if (strcmp(op, "retract_all") == 0) {
            Reset(env);
            /* 规则保留，事实清除 */
        } else if (strcmp(op, "reload") == 0) {
            Clear(env);
            reload_rule_files(env, cmd);
        }

        json_object_put(cmd);
    }

    DestroyEnvironment(env);
    return 0;
}
```

---

## 9. 配置系统

### 9.1 配置文件

```yaml
# config/ersub.yaml

server:
  host: "0.0.0.0"
  port: 8080
  max_connections: 10000

database:
  host: "localhost"
  port: 5432
  user: "postgres"
  password: "${DB_PASSWORD}"
  database: "ersub"
  pool_size: 20

clips:
  pool_size: 8              # CLIPS worker 数量
  rules_dir: "priv/clips"
  custom_rules_dir: "priv/clips/custom"

gateway:
  max_account_switches: 10
  upstream_timeout_ms: 600000
  max_body_size: "256MB"
  ping_interval_ms: 10000

scheduling:
  sticky_session_ttl_s: 3600
  top_k: 7
  score_weights:
    priority: 1.0
    load: 1.0
    queue: 0.7
    error_rate: 0.8
    ttft: 0.5

concurrency:
  default_user_max: 5
  wait_queue_extra: 20
  wait_timeout_ms: 30000

billing:
  sync_interval_ms: 5000    # 余额同步到 DB 的间隔
  pricing_update_url: "https://raw.githubusercontent.com/.../pricing.json"

auth:
  jwt_secret: "${JWT_SECRET}"
  jwt_expire_hours: 24
  oauth_providers:
    github:
      client_id: "${GITHUB_CLIENT_ID}"
      client_secret: "${GITHUB_CLIENT_SECRET}"

payment:
  stripe:
    enabled: false
    secret_key: "${STRIPE_SECRET_KEY}"

moderation:
  mode: "off"                # off | observe | pre_block
  api_base_url: "https://api.openai.com"
  model: "omni-moderation-latest"
  timeout_ms: 3000
  sample_rate: 1.0           # 0.0-1.0
  max_input_runes: 12000
  worker_pool_size: 8
  worker_queue_max: 100000
  auto_ban:
    enabled: false
    threshold: 5             # 违规次数
    window_s: 86400          # 时间窗口
  retention:
    flagged_days: 180
    non_flagged_days: 3

security:
  url_allowlist:
    enabled: false
    upstream_hosts: []       # 支持通配符 ["*.openai.com"]
    allow_http: false        # 是否允许 HTTP（非 HTTPS）
  response_headers:
    enabled: true
    csp_enabled: true
  cors:
    allowed_origins: []      # 空=同源策略

upstream:
  pool_isolation: "account_proxy"  # proxy | account | account_proxy
  max_pools: 5000
  idle_ttl_ms: 900000        # 15 分钟
  max_idle_per_host: 120
  max_total_per_host: 240
  idle_timeout_ms: 90000     # 90s
  response_header_timeout_ms: 300000  # 5 分钟

h2c:
  enabled: true
  max_concurrent_streams: 50
  idle_timeout_ms: 75000

ops:
  metrics_aggregation_enabled: true
  usage_cleanup:
    enabled: true
    retention_days: 90
    run_at_hour: 3           # 凌晨 3 点
```

### 9.2 运行时配置（persistent_term）

```erlang
%% 读取（零开销，直接内存访问）
get_config(Key) ->
    persistent_term:get({ersub_config, Key}).

%% 写入（通过单一 gen_server 序列化，避免全局 GC 风暴）
set_config(Key, Value) ->
    gen_server:call(ersub_config_srv, {set, Key, Value}).

%% ersub_config_srv handle_call
handle_call({set, Key, Value}, _From, State) ->
    persistent_term:put({ersub_config, Key}, Value),
    %% 同步到 DB
    ersub_repo:upsert_setting(Key, Value),
    {reply, ok, State}.
```

---

## 10. 部署方案

### 10.1 Release 构建

```
ersub/
├── _build/prod/rel/ersub/
│   ├── bin/ersub              # 启动脚本
│   ├── lib/                   # BEAM 字节码
│   ├── releases/              # release 配置
│   └── priv/
│       ├── clips/             # CLIPS 规则文件
│       ├── static/            # 前端静态文件
│       └── ersub_clips        # CLIPS 可执行文件
```

使用 `rebar3` 或 `mix` (Elixir wrapper) 构建 release：

```bash
rebar3 as prod release
```

### 10.2 依赖

| 组件 | 最低版本 | 用途 |
|------|---------|------|
| Erlang/OTP | 26+ | 运行时 |
| PostgreSQL | 15+ | 持久化存储 |
| CLIPS | 6.4+ | 规则引擎 |
| json-c | 0.15+ | CLIPS 端 JSON 解析 |

**不再需要 Redis。**

### 10.3 Docker Compose

```yaml
version: "3.8"
services:
  ersub:
    build: .
    ports:
      - "8080:8080"
    environment:
      - DB_HOST=postgres
      - DB_PASSWORD=changeme
      - JWT_SECRET=changeme
    depends_on:
      - postgres

  postgres:
    image: postgres:16
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=ersub
      - POSTGRES_PASSWORD=changeme

volumes:
  pgdata:
```

### 10.4 Systemd 服务

```ini
[Unit]
Description=ErSub AI API Gateway
After=postgresql.service

[Service]
Type=exec
User=ersub
ExecStart=/opt/ersub/bin/ersub foreground
Restart=on-failure
RestartSec=5
Environment=HOME=/opt/ersub

[Install]
WantedBy=multi-user.target
```

---

## 11. 项目结构

```
ersub/
├── rebar.config                # 构建配置
├── config/
│   ├── sys.config              # OTP 应用配置
│   ├── vm.args                 # BEAM VM 参数
│   └── ersub.yaml              # 业务配置
├── src/
│   ├── ersub_app.erl           # application behaviour
│   ├── ersub_sup.erl           # top-level supervisor
│   │
│   ├── config/
│   │   └── ersub_config_srv.erl
│   │
│   ├── db/
│   │   ├── ersub_repo.erl          # 数据访问层
│   │   ├── ersub_repo_pool.erl     # 连接池
│   │   └── ersub_migration.erl     # 数据库迁移
│   │
│   ├── clips/
│   │   ├── ersub_clips_worker.erl  # CLIPS port gen_server
│   │   └── ersub_clips_pool.erl    # poolboy 配置
│   │
│   ├── gateway/
│   │   ├── ersub_claude_handler.erl
│   │   ├── ersub_openai_handler.erl
│   │   ├── ersub_openai_responses_handler.erl
│   │   ├── ersub_openai_images_handler.erl
│   │   ├── ersub_openai_ws_handler.erl      # WebSocket v2
│   │   ├── ersub_gemini_handler.erl
│   │   ├── ersub_antigravity_handler.erl
│   │   ├── ersub_stream_fsm.erl             # 流式状态机
│   │   ├── ersub_request_transform.erl      # 请求转换 + 模型映射
│   │   └── ersub_client_detector.erl        # Claude Code 检测
│   │
│   ├── scheduler/
│   │   ├── ersub_scheduler_srv.erl          # 调度入口
│   │   └── ersub_account_srv.erl            # 单账户进程
│   │
│   ├── billing/
│   │   ├── ersub_billing_srv.erl            # 实时计费
│   │   ├── ersub_usage_logger.erl           # 异步日志
│   │   └── ersub_pricing_srv.erl            # 定价表管理 + 自动更新
│   │
│   ├── concurrency/
│   │   ├── ersub_concurrency_srv.erl
│   │   └── ersub_rate_limiter.erl           # RPM 滑动窗口限速
│   │
│   ├── session/
│   │   └── ersub_session_srv.erl            # 粘滞会话
│   │
│   ├── channel/
│   │   └── ersub_channel_srv.erl            # Channel + 模型映射 + 定价覆盖
│   │
│   ├── moderation/
│   │   ├── ersub_moderation_srv.erl         # 内容审核入口
│   │   ├── ersub_moderation_worker.erl      # 异步审核 worker
│   │   └── ersub_moderation_cache.erl       # SHA256 去重缓存
│   │
│   ├── security/
│   │   ├── ersub_url_validator.erl          # SSRF 防护 + URL 白名单
│   │   ├── ersub_ip_access.erl              # IP 黑白名单 (CIDR)
│   │   ├── ersub_security_middleware.erl    # 安全响应头 + CSP
│   │   └── ersub_cors_middleware.erl        # CORS
│   │
│   ├── auth/
│   │   ├── ersub_auth_srv.erl               # JWT + OAuth
│   │   ├── ersub_auth_middleware.erl         # 认证中间件
│   │   ├── ersub_totp.erl                   # TOTP 2FA
│   │   └── ersub_token_refresh_srv.erl      # OAuth token 后台刷新
│   │
│   ├── admin/
│   │   ├── ersub_admin_handler.erl
│   │   ├── ersub_user_handler.erl
│   │   └── ersub_announcement_handler.erl   # 公告 CRUD
│   │
│   ├── ops/
│   │   ├── ersub_health_srv.erl             # 健康评分
│   │   ├── ersub_metrics_srv.erl            # 指标聚合
│   │   └── ersub_usage_cleanup_srv.erl      # 使用记录清理
│   │
│   ├── payment/
│   │   ├── ersub_payment_srv.erl
│   │   ├── ersub_stripe.erl
│   │   └── ersub_payment_handler.erl
│   │
│   ├── setup/
│   │   └── ersub_setup.erl                  # 首次运行向导
│   │
│   ├── upstream/
│   │   └── ersub_upstream_pool.erl          # 连接池管理 (gun)
│   │
│   └── platform/
│       ├── ersub_platform_sup.erl           # 平台 supervisor
│       ├── ersub_claude_pool.erl
│       ├── ersub_openai_pool.erl
│       ├── ersub_gemini_pool.erl
│       └── ersub_antigravity_pool.erl
│
├── priv/
│   ├── clips/
│   │   ├── core.clp
│   │   ├── scheduling.clp
│   │   ├── billing.clp
│   │   ├── quota.clp
│   │   ├── account_status.clp
│   │   ├── model_routing.clp
│   │   ├── error_passthrough.clp    # 错误透传规则
│   │   └── custom/
│   ├── static/                      # 前端构建产物
│   ├── pricing/                     # 内嵌定价 fallback
│   │   └── model_prices.json
│   └── migrations/                  # SQL 迁移文件
│       ├── 001_initial.sql
│       └── ...
│
├── c_src/
│   ├── ersub_clips.c                # CLIPS port 可执行文件
│   └── Makefile
│
├── test/
│   ├── ersub_scheduler_tests.erl
│   ├── ersub_billing_tests.erl
│   ├── ersub_clips_tests.erl
│   ├── ersub_moderation_tests.erl
│   ├── ersub_url_validator_tests.erl
│   └── ...
│
├── docs/
│   └── DESIGN.md                    # 本文档
│
├── deploy/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── ersub.service
│
└── frontend/                    # sub2api 前端（git submodule 或复制）
    └── ...
```

---

## 12. 实施路线

### Phase 1: 基础骨架（MVP）

- [ ] rebar3 项目初始化 + Cowboy HTTP server（含 H2C 支持）
- [ ] PostgreSQL 连接池 + 基础 migration
- [ ] CLIPS Port 集成 + worker pool
- [ ] 基础认证（API Key 验证 + IP 黑白名单）
- [ ] Claude `/v1/messages` 代理（非流式）
- [ ] Setup Wizard（首次运行向导）

### Phase 2: 核心功能

- [ ] SSE 流式响应（gen_statem）
- [ ] CLIPS 账户选择评分规则
- [ ] CLIPS 计费规则（token + per_request + image 三模式）
- [ ] 并发控制（counters）
- [ ] 会话粘滞（ETS）
- [ ] Failover 机制
- [ ] RPM 限速（滑动窗口）
- [ ] 连接池管理（gun，三种隔离策略）

### Phase 3: 多平台 + 请求管道

- [ ] OpenAI Chat Completions 兼容
- [ ] Gemini 兼容
- [ ] Channel 系统 + 三级模型映射链
- [ ] Channel 级定价覆盖
- [ ] 错误透传规则引擎（CLIPS）
- [ ] OAuth Token 后台刷新服务
- [ ] Claude Code 客户端检测 + codex_cli_only
- [ ] Cache Control 注入

### Phase 4: 管理 + 安全

- [ ] 用户管理 API
- [ ] Admin 管理 API
- [ ] 分组/订阅/配额系统
- [ ] 公告系统
- [ ] 软删除（partial unique index）
- [ ] 安全响应头（CSP + nonce）
- [ ] CORS 中间件
- [ ] URL Allowlist / SSRF 防护
- [ ] 内容审核系统（off / observe / pre_block）
- [ ] 前端集成

### Phase 5: 运营功能

- [ ] JWT + OAuth 认证（含 pending auth sessions）
- [ ] 支付集成（多服务商 + 负载均衡 + 审计日志）
- [ ] 兑换码 + 促销码系统
- [ ] 分销返佣系统（Affiliate）
- [ ] 余额通知（邮件）
- [ ] 自定义页面（Markdown）
- [ ] 用户自定义属性
- [ ] 后端只读模式（Backend Mode Guard）

### Phase 6: 生产就绪

- [ ] WebSocket v2（OpenAI Responses 帧级中继）
- [ ] 代理管理 + TLS 指纹伪装
- [ ] 定时健康检测 + 自动恢复
- [ ] Channel 监控（检测 + 日聚合）
- [ ] Ops 告警系统 + 静默规则
- [ ] 规则热更新 API
- [ ] 可观测性（健康评分、指标聚合、使用记录清理、系统日志）
- [ ] 定价表自动更新（LiteLLM 格式 + 内嵌 fallback）
- [ ] 使用计费去重
- [ ] 数据备份（S3 + pg_dump）
- [ ] 账户批量导入
- [ ] Docker 部署
- [ ] 压力测试与性能调优

---

## 13. 测试策略

对标 sub2api 的测试体系（527 个测试文件），映射到 Erlang/OTP 测试范式。

### 13.1 sub2api 测试体系概览

| 维度 | sub2api 实现 |
|------|-------------|
| 测试文件数 | 527 个 `*_test.go` |
| 测试类型 | unit (190) / integration (46) / e2e (3) |
| 构建标签 | `//go:build unit`, `//go:build integration`, `//go:build e2e` |
| 测试框架 | testify (assert/require/suite) |
| DB 测试 | testcontainers (PostgreSQL/Redis) + 事务隔离回滚 |
| Mock 策略 | 手写 mock（无 codegen），记录调用 + 返回固定值 |
| HTTP 测试 | gin.TestMode + httptest.NewRecorder |
| 数据工厂 | `must*` 命名规范的 fixture factory |
| 覆盖率分布 | service 289 文件（最多）→ repository 87 → handler 73 → pkg 38 |
| CI 集成 | Makefile targets: test-unit / test-integration / test-e2e |

### 13.2 Erlang 测试框架选型

| sub2api (Go) | ersub (Erlang) | 说明 |
|-------------|----------------|------|
| `testing` + `testify` | `eunit` + `common_test` (CT) | 标准库内置 |
| `//go:build unit` | eunit 模块 | 进程内快速测试 |
| `//go:build integration` | Common Test suite | 需要外部依赖的集成测试 |
| `//go:build e2e` | Common Test + `gun` client | 真实 HTTP 请求 |
| `testcontainers-go` | `testcontainers-erlang` 或 Docker CLI | 容器化 PostgreSQL |
| testify `suite` (setup/teardown) | CT `init_per_suite/end_per_suite` | 套件级生命周期 |
| testify `require/assert` | `?assertEqual` / `?assertMatch` 宏 | eunit 断言宏 |
| `gin.TestMode` + `httptest` | `cowboy_test` / 直接 `gun:open` | HTTP handler 测试 |
| 手写 mock 结构体 | `meck` 库 或 手写 behaviour mock | 进程级 mock |
| 事务回滚隔离 | CT `init_per_testcase` + DB transaction | 每用例事务隔离 |
| 表驱动测试 | eunit generator / 列表推导 | 参数化测试 |

### 13.3 测试分类与组织

```
test/
├── unit/                           # eunit 单元测试
│   ├── ersub_scheduler_tests.erl   # 调度器评分算法
│   ├── ersub_billing_tests.erl     # 计费计算逻辑
│   ├── ersub_quota_tests.erl       # 配额检查
│   ├── ersub_model_mapping_tests.erl # 模型映射（三级链 + 通配符）
│   ├── ersub_ip_access_tests.erl   # IP 黑白名单 CIDR 匹配
│   ├── ersub_url_validator_tests.erl # SSRF 防护
│   ├── ersub_client_detector_tests.erl # Claude Code 检测
│   ├── ersub_rate_limiter_tests.erl # RPM 滑动窗口
│   ├── ersub_affiliate_tests.erl   # 返佣计算
│   ├── ersub_pricing_tests.erl     # 定价表解析
│   └── ersub_error_passthrough_tests.erl # 错误透传规则匹配
│
├── integration/                    # Common Test 集成测试
│   ├── ersub_repo_SUITE.erl        # 数据库 CRUD（事务隔离）
│   ├── ersub_clips_SUITE.erl       # CLIPS Port 通信 + 规则执行
│   ├── ersub_concurrency_SUITE.erl # 并发控制（counters + 等待队列）
│   ├── ersub_session_SUITE.erl     # 粘滞会话（ETS TTL）
│   ├── ersub_billing_SUITE.erl     # 计费 + 余额同步 + 去重
│   ├── ersub_moderation_SUITE.erl  # 内容审核 worker pool
│   ├── ersub_channel_SUITE.erl     # Channel + 定价覆盖
│   ├── ersub_auth_SUITE.erl        # JWT + OAuth + TOTP
│   ├── ersub_payment_SUITE.erl     # 支付 webhook 处理
│   ├── ersub_upstream_pool_SUITE.erl # 连接池隔离
│   └── ersub_token_refresh_SUITE.erl # OAuth token 刷新
│
├── e2e/                            # 端到端测试
│   ├── ersub_gateway_SUITE.erl     # Claude /v1/messages（流式+非流式）
│   ├── ersub_openai_SUITE.erl      # OpenAI /v1/chat/completions
│   └── ersub_gemini_SUITE.erl      # Gemini /v1beta/*
│
├── property/                       # 属性测试（PropEr）
│   ├── ersub_billing_prop.erl      # 任意 token 组合的计费正确性
│   ├── ersub_scheduler_prop.erl    # 任意账户状态下的调度收敛性
│   └── ersub_cidr_prop.erl         # 任意 IP + CIDR 的匹配正确性
│
├── bench/                          # 性能基准测试
│   ├── ersub_clips_bench.erl       # CLIPS Port 调用延迟
│   ├── ersub_scheduler_bench.erl   # 调度器吞吐量
│   └── ersub_ets_bench.erl         # ETS 读写性能
│
└── support/                        # 测试辅助
    ├── ersub_test_fixtures.erl     # 数据工厂（must_* 函数）
    ├── ersub_test_db.erl           # PostgreSQL 容器 + 事务管理
    ├── ersub_test_clips.erl        # CLIPS Port 测试辅助
    ├── ersub_mock_upstream.erl     # 模拟上游 API 服务器
    └── ersub_test_helpers.erl      # 通用断言 + 工具函数
```

### 13.4 单元测试模式（eunit）

对标 sub2api 的 `//go:build unit` 测试。

**表驱动测试（Table-Driven）：**

```erlang
%% ersub_model_mapping_tests.erl
-include_lib("eunit/include/eunit.hrl").

%% 对标 sub2api handler/endpoint_test.go 的表驱动模式
model_mapping_test_() ->
    Mapping = #{
        <<"gpt-4">> => <<"gpt-4-turbo">>,
        <<"gpt-*">> => <<"gpt-4o">>,
        <<"claude-3">> => <<"claude-sonnet-4">>
    },
    Tests = [
        {<<"gpt-4">>,        <<"gpt-4-turbo">>,  "exact match"},
        {<<"gpt-4o-mini">>,  <<"gpt-4o">>,        "wildcard match"},
        {<<"claude-3">>,     <<"claude-sonnet-4">>, "exact match"},
        {<<"unknown">>,      undefined,            "no match"}
    ],
    [
        {Desc, fun() ->
            ?assertEqual(Expected, ersub_request_transform:resolve_model_mapping(Input, Mapping))
        end}
        || {Input, Expected, Desc} <- Tests
    ].
```

**IP CIDR 匹配测试：**

```erlang
%% ersub_ip_access_tests.erl
ip_whitelist_test_() ->
    Tests = [
        %% {ClientIP, Whitelist, Blacklist, Expected}
        {{10, 0, 0, 1},   [<<"10.0.0.0/8">>],  [],                  allow},
        {{192, 168, 1, 1}, [<<"10.0.0.0/8">>],  [],                  deny},
        {{10, 0, 0, 1},   [<<"10.0.0.0/8">>],  [<<"10.0.0.1/32">>], deny},   % 黑名单优先
        {{172, 16, 0, 1},  [],                  [],                  allow},  % 无白名单=全放行
        {{127, 0, 0, 1},   [],                  [<<"127.0.0.0/8">>], deny}
    ],
    [
        {lists:flatten(io_lib:format("~p", [IP])), fun() ->
            ?assertEqual(Exp, ersub_ip_access:check_ip_access(IP, WL, BL))
        end}
        || {IP, WL, BL, Exp} <- Tests
    ].
```

**CLIPS 计费规则单元测试：**

```erlang
%% ersub_billing_tests.erl
%% 测试 CLIPS 计费规则的正确性，使用真实 CLIPS Port

billing_token_mode_test() ->
    %% 构造 usage facts
    Usage = #{
        model => <<"claude-sonnet-4-20250514">>,
        input_tokens => 1000,
        output_tokens => 500,
        cache_read_tokens => 200,
        cache_5m_tokens => 0,
        cache_1h_tokens => 100,
        image_output_tokens => 0,
        service_tier => standard,
        account_rate_mult => 1.0,
        group_rate_mult => 1.0,
        total_input_tokens => 1000
    },
    {ok, Result} = ersub_clips_worker:calculate_billing(Usage),
    ?assert(maps:get(actual_cost, Result) > 0),
    ?assertEqual(0.0, maps:get(image_cost, Result)).

billing_priority_tier_test() ->
    Usage = #{
        model => <<"claude-sonnet-4-20250514">>,
        input_tokens => 1000,
        output_tokens => 500,
        service_tier => priority,  %% 2x 乘数
        account_rate_mult => 1.0,
        group_rate_mult => 1.0
    },
    {ok, PriorityResult} = ersub_clips_worker:calculate_billing(Usage),

    Usage2 = Usage#{service_tier => standard},
    {ok, StandardResult} = ersub_clips_worker:calculate_billing(Usage2),

    %% priority 价格应该是 standard 的 2 倍
    ?assertEqual(
        maps:get(actual_cost, PriorityResult),
        maps:get(actual_cost, StandardResult) * 2.0
    ).

billing_per_request_mode_test() ->
    Usage = #{
        model => <<"fixed-price-model">>,
        billing_mode => per_request,
        fixed_price => 0.05,
        account_rate_mult => 1.5,
        group_rate_mult => 1.0
    },
    {ok, Result} = ersub_clips_worker:calculate_billing(Usage),
    ?assertEqual(0.075, maps:get(actual_cost, Result)).  %% 0.05 * 1.5

billing_image_mode_test() ->
    Usage = #{
        billing_mode => image,
        image_count => 2,
        image_size => <<"2K">>,
        account_rate_mult => 1.0,
        group_rate_mult => 1.0,
        group_image_rate_mult => 2.0,
        group_image_rate_independent => true
    },
    {ok, Result} = ersub_clips_worker:calculate_billing(Usage),
    ?assert(maps:get(image_cost, Result) > 0).
```

### 13.5 集成测试模式（Common Test）

对标 sub2api 的 `//go:build integration` + testcontainers 模式。

**数据库事务隔离（对标 sub2api 的 `testEntTx`）：**

```erlang
%% ersub_test_db.erl - 测试辅助模块
%% 对标 sub2api repository/integration_harness_test.go

-module(ersub_test_db).
-export([start_container/0, get_connection/0, with_transaction/1]).

%% 启动 PostgreSQL 测试容器
start_container() ->
    %% 使用 docker CLI 启动 PostgreSQL 容器
    os:cmd("docker run -d --name ersub_test_pg "
           "-e POSTGRES_DB=ersub_test "
           "-e POSTGRES_PASSWORD=test "
           "-p 15432:5432 postgres:16"),
    wait_for_ready(15432, 30000),
    %% 执行 migration
    ersub_migration:run(test_connection_config()),
    ok.

%% 事务隔离：每个测试用例在事务中运行，自动回滚
with_transaction(Fun) ->
    {ok, Conn} = get_connection(),
    {ok, _, _} = epgsql:squery(Conn, "BEGIN"),
    try
        Result = Fun(Conn),
        {ok, _, _} = epgsql:squery(Conn, "ROLLBACK"),
        Result
    catch
        Class:Reason:Stack ->
            epgsql:squery(Conn, "ROLLBACK"),
            erlang:raise(Class, Reason, Stack)
    after
        epgsql:close(Conn)
    end.
```

**Repository 集成测试 SUITE（对标 `account_repo_integration_test.go`）：**

```erlang
%% ersub_repo_SUITE.erl
-module(ersub_repo_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%% === 套件生命周期 ===
%% 对标 sub2api 的 testcontainers setup

all() -> [
    create_account_test,
    get_account_by_id_test,
    update_account_test,
    delete_account_cascade_test,
    list_accounts_with_filter_test,
    create_user_with_soft_delete_test,
    affiliate_ledger_test
].

init_per_suite(Config) ->
    ersub_test_db:start_container(),
    Config.

end_per_suite(_Config) ->
    os:cmd("docker rm -f ersub_test_pg"),
    ok.

%% 每个测试用例在独立事务中运行
init_per_testcase(_TestCase, Config) ->
    {ok, Conn} = ersub_test_db:get_connection(),
    {ok, _, _} = epgsql:squery(Conn, "BEGIN"),
    [{db_conn, Conn} | Config].

end_per_testcase(_TestCase, Config) ->
    Conn = ?config(db_conn, Config),
    epgsql:squery(Conn, "ROLLBACK"),
    epgsql:close(Conn),
    ok.

%% === 测试用例 ===

create_account_test(Config) ->
    Conn = ?config(db_conn, Config),
    Account = ersub_test_fixtures:must_create_account(Conn, #{
        name => <<"test-claude-1">>,
        platform => claude,
        account_type => api_key,
        credentials => #{<<"api_key">> => <<"sk-test">>},
        priority => 10
    }),
    ?assertMatch(#{id := Id} when is_integer(Id), Account),
    ?assertEqual(<<"test-claude-1">>, maps:get(name, Account)).

delete_account_cascade_test(Config) ->
    Conn = ?config(db_conn, Config),
    Account = ersub_test_fixtures:must_create_account(Conn, #{
        name => <<"cascade-test">>, platform => openai
    }),
    Group = ersub_test_fixtures:must_create_group(Conn, #{
        name => <<"test-group">>, platform => openai
    }),
    ersub_test_fixtures:must_bind_account_to_group(
        Conn, maps:get(id, Account), maps:get(id, Group)
    ),
    %% 删除账户应该级联删除 account_groups
    ok = ersub_repo:delete_account(Conn, maps:get(id, Account)),
    ?assertEqual([], ersub_repo:list_account_groups(Conn, maps:get(id, Account))).
```

**CLIPS 集成测试（验证 Port 通信 + 规则正确性）：**

```erlang
%% ersub_clips_SUITE.erl
-module(ersub_clips_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> [
    port_lifecycle_test,
    scheduling_rule_test,
    billing_rule_test,
    quota_rule_test,
    error_passthrough_rule_test,
    rule_reload_test,
    concurrent_requests_test
].

init_per_suite(Config) ->
    %% 编译 CLIPS 可执行文件
    os:cmd("cd c_src && make"),
    %% 启动 CLIPS worker pool
    {ok, _} = ersub_clips_pool:start_link(#{pool_size => 2}),
    Config.

end_per_suite(_Config) ->
    ersub_clips_pool:stop(),
    ok.

%% Port 生命周期测试
port_lifecycle_test(_Config) ->
    %% 验证 worker 能正常获取和归还
    {ok, Worker} = poolboy:checkout(clips_pool),
    ?assert(is_pid(Worker)),
    ?assert(is_process_alive(Worker)),
    poolboy:checkin(clips_pool, Worker).

%% 调度规则正确性
scheduling_rule_test(_Config) ->
    Candidates = [
        #{id => 1, priority => 10, load_rate => 0.2, error_rate => 0.01,
          ttft_ms => 100.0, waiting => 0, status => active, supports_model => 1},
        #{id => 2, priority => 5, load_rate => 0.8, error_rate => 0.05,
          ttft_ms => 500.0, waiting => 3, status => active, supports_model => 1},
        #{id => 3, priority => 1, load_rate => 0.1, error_rate => 0.0,
          ttft_ms => 50.0, waiting => 0, status => active, supports_model => 1}
    ],
    Weights = #{priority => 1.0, load => 1.0, queue => 0.7,
                error_rate => 0.8, ttft => 0.5},
    {ok, Result} = ersub_clips_worker:select_account(Candidates, Weights, 3),
    SelectedId = maps:get(account_id, Result),
    %% 账户 3 应该得分最高（最低 priority 值 + 最低 load + 零 error）
    ?assertEqual(3, SelectedId).

%% 规则热更新测试
rule_reload_test(_Config) ->
    %% 修改规则文件
    ok = file:write_file("priv/clips/custom/test_rule.clp",
        "(defrule test-rule => (assert (test-fired TRUE)))"),
    %% 触发重载
    ok = ersub_clips_pool:reload_rules(),
    %% 验证新规则生效
    {ok, Result} = ersub_clips_worker:run_custom_query(test_fired),
    ?assertEqual(true, maps:get(value, Result)),
    %% 清理
    file:delete("priv/clips/custom/test_rule.clp"),
    ersub_clips_pool:reload_rules().

%% 并发请求测试（验证 pool 隔离）
concurrent_requests_test(_Config) ->
    Parent = self(),
    N = 50,
    Pids = [spawn_link(fun() ->
        Candidates = [#{id => I, priority => I, load_rate => 0.1,
                        error_rate => 0.0, ttft_ms => 100.0,
                        waiting => 0, status => active, supports_model => 1}],
        {ok, _Result} = ersub_clips_worker:select_account(
            Candidates, default_weights(), 1
        ),
        Parent ! {done, self()}
    end) || I <- lists:seq(1, N)],
    %% 所有请求应在合理时间内完成
    [receive {done, Pid} -> ok after 5000 -> ct:fail({timeout, Pid}) end
     || Pid <- Pids].
```

### 13.6 E2E 测试模式

对标 sub2api 的 `//go:build e2e` + 环境变量配置模式。

```erlang
%% ersub_gateway_SUITE.erl
-module(ersub_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    case os:getenv("ERSUB_E2E_ENABLED") of
        false -> [];
        _ -> [
            claude_messages_sync_test,
            claude_messages_stream_test,
            openai_completions_test,
            failover_test,
            rate_limit_test,
            concurrent_test
        ]
    end.

init_per_suite(Config) ->
    BaseUrl = os:getenv("ERSUB_BASE_URL", "http://localhost:8080"),
    ApiKey = os:getenv("ERSUB_API_KEY"),
    case ApiKey of
        false -> {skip, "ERSUB_API_KEY not set"};
        _ -> [{base_url, BaseUrl}, {api_key, ApiKey} | Config]
    end.

%% Claude Messages 非流式测试
claude_messages_sync_test(Config) ->
    BaseUrl = ?config(base_url, Config),
    ApiKey = ?config(api_key, Config),
    {ok, ConnPid} = gun:open("localhost", 8080),
    Body = jsx:encode(#{
        model => <<"claude-sonnet-4-20250514">>,
        max_tokens => 100,
        messages => [#{role => <<"user">>, content => <<"Hello">>}]
    }),
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"x-api-key">>, list_to_binary(ApiKey)}
    ],
    StreamRef = gun:post(ConnPid, "/v1/messages", Headers, Body),
    {response, nofin, 200, _RespHeaders} = gun:await(ConnPid, StreamRef, 60000),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, 60000),
    Response = jsx:decode(RespBody, [return_maps]),
    ?assertMatch(#{<<"type">> := <<"message">>}, Response),
    ?assert(maps:is_key(<<"content">>, Response)),
    gun:close(ConnPid).

%% Claude Messages 流式测试
claude_messages_stream_test(Config) ->
    ApiKey = ?config(api_key, Config),
    {ok, ConnPid} = gun:open("localhost", 8080),
    Body = jsx:encode(#{
        model => <<"claude-sonnet-4-20250514">>,
        max_tokens => 100,
        stream => true,
        messages => [#{role => <<"user">>, content => <<"Hi">>}]
    }),
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"x-api-key">>, list_to_binary(ApiKey)}
    ],
    StreamRef = gun:post(ConnPid, "/v1/messages", Headers, Body),
    {response, nofin, 200, RespHeaders} = gun:await(ConnPid, StreamRef, 60000),
    %% 验证 SSE content-type
    ContentType = proplists:get_value(<<"content-type">>, RespHeaders),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    %% 收集 SSE events
    Events = collect_sse_events(ConnPid, StreamRef, []),
    ?assert(length(Events) > 0),
    %% 验证事件序列包含 message_start 和 message_stop
    EventTypes = [maps:get(<<"type">>, E) || E <- Events],
    ?assert(lists:member(<<"message_start">>, EventTypes)),
    ?assert(lists:member(<<"message_stop">>, EventTypes)),
    gun:close(ConnPid).

collect_sse_events(ConnPid, StreamRef, Acc) ->
    case gun:await(ConnPid, StreamRef, 30000) of
        {data, nofin, Data} ->
            NewEvents = parse_sse_data(Data),
            collect_sse_events(ConnPid, StreamRef, Acc ++ NewEvents);
        {data, fin, Data} ->
            Acc ++ parse_sse_data(Data);
        {error, _} ->
            Acc
    end.
```

### 13.7 属性测试（PropEr）

sub2api 没有属性测试，ersub 利用 Erlang 生态的 PropEr 库增强覆盖。

```erlang
%% ersub_billing_prop.erl
-module(ersub_billing_prop).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% 属性：任意合法 token 组合，计费结果必须非负
prop_billing_non_negative() ->
    ?FORALL({InputTokens, OutputTokens, CacheReadTokens},
            {non_neg_integer(), non_neg_integer(), non_neg_integer()},
        begin
            Usage = #{
                model => <<"claude-sonnet-4-20250514">>,
                input_tokens => InputTokens,
                output_tokens => OutputTokens,
                cache_read_tokens => CacheReadTokens,
                cache_5m_tokens => 0,
                cache_1h_tokens => 0,
                image_output_tokens => 0,
                service_tier => standard,
                account_rate_mult => 1.0,
                group_rate_mult => 1.0,
                total_input_tokens => InputTokens
            },
            {ok, Result} = ersub_clips_worker:calculate_billing(Usage),
            maps:get(actual_cost, Result) >= 0
        end).

%% 属性：rate_multiplier=0 时实际成本为 0
prop_zero_rate_multiplier() ->
    ?FORALL({InputTokens, OutputTokens},
            {pos_integer(), pos_integer()},
        begin
            Usage = #{
                model => <<"claude-sonnet-4-20250514">>,
                input_tokens => InputTokens,
                output_tokens => OutputTokens,
                account_rate_mult => 0.0,
                group_rate_mult => 1.0
            },
            {ok, Result} = ersub_clips_worker:calculate_billing(Usage),
            maps:get(actual_cost, Result) == 0.0
        end).

%% 属性：priority tier 成本始终是 standard 的 2 倍
prop_priority_double() ->
    ?FORALL({InputTokens, OutputTokens},
            {pos_integer(), pos_integer()},
        begin
            Base = #{
                model => <<"claude-sonnet-4-20250514">>,
                input_tokens => InputTokens,
                output_tokens => OutputTokens,
                account_rate_mult => 1.0,
                group_rate_mult => 1.0
            },
            {ok, Std} = ersub_clips_worker:calculate_billing(
                Base#{service_tier => standard}),
            {ok, Pri} = ersub_clips_worker:calculate_billing(
                Base#{service_tier => priority}),
            abs(maps:get(actual_cost, Pri) -
                maps:get(actual_cost, Std) * 2.0) < 0.0001
        end).

%% 属性：CIDR 匹配一致性
prop_cidr_consistency() ->
    ?FORALL(IP, ip_address(),
        begin
            %% 10.0.0.0/8 应该匹配所有 10.x.x.x
            case IP of
                {10, _, _, _} ->
                    ersub_ip_access:match_cidr(IP, {10,0,0,0}, 8) =:= true;
                _ ->
                    ersub_ip_access:match_cidr(IP, {10,0,0,0}, 8) =:= false
            end
        end).

ip_address() ->
    {range(0, 255), range(0, 255), range(0, 255), range(0, 255)}.
```

### 13.8 性能基准测试

```erlang
%% ersub_clips_bench.erl
-module(ersub_clips_bench).
-export([run/0]).

%% CLIPS Port 调用延迟基准
run() ->
    {ok, _} = ersub_clips_pool:start_link(#{pool_size => 4}),
    Candidates = generate_candidates(20),
    Weights = default_weights(),

    %% 预热
    [ersub_clips_worker:select_account(Candidates, Weights, 7)
     || _ <- lists:seq(1, 100)],

    %% 测量
    N = 1000,
    {Time, _} = timer:tc(fun() ->
        [ersub_clips_worker:select_account(Candidates, Weights, 7)
         || _ <- lists:seq(1, N)]
    end),
    AvgUs = Time / N,
    io:format("CLIPS select_account: ~.1f μs/call (~.0f calls/s)~n",
              [AvgUs, 1_000_000 / AvgUs]),

    %% 并发基准
    {ConcTime, _} = timer:tc(fun() ->
        Parent = self(),
        Pids = [spawn_link(fun() ->
            [ersub_clips_worker:select_account(Candidates, Weights, 7)
             || _ <- lists:seq(1, N div 10)],
            Parent ! {done, self()}
        end) || _ <- lists:seq(1, 10)],
        [receive {done, P} -> ok end || P <- Pids]
    end),
    ConcAvg = ConcTime / N,
    io:format("CLIPS concurrent (10 workers): ~.1f μs/call~n", [ConcAvg]),

    ersub_clips_pool:stop().
```

### 13.9 测试数据工厂

对标 sub2api 的 `fixtures_integration_test.go` 中的 `must*` 命名规范。

```erlang
%% ersub_test_fixtures.erl
-module(ersub_test_fixtures).
-export([
    must_create_user/2,
    must_create_account/2,
    must_create_group/2,
    must_create_api_key/2,
    must_create_channel/2,
    must_bind_account_to_group/3,
    must_create_subscription/2,
    must_create_redeem_code/2
]).

%% 创建用户（失败则 ct:fail）
must_create_user(Conn, Overrides) ->
    Defaults = #{
        email => iolist_to_binary([<<"test-">>,
            integer_to_binary(erlang:unique_integer([positive])),
            <<"@test.com">>]),
        password_hash => <<"$2b$10$test_hash">>,
        role => <<"user">>,
        balance_usd => 100.0,
        max_concurrency => 5
    },
    Attrs = maps:merge(Defaults, Overrides),
    case ersub_repo:create_user(Conn, Attrs) of
        {ok, User} -> User;
        {error, Reason} -> ct:fail({create_user_failed, Reason})
    end.

%% 创建账户
must_create_account(Conn, Overrides) ->
    Defaults = #{
        name => iolist_to_binary([<<"account-">>,
            integer_to_binary(erlang:unique_integer([positive]))]),
        platform => claude,
        account_type => api_key,
        credentials => #{<<"api_key">> => <<"sk-test-key">>},
        status => active,
        priority => 100,
        concurrency => 5,
        schedulable => true
    },
    Attrs = maps:merge(Defaults, Overrides),
    case ersub_repo:create_account(Conn, Attrs) of
        {ok, Account} -> Account;
        {error, Reason} -> ct:fail({create_account_failed, Reason})
    end.

%% 创建 API Key
must_create_api_key(Conn, Overrides) ->
    Defaults = #{
        key_hash => base64:encode(crypto:strong_rand_bytes(32)),
        key_prefix => <<"sk-test-">>,
        name => <<"test-key">>,
        is_active => true
    },
    Attrs = maps:merge(Defaults, Overrides),
    case ersub_repo:create_api_key(Conn, Attrs) of
        {ok, Key} -> Key;
        {error, Reason} -> ct:fail({create_api_key_failed, Reason})
    end.

%% 绑定账户到分组
must_bind_account_to_group(Conn, AccountId, GroupId) ->
    case ersub_repo:bind_account_to_group(Conn, AccountId, GroupId) of
        ok -> ok;
        {error, Reason} -> ct:fail({bind_failed, Reason})
    end.
```

### 13.10 Mock 模式

对标 sub2api 的三种手写 mock 模式。

**模式 1：调用记录器（Record Calls）**

```erlang
%% 对标 sub2api 的 mockTempUnscheduler
-module(ersub_mock_scheduler_cache).
-behaviour(gen_server).
-export([start_link/0, get_calls/1, reset/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    {ok, #{set_accounts => [], invalidated => []}}.

handle_cast({set_account, Account}, State) ->
    {noreply, State#{set_accounts => [Account | maps:get(set_accounts, State)]}};
handle_cast({invalidate, AccountId}, State) ->
    {noreply, State#{invalidated => [AccountId | maps:get(invalidated, State)]}}.

get_calls(Pid) ->
    gen_server:call(Pid, get_calls).

handle_call(get_calls, _From, State) ->
    {reply, State, State}.

%% 测试中使用：
%% {ok, MockCache} = ersub_mock_scheduler_cache:start_link(),
%% ... 执行被测代码 ...
%% Calls = ersub_mock_scheduler_cache:get_calls(MockCache),
%% ?assertEqual(1, length(maps:get(set_accounts, Calls))).
```

**模式 2：模拟上游 API 服务器**

```erlang
%% ersub_mock_upstream.erl
%% 启动一个本地 Cowboy 服务器，模拟 Claude/OpenAI API 响应

-module(ersub_mock_upstream).
-export([start/1, stop/0]).

start(Opts) ->
    Routes = [
        {"/v1/messages", ersub_mock_claude_handler,
         maps:get(claude_response, Opts, default_claude_response())},
        {"/v1/chat/completions", ersub_mock_openai_handler,
         maps:get(openai_response, Opts, default_openai_response())}
    ],
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    {ok, _} = cowboy:start_clear(mock_upstream, [{port, 19090}],
        #{env => #{dispatch => Dispatch}}).

stop() ->
    cowboy:stop_listener(mock_upstream).

%% 可配置响应：正常、429、502、流式、延迟
default_claude_response() ->
    #{status => 200, body => #{
        type => <<"message">>,
        content => [#{type => <<"text">>, text => <<"Hello">>}],
        usage => #{input_tokens => 10, output_tokens => 5}
    }}.
```

**模式 3：meck 库动态 mock（可选）**

```erlang
%% 使用 meck 动态替换模块函数
mock_billing_test() ->
    meck:new(ersub_repo, [passthrough]),
    meck:expect(ersub_repo, get_user_balance, fun(_UserId) -> 100.0 end),

    Result = ersub_billing_srv:check_balance(1, 50.0),
    ?assertEqual(ok, Result),

    ?assertEqual(1, meck:num_calls(ersub_repo, get_user_balance, '_')),
    meck:unload(ersub_repo).
```

### 13.11 CI/CD 测试集成

**Makefile targets：**

```makefile
# Makefile

.PHONY: test test-unit test-integration test-e2e test-property bench

## 全量测试
test: test-unit test-integration

## 单元测试（eunit，无外部依赖）
test-unit:
	rebar3 eunit --dir=test/unit

## 集成测试（Common Test，需要 Docker）
test-integration:
	@echo "Starting test containers..."
	docker compose -f deploy/docker-compose.test.yml up -d postgres
	@sleep 3
	rebar3 ct --dir=test/integration --logdir=_build/test/logs
	docker compose -f deploy/docker-compose.test.yml down

## E2E 测试（需要运行中的 ersub 实例）
test-e2e:
	ERSUB_E2E_ENABLED=1 \
	ERSUB_BASE_URL=$(ERSUB_BASE_URL) \
	ERSUB_API_KEY=$(ERSUB_API_KEY) \
	rebar3 ct --dir=test/e2e

## 属性测试（PropEr）
test-property:
	rebar3 proper --dir=test/property -n 1000

## 性能基准
bench:
	rebar3 as test shell --eval "ersub_clips_bench:run(), init:stop()."

## 覆盖率报告
cover:
	rebar3 cover --verbose
	@echo "Coverage report: _build/test/cover/index.html"

## Dialyzer 类型检查
dialyzer:
	rebar3 dialyzer
```

**GitHub Actions CI：**

```yaml
# .github/workflows/ci.yml
name: CI

on: [push, pull_request]

jobs:
  unit-test:
    runs-on: ubuntu-latest
    container:
      image: erlang:26
    steps:
      - uses: actions/checkout@v4
      - run: rebar3 compile
      - run: rebar3 eunit --dir=test/unit
      - run: rebar3 dialyzer

  integration-test:
    runs-on: ubuntu-latest
    container:
      image: erlang:26
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_DB: ersub_test
          POSTGRES_PASSWORD: test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - name: Build CLIPS
        run: cd c_src && make
      - run: rebar3 ct --dir=test/integration
      - run: rebar3 cover --verbose

  property-test:
    runs-on: ubuntu-latest
    container:
      image: erlang:26
    steps:
      - uses: actions/checkout@v4
      - run: rebar3 proper --dir=test/property -n 500

  lint:
    runs-on: ubuntu-latest
    container:
      image: erlang:26
    steps:
      - uses: actions/checkout@v4
      - run: rebar3 dialyzer
      - run: rebar3 xref
```

### 13.12 测试覆盖率目标

| 层级 | sub2api 覆盖度 | ersub 目标 | 说明 |
|------|---------------|-----------|------|
| Service（业务逻辑） | ~104%（289 tests / 278 files） | ≥ 80% | CLIPS 规则 + Erlang 服务 |
| Repository（数据访问） | ~94%（87 / 93） | ≥ 80% | 事务隔离集成测试 |
| Handler（HTTP 层） | ~82%（73 / 89） | ≥ 70% | Cowboy handler 测试 |
| CLIPS 规则 | N/A | ≥ 90% | 核心决策逻辑，高覆盖 |
| 基础设施（pkg） | ~67%（38 / 57） | ≥ 60% | 工具模块 |

**覆盖率生成：**

```bash
rebar3 cover --verbose
# 输出 _build/test/cover/index.html
```

### 13.13 测试与 sub2api 的对齐矩阵

| sub2api 测试领域 | 测试文件数 | ersub 对标测试 |
|-----------------|-----------|---------------|
| 调度器评分算法 | 15+ | `ersub_scheduler_tests` + `ersub_scheduler_prop` |
| 计费计算 | 20+ | `ersub_billing_tests` + `ersub_billing_prop` |
| 配额检查与重置 | 8+ | `ersub_quota_tests` |
| OAuth 流程 | 8+ | `ersub_auth_SUITE` |
| 账户 CRUD | 10+ | `ersub_repo_SUITE` |
| API Key 管理 | 5+ | `ersub_repo_SUITE` |
| 并发控制 | 5+ | `ersub_concurrency_SUITE` |
| 流式 SSE 解析 | 5+ | `ersub_stream_fsm` eunit |
| 模型映射 | 3+ | `ersub_model_mapping_tests` |
| IP/CIDR 匹配 | 3+ | `ersub_ip_access_tests` + `ersub_cidr_prop` |
| URL 校验/SSRF | 3+ | `ersub_url_validator_tests` |
| Claude Code 检测 | 2+ | `ersub_client_detector_tests` |
| 错误透传 | 2+ | `ersub_error_passthrough_tests` |
| 内容审核 | 2+ | `ersub_moderation_SUITE` |
| Channel + 定价 | 3+ | `ersub_channel_SUITE` |
| 支付 webhook | 3+ | `ersub_payment_SUITE` |
| 网关 E2E | 3 | `ersub_gateway_SUITE` / `ersub_openai_SUITE` |
| 返佣计算 | 2+ | `ersub_affiliate_tests` |
| 请求体限制 | 2+ | handler 集成测试 |
| Token 刷新 | 2+ | `ersub_token_refresh_SUITE` |
