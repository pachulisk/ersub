-- Extended schema: affiliate, redeem, promo, proxy, TLS, scheduled tests,
-- channel monitors, billing dedup, ops alerts, payment extras, user attributes

-- Affiliate system
CREATE TABLE IF NOT EXISTS user_affiliates (
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

CREATE TABLE IF NOT EXISTS user_affiliate_ledger (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),
    action          TEXT NOT NULL,
    amount          NUMERIC(12,6) NOT NULL,
    related_user_id BIGINT,
    related_usage_id BIGINT,
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Redeem codes
CREATE TABLE IF NOT EXISTS redeem_codes (
    id          BIGSERIAL PRIMARY KEY,
    code        TEXT UNIQUE NOT NULL,
    amount_usd  NUMERIC(12,6) NOT NULL,
    is_used     BOOLEAN NOT NULL DEFAULT FALSE,
    used_by     BIGINT REFERENCES users(id),
    used_at     TIMESTAMPTZ,
    notes       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Promo codes
CREATE TABLE IF NOT EXISTS promo_codes (
    id              BIGSERIAL PRIMARY KEY,
    code            TEXT UNIQUE NOT NULL,
    discount_type   TEXT NOT NULL,
    discount_value  NUMERIC(12,6) NOT NULL,
    max_uses        INTEGER NOT NULL DEFAULT 0,
    current_uses    INTEGER NOT NULL DEFAULT 0,
    valid_from      TIMESTAMPTZ NOT NULL,
    valid_until     TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS promo_code_usage (
    id              BIGSERIAL PRIMARY KEY,
    promo_code_id   BIGINT NOT NULL REFERENCES promo_codes(id),
    user_id         BIGINT NOT NULL REFERENCES users(id),
    order_id        BIGINT REFERENCES payment_orders(id),
    used_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(promo_code_id, user_id)
);

-- Proxies
CREATE TABLE IF NOT EXISTS proxies (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    protocol        TEXT NOT NULL,
    host            TEXT NOT NULL,
    port            INTEGER NOT NULL,
    auth_user       TEXT,
    auth_pass       TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_probe_ms   INTEGER,
    last_probe_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- TLS fingerprint profiles
CREATE TABLE IF NOT EXISTS tls_fingerprint_profiles (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    ja3_hash    TEXT,
    user_agent  TEXT,
    headers     JSONB,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Scheduled tests
CREATE TABLE IF NOT EXISTS scheduled_tests (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    account_id      BIGINT NOT NULL REFERENCES accounts(id),
    model           TEXT NOT NULL,
    test_prompt     TEXT NOT NULL,
    interval_s      INTEGER NOT NULL DEFAULT 300,
    timeout_ms      INTEGER NOT NULL DEFAULT 30000,
    auto_recover    BOOLEAN NOT NULL DEFAULT FALSE,
    last_result     TEXT,
    last_run_at     TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Channel monitors
CREATE TABLE IF NOT EXISTS channel_monitors (
    id                  BIGSERIAL PRIMARY KEY,
    channel_id          BIGINT NOT NULL REFERENCES channels(id),
    check_interval_s    INTEGER NOT NULL DEFAULT 60,
    request_template_id BIGINT,
    expected_status     INTEGER NOT NULL DEFAULT 200,
    timeout_ms          INTEGER NOT NULL DEFAULT 10000,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS channel_monitor_histories (
    id              BIGSERIAL PRIMARY KEY,
    monitor_id      BIGINT NOT NULL REFERENCES channel_monitors(id),
    status_code     INTEGER,
    latency_ms      INTEGER,
    is_success      BOOLEAN NOT NULL,
    error_message   TEXT,
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS channel_monitor_daily_rollups (
    id              BIGSERIAL PRIMARY KEY,
    monitor_id      BIGINT NOT NULL REFERENCES channel_monitors(id),
    date            DATE NOT NULL,
    total_checks    INTEGER NOT NULL DEFAULT 0,
    success_count   INTEGER NOT NULL DEFAULT 0,
    avg_latency_ms  NUMERIC(10,2),
    p99_latency_ms  NUMERIC(10,2),
    UNIQUE(monitor_id, date)
);

CREATE TABLE IF NOT EXISTS channel_monitor_request_templates (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    method      TEXT NOT NULL DEFAULT 'POST',
    path        TEXT NOT NULL,
    headers     JSONB,
    body        JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Usage billing dedup
CREATE TABLE IF NOT EXISTS usage_billing_dedup (
    request_id  TEXT PRIMARY KEY,
    billed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS usage_billing_dedup_archive (
    request_id  TEXT PRIMARY KEY,
    billed_at   TIMESTAMPTZ NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ops alerts
CREATE TABLE IF NOT EXISTS ops_alert_rules (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    condition   JSONB NOT NULL,
    severity    TEXT NOT NULL DEFAULT 'warning',
    notify      JSONB NOT NULL DEFAULT '["email"]',
    cooldown_s  INTEGER NOT NULL DEFAULT 300,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops_alert_silences (
    id          BIGSERIAL PRIMARY KEY,
    rule_id     BIGINT REFERENCES ops_alert_rules(id),
    until       TIMESTAMPTZ NOT NULL,
    reason      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ops system logs
CREATE TABLE IF NOT EXISTS ops_system_logs (
    id          BIGSERIAL PRIMARY KEY,
    level       TEXT NOT NULL,
    source      TEXT NOT NULL,
    message     TEXT NOT NULL,
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ops_system_logs_created
    ON ops_system_logs(created_at DESC);

-- Payment audit logs
CREATE TABLE IF NOT EXISTS payment_audit_logs (
    id              BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES payment_orders(id),
    action          TEXT NOT NULL,
    idempotency_key TEXT UNIQUE,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Payment provider instances
CREATE TABLE IF NOT EXISTS payment_provider_instances (
    id              BIGSERIAL PRIMARY KEY,
    provider_type   TEXT NOT NULL,
    name            TEXT NOT NULL,
    config          JSONB NOT NULL,
    weight          INTEGER NOT NULL DEFAULT 1,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- User attributes
CREATE TABLE IF NOT EXISTS user_attribute_definitions (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT UNIQUE NOT NULL,
    data_type   TEXT NOT NULL,
    is_required BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_attribute_values (
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    attribute_id    BIGINT NOT NULL REFERENCES user_attribute_definitions(id) ON DELETE CASCADE,
    value           JSONB NOT NULL,
    PRIMARY KEY (user_id, attribute_id)
);

-- Security secrets
CREATE TABLE IF NOT EXISTS security_secrets (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT UNIQUE NOT NULL,
    secret_type TEXT NOT NULL,
    value       BYTEA NOT NULL,
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Metrics aggregated
CREATE TABLE IF NOT EXISTS metrics_aggregated (
    id              BIGSERIAL PRIMARY KEY,
    dimension_type  TEXT NOT NULL,
    dimension_id    TEXT NOT NULL,
    window_start    TIMESTAMPTZ NOT NULL,
    window_end      TIMESTAMPTZ NOT NULL,
    granularity     TEXT NOT NULL,
    request_count   INTEGER NOT NULL DEFAULT 0,
    error_count     INTEGER NOT NULL DEFAULT 0,
    total_tokens    BIGINT NOT NULL DEFAULT 0,
    total_cost_usd  NUMERIC(12,8) NOT NULL DEFAULT 0,
    avg_ttft_ms     NUMERIC(10,2),
    p99_latency_ms  NUMERIC(10,2),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_metrics_dim_window
    ON metrics_aggregated(dimension_type, dimension_id, window_start DESC);
