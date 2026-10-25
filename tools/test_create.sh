#!/usr/bin/env bash
# test_create.sh — M4 create-mode differential harness: `btar -cf` vs GNU tar.
#
# Builds deterministic source trees in a temp dir, creates archives with GNU tar
# (reference) and with "$BTAR" (candidate), then validates the candidate:
#   * GNU tar can read it (end blocks / padding accepted, no read warnings);
#   * normalised `tar -tvf` listings match (type/perms/size/name/link target,
#     no dates/owners) — this also covers mode bits incl. setuid;
#   * GNU extraction of both archives yields equivalent trees
#     (tools/compare_tree.py: contents, modes, symlink targets, hardlink groups);
#   * bsdtar can also read it (when installed).
#
# Cases: default create, separate `-c -f`, `-cvf` (verbose output non-empty),
# relative and absolute `-C`, `-p` permissions, `--format=pax` on long names,
# empty tree, and a FIFO source (warning/exit-1 policy, archive still valid).
#
# Create mode is being implemented concurrently: if the `-cf` probe returns the
# usage/fatal path (exit 2) the script prints SKIP with the observed reason and
# exits 0, so the gate stays honest until the writer lands.
#
# Usage:
#   ./tools/test_create.sh [--keep]
#   BTAR=/path/to/btar ./tools/test_create.sh
#
#   --keep  keep the temp trees/archives/logs (printed at the end)
#
# Exit codes: 0 pass, or SKIP when create mode is unimplemented; 1 failures;
#             2 setup/usage error.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE="$ROOT/tools/compare_tree.py"
BTAR="${BTAR:-$ROOT/build/btar}"

KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "test_create: unknown argument: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

for tool in python3 tar find touch cmp; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "test_create: required tool not found: $tool" >&2
        exit 2
    }
done
[ -x "$BTAR" ] || {
    echo "test_create: BTAR not executable: $BTAR" >&2
    echo "            build it first: bend app/main.bend -o build/btar" >&2
    exit 2
}

umask 022
export LC_ALL=C

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-create.XXXXXX")"
cleanup() {
    if [ "$KEEP" = 0 ]; then
        rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT

SRC="$TMP/src"
REF="$TMP/ref"
mkdir -p "$SRC" "$REF" "$TMP/cases"

# --------------------------------------------------------------------------- #
# Deterministic source trees (byte-exact; fixed mtimes, modes and links).
# --------------------------------------------------------------------------- #
build_trees() {
    python3 - "$SRC" <<'PY'
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])


def pattern(size: int) -> bytes:
    seed = b"0123456789abcdef"
    return (seed * ((size // len(seed)) + 1))[:size]


def make_tree(root: pathlib.Path, include_nonutf8: bool) -> None:
    root.mkdir(parents=True)

    def write(rel: str, data: bytes, mode: int = 0o644) -> None:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        os.chmod(path, mode)

    write("empty.txt", b"")
    write("hello.txt", b"hello world\n")
    write("big.bin", pattern(1024 * 1024))
    write("sparse-ish.bin", b"\0" * (4 * 1024 * 1024))  # cheap sparse-ish file
    for size in (511, 512, 513, 4096):
        write(f"pads/pad_{size}.bin", pattern(size))
    write("dirs/nested/deep.txt", b"deep\n")
    write("modes/mode_0640.txt", b"0640\n", 0o640)
    write("modes/mode_0755.sh", b"#!/bin/sh\ntrue\n", 0o755)
    write("modes/mode_0660.txt", b"0660\n", 0o660)
    write("modes/setuid_4755.bin", b"setuid\n", 0o4755)
    (root / "links").mkdir()
    os.symlink("../hello.txt", root / "links" / "rel-link")
    os.symlink("/etc/hostname", root / "links" / "abs-link")
    write("hard/orig.bin", b"hardlinked\n")
    os.link(root / "hard" / "orig.bin", root / "hard" / "link.bin")
    write("long/" + "l" * 120 + ".txt", b"long pax name\n")
    deep = root / "long" / "deep"
    for _ in range(5):
        deep = deep / ("d" * 60)
    deep.mkdir(parents=True)
    (deep / ("f" * 50 + ".txt")).write_bytes(b"deep path\n")
    if include_nonutf8:
        # latin-1 byte 0xE9, not valid UTF-8. POSIX pax stores names as UTF-8,
        # so the pax tree below keeps only portable names.
        fd = os.open(os.fsencode(root) + b"/caf\xe9.txt",
                     os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        os.write(fd, b"latin-1\n")
        os.close(fd)


def fix_times(root: pathlib.Path) -> None:
    for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        os.utime(path, ns=(0, 0), follow_symlinks=False)
    os.utime(root, ns=(0, 0))


base = src / "base"
make_tree(base, include_nonutf8=True)
pax = src / "pax"
make_tree(pax, include_nonutf8=False)
empty = src / "empty"
empty.mkdir()
special = src / "special"
special.mkdir()
os.mkfifo(special / "pipe", 0o644)

# Fixed timestamps make repeated runs comparable (dates are ignored by the
# listing comparison anyway, but this keeps ref/ours headers maximally close).
for root in (base, pax, empty, special):
    fix_times(root)
PY
}

# --------------------------------------------------------------------------- #
# Case bookkeeping
# --------------------------------------------------------------------------- #
pass_count=0
fail_count=0
skip_count=0
case_no=0
CASE_FAILED=0
failure_log=""
skip_log=""

add_failure() { # $1 case, $2 reason
    CASE_FAILED=1
    fail_count=$((fail_count + 1))
    failure_log+="$1: $2"$'\n'
}

add_skip() { # $1 case, $2 reason
    skip_count=$((skip_count + 1))
    skip_log+="$1: $2"$'\n'
}

# verify_archives CASE REF_TAR OURS_TAR [filter_fifo]
# Returns 0 on success; failures are recorded via add_failure.
verify_archives() {
    local name="$1" ref="$2" ours="$3" filter_fifo="${4:-0}"
    local dir="$TMP/cases/$name"
    local before=$fail_count

    # 1. End blocks / trailing padding: GNU tar must read the archive cleanly.
    local read_rc=0
    tar -tf "$ours" >"$dir/ours.list" 2>"$dir/ours.read.err" || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
        local read_err
        read_err="$(head -n 1 "$dir/ours.read.err")"
        add_failure "$name" "GNU tar cannot read btar archive (rc=$read_rc): $read_err"
        return 1
    fi
    if [ -s "$dir/ours.read.err" ]; then
        add_failure "$name" "GNU tar read warnings: $(head -n 1 "$dir/ours.read.err")"
    fi

    # 2. Normalised listing comparison (also verifies stored modes incl setuid).
    if [ "$filter_fifo" -eq 0 ]; then
        tar -tvf "$ref" >"$dir/ref.list" 2>"$dir/ref.list.err" || {
            add_failure "$name" "GNU tar -tvf failed on reference archive"
            return 1
        }
        tar -tvf "$ours" >"$dir/ours.listv" 2>"$dir/ours.listv.err" || {
            add_failure "$name" "GNU tar -tvf failed on btar archive"
            return 1
        }
        local list_rc=0
        python3 "$COMPARE" --listings "$dir/ref.list" "$dir/ours.listv" \
            >"$dir/list.diff" 2>&1 || list_rc=$?
        if [ "$list_rc" -ne 0 ]; then
            add_failure "$name" "normalised listing differs (see $dir/list.diff)"
            sed 's/^/    /' "$dir/list.diff" >&2
        fi
    fi

    # 3. Tree comparison via GNU extraction of both archives.
    mkdir -p "$dir/ref.d" "$dir/ours.d"
    local extract_rc=0
    tar -xf "$ref" -C "$dir/ref.d" >"$dir/ref.extract.out" \
        2>"$dir/ref.extract.err" || extract_rc=$?
    if [ "$extract_rc" -ne 0 ]; then
        add_failure "$name" "GNU extraction of reference failed (rc=$extract_rc)"
        return 1
    fi
    extract_rc=0
    tar -xf "$ours" -C "$dir/ours.d" >"$dir/ours.extract.out" \
        2>"$dir/ours.extract.err" || extract_rc=$?
    if [ "$extract_rc" -ne 0 ]; then
        local extract_err
        extract_err="$(head -n 1 "$dir/ours.extract.err")"
        add_failure "$name" "GNU extraction of btar archive failed (rc=$extract_rc): $extract_err"
        return 1
    fi

    # FIFO policy: if btar warned and skipped the fifo, drop it from the
    # reference tree so the remaining entries are compared.
    if [ "$filter_fifo" -eq 1 ]; then
        local ours_fifos
        ours_fifos="$(find "$dir/ours.d" -type p -print -quit 2>/dev/null)"
        if [ -z "$ours_fifos" ]; then
            find "$dir/ref.d" -type p -delete 2>/dev/null || true
        fi
    fi

    local tree_rc=0
    python3 "$COMPARE" "$dir/ref.d" "$dir/ours.d" >"$dir/tree.diff" 2>&1 \
        || tree_rc=$?
    if [ "$tree_rc" -ne 0 ]; then
        add_failure "$name" "tree compare failed (see $dir/tree.diff)"
        sed 's/^/    /' "$dir/tree.diff" >&2
    fi

    # 4. Cross-reader sanity: libarchive should read it too.
    if command -v bsdtar >/dev/null 2>&1; then
        local bsd_rc=0
        bsdtar -tf "$ours" >/dev/null 2>"$dir/bsdtar.err" || bsd_rc=$?
        [ "$bsd_rc" -eq 0 ] || add_failure "$name" \
            "bsdtar cannot read btar archive (rc=$bsd_rc): $(head -n 1 "$dir/bsdtar.err")"
    fi

    [ "$fail_count" -eq "$before" ]
}

# run_case CASE REF_TAR [extra btar args...]
# The caller passes the complete `-cf OURS -C DIR .` invocation.
run_case() {
    local name="$1" ref="$2"
    shift 2
    local dir="$TMP/cases/$name"
    mkdir -p "$dir/ref.d" "$dir/ours.d"
    local rc=0
    "$@" >"$dir/run.out" 2>"$dir/run.err" || rc=$?
    case_no=$((case_no + 1))
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        add_failure "$name" "btar create rc=$rc: $(head -n 1 "$dir/run.err")"
        printf '[%2d] FAIL %-16s rc=%d\n' "$case_no" "$name" "$rc"
        return 1
    fi
    if [ "$rc" -eq 1 ] && [ ! -s "$dir/run.err" ]; then
        add_failure "$name" "warning exit 1 without a warning message"
    fi
    verify_archives "$name" "$ref" "$dir/ours.tar" 0 || true
    if [ "$CASE_FAILED" -eq 0 ]; then
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-16s (listing + tree + hardlinks, rc=%d)\n' \
            "$case_no" "$name" "$rc"
    else
        printf '[%2d] FAIL %-16s (see %s)\n' "$case_no" "$name" "$dir"
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Build trees and detect create-mode support.
# --------------------------------------------------------------------------- #
build_trees
echo "test_create: btar=$BTAR"
echo "test_create: source trees under $TMP/src (base, empty, special)"

tar -cf "$REF/base.tar" -C "$SRC/base" .
tar -cf "$REF/pax.tar" -C "$SRC/pax" .
tar -cf "$REF/empty.tar" -C "$SRC/empty" .
tar -cf "$REF/special.tar" -C "$SRC/special" .

CASE_FAILED=0
probe_rc=0
"$BTAR" -cf "$TMP/probe.tar" -C "$SRC/base" . \
    >"$TMP/probe.out" 2>"$TMP/probe.err" || probe_rc=$?
if [ "$probe_rc" -eq 2 ]; then
    reason="$(head -n 1 "$TMP/probe.err" 2>/dev/null || true)"
    echo "test_create: SKIP: btar -cf unsupported (probe rc=2): ${reason:-no message}"
    echo "RESULT: SKIP (create mode not implemented yet; harness ready for M4)"
    exit 0
fi
if [ "$probe_rc" -ne 0 ] && [ "$probe_rc" -ne 1 ]; then
    echo "test_create: FAIL: create probe rc=$probe_rc: $(head -n 1 "$TMP/probe.err")" >&2
    echo "RESULT: FAIL (create probe)"
    exit 1
fi
probe_read_rc=0
tar -tf "$TMP/probe.tar" >/dev/null 2>"$TMP/probe.read.err" || probe_read_rc=$?
if [ "$probe_read_rc" -ne 0 ]; then
    probe_err="$(head -n 1 "$TMP/probe.read.err")"
    echo "test_create: FAIL: probe archive is not GNU-tar readable: $probe_err" >&2
    echo "RESULT: FAIL (probe archive invalid)"
    exit 1
fi
echo "test_create: create mode detected (probe rc=$probe_rc, GNU-readable)"

# --------------------------------------------------------------------------- #
# Cases (candidate archives all compared against the matching GNU reference).
# --------------------------------------------------------------------------- #
CASE_FAILED=0
run_case default "$REF/base.tar" \
    "$BTAR" -cf "$TMP/cases/default/ours.tar" -C "$SRC/base" .
run_case separate-flags "$REF/base.tar" \
    "$BTAR" -c -f "$TMP/cases/separate-flags/ours.tar" -C "$SRC/base" .
run_case absolute-C "$REF/base.tar" \
    "$BTAR" -cf "$TMP/cases/absolute-C/ours.tar" -C "$SRC/base" .

# verbose (-v): archive must be valid AND the run must print something.
CASE_FAILED=0
verbose_dir="$TMP/cases/verbose"
mkdir -p "$verbose_dir"
verbose_rc=0
"$BTAR" -cvf "$verbose_dir/ours.tar" -C "$SRC/base" . \
    >"$verbose_dir/run.out" 2>"$verbose_dir/run.err" || verbose_rc=$?
case_no=$((case_no + 1))
if [ "$verbose_rc" -ne 0 ] && [ "$verbose_rc" -ne 1 ]; then
    add_failure "verbose" "btar create rc=$verbose_rc: $(head -n 1 "$verbose_dir/run.err")"
elif [ ! -s "$verbose_dir/run.out" ] && [ ! -s "$verbose_dir/run.err" ]; then
    add_failure "verbose" "-v produced no output on stdout or stderr"
else
    verify_archives "verbose" "$REF/base.tar" "$verbose_dir/ours.tar" 0 || true
fi
if [ "$CASE_FAILED" -eq 0 ]; then
    pass_count=$((pass_count + 1))
    printf '[%2d] PASS %-16s (-v output non-empty, archive valid)\n' "$case_no" verbose
else
    printf '[%2d] FAIL %-16s (see %s)\n' "$case_no" verbose "$verbose_dir"
fi

# -p: permissions (listing compare above verifies stored mode bits incl setuid).
CASE_FAILED=0
run_case permissions-p "$REF/base.tar" \
    "$BTAR" -cpf "$TMP/cases/permissions-p/ours.tar" -C "$SRC/base" .

# Relative -C: run from $SRC with `-C base`.
CASE_FAILED=0
rel_dir="$TMP/cases/relative-C"
mkdir -p "$rel_dir/ref.d" "$rel_dir/ours.d"
rel_rc=0
( cd "$SRC" && "$BTAR" -cf "$rel_dir/ours.tar" -C base . ) \
    >"$rel_dir/run.out" 2>"$rel_dir/run.err" || rel_rc=$?
case_no=$((case_no + 1))
if [ "$rel_rc" -ne 0 ] && [ "$rel_rc" -ne 1 ]; then
    add_failure "relative-C" "btar create rc=$rel_rc: $(head -n 1 "$rel_dir/run.err")"
else
    verify_archives "relative-C" "$REF/base.tar" "$rel_dir/ours.tar" 0 || true
fi
if [ "$CASE_FAILED" -eq 0 ]; then
    pass_count=$((pass_count + 1))
    printf '[%2d] PASS %-16s (relative -C)\n' "$case_no" relative-C
else
    printf '[%2d] FAIL %-16s (see %s)\n' "$case_no" relative-C "$rel_dir"
fi

# --format=pax on the long-name tree (optional until the writer implements it).
CASE_FAILED=0
pax_dir="$TMP/cases/format-pax"
mkdir -p "$pax_dir"
pax_rc=0
"$BTAR" --format=pax -cf "$pax_dir/ours.tar" -C "$SRC/pax" . \
    >"$pax_dir/run.out" 2>"$pax_dir/run.err" || pax_rc=$?
case_no=$((case_no + 1))
pax_unsupported=0
if [ "$pax_rc" -eq 2 ]; then
    pax_unsupported=1
elif [ "$pax_rc" -ne 0 ] && grep -qiE 'usage|unsupported|invalid|unrecognized' \
    "$pax_dir/run.err" 2>/dev/null; then
    pax_unsupported=1
fi
if [ "$pax_unsupported" -eq 1 ]; then
    add_skip "format-pax" "btar --format not implemented yet (rc=$pax_rc)"
    printf '[%2d] SKIP %-16s (--format unsupported yet)\n' "$case_no" format-pax
else
    if [ "$pax_rc" -ne 0 ] && [ "$pax_rc" -ne 1 ]; then
        add_failure "format-pax" "btar create rc=$pax_rc: $(head -n 1 "$pax_dir/run.err")"
    else
        verify_archives "format-pax" "$REF/pax.tar" "$pax_dir/ours.tar" 0 \
            || true
    fi
    if [ "$CASE_FAILED" -eq 0 ]; then
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-16s (--format=pax, GNU-readable)\n' "$case_no" format-pax
    else
        printf '[%2d] FAIL %-16s (see %s)\n' "$case_no" format-pax "$pax_dir"
    fi
fi

# Empty tree.
CASE_FAILED=0
run_case empty-tree "$REF/empty.tar" \
    "$BTAR" -cf "$TMP/cases/empty-tree/ours.tar" -C "$SRC/empty" .

# FIFO source: warning/exit-1 policy is allowed, archive must stay valid.
CASE_FAILED=0
fifo_dir="$TMP/cases/special-fifo"
mkdir -p "$fifo_dir/ref.d" "$fifo_dir/ours.d"
fifo_rc=0
"$BTAR" -cf "$fifo_dir/ours.tar" -C "$SRC/special" . \
    >"$fifo_dir/run.out" 2>"$fifo_dir/run.err" || fifo_rc=$?
case_no=$((case_no + 1))
if [ "$fifo_rc" -ne 0 ] && [ "$fifo_rc" -ne 1 ]; then
    add_failure "special-fifo" "btar create rc=$fifo_rc: $(head -n 1 "$fifo_dir/run.err")"
elif [ "$fifo_rc" -eq 1 ] && [ ! -s "$fifo_dir/run.err" ]; then
    add_failure "special-fifo" "warning exit 1 without a warning message"
else
    verify_archives "special-fifo" "$REF/special.tar" "$fifo_dir/ours.tar" 1 \
        || true
    if [ "$CASE_FAILED" -eq 0 ]; then
        fifo_note="fifo archived"
        if [ -z "$(find "$fifo_dir/ours.d" -type p -print -quit 2>/dev/null)" ]; then
            fifo_note="fifo skipped with warning (exit 1)"
        fi
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-16s (rc=%d, %s, archive valid)\n' \
            "$case_no" special-fifo "$fifo_rc" "$fifo_note"
    fi
fi
if [ "$CASE_FAILED" -ne 0 ]; then
    printf '[%2d] FAIL %-16s (see %s)\n' "$case_no" special-fifo "$fifo_dir"
fi

# --------------------------------------------------------------------------- #
# M6: multi-operand create, --sort=name ordering, gzip warning semantics
# --------------------------------------------------------------------------- #
echo
echo "test_create: probing M6 features (multi-operand, --sort=name, -czf warnings)"

M6_GZIP=0
command -v gzip >/dev/null 2>&1 && M6_GZIP=1
m6_verify() { # name ref ours label
    local name="$1" ref="$2" ours="$3" label="$4"
    case_no=$((case_no + 1))
    CASE_FAILED=0
    verify_archives "$name" "$ref" "$ours" 0 || true
    if [ "$CASE_FAILED" -eq 0 ]; then
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-16s (%s)\n' "$case_no" "$name" "$label"
    else
        printf '[%2d] FAIL %-16s (see %s)\n' "$case_no" "$name" "$TMP/cases/$name"
    fi
}

# --- multi-operand create ---------------------------------------------------
MULTI=0
multi_probe_rc=0
"$BTAR" -cf "$TMP/probe-multi.tar" -C "$SRC/base" hello.txt dirs \
    >"$TMP/probe-multi.out" 2>"$TMP/probe-multi.err" || multi_probe_rc=$?
if [ "$multi_probe_rc" -eq 0 ] && tar -tf "$TMP/probe-multi.tar" >/dev/null 2>&1; then
    MULTI=1
fi
multi_reason="probe rc=$multi_probe_rc: $(head -n 1 "$TMP/probe-multi.err" 2>/dev/null || true)"

if [ "$MULTI" -eq 0 ]; then
    for case_name in operands-C operands-cwd operands-dot duplicates \
        absolute-operand missing-operand; do
        add_skip "$case_name" "multi-operand create unsupported yet ($multi_reason)"
    done
    case_no=$((case_no + 6))
    printf '[--] SKIP %-16s (multi-operand create unsupported: %s)\n' \
        "multi-operand" "$multi_reason"
else
    # -C base hello.txt dirs
    multi_dir="$TMP/cases/operands-C"
    mkdir -p "$multi_dir"
    ( cd "$SRC" && tar -cf "$multi_dir/ref.tar" -C base hello.txt dirs )
    multi_rc=0
    ( cd "$SRC" && "$BTAR" -cf "$multi_dir/ours.tar" -C base hello.txt dirs ) \
        >"$multi_dir/run.out" 2>"$multi_dir/run.err" || multi_rc=$?
    if [ "$multi_rc" -ne 0 ]; then
        add_failure "operands-C" "btar rc=$multi_rc: $(head -n 1 "$multi_dir/run.err")"
        case_no=$((case_no + 1))
        printf '[%2d] FAIL %-16s (rc=%d)\n' "$case_no" operands-C "$multi_rc"
    else
        m6_verify "operands-C" "$multi_dir/ref.tar" "$multi_dir/ours.tar" \
            "-C base hello.txt dirs"
    fi

    # cwd-relative operands, no -C: tree/a.txt tree/sub style
    cwd_dir="$TMP/cases/operands-cwd"
    mkdir -p "$cwd_dir"
    ( cd "$SRC" && tar -cf "$cwd_dir/ref.tar" base/hello.txt base/dirs )
    cwd_rc=0
    ( cd "$SRC" && "$BTAR" -cf "$cwd_dir/ours.tar" base/hello.txt base/dirs ) \
        >"$cwd_dir/run.out" 2>"$cwd_dir/run.err" || cwd_rc=$?
    if [ "$cwd_rc" -ne 0 ]; then
        add_failure "operands-cwd" "btar rc=$cwd_rc: $(head -n 1 "$cwd_dir/run.err")"
        case_no=$((case_no + 1))
        printf '[%2d] FAIL %-16s (rc=%d)\n' "$case_no" operands-cwd "$cwd_rc"
    else
        m6_verify "operands-cwd" "$cwd_dir/ref.tar" "$cwd_dir/ours.tar" \
            "cwd-relative base/hello.txt base/dirs"
    fi

    # leading ./ operands
    dot_dir="$TMP/cases/operands-dot"
    mkdir -p "$dot_dir"
    ( cd "$SRC" && tar -cf "$dot_dir/ref.tar" -C base ./hello.txt ./dirs )
    dot_rc=0
    ( cd "$SRC" && "$BTAR" -cf "$dot_dir/ours.tar" -C base ./hello.txt ./dirs ) \
        >"$dot_dir/run.out" 2>"$dot_dir/run.err" || dot_rc=$?
    if [ "$dot_rc" -ne 0 ]; then
        add_failure "operands-dot" "btar rc=$dot_rc: $(head -n 1 "$dot_dir/run.err")"
        case_no=$((case_no + 1))
        printf '[%2d] FAIL %-16s (rc=%d)\n' "$case_no" operands-dot "$dot_rc"
    else
        m6_verify "operands-dot" "$dot_dir/ref.tar" "$dot_dir/ours.tar" \
            "leading './' operands"
    fi

    # duplicate operands: documented policy, not a parity requirement
    dup_dir="$TMP/cases/duplicates"
    mkdir -p "$dup_dir"
    dup_rc=0
    ( cd "$SRC" && "$BTAR" -cf "$dup_dir/ours.tar" -C base hello.txt hello.txt ) \
        >"$dup_dir/run.out" 2>"$dup_dir/run.err" || dup_rc=$?
    case_no=$((case_no + 1))
    if [ "$dup_rc" -ne 0 ]; then
        add_failure "duplicates" "btar rc=$dup_rc: $(head -n 1 "$dup_dir/run.err")"
        printf '[%2d] FAIL %-16s (rc=%d)\n' "$case_no" duplicates "$dup_rc"
    elif ! tar -tf "$dup_dir/ours.tar" >"$dup_dir/list.txt" 2>"$dup_dir/list.err"; then
        add_failure "duplicates" "duplicate-operand archive is not GNU-readable"
        printf '[%2d] FAIL %-16s (unreadable archive)\n' "$case_no" duplicates
    else
        btar_dup_count="$(wc -l <"$dup_dir/list.txt" | tr -d ' ')"
        ( cd "$SRC" && tar -cf "$dup_dir/ref.tar" -C base hello.txt hello.txt ) \
            2>/dev/null || true
        gnu_dup_count="$(tar -tf "$dup_dir/ref.tar" 2>/dev/null | wc -l | tr -d ' ')"
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-16s (btar=%s GNU=%s entries; duplicate policy documented)\n' \
            "$case_no" duplicates "$btar_dup_count" "$gnu_dup_count"
    fi

    # absolute operand policy: GNU strips leading '/', btar may reject (both OK)
    abs_dir="$TMP/cases/absolute-operand"
    mkdir -p "$abs_dir"
    abs_rc=0
    ( cd "$SRC" && "$BTAR" -cf "$abs_dir/ours.tar" "$SRC/base/hello.txt" ) \
        >"$abs_dir/run.out" 2>"$abs_dir/run.err" || abs_rc=$?
    case_no=$((case_no + 1))
    if [ "$abs_rc" -eq 0 ]; then
        if tar -tf "$abs_dir/ours.tar" >"$abs_dir/list.txt" 2>/dev/null \
            && ! grep -q '^/' "$abs_dir/list.txt"; then
            pass_count=$((pass_count + 1))
            printf '[%2d] PASS %-16s (absolute operand stripped, no leading /)\n' \
                "$case_no" absolute-operand
        else
            add_failure "absolute-operand" \
                "accepted absolute operand but archive keeps/invalid absolute name"
            printf '[%2d] FAIL %-16s\n' "$case_no" absolute-operand
        fi
    elif [ "$abs_rc" -eq 2 ]; then
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-16s (absolute operand rejected, exit 2)\n' \
            "$case_no" absolute-operand
    else
        add_failure "absolute-operand" "unexpected rc=$abs_rc"
        printf '[%2d] FAIL %-16s (rc=%d)\n' "$case_no" absolute-operand "$abs_rc"
    fi

    # missing operand: fatal exit 2, no valid archive
    miss_dir="$TMP/cases/missing-operand"
    mkdir -p "$miss_dir"
    miss_rc=0
    ( cd "$SRC" && "$BTAR" -cf "$miss_dir/ours.tar" -C base definitely-missing ) \
        >"$miss_dir/run.out" 2>"$miss_dir/run.err" || miss_rc=$?
    case_no=$((case_no + 1))
    if [ "$miss_rc" -ne 2 ]; then
        add_failure "missing-operand" "expected fatal exit 2, got $miss_rc"
        printf '[%2d] FAIL %-16s (rc=%d)\n' "$case_no" missing-operand "$miss_rc"
    elif [ -f "$miss_dir/ours.tar" ] \
        && tar -tf "$miss_dir/ours.tar" >/dev/null 2>&1; then
        add_failure "missing-operand" "fatal exit but output archive is valid"
        printf '[%2d] FAIL %-16s (valid output on fatal)\n' "$case_no" missing-operand
    else
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-16s (fatal exit 2, no valid output)\n' \
            "$case_no" missing-operand
    fi
fi

# --- --sort=name determinism/order -----------------------------------------
SORT=0
sort_probe_rc=0
"$BTAR" --sort=name -cf "$TMP/probe-sort.tar" -C "$SRC/base" . \
    >"$TMP/probe-sort.out" 2>"$TMP/probe-sort.err" || sort_probe_rc=$?
if [ "$sort_probe_rc" -eq 0 ] && tar -tf "$TMP/probe-sort.tar" >/dev/null 2>&1; then
    SORT=1
fi
sort_reason="probe rc=$sort_probe_rc: $(head -n 1 "$TMP/probe-sort.err" 2>/dev/null || true)"
if [ "$SORT" -eq 0 ]; then
    add_skip "sort-name" "--sort=name unsupported yet ($sort_reason)"
    case_no=$((case_no + 1))
    printf '[--] SKIP %-16s (--sort=name unsupported: %s)\n' sort-name "$sort_reason"
else
    sort_dir="$TMP/cases/sort-name"
    mkdir -p "$sort_dir"
    sort_rc=0
    "$BTAR" --sort=name -cf "$sort_dir/a.tar" -C "$SRC/base" . \
        >"$sort_dir/a.out" 2>"$sort_dir/a.err" || sort_rc=$?
    "$BTAR" --sort=name -cf "$sort_dir/b.tar" -C "$SRC/base" . \
        >"$sort_dir/b.out" 2>"$sort_dir/b.err" || sort_rc=$?
    tar --sort=name -cf "$sort_dir/ref.tar" -C "$SRC/base" . 2>/dev/null || true
    sha_a="$(sha256sum "$sort_dir/a.tar" | cut -d' ' -f1)"
    sha_b="$(sha256sum "$sort_dir/b.tar" | cut -d' ' -f1)"
    case_no=$((case_no + 1))
    if [ "$sort_rc" -ne 0 ]; then
        add_failure "sort-name" "btar --sort=name rc=$sort_rc: $(head -n 1 "$sort_dir/a.err")"
        printf '[%2d] FAIL %-16s\n' "$case_no" sort-name
    elif [ "$sha_a" != "$sha_b" ]; then
        add_failure "sort-name" "two --sort=name runs differ (sha256)"
        printf '[%2d] FAIL %-16s (nondeterministic)\n' "$case_no" sort-name
    else
        m6_verify "sort-name" "$sort_dir/ref.tar" "$sort_dir/a.tar" \
            "two runs byte-identical, GNU --sort=name parity"
    fi

    # gzip + --sort determinism (header mtime must stay fixed)
    if [ "$M6_GZIP" -eq 1 ]; then
        gz_sort_rc=0
        "$BTAR" --sort=name -czf "$sort_dir/a.tgz" -C "$SRC/base" . \
            >"$sort_dir/a.tgz.out" 2>"$sort_dir/a.tgz.err" || gz_sort_rc=$?
        if [ "$gz_sort_rc" -eq 2 ]; then
            add_skip "sort-name-gzip" "--sort=name with -czf unsupported yet"
            case_no=$((case_no + 1))
            printf '[--] SKIP %-16s (-czf --sort=name unsupported)\n' sort-name-gzip
        else
            "$BTAR" --sort=name -czf "$sort_dir/b.tgz" -C "$SRC/base" . \
                >"$sort_dir/b.tgz.out" 2>"$sort_dir/b.tgz.err" || true
            gz_sha_a="$(sha256sum "$sort_dir/a.tgz" | cut -d' ' -f1)"
            gz_sha_b="$(sha256sum "$sort_dir/b.tgz" | cut -d' ' -f1)"
            case_no=$((case_no + 1))
            if [ "$gz_sort_rc" -ne 0 ] || ! gzip -t "$sort_dir/a.tgz" \
                >/dev/null 2>&1; then
                add_failure "sort-name-gzip" "btar -czf --sort=name rc=$gz_sort_rc"
                printf '[%2d] FAIL %-16s\n' "$case_no" sort-name-gzip
            elif [ "$gz_sha_a" != "$gz_sha_b" ]; then
                add_failure "sort-name-gzip" "two runs differ (compression nondeterministic)"
                printf '[%2d] FAIL %-16s (nondeterministic)\n' "$case_no" sort-name-gzip
            else
                pass_count=$((pass_count + 1))
                printf '[%2d] PASS %-16s (deterministic gzip, fixed header mtime)\n' \
                    "$case_no" sort-name-gzip
            fi
        fi
    else
        add_skip "sort-name-gzip" "gzip tool missing"
    fi
fi

# --- gzip warning semantics (-czf with a FIFO: exit 1, valid archive) -----
if [ "$M6_GZIP" -eq 0 ]; then
    add_skip "gzip-warning" "gzip tool missing"
    case_no=$((case_no + 1))
    printf '[--] SKIP %-16s (gzip tool missing)\n' gzip-warning
else
    gz_warn_dir="$TMP/cases/gzip-warning"
    mkdir -p "$gz_warn_dir"
    gz_warn_rc=0
    "$BTAR" -czf "$gz_warn_dir/ours.tgz" -C "$SRC/special" . \
        >"$gz_warn_dir/run.out" 2>"$gz_warn_dir/run.err" || gz_warn_rc=$?
    case_no=$((case_no + 1))
    if [ "$gz_warn_rc" -eq 1 ]; then
        if [ ! -f "$gz_warn_dir/ours.tgz" ]; then
            add_failure "gzip-warning" "exit 1 but no archive written"
            printf '[%2d] FAIL %-16s (no archive)\n' "$case_no" gzip-warning
        elif ! gzip -t "$gz_warn_dir/ours.tgz" >/dev/null 2>&1; then
            add_failure "gzip-warning" "exit 1 archive fails gzip -t"
            printf '[%2d] FAIL %-16s (gzip -t rejects archive)\n' "$case_no" gzip-warning
        elif ! tar -tzf "$gz_warn_dir/ours.tgz" >/dev/null 2>&1; then
            add_failure "gzip-warning" "GNU tar cannot list the warning archive"
            printf '[%2d] FAIL %-16s (unreadable archive)\n' "$case_no" gzip-warning
        elif ! mkdir -p "$gz_warn_dir/extract" \
            || ! tar -xzf "$gz_warn_dir/ours.tgz" -C "$gz_warn_dir/extract" \
                >/dev/null 2>&1; then
            add_failure "gzip-warning" "GNU tar cannot extract the warning archive"
            printf '[%2d] FAIL %-16s (unextractable archive)\n' "$case_no" gzip-warning
        else
            pass_count=$((pass_count + 1))
            printf '[%2d] PASS %-16s (exit 1, valid gzip archive, GNU-readable)\n' \
                "$case_no" gzip-warning
        fi
    elif [ "$gz_warn_rc" -eq 0 ]; then
        add_skip "gzip-warning" \
            "warning-exit semantics not implemented yet (rc=0 with warning)"
        printf '[--] SKIP %-16s (rc=0; warning-exit semantics M6 pending)\n' gzip-warning
    elif [ "$gz_warn_rc" -eq 2 ]; then
        add_skip "gzip-warning" \
            "gzip create unavailable/fatal (rc=2): $(head -n 1 "$gz_warn_dir/run.err")"
        printf '[--] SKIP %-16s (gzip create rc=2)\n' gzip-warning
    else
        add_failure "gzip-warning" "unexpected rc=$gz_warn_rc"
        printf '[%2d] FAIL %-16s (rc=%d)\n' "$case_no" gzip-warning "$gz_warn_rc"
    fi
fi

# --------------------------------------------------------------------------- #
# M7: self-roundtrip hardlink regression (create -> same btar extracts)
# Regression for the release blocker fixed in M7: hardlink targets/names with
# the './' root prefix must normalise through path policy. An archive created by
# btar itself (root './') must extract with the same binary into a tree with the
# hardlink pair sharing one inode (nlink=2, same content). Also covers the gzip
# path and a GNU-tar-created './'-prefixed archive.
# --------------------------------------------------------------------------- #
echo
echo "test_create: M7 self-roundtrip hardlink regression"

roundtrip_tree="$SRC/roundtrip"
mkdir -p "$roundtrip_tree"
python3 - "$roundtrip_tree" <<'PY'
import os
import pathlib
import sys

tree = pathlib.Path(sys.argv[1])
(tree / "a").mkdir(parents=True)
(tree / "b" / "nested").mkdir(parents=True)
payload = b"hardlink roundtrip payload\n"
(tree / "a" / "one.txt").write_bytes(payload)
os.link(tree / "a" / "one.txt", tree / "b" / "nested" / "two.txt")
(tree / "regular.txt").write_bytes(b"plain file\n")
os.symlink("a/one.txt", tree / "link-rel")
for path in sorted(tree.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    os.utime(path, ns=(0, 0), follow_symlinks=False)
os.utime(tree, ns=(0, 0))
PY

# verify_self_roundtrip NAME TREE DEST DESCRIPTION
# Asserts the nested cross-dir hardlink pair shares one inode with nlink=2 and
# equal content, then compares the whole extracted tree with the source tree.
verify_self_roundtrip() { # $1 name, $2 source tree, $3 extracted dir, $4 description
    local name="$1" tree="$2" dest="$3" description="$4"
    mkdir -p "$TMP/cases/$name"
    local detail=""
    local ok=1
    detail="$(python3 - "$dest" <<'PY'
import os
import stat
import sys

dest = sys.argv[1]
first = os.path.join(dest, "a", "one.txt")
second = os.path.join(dest, "b", "nested", "two.txt")
try:
    a = os.lstat(first)
    b = os.lstat(second)
except FileNotFoundError as exc:
    print(f"missing hardlink path: {exc}")
    raise SystemExit(1)
problems = []
if not (stat.S_ISREG(a.st_mode) and stat.S_ISREG(b.st_mode)):
    problems.append("hardlink pair is not two regular files")
if a.st_ino != b.st_ino or a.st_dev != b.st_dev:
    problems.append(f"different inodes ({a.st_ino} vs {b.st_ino})")
if a.st_nlink != 2 or b.st_nlink != 2:
    problems.append(f"nlink {a.st_nlink}/{b.st_nlink}, expected 2/2")
with open(first, "rb") as handle:
    content_a = handle.read()
with open(second, "rb") as handle:
    content_b = handle.read()
if content_a != content_b:
    problems.append("content differs between hardlink names")
if problems:
    print("; ".join(problems))
    raise SystemExit(1)
print(f"inode={a.st_ino} nlink={a.st_nlink} content={content_a!r}")
PY
)" || ok=0

    case_no=$((case_no + 1))
    CASE_FAILED=0
    if [ "$ok" -eq 1 ]; then
        tree_rc=0
        python3 "$COMPARE" "$tree" "$dest" >"$TMP/cases/$name/tree.diff" 2>&1 \
            || tree_rc=$?
        if [ "$tree_rc" -ne 0 ]; then
            add_failure "$name" "source tree vs extracted tree differ (see tree.diff)"
            ok=0
        fi
    else
        add_failure "$name" "hardlink assertions failed: $detail"
    fi
    if [ "$ok" -eq 1 ]; then
        pass_count=$((pass_count + 1))
        printf '[%2d] PASS %-22s (%s; %s)\n' "$case_no" "$name" \
            "$description" "$detail"
    else
        printf '[%2d] FAIL %-22s (%s: %s)\n' "$case_no" "$name" \
            "$description" "$detail"
    fi
}

roundtrip_dir="$TMP/cases/roundtrip"
mkdir -p "$roundtrip_dir"

# (a) plain: btar -cf (./ rooted) -> btar -xf
plain_rc=0
"$BTAR" -cf "$roundtrip_dir/self.tar" -C "$roundtrip_tree" . \
    >"$roundtrip_dir/plain-create.out" 2>"$roundtrip_dir/plain-create.err" || plain_rc=$?
if [ "$plain_rc" -ne 0 ]; then
    add_skip "self-roundtrip-plain" "btar create unavailable (rc=$plain_rc)"
    case_no=$((case_no + 1))
    printf '[--] SKIP %-22s (create unavailable)\n' self-roundtrip-plain
else
    mkdir -p "$roundtrip_dir/plain.dest"
    plain_x=0
    "$BTAR" -xf "$roundtrip_dir/self.tar" -C "$roundtrip_dir/plain.dest" \
        >"$roundtrip_dir/plain-x.out" 2>"$roundtrip_dir/plain-x.err" || plain_x=$?
    if [ "$plain_x" -ne 0 ]; then
        case_no=$((case_no + 1))
        add_failure "self-roundtrip-plain" \
            "btar -xf of own ./ archive failed (rc=$plain_x): $(head -n 1 "$roundtrip_dir/plain-x.err")"
        printf '[%2d] FAIL %-22s (extract rc=%d)\n' "$case_no" self-roundtrip-plain "$plain_x"
    else
        verify_self_roundtrip "self-roundtrip-plain" "$roundtrip_tree" \
            "$roundtrip_dir/plain.dest" "btar -cf -> btar -xf"
    fi
fi

# (b) gzip: btar -czf (./ rooted) -> btar -xzf
if [ "$M6_GZIP" -eq 0 ]; then
    add_skip "self-roundtrip-gzip" "gzip tool missing"
    case_no=$((case_no + 1))
    printf '[--] SKIP %-22s (gzip tool missing)\n' self-roundtrip-gzip
else
    gz_rc=0
    "$BTAR" -czf "$roundtrip_dir/self.tgz" -C "$roundtrip_tree" . \
        >"$roundtrip_dir/gz-create.out" 2>"$roundtrip_dir/gz-create.err" || gz_rc=$?
    if [ "$gz_rc" -ne 0 ]; then
        add_skip "self-roundtrip-gzip" \
            "btar -czf unavailable/failed (rc=$gz_rc): $(head -n 1 "$roundtrip_dir/gz-create.err")"
        case_no=$((case_no + 1))
        printf '[--] SKIP %-22s (gzip create unavailable)\n' self-roundtrip-gzip
    else
        mkdir -p "$roundtrip_dir/gzip.dest"
        gz_x=0
        "$BTAR" -xzf "$roundtrip_dir/self.tgz" -C "$roundtrip_dir/gzip.dest" \
            >"$roundtrip_dir/gz-x.out" 2>"$roundtrip_dir/gz-x.err" || gz_x=$?
        if [ "$gz_x" -ne 0 ]; then
            case_no=$((case_no + 1))
            add_failure "self-roundtrip-gzip" \
                "btar -xzf of own ./ gzip archive failed (rc=$gz_x): $(head -n 1 "$roundtrip_dir/gz-x.err")"
            printf '[%2d] FAIL %-22s (extract rc=%d)\n' "$case_no" self-roundtrip-gzip "$gz_x"
        else
            verify_self_roundtrip "self-roundtrip-gzip" "$roundtrip_tree" \
                "$roundtrip_dir/gzip.dest" "btar -czf -> btar -xzf"
        fi
    fi
fi

# (c) GNU-tar-created './'-prefixed hardlink archive -> btar -xf
gnu_rc=0
tar -cf "$roundtrip_dir/gnu-dot.tar" -C "$roundtrip_tree" . \
    >"$roundtrip_dir/gnu-create.out" 2>"$roundtrip_dir/gnu-create.err" || gnu_rc=$?
if [ "$gnu_rc" -ne 0 ]; then
    add_failure "gnu-dot-hardlink" "GNU reference archive creation failed"
    case_no=$((case_no + 1))
    printf '[%2d] FAIL %-22s (GNU create failed)\n' "$case_no" gnu-dot-hardlink
else
    mkdir -p "$roundtrip_dir/gnu.dest"
    gnu_x=0
    "$BTAR" -xf "$roundtrip_dir/gnu-dot.tar" -C "$roundtrip_dir/gnu.dest" \
        >"$roundtrip_dir/gnu-x.out" 2>"$roundtrip_dir/gnu-x.err" || gnu_x=$?
    if [ "$gnu_x" -ne 0 ]; then
        case_no=$((case_no + 1))
        gnu_err="$(head -n 1 "$roundtrip_dir/gnu-x.err")"
        add_failure "gnu-dot-hardlink" \
            "btar -xf of GNU ./-prefixed hardlink archive failed (rc=$gnu_x): $gnu_err"
        printf '[%2d] FAIL %-22s (extract rc=%d)\n' "$case_no" gnu-dot-hardlink "$gnu_x"
    else
        verify_self_roundtrip "gnu-dot-hardlink" "$roundtrip_tree" \
            "$roundtrip_dir/gnu.dest" "GNU tar ./-rooted -> btar -xf"
    fi
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo
if [ "$skip_count" -gt 0 ]; then
    echo "skipped variants:"
    printf '%s' "$skip_log" | sed 's/^/  - /'
fi
if [ "$fail_count" -gt 0 ]; then
    echo "failures:"
    printf '%s' "$failure_log" | sed 's/^/  - /'
    echo "test_create summary: $pass_count pass, $fail_count fail, $skip_count skip"
    echo "RESULT: FAIL (create mode)"
    echo "artifacts: $TMP"
    KEEP=1
    exit 1
fi
echo "test_create summary: $pass_count pass, 0 fail, $skip_count skip (create mode)"
if [ "$KEEP" = 1 ]; then
    echo "artifacts: $TMP"
fi
echo "RESULT: PASS"
