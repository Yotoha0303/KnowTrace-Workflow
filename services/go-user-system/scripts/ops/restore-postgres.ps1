[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupPath,
    [string]$ProjectDirectory = "",
    [string]$RestoreDatabase = "go_user_system_restore_test",
    [string]$ComposeProjectName = "",
    [string]$EvidenceDirectory = "",
    # 认证库在 compose 里的服务名 / 用户名。M4（切库）之前需显式覆盖。
    [string]$ComposeService = "postgres",
    [string]$DatabaseUser = "go_user_system",
    [switch]$ConfirmRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $ConfirmRestore) {
    throw "-ConfirmRestore is required"
}
if ($RestoreDatabase -notmatch '^[A-Za-z0-9_]+_restore_test$') {
    throw "RestoreDatabase must contain only letters, numbers, underscores and end with _restore_test"
}
foreach ($value in @($ComposeService, $DatabaseUser)) {
    if ($value -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "service/user contains unsupported characters: $value"
    }
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $composeArguments = @("compose", "--project-directory", $ProjectDirectory)
    if (-not [string]::IsNullOrWhiteSpace($ComposeProjectName)) {
        $composeArguments += @("--project-name", $ComposeProjectName)
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & docker @composeArguments @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "docker compose $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-ComposeWithInput {
    param(
        [Parameter(Mandatory)]
        [string]$InputText,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $composeArguments = @("compose", "--project-directory", $ProjectDirectory)
    if (-not [string]::IsNullOrWhiteSpace($ComposeProjectName)) {
        $composeArguments += @("--project-name", $ComposeProjectName)
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = $InputText | & docker @composeArguments @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "docker compose $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

Get-Command docker -ErrorAction Stop | Out-Null
if ([string]::IsNullOrWhiteSpace($ProjectDirectory)) {
    $ProjectDirectory = Join-Path $PSScriptRoot "../.."
}
$ProjectDirectory = (Resolve-Path $ProjectDirectory).Path
$BackupPath = (Resolve-Path $BackupPath).Path
$manifestPath = "$BackupPath.manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "backup manifest is required: $manifestPath"
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
# dump 文件名里仍带 go_user_system；数据库字段是源库名，恢复目标是 $RestoreDatabase。
if ($manifest.schema_version -ne 1 -or $manifest.database -ne "go_user_system") {
    throw "unsupported or invalid backup manifest"
}
$backupFile = Get-Item -LiteralPath $BackupPath
$backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $BackupPath).Hash.ToLowerInvariant()
if ($backupHash -ne $manifest.sha256.ToLowerInvariant() -or $backupFile.Length -ne $manifest.size_bytes) {
    throw "backup file does not match its manifest"
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $ProjectDirectory "artifacts/operations"
}
$EvidenceDirectory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null

$runningServices = @(Invoke-Compose -Arguments @("ps", "--status", "running", "--services"))
if ($runningServices -notcontains $ComposeService) {
    throw "the Compose $ComposeService service is not running"
}

$startedAt = (Get-Date).ToUniversalTime()
$containerPath = "/tmp/go_user_system-restore-$($startedAt.ToString('yyyyMMdd-HHmmss')).dump"
# 维护连录用 postgres 库（与 scripts/check-go-integration-server-witness.mjs 同一口径）。
# ⚠️ 两条"按库"的读数都**必须连到目标库本身**去读：
#   PG 不支持跨库引用（`otherdb.public.t` 会直接报错），且 information_schema.tables
#   在维护库上看到的是**维护库自己**的表。
# ⚠️ DROP/CREATE DATABASE 不能在一个 -c 里用分号连写：psql 会把多语句当隐式事务块，
#   PG 报 "DROP DATABASE cannot run inside a transaction block"。故拆成两条 -Command。
$adminArguments = @("exec", "-T", $ComposeService, "psql", "--username=$DatabaseUser", "--dbname=postgres", "--no-psqlrc", "--tuples-only", "--no-align")
$drillArguments = @("exec", "-T", $ComposeService, "psql", "--username=$DatabaseUser", "--dbname=$RestoreDatabase", "--no-psqlrc", "--tuples-only", "--no-align")
$dropSql = "DROP DATABASE IF EXISTS $RestoreDatabase;"
$createSql = "CREATE DATABASE $RestoreDatabase OWNER $DatabaseUser;"
# goose 的 PG 版本表是 goose_db_version(version_id, is_applied, tstamp)；
# 「当前版本」= 已应用的最大 version_id，脚本/文件版本号须一致。
$tableCountSql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';"
$migrationVersionSql = "SELECT COALESCE(MAX(version_id), 0) FROM goose_db_version WHERE is_applied;"

try {
    Invoke-Compose -Arguments @("cp", $BackupPath, "$($ComposeService):$containerPath") | Out-Null

    # 先校验可解析与数据块完整，再动库（ADR-0019 §5.4(b)）：
    # --list 只读 TOC，抓不到尾部截断；--data-only 配 --file=/dev/null 全量读一遍数据块。
    $tocListing = @(Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "pg_restore", "--list", $containerPath))
    if (@($tocListing | Where-Object { $_ -match '\S' }).Count -eq 0) {
        throw "pg_restore --list produced no TOC entries: $containerPath"
    }
    Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "pg_restore", "--data-only", "--file=/dev/null", $containerPath) | Out-Null

    Invoke-ComposeWithInput -InputText $dropSql -Arguments $adminArguments | Out-Null
    Invoke-ComposeWithInput -InputText $createSql -Arguments $adminArguments | Out-Null
    Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "pg_restore",
        "--username=$DatabaseUser", "--dbname=$RestoreDatabase",
        "--no-owner", "--no-privileges", "--exit-on-error", $containerPath) | Out-Null

    $tableCount = ((Invoke-ComposeWithInput -InputText $tableCountSql -Arguments $drillArguments) | Select-Object -Last 1).Trim()
    $migrationVersion = ((Invoke-ComposeWithInput -InputText $migrationVersionSql -Arguments $drillArguments) | Select-Object -Last 1).Trim()
    if ([int]$tableCount -le 0 -or [int64]$migrationVersion -le 0) {
        throw "restored database validation failed: tables=$tableCount migration=$migrationVersion"
    }

    $completedAt = (Get-Date).ToUniversalTime()
    $evidence = [ordered]@{
        schema_version      = 1
        status              = "passed"
        source_backup       = $backupFile.Name
        source_sha256       = $backupHash
        restore_database    = $RestoreDatabase
        compose_service     = $ComposeService
        application_user    = $DatabaseUser
        started_at_utc      = $startedAt.ToString("o")
        completed_at_utc    = $completedAt.ToString("o")
        duration_seconds    = [math]::Round(($completedAt - $startedAt).TotalSeconds, 3)
        table_count         = [int]$tableCount
        migration_version   = [int64]$migrationVersion
    }
    $evidencePath = Join-Path $EvidenceDirectory "restore-drill-$($completedAt.ToString('yyyyMMdd-HHmmss')).json"
    $evidence | ConvertTo-Json | Set-Content -LiteralPath $evidencePath -Encoding utf8

    [pscustomobject]@{
        RestoreDatabase  = $RestoreDatabase
        TableCount       = [int]$tableCount
        MigrationVersion = [int64]$migrationVersion
        DurationSeconds  = $evidence.duration_seconds
        EvidencePath     = $evidencePath
    } | Format-List
}
finally {
    try {
        Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "rm", "-f", $containerPath) | Out-Null
    }
    catch {
        Write-Warning "failed to remove temporary restore file: $($_.Exception.Message)"
    }
}
