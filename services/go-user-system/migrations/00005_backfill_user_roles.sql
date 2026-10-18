-- +goose Up
-- PostgreSQL 方言：`INSERT IGNORE` → `ON CONFLICT DO NOTHING`；`NOW(3)` → `now()`。
-- ⚠️ 第二条同样是「无 ON 的 JOIN」⇒ 必须写 `CROSS JOIN`。
INSERT INTO user_roles (user_id, role_id, created_at)
SELECT u.id, r.id, now()
FROM users u
CROSS JOIN roles r
WHERE r.code = 'user'
ON CONFLICT DO NOTHING;

INSERT INTO user_roles (user_id, role_id, created_at)
SELECT first_user.id, r.id, now()
FROM (
    SELECT MIN(id) AS id
    FROM users
) AS first_user
CROSS JOIN roles r
WHERE r.code = 'admin'
  AND first_user.id IS NOT NULL
ON CONFLICT DO NOTHING;

-- +goose Down
-- Role backfill is intentionally not deleted on rollback because these rows may
-- have been modified by administrators after migration.
SELECT 1;
