#!/usr/bin/env python3
"""Header fuzz harness for btar (M2 sanitizer gate).

Deterministically mutates valid tar archives and feeds them to the ASan/UBSan
binary. The corpus is reproducible: the same --seed/--iterations and fixture
set give the same bytes (and the same `corpus_sha256`).

Mutation classes (chosen per iteration): header field byte flips (name/mode/
uid/gid/size/mtime/chksum/typeflag/linkname/magic/version/uname/gname/dev/
prefix), checksum-preserving field faults, checksum-only corruption, whole
512-byte block randomisation, truncation, trailing garbage, base-256 size lie,
and typeflag substitution. List mode is always exercised; extraction mode is
auto-detected and also exercised when the binary supports -xf.

Real findings (sanitizer report, signal, timeout, or an exit status outside
the documented 0/1/2 plan contract) are saved to the record directory with a JSON
descriptor and make the harness exit nonzero. Prints RESULT: PASS/FAIL.

Usage:
    python3 tools/fuzz_headers.py [--iterations N] [--seed N] [--deterministic]
        [--bin PATH] [--timeout SECONDS] [--no-extract] [--record-dir DIR]

Exit codes: 0 clean, 1 findings, 2 setup error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VALID_DIR = ROOT / "fixtures" / "generated" / "valid"
MANIFEST = ROOT / "fixtures" / "generated" / "manifest.json"
GEN = ROOT / "tools" / "gen_fixtures.py"
DEFAULT_BIN = ROOT / "build" / "btar_asan"
DEFAULT_TIMEOUT = 5.0
OK_EXIT_CODES = (0, 1, 2)  # plan §2.1: 0 ok, 1 warnings, 2 fatal

SAN_MARKERS = re.compile(
    r"ERROR: AddressSanitizer|AddressSanitizer:DEADLYSIGNAL|"
    r"SUMMARY: AddressSanitizer|SUMMARY: UndefinedBehaviorSanitizer|"
    r"runtime error:|UndefinedBehaviorSanitizer"
)

# ustar header field ranges (offset, length) inside a 512-byte header block.
FIELDS = [
    ("name", 0, 100),
    ("mode", 100, 8),
    ("uid", 108, 8),
    ("gid", 116, 8),
    ("size", 124, 12),
    ("mtime", 136, 12),
    ("chksum", 148, 8),
    ("typeflag", 156, 1),
    ("linkname", 157, 100),
    ("magic", 257, 6),
    ("version", 263, 2),
    ("uname", 265, 32),
    ("gname", 297, 32),
    ("devmajor", 329, 8),
    ("devminor", 337, 8),
    ("prefix", 345, 155),
]
TYPE_FLAGS = b"0d2157S4D3MKLxg"
BASE256_SIZE = bytes([0x80]) + (1 << 40).to_bytes(11, "big")


def ensure_fixtures() -> int:
    sources = sorted(VALID_DIR.glob("*.tar"))
    if sources:
        return 0
    if not MANIFEST.exists() and GEN.exists():
        print("fuzz_headers: fixtures missing; generating ...")
        try:
            subprocess.run([sys.executable, str(GEN)], check=True)
        except subprocess.CalledProcessError as exc:
            print(f"fuzz_headers: fixture generation failed: {exc}", file=sys.stderr)
            return 2
        sources = sorted(VALID_DIR.glob("*.tar"))
    if not sources:
        print(
            f"fuzz_headers: no valid fixtures in {VALID_DIR}; "
            f"run python3 tools/gen_fixtures.py",
            file=sys.stderr,
        )
        return 2
    return 0


def load_fixtures() -> dict[str, bytes]:
    fixtures = {}
    for path in sorted(VALID_DIR.glob("*.tar")):
        fixtures[path.name] = path.read_bytes()
    if not fixtures:
        raise SystemExit(2)
    return fixtures


def nonzero_blocks(data: bytes) -> list[int]:
    """512-aligned offsets of non-empty blocks (headers and payloads)."""
    if len(data) < 512:
        return []
    return [
        off
        for off in range(0, len(data) - 511, 512)
        if any(data[off : off + 512])
    ]


def is_ustar_block(data: bytes, off: int) -> bool:
    return len(data) >= off + 512 and data[off + 257 : off + 263] == b"ustar\x00"


def fix_checksum(data: bytearray, off: int) -> None:
    """Recompute the header checksum of the 512-byte block at off (in place)."""
    block = bytearray(data[off : off + 512])
    block[148:156] = b" " * 8
    block[148:156] = b"%06o\0 " % sum(block)
    data[off : off + 512] = block


def mutate(
    rng: random.Random, source: str, original: bytes
) -> tuple[bytes, dict]:
    """Apply one deterministic mutation; returns (bytes, descriptor)."""
    data = bytearray(original)
    headers = [off for off in nonzero_blocks(data) if is_ustar_block(data, off)]
    blocks = nonzero_blocks(data)
    kind = rng.choices(
        [
            "field",
            "field_fixed_checksum",
            "truncate",
            "random_block",
            "append",
            "size_bomb",
            "typeflag",
            "checksum_only",
        ],
        weights=[26, 24, 12, 12, 5, 8, 8, 5],
    )[0]
    desc: dict = {"source": source, "kind": kind}

    if kind in ("field", "field_fixed_checksum") and headers:
        off = rng.choice(headers)
        name, start, length = rng.choice(FIELDS)
        pos = off + start + rng.randrange(length)
        count = rng.randint(1, 3)
        before = bytes(data[pos : pos + count])
        data[pos : pos + count] = rng.randbytes(count)
        desc.update(
            block=off,
            field=name,
            offset=pos,
            before=before.hex(),
            after=bytes(data[pos : pos + count]).hex(),
        )
        if kind == "field_fixed_checksum":
            fix_checksum(data, off)
            desc["checksum_fixed"] = True
        else:
            desc["checksum_fixed"] = False

    elif kind == "size_bomb" and headers:
        off = rng.choice(headers)
        data[off + 124 : off + 136] = BASE256_SIZE
        fix_checksum(data, off)
        desc.update(block=off, declared_size=1 << 40, checksum_fixed=True)

    elif kind == "typeflag" and headers:
        off = rng.choice(headers)
        typeflag = rng.choice(TYPE_FLAGS)
        data[off + 156] = typeflag
        fix_checksum(data, off)
        desc.update(block=off, typeflag=chr(typeflag), checksum_fixed=True)

    elif kind == "checksum_only" and headers:
        off = rng.choice(headers)
        pos = off + 148 + rng.randrange(8)
        data[pos] ^= 0xFF
        desc.update(block=off, offset=pos)

    elif kind == "random_block" and blocks:
        off = rng.choice(blocks)
        data[off : off + 512] = rng.randbytes(512)
        desc.update(block=off)

    elif kind == "truncate" and len(original) > 1:
        new_len = rng.randrange(0, len(original))
        del data[new_len:]
        desc.update(truncated_to=new_len, original_len=len(original))

    elif kind == "append":
        extra = rng.randbytes(rng.randint(1, 1024))
        data.extend(extra)
        desc.update(appended=len(extra))

    else:  # fallback for tiny/degenerate sources: always change one byte
        pos = rng.randrange(len(data))
        data[pos] ^= 0xFF
        desc.update(kind="byte_flip", offset=pos)

    mutated = bytes(data)
    if mutated == original:  # guarantee a candidate actually differs
        mutated = bytes([original[0] ^ 0xFF]) + original[1:]
        desc.update(kind="byte_flip", offset=0, forced=True)
    desc["sha256"] = hashlib.sha256(mutated).hexdigest()
    desc["size"] = len(mutated)
    return mutated, desc


def classify(
    rc: int, stderr: str
) -> tuple[str, int | str]:
    """Return (status, detail); status=ok means within the documented contract."""
    if SAN_MARKERS.search(stderr):
        return "sanitizer", rc
    if rc < 0:
        return "signal", -rc
    if rc in OK_EXIT_CODES:
        return "ok", rc
    return "unexpected-exit", rc


def run_one(
    binary: Path,
    args: list[str],
    *,
    cwd: Path | None,
    timeout: float,
    env: dict[str, str],
) -> tuple[str, int | str, str]:
    try:
        proc = subprocess.run(
            [str(binary), *args],
            cwd=cwd,
            capture_output=True,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return "timeout", "timeout", ""
    stderr = proc.stderr.decode("utf-8", "replace")
    status, detail = classify(proc.returncode, stderr)
    return status, detail, stderr


def detect_extract(
    binary: Path, fixtures: dict[str, bytes], env: dict[str, str], timeout: float
) -> tuple[str | None, str]:
    """Probe -xf; returns ("argc"|"cwd", reason) or (None, reason)."""
    probe_name = "single_file.tar" if "single_file.tar" in fixtures else next(
        iter(fixtures)
    )
    probe = Path(tempfile.mkdtemp(prefix="btar-fuzz-probe-")) / probe_name
    probe.write_bytes(fixtures[probe_name])
    try:
        for style in ("argc", "cwd"):
            dest = probe.parent / f"dest-{style}"
            dest.mkdir()
            if style == "argc":
                status, detail, stderr = run_one(
                    binary,
                    ["-xf", str(probe), "-C", str(dest)],
                    cwd=None,
                    timeout=timeout,
                    env=env,
                )
                worked = (dest / "hello.txt").is_file()
            else:
                status, detail, stderr = run_one(
                    binary,
                    ["-xf", str(probe)],
                    cwd=dest,
                    timeout=timeout,
                    env=env,
                )
                worked = (dest / "hello.txt").is_file()
            if status == "ok" and worked:
                return style, f"-xf style: {style}"
        return None, f"-xf unsupported (probe status={status} detail={detail})"
    finally:
        shutil.rmtree(probe.parent, ignore_errors=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Deterministic header fuzzer for the btar ASan binary."
    )
    parser.add_argument("--iterations", type=int, default=200, metavar="N",
                        help="number of mutated cases (default 200)")
    parser.add_argument("--seed", type=int, default=0, metavar="N",
                        help="deterministic RNG seed (default 0)")
    parser.add_argument("--deterministic", action="store_true",
                        help="force seed 0 and stable ordering (the default; kept for clarity)")
    parser.add_argument("--bin", type=Path, default=DEFAULT_BIN, metavar="PATH",
                        help=f"btar binary (default {DEFAULT_BIN})")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        metavar="SECONDS", help="per-run timeout (default 5.0)")
    parser.add_argument("--no-extract", action="store_true",
                        help="only exercise list mode even if -xf works")
    parser.add_argument("--record-dir", type=Path, default=None, metavar="DIR",
                        help="findings directory (default /tmp/btar-fuzz-<seed>)")
    args = parser.parse_args(argv)

    if args.iterations < 1:
        parser.error("--iterations must be >= 1")
    if args.timeout <= 0:
        parser.error("--timeout must be > 0")
    if args.deterministic and args.seed != 0:
        print("fuzz_headers: --deterministic forces --seed 0", file=sys.stderr)
        args.seed = 0

    code = ensure_fixtures()
    if code:
        return code
    fixtures = load_fixtures()
    binary = args.bin.resolve()
    if not (binary.is_file() and os.access(binary, os.X_OK)):
        print(
            f"fuzz_headers: missing ASan binary {binary}; run ./tools/build_asan.sh",
            file=sys.stderr,
        )
        return 2

    record_dir = args.record_dir or Path(tempfile.gettempdir()) / f"btar-fuzz-{args.seed}"
    record_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="btar-fuzz-work-"))

    env = dict(os.environ)
    env.setdefault("ASAN_OPTIONS", "detect_leaks=0:abort_on_error=1")
    env.setdefault("UBSAN_OPTIONS", "halt_on_error=1")
    env["LC_ALL"] = "C"

    extract_style: str | None = None
    extract_reason = "disabled by --no-extract"
    if not args.no_extract:
        extract_style, extract_reason = detect_extract(
            binary, fixtures, env, args.timeout
        )

    names = sorted(fixtures)
    findings: list[dict] = []
    corpus_hash = hashlib.sha256()
    runs = 0
    started = time.time()

    print(f"fuzz_headers: bin={binary}")
    print(
        f"fuzz_headers: iterations={args.iterations} seed={args.seed} "
        f"fixtures={len(names)} list=-tf extract={extract_style or 'SKIP'} "
        f"timeout={args.timeout:g}s"
    )
    if extract_style is None:
        print(f"fuzz_headers: extraction {extract_reason}")

    try:
        for index in range(args.iterations):
            rng = random.Random(f"{args.seed}:{index}")
            source = rng.choice(names)
            data, desc = mutate(rng, source, fixtures[source])
            corpus_hash.update(index.to_bytes(8, "big"))
            corpus_hash.update(len(data).to_bytes(8, "big"))
            corpus_hash.update(data)

            case_path = work / f"case-{index:03d}.bin"
            case_path.write_bytes(data)
            case_results: list[dict] = []
            failed = False

            # list mode
            status, detail, stderr = run_one(
                binary, ["-tf", str(case_path)], cwd=None,
                timeout=args.timeout, env=env,
            )
            runs += 1
            if status != "ok":
                failed = True
                case_results.append(
                    {
                        "mode": "list",
                        "command": f"{binary} -tf {case_path}",
                        "status": status,
                        "detail": detail,
                        "stderr": stderr[-2000:],
                    }
                )

            # extract mode (when the app supports it)
            extract_dest = work / f"case-{index:03d}-x"
            if extract_style is not None:
                extract_dest.mkdir()
                if extract_style == "argc":
                    status, detail, stderr = run_one(
                        binary,
                        ["-xf", str(case_path), "-C", str(extract_dest)],
                        cwd=None, timeout=args.timeout, env=env,
                    )
                else:
                    status, detail, stderr = run_one(
                        binary, ["-xf", str(case_path)], cwd=extract_dest,
                        timeout=args.timeout, env=env,
                    )
                runs += 1
                if status != "ok":
                    failed = True
                    case_results.append(
                        {
                            "mode": "extract",
                            "command": f"cd {extract_dest} && {binary} -xf {case_path}"
                            if extract_style == "cwd"
                            else f"{binary} -xf {case_path} -C {extract_dest}",
                            "status": status,
                            "detail": detail,
                            "stderr": stderr[-2000:],
                        }
                    )

            if failed:
                case_file = record_dir / f"case-{index:03d}.bin"
                case_file.write_bytes(data)
                record = {
                    "iteration": index,
                    "seed": args.seed,
                    "mutation": desc,
                    "binary": str(binary),
                    "case": str(case_file),
                    "results": case_results,
                }
                (record_dir / f"case-{index:03d}.json").write_text(
                    json.dumps(record, indent=2) + "\n", encoding="utf-8"
                )
                findings.append(record)
                summary = ", ".join(
                    f"{result['mode']}={result['status']}" for result in case_results
                )
                print(f"FAIL case-{index:03d}: {summary} ({desc['kind']}, "
                      f"source={source})")
                for result in case_results:
                    if result["stderr"]:
                        first = result["stderr"].strip().splitlines()[0]
                        print(f"      {first[:180]}")

            shutil.rmtree(extract_dest, ignore_errors=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    elapsed = time.time() - started
    digest = corpus_hash.hexdigest()
    run_meta = {
        "seed": args.seed,
        "iterations": args.iterations,
        "corpus_sha256": digest,
        "binary": str(binary),
        "extract_style": extract_style,
        "runs": runs,
        "findings": len(findings),
        "elapsed_seconds": round(elapsed, 3),
    }
    (record_dir / "run.json").write_text(
        json.dumps(run_meta, indent=2) + "\n", encoding="utf-8"
    )

    print(
        f"fuzz_headers: runs={runs} clean={runs - sum(len(f['results']) for f in findings)} "
        f"findings={len(findings)} elapsed={elapsed:.1f}s"
    )
    print(f"fuzz_headers: corpus_sha256={digest}")
    print(f"fuzz_headers: record_dir={record_dir}")
    if findings:
        print("fuzz_headers: reproduce with "
              f"ASAN_OPTIONS='{env['ASAN_OPTIONS']}' UBSAN_OPTIONS='{env['UBSAN_OPTIONS']}' "
              f"{binary} -tf {record_dir}/<case>.bin")
        print(f"RESULT: FAIL ({len(findings)} case(s))")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
