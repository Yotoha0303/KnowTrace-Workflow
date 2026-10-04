#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_DIRECTORY = Path(__file__).resolve().parents[2]


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        values[key.strip()] = value
    return values


def request(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    data: bytes | None = None,
    method: str | None = None,
    timeout: float = 8.0,
) -> tuple[int, bytes, dict[str, str]]:
    http_request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"User-Agent": "KnowTrace-observability-verify/1.0", **(headers or {})},
    )
    with urllib.request.urlopen(http_request, timeout=timeout) as response:
        response_headers = {
            key.lower(): value for key, value in response.headers.items()
        }
        return response.status, response.read(), response_headers


def get_json(url: str, *, headers: dict[str, str] | None = None) -> tuple[int, Any]:
    status, body, _ = request(url, headers=headers)
    return status, json.loads(body.decode("utf-8"))


def wait_http(name: str, url: str, attempts: int = 40, delay: float = 3.0) -> bytes:
    last_error: Exception | None = None
    for _ in range(attempts):
        try:
            status, body, _ = request(url)
            if 200 <= status < 300:
                print(f"PASS {name}: HTTP {status}")
                return body
            last_error = RuntimeError(f"HTTP {status}")
        except (OSError, ValueError, urllib.error.URLError) as error:
            last_error = error
        time.sleep(delay)
    raise RuntimeError(f"{name} 未就绪：{last_error}")


def prometheus_query(expression: str) -> list[dict[str, Any]]:
    query = urllib.parse.urlencode({"query": expression})
    _, payload = get_json(f"http://127.0.0.1:9090/api/v1/query?{query}")
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus 查询失败：{expression}")
    return payload.get("data", {}).get("result", [])


def wait_for_prometheus_targets(attempts: int = 30, delay: float = 3.0) -> None:
    last_unhealthy: list[dict[str, Any]] = []
    for _ in range(attempts):
        _, payload = get_json("http://127.0.0.1:9090/api/v1/targets")
        targets = payload.get("data", {}).get("activeTargets", [])
        last_unhealthy = [target for target in targets if target.get("health") != "up"]
        if len(targets) >= 12 and not last_unhealthy:
            print(f"PASS Prometheus targets: total={len(targets)} up={len(targets)}")
            return
        time.sleep(delay)
    details = [
        {
            "scrapeUrl": target.get("scrapeUrl"),
            "health": target.get("health"),
            "lastError": target.get("lastError"),
        }
        for target in last_unhealthy
    ]
    raise RuntimeError(f"Prometheus target 未全部 UP：{json.dumps(details, ensure_ascii=False)}")


def verify_core(values: dict[str, str]) -> None:
    wait_http("KnowTrace liveness", "http://127.0.0.1:3000/api/health/live")
    wait_http("KnowTrace readiness", "http://127.0.0.1:3000/api/health/ready")
    wait_http("Auth readiness", "http://127.0.0.1:8082/readyz")
    wait_http("Prometheus", "http://127.0.0.1:9090/-/ready")
    wait_http("Alertmanager", "http://127.0.0.1:9093/-/ready")
    wait_http("Grafana", "http://127.0.0.1:3001/api/health")

    metrics_token = values.get("METRICS_BEARER_TOKEN", "")
    status, body, headers = request(
        "http://127.0.0.1:3000/api/metrics",
        headers={"Authorization": f"Bearer {metrics_token}"},
    )
    metrics_text = body.decode("utf-8", errors="replace")
    if status != 200 or "knowtrace_build_info" not in metrics_text:
        raise RuntimeError("主应用受保护 metrics 端点缺少预期指标")
    if "text/plain" not in headers.get("content-type", ""):
        raise RuntimeError("主应用 metrics Content-Type 不正确")
    print("PASS KnowTrace protected metrics endpoint")

    try:
        request("http://127.0.0.1:8080/api/metrics")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        raise RuntimeError("Nginx 公网代理层没有屏蔽 /api/metrics")
    print("PASS Nginx blocks public metrics path with 404")

    wait_for_prometheus_targets()
    for expression in (
        "knowtrace_build_info",
        "knowtrace_database_ready == 1",
        "go_user_system_readiness == 1",
        "knowtrace_backup_archive_count >= 1",
        'probe_success{job="knowtrace-http-public"} == 1',
    ):
        if not prometheus_query(expression):
            raise RuntimeError(f"Prometheus 查询没有有效样本：{expression}")
        print(f"PASS PromQL: {expression}")

    _, alertmanagers = get_json("http://127.0.0.1:9090/api/v1/alertmanagers")
    active = alertmanagers.get("data", {}).get("activeAlertmanagers", [])
    if not active:
        raise RuntimeError("Prometheus 未发现 active Alertmanager")
    print(f"PASS Prometheus to Alertmanager discovery: active={len(active)}")

    basic = base64.b64encode(
        f"{values.get('GRAFANA_ADMIN_USER', 'admin')}:{values.get('GRAFANA_ADMIN_PASSWORD', '')}".encode()
    ).decode()
    grafana_headers = {"Authorization": f"Basic {basic}"}
    _, dashboards = get_json(
        "http://127.0.0.1:3001/api/search?query=KnowTrace%20VPS",
        headers=grafana_headers,
    )
    if not any(item.get("uid") == "knowtrace-vps-overview" for item in dashboards):
        raise RuntimeError("Grafana 没有加载 KnowTrace VPS dashboard")
    print("PASS Grafana provisioned dashboard: knowtrace-vps-overview")

    _, datasource = get_json(
        "http://127.0.0.1:3001/api/datasources/uid/prometheus",
        headers=grafana_headers,
    )
    if datasource.get("url") != "http://prometheus:9090":
        raise RuntimeError("Grafana Prometheus datasource 配置不正确")
    print("PASS Grafana provisioned Prometheus datasource")


def send_verification_log() -> str:
    event_id = f"stage3-{int(time.time())}"
    event = {
        "@timestamp": datetime.now(timezone.utc).isoformat(),
        "event_id": event_id,
        "level": "INFO",
        "message": "KnowTrace stage-three ELK verification event",
        "verification_source": "scripts/linux/verify-observability.py",
    }
    with socket.create_connection(("127.0.0.1", 5000), timeout=8) as connection:
        connection.sendall((json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8"))
    print(f"PASS Logstash TCP input accepted verification event: {event_id}")
    return event_id


def wait_for_log_event(event_id: str, attempts: int = 45, delay: float = 3.0) -> None:
    query = urllib.parse.urlencode({"q": f"event_id:{event_id}"})
    url = f"http://127.0.0.1:9200/knowtrace-logs-*/_search?{query}"
    for _ in range(attempts):
        try:
            _, payload = get_json(url)
            total = payload.get("hits", {}).get("total", {}).get("value", 0)
            if total >= 1:
                print(f"PASS Elasticsearch event search: hits={total} event_id={event_id}")
                return
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(delay)
    raise RuntimeError(f"Elasticsearch 中未找到验证事件：{event_id}")


def verify_elk() -> None:
    wait_http("Elasticsearch", "http://127.0.0.1:9200/_cluster/health")
    wait_http("Kibana", "http://127.0.0.1:5601/api/status", attempts=60, delay=5.0)
    wait_for_log_event(send_verification_log())

    _, policy = get_json("http://127.0.0.1:9200/_ilm/policy/knowtrace-logs-7d")
    if "knowtrace-logs-7d" not in policy:
        raise RuntimeError("Elasticsearch 缺少 7 天日志保留策略")
    print("PASS Elasticsearch ILM policy: knowtrace-logs-7d")

    _, saved_object = get_json(
        "http://127.0.0.1:5601/api/saved_objects/index-pattern/knowtrace-logs"
    )
    if saved_object.get("attributes", {}).get("title") != "knowtrace-logs-*":
        raise RuntimeError("Kibana 缺少 KnowTrace Logs data view")
    print("PASS Kibana data view: knowtrace-logs-*")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify KnowTrace stage-three observability")
    parser.add_argument("--core", action="store_true", help="verify metrics, Grafana and Alertmanager")
    parser.add_argument("--elk", action="store_true", help="verify on-demand ELK pipeline")
    args = parser.parse_args()
    if not args.core and not args.elk:
        parser.error("至少指定 --core 或 --elk")

    environment_path = PROJECT_DIRECTORY / ".env.observability"
    if not environment_path.exists():
        print(f"FAIL 缺少 {environment_path}", file=sys.stderr)
        return 1
    values = read_env(environment_path)

    try:
        if args.core:
            verify_core(values)
        if args.elk:
            verify_elk()
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1

    print("RESULT all requested observability checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
