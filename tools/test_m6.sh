#!/usr/bin/env bash
# test_m6.sh — aggregate M6 gate: create + gzip + security + diff baselines.
#
# Runs the four harness scripts, captures their logs, and prints one combined
# summary. Optional convenience for the Lead to wire into tools/run.sh; it adds
# no checks of its own (each script reports its own PASS/FAIL/SKIP).
#
# Usage:
#   ./tools/test_m6.sh [--keep]
#
#   --keep  keep the per-script logs (printed at the end; always kept on failure)
#
# Exit codes: 0 all scripts pass/skip, 1 any script fails, 2 setup error.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        -h|--help)
            sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "test_m6: unknown argument: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-m6.XXXXXX")"
cleanup() {
    if [ "$KEEP" = 0 ]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT

scripts=("test_create.sh" "test_gzip.sh" "run_security.sh" "run_diff.sh")
pass=0
fail=0
skip=0
detail=""

for name in "${scripts[@]}"; do
    script="$ROOT/tools/$name"
    log="$TMP/${name%.sh}.log"
    if [ ! -x "$script" ]; then
        detail+="[SKIP] $name (missing)"$'\n'
        skip=$((skip + 1))
        continue
    fi
    echo "test_m6: running $name ..."
    rc=0
    # create/gzip harnesses exercise the BTAR binary; diff/security here are the
    # BTAR-unset baselines (their BTAR-enabled modes are run by the Lead gate).
    case "$name" in
        test_create.sh|test_gzip.sh) btar_env="${BTAR:-$ROOT/build/btar}" ;;
        *) btar_env="" ;;
    esac
    if BTAR="$btar_env" "$script" >"$log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    result="$(grep -E '^RESULT:' "$log" | tail -n 1 || true)"
    summary="$(grep -E 'summary:' "$log" | tail -n 1 || true)"
    case "$result" in
        *SKIP*) status="SKIP"; skip=$((skip + 1)) ;;
        *PASS*) status="PASS"; pass=$((pass + 1)) ;;
        *FAIL*) status="FAIL"; fail=$((fail + 1)) ;;
        *)
            if [ "$rc" -eq 0 ]; then status="PASS"; pass=$((pass + 1))
            else status="FAIL"; fail=$((fail + 1)); fi
            ;;
    esac
    if [ "$rc" -ne 0 ] && [ "$status" = "PASS" ]; then
        status="FAIL"
        pass=$((pass - 1))
        fail=$((fail + 1))
    fi
    printf '[%-4s] %-18s rc=%d  %s\n' "$status" "$name" "$rc" "${summary:-$result}"
    detail+="[$status] $name (rc=$rc): ${result:-no RESULT line}"$'\n'
done

echo
echo "test_m6 summary: $pass pass, $fail fail, $skip skip"
if [ "$KEEP" = 1 ] || [ "$fail" -gt 0 ]; then
    echo "logs: $TMP"
fi
if [ "$fail" -gt 0 ]; then
    printf '%s' "$detail" | sed 's/^/  /'
    echo "RESULT: FAIL (aggregate)"
    KEEP=1
    exit 1
fi
echo "RESULT: PASS"
