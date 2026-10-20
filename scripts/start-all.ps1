param(
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$projectDirectory = Split-Path -Parent $PSScriptRoot
Push-Location $projectDirectory
try {
  & (Join-Path $PSScriptRoot "import-legacy-auth-env.ps1")
  & (Join-Path $PSScriptRoot "init-env.ps1")

  docker info *> $null
  if ($LASTEXITCODE -ne 0) { throw "Docker Desktop 尚未就绪。" }

  $legacyContainerIds = @(
    docker ps `
      --filter "label=com.docker.compose.project=go-user-system" `
      --format "{{.ID}}"
  ) | Where-Object { $_ }
  if ($legacyContainerIds.Count -gt 0) {
    Write-Output "检测到旧的独立 go-user-system Compose，正在停止容器并保留 Redis 数据卷以供统一栈复用。"
    docker stop $legacyContainerIds | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "无法停止旧的 go-user-system 容器。" }
  }

  foreach ($volumeName in @("go-user-system_redis_data")) {
    docker volume inspect $volumeName *> $null
    if ($LASTEXITCODE -ne 0) {
      docker volume create $volumeName | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "无法创建数据卷 $volumeName。" }
    }
  }

  $arguments = @("compose", "up", "-d", "--wait")
  if (-not $SkipBuild) { $arguments += "--build" }
  & docker $arguments
  if ($LASTEXITCODE -ne 0) { throw "统一 Compose 启动失败。" }

  $authReady = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8082/readyz"
  if ($authReady.StatusCode -ne 200) { throw "go-user-system 就绪检查失败。" }
  $appReady = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:3000/api/health/ready"
  if ($appReady.StatusCode -ne 200) { throw "KnowTrace-Workflow 就绪检查失败。" }

  docker compose ps
  Write-Output "KnowTrace-Workflow 统一栈已就绪：http://127.0.0.1:3000"
  # 2026-10-02 起管理员口令默认随机生成（见 scripts/init-env.ps1 的说明），
  # 所以这里不能再无条件打印一对固定凭据。
  $adminPassword = (Select-String -Path (Join-Path $projectDirectory ".env") -Pattern '^KNOWTRACE_ADMIN_PASSWORD=' |
    Select-Object -First 1).Line -replace '^KNOWTRACE_ADMIN_PASSWORD=', ''
  if ($adminPassword -eq 'KnowTrace-Workflow@123') {
    Write-Output "管理员凭据：KnowTrace-Workflow / KnowTrace-Workflow@123（固定值，仅本机开发；已在数据库改过密码时以数据库为准）。"
  } else {
    Write-Output "管理员口令为随机生成（不是 KnowTrace-Workflow@123）。查看方式（勿贴进聊天或日志）："
    Write-Output "  Select-String '^KNOWTRACE_ADMIN_' .env"
  }
} finally {
  Pop-Location
}
