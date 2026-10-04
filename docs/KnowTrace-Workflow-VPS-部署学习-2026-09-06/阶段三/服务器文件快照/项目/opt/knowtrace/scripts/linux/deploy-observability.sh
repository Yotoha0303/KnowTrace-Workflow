#!/usr/bin/env bash
set -Eeuo pipefail

build_app=false
for argument in "$@"; do
  case "$argument" in
    --build-app) build_app=true ;;
    *)
      echo "用法：$0 [--build-app]" >&2
      exit 2
      ;;
  esac
done

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

exec 9>/run/knowtrace-observability.lock
flock -n 9 || {
  echo "错误：另一个可观测性部署正在运行。" >&2
  exit 1
}

[[ -f "$project_directory/.env" ]] || {
  echo "错误：缺少生产环境文件 $project_directory/.env" >&2
  exit 1
}
[[ -f "$project_directory/compose.production.yaml" ]] || {
  echo "错误：缺少 VPS 叠加文件 compose.production.yaml" >&2
  exit 1
}

available_kib="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
disk_available_kib="$(df --output=avail -k "$project_directory" | tail -n 1 | tr -d ' ')"
if (( available_kib < 500000 || disk_available_kib < 8000000 )); then
  echo "错误：核心监控预检不通过；至少需要 500 MiB 可用内存和 8 GiB 可用磁盘。" >&2
  free -h >&2
  df -h "$project_directory" >&2
  exit 1
fi

"$script_directory/init-observability-env.sh"
export KNOWTRACE_APP_REVISION="$(git -C "$project_directory" rev-parse HEAD 2>/dev/null || echo unknown)"
compose=(docker compose --project-directory "$project_directory" --env-file "$project_directory/.env" --env-file "$project_directory/.env.observability" -f "$project_directory/compose.yaml" -f "$project_directory/compose.production.yaml" -f "$project_directory/compose.observability.yaml")

"${compose[@]}" config --quiet
docker run --rm --entrypoint /bin/promtool \
  -v "$project_directory/deploy/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$project_directory/deploy/monitoring/rules:/etc/prometheus/rules:ro" \
  -v "$project_directory/runtime/prometheus:/etc/prometheus/secrets:ro" \
  quay.io/prometheus/prometheus:v3.5.5 \
  check config /etc/prometheus/prometheus.yml
docker run --rm --entrypoint /bin/amtool \
  -v "$project_directory/runtime/alertmanager:/etc/alertmanager:ro" \
  quay.io/prometheus/alertmanager:v0.28.1 \
  check-config /etc/alertmanager/alertmanager.json

echo "[1/5] 拉取固定版本的核心监控镜像"
"${compose[@]}" pull node-exporter blackbox-exporter alertmanager prometheus grafana

echo "[2/5] 让主应用加载私有 metrics token"
if [[ "$build_app" == true ]]; then
  "${compose[@]}" up -d --no-deps --build --wait --wait-timeout 900 app
else
  "${compose[@]}" up -d --no-deps --no-build --wait --wait-timeout 300 app
fi

echo "[3/5] 安装 Nginx metrics 公网阻断并保留原配置"
"$script_directory/install-observability-nginx.sh"

echo "[4/5] 启动 Alertmanager、Exporter、Prometheus 和 Grafana"
"${compose[@]}" up -d --no-build --wait --wait-timeout 600 \
  alertmanager node-exporter blackbox-exporter prometheus grafana

install -m 644 "$project_directory/deploy/systemd/knowtrace-backup.service" /etc/systemd/system/knowtrace-backup.service
install -m 644 "$project_directory/deploy/systemd/knowtrace-backup.timer" /etc/systemd/system/knowtrace-backup.timer
systemctl daemon-reload
systemctl enable --now knowtrace-backup.timer >/dev/null
"$script_directory/write-backup-metrics.sh"

echo "[5/5] 执行端点、target、PromQL、Alertmanager 和 Grafana provisioning 验收"
python3 "$script_directory/verify-observability.py" --core

echo "核心监控已部署；所有管理端口只绑定 127.0.0.1。"
