#!/usr/bin/env bash
# KnowTrace-Workflow 轻量交钥匙版一键拉起脚本 (deploy/lite/run-lite.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${PROJECT_ROOT}"

echo "=========================================================="
echo ">>> [KnowTrace Lite] 启动客户交钥匙轻量版 (4 核心容器)"
echo ">>> 架构：Single-Postgres + Redis + Go Auth + Next.js Web"
echo "=========================================================="

# 确保本地数据目录存在
mkdir -p data/uploads/evidence

# 校验 Docker 环境
if ! command -v docker &>/dev/null; then
    echo "错误：未检测到 Docker 环境，请先安装 Docker 和 Docker Compose。" >&2
    exit 1
fi

echo ">>> 正在构建并拉起精简容器组..."
docker compose -f compose.lite.yaml up -d --build

echo ">>> 等待核心微服务就绪..."
sleep 5

docker compose -f compose.lite.yaml ps

echo "=========================================================="
echo ">>> KnowTrace 轻量版启动完毕！"
echo ">>> Web 访问入口: http://localhost:3000"
echo ">>> 认证接口入口: http://localhost:8082"
echo ">>> 默认管理员: KnowTrace-Admin / KnowTrace@123456"
echo ">>> 停止运行命令: docker compose -f compose.lite.yaml down"
echo "=========================================================="
