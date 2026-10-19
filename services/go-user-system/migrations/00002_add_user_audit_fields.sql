-- +goose Up
-- PostgreSQL 方言：DATETIME(3) → timestamptz(3)；ADD INDEX → CREATE INDEX。
ALTER TABLE users
    ADD COLUMN last_login_at timestamptz(3) NULL DEFAULT NULL,
    ADD COLUMN deleted_at timestamptz(3) NULL DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON users (deleted_at);

-- +goose Down
DROP INDEX IF EXISTS idx_users_deleted_at;

ALTER TABLE users
    DROP COLUMN IF EXISTS deleted_at,
    DROP COLUMN IF EXISTS last_login_at;
