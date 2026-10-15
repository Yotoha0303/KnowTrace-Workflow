#!/usr/bin/env python3
"""TLS 证书有效期批量检查（KnowTrace-Workflow 运维工具包）。

为什么用 Python 而不是 Bash
---------------------------
Bash 用 ``openssl s_client | openssl x509 -noout -enddate`` 看一张证书足够。
但本项目的实际需求是：

* 检查多个域名（公网入口、可能的子域、监控域名）；
* 把 ``notAfter`` 解析成「剩余天数」；
* 按阈值分级（≤30 天 WARN，≤7 天 CRITICAL）；
* 校验证书链与域名匹配，并把 DNS 解析结果和记录值比对（本项目出现过
  「DNS 仍指向旧 IP」的故障 INC-003）；
* 输出可存档的 Markdown / JSON 报告，附到 ``docs/日常运维/``。

这已经是「获取数据 → 解析 → 计算 → 判断 → 分类 → 输出」的数据流，
属于 Python 的职责范围（见 ``bash与python的运维使用建议.md`` 第 3 节）。

安全性说明
----------
* 本脚本**不提供**跳过 TLS 校验来「制造通过结果」的选项，遵循
  ``KnowTrace-ops/archive/docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段二/Bug记录/BUG-S2-005`` 的结论：
  不能用「不验证证书」换取通过。
* 当证书链校验失败时，脚本仍会尽力读取证书内容以报告有效期，但整体结论一定
  是 FAIL —— 信息用于排障，结论不被美化。
* 使用 socket 直连，不读取 HTTP(S)_PROXY 环境变量，避免 Windows 代理链造成
  的 TLS 误判（ISSUE-S3-008）。

退出码：0=全部正常  1=存在 WARN  2=存在 FAIL  3=脚本自身错误
"""

from __future__ import annotations

import argparse
import socket
import ssl
import subprocess
import sys
from datetime import timezone
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
    load_ops_conf,
    repo_root,
    utc_now,
)


# ---------------------------------------------------------------------------
# 证书解析
# ---------------------------------------------------------------------------


def _pem_from_der(der: bytes) -> str:
    return ssl.DER_cert_to_PEM_cert(der)


def _cert_validity(cert) -> tuple[object, object]:
    """返回证书的 (not_before, not_after)，两者都带 UTC 时区。

    兼容性要点（直接影响 Ubuntu 24.04 的发行版 python3-cryptography）：
    ``not_valid_after_utc`` / ``not_valid_before_utc`` 是 cryptography 42.0 才加
    的属性；更早的版本只有 **naive** 的 ``not_valid_after`` / ``not_valid_before``。
    Ubuntu 24.04 (noble) 的 ``python3-cryptography`` 可能早于 42，直接访问新属性
    会抛 AttributeError 让整个脚本崩掉，所以这里必须按版本回退，
    并对 naive datetime 补上 UTC（否则 ``timestamp()`` 会按本地时区换算，
    在非 UTC 机器上算出错误的剩余天数）。
    """
    not_before = getattr(cert, "not_valid_before_utc", None)
    not_after = getattr(cert, "not_valid_after_utc", None)

    if not_before is None or not_after is None:
        # cryptography < 42：naive datetime，按 UTC 解释
        not_before = cert.not_valid_before.replace(tzinfo=timezone.utc)
        not_after = cert.not_valid_after.replace(tzinfo=timezone.utc)

    if not_before.tzinfo is None:
        not_before = not_before.replace(tzinfo=timezone.utc)
    if not_after.tzinfo is None:
        not_after = not_after.replace(tzinfo=timezone.utc)
    return not_before, not_after


def _parse_pem_with_cryptography(pem: str) -> dict[str, str] | None:
    """优先使用 cryptography；未安装或版本过旧时返回 None，由 openssl CLI 兜底。"""
    try:
        from cryptography import x509  # type: ignore
    except ImportError:
        return None

    try:
        cert = x509.load_pem_x509_certificate(pem.encode("ascii"))
    except Exception:
        return None

    def name_to_str(name) -> str:
        parts = []
        for attribute in name:
            try:
                parts.append(f"{attribute.oid._name}={attribute.value}")
            except Exception:
                parts.append(str(attribute.value))
        return ", ".join(parts) if parts else "unknown"

    san_entries: list[str] = []
    try:
        extension = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
        san_entries = [
            str(value) for value in extension.value.get_values_for_type(x509.DNSName)
        ]
    except Exception:
        san_entries = []

    try:
        not_before, expiry = _cert_validity(cert)
    except Exception:
        # 例如 cryptography 版本 API 差异超出预期：交给 openssl CLI 兜底
        return None

    return {
        "subject": name_to_str(cert.subject),
        "issuer": name_to_str(cert.issuer),
        "not_before": not_before.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "not_after": expiry.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "not_after_epoch": str(int(expiry.timestamp())),
        "sans": ",".join(san_entries),
    }


def _parse_pem_with_openssl(pem: str) -> dict[str, str] | None:
    """用 openssl CLI 解析 PEM，作为没有 cryptography 时的兜底。

    openssl 的失败诊断不静默吞掉：无法解析时返回 None，由调用方记为结论。
    """
    if not have_command("openssl"):
        return None

    try:
        completed = subprocess.run(
            [
                "openssl",
                "x509",
                "-noout",
                "-subject",
                "-issuer",
                "-startdate",
                "-enddate",
                "-ext",
                "subjectAltName",
            ],
            input=pem,
            capture_output=True,
            text=True,
            timeout=15.0,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    if completed.returncode != 0:
        return None

    text = completed.stdout
    parsed: dict[str, str] = {}

    def grab(prefix: str) -> str:
        for line in text.splitlines():
            if line.strip().startswith(prefix):
                return line.split("=", 1)[1].strip()
        return ""

    subject = grab("subject=")
    issuer = grab("issuer=")
    not_before = grab("notBefore=")
    not_after = grab("notAfter=")
    if not not_after:
        return None

    from email.utils import parsedate_to_datetime

    expiry_dt = parsedate_to_datetime(not_after)
    if expiry_dt.tzinfo is None:
        expiry_dt = expiry_dt.replace(tzinfo=timezone.utc)

    sans = ""
    for line in text.splitlines():
        if line.strip().startswith("DNS:"):
            sans = line.strip()

    parsed.update(
        {
            "subject": subject or "unknown",
            "issuer": issuer or "unknown",
            "not_before": not_before,
            "not_after": expiry_dt.astimezone(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            ),
            "not_after_epoch": str(int(expiry_dt.timestamp())),
            "sans": sans,
        }
    )
    return parsed


def parse_certificate_pem(pem: str) -> dict[str, str] | None:
    parsed = _parse_pem_with_cryptography(pem)
    if parsed is not None:
        return parsed
    return _parse_pem_with_openssl(pem)


# ---------------------------------------------------------------------------
# 探测
# ---------------------------------------------------------------------------


class CertResult:
    def __init__(self, label: str, host: str, port: int) -> None:
        self.label = label
        self.host = host
        self.port = port
        self.resolved_ips: list[str] = []
        self.connect_ip: str | None = None
        self.handshake_ok = False
        self.chain_verified = False
        self.validation_error = ""
        self.validation_code: int | None = None
        self.validation_hint = ""
        self.trust_store = ""
        self.trust_store_is_insecure = False
        self.trust_stores_available: list[str] = []
        self.protocol = ""
        self.cipher = ""
        self.tls_version_ok = True
        self.info: dict[str, str] = {}
        self.days_remaining: int | None = None
        self.hostname_matched: bool | None = None
        self.error = ""

    @property
    def endpoint(self) -> str:
        return f"{self.host}:{self.port}"


def resolve(host: str) -> list[str]:
    """解析 A/AAAA 记录。找不到时返回空列表（不抛异常）。"""
    addresses: list[str] = []
    for family in (socket.AF_INET, socket.AF_INET6):
        try:
            infos = socket.getaddrinfo(host, None, family, socket.SOCK_STREAM)
        except socket.gaierror:
            continue
        for info in infos:
            address = info[4][0]
            if address not in addresses:
                addresses.append(address)
    return addresses


def _handshake(
    ip: str,
    host: str,
    port: int,
    *,
    context: ssl.SSLContext,
    timeout: float,
) -> tuple[bytes, str, str]:
    """与 ``ip:port`` 建立 TLS，SNI 使用 ``host``。

    返回 ``(der, tls_version, cipher)``；失败时抛异常由调用方处理。
    """
    with socket.create_connection((ip, port), timeout=timeout) as raw_socket:
        with context.wrap_socket(raw_socket, server_hostname=host) as tls_socket:
            der = tls_socket.getpeercert(binary_form=True) or b""
            version = tls_socket.version() or ""
            cipher_name = ""
            try:
                cipher = tls_socket.cipher()
                cipher_name = cipher[0] if cipher else ""
            except Exception:
                cipher_name = ""
            return der, version, cipher_name


class TrustStore:
    """一个可用的证书信任来源。

    本项目已知的坑（见 ``BUG-S2-005-Python默认CA导致公网压测TLS失败``）：
    Windows 上 ``python.org`` 版 Python 的 OpenSSL 通常**没有编译默认 CA 路径**，
    ``ssl.get_default_verify_paths()`` 返回 ``cafile=None``，于是任何公网 TLS
    校验都会莫名失败，而错误信息还会是误导性的 ``certificate has expired``
    （实际是本机找不到信任根，不是对端证书过期）。

    因此这里按顺序尝试多个来源，并把「最终用的是哪一个」明确写进报告 ——
    一个不知道自己用哪个信任库的证书检查器，会制造假故障。
    """

    def __init__(self, name: str, context: ssl.SSLContext) -> None:
        self.name = name
        self.context = context


def build_trust_stores(explicit_ca: str | None = None) -> list[TrustStore]:
    """构造候选信任来源列表，按可信度排序。"""
    stores: list[TrustStore] = []

    # 1) 显式指定的 CA（最高优先级：运维明确给出的信任锚）
    if explicit_ca:
        ca_path = Path(explicit_ca)
        if not ca_path.is_file():
            die(f"--ca-file 指定的 CA 文件不存在: {ca_path}")
        context = ssl.create_default_context(cafile=str(ca_path))
        stores.append(TrustStore(f"显式 CA ({ca_path.name})", context))

    # 2) 系统默认信任库（Linux 上是 /etc/ssl/certs，最权威）
    try:
        system_context = ssl.create_default_context()
        paths = ssl.get_default_verify_paths()
        has_default = bool(paths.cafile or paths.capath) or have_command("openssl")
        # Linux 上即使 cafile/capath 为 None，OpenSSL 也会用编译内置路径，
        # 因此这里不因为返回 None 就断定不可用，而是实际尝试一次（见 probe.py 交叉验证）。
        if has_default or sys.platform.startswith("linux"):
            stores.append(TrustStore("系统信任库", system_context))
    except Exception:
        pass

    # 3) certifi 的 CA 包（跨平台，专门解决 Windows 缺 CA 的问题）
    try:
        import certifi  # type: ignore

        certifi_context = ssl.create_default_context(cafile=certifi.where())
        stores.append(TrustStore(f"certifi ({Path(certifi.where()).name})", certifi_context))
    except Exception:
        pass

    # 4) 项目内自带的 CA 包（运维可放到 lib/ 或 ops.conf 指定）
    for bundled in (repo_root() / "lib" / "ca-bundle.crt", repo_root() / "ca-bundle.crt"):
        if bundled.is_file():
            try:
                context = ssl.create_default_context(cafile=str(bundled))
            except Exception:
                continue
            stores.append(TrustStore(f"内置 CA ({bundled.name})", context))
            break

    # 5) 显式关闭校验（只测有效期，不测信任）——必须由使用者明确要求
    insecure_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    insecure_context.check_hostname = False
    insecure_context.verify_mode = ssl.CERT_NONE
    stores.append(TrustStore("未校验（仅测有效期）", insecure_context))

    return stores


def _is_insecure(store: TrustStore) -> bool:
    return store.context.verify_mode == ssl.CERT_NONE


def _describe_validation_failure(code: int, message: str, verified_any: bool) -> str:
    """把 OpenSSL 的 verify code 翻译成不会误导人的中文说明。

    关键点：``CERTIFICATE_VERIFY_FAILED`` 的原始文案是
    ``certificate has expired``，但在「本机没有任何信任库」的场景下它指的是
    **本机缺信任根**，与对端证书是否过期完全无关。必须区分开。
    """
    if code == 20:  # unable to get local issuer certificate
        return "找不到签发者证书：要么对端未下发中间证书，要么本机信任库不完整/缺失"
    if code == 10:  # certificate has expired
        if not verified_any:
            return (
                "本机信任库缺失或不完整（OpenSSL 报 'certificate has expired' 是误导，"
                "实际未加载任何信任锚）。请用 --ca-file 指定 CA，或安装 certifi"
            )
        return "证书链中确有证书已过期（请核对链上每一张证书的有效期）"
    if code == 60:  # hostname mismatch
        return "证书域名与被访问域名不匹配"
    if code in (18, 19):  # self signed / self signed in chain
        return "自签名证书或链中包含自签名证书"
    return f"校验失败: {message}"


def describe_trust_sources(stores: list[TrustStore]) -> list[str]:
    """给出可读的信任来源清单（写进报告，便于事后追溯）。"""
    lines = []
    for store in stores:
        if _is_insecure(store):
            lines.append(f"{store.name}：存在，但只在不要求校验时使用")
        else:
            lines.append(f"{store.name}：可用")
    return lines



def check_domain(
    label: str,
    host: str,
    port: int,
    *,
    timeout: float = 10.0,
    expect_ips: list[str] | None = None,
    trust_stores: list[TrustStore] | None = None,
) -> CertResult:
    result = CertResult(label, host, port)

    if trust_stores is None:
        trust_stores = build_trust_stores()
    result.trust_stores_available = describe_trust_sources(trust_stores)

    result.resolved_ips = resolve(host)
    if not result.resolved_ips:
        result.error = "DNS 解析失败，无法连接"
        return result

    result.connect_ip = result.resolved_ips[0]

    # 1) 先拿一次不校验的证书 —— 无论信任库是否可用，证书本体都能取到，
    #    这样「有效期」和「信任」两件事可以分别给结论，而不是互相污染。
    der = b""
    insecure_store = next((s for s in trust_stores if _is_insecure(s)), None)
    if insecure_store is not None:
        try:
            der, version, cipher_name = _handshake(
                result.connect_ip, host, port,
                context=insecure_store.context, timeout=timeout,
            )
            result.handshake_ok = True
            result.protocol = version
            result.cipher = cipher_name
        except (ssl.SSLError, socket.timeout, TimeoutError, OSError) as error:
            result.error = f"无法获取证书: {error}"
            return result

    if der:
        parsed = parse_certificate_pem(_pem_from_der(der))
        if parsed:
            result.info = parsed
            try:
                expiry = int(parsed["not_after_epoch"])
                now = int(utc_now().timestamp())
                result.days_remaining = (expiry - now) // 86400
            except (KeyError, TypeError, ValueError):
                result.error = "证书缺少可用的 notAfter 字段"

    # 2) 依次尝试每个「要求校验」的信任来源。
    #    任何一个成功 => 信任成立，结论可以为 OK。
    verifying_stores = [s for s in trust_stores if not _is_insecure(s)]

    if not verifying_stores:
        result.validation_hint = (
            "本机没有任何可用的证书信任来源（系统信任库与 certifi 都不可用）。"
            "结论只反映证书有效期，无法判断信任链。请安装 certifi 或用 --ca-file 指定 CA。"
        )
        result.chain_verified = False
        result.trust_store = "无（仅测有效期）"
        result.trust_store_is_insecure = True
    else:
        for store in verifying_stores:
            try:
                _handshake(
                    result.connect_ip, host, port,
                    context=store.context, timeout=timeout,
                )
                result.chain_verified = True
                result.hostname_matched = True
                result.trust_store = store.name
                result.trust_store_is_insecure = False
                result.validation_error = ""
                result.validation_code = None
                break
            except ssl.SSLCertVerificationError as error:
                if not result.validation_error:
                    result.validation_code = error.verify_code
                    result.validation_error = error.verify_message or str(error)
                    result.validation_hint = _describe_validation_failure(
                        error.verify_code or 0,
                        error.verify_message or str(error),
                        verified_any=False,
                    )
                    result.trust_store = store.name
            except ssl.SSLError as error:
                if not result.validation_error:
                    result.validation_error = f"TLS 错误: {error}"
                    result.trust_store = store.name
            except (socket.timeout, TimeoutError):
                result.error = result.error or "连接超时"
            except OSError as error:
                result.error = result.error or f"连接失败: {error}"

    # 3) 弱协议只作为 WARN 线索，不作为 FAIL（TLS 1.2 仍属可接受）
    result.tls_version_ok = result.protocol in ("TLSv1.2", "TLSv1.3", "")

    # DNS 期望值比对（本项目发生过 DNS 仍指向旧 IP 的故障）
    if expect_ips:
        unexpected = [ip for ip in result.resolved_ips if ip not in expect_ips]
        if unexpected:
            result.info["dns_unexpected"] = ",".join(unexpected)

    return result

# ---------------------------------------------------------------------------
# 域名清单
# ---------------------------------------------------------------------------


def parse_target(entry: str, default_port: int) -> tuple[str, str, int]:
    """解析 ``host`` / ``host:port`` / ``label=host[:port]``。"""
    raw = entry.strip()
    label = ""
    if "=" in raw:
        label, _, raw = raw.partition("=")
        label = label.strip()

    host = raw
    port = default_port
    if raw.startswith("["):  # IPv6 字面量
        close = raw.find("]")
        if close > 0:
            host = raw[1:close]
            rest = raw[close + 1 :]
            if rest.startswith(":") and rest[1:].isdigit():
                port = int(rest[1:])
    elif raw.count(":") == 1:
        candidate_host, _, candidate_port = raw.partition(":")
        if candidate_port.isdigit():
            host, port = candidate_host, int(candidate_port)

    host = host.strip()
    if not label:
        label = f"{host}:{port}" if port != 443 else host
    return label, host, port


def load_targets(
    cli_targets: list[str],
    conf_domains: list[str],
    domains_file: str | None,
    default_port: int,
) -> list[tuple[str, str, int]]:
    entries: list[str] = []
    entries.extend(cli_targets)
    entries.extend(conf_domains)

    if domains_file:
        path = Path(domains_file)
        if not path.is_file():
            die(f"--domains-file 指定的文件不存在: {path}")
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            entries.append(line)

    seen: set[tuple[str, int]] = set()
    targets: list[tuple[str, str, int]] = []
    for entry in entries:
        label, host, port = parse_target(entry, default_port)
        key = (host.lower(), port)
        if key in seen:
            continue
        seen.add(key)
        targets.append((label, host, port))
    return targets


def derive_default_domain(conf) -> list[str]:
    """没显式配置证书域名时，从 PUBLIC_HEALTH_URL / PUBLIC_DOMAIN 推导一个。"""
    explicit = conf.get("PUBLIC_DOMAIN", "")
    if explicit:
        return [explicit]

    url = conf.get("PUBLIC_HEALTH_URL", "")
    if url:
        from urllib.parse import urlparse

        parsed = urlparse(url)
        if parsed.hostname:
            return [parsed.hostname]
    return []


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "KnowTrace-Workflow TLS 证书有效期批量检查（只读）。"
            "信任链校验不通过时绝不返回 OK，也不提供「跳过校验换取通过」的选项。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 用 ops.conf 中配置的 CERT_DOMAINS
  ./scripts/cert_check.py

  # 直接指定域名，并校验 DNS 是否仍指向预期 IP
  ./scripts/cert_check.py knowtrace.duckdns.org --expect-ip 45.64.74.99

  # Windows 上 Python 缺 CA 包时，显式指定 CA（本项目 BUG-S2-005 的规避方式）
  ./scripts/cert_check.py knowtrace.duckdns.org --ca-file D:/Git/mingw64/etc/ssl/certs/ca-bundle.crt

  # 多域名 + Markdown 归档报告
  ./scripts/cert_check.py \\
    knowtrace.duckdns.org \\
    api.example.com:8443 \\
    --markdown ./reports/2026-09-28-证书检查.md

阈值: 默认剩余天数 <=30 天为 WARN，<=7 天为 FAIL（可用 ops.conf 覆盖）。

信任来源: 依次尝试「显式 --ca-file → 系统信任库 → certifi → 仓库内置 CA」，
报告会写明最终采用哪一个。若全部不可用，则只报告有效期并给出 WARN，
不会把「本机缺信任库」误报成「对端证书过期」。
""",
    )
    parser.add_argument(
        "targets",
        nargs="*",
        help="host 或 host:port 或 标签=host:port（覆盖 ops.conf 中的 CERT_DOMAINS）",
    )
    parser.add_argument("--domains-file", default=None, help="从文件读取域名，每行一个，# 为注释")
    parser.add_argument("--expect-ip", action="append", default=[], help="期望的 DNS A 记录（可重复）")
    parser.add_argument("--timeout", type=float, default=10.0, help="单次连接超时秒数（默认 10）")
    parser.add_argument(
        "--ca-file",
        default=None,
        help="显式指定 CA 证书包（PEM）。Linux 上通常不需要；Windows 上常用来规避缺 CA",
    )
    add_common_arguments(parser)
    args = parser.parse_args(argv)

    conf = load_ops_conf(args.conf)
    report = Report(
        script="cert_check",
        title="KnowTrace-Workflow TLS 证书有效期检查",
        quiet=args.quiet,
        no_color=args.no_color,
        extra_meta=environment_summary(),
    )

    default_port = conf.get_int("CERT_PORT", 443)
    warn_days = conf.get_int("CERT_WARN_DAYS", 30)
    critical_days = conf.get_int("CERT_CRITICAL_DAYS", 7)

    conf_domains = conf.get_list("CERT_DOMAINS", []) if not args.targets else []
    if not args.targets and not conf_domains and not args.domains_file:
        conf_domains = derive_default_domain(conf)
        if conf_domains:
            report.note(
                f"未配置 CERT_DOMAINS，已从 PUBLIC_DOMAIN/PUBLIC_HEALTH_URL 推导: "
                f"{', '.join(conf_domains)}"
            )

    targets = load_targets(args.targets, conf_domains, args.domains_file, default_port)

    report.heading(f"TLS 证书有效期检查  阈值: WARN<={warn_days}天  FAIL<={critical_days}天")

    if not targets:
        report.fail(
            "cert.targets",
            "没有可检查的域名。请在 ops.conf 设置 CERT_DOMAINS，或直接传入域名参数。",
        )
        report.finish()
        emit_reports(report, args)
        return EXIT_ERROR

    expect_ips = [ip for ip in args.expect_ip if ip]

    # 信任来源只构造一次，所有端点复用；并把清单写进报告以便事后追溯
    # （本项目曾在 Windows 上因 Python 缺 CA 包而产生假失败，见 BUG-S2-005）。
    ca_file = args.ca_file or conf.get("CERT_CA_FILE", "") or None
    trust_stores = build_trust_stores(ca_file)

    report.section("信任来源")
    for line in describe_trust_sources(trust_stores):
        report.note(line)
    if not any(not _is_insecure(store) for store in trust_stores):
        report.warn(
            "trust.store",
            "本机没有任何可用的证书信任来源（系统信任库与 certifi 都不可用）。"
            "结论不包含信任链判断；请安装 certifi 或用 --ca-file 指定 CA。",
        )

    # 每个域名只探测一次：结果同时供「明细」和「汇总」两节使用，
    # 避免重复握手（重复探测既慢，也会让报告中的两次结果可能不一致）。
    if not args.quiet:
        print(f"\n正在探测 {len(targets)} 个端点...")
    results = [
        check_domain(
            label, host, port,
            timeout=args.timeout,
            expect_ips=expect_ips,
            trust_stores=trust_stores,
        )
        for label, host, port in targets
    ]

    report.section("证书明细")

    for result in results:
        label = result.label

        if result.error and not result.info:
            report.fail(
                f"cert.{label}",
                f"{result.endpoint} —— {result.error}",
                resolved=", ".join(result.resolved_ips) or "无",
            )
            continue

        days = result.days_remaining
        not_after = result.info.get("not_after", "unknown")
        issuer = result.info.get("issuer", "unknown")
        remaining_text = "unknown" if days is None else f"{days} 天"
        detail = (
            f"{result.endpoint} 剩余 {remaining_text}（到期 {not_after}）"
        )

        # 1) 信任链校验不通过 —— 结论一定是 FAIL，但必须说清是「对端问题」
        #    还是「本机信任库问题」，否则会把人带偏。
        #    本项目真实踩过：Windows 上 Python 没有 CA 包，OpenSSL 报
        #    "certificate has expired"，而实际链上没有任何证书过期。
        if not result.chain_verified:
            reason = result.validation_hint or result.validation_error or "未知原因"
            if result.trust_store_is_insecure or not result.trust_stores_available:
                report.fail(
                    f"cert.{label}.trust",
                    f"{detail} —— 本机无可用信任来源，未做信任链判断: {reason}",
                    issuer=issuer,
                )
            else:
                report.fail(
                    f"cert.{label}",
                    f"{detail} —— 信任链校验失败（使用 {result.trust_store}）: {reason}",
                    issuer=issuer,
                    resolved=", ".join(result.resolved_ips),
                )
            report.note(
                "提示: 先用独立验证器交叉确认（curl -sS --noproxy '*' -o /dev/null "
                "-w '%{ssl_verify_result}\\n' https://<域名>/ 或 openssl s_client -CAfile <CA>），"
                "再判断是证书问题还是本机信任库问题。"
            )
        # 2) 连接层面失败
        elif days is None:
            report.fail(f"cert.{label}", f"{detail} —— 无法计算剩余天数")
        # 3) 有效期阈值
        elif days <= critical_days:
            report.fail(
                f"cert.{label}",
                f"{detail}，已进入紧急区间（<={critical_days} 天）",
                issuer=issuer,
            )
        elif days <= warn_days:
            report.warn(
                f"cert.{label}",
                f"{detail}，请安排续期（<={warn_days} 天）",
                issuer=issuer,
            )
        else:
            report.ok(
                f"cert.{label}",
                f"{detail}；信任链已通过（{result.trust_store}）",
                issuer=issuer,
            )

        # 4) 附加线索（不改变上面的结论）
        if days is not None and days < 0:
            report.fail(f"cert.{label}.expired", f"证书已过期 {-days} 天")

        if not result.tls_version_ok and result.protocol:
            report.warn(
                f"cert.{label}.protocol",
                f"协商到 {result.protocol}，建议确认是否仍允许 TLS 1.2 以下",
            )

        if result.info.get("dns_unexpected"):
            report.warn(
                f"cert.{label}.dns",
                f"DNS 解析到非预期地址: {result.info['dns_unexpected']}"
                f"（预期 {', '.join(expect_ips)}）",
            )

        if result.info.get("sans"):
            report.note(f"{label} SAN: {result.info['sans']}")

    # --- 汇总表 -------------------------------------------------------------
    report.section("汇总")
    rows = []
    for result in results:
        if result.info:
            days = result.days_remaining
            status = "OK"
            if days is None or not result.chain_verified:
                status = "FAIL"
            elif days <= critical_days:
                status = "FAIL"
            elif days <= warn_days:
                status = "WARN"
            trust_label = result.trust_store if result.chain_verified else (
                result.trust_store or "无可用信任来源"
            )
            rows.append(
                [
                    result.endpoint,
                    "unknown" if days is None else str(days),
                    result.info.get("not_after", "unknown"),
                    result.protocol or "-",
                    "是" if result.chain_verified else "否",
                    trust_label,
                    status,
                ]
            )
        else:
            rows.append(
                [
                    result.endpoint,
                    "-",
                    "-",
                    "-",
                    "否",
                    "-",
                    "FAIL",
                ]
            )

    report.table(
        ["域名", "剩余天数", "到期时间(UTC)", "TLS", "链校验", "信任来源", "状态"],
        rows,
    )

    report.note(
        "说明: 剩余天数按 UTC 计算；「链校验=否」表示所有可用信任来源都无法完成"
        "校验握手。验证器不提供「跳过校验换取通过」的选项。"
    )

    report.section("记录建议")
    report.note("到期日期临近时，先在 docs/日常运维/ 记录当前到期时间和续期计划。")
    report.note("若出现「链校验失败」，先用 curl / openssl 交叉验证，再判断是证书问题还是本机信任库问题。")
    report.note(
        "本机缺 CA 包时（Windows 上常见），可安装 certifi 或用 "
        "--ca-file 指定 CA，不要据此断定线上有故障。"
    )
    report.note(f"证书检查间隔建议: 每周一次；紧急区间剩 {critical_days} 天时应每日检查。")

    code = report.finish()
    emit_reports(report, args)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
