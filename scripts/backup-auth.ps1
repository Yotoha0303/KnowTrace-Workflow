param(
  [string]$DestinationDirectory = "backups/auth",
  # 认证库服务名 / 库名 / 用户名**刻意可配置**：它们由 compose 决定，而 compose 属 M4（切库）。
  # 默认值对应 ADR-0019 切库后的目标形态；切库前需要显式覆盖。
  [string]$ComposeService = $(if ($env:AUTH_POSTGRES_SERVICE) { $env:AUTH_POSTGRES_SERVICE } else { "auth-postgres" }),
  [string]$Database = $(if ($env:AUTH_POSTGRES_DB) { $env:AUTH_POSTGRES_DB } else { "go_user_system" }),
  [string]$DatabaseUser = $(if ($env:AUTH_POSTGRES_USER) { $env:AUTH_POSTGRES_USER } else { "go_user_system" })
)

$ErrorActionPreference = "Stop"
$projectDirectory = Split-Path -Parent $PSScriptRoot
$resolvedDestination = [System.IO.Path]::GetFullPath(
  [System.IO.Path]::Combine($projectDirectory, $DestinationDirectory)
)
$projectPrefix = $projectDirectory.TrimEnd(
  [System.IO.Path]::DirectorySeparatorChar,
  [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedDestination.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "认证备份目录必须位于 KnowTrace-Workflow 项目内。"
}

foreach ($value in @($ComposeService, $Database, $DatabaseUser)) {
  if ($value -notmatch '^[A-Za-z0-9_.-]+$') { throw "服务名/库名/用户名含未支持字符：$value" }
}

function Get-SHA256Hex([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
}

$runningServices = @(docker compose ps --status running --services)
if ($LASTEXITCODE -ne 0 -or $runningServices -notcontains $ComposeService) {
  throw "统一 Compose 的 $ComposeService 服务尚未运行。"
}

New-Item -ItemType Directory -Force -Path $resolvedDestination | Out-Null
$createdAt = (Get-Date).ToUniversalTime()
$stamp = $createdAt.ToString("yyyyMMdd-HHmmss")
$containerPath = "/tmp/go_user_system-$stamp.dump"
$backupPath = Join-Path $resolvedDestination "go_user_system-$stamp.dump"
$manifestPath = "$backupPath.manifest.json"

# --format=custom：与 scripts/linux/backup-all.sh 的 postgres.dump 同形（恢复端共用 pg_restore 路径）。
# 不加 --create：恢复端按「恢复到指定库」使用，与 verify-restore.sh 的 PG 段一致。
$dumpCommand = 'umask 077; pg_dump --username=' + $DatabaseUser + ' --dbname=' + $Database +
  ' --format=custom --no-owner --no-privileges --file=' + $containerPath

try {
  docker compose exec -T $ComposeService sh -c $dumpCommand
  if ($LASTEXITCODE -ne 0) { throw "go-user-system PostgreSQL 备份失败。" }

  # ⚠️ 四步校验的第 0 步（ADR-0019 §5.4(b)）：**可解析性**。
  # custom 格式是二进制：grep 不可用、`Length -le 0` 只挡 0 字节。
  # 被截断但非空的 dump 会让「容器内 sha256 == 主机 sha256」**完全成立** ——
  # 四步全绿，直到真恢复时才炸（AGENTS.md §8.1 ① 的 PG 版）。
  # 所以必须在**容器内、算 sha 之前**先让 pg_restore 解析一遍 TOC。
  $listCheck = docker compose exec -T $ComposeService pg_restore --list $containerPath
  if ($LASTEXITCODE -ne 0) { throw "认证库 dump 不可解析（pg_restore --list 失败）。" }
  if (@($listCheck | Where-Object { $_ -match '\S' }).Count -eq 0) {
    throw "认证库 dump 的 TOC 为空（pg_restore --list 无输出）。"
  }
  # --list 只读 TOC（文件头附近），**抓不到尾部截断**：实测尾部砍掉 128 字节时
  # `pg_restore --list` 仍 exit 0，而真实恢复才报「无法从输入文件中读取：文件的结尾」。
  # 故再全量读一遍数据块（--data-only 配 --file=/dev/null：解压+校验、不写库、**不连数据库**）。
  docker compose exec -T $ComposeService pg_restore --data-only --file=/dev/null $containerPath | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "认证库 dump 数据块不完整（全量读取失败）。" }

  $containerHash = ((docker compose exec -T $ComposeService sha256sum $containerPath) -split "\s+")[0].ToLowerInvariant()
  if ($LASTEXITCODE -ne 0 -or $containerHash -notmatch '^[0-9a-f]{64}$') {
    throw "无法校验容器内认证备份。"
  }

  docker compose cp "$($ComposeService):$containerPath" $backupPath
  if ($LASTEXITCODE -ne 0) { throw "无法复制认证备份文件。" }
  $file = Get-Item -LiteralPath $backupPath
  if ($file.Length -le 0) { throw "认证备份文件为空。" }
  $hostHash = Get-SHA256Hex $backupPath
  if ($hostHash -ne $containerHash) { throw "认证备份复制前后校验和不一致。" }

  $manifest = [ordered]@{
    schema_version = 1
    source = "knowtrace-unified-compose"
    database = $Database
    format = "pg_dump-custom"
    service = $ComposeService
    created_at_utc = $createdAt.ToString("o")
    application_commit = (git rev-parse HEAD 2>$null | Select-Object -First 1)
    file = $file.Name
    size_bytes = $file.Length
    sha256 = $hostHash
  }
  $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
  Write-Output $backupPath
} finally {
  docker compose exec -T $ComposeService rm -f $containerPath 2>$null
}
