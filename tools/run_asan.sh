#!/usr/bin/env bash
# run_asan.sh — run the ASan/UBSan btar binary over the valid fixture corpus.
#
# Checks process health only (exit status + sanitizer report); listing/tree
# correctness stays with ./tools/run.sh list and tools/run_diff.sh. Extraction
# (-xf) is auto-detected, so this works on the M1 lister today and on the M2
# extractor without changes.
#
# Usage:
#   ./tools/run_asan.sh [--keep] [--regen] [--no-extract] [--timeout SECONDS]
#
#   --keep        keep the temporary logs/extraction dirs (always kept on failure)
#   --regen       regenerate fixtures first
#   --no-extract  skip the -xf phase even if the binary supports it
#   --timeout N   per-invocation timeout in seconds (default 20)
#
# Exit codes: 0 all runs clean, 1 sanitizer/crash/timeout/unexpected exit, 2 setup.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/build/btar_asan"
FIXTURES="$ROOT/fixtures/generated"
MANIFEST="$FIXTURES/manifest.json"
GEN="$ROOT/tools/gen_fixtures.py"

KEEP=0
REGEN=0
EXTRACT_FLAG=1
TIMEOUT=20
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --regen) REGEN=1; shift ;;
        --no-extract) EXTRACT_FLAG=0; shift ;;
        --timeout)
            [ "$#" -ge 2 ] || { echo "run_asan: --timeout needs a value" >&2; exit 2; }
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "run_asan: unknown argument: $1 (try --help)" >&2
            exit 2
            ;;
    esac
done
case "$TIMEOUT" in
    ''|*[!0-9]*) echo "run_asan: --timeout must be a positive integer" >&2; exit 2 ;;
esac
[ "$TIMEOUT" -ge 1 ] || { echo "run_asan: --timeout must be >= 1" >&2; exit 2; }

for tool in python3 timeout grep tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "run_asan: required tool not found: $tool" >&2
        exit 2
    }
done
[ -x "$BIN" ] || {
    echo "run_asan: missing $BIN; build it first with ./tools/build_asan.sh" >&2
    exit 2
}

if [ "$REGEN" = 1 ] || [ ! -f "$MANIFEST" ]; then
    echo "run_asan: generating fixtures ..."
    python3 "$GEN" >/dev/null
fi
[ -d "$FIXTURES/valid" ] || {
    echo "run_asan: no valid fixtures under $FIXTURES/valid" >&2
    exit 2
}

export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}"
export LC_ALL=C

SAN_RE='ERROR: AddressSanitizer|AddressSanitizer:DEADLYSIGNAL|'
SAN_RE+='SUMMARY: AddressSanitizer|SUMMARY: UndefinedBehaviorSanitizer|'
SAN_RE+='runtime error:|UndefinedBehaviorSanitizer'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-asan.XXXXXX")"
cleanup() { if [ "$KEEP" = 0 ]; then rm -rf -- "$TMP"; fi; }
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# Extraction support is a property of the current app, not of this harness:
# probe -xf on the simplest valid fixture. It returns rc=2 (usage) on the M1
# lister, so the extract phase is skipped instead of failing the gate.
# --------------------------------------------------------------------------- #
EXTRACT_STYLE="skip"
EXTRACT_SKIP_REASON=""
detect_extract() {
    local probe="$FIXTURES/valid/single_file.tar"
    [ -f "$probe" ] || { EXTRACT_SKIP_REASON="single_file.tar missing"; return 0; }
    local d_opt="$TMP/probe-C" d_cwd="$TMP/probe-cwd"
    mkdir -p "$d_opt" "$d_cwd"
    local rc=0
    timeout "$TIMEOUT" "$BIN" -xf "$probe" -C "$d_opt" \
        >"$TMP/probe-C.out" 2>"$TMP/probe-C.err" || rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$d_opt/hello.txt" ]; then
        EXTRACT_STYLE="argc"
        return 0
    fi
    rc=0
    ( cd "$d_cwd" && timeout "$TIMEOUT" "$BIN" -xf "$probe" ) \
        >"$TMP/probe-cwd.out" 2>"$TMP/probe-cwd.err" || rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$d_cwd/hello.txt" ]; then
        EXTRACT_STYLE="cwd"
        return 0
    fi
    EXTRACT_SKIP_REASON="-xf probe rc=$rc: $(head -n 1 "$TMP/probe-C.err" | cut -c1-120)"
}
if [ "$EXTRACT_FLAG" = 1 ]; then
    detect_extract
fi

classify() { # $1 rc, $2 stderr file -> "ok" | "sanitizer" | "timeout" | "signal N" | "exit N"
    local rc="$1" err="$2"
    if [ -f "$err" ] && grep -Eq "$SAN_RE" "$err"; then echo "sanitizer"; return; fi
    if [ "$rc" -eq 124 ]; then echo "timeout"; return; fi
    if [ "$rc" -gt 128 ]; then echo "signal $((rc - 128))"; return; fi
    if [ "$rc" -ne 0 ]; then echo "exit $rc"; return; fi
    echo ok
}

list_pass=0
list_fail=0
extract_pass=0
extract_fail=0
extract_total=0
failure_log=""
index=0
total=0
for fixture in "$FIXTURES"/valid/*.tar; do
    [ -e "$fixture" ] && total=$((total + 1))
done

echo "run_asan: binary=$BIN"
echo "run_asan: fixtures=$FIXTURES/valid ($total archives)"
echo "run_asan: ASAN_OPTIONS=$ASAN_OPTIONS UBSAN_OPTIONS=$UBSAN_OPTIONS timeout=${TIMEOUT}s"
if [ "$EXTRACT_STYLE" = skip ]; then
    echo "run_asan: extraction SKIP (M1 lister / -xf unsupported: $EXTRACT_SKIP_REASON)"
else
    echo "run_asan: extraction enabled (-xf style: $EXTRACT_STYLE)"
fi

add_failure() {
    failure_log+="$1: $2"$'\n'
    if [ -s "$3" ]; then
        failure_log+="    stderr: $(head -n 1 "$3" | tr -d '\n' | cut -c1-180)"$'\n'
    fi
}

for fixture in "$FIXTURES"/valid/*.tar; do
    [ -e "$fixture" ] || continue
    name="$(basename "$fixture" .tar)"
    work="$TMP/$name"
    mkdir -p "$work"
    index=$((index + 1))
    reasons=""
    list_status="-"
    extract_status="-"

    # --- list (-tf) ------------------------------------------------------
    list_rc=0
    timeout "$TIMEOUT" "$BIN" -tf "$fixture" >"$work/list.out" 2>"$work/list.err" \
        || list_rc=$?
    list_status="$(classify "$list_rc" "$work/list.err")"
    if [ "$list_status" = ok ]; then
        list_pass=$((list_pass + 1))
    else
        list_fail=$((list_fail + 1))
        reasons+="list=$list_status "
        add_failure "$name" "list $list_status (rc=$list_rc, log: $work/list.err)" \
            "$work/list.err"
    fi

    # --- extract (-xf) ---------------------------------------------------
    if [ "$EXTRACT_STYLE" != skip ]; then
        extract_total=$((extract_total + 1))
        mkdir -p "$work/extract"
        extract_rc=0
        if [ "$EXTRACT_STYLE" = argc ]; then
            timeout "$TIMEOUT" "$BIN" -xf "$fixture" -C "$work/extract" \
                >"$work/extract.out" 2>"$work/extract.err" || extract_rc=$?
        else
            ( cd "$work/extract" && timeout "$TIMEOUT" "$BIN" -xf "$fixture" ) \
                >"$work/extract.out" 2>"$work/extract.err" || extract_rc=$?
        fi
        extract_status="$(classify "$extract_rc" "$work/extract.err")"
        if [ "$extract_status" = ok ]; then
            extract_pass=$((extract_pass + 1))
        else
            extract_fail=$((extract_fail + 1))
            reasons+="extract=$extract_status "
            add_failure "$name" \
                "extract $extract_status (rc=$extract_rc, log: $work/extract.err)" \
                "$work/extract.err"
        fi
    fi

    printf '[%2d/%2d] %s %-28s list=%s extract=%s\n' \
        "$index" "$total" \
        "$([ -z "$reasons" ] && echo PASS || echo FAIL)" \
        "$name" "$list_status" "$extract_status"
done

# --- gzip: pipes + forked pumps + inline effects (list, extract, create) ------
gz_total=0
gz_pass=0
gz_fail=0
for gzf in "$FIXTURES"/gzip/valid/*.tar.gz; do
    [ -e "$gzf" ] || continue
    gname="gz-$(basename "$gzf" .tar.gz)"
    gwork="$TMP/$gname"
    mkdir -p "$gwork/extract" "$gwork/src"
    gz_total=$((gz_total + 1))
    g_reasons=""
    for step in list extract create; do
        g_rc=0
        case "$step" in
            list)
                timeout "$TIMEOUT" "$BIN" -tzf "$gzf" >"$gwork/list.out" 2>"$gwork/list.err" \
                    || g_rc=$?
                ;;
            extract)
                timeout "$TIMEOUT" "$BIN" -xzf "$gzf" -C "$gwork/extract" \
                    >"$gwork/extract.out" 2>"$gwork/extract.err" || g_rc=$?
                ;;
            create)
                timeout "$TIMEOUT" "$BIN" -czf "$gwork/out.tgz" -C "$gwork/extract" . \
                    >"$gwork/create.out" 2>"$gwork/create.err" || g_rc=$?
                ;;
        esac
        g_status="$(classify "$g_rc" "$gwork/$step.err")"
        # -czf exits 1 when the tree holds a skipped special file; any other nonzero is a failure
        if [ "$g_status" = "exit 1" ] && [ "$step" = create ]; then g_status=ok; fi
        if [ "$g_status" != ok ]; then
            g_reasons+="$step=$g_status "
            add_failure "$gname" "$step $g_status (rc=$g_rc, log: $gwork/$step.err)" \
                "$gwork/$step.err"
        fi
    done
    if [ -z "$g_reasons" ]; then gz_pass=$((gz_pass + 1)); else gz_fail=$((gz_fail + 1)); fi
    printf '[gz] %s %-28s\n' "$([ -z "$g_reasons" ] && echo PASS || echo FAIL)" "$gname"
done

# --- append / update: in-place rewrite, seek, truncate (exit 2 = refused is clean) --
ap_total=0
ap_pass=0
ap_fail=0
mkdir -p "$TMP/apsrc"
printf 'appended\n' >"$TMP/apsrc/new.txt"
touch -d '2033-01-01 00:00:00' "$TMP/apsrc/new.txt"
for fixture in "$FIXTURES"/valid/*.tar; do
    [ -e "$fixture" ] || continue
    aname="ap-$(basename "$fixture" .tar)"
    awork="$TMP/$aname"
    mkdir -p "$awork"
    ap_total=$((ap_total + 1))
    a_reasons=""
    cp "$fixture" "$awork/a.tar"
    for step in r u; do
        a_rc=0
        timeout "$TIMEOUT" "$BIN" "-${step}f" "$awork/a.tar" -C "$TMP/apsrc" new.txt \
            >"$awork/$step.out" 2>"$awork/$step.err" || a_rc=$?
        a_status="$(classify "$a_rc" "$awork/$step.err")"
        if [ "$a_status" = "exit 2" ]; then a_status=ok; fi
        if [ "$a_status" != ok ]; then
            a_reasons+="$step=$a_status "
            add_failure "$aname" "append -$step $a_status (rc=$a_rc, log: $awork/$step.err)" \
                "$awork/$step.err"
        fi
    done
    if [ -z "$a_reasons" ]; then ap_pass=$((ap_pass + 1)); else ap_fail=$((ap_fail + 1)); fi
    printf '[ap] %s %-28s\n' "$([ -z "$a_reasons" ] && echo PASS || echo FAIL)" "$aname"
done

echo
echo "run_asan: list   $list_pass/$total clean"
if [ "$EXTRACT_STYLE" = skip ]; then
    echo "run_asan: extract SKIP (M1 lister: -xf unsupported)"
else
    echo "run_asan: extract $extract_pass/$extract_total clean (-xf style: $EXTRACT_STYLE)"
fi
echo "run_asan: gzip   $gz_pass/$gz_total clean (list + extract + create)"
echo "run_asan: append $ap_pass/$ap_total clean (-rf + -uf)"
if [ $((list_fail + extract_fail + gz_fail + ap_fail)) -gt 0 ]; then
    echo
    echo "failures:"
    printf '%s' "$failure_log" | sed 's/^/  - /'
    echo "RESULT: FAIL ($((list_fail + extract_fail + gz_fail + ap_fail)) run(s))"
    echo "logs: $TMP"
    KEEP=1
    exit 1
fi
if [ "$KEEP" = 1 ]; then
    echo "logs: $TMP"
fi
echo "RESULT: PASS"
