#!/usr/bin/env bash
# bench_release.sh — btar benchmark vs GNU tar, writes bench/RESULTS.md.
#
# Two deterministic workloads, each measured for plain and gzip create/list/
# extract against GNU tar:
#   small  ~5 MiB, 412 entries (files, dirs, symlink, hardlink) — the v1.0.0 tree;
#   large  --large-mib MiB (default 160) of word-like text, random bytes, zero runs and
#          thousands of small files — the streaming / many-entry workload.
#   * wall time, median of --reps (default 3) runs;
#   * peak RSS (max of runs, via Python wait4 resource accounting — no /usr/bin/time);
#   * archive sizes (plain and gzip, btar vs GNU; gzip/plain ratio).
#
# This is a report, not a pass/fail gate: btar being slower is recorded, not an
# error. Exit is nonzero only if a benchmark command itself fails.
#
# Usage:
#   ./tools/bench_release.sh [--reps N] [--large-mib N] [--large-reps N] [--no-large]
#                            [--out PATH] [--keep]
#
#   --reps N         repetitions for the small workload (default 3; median reported)
#   --large-mib N    size of the large workload (default 160)
#   --large-reps N   repetitions for the large workload (default 1)
#   --no-large       skip the large workload
#   --out PATH       markdown output path (default bench/RESULTS.md)
#   --keep           keep the temp trees/archives (printed at the end)
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BTAR="${BTAR:-$ROOT/build/btar}"
BEND="${BEND:-$ROOT/.cache/toolchain/bin/bend}"
OUT="$ROOT/bench/RESULTS.md"
REPS=3
LARGE_MIB=160
LARGE_REPS=1
DO_LARGE=1
KEEP=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --reps) [ "$#" -ge 2 ] || { echo "bench_release: --reps needs a value" >&2; exit 2; }
            REPS="$2"; shift 2 ;;
        --out) [ "$#" -ge 2 ] || { echo "bench_release: --out needs a value" >&2; exit 2; }
            OUT="$2"; shift 2 ;;
        --large-mib) [ "$#" -ge 2 ] || { echo "bench_release: --large-mib needs a value" >&2; exit 2; }
            LARGE_MIB="$2"; shift 2 ;;
        --large-reps) [ "$#" -ge 2 ] || { echo "bench_release: --large-reps needs a value" >&2; exit 2; }
            LARGE_REPS="$2"; shift 2 ;;
        --no-large) DO_LARGE=0; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help)
            sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "bench_release: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done
case "$REPS" in ''|*[!0-9]*) echo "bench_release: --reps must be a positive integer" >&2; exit 2 ;; esac
[ "$REPS" -ge 1 ] || { echo "bench_release: --reps must be >= 1" >&2; exit 2; }

for tool in python3 tar gzip sha256sum timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "bench_release: required tool not found: $tool" >&2
        exit 2
    }
done
[ -x "$BTAR" ] || {
    echo "bench_release: missing $BTAR; run ./tools/test_release.sh or bend app/main.bend -o build/btar" >&2
    exit 2
}

umask 022
export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-bench.XXXXXX")"
cleanup() {
    if [ "$KEEP" = 0 ]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# Workload trees
# --------------------------------------------------------------------------- #
build_small_tree() { # DIR
    python3 - "$1" <<'PY'
import os
import pathlib
import random
import sys

tree = pathlib.Path(sys.argv[1])
rng = random.Random(0)
text = b"tar-bend release benchmark payload 0123456789abcdef\n"


def write(rel: str, data: bytes, mode: int = 0o644) -> None:
    path = tree / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.chmod(path, mode)


# 256 x 4 KiB small files (half compressible text, half incompressible random)
for index in range(256):
    data = (text * 128)[:4096] if index % 2 == 0 else rng.randbytes(4096)
    write(f"small/file-{index:03d}.bin", data)
# 16 dirs x 8 files
for directory in range(16):
    for index in range(8):
        write(f"dirs/d{directory:02d}/f{index}.txt", text * 8, 0o640)
# 4 x 1 MiB files (half zeros, half random)
for index in range(4):
    data = b"\0" * (1024 * 1024) if index % 2 == 0 else rng.randbytes(1024 * 1024)
    write(f"big/blob-{index}.bin", data)
os.symlink("small/file-000.bin", tree / "link-rel")
write("hard/orig.bin", b"hardlinked payload\n")
os.link(tree / "hard" / "orig.bin", tree / "hard" / "link.bin")
for path in sorted(tree.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    os.utime(path, ns=(0, 0), follow_symlinks=False)
os.utime(tree, ns=(0, 0))
PY
}

build_large_tree() { # DIR MIB
    python3 - "$1" "$2" <<'PY'
import os
import pathlib
import random
import sys

tree = pathlib.Path(sys.argv[1])
mib = int(sys.argv[2])
rng = random.Random(11)
vocab = [bytes(rng.choices(b"abcdefghijklmnopqrstuvwxyz", k=rng.randint(2, 10)))
         for _ in range(6000)]


def text(n: int) -> bytes:
    out = bytearray()
    while len(out) < n:
        out += rng.choice(vocab) + (b"\n" if rng.random() < 0.06 else b" ")
    return bytes(out[:n])


def write(rel: str, data: bytes) -> None:
    path = tree / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.chmod(path, 0o644)


budget = mib * 1048576
# a few large files: 50 % text, 15 % random, 10 % zeros (by total budget)
sizes = [("text", budget // 2), ("rand", budget * 15 // 100), ("zero", budget // 10)]
for kind, total in sizes:
    per = 8 * 1048576
    for i in range((total + per - 1) // per):
        n = min(per, total - i * per)
        data = text(n) if kind == "text" else rng.randbytes(n) if kind == "rand" else bytes(n)
        write(f"big/{kind}-{i:03d}.bin", data)
# many small files: ~25 % of the budget in 3 KiB-24 KiB text files across 300 dirs
used = 0
index = 0
while used < budget // 4:
    n = rng.randint(3000, 24000)
    write(f"src/d{index % 300:03d}/f{index:05d}.txt", text(n))
    used += n
    index += 1
os.symlink("big/text-000.bin", tree / "link-rel")
for path in sorted(tree.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    os.utime(path, ns=(0, 0), follow_symlinks=False)
os.utime(tree, ns=(0, 0))
PY
}

tree_stats() { # DIR -> "bytes entries"
    python3 - "$1" <<'PY'
import os
import sys
total = 0
n = 0
for root, dirs, files in os.walk(sys.argv[1]):
    n += len(dirs) + len(files)
    for name in files:
        try:
            total += os.lstat(os.path.join(root, name)).st_size
        except OSError:
            pass
print(total, n + 1)
PY
}

# measure CMD... -> "wall_ms rss_kb rc"
measure() {
    python3 - "$@" <<'PY'
import resource
import subprocess
import sys
import time

started = time.monotonic()
proc = subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL)
wall_ms = (time.monotonic() - started) * 1000.0
usage = resource.getrusage(resource.RUSAGE_CHILDREN)
print(f"{wall_ms:.1f} {usage.ru_maxrss} {proc.returncode}")
PY
}

median() {
    printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'
}

FAILURES=0
SECTIONS_FILE="$TMP/sections.md"
: >"$SECTIONS_FILE"

# bench_workload LABEL TREE REPS -- appends a markdown section to $SECTIONS_FILE
bench_workload() {
    local label="$1" tree="$2" reps="$3"
    local work="$TMP/w-$label"
    mkdir -p "$work"
    local results="$work/results.tsv" errors="$work/errors.tsv"
    : >"$results"; : >"$errors"
    local stats tree_bytes tree_entries tree_mib
    stats="$(tree_stats "$tree")"
    tree_bytes="${stats% *}"; tree_entries="${stats#* }"
    tree_mib="$(python3 -c "print(f'{$tree_bytes/1048576:.1f}')")"
    echo "bench_release: [$label] tree=$tree_mib MiB, $tree_entries entries, $reps run(s)"

    # run_bench OP TOOL CMD...; extraction commands receive a fresh DEST placeholder
    run_bench() {
        local op="$1" tool="$2"
        shift 2
        local -a base=("$@")
        local -a walls=()
        local rss_max=0 rep dest res wall rss rc wall_med err_msg token
        local -a cmd
        for ((rep = 1; rep <= reps; rep++)); do
            dest="$work/dest-$op-$tool-$rep"
            rm -rf "$dest"
            mkdir -p "$dest"
            cmd=()
            for token in "${base[@]}"; do
                [ "$token" = "DEST" ] && token="$dest"
                cmd+=("$token")
            done
            res="$(measure "${cmd[@]}")" || res="0.0 0 -1"
            read -r wall rss rc <<<"$res"
            if [ "$rc" -ne 0 ]; then
                err_msg="$( "${cmd[@]}" 2>&1 | head -n 1 || true )"
                printf '%s\t%s\t%s\t%s\n' "$op" "$tool" "rc=$rc" "$err_msg" >>"$errors"
                echo "bench_release: FAIL $label/$op/$tool rep=$rep rc=$rc: $err_msg" >&2
                FAILURES=$((FAILURES + 1))
            fi
            walls+=("$wall")
            [ "$rss" -gt "$rss_max" ] && rss_max="$rss"
            rm -rf "$dest"
        done
        if [ "${#walls[@]}" -eq 1 ]; then wall_med="${walls[0]}"; else wall_med="$(median "${walls[@]}")"; fi
        printf '%s\t%s\t%s\t%s\n' "$op" "$tool" "$wall_med" "$rss_max" >>"$results"
        echo "bench_release: [$label] $op/$tool median=${wall_med}ms rss=$((rss_max / 1024))MiB"
    }

    # Every operation uses the tool's own archive: create writes, list reads it
    # back, extract expands the same archive.
    run_bench create-plain btar "$BTAR" -cf "$work/btar-plain.tar" -C "$tree" .
    run_bench create-plain gnu tar -cf "$work/gnu-plain.tar" -C "$tree" .
    run_bench create-gzip btar "$BTAR" -czf "$work/btar-gzip.tar.gz" -C "$tree" .
    run_bench create-gzip gnu tar -czf "$work/gnu-gzip.tar.gz" -C "$tree" .
    run_bench list-plain btar "$BTAR" -tf "$work/btar-plain.tar"
    run_bench list-plain gnu tar -tf "$work/gnu-plain.tar"
    run_bench list-gzip btar "$BTAR" -tzf "$work/btar-gzip.tar.gz"
    run_bench list-gzip gnu tar -tzf "$work/gnu-gzip.tar.gz"
    run_bench extract-plain btar "$BTAR" -xf "$work/btar-plain.tar" -C DEST
    run_bench extract-plain gnu tar -xf "$work/gnu-plain.tar" -C DEST
    run_bench extract-gzip btar "$BTAR" -xzf "$work/btar-gzip.tar.gz" -C DEST
    run_bench extract-gzip gnu tar -xzf "$work/gnu-gzip.tar.gz" -C DEST
    # GNU-made gzip archive read by btar (the realistic .tar.gz download case)
    run_bench list-gzip-gnu-made btar "$BTAR" -tzf "$work/gnu-gzip.tar.gz"
    run_bench extract-gzip-gnu-made btar "$BTAR" -xzf "$work/gnu-gzip.tar.gz" -C DEST

    value_of() { # op tool column(3=wall,4=rss)
        awk -F'\t' -v op="$1" -v tool="$2" -v col="$3" \
            '$1 == op && $2 == tool {print $col}' "$results"
    }
    op_error() {
        awk -F'\t' -v op="$1" -v tool="$2" '$1 == op && $2 == tool {print $3": "$4}' "$errors" | head -n 1
    }
    table_row() { # op label
        local op="$1" label="$2" bw br gw gr berr gerr ratio
        bw="$(value_of "$op" btar 3)"; br="$(value_of "$op" btar 4)"
        gw="$(value_of "$op" gnu 3)"; gr="$(value_of "$op" gnu 4)"
        berr="$(op_error "$op" btar)"; gerr="$(op_error "$op" gnu)"
        if [ -n "$berr" ] || [ -n "$gerr" ]; then
            printf '| %s | %s | - | %s | - | n/a |\n' "$label" "${berr:+FAIL}" "${gerr:+FAIL}"; return
        fi
        ratio="$(python3 -c "print(f'{$bw/$gw:.2f}x' if $gw > 0 else 'n/a')")"
        printf '| %s | %.1f | %d | %.1f | %d | %s |\n' \
            "$label" "$bw" "$((br / 1024))" "$gw" "$((gr / 1024))" "$ratio"
    }
    table_row_gnu_made() { # op label
        local op="$1" label="$2" bw br
        bw="$(value_of "$op" btar 3)"; br="$(value_of "$op" btar 4)"
        printf '| %s | %.1f | %d | (same GNU archive: see gzip rows) | - | - |\n' \
            "$label" "$bw" "$((br / 1024))"
    }

    local bps gps bgs ggs bgp ggp
    bps="$(stat -c%s "$work/btar-plain.tar")"; gps="$(stat -c%s "$work/gnu-plain.tar")"
    bgs="$(stat -c%s "$work/btar-gzip.tar.gz" 2>/dev/null || echo 0)"; ggs="$(stat -c%s "$work/gnu-gzip.tar.gz")"
    bgp="$(python3 -c "print(f'{100.0*$bgs/$bps:.1f}')")"; ggp="$(python3 -c "print(f'{100.0*$ggs/$gps:.1f}')")"
    {
        echo "## $label workload — $tree_mib MiB, $tree_entries entries ($reps run(s), median wall time)"
        echo
        echo "| operation | btar ms | btar RSS MiB | GNU tar ms | GNU tar RSS MiB | btar/GNU wall |"
        echo "|---|---:|---:|---:|---:|---:|"
        table_row create-plain "create plain"
        table_row create-gzip "create gzip (-z)"
        table_row list-plain "list plain (-t)"
        table_row list-gzip "list gzip (-tz)"
        table_row extract-plain "extract plain (-x)"
        table_row extract-gzip "extract gzip (-xz)"
        table_row_gnu_made list-gzip-gnu-made "list GNU-made .tar.gz (btar -tz)"
        table_row_gnu_made extract-gzip-gnu-made "extract GNU-made .tar.gz (btar -xz)"
        echo
        echo "| archive | size (bytes) | vs plain |"
        echo "|---|---:|---:|"
        printf '| btar plain tar | %d | 100.0%% |\n' "$bps"
        printf '| GNU plain tar | %d | 100.0%% |\n' "$gps"
        printf '| btar gzip | %d | %s%% |\n' "$bgs" "$bgp"
        printf '| GNU tar -czf (gzip -6) | %d | %s%% |\n' "$ggs" "$ggp"
        echo
    } >>"$SECTIONS_FILE"
    rm -rf "$work"
}

SMALL="$TMP/tree-small"
echo "bench_release: building small tree ..."
build_small_tree "$SMALL"
bench_workload small "$SMALL" "$REPS"
rm -rf "$SMALL"
if [ "$DO_LARGE" = 1 ]; then
    LARGE="$TMP/tree-large"
    echo "bench_release: building large tree ($LARGE_MIB MiB) ..."
    build_large_tree "$LARGE" "$LARGE_MIB"
    bench_workload large "$LARGE" "$LARGE_REPS"
    rm -rf "$LARGE"
fi

btar_version="$(timeout 5 "$BTAR" --version 2>/dev/null | head -n 1 || true)"
[ -n "$btar_version" ] || btar_version="(no --version support yet)"
gnu_tar_version="$(tar --version | head -n 1)"
bend_version="$("$BEND" version 2>/dev/null || echo 'n/a')"
gzip_version="$(gzip --version | head -n 1)"
cpu_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
cores="$(nproc)"
mem_gib="$(python3 -c "print(round($(grep -m1 MemTotal /proc/meminfo | awk '{print $2}')/1048576, 1))")"
kernel="$(uname -sr)"
tmp_fs="$(df -T /tmp 2>/dev/null | awk 'NR==2 {print $2}')"
date_utc="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
host="$(hostname)"

mkdir -p "$(dirname "$OUT")"
{
    echo "# tar-bend benchmark — btar vs GNU tar"
    echo
    echo "Generated by \`tools/bench_release.sh\` (median wall time; peak RSS = max over runs, from"
    echo "Python \`wait4\` accounting of the process tree's largest member)."
    echo
    echo "- date: $date_utc"
    echo "- host: $host ($cores cores: $cpu_model, ${mem_gib} GiB RAM, kernel $kernel)"
    echo "- filesystem for temp trees/archives: $tmp_fs (\`/tmp\`), warm page cache"
    echo "- btar: \`$btar_version\` ($(stat -c%s "$BTAR") bytes), native, default threads (= $cores)"
    echo "- GNU tar: \`$gnu_tar_version\`; gzip: \`$gzip_version\` (\`tar -z\` = level 6); Bend: \`$bend_version\`"
    echo "- gzip in btar is pure Bend: streaming decoder (single-threaded), segment-parallel encoder"
    echo "  (all cores). No size caps. The v1.0.0 numbers are kept in docs/release-verification.md."
    echo
    cat "$SECTIONS_FILE"
    echo "## notes"
    echo
    echo "- Every operation uses the tool's own archive (create writes it, list/extract read it back);"
    echo "  extraction destinations are fresh per run and removed outside the measurement."
    echo "- This is a report, not a gate: slower-than-GNU numbers are recorded, not failures."
} >"$OUT"

echo
cat "$OUT"
echo
if [ "$FAILURES" -gt 0 ]; then
    echo "bench_release: $FAILURES benchmark run(s) exited nonzero; see report"
    echo "RESULT: FAIL ($FAILURES benchmark run(s) exited nonzero; see report)"
    exit 1
fi
echo "RESULT: PASS (benchmark report written to $OUT)"
