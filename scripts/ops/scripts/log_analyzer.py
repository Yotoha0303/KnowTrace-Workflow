#!/usr/bin/env python3
"""日志错误模式分析与趋势对比（KnowTrace-Workflow 运维工具包）。

为什么用 Python 而不是 Bash
--------------------------
Bash 里 ``docker logs --since 168h app | grep -Ei "error|panic"`` 很好用，
但它只能回答「有没有」。本项目的周运维清单要求的是：

* 最近 7 天出现最多的错误是什么（聚类 + 计数 + 排序）；
* 和上周基线相比，**新出现**的高危模式是哪些（趋势，而不只是快照）；
* 把结果输出成可存档的 Markdown / JSON，附到 ``docs/日常运维/``。

这是「获取数据 → 解析 → 归一化 → 统计 → 排序 → 对比基线 → 输出」的数据流，
属于 Python 的职责范围（见 ``bash与pthon的运维使用建议.md`` 第 6 节）。

安全性说明
----------
* 只读：只调用 ``docker logs`` / 读本机日志文件，不重启、不删除任何容器。
* 不打印密钥：日志里出现 ``password=``、``token:`` 等键值时，值会被替换成 ``***``，
  再进入报告（见 :func:`redact_line`）。
* 归一是「去数字化」，只用于聚类计数，**原始行会保留在证据里**，且归一化后的
  模式串不含原始数字，避免把 IP、ID 写进报告。
* 基线对比只在同一台主机、同一组容器上进行；基线缺失时记 INFO，绝不把
  「没有基线」说成「没有新增异常」。

退出码：0=无异常  1=存在 WARN  2=存在 FAIL  3=脚本自身错误
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

from ops_common import (  # noqa: E402
    EXIT_ERROR,
    Report,
    add_common_arguments,
    die,
    emit_reports,
    environment_summary,
    have_command,
    human_bytes,
    load_ops_conf,
    parse_duration_seconds,
    parse_timestamp,
    run_readonly,
    utc_now,
    utc_now_iso,
)

# ---------------------------------------------------------------------------
# 归一化与脱敏
# ---------------------------------------------------------------------------

# 出现这些词的行属于「高危」，即使计数不多也要单独列出
_HIGH_SEVERITY = re.compile(
    r"\b(panic|fatal|oom|out of memory|segfault|crash|corrupt|"
    r"data loss|deadlock|refused|unavailable|unhealthy|"
    r"no space left|cannot allocate|permission denied)\b",
    re.IGNORECASE,
)

_LEVEL_ERROR = re.compile(r"\b(error|err|eror)\b", re.IGNORECASE)
_LEVEL_WARN = re.compile(r"\b(warn|warning)\b", re.IGNORECASE)

# 键值形式的敏感信息：只保留键，值替换掉
_SECRET_KV = re.compile(
    r"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|apikey|"
    r"authorization|auth|bearer|cookie|session|private[_-]?key|"
    r"mysql_pwd|postgres_password|pgpassword|jwt)\b\s*[:=]\s*\S+"
)
# URL 里的凭据 scheme://user:pass@host
_URL_CREDENTIALS = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@")

# 归一化用的替换表（顺序敏感：先长后短）
_NORMALIZERS: list[tuple[re.Pattern[str], str]] = [
    # ISO8601 / 常见时间戳
    (re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"), "<ts>"),
    (re.compile(r"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"), "<time>"),
    # IPv4 / IPv6（也避免把地址写进报告）
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "<ip>"),
    (re.compile(r"\b(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{1,4}\b"), "<ip6>"),
    # UUID
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    # 十六进制摘要（sha256/md5/etag）
    (re.compile(r"\b[0-9a-fA-F]{32,64}\b"), "<hash>"),
    # 端口、行号、耗时、字节数、计数
    (re.compile(r"(?i)\b(port|line|pid|inode|offset|took|duration|elapsed|latency|ms|bytes|length)\s*[:=]?\s*\d+"), r"\1=<n>"),
    (re.compile(r"\b\d+(?:\.\d+)?\s*(?:ms|us|ns|s|m|h|ki?b|mi?b|gi?b|bytes?)\b"), "<size>"),
    # 括号里的数字/十六进制（Node 栈常见 (file:line:col)）
    (re.compile(r":\d+:\d+\b"), ":<n>:<n>"),
    # 纯数字（剩下的都当噪声）
    (re.compile(r"\b\d+\b"), "<n>"),
]

_WHITESPACE = re.compile(r"\s+")


def redact_line(line: str) -> str:
    """把日志行里的敏感值替换成 ``***``，保留键名与整体结构。"""
    text = _URL_CREDENTIALS.sub(r"\1***:***@", line)
    text = _SECRET_KV.sub(lambda m: f"{m.group(1)}=***", text)
    return text


def normalize_line(line: str) -> str:
    """把一行日志归一化成可聚类的「模式」。

    归一化后**不含任何原始数字**，因此可以安全地写进报告。
    """
    text = redact_line(line)
    for pattern, replacement in _NORMALIZERS:
        text = pattern.sub(replacement, text)
    text = _WHITESPACE.sub(" ", text).strip()
    # 去掉 JSON 里常见的标点噪声，让相似行更容易合并
    text = text.strip(" \t,;")
    return text[:400]


def classify_line(line: str) -> str:
    """给一行定级：ERROR / WARN / OTHER。"""
    if _LEVEL_ERROR.search(line) or _HIGH_SEVERITY.search(line):
        return "ERROR"
    if _LEVEL_WARN.search(line):
        return "WARN"
    return "OTHER"


# ---------------------------------------------------------------------------
# 数据模型
# ---------------------------------------------------------------------------


@dataclass
class PatternStat:
    pattern: str
    container: str
    count: int = 0
    severity: str = "OTHER"
    sample: str = ""
    first_seen: datetime | None = None
    last_seen: datetime | None = None

    def to_row(self) -> list[str]:
        when = "-"
        if self.last_seen:
            when = self.last_seen.strftime("%m-%d %H:%M")
        return [self.severity, str(self.count), self.container, when, self.pattern[:110]]


@dataclass
class ContainerScan:
    name: str
    lines_scanned: int = 0
    lines_total_seen: int = 0
    truncated: bool = False
    parse_errors: int = 0
    window_start: datetime | None = None
    window_end: datetime | None = None
    patterns: dict[str, PatternStat] = field(default_factory=dict)
    note: str = ""


# ---------------------------------------------------------------------------
# 日志来源
# ---------------------------------------------------------------------------


def _docker_logs(container: str, *, window: str, max_lines: int) -> tuple[list[str], bool]:
    """取容器最近日志。

    返回 ``(行列表, 是否被截断)``。

    ⚠ ``docker logs`` 与 ``docker logs --since`` 都会先在**整个**日志流上跑
    正则匹配，再按 ``--tail`` 截断。所以只给 ``--tail`` 不给 ``--since`` 时，
    匹配的是全量历史、返回的是最旧的若干行 —— 那会把几周前的告警当成今天的。
    因此这里**始终带上 --since**，并且取尾部：
    ``docker logs --since <窗口> --tail <上限>`` 的两个过滤器是 AND 关系
    （实测于 Docker 29），结果确定是「窗口内最近的 N 行」。
    """
    argv = ["docker", "logs", "--since", window, "--tail", str(max_lines), container]
    result = run_readonly(argv, timeout=120.0)
    if not result.ok and not result.stdout:
        # 某些版本对 --tail 在容器启动前的时间窗会报错，退回不带 --tail
        retry = run_readonly(["docker", "logs", "--since", window, container], timeout=120.0)
        if not retry.ok and not retry.stdout:
            return [], False
        lines = (retry.stdout + retry.stderr).splitlines()
        return lines, len(lines) >= max_lines
    lines = (result.stdout + result.stderr).splitlines()
    return lines, len(lines) >= max_lines


def _read_file_tail(path: Path, max_lines: int) -> tuple[list[str], bool]:
    """读文件尾部 max_lines 行（大文件不回读整个文件）。"""
    if not path.is_file():
        return [], False
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            block = min(size, max(65536, max_lines * 512))
            handle.seek(size - block)
            data = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return [], False
    lines = data.splitlines()
    truncated = len(lines) > max_lines
    return lines[-max_lines:], truncated


# node/nginx 默认格式：``2026-09-28T10:20:21.123Z ...`` 或
# ``2026/09/28 10:20:21 [error] ...`` 或 caddy JSON ``{"ts":1758974421.5,...}``


def _extract_timestamp(line: str) -> datetime | None:
    """从行首尽力取时间戳；失败返回 None（不猜测）。"""
    head = line[:64]
    stamp = parse_timestamp(head.split(" ", 1)[0]) if head else None
    if stamp:
        return stamp
    # caddy / JSON 日志
    if head.lstrip().startswith("{"):
        try:
            payload = json.loads(line)
        except (ValueError, TypeError):
            return None
        for key in ("ts", "time", "timestamp", "@timestamp"):
            value = payload.get(key)
            if isinstance(value, (int, float)):
                return datetime.fromtimestamp(float(value), tz=timezone.utc)
            if isinstance(value, str):
                parsed = parse_timestamp(value)
                if parsed:
                    return parsed
    # ``2026/09/28 10:20:21``
    match = re.match(r"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})", head)
    if match:
        return parse_timestamp(match.group(1))
    return None


def scan_lines(name: str, lines: list[str], *, truncated: bool) -> ContainerScan:
    scan = ContainerScan(name=name, truncated=truncated, lines_scanned=len(lines))
    for raw in lines:
        scan.lines_total_seen += 1
        if not raw.strip():
            continue
        stamp = _extract_timestamp(raw)
        if stamp:
            if scan.window_start is None or stamp < scan.window_start:
                scan.window_start = stamp
            if scan.window_end is None or stamp > scan.window_end:
                scan.window_end = stamp
        else:
            scan.parse_errors += 1

        severity = classify_line(raw)
        if severity == "OTHER":
            continue

        pattern = normalize_line(raw)
        if not pattern:
            continue
        key = f"{severity}\x00{pattern}"
        stat = scan.patterns.get(key)
        if stat is None:
            stat = PatternStat(
                pattern=pattern,
                container=name,
                severity=severity,
                sample=redact_line(raw)[:300],
                first_seen=stamp,
                last_seen=stamp,
            )
            scan.patterns[key] = stat
        stat.count += 1
        if stamp:
            if stat.first_seen is None or stamp < stat.first_seen:
                stat.first_seen = stamp
            if stat.last_seen is None or stamp > stat.last_seen:
                stat.last_seen = stamp
    return scan


# ---------------------------------------------------------------------------
# 基线
# ---------------------------------------------------------------------------


def _baseline_path() -> Path:
    override = os.environ.get("OPS_LOG_BASELINE", "").strip()
    if override:
        return Path(override)
    return Path("/var/lib/knowtrace/log-baseline.json")


def load_baseline(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(payload, dict):
        return {}
    if payload.get("hostname") and payload["hostname"] != os.uname().nodename:
        # 不同主机的模式串不可比（容器名与路径可能相同但含义不同）
        return {}
    return payload


def save_baseline(path: Path, scans: list[ContainerScan], window: str) -> str:
    """把本次的模式集合写成基线，供下次做「新增模式」对比。

    只保存模式串与计数，**不保存原始日志行**，避免把敏感内容长期落盘。
    """
    patterns: dict[str, dict] = {}
    for scan in scans:
        for key, stat in scan.patterns.items():
            existing = patterns.get(stat.pattern)
            if existing is None:
                patterns[stat.pattern] = {
                    "severity": stat.severity,
                    "count": stat.count,
                    "containers": [scan.name],
                }
            else:
                existing["count"] += stat.count
                if scan.name not in existing["containers"]:
                    existing["containers"].append(scan.name)

    payload = {
        "schema": "knowtrace-log-baseline/1",
        "hostname": os.uname().nodename,
        "generated_at": utc_now_iso(),
        "window": window,
        "pattern_count": len(patterns),
        "patterns": patterns,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)
    except OSError as error:
        return f"基线写入失败: {error}"
    return ""


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="log_analyzer.py",
        description="KnowTrace-Workflow 日志错误模式分析与趋势对比（只读）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  ./scripts/log_analyzer.py --containers app,auth --since 168h\n"
            "  ./scripts/log_analyzer.py --files /var/log/nginx/knowtrace.error.log\n"
            "  ./scripts/log_analyzer.py --since 168h --save-baseline   # 周末留存，供下周对比\n"
        ),
    )
    parser.add_argument(
        "--containers",
        default="",
        help="要分析的容器名，逗号/空白分隔（默认取 EXPECTED_SERVICES 对应的 knowtrace-*-1）",
    )
    parser.add_argument(
        "--files",
        default="",
        help="额外分析的本机日志文件，逗号分隔（例：/var/log/nginx/knowtrace.error.log）",
    )
    parser.add_argument("--since", default="", help="时间窗口，例 24h / 7d / 168h（默认取 ops.conf）")
    parser.add_argument("--max-lines", type=int, default=0, help="单来源最大读取行数")
    parser.add_argument(
        "--save-baseline",
        action="store_true",
        help="把本次模式集合写成基线（供下次对比「新出现的模式」）",
    )
    parser.add_argument("--baseline", default=None, help="指定基线文件路径")
    add_common_arguments(parser)
    return parser


def _resolve_containers(conf, explicit: str) -> tuple[list[str], str]:
    """决定要分析哪些容器。返回 (容器名列表, 说明)。"""
    if explicit:
        names = [item for item in re.split(r"[\s,]+", explicit) if item]
        return names, "命令行 --containers"

    configured = conf.get_list("LOG_CONTAINERS", [])
    if configured:
        return configured, "ops.conf LOG_CONTAINERS"

    services = conf.get_list("EXPECTED_SERVICES", ["app", "auth", "postgres", "auth-postgres", "auth-redis"])
    project_dir = conf.get("PROJECT_DIR", "/opt/knowtrace")
    compose_file = str(Path(project_dir) / "compose.yaml")
    names: list[str] = []
    seen: set[str] = set()
    for service in services:
        # 容器名形如 knowtrace-workflow-app-1 —— **前缀不要写死**。
        # 2026-10-03 实测踩到：原实现写的是 `name=^/knowtrace-{service}-[0-9]+$`，
        # 仓库更名为 KnowTrace-Workflow、容器名随之变化后一个都匹配不上，
        # 而回退值又是硬编码的 `knowtrace-{service}-1`（同样错），
        # 于是日志分析**静默地不看任何容器** —— 报告照出，结论照写。
        # 改为先问 compose 要容器，与项目名解耦。
        #
        # ⚠ 若将来仍要用 docker 的 name 过滤器：它是**正则**匹配而非精确匹配，
        #   `name=^knowtrace-auth-` 会把 auth、auth-postgres、auth-redis 全匹配上，
        #   导致同一容器被分析多次（统计翻倍）。所以下面仍做去重。
        result = run_readonly(
            ["docker", "compose", "--project-directory", project_dir,
             "-f", compose_file, "ps", "-q", service],
            timeout=20.0,
        )
        for cid in (line.strip() for line in result.stdout.splitlines()):
            if not cid:
                continue
            inspected = run_readonly(
                ["docker", "inspect", "--format", "{{.Name}}", cid], timeout=10.0
            )
            for line in inspected.stdout.splitlines():
                name = line.strip().lstrip("/")
                if name and name not in seen:
                    seen.add(name)
                    names.append(name)
    return names, "ops.conf EXPECTED_SERVICES（按 compose 解析实际容器名，已去重）"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    conf = load_ops_conf(args.conf)
    report = Report(
        script="log_analyzer",
        title="KnowTrace-Workflow 日志错误模式分析",
        quiet=args.quiet,
        no_color=args.no_color,
        extra_meta=environment_summary(),
    )

    window_raw = args.since or conf.get("CONTAINER_LOG_WINDOW", "168h")
    window_seconds = parse_duration_seconds(window_raw, default=7 * 86400)
    window = f"{window_seconds}s"
    max_lines = args.max_lines or conf.get_int("CONTAINER_LOG_MAX_LINES", 20000)
    top_n = conf.get_int("LOG_TOP_PATTERNS", 10)

    warn_errors = conf.get_int("THRESHOLD_LOG_ERROR_WARN", 20)
    fail_errors = conf.get_int("THRESHOLD_LOG_ERROR_FAIL", 200)
    warn_new_patterns = conf.get_int("THRESHOLD_LOG_NEW_PATTERN_WARN", 1)

    if not have_command("docker"):
        die("缺少 docker 命令，无法采集容器日志")

    report.heading(f"{report.title}  窗口={window_raw}  生成时间={utc_now_iso()}")

    # ---- 采集 -------------------------------------------------------------
    scans: list[ContainerScan] = []
    containers, source_note = _resolve_containers(conf, args.containers)
    report.section("1. 采集范围")
    report.note(f"容器来源：{source_note}")

    rows: list[list[str]] = []
    for name in containers:
        lines, truncated = _docker_logs(name, window=window, max_lines=max_lines)
        scan = scan_lines(name, lines, truncated=truncated)
        scans.append(scan)
        rows.append([name, "docker logs", str(scan.lines_scanned), "是" if truncated else "否"])

    for raw_path in re.split(r"[\s,]+", args.files) if args.files else []:
        if not raw_path:
            continue
        path = Path(raw_path)
        lines, truncated = _read_file_tail(path, max_lines)
        if not lines and not path.is_file():
            rows.append([raw_path, "file", "0（不存在）", "-"])
            continue
        scan = scan_lines(str(path), lines, truncated=truncated)
        scans.append(scan)
        rows.append([raw_path, "file", str(scan.lines_scanned), "是" if truncated else "否"])

    report.table(["来源", "类型", "读取行数", "被截断"], rows)

    # 明确说明截断，避免「统计看起来完整」的错觉
    truncated_sources = [scan.name for scan in scans if scan.truncated]
    if truncated_sources:
        report.warn(
            "log.truncated",
            f"以下来源达到行数上限 {max_lines}，统计只覆盖窗口内最近的部分："
            + "、".join(truncated_sources),
        )
    else:
        report.ok("log.truncated", "所有来源均在行数上限内，统计覆盖完整窗口")

    # ---- 聚类结果 ---------------------------------------------------------
    all_stats: list[PatternStat] = []
    for scan in scans:
        all_stats.extend(scan.patterns.values())
    all_stats.sort(key=lambda item: (item.severity != "ERROR", -item.count, item.container))

    errors = [item for item in all_stats if item.severity == "ERROR"]
    warns = [item for item in all_stats if item.severity == "WARN"]
    error_total = sum(item.count for item in errors)
    warn_total = sum(item.count for item in warns)
    lines_total = sum(scan.lines_scanned for scan in scans)

    report.section("2. 错误模式聚类（TOP {}）".format(top_n))
    if not all_stats:
        report.ok("log.patterns", "窗口内没有匹配到 error/warn 模式")
    else:
        report.table(
            ["级别", "次数", "来源", "最近出现(UTC)", "归一化模式"],
            [stat.to_row() for stat in all_stats[:top_n]],
        )
        report.info(
            "log.totals",
            f"共读取 {lines_total} 行，匹配 ERROR {error_total} 行 / WARN {warn_total} 行，"
            f"归并为 {len(all_stats)} 个模式",
        )

    # 高危模式单独拎出来，即使次数少也不该被 TOP 列表挤掉
    high_risk = [
        item for item in all_stats
        if _HIGH_SEVERITY.search(item.pattern) or item.severity == "ERROR"
    ][:top_n]
    report.section("3. 高危模式（panic / OOM / refused / no space 等）")
    if not high_risk:
        report.ok("log.high-risk", "未发现高危模式")
    else:
        report.table(
            ["级别", "次数", "来源", "最近出现(UTC)", "归一化模式"],
            [stat.to_row() for stat in high_risk],
        )
        report.note("高危模式只代表「关键字命中了」，是否需要处理要看上下文；原始行见 --samples。")

    # ---- 基线对比 ---------------------------------------------------------
    baseline_path = Path(args.baseline) if args.baseline else _baseline_path()
    baseline = load_baseline(baseline_path)
    report.section("4. 与上次基线的趋势对比")
    if not baseline:
        report.info(
            "log.baseline",
            f"没有可用基线（{baseline_path}）；本次只能给快照，无法判断是否「新出现」。"
            "首次运行后用 --save-baseline 留存，下周即可对比。",
        )
        new_patterns: list[PatternStat] = []
    else:
        known = baseline.get("patterns", {})
        report.note(
            f"基线：{baseline.get('generated_at', 'unknown')}，"
            f"窗口 {baseline.get('window', 'unknown')}，{baseline.get('pattern_count', 0)} 个模式"
        )
        new_patterns = [item for item in all_stats if item.pattern not in known]
        gone = [key for key in known if key not in {item.pattern for item in all_stats}]
        if new_patterns:
            report.table(
                ["级别", "次数", "来源", "最近出现(UTC)", "新出现的模式"],
                [stat.to_row() for stat in new_patterns[:top_n]],
            )
        else:
            report.ok("log.new-patterns", "窗口内没有相对基线新出现的模式")

        resolved = [key for key in gone if known[key].get("severity") == "ERROR"]
        if resolved:
            report.info("log.resolved", f"基线中 {len(resolved)} 个 ERROR 模式在本次窗口未再出现")
        report.info("log.baseline-stats", f"基线存在但本次消失的模式：{len(gone)} 个")

    # 留存本次结果作为下次的基线。只在显式要求时写，避免定时任务每次都覆盖掉
    # 「上周」的参照物（否则永远只会和上一次比，看不到长期趋势）。
    if args.save_baseline:
        problem = save_baseline(baseline_path, scans, window_raw)
        if problem:
            report.warn("log.baseline-save", problem)
        else:
            report.ok("log.baseline-save", f"已更新基线: {baseline_path}（下次运行即可对比新增模式）")

    # ---- 结论 -------------------------------------------------------------
    report.section("5. 结论与建议")
    if error_total >= fail_errors:
        report.fail(
            "log.error-volume",
            f"ERROR 行数 {error_total} 已达到阈值 {fail_errors}（窗口 {window_raw}）",
        )
    elif error_total >= warn_errors:
        report.warn(
            "log.error-volume",
            f"ERROR 行数 {error_total} 超过阈值 {warn_errors}（窗口 {window_raw}）",
        )
    else:
        report.ok("log.error-volume", f"ERROR 行数 {error_total}，低于阈值 {warn_errors}")

    new_error_patterns = [item for item in new_patterns if item.severity == "ERROR"]
    if new_error_patterns and len(new_error_patterns) >= warn_new_patterns:
        report.warn(
            "log.new-error-patterns",
            f"相对基线新出现 {len(new_error_patterns)} 个 ERROR 模式，建议逐个确认："
            + "、".join(item.pattern[:60] for item in new_error_patterns[:3]),
        )

    if error_total == 0 and not new_patterns:
        report.ok("log.conclusion", "窗口内未发现错误模式，且相对基线无新增")

    for text in (
        "本分析只覆盖所采集的来源与窗口；PLG 日志栈（Loki/Alloy）未运行时，"
        "容器日志来自 docker logs，不是集中式采集。",
        "归一化模式中的数字已被替换成 <n>/<ts>/<ip> 等占位符，原始行请用 --samples 单独查看。",
        "报告不会包含 password= / token: 等键值形式的敏感内容（值已替换为 ***）。",
    ):
        report.note(text)

    code = report.finish()
    emit_reports(report, args, command="log_analyzer.py")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
