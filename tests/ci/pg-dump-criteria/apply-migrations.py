#!/usr/bin/env python3
"""把仓库里的迁移 SQL 应用到 CI 的 PostgreSQL service 上。

支持两种来源（本 job 两个库各用其一）：

  drizzle（主应用，`drizzle/*.sql`）
      复刻 `scripts/migrate.mjs` 的两条解析规则：
        ① 迁移文件按文件名字典序应用（`0000_…` → `0021_…`）；
        ② 用 `--> statement-breakpoint` 切分语句，丢弃空段；
      ⚠️ **不**复刻 `knowtrace_migrations` 记账表——那是 drizzle 的幂等机制，
         与「dump 判据」无关，本 job 在一次性数据库上跑。

  goose（认证库，`services/go-user-system/migrations/*.sql`）
      只取 `-- +goose Up` 到 `-- +goose Down` 之间的内容，丢弃 Down 段
      （psql 不认识 goose 指令，但它只是注释；若不切掉 Down，`SELECT 1;` 之类会照跑，
      将来 Down 里出现 DROP 就会把刚建好的 schema 拆掉）。

用法：
  apply-migrations.py --check [--goose] <dir>
  apply-migrations.py [--goose] <dir> <database>

环境变量：PG_SERVICE_CONTAINER / PGUSER / PGPASSWORD / PGHOST_IN_CONTAINER / PGPORT_IN_CONTAINER
"""

import os
import re
import subprocess
import sys
from pathlib import Path

BREAKPOINT = "--> statement-breakpoint"
GOOSE_DOWN = re.compile(r"^\s*--\s*\+goose\s+Down\b", re.IGNORECASE)


def fail(message: str) -> None:
    print(f"FAIL apply-migrations: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_drizzle(path: Path) -> list[str]:
    content = path.read_text(encoding="utf-8")
    parts = [part.strip() for part in content.split(BREAKPOINT)]
    parts = [part for part in parts if part]
    if not parts:
        fail(f"{path.name} contains no statements")
    return parts


def read_goose(path: Path) -> list[str]:
    """返回该文件的 Up 段（原样，不切分号——函数体里会有分号）。"""
    lines = path.read_text(encoding="utf-8").splitlines()
    kept: list[str] = []
    for line in lines:
        if GOOSE_DOWN.match(line):
            break
        kept.append(line)
    body = "\n".join(kept).strip()
    if not body:
        fail(f"{path.name} has an empty Up section")
    return [body]


def collect(directory: Path, goose: bool) -> tuple[list[Path], list[str]]:
    if not directory.is_dir():
        fail(f"migration directory not found: {directory}")

    files = sorted(directory.glob("*.sql"))
    if not files:
        # 空分母不得判绿（AGENTS.md D3）
        fail(f"no *.sql files under {directory}")

    reader = read_goose if goose else read_drizzle
    statements: list[str] = []
    for path in files:
        statements.extend(reader(path))
    return files, statements


def main() -> None:
    arguments = sys.argv[1:]
    check_only = False
    goose = False
    while arguments and arguments[0].startswith("--"):
        flag = arguments.pop(0)
        if flag == "--check":
            check_only = True
        elif flag == "--goose":
            goose = True
        else:
            fail(f"unknown flag: {flag}")

    expected = 1 if check_only else 2
    if len(arguments) != expected:
        fail("usage: apply-migrations.py [--check] [--goose] <dir> [database]")

    directory = Path(arguments[0])
    flavor = "goose" if goose else "drizzle"
    files, statements = collect(directory, goose)

    if check_only:
        print(f"parsed {len(files)} {flavor} migrations, {len(statements)} statement groups")
        for path in files:
            print(f"  {path.name}")
        print("APPLY_MIGRATIONS_CHECK=PASS")
        return

    database = arguments[1]
    container = os.environ.get("PG_SERVICE_CONTAINER", "")
    if not container:
        fail("PG_SERVICE_CONTAINER is not set")

    # 一次性喂给 psql：语句里允许含分号（DO 块、CHECK 里的正则、goose 的函数体），
    # 所以**不能**按分号再切，必须让 psql 自己解析。
    script = ";\n".join(statements) + ";\n"

    command = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={os.environ.get('PGPASSWORD', 'postgres')}",
        container,
        "psql",
        f"--host={os.environ.get('PGHOST_IN_CONTAINER', '127.0.0.1')}",
        f"--port={os.environ.get('PGPORT_IN_CONTAINER', '5432')}",
        f"--username={os.environ.get('PGUSER', 'postgres')}",
        f"--dbname={database}",
        "--no-psqlrc",
        "--set=ON_ERROR_STOP=1",
        "--single-transaction",
        "--quiet",
        "--file=-",
    ]

    print(f"applying {len(files)} {flavor} migrations to {database}")
    for path in files:
        print(f"  {path.name}")

    result = subprocess.run(command, input=script, text=True)
    if result.returncode != 0:
        fail(f"psql exited {result.returncode} while applying {flavor} schema to {database}")

    print(f"{flavor} schema applied to {database}")


if __name__ == "__main__":
    main()
