# ErSub 快速上手指南

## 概述

ErSub 是一个基于 Erlang/OTP + CLIPS 规则引擎的 AI API 网关，可将 Claude、OpenAI、Gemini 等上游 AI 订阅分发给多个用户，支持认证、计费、限速和负载均衡。

本文档提供两种启动方式：**Docker（推荐，5 分钟）** 和 **源码构建**。

---

## 方式一：Docker 快速启动（推荐）

### 前置条件

- Docker Engine 24+
- Docker Compose v2

### 步骤

```bash
# 1. 克隆仓库
git clone https://github.com/pachulisk/ersub.git
cd ersub

# 2. 启动服务（自动构建镜像、初始化数据库、生成密钥）
cd deploy
docker compose up -d

# 3. 等待启动完成（约 1-2 分钟）
docker compose logs -f ersub
# 看到 "ErSub started on port 8080" 即可 Ctrl+C
```

服务启动后：

| 服务 | 地址 |
|------|------|
| ErSub 网关 | http://localhost:8080 |
| PostgreSQL | localhost:5432 |

**首次启动自动完成**：
- 运行 39 张表的数据库迁移
- 创建管理员账户 `admin@ersub.local` / `admin`
- 生成并打印管理员 JWT token 到日志

---

## 方式二：源码构建

### 前置条件

- Erlang/OTP 26+
- PostgreSQL 15+
- GCC + Make（用于编译 CLIPS C 扩展）

```bash
# macOS
brew install erlang postgresql gcc make

# Ubuntu/Debian
apt-get install erlang postgresql build-essential
```

安装 rebar3：

```bash
curl -sLo rebar3 https://s3.amazonaws.com/rebar3/rebar3 && chmod +x rebar3
sudo mv rebar3 /usr/local/bin/
```

### 构建与运行

```bash
# 1. 克隆仓库
git clone https://github.com/pachulisk/ersub.git
cd ersub

# 2. 编译 CLIPS C 扩展（仅需一次）
cd c_src && make && cd ..

# 3. 编译 Erlang 代码
rebar3 compile

# 4. 创建数据库
createdb ersub

# 5. 配置环境变量
export DB_USER=postgres
export DB_PASSWORD=your_password
export JWT_SECRET=$(openssl rand -hex 32)

# 6. （可选）覆盖其他配置
cp config/ersub.yaml config/ersub.local.yaml
# 编辑 config/ersub.local.yaml

# 7. 启动服务
make run
```

服务在 `http://localhost:8080` 启动，首次运行自动执行数据库迁移。

---

## 第一步：登录并获取管理员 Token

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@ersub.local","password":"admin"}' | jq -r '.token')

echo "管理员 Token: $TOKEN"
```

> **安全提示**：首次登录后请立即修改默认密码。

---

## 第二步：添加上游 AI 账户

ErSub 需要至少一个上游账户才能代理请求。

### 添加 Claude API Key 账户

```bash
curl -s -X POST http://localhost:8080/api/admin/accounts \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Claude 主账户",
    "platform": "claude",
    "account_type": "api_key",
    "credentials": {
      "api_key": "sk-ant-..."
    },
    "priority": 100
  }' | jq '.data.id'
```

### 添加 OpenAI API Key 账户

```bash
curl -s -X POST http://localhost:8080/api/admin/accounts \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "OpenAI 主账户",
    "platform": "openai",
    "account_type": "api_key",
    "credentials": {
      "api_key": "sk-..."
    },
    "priority": 100
  }' | jq '.data.id'
```

支持的平台：`claude`、`openai`、`gemini`、`bedrock`（AWS）、`vertex`（GCP）

---

## 第三步：创建用户 API Key

```bash
# 为当前用户（admin）创建 API key
API_KEY=$(curl -s -X POST http://localhost:8080/api/keys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"我的 API Key"}' | jq -r '.data.raw_key')

echo "API Key: $API_KEY"
# 格式: sk-ersub-xxxxxxxxxxxxxxxxxx
# 注意：raw_key 仅在创建时返回一次，请妥善保存
```

---

## 第四步：使用网关

将 API 请求中的端点和 key 替换为 ErSub 的即可，其余请求格式完全兼容原始 API。

### Claude

```bash
curl http://localhost:8080/v1/messages \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 256,
    "messages": [{"role": "user", "content": "你好，ErSub！"}]
  }'
```

### OpenAI

```bash
curl http://localhost:8080/openai/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello ErSub!"}]
  }'
```

### Gemini

```bash
curl http://localhost:8080/gemini/v1beta/models/gemini-2.0-flash:generateContent \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"contents": [{"parts": [{"text": "Hello ErSub!"}]}]}'
```

### 查询可用模型

```bash
curl http://localhost:8080/v1/models -H "x-api-key: $API_KEY" | jq '.data[].id'
```

---

## 管理后台（Web UI）

访问 `http://localhost:8080` 打开 Web 管理后台，使用管理员账户登录。

主要功能：
- **账户管理** — 添加/编辑上游 AI 账户
- **渠道管理** — 创建渠道并分配账户池
- **用户管理** — 管理用户、余额、并发限制
- **实时监控** — WebSocket 看板（请求量、错误率、TTFT）
- **用量统计** — 按用户/模型/渠道查看用量明细

---

## 常见配置

### 调整并发与限速

编辑 `config/ersub.yaml`：

```yaml
concurrency:
  default_user_max: 10      # 每用户最大并发请求数

scheduling:
  top_k: 7                  # 账户选择 Top-K 数量
  score_weights:
    priority: 1.0           # 优先级权重
    load: 1.0               # 负载权重
    error_rate: 0.8         # 错误率权重
```

修改配置后重启生效；CLIPS 规则可通过 API 热更新：

```bash
curl -X POST http://localhost:8080/api/admin/clips/reload \
  -H "Authorization: Bearer $TOKEN"
```

### 启用内容审核

```yaml
moderation:
  mode: "observe"           # off | observe | pre_block
  thresholds:
    harassment: 0.5
    hate: 0.5
```

---

## 健康检查

```bash
curl http://localhost:8080/health
# {"status":"ok","db":"ok","clips":"ok","accounts":1}
```

---

## 下一步

- 查看完整配置参考：[`config/ersub.yaml`](config/ersub.yaml)
- 了解 CLIPS 规则定制：[`priv/clips/`](priv/clips/)
- 阅读完整文档：[README_CN.md](README_CN.md)
