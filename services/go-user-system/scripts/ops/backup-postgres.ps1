[CmdletBinding()]
param(
    [string]$ProjectDirectory = "",
    [string]$OutputDirectory = "",
    [string]$ComposeProjectName = "",
    # 认证库在 compose 里的服务名 / 库名 / 用户名。M4（切库）之前需显式覆盖。
    [string]$ComposeService = "postgres",
    [string]$Database = "go_user_system",
    [string]$DatabaseUser = "go_user_system"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

foreach ($value in @($ComposeService, $Database, $DatabaseUser)) {
    if ($value -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "service/database/user contains unsupported characters: $value"
    }
}

Get-Command docker -ErrorAction Stop | Out-Null
if ([string]::IsNullOrWhiteSpace($ProjectDirectory)) {
    $ProjectDirectory = Join-Path $PSScriptRoot "../.."
}
$ProjectDirectory = (Resolve-Path $ProjectDirectory).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $ProjectDirectory "backups"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null

$runningServices = @(Invoke-Compose -Arguments @("ps", "--status", "running", "--services"))
if ($runningServices -notcontains $ComposeService) {
    throw "the Compose $ComposeService service is not running"
}

$createdAt = (Get-Date).ToUniversalTime()
$stamp = $createdAt.ToString("yyyyMMdd-HHmmss")
$containerPath = "/tmp/go_user_system-$stamp.dump"
$backupPath = Join-Path $OutputDirectory "go_user_system-$stamp.dump"
$manifestPath = "$backupPath.manifest.json"
$dumpCommand = 'umask 077; pg_dump --username=' + $DatabaseUser + ' --dbname=' + $Database +
    ' --format=custom --no-owner --no-privileges --file=' + $containerPath

try {
    Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "sh", "-c", $dumpCommand) | Out-Null

    # 可解析性必须先于 sha256 往返（ADR-0019 §5.4(b)）：
    # custom 格式是二进制，截断但非空的 dump 能让「容器哈希 == 主机哈希」完全成立。
    $tocListing = @(Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "pg_restore", "--list", $containerPath))
    if (@($tocListing | Where-Object { $_ -match '\S' }).Count -eq 0) {
        throw "pg_restore --list produced no TOC entries: $containerPath"
    }
    # --list 只读 TOC，抓不到尾部截断；再全量读数据块（--file=/dev/null：不写库、不连数据库）。
    Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "pg_restore", "--data-only", "--file=/dev/null", $containerPath) | Out-Null

    $containerHashOutput = @(Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "sha256sum", $containerPath))
    $containerHash = (($containerHashOutput -join " ") -split "\s+")[0].ToLowerInvariant()
    if ($containerHash -notmatch '^[0-9a-f]{64}$') {
        throw "unexpected container checksum output: $containerHash"
    }

    Invoke-Compose -Arguments @("cp", "$($ComposeService):$containerPath", $backupPath) | Out-Null
    $file = Get-Item -LiteralPath $backupPath
    if ($file.Length -le 0) {
        throw "backup file is empty: $backupPath"
    }
    $hostHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash.ToLowerInvariant()
    if ($hostHash -ne $containerHash) {
        throw "backup checksum mismatch between container and host"
    }

    $commit = "unknown"
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $gitCommand) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $commitOutput = & $gitCommand.Source -C $ProjectDirectory rev-parse HEAD 2>$null
            $gitExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($gitExitCode -eq 0) {
            $commit = ($commitOutput | Select-Object -First 1).Trim()
        }
    }
    $manifest = [ordered]@{
        schema_version   = 1
        source           = "docker-compose"
        compose_project  = $ComposeProjectName
        database         = $Database
        format           = "pg_dump-custom"
        service          = $ComposeService
        created_at_utc   = $createdAt.ToString("o")
        application_commit = $commit
        file             = $file.Name
        size_bytes       = $file.Length
        sha256           = $hostHash
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8

    [pscustomobject]@{
        BackupPath   = $backupPath
        ManifestPath = $manifestPath
        SizeBytes    = $file.Length
        SHA256       = $hostHash
    } | Format-List
}
finally {
    try {
        Invoke-Compose -Arguments @("exec", "-T", $ComposeService, "rm", "-f", $containerPath) | Out-Null
    }
    catch {
        Write-Warning "failed to remove temporary container backup: $($_.Exception.Message)"
    }
}
