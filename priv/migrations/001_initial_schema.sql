-- ErSub Initial Schema
-- Covers: users, accounts, api_keys, groups, relations, subscriptions,
--          usage_logs, payment_orders, settings, auth_identities

-- Users
CREATE TABLE IF NOT EXISTS users (
    id              BIGSERIAL PRIMARY KEY,
    email           TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'user',
    balance_usd     NUMERIC(12,6) NOT NULL DEFAULT 0,
    max_concurrency INTEGER NOT NULL DEFAULT 5,
    totp_secret     TEXT,
    totp_enabled    BOOLEAN NOT NULL DEFAULT FALSE,
    rpm_limit       INTEGER,
    is_banned       BOOLEAN NOT NULL DEFAULT FALSE,
    ban_reason      TEXT,
    balance_notify_enabled    BOOLEAN NOT NULL DEFAULT FALSE,
    balance_notify_threshold  NUMERIC(12,6),
    balance_notify_type       TEXT,
    notify_emails             JSONB,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_active
    ON users(email) WHERE deleted_at IS NULL;

-- Upstream accounts
CREATE TABLE IF NOT EXISTS accounts (
    id                  BIGSERIAL PRIMARY KEY,
    name                TEXT NOT NULL,
    platform            TEXT NOT NULL,
    account_type        TEXT NOT NULL,
    credentials         JSONB NOT NULL,
    status              TEXT NOT NULL DEFAULT 'active',
    priority            INTEGER NOT NULL DEFAULT 100,
    concurrency         INTEGER NOT NULL DEFAULT 5,
    load_factor         INTEGER,
    rate_multiplier     NUMERIC(8,4),
    schedulable         BOOLEAN NOT NULL DEFAULT TRUE,
    error_message       TEXT,
    rate_limited_until  TIMESTAMPTZ,
    overload_until      TIMESTAMPTZ,
    base_url            TEXT,
    notes               TEXT,
    expires_at          TIMESTAMPTZ,
    user_msg_queue_mode TEXT,
    last_used_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- API Keys
CREATE TABLE IF NOT EXISTS api_keys (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),
    key_hash        TEXT NOT NULL,
    key_prefix      TEXT NOT NULL,
    name            TEXT,
    max_concurrency INTEGER,
    rpm_limit       INTEGER,
    rate_limit_5h   INTEGER,
    ip_whitelist    JSONB,
    ip_blacklist    JSONB,
    allowed_models  TEXT[],
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    expires_at      TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_api_keys_hash_active
    ON api_keys(key_hash) WHERE deleted_at IS NULL;

-- Groups
CREATE TABLE IF NOT EXISTS groups (
    id                      BIGSERIAL PRIMARY KEY,
    name                    TEXT NOT NULL,
    platform                TEXT NOT NULL,
    billing_type            SMALLINT NOT NULL DEFAULT 0,
    rate_multiplier         NUMERIC(8,4) NOT NULL DEFAULT 1.0,
    daily_limit_usd         NUMERIC(12,6),
    weekly_limit_usd        NUMERIC(12,6),
    monthly_limit_usd       NUMERIC(12,6),
    rpm_limit               INTEGER DEFAULT 0,
    model_routing           JSONB,
    model_routing_enabled   BOOLEAN NOT NULL DEFAULT FALSE,
    claude_code_only        BOOLEAN NOT NULL DEFAULT FALSE,
    fallback_group_id       BIGINT REFERENCES groups(id),
    allow_image_generation  BOOLEAN NOT NULL DEFAULT FALSE,
    image_rate_independent  BOOLEAN NOT NULL DEFAULT FALSE,
    image_rate_multiplier   NUMERIC(8,4) DEFAULT 1.0,
    image_price_1k          NUMERIC(12,6),
    image_price_2k          NUMERIC(12,6),
    image_price_4k          NUMERIC(12,6),
    sort_order              INTEGER DEFAULT 0,
    account_filter          JSONB,
    messages_dispatch       TEXT,
    messages_dispatch_model_config JSONB,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Account-Group association
CREATE TABLE IF NOT EXISTS account_groups (
    account_id  BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    group_id    BIGINT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    PRIMARY KEY (account_id, group_id)
);

-- User-Group association
CREATE TABLE IF NOT EXISTS user_allowed_groups (
    user_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    group_id  BIGINT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, group_id)
);

-- User subscriptions
CREATE TABLE IF NOT EXISTS user_subscriptions (
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

-- Usage logs
CREATE TABLE IF NOT EXISTS usage_logs (
    id                      BIGSERIAL PRIMARY KEY,
    user_id                 BIGINT NOT NULL,
    api_key_id              BIGINT,
    account_id              BIGINT NOT NULL,
    group_id                BIGINT,
    subscription_id         BIGINT,
    request_id              TEXT NOT NULL,
    requested_model         TEXT NOT NULL,
    upstream_model          TEXT,
    input_tokens            INTEGER NOT NULL DEFAULT 0,
    output_tokens           INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens       INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens   INTEGER NOT NULL DEFAULT 0,
    input_cost              NUMERIC(12,8) NOT NULL DEFAULT 0,
    output_cost             NUMERIC(12,8) NOT NULL DEFAULT 0,
    cache_read_cost         NUMERIC(12,8) NOT NULL DEFAULT 0,
    cache_creation_cost     NUMERIC(12,8) NOT NULL DEFAULT 0,
    total_cost              NUMERIC(12,8) NOT NULL DEFAULT 0,
    actual_cost             NUMERIC(12,8) NOT NULL DEFAULT 0,
    rate_multiplier         NUMERIC(8,4),
    account_rate_multiplier NUMERIC(8,4),
    service_tier            TEXT,
    billing_mode            TEXT,
    billing_type            SMALLINT NOT NULL DEFAULT 0,
    billing_model_source    TEXT,
    model_mapping_chain     TEXT,
    request_type            SMALLINT NOT NULL DEFAULT 0,
    stream                  BOOLEAN NOT NULL DEFAULT FALSE,
    openai_ws_mode          BOOLEAN NOT NULL DEFAULT FALSE,
    duration_ms             INTEGER,
    first_token_ms          INTEGER,
    image_count             INTEGER DEFAULT 0,
    image_size              TEXT,
    image_output_cost       NUMERIC(12,8) DEFAULT 0,
    user_agent              TEXT,
    ip_address              INET,
    inbound_endpoint        TEXT,
    upstream_endpoint       TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_usage_logs_user_created
    ON usage_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_usage_logs_account_created
    ON usage_logs(account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_usage_logs_created
    ON usage_logs(created_at DESC);

-- Payment orders
CREATE TABLE IF NOT EXISTS payment_orders (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),
    provider        TEXT NOT NULL,
    amount_usd      NUMERIC(12,6) NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    provider_order_id TEXT,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Global settings
CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value       JSONB NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- OAuth identities
CREATE TABLE IF NOT EXISTS auth_identities (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(id),
    provider    TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(provider, provider_id)
);
