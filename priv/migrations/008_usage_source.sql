ALTER TABLE usage_logs ADD COLUMN IF NOT EXISTS usage_source TEXT DEFAULT 'active';
