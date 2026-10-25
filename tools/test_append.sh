#!/usr/bin/env bash
# test_append.sh — v1.2 append/update harness: `btar -rf` / `btar -uf` vs GNU tar.
#
# Every differential case starts both tools from the same archive, applies the
# same `-r`/`-u` operation, and then checks that the btar result
#   * keeps the original archive bytes up to its logical end (byte-for-byte);
#   * ends exactly at <logical end> + 1024 zero bytes (no stale tail);
#   * is readable by GNU tar without warnings, and by bsdtar;
#   * has the same normalised `tar -tv` listing as the GNU result;
#   * extracts to the same tree as the GNU result;
#   * has the same exit status as GNU tar.
# Error cases (corrupt/truncated archive, missing operand, -z, option clashes)
# require exit 2 and a byte-identical archive afterwards.
#
# Usage: ./tools/test_append.sh [--keep]    (BTAR=/path/to/btar to override)
# Exit codes: 0 pass, 1 failures, 2 setup error.
set -u
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE="$ROOT/tools/compare_tree.py"
TAREND="$ROOT/tools/tar_end.py"
BTAR="${BTAR:-$ROOT/build/btar}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

for tool in python3 tar find touch cmp gzip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "test_append: need $tool" >&2; exit 2; }
done
[ -x "$BTAR" ] || { echo "test_append: BTAR not executable: $BTAR" >&2; exit 2; }

umask 022
export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-append.XXXXXX")"
trap '[ "$KEEP" = 1 ] || rm -rf -- "$TMP"' EXIT
SRC="$TMP/src"
mkdir -p "$SRC" "$TMP/cases"

# ------------------------------------------------------------------ trees --
python3 - "$SRC" <<'PY'
import os, sys, pathlib
src = pathlib.Path(sys.argv[1])
b = src / "base"
def w(rel, data, mode=0o644):
    p = b / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    os.chmod(p, mode)
w("hello.txt", b"hello world\n")
w("extra.txt", b"extra file\n")
w("empty.txt", b"")
w("big.bin", (b"0123456789abcdef" * 13000))
w("pad513.bin", b"p" * 513)
w("dirs/nested/deep.txt", b"deep\n")
w("dirs/a.txt", b"a\n")
w("dirs/b.txt", b"b\n")
w("modes/run.sh", b"#!/bin/sh\n", 0o755)
w("hard/orig.bin", b"hardlinked\n")
os.link(b / "hard/orig.bin", b / "hard/link.bin")
(b / "links").mkdir()
os.symlink("../hello.txt", b / "links/rel")
os.symlink("dangling", b / "links/dangling")
w("long/" + "l" * 120 + ".txt", b"long name\n")
(b / "special").mkdir()
os.mkfifo(b / "special/pipe", 0o644)
for p in sorted(b.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    os.utime(p, (1577836800, 1577836800), follow_symlinks=False)
os.utime(b, (1577836800, 1577836800))
PY

pass=0; fail=0; failures=""
CASE=""; D=""
note_fail() { fail=$((fail + 1)); failures+="$CASE: $1"$'\n'; printf '  FAIL %s: %s\n' "$CASE" "$1"; }
ok() { pass=$((pass + 1)); printf '  PASS %s\n' "$CASE"; }

begin() { CASE="$1"; D="$TMP/cases/$1"; rm -rf "$D"; mkdir -p "$D"; CF=0; UPD=${UPDMODE:-0}; }
# init ARGS...: both archives start from GNU `tar -cf` of ARGS (cwd = $SRC).
init() { ( cd "$SRC" && tar -cf "$D/ref.tar" "$@" ) && cp "$D/ref.tar" "$D/ours.tar"; cp "$D/ref.tar" "$D/orig.tar"; }
# run_ref / run_ours ARGS...: operation on each archive (cwd = $SRC).
run_ref()  { ( cd "$SRC" && tar "$@" ) >"$D/ref.out" 2>"$D/ref.err"; REF_RC=$?; }
run_ours() { ( cd "$SRC" && "$BTAR" "$@" ) >"$D/ours.out" 2>"$D/ours.err"; OURS_RC=$?; }

orig_end() { python3 "$TAREND" "$D/orig.tar" | awk '{print $2}'; }

# verify: full differential check of $D/ours.tar against $D/ref.tar.
verify() {
    local bad=0
    if [ "$REF_RC" -ne "$OURS_RC" ]; then
        note_fail "exit status: GNU=$REF_RC btar=$OURS_RC ($(head -n1 "$D/ours.err"))"; bad=1
    fi
    if [ "$OURS_RC" -ne 0 ] && [ "$OURS_RC" -ne 1 ]; then return 1; fi
    # original prefix preserved byte-for-byte
    if [ -s "$D/orig.tar" ]; then
        local end; end="$(orig_end)"
        if ! cmp -s -n "$end" "$D/orig.tar" "$D/ours.tar"; then
            note_fail "original entries changed (first $end bytes differ)"; bad=1
        fi
    fi
    # exact trailer
    if ! python3 "$TAREND" "$D/ours.tar" --strict >"$D/end.out" 2>&1; then
        note_fail "bad trailer/end ($(tr '\n' ' ' <"$D/end.out"))"; bad=1
    fi
    if ! tar -tf "$D/ours.tar" >"$D/ours.names" 2>"$D/ours.read.err" || [ -s "$D/ours.read.err" ]; then
        note_fail "GNU tar cannot read result cleanly: $(head -n1 "$D/ours.read.err")"; return 1
    fi
    if command -v bsdtar >/dev/null 2>&1 && ! bsdtar -tf "$D/ours.tar" >/dev/null 2>"$D/bsd.err"; then
        note_fail "bsdtar cannot read result: $(head -n1 "$D/bsd.err")"; bad=1
    fi
    tar -tvf "$D/ref.tar" >"$D/ref.list" 2>/dev/null
    tar -tvf "$D/ours.tar" >"$D/ours.list" 2>/dev/null
    local order=; [ "$UPD" = 1 ] && order=--unordered # GNU -u visits files before subdirectories
    if ! python3 "$COMPARE" --listings "$D/ref.list" "$D/ours.list" $order >"$D/list.diff" 2>&1; then
        note_fail "listing differs (see $D/list.diff)"; sed 's/^/      /' "$D/list.diff" | head -12; bad=1
    fi
    mkdir -p "$D/ref.d" "$D/ours.d"
    tar -xf "$D/ref.tar" -C "$D/ref.d" 2>/dev/null
    tar -xf "$D/ours.tar" -C "$D/ours.d" 2>/dev/null
    if ! python3 "$COMPARE" "$D/ref.d" "$D/ours.d" >"$D/tree.diff" 2>&1; then
        note_fail "extracted tree differs (see $D/tree.diff)"; sed 's/^/      /' "$D/tree.diff" | head -12; bad=1
    fi
    return $bad
}
finish() { local before=$fail; verify; [ "$fail" -eq "$before" ] && ok; }

# expect_error ARCHIVE_BEFORE ARGS...: btar must exit 2 and leave ARCHIVE alone.
expect_error() {
    local pattern="$1"; shift
    cp "$D/ours.tar" "$D/before.tar" 2>/dev/null || : >"$D/before.tar"
    local existed=0; [ -e "$D/ours.tar" ] && existed=1
    run_ours "$@"
    local before=$fail
    [ "$OURS_RC" -eq 2 ] || note_fail "expected exit 2, got $OURS_RC"
    if [ -n "$pattern" ] && ! grep -qi -- "$pattern" "$D/ours.err"; then
        note_fail "stderr lacks '$pattern': $(head -n1 "$D/ours.err")"
    fi
    if [ "$existed" = 1 ] && ! cmp -s "$D/before.tar" "$D/ours.tar"; then
        note_fail "archive modified by a failed operation"
    elif [ "$existed" = 0 ] && [ -e "$D/ours.tar" ]; then
        note_fail "archive created by a failed operation"
    fi
    [ "$fail" -eq "$before" ] && ok
}

echo "test_append: btar=$BTAR"
echo "== append (-r) =="

begin r-file;       init base/hello.txt
run_ref -rf "$D/ref.tar" base/extra.txt;  run_ours -rf "$D/ours.tar" base/extra.txt; finish
begin r-file-padded; init base/hello.txt   # GNU pads to 10240: the stale tail must go
run_ref -rf "$D/ref.tar" base/pad513.bin base/empty.txt
run_ours -rf "$D/ours.tar" base/pad513.bin base/empty.txt; finish
begin r-dir;        init base/hello.txt
run_ref -rf "$D/ref.tar" --sort=name base/dirs;  run_ours -rf "$D/ours.tar" --sort=name base/dirs; finish
begin r-big;        init base/dirs
run_ref -rf "$D/ref.tar" base/big.bin;  run_ours -rf "$D/ours.tar" base/big.bin; finish
begin r-links;      init base/hello.txt
run_ref -rf "$D/ref.tar" --sort=name base/links base/hard
run_ours -rf "$D/ours.tar" --sort=name base/links base/hard; finish
begin r-link-to-old;  init base/hard/orig.bin   # old members are not registered: stored as data
run_ref -rf "$D/ref.tar" base/hard/link.bin;  run_ours -rf "$D/ours.tar" base/hard/link.bin; finish
begin r-long;       init base/hello.txt
run_ref -rf "$D/ref.tar" base/long;  run_ours -rf "$D/ours.tar" base/long; finish
begin r-pax;        init base/hello.txt
run_ref -rf "$D/ref.tar" --format=posix base/long base/dirs
run_ours -rf "$D/ours.tar" --format=pax base/long base/dirs; finish
begin r-ustar-fmt;  init base/hello.txt
run_ref -rf "$D/ref.tar" --format=ustar base/dirs
run_ours -rf "$D/ours.tar" --format=ustar base/dirs; finish
begin r-C;          init -C base hello.txt
run_ref -rf "$D/ref.tar" -C base extra.txt dirs --sort=name
run_ours -rf "$D/ours.tar" -C base extra.txt dirs --sort=name; finish
begin r-C-dot;      init -C base hello.txt
run_ref -rf "$D/ref.tar" -C base ./extra.txt ./links
run_ours -rf "$D/ours.tar" -C base ./extra.txt ./links; finish
begin r-twice;      init base/hello.txt
run_ref -rf "$D/ref.tar" base/extra.txt; run_ref -rf "$D/ref.tar" base/extra.txt base/dirs --sort=name
run_ours -rf "$D/ours.tar" base/extra.txt; run_ours -rf "$D/ours.tar" base/extra.txt base/dirs --sort=name; finish
begin r-bundled;    init base/hello.txt
run_ref -r -f "$D/ref.tar" -p base/modes;  run_ours -r -f "$D/ours.tar" -p base/modes; finish
begin r-long-option;  init base/hello.txt
run_ref --append -f "$D/ref.tar" base/extra.txt;  run_ours --append -f "$D/ours.tar" base/extra.txt; finish
begin r-bundle-order; init base/hello.txt   # flags in any order: -vrf, -fr is not a bundle
run_ref -vrf "$D/ref.tar" base/extra.txt 2>/dev/null;  run_ours -vrf "$D/ours.tar" base/extra.txt 2>/dev/null; finish
begin r-missing-archive
run_ref -rf "$D/ref.tar" base/hello.txt;   run_ours -rf "$D/ours.tar" base/hello.txt; finish
begin r-empty-file; : >"$D/ref.tar"; : >"$D/ours.tar"; : >"$D/orig.tar"
run_ref -rf "$D/ref.tar" base/hello.txt;   run_ours -rf "$D/ours.tar" base/hello.txt; finish
begin r-no-endblocks  # archive truncated exactly after the last member: EOF is the end
init base/hello.txt; python3 - "$D" <<'PY'
import sys; d=sys.argv[1]
data=open(d+"/ref.tar","rb").read(); n=data.index(b"\0"*1024) if False else 1024
open(d+"/ref.tar","wb").write(data[:1024]); open(d+"/ours.tar","wb").write(data[:1024]); open(d+"/orig.tar","wb").write(data[:1024])
PY
run_ref -rf "$D/ref.tar" base/extra.txt;   run_ours -rf "$D/ours.tar" base/extra.txt; finish
begin r-verbose;    init base/hello.txt
run_ours -rvf "$D/ours.tar" base/extra.txt base/dirs
if [ "$OURS_RC" -eq 0 ] && grep -q 'base/extra.txt' "$D/ours.err" "$D/ours.out" && tar -tf "$D/ours.tar" | grep -q 'dirs/a.txt'; then ok; else note_fail "verbose output missing (rc=$OURS_RC)"; fi
begin r-no-operands; init base/hello.txt
run_ref -rf "$D/ref.tar";  run_ours -rf "$D/ours.tar"; finish
begin r-fifo;       init base/hello.txt   # unsupported type: warn, exit 1, archive stays valid
run_ours -rf "$D/ours.tar" base/special base/extra.txt
if [ "$OURS_RC" -eq 1 ] && tar -tf "$D/ours.tar" 2>/dev/null | grep -q 'extra.txt' \
   && python3 "$TAREND" "$D/ours.tar" --strict >/dev/null && grep -qi 'skipping' "$D/ours.err"; then ok; else note_fail "fifo policy (rc=$OURS_RC)"; fi
begin r-self        # the archive lives in the tree it appends: it is skipped, not dumped
mkdir -p "$D/w"; cp -r "$SRC/base/dirs" "$D/w/dirs"
( cd "$D/w" && "$BTAR" -cf self.tar dirs/a.txt && "$BTAR" -rf self.tar . ) >"$D/ours.out" 2>"$D/ours.err"; OURS_RC=$?
if [ "$OURS_RC" -le 1 ] && tar -tf "$D/w/self.tar" >"$D/self.names" 2>/dev/null \
   && ! grep -qx 'self.tar\|./self.tar' "$D/self.names" && grep -q 'dirs/b.txt' "$D/self.names"; then ok; else note_fail "self archive handling (rc=$OURS_RC)"; fi

echo "== append: errors leave the archive untouched =="
begin e-missing-operand; init base/hello.txt
expect_error 'stat\|No such' -rf "$D/ours.tar" base/nonexistent
begin e-absolute-operand; init base/hello.txt
expect_error 'refused' -rf "$D/ours.tar" /etc/hostname
begin e-dotdot-operand; init base/hello.txt
expect_error 'refused' -rf "$D/ours.tar" ../x
begin e-missing-operand-new   # failed append must not create the archive
rm -f "$D/ours.tar"
expect_error 'stat\|No such' -rf "$D/ours.tar" base/nonexistent
begin e-garbage; init base/hello.txt; head -c 512 /dev/zero | tr '\0' 'x' >"$D/ours.tar"
expect_error 'not a valid\|invalid' -rf "$D/ours.tar" base/extra.txt
begin e-bad-checksum; init base/hello.txt
python3 - "$D/ours.tar" <<'PY'
import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[0]^=1; open(p,"wb").write(b)
PY
expect_error 'not a valid\|invalid\|checksum' -rf "$D/ours.tar" base/extra.txt
begin e-trunc-header; init base/hello.txt; head -c 100 "$D/orig.tar" >"$D/ours.tar"
expect_error 'truncated' -rf "$D/ours.tar" base/extra.txt
begin e-trunc-data; init base/big.bin; head -c 5000 "$D/orig.tar" >"$D/ours.tar"
expect_error 'truncated' -rf "$D/ours.tar" base/extra.txt
begin e-trunc-after-header; init base/pad513.bin; head -c 512 "$D/orig.tar" >"$D/ours.tar"
expect_error 'truncated' -rf "$D/ours.tar" base/extra.txt
begin e-gzip-file; init base/hello.txt; gzip -c "$D/orig.tar" >"$D/ours.tar"
expect_error 'not a valid\|compress' -rf "$D/ours.tar" base/extra.txt
begin e-gzip-flag; init base/hello.txt
expect_error 'compressed' -rzf "$D/ours.tar" base/extra.txt
begin e-gzip-flag-long; init base/hello.txt
expect_error 'compressed' -rf "$D/ours.tar" --gzip base/extra.txt
begin e-update-gzip; init base/hello.txt
expect_error 'compressed' -uzf "$D/ours.tar" base/extra.txt
begin e-dir-archive; mkdir -p "$D/ours.tar.d"
CASE=e-dir-archive; run_ours -rf "$D/ours.tar.d" base/extra.txt
[ "$OURS_RC" -eq 2 ] && ok || note_fail "directory as archive: rc=$OURS_RC"
begin e-no-f; init base/hello.txt
expect_error '' -r base/extra.txt
begin e-stdin;  init base/hello.txt
expect_error 'not supported' -rf - base/extra.txt
for combo in "-rtf" "-rxf" "-ruf" "-rcf" "-urf" "-ucf" "-rOf"; do
    begin "e-clash-${combo#-}"; init base/hello.txt
    expect_error 'usage\|more than one\|both' "$combo" "$D/ours.tar" base/extra.txt
done
begin e-clash-long; init base/hello.txt
expect_error 'usage' -rf "$D/ours.tar" --list base/extra.txt
begin e-clash-append-update; init base/hello.txt
expect_error 'both' --append --update -f "$D/ours.tar" base/extra.txt
begin e-append-gzip-long; init base/hello.txt
expect_error 'compressed' --append --gzip -f "$D/ours.tar" base/extra.txt
begin e-strip-comp-still-works   # regression: --strip-components must not look like -c
mkdir -p "$D/x"; ( cd "$SRC" && tar -cf "$D/s.tar" base/dirs )
run_ours -xf "$D/s.tar" --strip-components=1 -C "$D/x"
[ "$OURS_RC" -eq 0 ] && [ -f "$D/x/dirs/a.txt" ] && ok || note_fail "extract --strip-components rc=$OURS_RC"

echo "== update (-u) =="
UPDMODE=1
reset_mtimes() { find "$SRC/base" -exec touch -h -d '2020-01-01 00:00:00' {} +; }
upd() { # name init-args... — GNU/btar both update from the same initial archive
    :
}
begin u-unchanged; reset_mtimes; init base/dirs base/hello.txt
run_ref -uf "$D/ref.tar" --sort=name base/dirs base/hello.txt
run_ours -uf "$D/ours.tar" --sort=name base/dirs base/hello.txt; finish
begin u-newer-file; reset_mtimes; init base/dirs base/hello.txt
touch -d '2021-06-01 12:00:00' "$SRC/base/dirs/a.txt"
run_ref -uf "$D/ref.tar" --sort=name base/dirs base/hello.txt
run_ours -uf "$D/ours.tar" --sort=name base/dirs base/hello.txt; finish
if tar -tf "$D/ours.tar" | tail -n1 | grep -qx 'base/dirs/a.txt'; then :; else CASE=u-newer-file; note_fail "updated file not appended last"; fi
begin u-older-file; reset_mtimes; init base/dirs base/hello.txt
touch -d '2019-01-01 00:00:00' "$SRC/base/dirs/b.txt"
run_ref -uf "$D/ref.tar" --sort=name base/dirs base/hello.txt
run_ours -uf "$D/ours.tar" --sort=name base/dirs base/hello.txt; finish
begin u-new-names; reset_mtimes; init base/dirs
run_ref -uf "$D/ref.tar" --sort=name base/dirs base/hello.txt base/extra.txt
run_ours -uf "$D/ours.tar" --sort=name base/dirs base/hello.txt base/extra.txt; finish
begin u-deleted; reset_mtimes; init base/dirs base/hello.txt base/extra.txt
mv "$SRC/base/extra.txt" "$SRC/base/extra.gone"
run_ref -uf "$D/ref.tar" --sort=name base/dirs base/hello.txt
run_ours -uf "$D/ours.tar" --sort=name base/dirs base/hello.txt; finish
mv "$SRC/base/extra.gone" "$SRC/base/extra.txt"
begin u-deleted-operand; reset_mtimes; init base/dirs base/extra.txt
mv "$SRC/base/extra.txt" "$SRC/base/extra.gone"
run_ref -uf "$D/ref.tar" base/extra.txt; run_ours -uf "$D/ours.tar" base/extra.txt; finish
mv "$SRC/base/extra.gone" "$SRC/base/extra.txt"
begin u-size-only; reset_mtimes; init base/hello.txt   # same mtime, different size: not newer
printf 'hello world, longer now\n' >"$SRC/base/hello.txt"; touch -d '2020-01-01 00:00:00' "$SRC/base/hello.txt"
run_ref -uf "$D/ref.tar" base/hello.txt; run_ours -uf "$D/ours.tar" base/hello.txt; finish
printf 'hello world\n' >"$SRC/base/hello.txt"
begin u-dir-mtime; reset_mtimes; init base/dirs
touch -d '2022-02-02 00:00:00' "$SRC/base/dirs"
run_ref -uf "$D/ref.tar" --sort=name base/dirs; run_ours -uf "$D/ours.tar" --sort=name base/dirs; finish
begin u-hardlinks; reset_mtimes; init base/hard
touch -d '2023-03-03 00:00:00' "$SRC/base/hard/orig.bin"
run_ref -uf "$D/ref.tar" --sort=name base/hard; run_ours -uf "$D/ours.tar" --sort=name base/hard; finish
begin u-hardlinks-partial; reset_mtimes; init base/hard/orig.bin   # only one name archived: other is new
touch -d '2023-03-03 00:00:00' "$SRC/base/hard/orig.bin"
run_ref -uf "$D/ref.tar" --sort=name base/hard; run_ours -uf "$D/ours.tar" --sort=name base/hard; finish
begin u-long-option; reset_mtimes; init base/dirs
touch -d '2021-06-01 12:00:00' "$SRC/base/dirs/a.txt"
run_ref --update -f "$D/ref.tar" --sort=name base/dirs; run_ours --update -f "$D/ours.tar" --sort=name base/dirs; finish
begin u-missing-archive; reset_mtimes
run_ref -uf "$D/ref.tar" --sort=name base/dirs; run_ours -uf "$D/ours.tar" --sort=name base/dirs; finish
begin u-C-dot; reset_mtimes; rm -rf "$SRC/base2"; cp -a "$SRC/base" "$SRC/base2"; rm -rf "$SRC/base2/special"
( cd "$SRC" && tar -cf "$D/ref.tar" -C base2 . ) && cp "$D/ref.tar" "$D/ours.tar" && cp "$D/ref.tar" "$D/orig.tar"
touch -d '2024-04-04 00:00:00' "$SRC/base2/dirs/a.txt" "$SRC/base2/hello.txt"
run_ref -uf "$D/ref.tar" --sort=name -C base2 .; run_ours -uf "$D/ours.tar" --sort=name -C base2 .; finish
begin u-long-names; reset_mtimes; init base/long
touch -d '2025-05-05 00:00:00' "$SRC"/base/long/l*.txt
run_ref -uf "$D/ref.tar" base/long; run_ours -uf "$D/ours.tar" base/long; finish
begin u-pax-archive; reset_mtimes; ( cd "$SRC" && tar --format=posix -cf "$D/ref.tar" base/dirs base/long ) && cp "$D/ref.tar" "$D/ours.tar" && cp "$D/ref.tar" "$D/orig.tar"
touch -d '2026-01-01 00:00:00' "$SRC/base/dirs/b.txt"
run_ref -uf "$D/ref.tar" --sort=name base/dirs base/long; run_ours -uf "$D/ours.tar" --sort=name base/dirs base/long; finish
begin u-twice;  reset_mtimes; init base/dirs
touch -d '2021-01-01 00:00:00' "$SRC/base/dirs/a.txt"
run_ref -uf "$D/ref.tar" --sort=name base/dirs; run_ref -uf "$D/ref.tar" --sort=name base/dirs
run_ours -uf "$D/ours.tar" --sort=name base/dirs; run_ours -uf "$D/ours.tar" --sort=name base/dirs; finish
begin u-type-changes; reset_mtimes; rm -rf "$SRC/tc"; mkdir -p "$SRC/tc/f" "$SRC/tc/dd"; echo x >"$SRC/tc/f/inner"; echo y >"$SRC/tc/dd/inner"
echo q >"$SRC/tc/file2"; ln -s target "$SRC/tc/lnk"; echo t >"$SRC/tc/target"
find "$SRC/tc" -exec touch -h -d '2020-01-01' {} +
init tc/f tc/dd tc/lnk tc/file2
rm -rf "$SRC/tc/f" "$SRC/tc/lnk" "$SRC/tc/file2"; echo file >"$SRC/tc/f"; echo reg >"$SRC/tc/lnk"; mkdir "$SRC/tc/file2"; echo i >"$SRC/tc/file2/i"
touch -d 2024-01-01 "$SRC/tc/f" "$SRC/tc/dd" "$SRC/tc/lnk" "$SRC/tc/file2" "$SRC/tc/file2/i"
run_ref -uf "$D/ref.tar" --sort=name tc/f tc/dd tc/lnk tc/file2; run_ours -uf "$D/ours.tar" --sort=name tc/f tc/dd tc/lnk tc/file2; finish
begin u-symlink-retarget; reset_mtimes; rm -rf "$SRC/tc"; mkdir -p "$SRC/tc"; ln -s target "$SRC/tc/lnk"; find "$SRC/tc" -exec touch -h -d '2020-01-01' {} +
init tc/lnk; rm "$SRC/tc/lnk"; ln -s other "$SRC/tc/lnk"; touch -h -d 2024-01-01 "$SRC/tc/lnk"
run_ref -uf "$D/ref.tar" tc/lnk; run_ours -uf "$D/ours.tar" tc/lnk; finish
begin u-error-untouched; reset_mtimes; init base/dirs
expect_error 'stat\|No such' -uf "$D/ours.tar" base/dirs base/nonexistent
reset_mtimes

echo
echo "test_append: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    printf '%s' "$failures" >&2
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
