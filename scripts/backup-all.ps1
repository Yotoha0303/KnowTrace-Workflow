$ErrorActionPreference = "Stop"
$projectDirectory = Split-Path -Parent $PSScriptRoot
Push-Location $projectDirectory
try {
  $knowledgeBackup = & (Join-Path $PSScriptRoot "backup.ps1")
  $authBackup = & (Join-Path $PSScriptRoot "backup-auth.ps1")

  $uploadBackup = $null
  $uploadDirectory = Join-Path $projectDirectory "data/uploads"
  if (Test-Path -LiteralPath $uploadDirectory) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $uploadBackup = Join-Path $projectDirectory "backups/knowtrace-uploads-$stamp.zip"
    Compress-Archive -LiteralPath $uploadDirectory -DestinationPath $uploadBackup -CompressionLevel Optimal
  }

  Write-Output "KnowTrace-Workflow PostgreSQL：$knowledgeBackup"
  Write-Output "go-user-system PostgreSQL：$authBackup"
  if ($uploadBackup) { Write-Output "证据图片：$uploadBackup" }
} finally {
  Pop-Location
}
