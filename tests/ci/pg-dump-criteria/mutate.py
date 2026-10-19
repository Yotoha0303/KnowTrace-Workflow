#!/usr/bin/env python3
"""对 dump 文件做**确定性**变异（M5 修复 F9 第二层的负向用例）。

为什么要单独一个脚本而不是在 CI 里写 `head -c 128 /dev/urandom`：
  **每个负向用例都必须稳定复现**（任务书的硬要求）。随机字节的用例在 PG 里确实
  版本相关（`docs/changes/2026-10-19-M5修复-F2F3-dump完整性与库身份.md` 实测：
  追加随机 128B 在 17.11 上产物不变、在 18 上观察到表数变化），若连"注入什么"都不定，
  将来红了无法判断是判据变了还是注入变了。故随机流用**固定种子**。

用法：
  mutate.py copy            <src> <dst>
  mutate.py append-random-128 <src> <dst>          # 固定种子
  mutate.py append-zeros-128  <src> <dst>
  mutate.py truncate-128      <src> <dst>
  mutate.py flip-fraction <num>/<den> <src> <dst>  # 在 size*num/den 处翻 1 字节
  mutate.py flip-needle <utf-8 文本> <src> <dst>   # 在首次出现的该文本处翻 1 字节

每种模式都打印一行 `MUTATION ...`，含**实际偏移**与翻之前的字节值 ——
CI 日志里因此有「注入点在哪」的第一手证据，而不是一句"我改了"。
"""

import random
import sys
from pathlib import Path

SEED = 0x5EED_2026


def fail(message: str) -> None:
    print(f"FAIL mutate: {message}", file=sys.stderr)
    raise SystemExit(1)


def describe(mode: str, src: bytes, dst: bytes, offset: int | None = None,
             old: int | None = None, new: int | None = None) -> None:
    fields = [
        f"mode={mode}",
        f"src_size={len(src)}",
        f"dst_size={len(dst)}",
    ]
    if offset is not None:
        fields.append(f"offset={offset}")
    if old is not None and new is not None:
        fields.append(f"old=0x{old:02x}")
        fields.append(f"new=0x{new:02x}")
    print("MUTATION " + " ".join(fields))


def flip(data: bytearray, offset: int, mode: str, src: bytes) -> None:
    if offset < 0 or offset >= len(data):
        fail(f"flip offset {offset} outside file (size={len(data)})")
    old = data[offset]
    # XOR 0xFF 而不是 +1：保证**必然改变**该字节（+1 在 0xFF 处会回绕成 0x00 也变，
    # 但相邻两次注入同一位置时 XOR 可逆、便于对照）。同时保证新值 != 旧值。
    data[offset] = old ^ 0xFF
    describe(mode, src, bytes(data), offset, old, data[offset])


def main() -> None:
    arguments = sys.argv[1:]
    if len(arguments) < 3:
        fail("usage: mutate.py <mode> [extra] <src> <dst>")

    mode = arguments[0]
    if mode == "flip-fraction":
        if len(arguments) != 4:
            fail("usage: mutate.py flip-fraction <num>/<den> <src> <dst>")
        ratio, source_path, destination_path = arguments[1], arguments[2], arguments[3]
    elif mode == "flip-needle":
        if len(arguments) != 4:
            fail("usage: mutate.py flip-needle <text> <src> <dst>")
        needle, source_path, destination_path = arguments[1], arguments[2], arguments[3]
    elif mode in {"copy", "append-random-128", "append-zeros-128", "truncate-128"}:
        if len(arguments) != 3:
            fail(f"usage: mutate.py {mode} <src> <dst>")
        needle = ratio = None
        source_path, destination_path = arguments[1], arguments[2]
    else:
        fail(f"unknown mode: {mode}")

    source = Path(source_path).read_bytes()
    if not source:
        fail(f"source dump is empty: {source_path}")

    if mode == "copy":
        destination = source
        describe(mode, source, destination)

    elif mode == "append-random-128":
        tail = random.Random(SEED).randbytes(128)
        destination = source + tail
        describe(mode, source, destination)
        print(f"MUTATION appended_seed=0x{SEED:x} append_bytes=128 head={tail[:8].hex()}")

    elif mode == "append-zeros-128":
        destination = source + bytes(128)
        describe(mode, source, destination)

    elif mode == "truncate-128":
        if len(source) <= 128:
            fail(f"source too small to truncate 128 bytes (size={len(source)})")
        destination = source[:-128]
        describe(mode, source, destination)

    elif mode == "flip-fraction":
        numerator_text, _, denominator_text = ratio.partition("/")
        try:
            numerator, denominator = int(numerator_text), int(denominator_text)
        except ValueError:
            fail(f"flip-fraction expects <num>/<den>, got {ratio!r}")
        if denominator <= 0 or not 0 <= numerator < denominator:
            fail(f"flip-fraction ratio out of range: {ratio!r}")
        offset = len(source) * numerator // denominator
        data = bytearray(source)
        flip(data, offset, mode, source)
        destination = bytes(data)

    elif mode == "flip-needle":
        encoded = needle.encode("utf-8")
        offset = source.find(encoded)
        if offset < 0:
            fail(
                "needle not found in dump; note that pg_dump -Fc compresses data blocks "
                "by default, so plaintext needles are only findable with -Z0"
            )
        # 翻在 needle 的**最后一字节**，仍然完全落在该文本内。
        target = offset + len(encoded) - 1
        data = bytearray(source)
        flip(data, target, mode, source)
        destination = bytes(data)

    Path(destination_path).write_bytes(destination)


if __name__ == "__main__":
    main()
