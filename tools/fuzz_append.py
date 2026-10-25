#!/usr/bin/env python3
"""Append/update fuzz harness: mutated archives fed to `btar -rf` / `-uf`.

Deterministic (seeded) mutations of valid archives: header byte flips, block
randomisation, truncation (including inside end blocks), trailing garbage,
size lies, typeflag swaps. Invariants checked per run:
  * exit status in {0, 1, 2}; no signal/timeout/sanitizer report;
  * exit 2 => the archive is byte-identical to the mutated input (a failed
    append never modifies it);
  * exit 0/1 => the result starts with the mutated input up to its logical end
    and ends in exactly 1024 zero bytes, and GNU tar reads it iff it read the
    mutated input (btar must not accept what it cannot safely extend).
Usage: fuzz_append.py [--bin PATH] [--iterations N] [--seed N]
Exit: 0 clean, 1 findings, 2 setup error.
"""
from __future__ import annotations

import argparse
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True  # keep tools/ free of __pycache__ (source package, whitelist)
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from tar_end import end_of  # noqa: E402


def gnu_ok(path: Path) -> bool:
    return subprocess.run(["tar", "-tf", str(path)], capture_output=True).returncode == 0


def seeds(work: Path) -> list[bytes]:
    src = work / "src"
    (src / "d" / "sub").mkdir(parents=True)
    (src / "d" / "a.txt").write_bytes(b"alpha\n" * 100)
    (src / "d" / "sub" / "b.txt").write_bytes(b"b" * 700)
    (src / "d" / ("L" * 130 + ".txt")).write_bytes(b"long\n")
    os.symlink("a.txt", src / "d" / "ln")
    os.link(src / "d" / "a.txt", src / "d" / "hard")
    out = []
    for fmt in ("gnu", "posix", "ustar"):
        arc = work / f"seed-{fmt}.tar"
        skip = ["--exclude=LLL*"] if fmt == "ustar" else []  # name too long for ustar
        subprocess.run(["tar", f"--format={fmt}", *skip, "-cf", str(arc), "-C", str(src), "d"],
                       check=True, capture_output=True)
        out.append(arc.read_bytes())
    return out


def mutate(rng: random.Random, data: bytes) -> bytes:
    b = bytearray(data)
    kind = rng.randrange(8)
    if kind == 0 and len(b) > 1:  # truncate anywhere
        return bytes(b[:rng.randrange(len(b))])
    if kind == 1:  # trailing garbage after the end blocks
        return bytes(b) + bytes(rng.randrange(256) for _ in range(rng.randrange(1, 700)))
    nblocks = max(1, len(b) // 512)
    blk = rng.randrange(nblocks) * 512
    if kind == 2:  # flip bytes inside a block
        for _ in range(rng.randrange(1, 4)):
            b[blk + rng.randrange(512)] ^= 1 << rng.randrange(8)
    elif kind == 3:  # randomise a whole block
        b[blk:blk + 512] = bytes(rng.randrange(256) for _ in range(512))
    elif kind == 4:  # size field lie (octal digits) with a recomputed checksum
        lie = rng.choice([0, 1, 511, 513, 4096, 1 << 20, 0o77777777777])
        b[blk + 124:blk + 135] = b"%011o" % lie
        recheck(b, blk)
    elif kind == 5:  # typeflag swap with a recomputed checksum
        b[blk + 156] = rng.choice(b"0123456789xgLKSDVMN\0")
        recheck(b, blk)
    elif kind == 6:  # clobber the first end block region
        b[-1024:-512] = b"\x01" * 512
    else:  # flip a byte in the data area
        b[rng.randrange(len(b))] ^= 0xFF
    return bytes(b)


def recheck(b: bytearray, blk: int) -> None:
    b[blk + 148:blk + 156] = b"        "
    s = sum(b[blk:blk + 512])
    b[blk + 148:blk + 156] = b"%06o\0 " % s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=str(ROOT / "build" / "btar"))
    ap.add_argument("--iterations", type=int, default=150)
    ap.add_argument("--seed", type=int, default=20261025)
    ap.add_argument("--save", help="directory to keep archives behind findings")
    args = ap.parse_args()
    if not os.access(args.bin, os.X_OK):
        print(f"fuzz_append: not executable: {args.bin}", file=sys.stderr)
        return 2
    env = dict(os.environ)  # same sanitizer options as run_asan.sh / fuzz_headers.py
    env.setdefault("ASAN_OPTIONS", "detect_leaks=0:abort_on_error=1")
    env.setdefault("UBSAN_OPTIONS", "halt_on_error=1")
    rng = random.Random(args.seed)
    findings: list[str] = []
    stats = {"rc0": 0, "rc1": 0, "rc2": 0}
    with tempfile.TemporaryDirectory(prefix="btar-fuzz-append.") as tmp:
        work = Path(tmp)
        corpus = seeds(work)
        newf = work / "src" / "new.txt"
        newf.write_bytes(b"appended\n")
        os.utime(newf, (2000000000, 2000000000))
        for i in range(args.iterations):
            data = mutate(rng, corpus[i % len(corpus)])
            arc = work / "t.tar"
            arc.write_bytes(data)
            mode = "-uf" if i % 3 == 0 else "-rf"
            try:
                p = subprocess.run([args.bin, mode, str(arc), "-C", str(work / "src"),
                                    "new.txt", "d/a.txt"],
                                   capture_output=True, timeout=60, env=env)
            except subprocess.TimeoutExpired:
                findings.append(f"iter {i}: timeout"); continue
            after = arc.read_bytes()
            tag = f"iter {i} {mode} rc={p.returncode}"
            if p.returncode < 0 or p.returncode > 2 or b"Sanitizer" in p.stderr:
                findings.append(f"{tag}: bad exit/sanitizer: {p.stderr[-200:]!r}")
                continue
            stats[f"rc{p.returncode}"] += 1
            if p.returncode == 2:
                if after != data:
                    findings.append(f"{tag}: archive modified by a failed run")
                continue
            try:
                old_end = end_of(data)
            except (ValueError, IndexError):
                findings.append(f"{tag}: accepted an archive the oracle rejects")
                continue
            if after[:old_end] != data[:old_end] or after[-1024:] != b"\0" * 1024:
                findings.append(f"{tag}: prefix/trailer wrong")
            ref = work / "ref.tar"
            ref.write_bytes(data)
            if gnu_ok(ref) != gnu_ok(arc) and gnu_ok(ref):
                findings.append(f"{tag}: GNU read the input but cannot read the result")
                if args.save:
                    Path(args.save, f"in-{i}.tar").write_bytes(data)
                    Path(args.save, f"out-{i}.tar").write_bytes(after)
    print(f"fuzz_append: runs={args.iterations} clean={args.iterations - len(findings)} "
          f"rc0={stats['rc0']} rc1={stats['rc1']} rc2={stats['rc2']}")
    for f in findings[:20]:
        print("  FINDING", f)
    print("RESULT: PASS" if not findings else "RESULT: FAIL")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
