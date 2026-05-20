# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

ErSub is an Erlang/OTP + CLIPS AI API gateway. It proxies Claude, OpenAI, Gemini, and other AI APIs to multiple users with authentication, billing, rate limiting, and load balancing. All business decisions (account scoring, billing, quota, routing, model dispatch) are delegated to a CLIPS rule engine running as an Erlang Port process, enabling runtime rule updates without restarts.

## Common Commands

```bash
# Build CLIPS C wrapper (required once before compile)
cd c_src && make && cd ..

# Compile Erlang
rebar3 compile

# Run unit tests only
rebar3 as test eunit --dir=test/unit

# Run integration tests (requires PostgreSQL)
rebar3 as test ct --dir=test/integration

# Run all tests
make test

# Type checking
rebar3 dialyzer

# Cross-reference check
rebar3 xref

# Start the server locally
make run

# Build production release
make release
```

The server starts on `http://localhost:8080`. On first run it auto-runs migrations, creates `admin@ersub.local` / `admin`, and logs the admin JWT to console.

## Architecture

### Request Flow

```
Cowboy HTTP → ersub_auth_middleware (API key/Bearer, ETS-cached 60s)
           → ersub_ip_access (CIDR blacklist/whitelist)
           → ersub_auth_middleware:check_group_assignment (CLIPS-validated)
           → ersub_rate_limiter (RPM sliding window, ETS)
           → ersub_concurrency_srv (per-user slot counters)
           → ersub_scheduler_srv (CLIPS-driven account selection)
           → ersub_request_transform (model name mapping, header rewrite)
           → ersub_stream_fsm / direct forward (gun HTTP/2 upstream)
           → ersub_billing_srv (CLIPS cost calc, async DB sync)
           → ersub_usage_logger (async write)
```

### CLIPS Integration

`ersub_clips_pool` (poolboy pool of `ersub_clips_worker` gen_servers) manages CLIPS Port processes. The Port uses NDJSON for IPC. Every business decision goes through `ersub_clips_pool`:

- `select_account/2` — multi-factor account scoring from `scheduling.clp`
- `calculate_billing/1` — cost from `billing.clp`
- `check_quota/1` — from `quota.clp`
- `get_platform_config/1` — per-platform settings from `platform_config.clp`
- `evaluate_account_status/1` — state machine from `account_status.clp`
- `resolve_model_route/1` — from `model_routing.clp`
- `filter_channels/1` — from `channel_filter.clp`

CLIPS rules live in `priv/clips/*.clp`. Custom overrides go in `priv/clips/custom/`. Reload at runtime: `POST /api/admin/clips/reload`.

### Key Modules by Layer

| Layer | Key Modules |
|-------|-------------|
| Gateway handlers | `ersub_claude_handler`, `ersub_openai_handler`, `ersub_openai_responses_handler`, `ersub_antigravity_handler`, `ersub_gemini_handler` |
| Streaming | `ersub_stream_fsm` (gen_statem: connecting → streaming → done) |
| Scheduling | `ersub_scheduler_srv` — 3-layer: PreviousResponseID → session sticky → CLIPS score |
| Auth | `ersub_auth_middleware` — ETS key cache, `ersub_auth_srv` — JWT/PBKDF2 |
| Billing | `ersub_billing_srv` — balance cache + circuit breaker, `ersub_billing_helper` |
| DB | `ersub_repo` — all SQL via `ersub_repo_pool` (poolboy over epgsql) |
| Config | `ersub_config_srv` — YAML loaded into persistent_term at startup |
| Admin REST | `ersub_admin_handler` (large, covers accounts/groups/channels/CLIPS reload) |
| Ops | `ersub_metrics_srv` (5min/1h/24h), `ersub_health_srv`, `ersub_ops_ws_handler` (WS dashboard) |

### OTP Supervision

`ersub_sup` (one_for_one) starts ~28 children in dependency order: config → DB pool → ETS-backed services → CLIPS pool → background workers. `ersub_platform_sup` dynamically manages per-account supervisors.

### Database

Migrations run automatically at startup via `ersub_migration:run()`. Migration files are `priv/migrations/NNN_*.sql`. There are currently 10 migrations (39 tables). Always add new migrations as numbered files; never alter existing ones.

## Key Conventions

- **Config access**: `ersub_config_srv:get(Key, Default)` — reads from persistent_term loaded at startup from `config/ersub.yaml` with `${ENV_VAR}` expansion.
- **DB queries**: Use `ersub_repo:query(SQL, Params)` (parameterized, never string-concat user input). Add new operations to `ersub_repo` following the existing export pattern.
- **CLIPS decisions**: Always go through `ersub_clips_pool` wrappers, never call `ersub_clips_worker` directly. Add new decisions to `ersub_clips_worker` with a matching wrapper in `ersub_clips_pool`.
- **JSON**: Use `jsx:encode/decode`. The pattern `jsx:decode(Body, [return_maps])` returns `#{binary() => any()}` maps.
- **Error replies**: `reply_json(StatusCode, #{error => #{type => ..., message => ...}}, Req)` — matching Anthropic error format.
- **Dialyzer**: `warnings_as_errors` is on. Add `-spec` to exported functions. Run `rebar3 dialyzer` before committing.

## Frontend

The SPA lives in `frontend/` and is built separately from the Erlang backend.

**Stack**: Vue 3 + TypeScript + Vite + Pinia + Tailwind CSS + vue-i18n + Vitest

```bash
cd frontend
npm install
npm run dev          # dev server (proxies API to localhost:8080)
npm run build        # production build → frontend/dist/
npm run typecheck    # vue-tsc --noEmit
npm test             # vitest
npm run test:coverage
```

**Structure**:
- `src/views/auth/` — Login, Register, OAuth/OIDC/WeChat/LinuxDo callbacks
- `src/views/user/` — Dashboard, API keys, subscriptions, usage, payment (Stripe / WeChat QR)
- `src/views/admin/` — Accounts, channels, groups, users, orders, Ops real-time dashboard
- `src/components/` — Domain-scoped components (account/, admin/monitor/, payment/, etc.)
- `src/composables/` — Reusable composition functions (useTableLoader, useAutoRefresh, etc.)
- `src/stores/` — Pinia stores
- `src/api/` — Axios-based API clients matching backend REST routes
- `src/i18n/locales/` — i18n locale files

In production, `make release` bundles the frontend into the Erlang release via `ersub_page_handler`. The `frontend/dist/` assets are served statically by Cowboy.

## Testing Patterns

- Unit tests: `test/unit/ersub_*_tests.erl` using EUnit + meck for mocking
- Integration tests: `test/integration/ersub_*_SUITE.erl` using Common Test, require live PostgreSQL
- Property tests: `test/property/` using PropEr (`rebar3_proper`)
- E2E tests: `test/e2e/` require a running server

Test profile adds `meck` and `proper` as deps and sets `nowarn_export_all`.

## Dependencies

- **cowboy 2.12** — HTTP server
- **gun 2.1** — HTTP/2 upstream client
- **jsx 3.1** — JSON
- **poolboy 1.5** — worker pools (DB, CLIPS)
- **epgsql 4.7** — PostgreSQL driver
- **yamerl 0.10** — YAML config parsing
- **jose 1.11** — JWT (HS256)
- **gproc 1.0** — process registry
