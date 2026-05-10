-- Announcements
CREATE TABLE IF NOT EXISTS announcements (
    id              BIGSERIAL PRIMARY KEY,
    title           TEXT NOT NULL,
    content         TEXT NOT NULL,
    notify_mode     TEXT NOT NULL DEFAULT 'banner',
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Announcement reads
CREATE TABLE IF NOT EXISTS announcement_reads (
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    announcement_id BIGINT NOT NULL REFERENCES announcements(id) ON DELETE CASCADE,
    read_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, announcement_id)
);

-- Content moderation logs
CREATE TABLE IF NOT EXISTS moderation_logs (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL,
    api_key_id      BIGINT,
    request_id      TEXT NOT NULL,
    content_hash    TEXT NOT NULL,
    is_flagged      BOOLEAN NOT NULL,
    categories      JSONB NOT NULL,
    action_taken    TEXT,
    content_excerpt TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_moderation_logs_user
    ON moderation_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_logs_hash
    ON moderation_logs(content_hash);
