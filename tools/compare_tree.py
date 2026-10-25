#!/usr/bin/env python3
"""Compare two extracted tar trees (or two tar -tvf listings) for tar-bend.

Tree mode compares entry sets, entry types, modes, file contents (sha256),
symlink targets and normalised hardlink groups; uid/gid/ctime are ignored.
mtime is opt-in via --mtime with a tolerance (default 1.0 s).

Listing mode normalises GNU tar and bsdtar `-tv` output to (type, perms, size,
name, link target), ignoring date/owner/group, so the two tools can be diffed.

Usage:
    tools/compare_tree.py A B [--mtime] [--strict-modes] [--mtime-tol SECONDS]
    tools/compare_tree.py --listings GNU.list BSD.list [--unordered]

Exit codes: 0 identical, 1 differences, 2 usage/IO error.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import os
import re
import stat
import sys
from dataclasses import dataclass

KIND_BY_TYPE = {
    stat.S_IFREG: "file",
    stat.S_IFDIR: "dir",
    stat.S_IFLNK: "symlink",
    stat.S_IFIFO: "fifo",
    stat.S_IFCHR: "char",
    stat.S_IFBLK: "block",
    stat.S_IFSOCK: "socket",
}
DEFAULT_MODE_MASK = 0o777
STRICT_MODE_MASK = 0o7777
GNU_DATE = re.compile(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2}(?:\.\d+)?)? ")
BSD_DATE = re.compile(r"[A-Z][a-z]{2} +\d{1,2} +(?:[0-9]{4}|[0-9]{2}:[0-9]{2}(?::[0-9]{2})?) ")
MAX_DIFFS_DEFAULT = 200


# --------------------------------------------------------------------------- #
# Tree comparison
# --------------------------------------------------------------------------- #
@dataclass
class Entry:
    relpath: str
    kind: str
    mode: int  # already masked
    size: int
    sha256: str | None
    link: str | None
    dev: int
    ino: int
    nlink: int
    mtime: float


def _hash_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _scan(root: str, mode_mask: int) -> dict[str, Entry]:
    entries: dict[str, Entry] = {}
    hash_cache: dict[tuple[int, int], str] = {}

    def walk(rel: str) -> None:
        full = os.path.join(root, rel) if rel else root
        with os.scandir(full) as scan:
            children = sorted(scan, key=lambda item: item.name)
        for child in children:
            child_rel = f"{rel}/{child.name}" if rel else child.name
            st = child.stat(follow_symlinks=False)
            kind = KIND_BY_TYPE.get(stat.S_IFMT(st.st_mode))
            sha256 = link = None
            if kind == "file":
                key = (st.st_dev, st.st_ino)
                if key in hash_cache:
                    sha256 = hash_cache[key]
                else:
                    sha256 = _hash_file(child.path)
                    hash_cache[key] = sha256
            elif kind == "symlink":
                link = os.readlink(child.path)
            entries[child_rel] = Entry(
                relpath=child_rel,
                kind=kind or f"unknown({oct(stat.S_IFMT(st.st_mode))})",
                mode=stat.S_IMODE(st.st_mode) & mode_mask,
                size=st.st_size,
                sha256=sha256,
                link=link,
                dev=st.st_dev,
                ino=st.st_ino,
                nlink=st.st_nlink,
                mtime=st.st_mtime,
            )
            if kind == "dir":
                walk(child_rel)

    walk("")
    return entries


def _hardlink_groups(entries: dict[str, Entry]) -> set[frozenset[str]]:
    groups: dict[tuple[int, int], list[str]] = {}
    for entry in entries.values():
        if entry.kind == "file" and entry.nlink > 1:
            groups.setdefault((entry.dev, entry.ino), []).append(entry.relpath)
    return {frozenset(names) for names in groups.values()}


def _describe(entry: Entry) -> str:
    if entry.kind == "file":
        return f"file, mode {entry.mode:04o}, {entry.size} B"
    if entry.kind == "symlink":
        return f"symlink -> {entry.link!r}"
    return f"{entry.kind}, mode {entry.mode:04o}"


def compare_trees(
    root_a: str, root_b: str, *, mode_mask: int, check_mtime: bool, mtime_tol: float
) -> list[str]:
    for root in (root_a, root_b):
        if not os.path.isdir(root):
            raise FileNotFoundError(f"not a directory: {root}")
    entries_a = _scan(root_a, mode_mask)
    entries_b = _scan(root_b, mode_mask)
    diffs: list[str] = []

    for name in sorted(set(entries_a) - set(entries_b)):
        diffs.append(f"only in A: {name!r} ({_describe(entries_a[name])})")
    for name in sorted(set(entries_b) - set(entries_a)):
        diffs.append(f"only in B: {name!r} ({_describe(entries_b[name])})")

    for name in sorted(set(entries_a) & set(entries_b)):
        a, b = entries_a[name], entries_b[name]
        if a.kind != b.kind:
            diffs.append(f"type: {name!r}: {a.kind} in A, {b.kind} in B")
            continue
        if a.mode != b.mode:
            diffs.append(
                f"mode: {name!r}: {a.mode:04o} in A, {b.mode:04o} in B "
                f"(mask {mode_mask:04o})"
            )
        if a.kind == "file":
            if a.sha256 != b.sha256:
                diffs.append(
                    f"content: {name!r}: sha256 {a.sha256} in A, {b.sha256} in B"
                )
            elif a.size != b.size:
                diffs.append(f"size: {name!r}: {a.size} in A, {b.size} in B")
        elif a.kind == "symlink" and a.link != b.link:
            diffs.append(f"symlink target: {name!r}: {a.link!r} in A, {b.link!r} in B")
        if check_mtime and a.kind in ("file", "dir"):
            delta = abs(a.mtime - b.mtime)
            if delta > mtime_tol:
                diffs.append(
                    f"mtime: {name!r}: {a.mtime:.6f} in A, {b.mtime:.6f} in B "
                    f"(delta {delta:.6f}s > tol {mtime_tol:g}s)"
                )

    groups_a = _hardlink_groups(entries_a)
    groups_b = _hardlink_groups(entries_b)
    if groups_a != groups_b:
        only_a = sorted(sorted(group) for group in groups_a - groups_b)
        only_b = sorted(sorted(group) for group in groups_b - groups_a)
        if only_a:
            diffs.append(f"hardlink groups only in A: {only_a}")
        if only_b:
            diffs.append(f"hardlink groups only in B: {only_b}")
    return diffs


# --------------------------------------------------------------------------- #
# Listing normalisation (GNU tar -tv vs bsdtar -tv)
# --------------------------------------------------------------------------- #
def _normalise_line(line: str, source: str, lineno: int) -> tuple[str, str, int, str, str]:
    match = re.match(r"^(?P<mode>\S{10})\s+(?P<rest>.*)$", line)
    if not match:
        raise ValueError(f"{source}:{lineno}: cannot parse listing line: {line!r}")
    mode, rest = match.group("mode"), match.group("rest")
    perms = mode[1:10]

    # GNU: "owner size <date> name"; bsdtar: "nlink owner group size <date> name".
    # In both layouts the field immediately before the timestamp is the size.
    gnu_date = GNU_DATE.search(rest)
    bsd_date = BSD_DATE.search(rest)
    date_match = gnu_date or bsd_date
    if date_match is None:
        raise ValueError(f"{source}:{lineno}: cannot find a timestamp in {line!r}")
    prefix, name = rest[: date_match.start()], rest[date_match.end():]
    try:
        size = int(prefix.split()[-1])
    except (IndexError, ValueError) as exc:
        raise ValueError(f"{source}:{lineno}: cannot parse size in {line!r}") from exc

    type_char = mode[0]
    if type_char == "h" or " link to " in name:
        if " link to " not in name:
            raise ValueError(f"{source}:{lineno}: hardlink without target: {line!r}")
        name, target = name.split(" link to ", 1)
        type_char = "h"
    elif type_char == "l":
        if " -> " not in name:
            raise ValueError(f"{source}:{lineno}: symlink without target: {line!r}")
        name, target = name.split(" -> ", 1)
    else:
        target = ""
    return (type_char, perms, size, name, target)


def _canonical_line(canonical: tuple[str, str, int, str, str]) -> str:
    type_char, perms, size, name, target = canonical
    if type_char == "h":
        return f"h {perms} {size} {name} link to {target}"
    if type_char == "l":
        return f"l {perms} {size} {name} -> {target}"
    return f"{type_char} {perms} {size} {name}"


def read_listing(path: str) -> list[tuple[str, str, int, str, str]]:
    with open(path, "rb") as handle:
        text = handle.read().decode("utf-8", "surrogateescape")
    canonical = [
        _normalise_line(line, path, lineno)
        for lineno, line in enumerate(text.splitlines(), 1)
        if line.strip()
    ]
    return canonical


def compare_listings(listing_a: str, listing_b: str, unordered: bool = False) -> list[str]:
    canon_a = read_listing(listing_a)
    canon_b = read_listing(listing_b)
    lines_a = [_canonical_line(item) for item in canon_a]
    lines_b = [_canonical_line(item) for item in canon_b]
    if unordered:
        lines_a.sort()
        lines_b.sort()
    if lines_a == lines_b:
        return []
    return list(
        difflib.unified_diff(
            lines_a, lines_b, fromfile=listing_a, tofile=listing_b, lineterm=""
        )
    )


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Compare tar extraction trees or tar -tv listings.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("paths", nargs="*", metavar="DIR",
                        help="two extracted directory roots (tree mode)")
    parser.add_argument("--listings", nargs=2, metavar=("GNU_LIST", "BSD_LIST"),
                        help="compare two -tv listings instead of trees")
    parser.add_argument("--unordered", action="store_true",
                        help="listings: compare as sorted multisets (member order ignored)")
    parser.add_argument("--mtime", action="store_true",
                        help="also compare mtimes (files and directories)")
    parser.add_argument("--mtime-tol", type=float, default=1.0, metavar="SECONDS",
                        help="mtime tolerance in seconds (default 1.0)")
    parser.add_argument("--strict-modes", action="store_true",
                        help="compare setuid/setgid/sticky bits too (mask 07777)")
    parser.add_argument("--max-diffs", type=int, default=MAX_DIFFS_DEFAULT,
                        metavar="N", help="print at most N differences")
    args = parser.parse_args(argv)

    try:
        if args.listings:
            if args.paths:
                parser.error("--listings cannot be combined with DIR arguments")
            diffs = compare_listings(*args.listings, unordered=args.unordered)
            subject = f"listings {args.listings[0]} vs {args.listings[1]}"
        else:
            if len(args.paths) != 2:
                parser.error("tree mode needs exactly two DIR arguments")
            mode_mask = STRICT_MODE_MASK if args.strict_modes else DEFAULT_MODE_MASK
            diffs = compare_trees(
                args.paths[0],
                args.paths[1],
                mode_mask=mode_mask,
                check_mtime=args.mtime,
                mtime_tol=args.mtime_tol,
            )
            subject = f"trees {args.paths[0]} vs {args.paths[1]}"
    except (OSError, ValueError) as exc:
        print(f"compare_tree: error: {exc}", file=sys.stderr)
        return 2

    shown = diffs[: args.max_diffs]
    for diff in shown:
        print(f"diff: {diff}")
    if len(diffs) > len(shown):
        print(f"diff: ... {len(diffs) - len(shown)} more difference(s) hidden")
    if diffs:
        print(f"compare_tree: {len(diffs)} difference(s): {subject}")
        return 1
    print(f"compare_tree: OK: {subject}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
