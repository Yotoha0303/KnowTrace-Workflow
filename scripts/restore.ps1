param(
  [Parameter(Mandatory = $true)]
  [string]$BackupPath,
  [switch]$ConfirmDatabaseReset
)

$ErrorActionPreference = "Stop"
if (-not $ConfirmDatabaseReset) {
  throw "恢复会覆盖当前 KnowTrace-Workflow 数据库。确认后请加 -ConfirmDatabaseReset。"
}

$resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
if ([System.IO.Path]::GetExtension($resolvedBackup) -ne ".dump") {
  throw "只允许恢复由 backup.ps1 生成的 .dump 文件。"
}
if ((Get-Item -LiteralPath $resolvedBackup).Length -le 0) {
  throw "备份文件为空。"
}

$filename = "knowtrace-restore-$([guid]::NewGuid().ToString('N')).dump"
$containerPath = "/tmp/$filename"
$appStopped = $false

try {
  docker compose cp $resolvedBackup "postgres:$containerPath"
  if ($LASTEXITCODE -ne 0) { throw "无法把备份复制到数据库容器。" }

  docker compose exec -T postgres pg_restore --list $containerPath | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "备份格式校验失败。" }

  docker compose stop app
  if ($LASTEXITCODE -ne 0) { throw "无法停止应用容器。" }
  $appStopped = $true

  docker compose exec -T postgres pg_restore `
    --username=knowtrace_workflow `
    --dbname=postgres `
    --clean `
    --if-exists `
    --create `
    --no-owner `
    --no-privileges `
    $containerPath
  if ($LASTEXITCODE -ne 0) { throw "数据库恢复失败。" }
} finally {
  docker compose exec -T postgres rm -f $containerPath 2>$null
  if ($appStopped) { docker compose start app | Out-Null }
}

Write-Output "KnowTrace-Workflow 数据库已恢复：$resolvedBackup"
