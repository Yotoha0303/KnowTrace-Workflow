-- +goose Up
-- PostgreSQL 方言。两处不是机械替换：
--   1) `ADD COLUMN ... AFTER status` → **删掉 `AFTER`**（PG 无列序概念）
--   2) `MODIFY COLUMN family_id ... NOT NULL` → **必须两步**：
--      先回填 NULL（原 SQL 的 UPDATE 已做），再 `ALTER COLUMN ... SET NOT NULL`。
--      ⚠️ 不得并入一句——虽然当前库是空的能过，脚本会长期存在，
--         将来在**有 NULL 行**的真实数据上跑会失败。
ALTER TABLE users
    ADD COLUMN auth_version bigint NOT NULL DEFAULT 1;

ALTER TABLE refresh_tokens
    ADD COLUMN family_id varchar(64) NULL DEFAULT NULL,
    ADD COLUMN revoked_reason varchar(32) NULL DEFAULT NULL;

UPDATE refresh_tokens
SET family_id = jti
WHERE family_id IS NULL;

ALTER TABLE refresh_tokens
    ALTER COLUMN family_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_family_id ON refresh_tokens (family_id);

-- +goose Down
DROP INDEX IF EXISTS idx_refresh_tokens_family_id;

ALTER TABLE refresh_tokens
    DROP COLUMN IF EXISTS revoked_reason,
    DROP COLUMN IF EXISTS family_id;

ALTER TABLE users
    DROP COLUMN IF EXISTS auth_version;
