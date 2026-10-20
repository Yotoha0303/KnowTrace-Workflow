-- CI 夹具：主应用库（M5 修复 F9 第二层）
--
-- 目的：给 `pg_dump -Fc` 一个**非空、且有真实行**的库，让 dump 里有数据块。
-- 没有这个夹具，空 schema 的 dump 数据段极小，"数据区翻 1 字节"这类负向用例
-- 找不到可翻的位置（见 tests/ci/pg-dump-criteria/README 与变更记录）。
--
-- ⚠️ 本文件**不是**主应用的 schema 来源：schema 由 `drizzle/*.sql` 建（CI 里由
--    `python tests/ci/pg-dump-criteria/apply-drizzle.py` 应用）。这里只插数据。
--
-- 为什么是这几张表：它们是 `pg_stat_user_tables` 里最上游的三张——
-- `workspaces`（0020 迁移里预置了固定 UUID 的默认空间）、`categories`、`captures`。
-- `captures` 有 CHECK 约束（content 长度 1..20000、version > 0），
-- 夹具值刻意落在约束内：夹具自己违反约束会让「dump 判据」红在一个与 dump 无关的地方。

INSERT INTO "categories" ("name", "normalized_name", "description")
VALUES
  ('CI 夹具分类一', 'ci-fixture-category-1', 'M5 F9 dump 判据夹具'),
  ('CI 夹具分类二', 'ci-fixture-category-2', 'M5 F9 dump 判据夹具');

INSERT INTO "captures" (
  "title", "content", "idempotency_key", "idempotency_hash",
  "created_by_id", "created_by_name"
)
VALUES
  ('CI 夹具记录一', '第一条夹具内容，用于让 custom dump 含非空数据段。',
   'ci-fixture-key-1', repeat('a', 64), 'ci-fixture-owner', 'CI 夹具'),
  ('CI 夹具记录二', '第二条夹具内容。',
   'ci-fixture-key-2', repeat('b', 64), 'ci-fixture-owner', 'CI 夹具'),
  ('CI 夹具记录三', '第三条夹具内容。',
   'ci-fixture-key-3', repeat('c', 64), 'ci-fixture-owner', 'CI 夹具');

-- 关联表也插一行：让 TOC 里出现外键 / 复合主键这类对象，
-- 使 dump 的 TOC 条目数不至于少到让「截断 128B」只截掉 footer。
INSERT INTO "capture_categories" ("capture_id", "category_id")
SELECT c."id", k."id"
FROM "captures" c
CROSS JOIN "categories" k
WHERE c."idempotency_key" = 'ci-fixture-key-1'
  AND k."normalized_name" = 'ci-fixture-category-1';
