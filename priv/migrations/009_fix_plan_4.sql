-- Fix Plan 4: operations error tracking + payment plans
CREATE TABLE IF NOT EXISTS ops_request_errors (
    id              BIGSERIAL PRIMARY KEY,
    request_id      TEXT NOT NULL,
    user_id         BIGINT,
    account_id      BIGINT,
    platform        TEXT,
    model           TEXT,
    status_code     INTEGER,
    error_type      TEXT,
    error_message   TEXT,
    is_resolved     BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_at     TIMESTAMPTZ,
    resolved_by     BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ops_request_errors_created ON ops_request_errors(created_at DESC);

CREATE TABLE IF NOT EXISTS payment_plans (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    amount_usd      NUMERIC(12,6) NOT NULL,
    description     TEXT,
    features        JSONB,
    validity_days   INTEGER NOT NULL DEFAULT 30,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
