-- Channels (upstream endpoint configuration + pricing override)
CREATE TABLE IF NOT EXISTS channels (
    id                  BIGSERIAL PRIMARY KEY,
    name                TEXT NOT NULL,
    group_id            BIGINT NOT NULL REFERENCES groups(id),
    platform            TEXT NOT NULL,
    base_url            TEXT NOT NULL,
    model_mapping       JSONB,
    pricing_override    JSONB,
    allowed_models      JSONB,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
