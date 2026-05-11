-- Pending auth sessions for OAuth registration flow
CREATE TABLE IF NOT EXISTS pending_auth_sessions (
    id              BIGSERIAL PRIMARY KEY,
    session_token   TEXT UNIQUE NOT NULL,
    intent          TEXT NOT NULL DEFAULT 'signup',  -- signup | login | bind
    provider        TEXT NOT NULL,
    provider_id     TEXT,
    oauth_email     TEXT,
    oauth_display_name TEXT,
    oauth_avatar_url TEXT,
    completion_code TEXT,
    browser_key     TEXT,             -- CSRF prevention
    metadata        JSONB,
    expires_at      TIMESTAMPTZ NOT NULL,
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pending_auth_token ON pending_auth_sessions(session_token);

-- Identity adoption decisions
CREATE TABLE IF NOT EXISTS identity_adoption_decisions (
    id                  BIGSERIAL PRIMARY KEY,
    pending_session_id  BIGINT NOT NULL REFERENCES pending_auth_sessions(id),
    user_id             BIGINT REFERENCES users(id),
    adopt_display_name  BOOLEAN NOT NULL DEFAULT FALSE,
    adopt_avatar        BOOLEAN NOT NULL DEFAULT FALSE,
    action              TEXT NOT NULL,  -- create_new | merge | link | reject
    reason              TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- User fields extension
ALTER TABLE users ADD COLUMN IF NOT EXISTS signup_source TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS total_recharged NUMERIC(12,6) NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- Account extra JSONB
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS extra JSONB;
