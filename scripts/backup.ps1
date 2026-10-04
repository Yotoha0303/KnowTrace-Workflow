param(
  [string]$DestinationDirectory = "backups"
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
if (
  $resolvedDestination -ne $projectDirectory -and
  -not $resolvedDestination.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)
) {
  throw "备份目录必须位于 KnowTrace-Workflow 项目内。"
}

New-Item -ItemType Directory -Force -Path $resolvedDestination | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$nonce = [guid]::NewGuid().ToString("N").Substring(0, 8)
$filename = "knowtrace-$timestamp-$nonce.dump"
$localPath = Join-Path $resolvedDestination $filename
$containerPath = "/tmp/$filename"

try {
  docker compose exec -T postgres pg_dump `
    --username=knowtrace_workflow `
    --dbname=knowtrace_workflow `
    --format=custom `
    --create `
    --no-owner `
    --no-privileges `
    --file=$containerPath
  if ($LASTEXITCODE -ne 0) { throw "pg_dump 执行失败。" }

  docker compose exec -T postgres pg_restore --list $containerPath | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "备份校验失败。" }

  docker compose cp "postgres:$containerPath" $localPath
  if ($LASTEXITCODE -ne 0) { throw "无法复制备份文件。" }
  if (-not (Test-Path -LiteralPath $localPath) -or (Get-Item -LiteralPath $localPath).Length -le 0) {
    throw "备份文件为空。"
  }
} finally {
  docker compose exec -T postgres rm -f $containerPath 2>$null
}

Write-Output $localPath
