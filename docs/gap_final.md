# sub2api vs ersub — 最终功能差距表

> Phase 1+2+3 + CLIPS 迁移完成后的最终审计  
> sub2api: 265+ 端点, 274 服务文件 | ersub: ~40 端点, 79 模块

---

## CRITICAL — 阻塞生产使用

| # | 功能 | sub2api | ersub | 说明 |
|---|------|---------|-------|------|
| 1 | 错误透传规则 CRUD | `/api/v1/admin/error-passthrough-rules` 完整 CRUD | 表存在但无管理端点 | 运维调试必需 |
| 2 | Dashboard 快照 V2 | 单请求合并所有指标 | 分散在多个端点 | 管理员监控体验 |
| 3 | messages_dispatch 配置 | Group 级别模型映射管理 | 有 CLIPS 规则但无配置 UI/API | 多模型路由必需 |
| 4 | 账户 today-stats 缓存 | 30 秒缓存批量端点 | 无缓存层 | 仪表盘性能 |
| 5 | Idempotency 请求处理 | 完整状态跟踪+冲突检测 | 基础 ETS 缓存 | 重复请求防护 |
| 6 | TLS 指纹管理 | 创建/更新/删除/列表 | 表存在但无端点 | 凭证伪装保护 |

## HIGH — 重要功能缺失

| # | 功能 | sub2api | ersub | 说明 |
|---|------|---------|-------|------|
| 7 | 账户凭证轮换端点 | 25+ 端点 (exchange-code, refresh-tier 等) | 基础 CRUD | 账户生命周期管理 |
| 8 | 独立 OAuth Handler | LinuxDo/WeChat/OIDC/email 各有专用 handler | 通用 handler + config | 平台特定 OAuth 流程 |
| 9 | Admin 仪表盘缓存 | 查询缓存+快照缓存+趋势缓存 | 直接 SQL 查询 | 性能瓶颈 |
| 10 | 数据管理 (S3 备份) | S3 Profile CRUD + 备份任务管理 | 无 | 数据安全 |
| 11 | 自定义错误过滤 per 账户 | 规则仓库+优先级排序+匹配模式 | CLIPS 基础规则 | 可靠性控制 |
| 12 | 账户使用来源过滤 | passive/active 来源区分 | 无区分 | 精细使用分析 |
| 13 | 用户消息队列 + SSE ping | 串行化等待时 SSE ping 保活 | 基础串行化 | 连接保活 |
| 14 | 促销/兑换批量操作 | 批量创建/验证 | 单条操作 | 运营效率 |

## MEDIUM — 锦上添花

| # | 功能 | sub2api | ersub | 说明 |
|---|------|---------|-------|------|
| 15 | CodexCLI 强制执行 | UA 验证+ForceCodexCLI 标记 | 基础检测 | 客户端限制 |
| 16 | Channel 监控模板管理 | CRUD 端点 | 无 | 运维便利 |
| 17 | 定时测试计划管理 | CRUD 端点 | 有服务但无管理端点 | 运维便利 |
| 18 | 代理管理 CRUD | CRUD 端点 | 有表和探测但无管理端点 | 运维便利 |
| 19 | OpenAI Compact 模式 | /v1/responses/compact 路由 | 无 | OpenAI 特定功能 |
| 20 | 预热请求拦截 | 检测+Mock 响应 | 无 | 连接池优化 |
| 21 | 账户临时不可调度管理 | 状态恢复端点 | 有内部状态但无端点 | 运维便利 |
| 22 | Idempotency 清理服务 | 自动 24h TTL 过期 | 无自动清理 | 存储管理 |

## LOW — 边缘场景

| # | 功能 | sub2api | ersub | 说明 |
|---|------|---------|-------|------|
| 23 | 账户 notes/extra 使用 | 存储+检索+历史 | 字段存在但未使用 | 运维注释 |
| 24 | WebSearch 模拟 | 查询改写+响应合成 | 无 | Claude 兼容 |
| 25 | 通用快照缓存 | 时间序列快照抽象 | 无 | 性能基础设施 |
| 26 | TLS Profile 统一 | 配置文件合并 | 无 | 安全基础设施 |

---

## 缺失中间件

| 中间件 | sub2api | ersub | 优先级 |
|--------|---------|-------|--------|
| 请求体大小限制 | Content-Length 校验 + 413 响应 | cowboy read_body 参数 | LOW |
| Backend Mode Guard | admin bypass + 端点白名单 | 基础 check_backend_mode | MEDIUM |
| Group 分配检查 | 阻止无 group 的 key 使用 | 无 | MEDIUM |
| 平台强制路由 | /antigravity 强制 Claude/Gemini | 无 | LOW |
| Inbound 端点规范化 | 路径标准化 | 无 | LOW |

---

## 缺失缓存层

| 缓存 | sub2api | ersub | 优先级 |
|------|---------|-------|--------|
| Scheduler Cache | Write-through + 失效队列 | 无 | HIGH |
| Dashboard Query Cache | 30s TTL + 多类型 | 无 | HIGH |
| Account Today-Stats | 30s 批量缓存 | 无 | CRITICAL |
| Billing Snapshot | 只读隔离 | 无 | MEDIUM |
| API Key Auth Cache | 5 分钟分布式 TTL | 60s ETS | LOW |

---

## 数量对比

| 维度 | sub2api | ersub | 差距 |
|------|---------|-------|------|
| API 端点 | ~265 | ~40 | ~225 |
| 服务文件 | 274 | 79 | ~195 |
| 中间件 | 8+ | 3 | ~5 |
| 缓存层 | 5 | 1 (ETS) | 4 |
| CLIPS 规则 | 0 (全硬编码) | 15 文件, 43 规则 | ersub 优势 |
| 代码行数 | ~223,000 Go | ~14,000 Erlang | ersub 更精简 |
