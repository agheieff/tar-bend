#!/usr/bin/env bash
# test_gzip.sh — M5 gzip differential harness: `btar` compressed mode vs GNU tar.
#
# Uses the deterministic compressed corpus in fixtures/generated/gzip/:
#   * gzip -1/-9 versions of selected valid tar fixtures, one stored-DEFLATE
#     (zlib level 0) container, and one two-member concatenated gzip stream;
#   * corrupt variants: bad magic, bad CM, truncated header, bad CRC32,
#     bad ISIZE, truncated DEFLATE, 4 GiB ISIZE bomb.
#
# Checks:
#   * detect gzip support via `"$BTAR" -tzf` (explicit -z) and `-tf`
#     (auto-detect) on a known-good .tar.gz; print SKIP when both are absent;
#   * per valid fixture: gzip-mode listing vs `tar -tzf` (GNU octal escapes
#     normalized to raw bytes) and extraction tree compare via
#     tools/compare_tree.py against `tar -xzf`; explicit/auto parity when both
#     are supported; `-O` stdout byte compare on the single-file fixture;
#   * create direction: `"$BTAR" -czf` (bundled) and `-c -z -f` (separated)
#     archives validated with `gzip -t`, GNU `tar -tzf`/`-xzf` and tree compare,
#     with a compression-ratio report (SKIP if `-czf` is not implemented yet);
#   * corrupt fixtures: fatal exit 2 (plan §2.1) with a non-empty diagnostic.
#
# Usage:
#   ./tools/test_gzip.sh [--keep] [--regen]
#   BTAR=/path/to/btar ./tools/test_gzip.sh
#
#   --keep   keep temp dirs/logs (always kept on failure)
#   --regen  regenerate fixtures first
#
# Exit codes: 0 PASS or SKIP (gzip integration absent), 1 FAIL, 2 setup/usage.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/fixtures/generated"
MANIFEST="$FIXTURES/manifest.json"
GEN="$ROOT/tools/gen_fixtures.py"
COMPARE="$ROOT/tools/compare_tree.py"
BTAR="${BTAR:-$ROOT/build/btar}"
TIMEOUT=30

KEEP=0
REGEN=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --regen) REGEN=1 ;;
        -h|--help)
            sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "test_gzip: unknown argument: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

for tool in python3 tar gzip timeout cmp find; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "test_gzip: required tool not found: $tool" >&2
        exit 2
    }
done
[ -x "$BTAR" ] || {
    echo "test_gzip: BTAR not executable: $BTAR" >&2
    echo "            build it first: bend app/main.bend -o build/btar" >&2
    exit 2
}

if [ "$REGEN" = 1 ] || [ ! -f "$MANIFEST" ]; then
    echo "test_gzip: generating fixtures ..."
    python3 "$GEN" >/dev/null
fi
[ -d "$FIXTURES/gzip/valid" ] || {
    echo "test_gzip: no compressed fixtures; run python3 tools/gen_fixtures.py" >&2
    exit 2
}

umask 022
export LC_ALL=C

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-gzip.XXXXXX")"
cleanup() {
    if [ "$KEEP" = 0 ]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT

# file, sha256, gzip-level/profile/source expected in the manifest
mapfile -t VALID_ROWS < <(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for fixture in manifest.get("gzip_valid", []):
    print("\x1f".join([
        fixture["file"],
        fixture["sha256"],
        fixture.get("source", ""),
        fixture.get("profile", "deflate"),
    ]))
PY
)
mapfile -t EVIL_ROWS < <(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for fixture in manifest.get("gzip_evil", []):
    expected = fixture["expected"]
    print("\x1f".join([
        fixture["file"],
        fixture["sha256"],
        str(expected.get("exit", 2)),
        expected.get("note", ""),
    ]))
PY
)

total_valid="${#VALID_ROWS[@]}"
total_evil="${#EVIL_ROWS[@]}"
[ "$total_valid" -gt 0 ] || {
    echo "test_gzip: manifest has no gzip_valid fixtures" >&2
    exit 2
}
[ "$total_evil" -gt 0 ] || {
    echo "test_gzip: manifest has no gzip_evil fixtures" >&2
    exit 2
}

pass_count=0
fail_count=0
skip_count=0
failure_log=""
skip_log=""

add_failure() { # $1 case, $2 reason
    fail_count=$((fail_count + 1))
    failure_log+="$1: $2"$'\n'
}

add_skip() { # $1 case, $2 reason
    skip_count=$((skip_count + 1))
    skip_log+="$1: $2"$'\n'
}

# Compare two name lists; normalizes GNU tar octal/backslash escapes to raw
# bytes so btar's raw-byte names (e.g. latin-1 caf\xe9) match GNU's `caf\351`.
compare_name_lists() { # $1 btar.list, $2 gnu.list
    python3 - "$1" "$2" <<'PY'
import sys


def unescape(line: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(line):
        byte = line[i]
        if (byte == 0x5C and i + 3 < len(line)
                and all(0x30 <= line[i + j] <= 0x37 for j in (1, 2, 3))):
            out.append(int(line[i + 1:i + 4], 8))
            i += 4
        elif byte == 0x5C and i + 1 < len(line) and line[i + 1] == 0x5C:
            out.append(0x5C)
            i += 2
        else:
            out.append(byte)
            i += 1
    return bytes(out)


def read_lines(path: str) -> list[bytes]:
    data = open(path, "rb").read()
    return [unescape(line) for line in data.split(b"\n") if line]


btar = read_lines(sys.argv[1])
gnu = read_lines(sys.argv[2])
if btar == gnu:
    sys.exit(0)
for index in range(max(len(btar), len(gnu))):
    a = btar[index] if index < len(btar) else b"<missing>"
    b = gnu[index] if index < len(gnu) else b"<missing>"
    if a != b:
        print(f"first mismatch at line {index + 1}: btar={a!r} gnu={b!r}")
        break
print(f"line counts: btar={len(btar)} gnu={len(gnu)}")
sys.exit(1)
PY
}

# detect gzip read support ---------------------------------------------------
probe="$FIXTURES/gzip/valid/single_file_gz.tar.gz"
MODE_Z=0
MODE_AUTO=0
z_rc=0
timeout "$TIMEOUT" "$BTAR" -tzf "$probe" >"$TMP/probe.z.out" 2>"$TMP/probe.z.err" \
    || z_rc=$?
auto_rc=0
timeout "$TIMEOUT" "$BTAR" -tf "$probe" >"$TMP/probe.auto.out" 2>"$TMP/probe.auto.err" \
    || auto_rc=$?
[ "$z_rc" -eq 0 ] && MODE_Z=1
[ "$auto_rc" -eq 0 ] && MODE_AUTO=1

echo "test_gzip: btar=$BTAR"
echo "test_gzip: fixtures=$FIXTURES/gzip ($total_valid valid, $total_evil evil)"
echo "test_gzip: support probe: explicit -tzf rc=$z_rc, auto -tf rc=$auto_rc"
if [ "$MODE_Z" -eq 0 ] && [ "$MODE_AUTO" -eq 0 ]; then
    echo "test_gzip: SKIP: gzip read integration absent"
    echo "  -tzf: $(head -n 1 "$TMP/probe.z.err" | cut -c1-160)"
    echo "  -tf : $(head -n 1 "$TMP/probe.auto.err" | cut -c1-160)"
    echo "RESULT: SKIP (gzip read not implemented yet; corpus/harness ready for M5)"
    exit 0
fi
if [ "$MODE_Z" -eq 1 ]; then
    LIST_ARGS=(-tzf)
    EXTRACT_ARGS=(-xzf)
    PRIMARY="explicit -z"
else
    LIST_ARGS=(-tf)
    EXTRACT_ARGS=(-xf)
    PRIMARY="auto-detect"
fi
echo "test_gzip: primary read mode: $PRIMARY"
if [ "$MODE_Z" -eq 0 ] || [ "$MODE_AUTO" -eq 0 ]; then
    echo "test_gzip: partial read integration (one of -z / auto-detect missing)"
fi

# --------------------------------------------------------------------------- #
# Valid compressed fixtures
# --------------------------------------------------------------------------- #
index=0
for row in "${VALID_ROWS[@]}"; do
    IFS=$'\x1f' read -r file sha source profile <<<"$row"
    name="$(basename "$file" .tar.gz)"
    fixture="$FIXTURES/$file"
    work="$TMP/valid/$name"
    mkdir -p "$work/ref.d" "$work/ours.d"
    index=$((index + 1))
    before=$fail_count

    actual_sha="$(sha256sum -- "$fixture" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$actual_sha" != "$sha" ]; then
        add_failure "$name" "sha256 mismatch (run --regen)"
    fi

    # list parity vs GNU tar (gzip mode)
    list_rc=0
    timeout "$TIMEOUT" "$BTAR" "${LIST_ARGS[@]}" "$fixture" \
        >"$work/btar.list" 2>"$work/btar.list.err" || list_rc=$?
    gnu_list_rc=0
    tar -tzf "$fixture" >"$work/gnu.list" 2>"$work/gnu.list.err" || gnu_list_rc=$?
    if [ "$list_rc" -ne 0 ]; then
        add_failure "$name" "btar list rc=$list_rc: $(head -n 1 "$work/btar.list.err")"
    elif [ "$gnu_list_rc" -ne 0 ]; then
        add_failure "$name" "GNU tar -tzf failed on reference fixture"
    elif ! compare_name_lists "$work/btar.list" "$work/gnu.list" \
        >"$work/list.diff" 2>&1; then
        add_failure "$name" "listing differs from GNU tar -tzf (see $work/list.diff)"
        sed 's/^/    /' "$work/list.diff" >&2
    fi

    # extraction tree parity vs GNU tar
    extract_rc=0
    timeout "$TIMEOUT" "$BTAR" "${EXTRACT_ARGS[@]}" "$fixture" -C "$work/ours.d" \
        >"$work/btar.out" 2>"$work/btar.err" || extract_rc=$?
    ref_rc=0
    tar -xzf "$fixture" -C "$work/ref.d" >"$work/gnu.out" 2>"$work/gnu.err" \
        || ref_rc=$?
    if [ "$extract_rc" -ne 0 ]; then
        add_failure "$name" "btar extract rc=$extract_rc: $(head -n 1 "$work/btar.err")"
    elif [ "$ref_rc" -ne 0 ]; then
        add_failure "$name" "GNU tar -xzf failed on reference fixture"
    else
        tree_rc=0
        python3 "$COMPARE" "$work/ref.d" "$work/ours.d" >"$work/tree.diff" 2>&1 \
            || tree_rc=$?
        if [ "$tree_rc" -ne 0 ]; then
            add_failure "$name" "extraction tree differs (see $work/tree.diff)"
            sed 's/^/    /' "$work/tree.diff" >&2
        fi
    fi

    if [ "$fail_count" -eq "$before" ]; then
        pass_count=$((pass_count + 1))
        printf '[%2d/%2d] PASS %-18s (%s, source=%s, profile=%s)\n' \
            "$index" "$total_valid" "$name" "$PRIMARY" "$source" "$profile"
    else
        printf '[%2d/%2d] FAIL %-18s (see %s)\n' "$index" "$total_valid" "$name" "$work"
    fi
done

# explicit-vs-auto parity (when both modes are integrated)
if [ "$MODE_Z" -eq 1 ] && [ "$MODE_AUTO" -eq 1 ]; then
    both_work="$TMP/valid/both-modes"
    mkdir -p "$both_work/auto.d" "$both_work/z.d"
    both_before=$fail_count
    timeout "$TIMEOUT" "$BTAR" -tzf "$probe" >"$both_work/z.list" \
        2>"$both_work/z.err" || true
    timeout "$TIMEOUT" "$BTAR" -tf "$probe" >"$both_work/auto.list" \
        2>"$both_work/auto.err" || true
    if ! cmp -s "$both_work/z.list" "$both_work/auto.list"; then
        add_failure "modes-parity" "-tzf and -tf list outputs differ"
    fi
    if [ "$fail_count" -eq "$both_before" ]; then
        pass_count=$((pass_count + 1))
        echo "[--/--] PASS modes-parity     (explicit -z and auto-detect agree)"
    fi
fi

# -O stdout comparison (single-file fixture)
o_before=$fail_count
o_file="$FIXTURES/gzip/valid/single_file_gz.tar.gz"
o_ok=0
if [ -f "$o_file" ]; then
    for candidate in "-xOzf" "-xzOf" "-xO -z -f" "-x -O -z -f"; do
        # shellcheck disable=SC2086
        if timeout "$TIMEOUT" "$BTAR" $candidate "$o_file" \
            >"$TMP/stdout.btar" 2>"$TMP/stdout.btar.err"; then
            o_ok=1
            break
        fi
    done
    if [ "$o_ok" -eq 1 ]; then
        tar -xOzf "$o_file" >"$TMP/stdout.gnu" 2>"$TMP/stdout.gnu.err" || true
        if ! cmp -s "$TMP/stdout.btar" "$TMP/stdout.gnu"; then
            add_failure "stdout" "-O bytes differ from GNU tar -xOzf"
        fi
    else
        add_skip "stdout" "-O with gzip not supported yet"
    fi
else
    add_skip "stdout" "single_file_gz fixture missing"
fi
if [ "$fail_count" -eq "$o_before" ]; then
    if [ "$o_ok" -eq 1 ]; then
        pass_count=$((pass_count + 1))
        echo "[--/--] PASS stdout             (-O bytes match GNU tar -xOzf)"
    else
        echo "[--/--] SKIP stdout             (-O + gzip not implemented yet)"
    fi
fi

# --------------------------------------------------------------------------- #
# Corrupt compressed fixtures: fatal (exit 2), no hang, non-empty diagnostic.
# --------------------------------------------------------------------------- #
corrupt_ok=0
for row in "${EVIL_ROWS[@]}"; do
    IFS=$'\x1f' read -r file sha expected_exit note <<<"$row"
    name="$(basename "$file" .tar.gz)"
    fixture="$FIXTURES/$file"
    work="$TMP/evil/$name"
    mkdir -p "$work"
    actual_sha="$(sha256sum -- "$fixture" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$actual_sha" != "$sha" ]; then
        add_failure "$name" "sha256 mismatch (run --regen)"
        continue
    fi
    rc=0
    timeout "$TIMEOUT" "$BTAR" "${LIST_ARGS[@]}" "$fixture" \
        >"$work/out" 2>"$work/err" || rc=$?
    if [ "$rc" -ne "$expected_exit" ]; then
        err_first="$(head -n 1 "$work/err")"
        add_failure "$name" "expected fatal exit $expected_exit, got rc=$rc: $err_first"
        continue
    fi
    if [ ! -s "$work/err" ]; then
        add_failure "$name" "fatal exit without a diagnostic message"
        continue
    fi
    corrupt_ok=$((corrupt_ok + 1))
    pass_count=$((pass_count + 1))
    printf '[--/--] PASS %-22s (fatal exit %d, rejected)\n' "$name" "$rc"
done

# --------------------------------------------------------------------------- #
# Create direction: btar -czf vs GNU tar -czf (SKIP if -z write is absent).
# --------------------------------------------------------------------------- #
create_dir="$TMP/create"
mkdir -p "$create_dir/src"
python3 - "$create_dir/src" <<'PY'
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])


def write(rel: str, data: bytes, mode: int = 0o644) -> None:
    path = src / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.chmod(path, mode)


seed = b"0123456789abcdef"
write("hello.txt", b"hello world\n")
write("big.bin", (seed * ((1024 * 1024 // len(seed)) + 1))[: 1024 * 1024])
write("dirs/nested/deep.txt", b"deep\n")
write("modes/mode_0640.txt", b"0640\n", 0o640)
write("modes/mode_0755.sh", b"#!/bin/sh\ntrue\n", 0o755)
write("hard/orig.bin", b"hardlinked\n")
os.link(src / "hard" / "orig.bin", src / "hard" / "link.bin")
os.symlink("../hello.txt", src / "links-rel")
for path in sorted(src.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    os.utime(path, ns=(0, 0), follow_symlinks=False)
os.utime(src, ns=(0, 0))
PY
ref_tgz="$create_dir/ref.tar.gz"
tar -czf "$ref_tgz" -C "$create_dir/src" .
create_supported=0
probe_rc=0
timeout "$TIMEOUT" "$BTAR" -czf "$create_dir/probe.tgz" -C "$create_dir/src" . \
    >"$create_dir/probe.out" 2>"$create_dir/probe.err" || probe_rc=$?
if [ "$probe_rc" -eq 0 ] && gzip -t "$create_dir/probe.tgz" >/dev/null 2>&1; then
    create_supported=1
fi

create_checks=0
create_pass=0
ratio_line=""
if [ "$create_supported" -eq 0 ]; then
    probe_err="$(head -n 1 "$create_dir/probe.err")"
    add_skip "create" "btar -czf not implemented yet (probe rc=$probe_rc): $probe_err"
    printf '[--/--] SKIP %-22s (-czf write not implemented yet)\n' create-gzip
else
    for style in bundled separated; do
        ours="$create_dir/ours-$style.tar.gz"
        create_rc=0
        if [ "$style" = bundled ]; then
            timeout "$TIMEOUT" "$BTAR" -czf "$ours" -C "$create_dir/src" . \
                >"$create_dir/$style.out" 2>"$create_dir/$style.err" || create_rc=$?
        else
            timeout "$TIMEOUT" "$BTAR" -c -z -f "$ours" -C "$create_dir/src" . \
                >"$create_dir/$style.out" 2>"$create_dir/$style.err" || create_rc=$?
        fi
        create_checks=$((create_checks + 1))
        style_before=$fail_count
        if [ "$create_rc" -ne 0 ]; then
            style_err="$(head -n 1 "$create_dir/$style.err")"
            add_failure "create-$style" "btar create rc=$create_rc: $style_err"
            continue
        fi
        if ! gzip -t "$ours" >/dev/null 2>&1; then
            add_failure "create-$style" "gzip -t rejects the archive"
            continue
        fi
        gnu_list_rc=0
        tar -tzf "$ours" >"$create_dir/$style.ours.list" 2>"$create_dir/$style.ours.err" \
            || gnu_list_rc=$?
        tar -tzf "$ref_tgz" >"$create_dir/ref.list" 2>/dev/null || true
        if [ "$gnu_list_rc" -ne 0 ]; then
            add_failure "create-$style" "GNU tar -tzf cannot read the archive"
            continue
        fi
        if ! compare_name_lists "$create_dir/$style.ours.list" \
            "$create_dir/ref.list" >"$create_dir/$style.list.diff" 2>&1; then
            add_failure "create-$style" "readback names differ from GNU tar -czf"
            continue
        fi
        mkdir -p "$create_dir/$style.ref.d" "$create_dir/$style.ours.d"
        tar -xzf "$ref_tgz" -C "$create_dir/$style.ref.d" >/dev/null 2>&1 || true
        tar -xzf "$ours" -C "$create_dir/$style.ours.d" >/dev/null 2>&1 \
            || add_failure "create-$style" "GNU extraction of btar archive failed"
        tree_rc=0
        python3 "$COMPARE" "$create_dir/$style.ref.d" \
            "$create_dir/$style.ours.d" >"$create_dir/$style.tree.diff" 2>&1 \
            || tree_rc=$?
        if [ "$tree_rc" -ne 0 ]; then
            add_failure "create-$style" "extracted tree differs from GNU tar archive"
            sed 's/^/    /' "$create_dir/$style.tree.diff" >&2
            continue
        fi
        if [ "$fail_count" -eq "$style_before" ]; then
            create_pass=$((create_pass + 1))
            pass_count=$((pass_count + 1))
            ours_size="$(stat -c%s "$ours")"
            ref_size="$(stat -c%s "$ref_tgz")"
            ratio="$(python3 -c "print(f'{100.0*$ours_size/$ref_size:.1f}%')")"
            printf '[--/--] PASS %-22s (valid gzip, GNU-readable, tree equal, %s)\n' \
                "create-$style" "ours/ref=$ratio"
            ratio_line+="create-$style: ours=${ours_size}B ref=${ref_size}B ratio=$ratio "
        fi
    done
    if [ "$create_pass" -eq "$create_checks" ] && [ -n "$ratio_line" ]; then
        echo "test_gzip: compression ratio: $ratio_line"
    fi
fi

# --------------------------------------------------------------------------- #
# M6: compression-ratio gate and large-ish create/list/extract timing.
# --------------------------------------------------------------------------- #
echo
echo "test_gzip: M6 compression-ratio / timing checks"

gzip_btype() { # $1 archive -> 0 stored, 1 fixed Huffman, 2 dynamic Huffman
    python3 - "$1" <<'PY'
import struct
import sys

data = open(sys.argv[1], "rb").read()
if data[:2] != b"\x1f\x8b":
    print("not-gzip")
    raise SystemExit(0)
flags = data[3]
pos = 10
if flags & 4:  # FEXTRA
    pos += 2 + struct.unpack("<H", data[pos:pos + 2])[0]
if flags & 8:  # FNAME
    pos = data.index(b"\0", pos) + 1
if flags & 16:  # FCOMMENT
    pos = data.index(b"\0", pos) + 1
if flags & 2:  # FHCRC
    pos += 2
print((data[pos] >> 1) & 0x3)
PY
}

m6_ratio_dir="$TMP/m6-ratio"
mkdir -p "$m6_ratio_dir/src"
python3 - "$m6_ratio_dir/src" <<'PY'
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
(src / "zeros.bin").write_bytes(b"\0" * (1024 * 1024))
(src / "repeat.txt").write_bytes(b"ABCD" * (512 * 1024))
(src / "sub").mkdir()
(src / "sub" / "nested.txt").write_bytes(b"tar-bend compression-ratio tree\n" * 4096)
for path in sorted(src.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    os.utime(path, ns=(0, 0))
os.utime(src, ns=(0, 0))
PY
tar -cf "$m6_ratio_dir/plain.tar" -C "$m6_ratio_dir/src" .
tar -czf "$m6_ratio_dir/gnu.tgz" -C "$m6_ratio_dir/src" . 2>/dev/null || true
plain_size="$(stat -c%s "$m6_ratio_dir/plain.tar")"
gnu_size="$(stat -c%s "$m6_ratio_dir/gnu.tgz" 2>/dev/null || echo 0)"

if [ "$create_supported" -ne 1 ]; then
    add_skip "compression-ratio" "gzip create (-czf) not implemented yet"
    echo "[--/--] SKIP compression-ratio  (-czf not implemented yet)"
else
    ratio_rc=0
    timeout "$TIMEOUT" "$BTAR" -czf "$m6_ratio_dir/ours.tgz" \
        -C "$m6_ratio_dir/src" . >"$m6_ratio_dir/run.out" 2>"$m6_ratio_dir/run.err" \
        || ratio_rc=$?
    if [ "$ratio_rc" -ne 0 ]; then
        ratio_err="$(head -n 1 "$m6_ratio_dir/run.err")"
        add_failure "compression-ratio" "btar -czf rc=$ratio_rc: $ratio_err"
        echo "[--/--] FAIL compression-ratio  (create rc=$ratio_rc)"
    elif ! gzip -t "$m6_ratio_dir/ours.tgz" >/dev/null 2>&1; then
        add_failure "compression-ratio" "gzip -t rejects btar archive"
        echo "[--/--] FAIL compression-ratio  (gzip -t rejects)"
    else
        ours_size="$(stat -c%s "$m6_ratio_dir/ours.tgz")"
        btype="$(gzip_btype "$m6_ratio_dir/ours.tgz")"
        ratio_pct="$(python3 -c "print(f'{100.0*$ours_size/$plain_size:.1f}')")"
        gnu_pct="$(python3 -c "print(f'{100.0*$gnu_size/$plain_size:.1f}')" \
            2>/dev/null || echo "?")"
        echo "test_gzip: ratio plain=${plain_size}B ours=${ours_size}B (${ratio_pct}%)" \
             "gnu=${gnu_size}B (${gnu_pct}%) deflate-btype=${btype}"
        if [ "$btype" = "0" ]; then
            add_skip "compression-ratio" \
                "stored-only DEFLATE (BTYPE=0, ${ratio_pct}% of plain); real deflate pending M6"
            echo "[--/--] SKIP compression-ratio  (stored-only, ${ratio_pct}%)"
        elif python3 -c "raise SystemExit(0 if $ours_size * 2 < $plain_size else 1)"; then
            pass_count=$((pass_count + 1))
            echo "[--/--] PASS compression-ratio  (<50% of plain: ${ratio_pct}%, GNU ${gnu_pct}%)"
        else
            add_failure "compression-ratio" \
                "real deflate but only ${ratio_pct}% of plain tar (expected <50%)"
            echo "[--/--] FAIL compression-ratio  (${ratio_pct}% >= 50%)"
        fi
    fi
fi

# Timing: large-ish compressible tree, create (when supported) + list + extract.
m6_perf_dir="$TMP/m6-perf"
mkdir -p "$m6_perf_dir/src"
python3 - "$m6_perf_dir/src" <<'PY'
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
pattern = b"tar-bend M6 timing payload 0123456789abcdef\n" * 64
for index in range(2):
    (src / f"chunk-{index}.bin").write_bytes(pattern * 256)
for index in range(200):
    path = src / "dirs" / f"d{index:03d}" / "f.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"small file\n")
for path in sorted(src.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    os.utime(path, ns=(0, 0))
os.utime(src, ns=(0, 0))
PY
m6_perf_size="$(du -sb "$m6_perf_dir/src" 2>/dev/null | cut -f1)"
perf_fail=0

now_ms() { date +%s%N; }
perf_create_ms="skip"
if [ "$create_supported" -eq 1 ]; then
    t0="$(now_ms)"
    perf_rc=0
    timeout "$TIMEOUT" "$BTAR" -czf "$m6_perf_dir/ours.tgz" \
        -C "$m6_perf_dir/src" . >"$m6_perf_dir/create.out" \
        2>"$m6_perf_dir/create.err" || perf_rc=$?
    t1="$(now_ms)"
    perf_create_ms=$(( (t1 - t0) / 1000000 ))
    if [ "$perf_rc" -ne 0 ] || ! gzip -t "$m6_perf_dir/ours.tgz" >/dev/null 2>&1; then
        add_failure "timing" "btar -czf perf tree rc=$perf_rc"
        perf_fail=1
    fi
fi
t0="$(now_ms)"
perf_list_rc=0
timeout "$TIMEOUT" "$BTAR" -tzf "$m6_perf_dir/ours.tgz" >/dev/null 2>"$m6_perf_dir/list.err" \
    || perf_list_rc=$?
t1="$(now_ms)"
perf_list_ms=$(( (t1 - t0) / 1000000 ))
t0="$(now_ms)"
perf_extract_rc=0
mkdir -p "$m6_perf_dir/extract"
timeout "$TIMEOUT" "$BTAR" -xzf "$m6_perf_dir/ours.tgz" -C "$m6_perf_dir/extract" \
    >/dev/null 2>"$m6_perf_dir/extract.err" || perf_extract_rc=$?
t1="$(now_ms)"
perf_extract_ms=$(( (t1 - t0) / 1000000 ))
if [ "$perf_list_rc" -ne 0 ]; then
    add_failure "timing" "btar -tzf perf tree rc=$perf_list_rc"
    perf_fail=1
fi
if [ "$perf_extract_rc" -ne 0 ]; then
    add_failure "timing" "btar -xzf perf tree rc=$perf_extract_rc"
    perf_fail=1
fi
create_label="SKIP"
[ "$perf_create_ms" != "skip" ] && create_label="${perf_create_ms}ms"
perf_mbs="n/a"
if [ "$perf_create_ms" != "skip" ] && [ "$perf_create_ms" -gt 0 ]; then
    perf_mbs="$(python3 -c "print(f'{$m6_perf_size/1e6/ ($perf_create_ms/1000.0):.1f}')")"
fi
echo "test_gzip: timing src=${m6_perf_size}B create=$create_label" \
     "list=${perf_list_ms}ms extract=${perf_extract_ms}ms (create ${perf_mbs} MB/s)"
if [ "$perf_create_ms" != "skip" ] && [ "$perf_create_ms" -gt 30000 ]; then
    add_failure "timing" "gzip create took ${perf_create_ms}ms (>30s)"
    perf_fail=1
fi
if [ "$perf_list_ms" -gt 30000 ] || [ "$perf_extract_ms" -gt 30000 ]; then
    add_failure "timing" "gzip list/extract exceeded 30s"
    perf_fail=1
fi
if [ "$perf_fail" -eq 0 ]; then
    pass_count=$((pass_count + 1))
    echo "[--/--] PASS timing             (all operations < 30s)"
fi

# --------------------------------------------------------------------------- #
# Streaming checks (no size caps, GNU interop at scale, determinism, memory).
# --------------------------------------------------------------------------- #
echo
echo "test_gzip: streaming checks (tools/test_gzip_stream.py)"
stream_out="$TMP/stream.out"
stream_rc=0
python3 "$ROOT/tools/test_gzip_stream.py" "$BTAR" >"$stream_out" 2>&1 || stream_rc=$?
while IFS= read -r line; do
    echo "[--/--] $line"
    case "$line" in
        PASS*) pass_count=$((pass_count + 1)) ;;
        FAIL*) add_failure "stream" "$line" ;;
    esac
done <"$stream_out"
if [ "$stream_rc" -ne 0 ] && ! grep -q '^FAIL' "$stream_out"; then
    add_failure "stream" "test_gzip_stream.py exited $stream_rc: $(tail -n 1 "$stream_out")"
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo
echo "test_gzip: modes explicit-z=$MODE_Z auto-detect=$MODE_AUTO primary=$PRIMARY"
if [ "$skip_count" -gt 0 ]; then
    echo "skipped checks:"
    printf '%s' "$skip_log" | sed 's/^/  - /'
fi
if [ "$fail_count" -gt 0 ]; then
    echo "failures:"
    printf '%s' "$failure_log" | sed 's/^/  - /'
    echo "test_gzip summary: $pass_count pass, $fail_count fail, $skip_count skip"
    echo "RESULT: FAIL (gzip mode)"
    echo "artifacts: $TMP"
    KEEP=1
    exit 1
fi
echo "test_gzip summary: $pass_count pass, 0 fail, $skip_count skip (gzip mode)"
if [ "$KEEP" = 1 ]; then
    echo "artifacts: $TMP"
fi
echo "RESULT: PASS"
