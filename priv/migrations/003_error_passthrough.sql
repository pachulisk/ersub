-- Error passthrough rules
CREATE TABLE IF NOT EXISTS error_passthrough_rules (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    status_codes    INTEGER[] NOT NULL,
    keywords        TEXT[],
    platform        TEXT,
    body_check_limit INTEGER NOT NULL DEFAULT 8192,
    action          TEXT NOT NULL DEFAULT 'passthrough',
    custom_body     JSONB,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
