-- Fix Plan 5: balance history tracking
CREATE TABLE IF NOT EXISTS balance_history (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(id),
    amount      NUMERIC(12,6) NOT NULL,
    balance_after NUMERIC(12,6) NOT NULL,
    action      TEXT NOT NULL,
    note        TEXT,
    admin_id    BIGINT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_balance_history_user ON balance_history(user_id, created_at DESC);
