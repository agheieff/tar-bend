#!/usr/bin/env bash
# run_security.sh — adversarial extraction harness for tar-bend (M0).
#
# For every evil fixture in fixtures/generated/manifest.json:
#   * validate the fixture against its manifest sha256;
#   * if BTAR is set (resolved binary), extract it into a fresh sandbox root and
#     assert the manifest exit policy against the plan §2.1 contract (0 ok,
#     1 warnings, 2 fatal; `nonzero` = 1/2, `either` = 0/1/2), that nothing
#     outside the root changed
#     (sentinel files intact, no symlink followed), and fixture-specific checks
#     such as "no special files" / "no large file created";
#   * if BTAR is unset, extract with GNU tar and bsdtar as controls (safe mode,
#     no -P extraction), record their exit codes and whether they wrote outside
#     the sandbox root, and print SKIP for the BTAR assertions. Listing with -P
#     is recorded too, without extracting to the host.
#
# Usage:
#   ./tools/run_security.sh [--keep] [--regen] [STRACE=1]
#   BTAR=/path/to/btar ./tools/run_security.sh [STRACE=1]
#
#   --keep   keep the temporary sandbox (printed at the end)
#   --regen  regenerate fixtures even if the manifest exists
#   STRACE=1 wrap each btar run in strace -f -e trace=openat2,openat,linkat,
#            symlinkat,mkdirat -o <case>/strace.log (requires strace installed)
#
# Exit codes: 0 pass (or controls recorded with BTAR unset), 1 failure,
#             2 setup/usage error.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/fixtures/generated"
MANIFEST="$FIXTURES/manifest.json"
GEN="$ROOT/tools/gen_fixtures.py"

KEEP=0
REGEN=0
for arg in "$@"; do
    case "$arg" in
        --keep)  KEEP=1 ;;
        --regen) REGEN=1 ;;
        -h|--help)
            sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "run_security: unknown argument: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

for tool in python3 tar bsdtar sha256sum find diff stat; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "run_security: required tool not found: $tool" >&2
        exit 2
    fi
done

BTAR_BIN=""
if [ -n "${BTAR:-}" ]; then
    if ! BTAR_BIN="$(command -v "$BTAR" 2>/dev/null)"; then
        echo "run_security: BTAR is set but not executable/found: $BTAR" >&2
        exit 2
    fi
    echo "btar binary: $BTAR_BIN"
fi

STRACE=0
if [ "${STRACE:-0}" = 1 ]; then
    if command -v strace >/dev/null 2>&1; then
        STRACE=1
    else
        echo "run_security: STRACE=1 but strace is not installed; continuing" >&2
    fi
fi

if [ "$REGEN" = 1 ] || [ ! -f "$MANIFEST" ]; then
    echo "generating fixtures ..."
    python3 "$GEN"
fi

umask 022
export LC_ALL=C

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-sec.XXXXXX")"
cleanup() {
    if [ "$KEEP" = 0 ]; then
        rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT

mapfile -t EVIL_ROWS < <(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for fixture in manifest["evil"]:
    expected = fixture["expected"]
    print("\x1f".join([
        fixture["file"],
        fixture["sha256"],
        expected["policy"],
        expected["btar_exit"],
        ",".join(expected.get("checks", [])),
        "|".join(expected.get("btar_args", [])),
        expected.get("note", ""),
    ]))
PY
)

total="${#EVIL_ROWS[@]}"
if [ "$total" -eq 0 ]; then
    echo "run_security: manifest contains no evil fixtures" >&2
    exit 2
fi

# Sandbox layout per case: <case>/container/{root,outside,sentinel.txt}.
prepare_sandbox() { # $1 sandbox base
    mkdir -p "$1/container/root" "$1/container/outside"
    printf 'sentinel: do not touch\n' >"$1/container/sentinel.txt"
    printf 'sentinel: outside root\n' >"$1/container/outside/sentinel.txt"
}

# Paths/type changes outside <root>, excluding the root subtree itself.
snapshot_outside() { # $1 container, $2 root, $3 output file
    find "$1" -mindepth 1 -not -path "$2" -not -path "$2/*" \
        -printf '%y %P -> %l\n' 2>/dev/null | LC_ALL=C sort >"$3"
}

sentinel_digest() { # $1 sandbox base; content + inode/link-count fingerprint
    sha256sum "$1/container/sentinel.txt" "$1/container/outside/sentinel.txt" \
        | sed 's/  .*//'
    stat -c '%i %h' "$1/container/sentinel.txt" \
        "$1/container/outside/sentinel.txt"
}

# Extract with a control tool into <root>; sets LAST_RC.
LAST_RC=0
extract_control() { # $1 tool, $2 fixture, $3 root, $4 log base
    local rc=0
    "$1" -xf "$2" -C "$3" >"$4.out" 2>"$4.err" || rc=$?
    LAST_RC="$rc"
}

run_btar() { # $1 case dir, $2 fixture, $3 root, $4 '|'-joined extra args
    local case_dir="$1" fixture="$2" root="$3" extra="$4"
    local -a args=()
    if [ -n "$extra" ]; then
        IFS='|' read -r -a args <<<"$extra"
    fi
    local rc=0
    if [ "$STRACE" = 1 ]; then
        strace -f -e trace=openat2,openat,linkat,symlinkat,mkdirat \
            -o "$case_dir/strace.log" \
            "$BTAR_BIN" -xf "$fixture" -C "$root" "${args[@]}" \
            >"$case_dir/btar.out" 2>"$case_dir/btar.err" || rc=$?
    else
        "$BTAR_BIN" -xf "$fixture" -C "$root" "${args[@]}" \
            >"$case_dir/btar.out" 2>"$case_dir/btar.err" || rc=$?
    fi
    LAST_RC="$rc"
}

first_line() {
    { head -n 1 "$1" 2>/dev/null || true; } | tr -d '\n' | cut -c1-160
}

# check_outside <case dir>: 0 if nothing outside root changed, 1 otherwise.
# Sets OUTSIDE_CHANGE and writes after.snapshot / after.sentinel.
check_outside() { # $1 case dir
    local case_dir="$1"
    snapshot_outside "$case_dir/container" "$case_dir/container/root" \
        "$case_dir/after.snapshot"
    if ! diff -q "$case_dir/before.snapshot" "$case_dir/after.snapshot" \
        >/dev/null 2>&1; then
        OUTSIDE_CHANGE="outside-root paths changed"
        return 1
    fi
    sentinel_digest "$case_dir" >"$case_dir/after.sentinel"
    if ! diff -q "$case_dir/before.sentinel" "$case_dir/after.sentinel" \
        >/dev/null 2>&1; then
        OUTSIDE_CHANGE="sentinel modified"
        return 1
    fi
    OUTSIDE_CHANGE=""
    return 0
}

failures=0
passed=0
exit_zero=0
exit_warn=0
exit_fatal=0
controls_gnu=0
controls_bsd=0
fixtures_ok=0
outside_events=0
p_runs=0
p_escapes=0
failure_log=""
warning_log=""

if [ -n "$BTAR_BIN" ]; then
    for row in "${EVIL_ROWS[@]}"; do
        IFS=$'\x1f' read -r file sha policy btar_exit checks extra note \
            <<<"$row"
        name="${file#evil/}"
        name="${name%.tar}"
        fixture="$FIXTURES/$file"
        case_dir="$TMP/cases/$name"
        reasons=""
        add_reason() {
            if [ -z "$reasons" ]; then reasons="$1"; else reasons="$reasons; $1"; fi
        }

        if [ ! -f "$fixture" ]; then
            add_reason "missing fixture"
        else
            actual_sha="$(sha256sum -- "$fixture" | cut -d' ' -f1)"
            if [ "$actual_sha" != "$sha" ]; then
                add_reason "sha256 mismatch (run --regen)"
            fi
        fi

        prepare_sandbox "$case_dir"
        snapshot_outside "$case_dir/container" "$case_dir/container/root" \
            "$case_dir/before.snapshot"
        sentinel_digest "$case_dir" >"$case_dir/before.sentinel"

        run_btar "$case_dir" "$fixture" "$case_dir/container/root" "$extra"
        rc="$LAST_RC"

        # Plan §2.1 exit contract: 0 success, 1 warnings (skipped/refused
        # entries), 2 fatal. `nonzero` accepts either warning or fatal; `either`
        # additionally accepts success; `warn`/`fatal` pin one class exactly.
        case "$btar_exit" in
            nonzero)
                case "$rc" in
                    1|2) : ;;
                    *) add_reason "expected warning/fatal exit (1/2), got $rc" ;;
                esac ;;
            zero)
                [ "$rc" -eq 0 ] || add_reason "expected zero exit, got $rc" ;;
            warn)
                [ "$rc" -eq 1 ] || add_reason "expected warning exit 1, got $rc" ;;
            fatal)
                [ "$rc" -eq 2 ] || add_reason "expected fatal exit 2, got $rc" ;;
            either)
                case "$rc" in
                    0|1|2) : ;;
                    *) add_reason "exit $rc outside plan contract 0/1/2" ;;
                esac ;;
            *)
                add_reason "bad manifest btar_exit '$btar_exit'" ;;
        esac
        case "$rc" in
            0) exit_zero=$((exit_zero + 1)) ;;
            1) exit_warn=$((exit_warn + 1)) ;;
            2) exit_fatal=$((exit_fatal + 1)) ;;
        esac

        if ! check_outside "$case_dir"; then
            add_reason "$OUTSIDE_CHANGE"
            outside_events=$((outside_events + 1))
        fi

        if [ "$checks" = "no-special-files" ]; then
            found="$(find "$case_dir/container/root" \
                \( -type p -o -type c -o -type b \) -print -quit 2>/dev/null)"
            [ -z "$found" ] || add_reason "special file created"
        fi
        if [ "$checks" = "no-large-file" ]; then
            found="$(find "$case_dir/container/root" -type f -size +16M \
                -print -quit 2>/dev/null)"
            [ -z "$found" ] || add_reason "suspicious large file created"
        fi

        if [ -z "$reasons" ]; then
            passed=$((passed + 1))
            printf '[%2d/%2d] PASS evil/%-34s policy=%-12s rc=%d outside=clean\n' \
                "$((passed + failures))" "$total" "$name" "$policy" "$rc"
        else
            failures=$((failures + 1))
            printf '[%2d/%2d] FAIL evil/%-34s policy=%-12s rc=%d: %s\n' \
                "$((passed + failures))" "$total" "$name" "$policy" "$rc" \
                "$reasons"
            failure_log+="$name: $reasons (log: $case_dir/btar.err)"$'\n'
            if [ -s "$case_dir/btar.err" ]; then
                echo "    stderr: $(first_line "$case_dir/btar.err")"
            fi
        fi
    done

    echo
    echo "security summary (BTAR=$BTAR_BIN): $passed/$total evil fixtures passed"
    echo "btar exit classes (plan 2.1): 0-success=$exit_zero 1-warning=$exit_warn" \
         "2-fatal=$exit_fatal"
    echo "outside-root changes: $outside_events"
    if [ "$STRACE" = 1 ]; then
        echo "strace logs: $TMP/cases/*/strace.log"
    fi
    if [ "$failures" -gt 0 ]; then
        echo
        echo "failures:"
        printf '%s' "$failure_log" | sed 's/^/  - /'
        echo "RESULT: FAIL ($failures fixture(s))"
        echo "artifacts: $TMP"
        KEEP=1
        exit 1
    fi
    if [ "$KEEP" = 1 ]; then
        echo "artifacts: $TMP"
    fi
    echo "RESULT: PASS"
    exit 0
fi

# --------------------------------------------------------------------------- #
# No BTAR: validate fixtures and record GNU tar / bsdtar control behavior.
# --------------------------------------------------------------------------- #
for row in "${EVIL_ROWS[@]}"; do
    IFS=$'\x1f' read -r file sha policy btar_exit checks extra note \
        <<<"$row"
    name="${file#evil/}"
    name="${name%.tar}"
    fixture="$FIXTURES/$file"
    case_dir="$TMP/controls/$name"
    reasons=""
    gnu_rc=0
    gnu_p=0
    bsd_rc=0
    bsd_p=0
    gnu_outside="clean"
    bsd_outside="clean"
    gnu_prc="skip"
    bsd_prc="skip"
    gnu_pout="clean"
    bsd_pout="clean"

    if [ ! -f "$fixture" ]; then
        reasons="missing fixture"
    else
        actual_sha="$(sha256sum -- "$fixture" | cut -d' ' -f1)"
        if [ "$actual_sha" != "$sha" ]; then
            reasons="sha256 mismatch (run --regen)"
        fi
    fi

    if [ -z "$reasons" ]; then
        fixtures_ok=$((fixtures_ok + 1))
        for tool in gnu bsdtar; do
            tool_dir="$case_dir/$tool"
            prepare_sandbox "$tool_dir"
            snapshot_outside "$tool_dir/container" "$tool_dir/container/root" \
                "$tool_dir/before.snapshot"
            sentinel_digest "$tool_dir" >"$tool_dir/before.sentinel"
            bin="tar"
            [ "$tool" = gnu ] || bin="bsdtar"
            extract_control "$bin" "$fixture" "$tool_dir/container/root" \
                "$tool_dir/extract"
            rc="$LAST_RC"
            # Listing with -P is recorded but never extracted to the host.
            list_rc=0
            if [ "$tool" = gnu ]; then
                tar -tPf "$fixture" >/dev/null 2>"$tool_dir/list.err" || list_rc=$?
            else
                bsdtar -tPf "$fixture" >/dev/null 2>"$tool_dir/list.err" \
                    || list_rc=$?
            fi
            # Second control pass: extract with -P into its own sandbox to record
            # unsafe-mode behaviour. Skipped for absolute_path because its member
            # name is a fixed host path; the sandbox must never touch the host.
            p_rc="skip"
            p_outside="skipped"
            if [ "$name" != "absolute_path" ]; then
                p_base="$tool_dir/passP"
                prepare_sandbox "$p_base"
                snapshot_outside "$p_base/container" "$p_base/container/root" \
                    "$p_base/before.snapshot"
                sentinel_digest "$p_base" >"$p_base/before.sentinel"
                p_rc=0
                "$bin" -xPf "$fixture" -C "$p_base/container/root" \
                    >"$p_base/extract.out" 2>"$p_base/extract.err" || p_rc=$?
                snapshot_outside "$p_base/container" "$p_base/container/root" \
                    "$p_base/after.snapshot"
                sentinel_digest "$p_base" >"$p_base/after.sentinel"
                p_outside="clean"
                if ! diff -q "$p_base/before.snapshot" \
                    "$p_base/after.snapshot" >/dev/null 2>&1; then
                    p_outside="changed"
                fi
                if ! diff -q "$p_base/before.sentinel" \
                    "$p_base/after.sentinel" >/dev/null 2>&1; then
                    p_outside="sentinel-modified"
                fi
                if [ "$p_outside" != "clean" ]; then
                    p_escapes=$((p_escapes + 1))
                    warning_log+="$name: $tool -P control $p_outside"$'\n'
                fi
                p_runs=$((p_runs + 1))
            fi
            snapshot_outside "$tool_dir/container" "$tool_dir/container/root" \
                "$tool_dir/after.snapshot"
            sentinel_digest "$tool_dir" >"$tool_dir/after.sentinel"
            tool_outside="clean"
            if ! diff -q "$tool_dir/before.snapshot" "$tool_dir/after.snapshot" \
                >/dev/null 2>&1; then
                tool_outside="changed"
            fi
            if ! diff -q "$tool_dir/before.sentinel" "$tool_dir/after.sentinel" \
                >/dev/null 2>&1; then
                tool_outside="sentinel-modified"
            fi
            if [ "$tool_outside" != "clean" ]; then
                outside_events=$((outside_events + 1))
                warning_log+="$name: $tool control $tool_outside"$'\n'
            fi
            if [ "$tool" = gnu ]; then
                controls_gnu=$((controls_gnu + 1))
                gnu_rc="$rc"
                gnu_p="$list_rc"
                gnu_outside="$tool_outside"
                gnu_prc="$p_rc"
                gnu_pout="$p_outside"
            else
                controls_bsd=$((controls_bsd + 1))
                bsd_rc="$rc"
                bsd_p="$list_rc"
                bsd_outside="$tool_outside"
                bsd_prc="$p_rc"
                bsd_pout="$p_outside"
            fi
        done
        control_line="gnu rc=$gnu_rc bsdtar rc=$bsd_rc"
        if [ "$gnu_p" -ne 0 ] || [ "$bsd_p" -ne 0 ]; then
            control_line+=" (list -P: gnu=$gnu_p bsdtar=$bsd_p)"
        fi
        if [ "$gnu_outside" != "clean" ]; then
            control_line+=" gnu-outside=$gnu_outside"
        fi
        if [ "$bsd_outside" != "clean" ]; then
            control_line+=" bsdtar-outside=$bsd_outside"
        fi
        if [ "$gnu_prc" != "skip" ] || [ "$bsd_prc" != "skip" ]; then
            control_line+=" [-P: gnu=$gnu_prc bsdtar=$bsd_prc"
            if [ "$gnu_pout" != "clean" ] || [ "$bsd_pout" != "clean" ]; then
                control_line+=" outside:$gnu_pout/$bsd_pout"
            fi
            control_line+="]"
        else
            control_line+=" [-P: skipped]"
        fi
    else
        failures=$((failures + 1))
        failure_log+="$name: $reasons"$'\n'
        control_line="fixture invalid"
    fi

    printf '[%2d/%2d] CONTROL evil/%-34s %s btar=SKIP\n' \
        "$((fixtures_ok + failures))" "$total" "$name" "$control_line"
done

echo
echo "security summary (BTAR unset): fixtures $fixtures_ok/$total valid; " \
     "controls gnu=$controls_gnu bsdtar=$controls_bsd; " \
     "safe-mode outside-root changes: $outside_events; " \
     "-P controls: runs=$p_runs outside-root changes=$p_escapes; " \
     "BTAR checks: SKIP"
if [ "$outside_events" -gt 0 ]; then
    echo "control anomalies (recorded, sandbox contained):"
    printf '%s' "$warning_log" | sed 's/^/  - /'
fi
if [ "$failures" -gt 0 ]; then
    echo
    echo "failures:"
    printf '%s' "$failure_log" | sed 's/^/  - /'
    echo "RESULT: FAIL ($failures fixture(s))"
    echo "artifacts: $TMP"
    KEEP=1
    exit 1
fi
if [ "$KEEP" = 1 ]; then
    echo "artifacts: $TMP"
fi
echo "RESULT: PASS"
