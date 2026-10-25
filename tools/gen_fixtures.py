#!/usr/bin/env python3
"""Generate the deterministic tar fixture corpus for tar-bend.

Writes fixtures/generated/{valid,evil}/*.tar plus fixtures/generated/manifest.json.
Valid fixtures are produced with GNU tar 1.35 (fixed metadata: --mtime=@0,
--owner=0 --group=0 --numeric-owner --sort=name) or with a small raw ustar writer
so that edge cases (base-256 numbers, pax records, odd name bytes, truncated
archives) are byte-exact. Evil fixtures are always written by the raw writer with
correct checksums; a few are intentionally corrupt.

The generator is idempotent: if a previous manifest exists its sha256 values are
compared with the freshly generated ones. A mismatch (nondeterminism) is an error.

Usage:
    python3 tools/gen_fixtures.py [--keep-sources] [--verbose]

Exit codes: 0 success, 1 generation/determinism/size failure, 2 usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures"
OUT = FIXTURES / "generated"
EPOCH = 0
TOTAL_LIMIT = 100 * 1024 * 1024  # keep the whole corpus below this
MANIFEST_SCHEMA = 1
ENV = {**os.environ, "TZ": "UTC", "LC_ALL": "C"}


# --------------------------------------------------------------------------- #
# ustar / pax raw writer (no third-party deps)
# --------------------------------------------------------------------------- #
def _octal_field(value: int, width: int) -> bytes:
    """Encode a non-negative integer as (width-1) octal digits + NUL."""
    text = b"%0*o" % (width - 1, value)
    if len(text) > width - 1:
        raise ValueError(f"value {value} does not fit in {width}-byte octal field")
    return text + b"\0"


def base256_field(value: int, width: int = 12) -> bytes:
    """Encode a non-negative integer in base-256 (high bit set)."""
    payload = width - 1
    if value < 0 or value >= 1 << (8 * payload):
        raise ValueError(f"value {value} does not fit in {width}-byte base-256 field")
    return bytes([0x80]) + value.to_bytes(payload, "big")


def ustar_header(
    name: bytes,
    *,
    mode: int = 0o644,
    uid: int = 0,
    gid: int = 0,
    size: int = 0,
    mtime: int = EPOCH,
    typeflag: bytes = b"0",
    linkname: bytes = b"",
    prefix: bytes = b"",
    devmajor: int = 0,
    devminor: int = 0,
    raw_size: bytes | None = None,
    raw_mtime: bytes | None = None,
    checksum_delta: int = 0,
) -> bytes:
    """Build a canonical 512-byte ustar header with a correct checksum."""
    if len(name) > 100 or len(linkname) > 100 or len(prefix) > 155:
        raise ValueError("header string field overflow")
    if len(typeflag) != 1:
        raise ValueError("typeflag must be one byte")
    header = bytearray(512)
    header[0:100] = name.ljust(100, b"\0")
    header[100:108] = _octal_field(mode & 0o77777, 8)
    header[108:116] = _octal_field(uid, 8)
    header[116:124] = _octal_field(gid, 8)
    header[124:136] = raw_size if raw_size is not None else _octal_field(size, 12)
    header[136:148] = raw_mtime if raw_mtime is not None else _octal_field(mtime, 12)
    header[148:156] = b" " * 8  # checksum placeholder
    header[156:157] = typeflag
    header[157:257] = linkname.ljust(100, b"\0")
    header[257:263] = b"ustar\x00"
    header[263:265] = b"00"
    header[265:297] = b"\0" * 32  # uname
    header[297:329] = b"\0" * 32  # gname
    header[329:337] = _octal_field(devmajor, 8)
    header[337:345] = _octal_field(devminor, 8)
    header[345:500] = prefix.ljust(155, b"\0")
    checksum = sum(header) + checksum_delta
    header[148:156] = b"%06o\0 " % checksum
    return bytes(header)


def block_pad(data: bytes) -> bytes:
    """Pad a payload to a 512-byte boundary."""
    return data + b"\0" * ((-len(data)) % 512)


def entry(data: bytes = b"", **header_fields) -> bytes:
    """Header + block-padded payload (size defaults to the payload length)."""
    header_fields.setdefault("size", len(data))
    return ustar_header(**header_fields) + block_pad(data)


def pax_record(key: bytes, value: bytes) -> bytes:
    """Encode one pax record: '<len> <key>=<value>\\n' (length includes itself)."""
    body = key + b"=" + value + b"\n"
    length = len(body) + 1
    while True:
        prefix = str(length).encode() + b" "
        if len(prefix) + len(body) == length:
            return prefix + body
        length = len(prefix) + len(body)


def pax_header(records: list[bytes], *, name: bytes, typeflag: bytes) -> bytes:
    """A pax extended header entry ('x' per-file, 'g' global)."""
    data = b"".join(records)
    return entry(data, name=name, typeflag=typeflag, size=len(data))


def archive(parts: list[bytes], *, eof_blocks: int = 2) -> bytes:
    return b"".join(parts) + b"\0" * (512 * eof_blocks)


# --------------------------------------------------------------------------- #
# Fixture metadata helpers
# --------------------------------------------------------------------------- #
VALID: list[dict] = []
EVIL: list[dict] = []
GZIP_VALID: list[dict] = []
GZIP_EVIL: list[dict] = []
GZIP_LIMIT = 50 * 1024 * 1024  # compressed corpus budget


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _escape(raw: bytes) -> str:
    """Render archive name bytes as printable ASCII for JSON (non-ASCII -> \\xNN)."""
    out = []
    for byte in raw:
        if 32 <= byte < 127 and byte not in (ord("\\"),):
            out.append(chr(byte))
        else:
            out.append(f"\\x{byte:02x}")
    return "".join(out)


def _display(name: str | bytes) -> str:
    raw = name.encode("utf-8", "surrogateescape") if isinstance(name, str) else name
    if len(raw) > 80:
        return _escape(raw[:64]) + f"...(len={len(raw)})"
    return _escape(raw)


def _archive_members(path: Path) -> list[str]:
    """Expected member names, read back with the stdlib tarfile reader."""
    members: list[str] = []
    with tarfile.open(path, "r:") as tar:
        for member in tar:
            name = _display(member.name)
            if member.isdir() and not name.endswith("/"):
                name += "/"
            members.append(name)
    return members


def _register(
    bucket: list[dict],
    *,
    kind: str,
    name: str,
    relpath: str,
    path: Path,
    fmt: str,
    tool: str,
    extra: dict | None = None,
) -> None:
    record = {
        "name": name,
        "kind": kind,
        "file": relpath,
        "format": fmt,
        "tool": tool,
        "size": path.stat().st_size,
        "sha256": _sha256(path),
    }
    if kind == "valid":
        record["members"] = _archive_members(path)
        record["expected"] = {"extract": "ok", "exit": 0}
    record.update(extra or {})
    bucket.append(record)


def _gnu_version() -> str:
    line = subprocess.run(
        ["tar", "--version"], capture_output=True, text=True, env=ENV, check=True
    ).stdout.splitlines()[0]
    return line.strip()


def _raw_version() -> str:
    return f"python {sys.version.split()[0]} raw-writer"


# --------------------------------------------------------------------------- #
# Source tree for tool-created fixtures
# --------------------------------------------------------------------------- #
def _write(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def _pattern(size: int) -> bytes:
    seed = b"0123456789abcdef"
    return (seed * ((size // len(seed)) + 1))[:size]


def build_source_tree(src: Path) -> None:
    _write(src / "hello.txt", b"hello world\n")
    _write(src / "empty.txt", b"")
    _write(src / "big.bin", _pattern(1024 * 1024))
    mods = src / "mods"
    _write(mods / "mode_0644.txt", b"0644\n", 0o644)
    _write(mods / "mode_0755.sh", b"#!/bin/sh\necho hi\n", 0o755)
    _write(mods / "mode_0600.secret", b"secret\n", 0o600)
    dirs = src / "dirs"
    _write(dirs / "top.txt", b"top\n")
    _write(dirs / "nested" / "deep.txt", b"deep\n")
    links = src / "links"
    links.mkdir(parents=True)
    (links / "rel-link").symlink_to("../hello.txt")
    (links / "abs-link").symlink_to("/etc/hostname")
    hard = src / "hard"
    _write(hard / "orig.bin", b"hardlinked\n")
    os.link(hard / "orig.bin", hard / "link.bin")
    cross = src / "cross"
    _write(cross / "a" / "one.txt", b"cross-dir hardlink payload\n")
    (cross / "b").mkdir(parents=True)
    os.link(cross / "a" / "one.txt", cross / "b" / "two.txt")
    preserve = src / "modes_preserve"
    _write(preserve / "keep_0640.txt", b"0640\n", 0o640)
    _write(preserve / "keep_0750.sh", b"#!/bin/sh\ntrue\n", 0o750)
    _write(preserve / "keep_0660.txt", b"0660\n", 0o660)
    _write(preserve / "setuid_4755.bin", b"setuid\n", 0o4755)
    _write(src / "long" / ("l" * 124 + ".txt"), b"long pax name\n")
    _write(src / "gnu-long" / ("g" * 130 + ".txt"), b"gnu longname\n")
    padding = src / "padding"
    for size in (511, 512, 513, 4096):
        _write(padding / f"pad_{size}.bin", _pattern(size))
    (src / "emptydir").mkdir()
    # Fixed timestamps; creation order is irrelevant because tar uses --mtime=@0.
    _fix_times(src)


def _fix_times(root: Path) -> None:
    for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        os.utime(path, ns=(EPOCH * 10**9, EPOCH * 10**9), follow_symlinks=False)
    os.utime(root, ns=(EPOCH * 10**9, EPOCH * 10**9))


def gnu_create(
    out: Path,
    *,
    cwd: Path,
    fmt: str = "ustar",
    members: list[str] | None = None,
    files_from_null: bool = False,
) -> None:
    cmd = [
        "tar",
        f"--format={fmt}",
        "--mtime=@0",
        "--owner=0",
        "--group=0",
        "--numeric-owner",
        "--sort=name",
        "-cf",
        str(out),
        "-C",
        str(cwd),
    ]
    if fmt == "posix":
        # Default pax extended-header names embed the tar PID -> not deterministic.
        cmd.append("--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime")
    if files_from_null:
        cmd += ["--files-from", "/dev/null"]
    elif members:
        cmd += members
    subprocess.run(cmd, check=True, env=ENV)
    assert out.exists(), f"tar did not create {out}"


# --------------------------------------------------------------------------- #
# Valid fixtures
# --------------------------------------------------------------------------- #
def gen_valid(work: Path, src: Path) -> None:
    valid = work / "valid"
    valid.mkdir(parents=True)
    gnu = _gnu_version()
    raw = _raw_version()

    def gnu_fixture(
        name: str, fmt: str, *, cwd: Path, members: list[str],
        extra: dict | None = None,
    ) -> None:
        path = valid / f"{name}.tar"
        gnu_create(path, cwd=cwd, fmt=fmt, members=members)
        _register(VALID, kind="valid", name=name, relpath=f"valid/{name}.tar",
                  path=path, fmt=fmt, tool=gnu, extra=extra)

    # --- created by GNU tar -------------------------------------------------
    gnu_create(valid / "empty.tar", cwd=src, fmt="ustar", files_from_null=True)
    _register(VALID, kind="valid", name="empty", relpath="valid/empty.tar",
              path=valid / "empty.tar", fmt="ustar", tool=gnu,
              extra={"expected": {"extract": "ok", "exit": 0},
                     "notes": "two zero blocks, no members"})

    gnu_fixture("single_file", "ustar", cwd=src, members=["hello.txt"],
                extra={"stdout_check": True,
                       "notes": "single regular file; the -O check compares "
                                "btar -xOf stdout with GNU tar -xOf"})
    gnu_fixture("dirs_nested", "ustar", cwd=src, members=["dirs"])
    gnu_fixture("symlink_relative", "ustar", cwd=src,
                members=["hello.txt", "links/rel-link"])
    gnu_fixture("symlink_absolute", "ustar", cwd=src, members=["links/abs-link"])
    gnu_fixture("hardlink", "ustar", cwd=src, members=["hard"])
    gnu_fixture("modes", "ustar", cwd=src, members=["mods"])
    gnu_fixture("empty_file", "ustar", cwd=src, members=["empty.txt"])
    gnu_fixture("big_1mib", "ustar", cwd=src, members=["big.bin"])
    gnu_fixture("long_name_pax", "posix", cwd=src,
                members=["long/" + "l" * 124 + ".txt"])
    gnu_fixture("gnu_longname", "gnu", cwd=src,
                members=["gnu-long/" + "g" * 130 + ".txt"])
    gnu_fixture("trailing_slash_dir", "ustar", cwd=src, members=["emptydir"])
    for size in (4096, 511, 512, 513):
        gnu_fixture(f"pad_{size}", "ustar", cwd=src / "padding",
                    members=[f"pad_{size}.bin"])
    gnu_fixture(
        "cross_dir_hardlink", "ustar", cwd=src,
        members=["cross/a/one.txt", "cross/b/two.txt"],
        extra={"notes": "cross-directory hardlink: b/two.txt is typeflag '1' "
                        "to a/one.txt; compare_tree hardlink groups must match"})
    gnu_fixture(
        "modes_preserve", "ustar", cwd=src, members=["modes_preserve"],
        extra={
            "btar_args": ["-p"],
            "reference_args": ["-p"],
            "notes": "0640/0750/0660 plus setuid 04755; default extraction "
                     "applies umask and strips setuid, -p preserves 07777 "
                     "except setuid/setgid (non-root policy). run_diff compares "
                     "-p trees with --strict-modes against GNU tar -xpf with "
                     "setuid/setgid cleared (plan rule 6)",
        })

    # --- raw writer: base-256 numeric fields --------------------------------
    path = valid / "base256_numeric.tar"
    payload = b"B" * 1024
    parts = [
        entry(payload, name=b"base256.bin", size=1024,
              raw_size=base256_field(1024), raw_mtime=base256_field(EPOCH))
    ]
    path.write_bytes(archive(parts))
    _register(VALID, kind="valid", name="base256_numeric",
              relpath="valid/base256_numeric.tar", path=path, fmt="ustar+base256",
              tool=raw, extra={"notes": "size and mtime fields are base-256"})

    # --- raw writer: pax per-file keys -------------------------------------
    path = valid / "pax_perfile.tar"
    records = [
        pax_record(b"path", b"renamed-pax.txt"),
        pax_record(b"mtime", b"2"),
        pax_record(b"uid", b"123"),
    ]
    parts = [
        pax_header(records, name=b"PaxHeaders/perfile", typeflag=b"x"),
        entry(b"pax per-file payload\n", name=b"stored-name.txt"),
    ]
    path.write_bytes(archive(parts))
    _register(VALID, kind="valid", name="pax_perfile",
              relpath="valid/pax_perfile.tar", path=path, fmt="pax", tool=raw,
              extra={"notes": "x header overrides path/mtime/uid"})

    # --- raw writer: pax global header -------------------------------------
    path = valid / "pax_global.tar"
    records = [pax_record(b"comment", b"tar-bend fixture corpus")]
    parts = [
        pax_header(records, name=b"GlobalHead", typeflag=b"g"),
        entry(b"global header\n", name=b"global-after.txt"),
    ]
    path.write_bytes(archive(parts))
    _register(VALID, kind="valid", name="pax_global",
              relpath="valid/pax_global.tar", path=path, fmt="pax", tool=raw,
              extra={"notes": "g header carries a comment only; bsdtar rejects "
                               "non-portable global keys"})

    # --- raw writer: pax global metadata (uid/gid/mtime) ------------------
    path = valid / "global_pax_raw.tar"
    records = [
        pax_record(b"uid", b"123"),
        pax_record(b"gid", b"456"),
        pax_record(b"mtime", b"1234567890"),
    ]
    parts = [
        pax_header(records, name=b"GlobalHead", typeflag=b"g"),
        entry(b"global metadata\n", name=b"global-meta.txt"),
    ]
    path.write_bytes(archive(parts))
    _register(
        VALID, kind="valid", name="global_pax_raw",
        relpath="valid/global_pax_raw.tar", path=path, fmt="pax", tool=raw,
        extra={
            "baseline_bsdtar": "refuse",
            "notes": "g header with uid=123/gid=456/mtime=1234567890; GNU tar "
                     "applies those to the following member. bsdtar 3.8.10 "
                     "refuses non-comment global pax keys, so the GNU-vs-bsdtar "
                     "baseline treats this fixture as GNU-only (documented)",
        })

    # --- raw writer: symlink with pax path + mtime metadata ----------------
    path = valid / "symlink_meta.tar"
    parts = [
        entry(b"target payload\n", name=b"target.txt"),
        pax_header(
            [pax_record(b"path", b"links/symlink-meta"),
             pax_record(b"mtime", b"1234567890")],
            name=b"PaxHeaders/symlink-meta", typeflag=b"x"),
        ustar_header(b"placeholder", typeflag=b"2", linkname=b"../target.txt"),
    ]
    path.write_bytes(archive(parts))
    _register(
        VALID, kind="valid", name="symlink_meta",
        relpath="valid/symlink_meta.tar", path=path, fmt="pax", tool=raw,
        extra={"notes": "x header overrides the symlink path and mtime; "
                        "compare checks the target, mtime stays opt-in"})

    # --- raw writer: non-UTF-8 name bytes ----------------------------------
    path = valid / "non_utf8_name.tar"
    parts = [entry(b"latin-1\n", name=b"caf\xe9.txt")]
    path.write_bytes(archive(parts))
    _register(VALID, kind="valid", name="non_utf8_name",
              relpath="valid/non_utf8_name.tar", path=path, fmt="ustar", tool=raw,
              extra={"notes": r"name bytes are caf\xe9.txt (latin-1), not UTF-8"})

    # --- raw writer: duplicate entries (last one wins on extract) ----------
    path = valid / "duplicate_entries.tar"
    parts = [
        entry(b"first\n", name=b"dup.txt"),
        entry(b"second\n", name=b"dup.txt"),
    ]
    path.write_bytes(archive(parts))
    _register(VALID, kind="valid", name="duplicate_entries",
              relpath="valid/duplicate_entries.tar", path=path, fmt="ustar",
              tool=raw, extra={"notes": "two members named dup.txt; GNU tar and "
                                         "bsdtar both keep the last content"})


# --------------------------------------------------------------------------- #
# Evil fixtures
# --------------------------------------------------------------------------- #
def gen_evil(work: Path) -> None:
    evil = work / "evil"
    evil.mkdir(parents=True)
    raw = _raw_version()
    big = base256_field(1 << 40)

    def add(
        name: str,
        parts: list[bytes],
        *,
        fmt: str = "ustar-raw",
        policy: str,
        btar_exit: str,
        notes: str,
        entries: list[str],
        checks: list[str] | None = None,
        btar_args: list[str] | None = None,
        eof_blocks: int = 2,
    ) -> None:
        path = evil / f"{name}.tar"
        path.write_bytes(archive(parts, eof_blocks=eof_blocks))
        extra = {
            "entries": entries,
            "expected": {
                "policy": policy,
                "btar_exit": btar_exit,
                "checks": checks or [],
                "btar_args": btar_args or [],
                "note": notes,
            },
        }
        _register(EVIL, kind="evil", name=name, relpath=f"evil/{name}.tar",
                  path=path, fmt=fmt, tool=raw, extra=extra)

    add("absolute_path",
        [entry(b"evil\n", name=b"/tmp/tar-bend-abs-escape.txt")],
        policy="refuse", btar_exit="nonzero",
        notes="absolute member name; GNU tar and bsdtar strip the leading '/', "
              "btar policy rejects absolute paths (AGENTS.md)",
        entries=["/tmp/tar-bend-abs-escape.txt"])

    add("dotdot_traversal",
        [entry(b"evil\n", name=b"../tar-bend-traversal-escape.txt")],
        policy="refuse", btar_exit="nonzero",
        notes="'..' component; both control tools refuse to write outside root",
        entries=["../tar-bend-traversal-escape.txt"])

    add("symlink_then_file_through_symlink",
        [
            entry(name=b"escape", typeflag=b"2", linkname=b"../outside"),
            entry(b"pwned\n", name=b"escape/pwned.txt"),
        ],
        policy="refuse", btar_exit="nonzero", checks=["no-symlink-follow"],
        notes="symlink then regular file below it; extraction must not follow the "
              "link out of the destination root",
        entries=["escape -> ../outside", "escape/pwned.txt"])

    add("absolute_symlink",
        [entry(name=b"abs-link", typeflag=b"2", linkname=b"/etc/passwd")],
        policy="allow", btar_exit="zero",
        notes="absolute symlink target: allowed by plan (tar-compatible); only the "
              "link is created inside root, it must never be traversed",
        entries=["abs-link -> /etc/passwd"])

    add("hardlink_escape",
        [entry(name=b"hardlink-escape", typeflag=b"1",
               linkname=b"../../etc/passwd")],
        policy="refuse", btar_exit="nonzero",
        notes="hardlink target outside the destination root",
        entries=["hardlink-escape link to ../../etc/passwd"])

    add("cross_dir_hardlink_escape",
        [
            entry(b"payload\n", name=b"a/one.txt"),
            ustar_header(b"b/escape", typeflag=b"1", linkname=b"../a/one.txt"),
        ],
        policy="refuse", btar_exit="nonzero",
        notes="cross-directory hardlink whose target contains '..'; M3 link "
              "policy must refuse it (no path escape, no outside inode)",
        entries=["a/one.txt", "b/escape link to ../a/one.txt"])

    add("hardlink_to_symlink",
        [
            entry(name=b"symlink-target", typeflag=b"2", linkname=b"/etc/passwd"),
            entry(name=b"hardlink-to-symlink", typeflag=b"1",
                  linkname=b"symlink-target"),
        ],
        policy="refuse", btar_exit="nonzero",
        notes="hardlinks may only target regular files extracted in this run",
        entries=["symlink-target -> /etc/passwd",
                 "hardlink-to-symlink link to symlink-target"])

    add("one_top_level_hardlink_escape",
        [
            entry(b"data\n", name=b"file.txt"),
            entry(name=b"sub/hard", typeflag=b"1", linkname=b"../file.txt"),
            entry(name=b"sub/escape", typeflag=b"1",
                  linkname=b"../../outside/sentinel.txt"),
        ],
        policy="refuse", btar_exit="nonzero",
        btar_args=["--one-top-level"],
        notes="CVE-2026-18508 style: --one-top-level + hardlink whose target "
              "traverses out of the chosen top-level directory",
        entries=["file.txt", "sub/hard link to ../file.txt",
                 "sub/escape link to ../../outside/sentinel.txt"])

    for name, typeflag, major, minor, what in (
        ("fifo", b"6", 0, 0, "FIFO"),
        ("char_device", b"3", 1, 3, "character device 1,3 (/dev/null)"),
        ("block_device", b"4", 8, 0, "block device 8,0"),
    ):
        add(name,
            [ustar_header(f"{name}.special".encode(), typeflag=typeflag,
                          devmajor=major, devminor=minor)],
            policy="refuse", btar_exit="nonzero", checks=["no-special-files"],
            notes=f"{what} member: listable but extraction refused by default",
            entries=[f"{name}.special (typeflag {typeflag.decode()})"])

    for name, typeflag, what in (
        ("sparse_S", b"S", "old GNU sparse header"),
        ("dumpdir_D", b"D", "GNU dumpdir header"),
        ("multivolume_M", b"M", "GNU multi-volume continuation"),
    ):
        add(name,
            [ustar_header(f"{name}.special".encode(), typeflag=typeflag)],
            policy="refuse", btar_exit="nonzero",
            notes=f"{what}: not supported, extraction must not guess",
            entries=[f"{name}.special (typeflag {typeflag.decode()})"])

    add("bad_checksum",
        [ustar_header(b"bad-checksum.txt", size=2, checksum_delta=1),
         block_pad(b"xx")],
        policy="refuse", btar_exit="nonzero",
        notes="header checksum does not match field bytes",
        entries=["bad-checksum.txt (checksum+1)"])

    truncated_header = ustar_header(b"truncated-header.txt", size=2)[:256]
    add("truncated_header", [truncated_header], policy="refuse", btar_exit="nonzero",
        notes="archive ends in the middle of a 512-byte header",
        entries=["truncated-header.txt (256/512 header bytes)"], eof_blocks=0)

    add("truncated_data",
        [ustar_header(b"truncated-data.txt", size=1024), b"X" * 100],
        policy="refuse", btar_exit="nonzero", checks=["no-large-file"],
        notes="declared 1024-byte payload, archive ends after 100 bytes",
        entries=["truncated-data.txt (size 1024, 100 data bytes)"], eof_blocks=0)

    add("one_zero_block_eof",
        [entry(b"ok\n", name=b"ok.txt"), b"\0" * 512],
        policy="eof-tolerant", btar_exit="either", eof_blocks=0,
        notes="single zero block then EOF; GNU warns 'lone zero block', bsdtar "
              "accepts; either tolerance or refusal is allowed, never a member",
        entries=["ok.txt", "<one zero block>"])

    oversized = pax_record(b"comment", b"A" * 70000)
    add("oversized_pax",
        [
            pax_header([oversized], name=b"PaxHeaders/oversized", typeflag=b"x"),
            entry(b"x", name=b"oversized-pax.txt"),
        ],
        policy="refuse", btar_exit="nonzero",
        notes="pax record ~70 KiB; btar caps pax payload at 64 KiB (GNU/bsdtar "
              "happen to accept it)",
        entries=["<x header: comment=70000 bytes>", "oversized-pax.txt"])

    overflow = b"18446744073709551616 path=overflow.txt\n"
    add("pax_length_overflow",
        [
            entry(overflow, name=b"PaxHeaders/overflow", typeflag=b"x"),
            entry(b"x", name=b"pax-overflow.txt"),
        ],
        policy="refuse", btar_exit="nonzero",
        notes="pax record length prefix exceeds u64; malformed extended header",
        entries=["<x header: length=18446744073709551616>",
                 "pax-overflow.txt"])

    comp255 = b"a" * 251 + b".txt"
    add("component_255",
        [
            pax_header([pax_record(b"path", comp255)],
                       name=b"PaxHeaders/comp255", typeflag=b"x"),
            entry(b"y", name=b"comp255-placeholder"),
        ],
        policy="limit-accept", btar_exit="zero",
        notes="single path component of exactly 255 bytes: allowed by the limit "
              "policy (component >255 is rejected)",
        entries=[comp255.decode()])

    comp256 = b"a" * 252 + b".txt"
    add("component_256",
        [
            pax_header([pax_record(b"path", comp256)],
                       name=b"PaxHeaders/comp256", typeflag=b"x"),
            entry(b"y", name=b"comp256-placeholder"),
        ],
        policy="refuse", btar_exit="nonzero",
        notes="single path component of 256 bytes exceeds the component limit",
        entries=["<256-byte component>"])

    # Total length 4096 with components <=255: 15 x 255 + 100 + 100 + 54 + 17 '/'.
    path_4096 = b"/".join([b"d" * 255] * 15 + [b"e" * 100, b"f" * 100, b"g" * 54])
    path_4097 = b"/".join([b"d" * 255] * 15 + [b"e" * 100, b"f" * 100, b"g" * 55])
    assert len(path_4096) == 4096 and len(path_4097) == 4097
    add("path_4096",
        [
            pax_header([pax_record(b"path", path_4096)],
                       name=b"PaxHeaders/path4096", typeflag=b"x"),
            entry(b"z", name=b"path4096-placeholder"),
        ],
        policy="limit-accept", btar_exit="either",
        notes="total path length exactly 4096: accepted by policy, but the host "
              "filesystem (PATH_MAX) may still fail extraction; must not escape",
        entries=["<4096-byte path>"])
    add("path_4097",
        [
            pax_header([pax_record(b"path", path_4097)],
                       name=b"PaxHeaders/path4097", typeflag=b"x"),
            entry(b"z", name=b"path4097-placeholder"),
        ],
        policy="refuse", btar_exit="nonzero",
        notes="total path length 4097 exceeds the total-path limit",
        entries=["<4097-byte path>"])

    add("bomb_huge_size_small_data",
        [ustar_header(b"bomb.bin", raw_size=big), b"tiny"],
        policy="refuse", btar_exit="nonzero", checks=["no-large-file"],
        eof_blocks=0,
        notes="header declares 1 TiB of data but only 4 bytes follow; must abort "
              "without allocating/writing the declared size",
        entries=["bomb.bin (declared size 1 TiB, 4 data bytes)"])

    add("duplicate_hardlink_targets",
        [
            entry(b"hello\n", name=b"target.txt"),
            entry(name=b"hard-a", typeflag=b"1", linkname=b"target.txt"),
            entry(name=b"hard-b", typeflag=b"1", linkname=b"target.txt"),
            entry(name=b"hard-chain", typeflag=b"1", linkname=b"hard-a"),
        ],
        policy="allow", btar_exit="either",
        notes="several hardlinks to the same target plus a hardlink-to-hardlink; "
              "link count semantics, all must resolve inside root",
        entries=["target.txt", "hard-a link to target.txt",
                 "hard-b link to target.txt", "hard-chain link to hard-a"])


# --------------------------------------------------------------------------- #
# gzip-compressed corpus (M5)
# --------------------------------------------------------------------------- #
GZIP_LEVEL_SPECS = [
    ("single_file_gz", "single_file.tar", 9),
    ("dirs_nested_gz", "dirs_nested.tar", 1),
    ("long_name_pax_gz", "long_name_pax.tar", 9),
    ("gnu_longname_gz", "gnu_longname.tar", 9),
    ("non_utf8_name_gz", "non_utf8_name.tar", 1),
    ("hardlink_gz", "hardlink.tar", 9),
    ("symlink_relative_gz", "symlink_relative.tar", 1),
    ("pad_511_gz", "pad_511.tar", 9),
    ("pad_512_gz", "pad_512.tar", 9),
    ("pad_513_gz", "pad_513.tar", 9),
    ("pad_4096_gz", "pad_4096.tar", 9),
    ("big_1mib_gz", "big_1mib.tar", 9),
]


def _gzip_version() -> str:
    return subprocess.run(
        ["gzip", "--version"], capture_output=True, text=True, env=ENV, check=True
    ).stdout.splitlines()[0].strip()


def _gzip_compress(data: bytes, level: int) -> bytes:
    """GNU gzip with -n (no name/mtime in the header) -> deterministic bytes."""
    return subprocess.run(
        ["gzip", f"-{level}", "-n", "-c"], input=data, capture_output=True,
        env=ENV, check=True,
    ).stdout


def _zlib_gzip(data: bytes, level: int) -> bytes:
    """gzip container written by Python zlib (deterministic header: mtime 0)."""
    compressor = zlib.compressobj(level, zlib.DEFLATED, 31)
    return compressor.compress(data) + compressor.flush()


def _register_gzip(
    bucket: list[dict], *, kind: str, name: str, relpath: str, path: Path,
    tool: str, extra: dict,
) -> None:
    record = {
        "name": name,
        "kind": kind,
        "file": relpath,
        "format": "tar+gzip",
        "compression": "gzip",
        "tool": tool,
        "size": path.stat().st_size,
        "sha256": _sha256(path),
    }
    if kind == "valid":
        record["expected"] = {"extract": "ok", "exit": 0}
    record.update(extra)
    bucket.append(record)


def gen_gzip(work: Path) -> None:
    valid_dir = work / "gzip" / "valid"
    evil_dir = work / "gzip" / "evil"
    valid_dir.mkdir(parents=True)
    evil_dir.mkdir(parents=True)
    source_dir = work / "valid"
    gzip_tool = _gzip_version()
    python_tool = _raw_version()

    def register_valid(
        name: str, path: Path, *, source: str, level: str, tool: str,
        notes: str, profile: str = "deflate",
    ) -> None:
        _register_gzip(
            GZIP_VALID, kind="valid", name=name,
            relpath=f"gzip/valid/{name}.tar.gz", path=path, tool=tool,
            extra={
                "source": f"valid/{source}",
                "members": _archive_members(source_dir / source),
                "gzip_level": level,
                "profile": profile,
                "notes": notes,
            })

    # gzip -1 / -9 versions of selected GNU-tar archives.
    for name, source, level in GZIP_LEVEL_SPECS:
        payload = (source_dir / source).read_bytes()
        path = valid_dir / f"{name}.tar.gz"
        path.write_bytes(_gzip_compress(payload, level))
        register_valid(
            name, path, source=source, level=f"-{level}",
            tool=f"{gzip_tool} -{level} -n",
            notes=f"gzip -{level} -n of {source}")

    # Stored DEFLATE blocks (no compression) via Python zlib level 0.
    stored_source = "dirs_nested.tar"
    path = valid_dir / "stored_level_gz.tar.gz"
    path.write_bytes(_zlib_gzip((source_dir / stored_source).read_bytes(), 0))
    register_valid(
        "stored_level_gz", path, source=stored_source, level="0",
        tool=f"{python_tool} zlib level-0", profile="stored",
        notes="gzip container with stored (uncompressed) DEFLATE blocks")

    # Multi-member gzip: split the tar stream into two chunks, compress each
    # independently, concatenate the two gzip members.
    multi_source = "dirs_nested.tar"
    stream = (source_dir / multi_source).read_bytes()
    half = ((len(stream) // 2) // 512) * 512
    first = _gzip_compress(stream[:half], 1)
    second = _gzip_compress(stream[half:], 9)
    path = valid_dir / "multi_member_gz.tar.gz"
    path.write_bytes(first + second)
    register_valid(
        "multi_member_gz", path, source=multi_source, level="-1/-9",
        tool=f"{gzip_tool} -1 + -9 (2 members)", profile="multi-member",
        notes="two concatenated gzip members over one tar stream")

    # Corrupt gzip fixtures: byte-exact with deterministic corruption.
    base = bytearray(_gzip_compress((source_dir / "dirs_nested.tar").read_bytes(), 9))

    def evil_seed() -> bytearray:
        return bytearray(base)

    def register_evil(name: str, data: bytes, notes: str) -> None:
        path = evil_dir / f"{name}.tar.gz"
        path.write_bytes(data)
        _register_gzip(
            GZIP_EVIL, kind="evil", name=name,
            relpath=f"gzip/evil/{name}.tar.gz", path=path, tool="python-corrupt",
            extra={
                "source": "valid/dirs_nested.tar",
                "expected": {
                    "policy": "refuse",
                    "btar_exit": "fatal",
                    "exit": 2,
                    "checks": [],
                    "note": notes,
                },
            })

    bad = evil_seed()
    bad[0] = 0x00
    register_evil("gzip_bad_magic", bytes(bad),
                  "gzip magic is not 1f 8b; -z must reject and auto-detect must not guess gzip")

    bad = evil_seed()
    bad[2] = 0x07  # compression method 7 (reserved)
    register_evil("gzip_bad_cm", bytes(bad),
                  "compression method CM=7; only CM=8 (deflate) is supported")

    register_evil("gzip_truncated_header", bytes(evil_seed()[:6]),
                  "gzip stream ends inside the 10-byte header")

    bad = evil_seed()
    bad[-8] ^= 0xFF  # CRC32 field
    register_evil("gzip_bad_crc", bytes(bad),
                  "trailer CRC32 does not match the decompressed payload")

    bad = evil_seed()
    bad[-4] ^= 0xFF  # ISIZE field
    register_evil("gzip_bad_isize", bytes(bad),
                  "trailer ISIZE (mod 2^32 size) does not match the output")

    register_evil("gzip_truncated_deflate",
                  bytes(evil_seed()[: len(base) // 2]),
                  "stream ends in the middle of the DEFLATE data")

    bad = evil_seed()
    bad[-4:] = b"\xff\xff\xff\xff"
    register_evil("gzip_bomb_isize", bytes(bad),
                  "ISIZE claims 4 GiB - 1 output; reader must detect the size "
                  "mismatch without materialising/allocating the declared size")


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def _load_previous_manifest() -> dict | None:
    manifest = OUT / "manifest.json"
    if not manifest.is_file():
        return None
    try:
        return json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _determinism_report(previous: dict | None) -> tuple[bool | None, list[str]]:
    if previous is None:
        return None, []
    old = {
        f["file"]: f["sha256"]
        for key in ("valid", "evil", "gzip_valid", "gzip_evil")
        for f in previous.get(key, [])
    }
    new = {f["file"]: f["sha256"]
           for f in VALID + EVIL + GZIP_VALID + GZIP_EVIL}
    changed = sorted(name for name in new if old.get(name) != new[name])
    changed += sorted(name for name in old if name not in new)
    return (not changed, changed)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate tar-bend fixtures.")
    parser.add_argument("--keep-sources", action="store_true",
                        help="keep the temporary source tree")
    parser.add_argument("--verbose", action="store_true",
                        help="print one line per fixture")
    args = parser.parse_args(argv)

    for tool in ("tar", "gzip"):
        if shutil.which(tool) is None:
            print(f"gen_fixtures: required tool not found: {tool}", file=sys.stderr)
            return 2

    previous = _load_previous_manifest()
    staging = Path(tempfile.mkdtemp(prefix=".gen-", dir=FIXTURES))
    sources = Path(tempfile.mkdtemp(prefix="tar-bend-src-"))
    started = time.time()
    try:
        src = sources / "src"
        src.mkdir()
        build_source_tree(src)
        gen_valid(staging, src)
        gen_evil(staging)
        gen_gzip(staging)

        VALID.sort(key=lambda f: f["name"])
        EVIL.sort(key=lambda f: f["name"])
        GZIP_VALID.sort(key=lambda f: f["name"])
        GZIP_EVIL.sort(key=lambda f: f["name"])
        gzip_bytes = sum(f["size"] for f in GZIP_VALID + GZIP_EVIL)
        if gzip_bytes >= GZIP_LIMIT:
            print(f"gen_fixtures: gzip corpus is {gzip_bytes} bytes, limit is "
                  f"{GZIP_LIMIT}", file=sys.stderr)
            return 1
        total_bytes = sum(f["size"] for f in VALID + EVIL) + gzip_bytes
        if total_bytes >= TOTAL_LIMIT:
            print(f"gen_fixtures: corpus is {total_bytes} bytes, limit is "
                  f"{TOTAL_LIMIT}; reduce fixture sizes", file=sys.stderr)
            return 1

        deterministic, changed = _determinism_report(previous)
        manifest = {
            "generator": "tools/gen_fixtures.py",
            "schema": MANIFEST_SCHEMA,
            "tools": {"gnu_tar": _gnu_version(), "python": sys.version.split()[0]},
            "totals": {
                "valid": len(VALID),
                "evil": len(EVIL),
                "gzip_valid": len(GZIP_VALID),
                "gzip_evil": len(GZIP_EVIL),
                "bytes": total_bytes,
                "gzip_bytes": gzip_bytes,
                "limit_bytes": TOTAL_LIMIT,
                "gzip_limit_bytes": GZIP_LIMIT,
            },
            "valid": VALID,
            "evil": EVIL,
            "gzip_valid": GZIP_VALID,
            "gzip_evil": GZIP_EVIL,
        }
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

        staging.chmod(0o755)
        if OUT.exists():
            shutil.rmtree(OUT)
        staging.rename(OUT)
    except subprocess.CalledProcessError as exc:
        print(f"gen_fixtures: command failed ({exc.cmd}): {exc}", file=sys.stderr)
        return 1
    finally:
        if staging.exists():
            shutil.rmtree(staging)
        if args.keep_sources:
            print(f"kept source tree: {src}")
        else:
            shutil.rmtree(sources, ignore_errors=True)

    elapsed = time.time() - started
    print(f"wrote {len(VALID)} valid + {len(EVIL)} evil + "
          f"{len(GZIP_VALID)} gzip-valid + {len(GZIP_EVIL)} gzip-evil fixtures "
          f"to {OUT.relative_to(ROOT)} ({total_bytes / 1024:.0f} KiB, "
          f"limits {TOTAL_LIMIT // (1024 * 1024)} MiB / "
          f"{GZIP_LIMIT // (1024 * 1024)} MiB gzip) in {elapsed:.2f}s")
    if deterministic is None:
        print("determinism: no previous manifest (first generation)")
    elif deterministic:
        print(f"determinism: OK ({len(VALID) + len(EVIL) + len(GZIP_VALID) + len(GZIP_EVIL)} "
              f"sha256 values unchanged)")
    else:
        print("determinism: FAILED, changed fixtures: " + ", ".join(changed),
              file=sys.stderr)
        return 1
    if args.verbose:
        for record in VALID + EVIL + GZIP_VALID + GZIP_EVIL:
            print(f"  {record['file']:42s} {record['format']:14s} "
                  f"{record['size']:8d}  {record['sha256'][:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
