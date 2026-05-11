# ErSub

**Erlang/OTP + CLIPS AI API Gateway** — a reimplementation of [sub2api](https://github.com/Wei-Shaw/sub2api) built for resilience, hot-reloadable business rules, and zero external state dependencies.

[中文文档](README_CN.md)

---

## What is ErSub?

ErSub is an AI API gateway that distributes upstream AI subscriptions (Claude, OpenAI, Gemini, etc.) to multiple users with authentication, billing, load balancing, and request proxying. Unlike traditional implementations that hardcode business logic, **ErSub delegates all decisions to a CLIPS rule engine**, enabling runtime rule updates without restarts.

### Key Differentiators

| Feature | Traditional (Go/sub2api) | ErSub (Erlang+CLIPS) |
|---------|------------------------|---------------------|
| Concurrency | goroutine + mutex + Redis | Process-per-connection, native isolation |
| Fault tolerance | Manual recovery | OTP supervision tree, let-it-crash |
| Business rules | Hardcoded in source | CLIPS rule files, hot-reloadable |
| State management | Redis (external) | ETS/counters/gen_server (built-in) |
| Streaming | SSE scanner + buffer pool | gen_statem state machine |
| Live updates | Restart required | Hot code reload + rule reload API |

---

## Architecture

```
Client → Cowboy HTTP/WS → Auth Middleware → Rate Limiter → Concurrency Control
    → CLIPS Scheduler (account selection) → Request Transform (model mapping)
    → Upstream Pool (gun HTTP/2) → SSE Stream FSM / Non-stream forward
    → CLIPS Billing (cost calculation) → Usage Logger → Response
```

### CLIPS Rule Engine Integration

All business decisions flow through the CLIPS engine via an Erlang Port:

| Decision | CLIPS Rule File | Templates |
|----------|----------------|-----------|
| Account scoring | `scheduling.clp` | candidate-account, score-weights, account-score |
| Cost calculation | `billing.clp` | usage, model-pricing, billing-result, tier-multiplier |
| Quota enforcement | `quota.clp` | subscription-quota, quota-violation |
| Status transitions | `account_status.clp` | account-event, account-status-update |
| Model routing | `model_routing.clp` | routing-request, model-route |
| Error passthrough | `error_passthrough.clp` | upstream-error, passthrough-rule |
| Content moderation | Via CLIPS pool | moderation-category thresholds |
| Refund validation | Via CLIPS pool | refund-request state machine |
| Model dispatch | Via CLIPS pool | dispatch-mapping cross-platform |

Rules are defined in `priv/clips/*.clp` and can be reloaded at runtime via `POST /api/admin/clips/reload`.

---

## Features

### Gateway Endpoints

| Endpoint | Protocol | Platform |
|----------|----------|----------|
| `POST /v1/messages` | Anthropic Messages API | Claude |
| `POST /openai/v1/chat/completions` | OpenAI Chat API | OpenAI |
| `POST /openai/v1/responses` | OpenAI Responses API | Codex CLI |
| `WS /openai/v1/realtime` | WebSocket v2 | OpenAI Realtime |
| `POST /openai/v1/images/generations` | Image Generation | DALL-E |
| `POST /openai/v1/images/edits` | Image Editing | DALL-E |
| `POST /gemini/v1beta/[...]` | Gemini API | Google Gemini |
| `POST /antigravity/v1/messages` | Antigravity Protocol | Claude Pro |
| `GET /v1/models` | Model Listing | All platforms |
| `GET /health` | Health Check | Internal |

### Account Types

- **API Key** — Static credentials for Claude, OpenAI, Gemini
- **OAuth** — Token refresh with automatic rotation (Claude, OpenAI, Gemini)
- **Setup Token** — Inference-only scope (Anthropic)
- **Bedrock** — AWS SigV4 signing for Amazon Bedrock
- **Service Account** — Google Vertex AI via JWT assertion
- **Upstream** — Relay to another gateway

### Billing (CLIPS-driven)

- Token-based, per-request, and image billing modes
- Service tier multipliers (priority 2x, flex 0.5x)
- Long-context surcharge (>272K tokens)
- Cache-tiered pricing (5min vs 1hour)
- Image resolution tiers (1K/2K/4K/HD)
- Circuit breaker for billing DB sync
- Billing deduplication (idempotent charges)

### Scheduling (CLIPS-driven)

- Multi-factor scoring: priority, load, queue depth, error rate, TTFT
- 3-layer selection: PreviousResponseID → Session sticky → CLIPS score
- Account pool mode (same-account retry before switching)
- Configurable top-K weighted random selection
- Runtime metrics (select_total, sticky_hit, load_skew)

### Security

- API Key authentication (SHA-256, ETS cached)
- JWT tokens (HS256) with configurable expiry
- PBKDF2-SHA256 password hashing (100K iterations)
- TOTP 2FA with QR code generation
- IP blacklist/whitelist (CIDR notation)
- SSRF prevention (private IP blocking, DNS rebinding protection)
- Content Security Policy with dynamic nonce
- Content moderation (13 risk categories, sampling, API key rotation)
- Idempotency-Key support

### Operations

- Real-time WebSocket dashboard (`/api/ops/ws`)
- Multi-granularity metrics (5min/1h/24h aggregation)
- Health scoring (DB + CLIPS + account components)
- Ops alert system with silence rules
- Scheduled account health testing with auto-recovery
- Channel monitoring with daily rollups
- Usage log cleanup with configurable retention
- CSV data export (usage, users)
- Advisory lock for aggregation deduplication

### Payment

- Stripe integration (checkout sessions, webhook verification)
- Alipay / WeChat Pay (scaffold, provider-pluggable)
- Redeem codes and promo codes
- Refund state machine (CLIPS-validated transitions)
- Payment resume tokens (HMAC-signed)
- Affiliate rebate system with ledger tracking

---

## Quick Start

### Prerequisites

- Erlang/OTP 26+
- PostgreSQL 15+
- CLIPS 6.4+ (built from source automatically)

### Build & Run

```bash
# Clone
git clone https://github.com/pachulisk/ersub.git
cd ersub

# Build CLIPS engine
cd c_src && make && cd ..

# Compile
rebar3 compile

# Configure
export DB_USER=your_user
export JWT_SECRET=your_secret
cp config/ersub.yaml config/ersub.local.yaml
# Edit config/ersub.local.yaml with your settings

# Run
make run
# Server starts on http://localhost:8080
```

### Docker

```bash
cd deploy
docker compose up -d
# ErSub: http://localhost:8080
# PostgreSQL: localhost:5432
```

### First Run

On first startup, ErSub automatically:
1. Runs database migrations (39 tables)
2. Creates admin user (`admin@ersub.local` / `admin`)
3. Generates admin JWT token (logged to console)

---

## Project Structure

```
ersub/
├── src/                    # 77 Erlang modules
│   ├── gateway/            # HTTP/WS handlers (Claude, OpenAI, Gemini, ...)
│   ├── scheduler/          # Account selection + CLIPS integration
│   ├── billing/            # Pricing, billing, quota, dedup, affiliate
│   ├── clips/              # CLIPS Port worker pool
│   ├── auth/               # JWT, OAuth, TOTP, AWS SigV4, GCP auth
│   ├── security/           # IP access, URL validator, CSP, CORS
│   ├── moderation/         # Content moderation pipeline
│   ├── channel/            # Channel management + pricing override
│   ├── ops/                # Health, metrics, alerts, monitoring
│   ├── payment/            # Stripe, Alipay, WeChat, redeem/promo
│   ├── admin/              # Admin/user REST handlers
│   ├── upstream/           # gun connection pool, proxy probe
│   ├── setup/              # First-run wizard
│   ├── config/             # YAML config + persistent_term
│   ├── db/                 # PostgreSQL repo + migrations
│   └── platform/           # Per-account supervisor
├── priv/
│   ├── clips/              # 7 CLIPS rule files (18 rules, 23 templates)
│   └── migrations/         # 5 SQL migration files (39 tables)
├── c_src/                  # CLIPS C wrapper (NDJSON Port protocol)
├── test/                   # 33 test files (88 tests)
├── config/                 # sys.config, vm.args, ersub.yaml
└── deploy/                 # Dockerfile, docker-compose, systemd
```

---

## OTP Supervision Tree

26 supervised children with automatic restart:

```
ersub_sup (one_for_one)
├── ersub_config_srv          # Configuration (persistent_term)
├── ersub_repo_pool           # PostgreSQL connection pool (poolboy)
├── ersub_session_srv         # Sticky session cache (ETS)
├── ersub_concurrency_srv     # Per-user concurrency slots (counters)
├── ersub_usage_logger        # Async usage log writer
├── ersub_rate_limiter        # RPM sliding window (ETS)
├── ersub_platform_sup        # Dynamic per-account supervisors
├── ersub_upstream_pool       # gun HTTP connection management
├── ersub_billing_srv         # Balance cache + circuit breaker
├── ersub_scheduler_srv       # CLIPS-driven account selection
├── ersub_auth_srv            # JWT + password hashing
├── ersub_channel_srv         # Channel pricing cache
├── ersub_quota_srv           # CLIPS-driven quota checking
├── ersub_clips_pool          # CLIPS Port worker pool (poolboy)
├── ersub_pricing_srv         # Model pricing (ETS + auto-update)
├── ersub_moderation_srv      # Content moderation pipeline
├── ersub_ops_alert_srv       # Alert rule evaluation
├── ersub_payment_srv         # Payment order lifecycle
├── ersub_token_refresh_srv   # OAuth token auto-refresh
├── ersub_affiliate_srv       # Affiliate rebate management
├── ersub_balance_notify_srv  # Low balance notifications
├── ersub_health_srv          # Health score calculation
├── ersub_metrics_srv         # Multi-granularity aggregation
├── ersub_usage_cleanup_srv   # Scheduled data cleanup
├── ersub_scheduled_test_srv  # Account health testing
└── ersub_channel_monitor     # Channel availability probes
```

---

## Configuration

Configuration is loaded from `config/ersub.yaml` with `${ENV_VAR}` substitution:

```yaml
server:
  host: "0.0.0.0"
  port: 8080

database:
  host: "localhost"
  port: 5432
  user: "${DB_USER}"
  password: "${DB_PASSWORD}"
  database: "ersub"

clips:
  pool_size: 8
  rules_dir: "priv/clips"

scheduling:
  sticky_session_ttl_s: 3600
  top_k: 7
  score_weights:
    priority: 1.0
    load: 1.0
    queue: 0.7
    error_rate: 0.8
    ttft: 0.5

moderation:
  mode: "off"          # off | observe | pre_block
  sample_rate: 100     # 0-100%
  thresholds:
    harassment: 0.5
    hate: 0.5
    sexual: 0.5
    violence: 0.5
```

See `config/ersub.yaml` for the full configuration reference.

---

## Testing

```bash
# Unit + property tests (88 tests)
rebar3 as test eunit --dir=test/unit --dir=test/property

# Integration tests (requires PostgreSQL)
rebar3 as test ct --dir=test/integration

# E2E tests (requires running server)
rebar3 as test ct --dir=test/e2e

# All tests
make test
```

---

## API Usage

### Create API Key

```bash
# Login as admin
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@ersub.local","password":"admin"}' | jq -r '.token')

# Create API key
curl -s -X POST http://localhost:8080/api/keys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-key"}' | jq '.data.raw_key'
```

### Use the Gateway

```bash
API_KEY="sk-ersub-..."

# Claude
curl http://localhost:8080/v1/messages \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-20250514","max_tokens":100,"messages":[{"role":"user","content":"Hello"}]}'

# OpenAI
curl http://localhost:8080/openai/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hello"}]}'

# List models
curl http://localhost:8080/v1/models -H "x-api-key: $API_KEY"
```

---

## License

Apache-2.0

---

## Acknowledgments

- [sub2api](https://github.com/Wei-Shaw/sub2api) — The Go reference implementation
- [CLIPS](https://www.clipsrules.net/) — Rule engine (6.4)
- [Cowboy](https://github.com/ninenines/cowboy) — HTTP server
- [gun](https://github.com/ninenines/gun) — HTTP client
- [poolboy](https://github.com/devinus/poolboy) — Worker pool
