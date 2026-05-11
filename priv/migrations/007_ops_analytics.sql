-- Ops analytics tables for request tracking and windowed aggregation

CREATE TABLE IF NOT EXISTS ops_request_details (
    id          BIGSERIAL PRIMARY KEY,
    request_id  TEXT,
    user_id     BIGINT,
    account_id  BIGINT,
    model       TEXT,
    status_code INTEGER,
    latency_ms  INTEGER,
    tokens      INTEGER,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops_account_availability (
    id          BIGSERIAL PRIMARY KEY,
    account_id  BIGINT,
    is_available BOOLEAN,
    error_rate  FLOAT,
    checked_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops_window_stats (
    id              BIGSERIAL PRIMARY KEY,
    window_type     TEXT,
    dimension       TEXT,
    dimension_id    TEXT,
    request_count   INTEGER,
    error_count     INTEGER,
    total_tokens    BIGINT,
    total_cost      NUMERIC(12,8),
    window_start    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ops_request_details_created
    ON ops_request_details(created_at DESC);
