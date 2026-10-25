#!/usr/bin/env bash
# run_diff.sh — differential extraction harness for tar-bend (M3).
#
# For every valid fixture from fixtures/generated/manifest.json:
#   * verify its sha256 against the manifest;
#   * baseline: extract with GNU tar into A, with bsdtar into B, compare A/B
#     (fixtures flagged `baseline_bsdtar: "refuse"` are GNU-only: bsdtar is
#     expected to reject them, e.g. non-comment global pax keys);
#   * compare normalised `tar -tvf` vs `bsdtar -tvf` listings (GNU-only
#     fixtures are compared with GNU tar only);
#   * if BTAR is set (resolved executable): extract into C with the fixture's
#     manifest btar_args (`-p`, ...), compare A/C; for fixtures with
#     `reference_args` compare C against GNU tar extracted with the same args
#     using --strict-modes (reference setuid/setgid cleared per plan rule 6);
#   * for fixtures flagged `stdout_check`, compare `BTAR -xOf` bytes against
#     `GNU tar -xOf`.
#
# Usage:
#   ./tools/run_diff.sh [--keep] [--regen]
#   BTAR=/path/to/btar ./tools/run_diff.sh
#
#   --keep   keep the temporary work directory (printed at the end)
#   --regen  regenerate fixtures even if fixtures/generated/manifest.json exists
#
# Exit codes: 0 all checks pass, 1 failures, 2 setup/usage error.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/fixtures/generated"
MANIFEST="$FIXTURES/manifest.json"
GEN="$ROOT/tools/gen_fixtures.py"
COMPARE="$ROOT/tools/compare_tree.py"

KEEP=0
REGEN=0
for arg in "$@"; do
    case "$arg" in
        --keep)  KEEP=1 ;;
        --regen) REGEN=1 ;;
        -h|--help)
            sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "run_diff: unknown argument: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

for tool in python3 tar bsdtar sha256sum cmp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "run_diff: required tool not found: $tool" >&2
        exit 2
    fi
done

BTAR_BIN=""
if [ -n "${BTAR:-}" ]; then
    if ! BTAR_BIN="$(command -v "$BTAR" 2>/dev/null)"; then
        echo "run_diff: BTAR is set but not executable/found: $BTAR" >&2
        exit 2
    fi
    echo "btar binary: $BTAR_BIN"
fi

if [ "$REGEN" = 1 ] || [ ! -f "$MANIFEST" ]; then
    echo "generating fixtures ..."
    python3 "$GEN"
fi

umask 022
export LC_ALL=C

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-diff.XXXXXX")"
cleanup() {
    if [ "$KEEP" = 0 ]; then
        rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT

# file, sha256, btar_args('|'), reference_args('|'), stdout_check(0/1),
# baseline_bsdtar(ok/refuse)
mapfile -t VALID_ROWS < <(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for fixture in manifest["valid"]:
    print("\x1f".join([
        fixture["file"],
        fixture["sha256"],
        "|".join(fixture.get("btar_args", [])),
        "|".join(fixture.get("reference_args", [])),
        "1" if fixture.get("stdout_check") else "0",
        fixture.get("baseline_bsdtar", "ok"),
    ]))
PY
)

total="${#VALID_ROWS[@]}"
baseline_pass=0
gnu_only=0
btar_total=0
btar_pass=0
stdout_checks=0
stdout_pass=0
strict_checks=0
strict_pass=0
failures=0
index=0
failure_log=""

add_failure() { # $1 fixture name, $2 reason
    failures=$((failures + 1))
    failure_log+="$1: $2"$'\n'
}

# split_args <'|'-joined string> -> ARGS array (empty string -> empty array)
split_args() {
    ARGS=()
    if [ -n "$1" ]; then
        IFS='|' read -r -a ARGS <<<"$1"
    fi
}

for row in "${VALID_ROWS[@]}"; do
    IFS=$'\x1f' read -r file expected_sha btar_args ref_args stdout_check \
        baseline_bsdtar <<<"$row"
    name="${file#valid/}"
    name="${name%.tar}"
    fixture="$FIXTURES/$file"
    work="$TMP/$name"
    mkdir -p "$work/A" "$work/B"
    index=$((index + 1))
    baseline_bad=0
    reasons=""
    add_reason() { if [ -z "$reasons" ]; then reasons="$1"; else reasons="$reasons; $1"; fi; }
    split_args "$btar_args"
    bargs=("${ARGS[@]}")
    split_args "$ref_args"
    rargs=("${ARGS[@]}")

    # 1. Fixture integrity: stale/corrupt fixtures are a harness error.
    if [ ! -f "$fixture" ]; then
        add_reason "missing fixture"
        baseline_bad=1
    else
        actual_sha="$(sha256sum -- "$fixture" | cut -d' ' -f1)"
        if [ "$actual_sha" != "$expected_sha" ]; then
            add_reason "sha256 mismatch (run --regen)"
            baseline_bad=1
        fi
    fi

    # 2. GNU tar baseline extraction.
    gnu_rc=0
    tar -xf "$fixture" -C "$work/A" >"$work/gnu.out" 2>"$work/gnu.err" || gnu_rc=$?
    if [ "$gnu_rc" -ne 0 ]; then
        add_reason "GNU tar extract rc=$gnu_rc"
        baseline_bad=1
    fi

    # 3. bsdtar baseline extraction. Some GNU-valid fixtures use pax global
    #    metadata that libarchive refuses; the manifest flags those GNU-only.
    bsd_rc=0
    bsdtar -xf "$fixture" -C "$work/B" >"$work/bsd.out" 2>"$work/bsd.err" \
        || bsd_rc=$?
    bsd_ok=0
    if [ "$baseline_bsdtar" = "refuse" ]; then
        if [ "$bsd_rc" -ne 0 ]; then
            gnu_only=$((gnu_only + 1))
        else
            bsd_ok=1
        fi
    else
        if [ "$bsd_rc" -ne 0 ]; then
            add_reason "bsdtar extract rc=$bsd_rc"
            baseline_bad=1
        else
            bsd_ok=1
        fi
    fi

    # 4. Extracted tree comparison (the actual differential baseline).
    if [ "$gnu_rc" -eq 0 ] && [ "$bsd_ok" -eq 1 ]; then
        cmp_rc=0
        python3 "$COMPARE" "$work/A" "$work/B" >"$work/cmp.out" 2>&1 || cmp_rc=$?
        if [ "$cmp_rc" -ne 0 ]; then
            add_reason "baseline tree compare failed (see $work/cmp.out)"
            baseline_bad=1
            sed 's/^/    /' "$work/cmp.out" >&2
        fi
    fi

    # 5. Normalised listing comparison (type/size/name/link, no date/owner).
    gnu_list_rc=0
    tar -tvf "$fixture" >"$work/gnu.list" 2>"$work/gnu.list.err" || gnu_list_rc=$?
    bsd_list_rc=0
    if [ "$baseline_bsdtar" = "refuse" ]; then
        bsd_list_rc=0  # GNU-only fixture: libarchive refuses the global keys
    else
        bsdtar -tvf "$fixture" >"$work/bsd.list" 2>"$work/bsd.list.err" \
            || bsd_list_rc=$?
    fi
    if [ "$gnu_list_rc" -ne 0 ] || [ "$bsd_list_rc" -ne 0 ]; then
        add_reason "listing rc gnu=$gnu_list_rc bsdtar=$bsd_list_rc"
        baseline_bad=1
    elif [ "$baseline_bsdtar" != "refuse" ]; then
        list_rc=0
        python3 "$COMPARE" --listings "$work/gnu.list" "$work/bsd.list" \
            >"$work/listcmp.out" 2>&1 || list_rc=$?
        if [ "$list_rc" -ne 0 ]; then
            add_reason "baseline listing compare failed"
            baseline_bad=1
            sed 's/^/    /' "$work/listcmp.out" >&2
        fi
    fi

    # 6. Optional btar differential extraction (with manifest args).
    if [ -n "$BTAR_BIN" ]; then
        btar_total=$((btar_total + 1))
        btar_ok=1
        mkdir -p "$work/C"
        btar_rc=0
        "$BTAR_BIN" -xf "$fixture" -C "$work/C" "${bargs[@]}" \
            >"$work/btar.out" 2>"$work/btar.err" || btar_rc=$?
        if [ "$btar_rc" -ne 0 ]; then
            add_reason "btar extract rc=$btar_rc (args: ${btar_args:-none})"
            btar_ok=0
        elif [ "${#rargs[@]}" -gt 0 ]; then
            # 6b. Arg-sensitive extraction (-p): default extraction A is not an
            #     apples-to-apples reference (umask applies, setuid is stripped),
            #     so compare strictly against GNU tar extracted with the same
            #     reference args. The reference setuid/setgid bits are cleared
            #     to match plan rule 6 (non-root strip); btar -p is expected to
            #     preserve 07777 minus setuid/setgid.
            strict_checks=$((strict_checks + 1))
            mkdir -p "$work/R"
            ref_rc=0
            tar -x -f "$fixture" -C "$work/R" "${rargs[@]}" \
                >"$work/ref.out" 2>"$work/ref.err" || ref_rc=$?
            if [ "$ref_rc" -ne 0 ]; then
                add_reason "GNU reference extraction failed (args: ${ref_args})"
                btar_ok=0
            else
                find "$work/R" -perm /6000 -exec chmod u-s,g-s {} + 2>/dev/null \
                    || true
                strict_rc=0
                python3 "$COMPARE" --strict-modes "$work/C" "$work/R" \
                    >"$work/strict_cmp.out" 2>&1 || strict_rc=$?
                if [ "$strict_rc" -ne 0 ]; then
                    add_reason "strict-mode compare against GNU ${ref_args} failed"
                    sed 's/^/    /' "$work/strict_cmp.out" >&2
                    btar_ok=0
                else
                    strict_pass=$((strict_pass + 1))
                fi
            fi
        else
            btar_cmp_rc=0
            python3 "$COMPARE" "$work/A" "$work/C" >"$work/btar_cmp.out" 2>&1 \
                || btar_cmp_rc=$?
            if [ "$btar_cmp_rc" -ne 0 ]; then
                add_reason "btar tree compare failed"
                sed 's/^/    /' "$work/btar_cmp.out" >&2
                btar_ok=0
            fi
        fi

        # 6c. -O stdout extraction byte comparison.
        if [ "$stdout_check" = 1 ]; then
            stdout_checks=$((stdout_checks + 1))
            stdout_rc=0
            "$BTAR_BIN" -xOf "$fixture" >"$work/stdout.btar" \
                2>"$work/stdout.btar.err" || stdout_rc=$?
            gnu_stdout_rc=0
            tar -xOf "$fixture" >"$work/stdout.gnu" 2>"$work/stdout.gnu.err" \
                || gnu_stdout_rc=$?
            if [ "$stdout_rc" -ne 0 ] || [ "$gnu_stdout_rc" -ne 0 ]; then
                add_reason "stdout extraction rc btar=$stdout_rc gnu=$gnu_stdout_rc"
                btar_ok=0
            elif ! cmp -s "$work/stdout.btar" "$work/stdout.gnu"; then
                add_reason "stdout extraction bytes differ from GNU tar -xOf"
                btar_ok=0
            else
                stdout_pass=$((stdout_pass + 1))
            fi
        fi

        [ "$btar_ok" -eq 1 ] && btar_pass=$((btar_pass + 1))
    fi

    # 7. Pass bookkeeping + result line.
    if [ "$baseline_bad" -eq 0 ]; then
        baseline_pass=$((baseline_pass + 1))
    fi
    if [ -n "$reasons" ]; then
        add_failure "$name" "$reasons"
    fi
    if [ -z "$reasons" ]; then
        printf '[%2d/%2d] PASS %s\n' "$index" "$total" "$name"
    else
        printf '[%2d/%2d] FAIL %s: %s\n' "$index" "$total" "$name" "$reasons"
    fi
done

echo
if [ "$gnu_only" -gt 0 ]; then
    echo "baseline (GNU tar 1.35 vs bsdtar): $baseline_pass/$total pass" \
        "($((total - gnu_only)) GNU-vs-bsdtar identical, $gnu_only GNU-only:" \
        "bsdtar refuses non-comment global pax keys)"
else
    echo "baseline (GNU tar 1.35 vs bsdtar): $baseline_pass/$total fixtures identical"
fi
if [ -n "$BTAR_BIN" ]; then
    echo "btar differential: $btar_pass/$btar_total fixtures identical ($BTAR_BIN)"
    if [ "$strict_checks" -gt 0 ]; then
        echo "btar -p/strict modes: $strict_pass/$strict_checks fixtures match" \
            "GNU tar reference (setuid/setgid cleared)"
    fi
    if [ "$stdout_checks" -gt 0 ]; then
        echo "btar -O stdout: $stdout_pass/$stdout_checks fixtures byte-identical" \
            "to GNU tar -xOf"
    fi
else
    echo "btar differential: SKIP (BTAR unset)"
    echo "btar -p/-O checks: SKIP (BTAR unset)"
fi
if [ "$failures" -gt 0 ]; then
    echo
    echo "failures:"
    printf '%s' "$failure_log" | sed 's/^/  - /'
    echo "RESULT: FAIL ($failures fixture(s))"
    echo "artifacts: $TMP"
    KEEP=1 # never delete evidence on failure
    exit 1
fi
if [ "$KEEP" = 1 ]; then
    echo "artifacts: $TMP"
fi
echo "RESULT: PASS"
