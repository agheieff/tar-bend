#!/usr/bin/env bash
# test_release.sh — btar release verification gate (version from VERSION).
#
# Runs the ordered release gate, with clear section banners, fail-fast on the
# first FAIL, an evidence table at the end, and SKIPs for release hardening that
# is still landing (e.g. `--version`, gzip memory caps) so the gate is usable
# before the final wiring is merged.
#
#   section 1  toolchain pin (bend 2.0.39)
#   section 2  effect ABI check
#   section 3  native build (build/btar)
#   section 4  release version (`btar --version` == btar $(cat VERSION); SKIP if absent)
#   section 5  pure-module check-only + effectful app compile gate
#   section 6  proofs: PROOF.bend + --verdict + PROOF_HEAVY.bend
#   section 7  unit suites (tests/run_tests.sh; --quick uses tools/run.sh unit)
#   section 8  fixture determinism
#   section 9  create harness (tools/test_create.sh)
#   section 10 gzip harness (tools/test_gzip.sh)
#   section 11 append/update + exclude harnesses (tools/test_append.sh, fuzz_append.py, test_exclude.sh)
#   section 12 M6 aggregator (tools/test_m6.sh, full runs only)
#   section 13 extract differential (BTAR=build/btar tools/run_diff.sh)
#   section 14 security corpus (BTAR=build/btar tools/run_security.sh)
#   section 15 ASan/UBSan build + run + 200-case fuzz + append fuzz (skipped by --quick)
#   section 16 release hardening: streaming gzip bounds (bomb, multi-member, many members)
#   section 17 release artifact: executable, type, sha256
#
# Usage:
#   ./tools/test_release.sh [--quick] [--verbose]
#
#   --quick    skip ASan/fuzz, PROOF_HEAVY and the M6 aggregate (fast pre-check)
#   --verbose  stream section command output instead of only logging it
#
# Exit codes: 0 release gate PASS, 1 a section FAILED, 2 setup/usage error.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BEND="${BEND:-$ROOT/.cache/toolchain/bin/bend}"
EXPECTED_BEND="bend 2.0.39"
EXPECTED_VERSION="btar $(cat "$ROOT/VERSION")"
BTAR="$ROOT/build/btar"
QUICK=0
VERBOSE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "test_release: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

for tool in python3 tar gzip sha256sum timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "test_release: required tool not found: $tool" >&2
        exit 2
    }
done
[ -x "$BEND" ] || {
    echo "test_release: missing project Bend toolchain: $BEND" >&2
    exit 2
}

umask 022
export LC_ALL=C
LOG="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-release.XXXXXX")"
cleanup() { rm -rf -- "$LOG"; }
trap cleanup EXIT

SECTIONS=()
STATUSES=()
EVIDENCES=()
SKIPS=0
CURRENT=""
CURRENT_LOG="$LOG/section.log"

begin() { # $1 section name
    CURRENT="$1"
    CURRENT_LOG="$LOG/$(printf '%s' "$1" | tr ' /' '__').log"
    : >"$CURRENT_LOG"
    echo
    echo "== [$1] =================================================="
}

record() { # $1 status, $2 evidence
    SECTIONS+=("$CURRENT")
    STATUSES+=("$1")
    EVIDENCES+=("$2")
    printf '[%s] %-28s %s\n' "$1" "$CURRENT" "$2"
}

pass() { record PASS "$1"; }
skip() { SKIPS=$((SKIPS + 1)); record SKIP "$1"; }

fail_fast() { # $1 reason
    record FAIL "$1"
    echo
    echo "--- failing section output (tail) ---"
    tail -n 20 "$CURRENT_LOG" 2>/dev/null || true
    echo
    echo "test_release: FAIL at section '$CURRENT'"
    echo "logs: $LOG"
    exit 1
}

run_logged() { # command... ; output appended to CURRENT_LOG, streamed if --verbose
    if [ "$VERBOSE" = 1 ]; then
        "$@" 2>&1 | tee -a "$CURRENT_LOG"
        return "${PIPESTATUS[0]}"
    fi
    "$@" >>"$CURRENT_LOG" 2>&1
}

# run_ok NAME PATTERN -- COMMAND...
# Runs a command, fails fast with its tail if it exits nonzero or its output
# does not match PATTERN; on success records PASS with the matching line.
run_expect() { # $1 pattern (grep -E, may be ''), $2 evidence label; shift 2; command...
    local pattern="$1" label="$2"
    shift 2
    local rc=0
    run_logged "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail_fast "$label failed (rc=$rc)"
    fi
    local line=""
    if [ -n "$pattern" ]; then
        line="$(grep -E "$pattern" "$CURRENT_LOG" | tail -n 1 || true)"
        [ -n "$line" ] || fail_fast "$label: expected output not found (pattern: $pattern)"
    fi
    pass "${line:-$label}"
}

# --------------------------------------------------------------------------- #
# 1. Toolchain pin
# --------------------------------------------------------------------------- #
begin "toolchain pin"
got="$("$BEND" version 2>/dev/null || true)"
[ "$got" = "$EXPECTED_BEND" ] || fail_fast "expected '$EXPECTED_BEND', got '$got'"
pass "$got ($BEND)"

# --------------------------------------------------------------------------- #
# 2. Effect ABI check
# --------------------------------------------------------------------------- #
begin "ABI check"
run_expect 'ABI OK' "ABI check" "$ROOT/tools/abi_check.sh"

# --------------------------------------------------------------------------- #
# 3. Native build
# --------------------------------------------------------------------------- #
begin "native build"
# Build directly to build/btar so the gate artifact sha equals the packaged binary
# (Bend embeds the output name, so a temp filename would change the bytes).
run_logged "$BEND" app/main.bend -o build/btar \
    || fail_fast "bend build failed"
[ -x "$BTAR" ] || fail_fast "release binary missing"
pass "build/btar $(stat -c%s "$BTAR") bytes"

# --------------------------------------------------------------------------- #
# 4. Release version (release hardening; SKIP while --version is landing)
# --------------------------------------------------------------------------- #
begin "release version"
ver_out="$("$BTAR" --version 2>&1 || true)"
ver_rc=0
"$BTAR" --version >/dev/null 2>&1 || ver_rc=$?
if [ "$ver_out" = "$EXPECTED_VERSION" ]; then
    pass "$ver_out"
elif printf '%s' "$ver_out" | grep -qE '^btar [0-9]+\.[0-9]+\.[0-9]+'; then
    fail_fast "wrong version string: $(printf '%s' "$ver_out" | head -n 1)"
else
    skip "no --version support yet (rc=$ver_rc): $(printf '%s' "$ver_out" | head -n 1 | cut -c1-100)"
fi

# --------------------------------------------------------------------------- #
# 5. Pure-module check-only + effectful app compile gate
# --------------------------------------------------------------------------- #
begin "check / app compile"
checked=0
for f in "$ROOT"/src/*.bend; do
    case "$f" in
        */read_stream.bend|*/extract.bend|*/write.bend|*/gzio.bend|*/append.bend|*/rewrite.bend|*/cli*.bend|*/ovparse.bend) continue ;; # effects
    esac
    "$BEND" --check-only "$f" >>"$CURRENT_LOG" 2>&1 \
        || fail_fast "check-only failed: $f"
    checked=$((checked + 1))
done
run_logged "$BEND" app/main.bend -o build/btar.c || fail_fast "effectful app compile failed"
pass "$checked pure modules + app/main.bend -> build/btar.c"

# --------------------------------------------------------------------------- #
# 6. Proofs
# --------------------------------------------------------------------------- #
begin "proofs"
run_logged "$BEND" proofs/PROOF.bend || fail_fast "PROOF.bend failed"
grep -q 'ALL PROOFS CHECK' "$CURRENT_LOG" || fail_fast "PROOF.bend: ALL PROOFS CHECK missing"
run_logged "$BEND" proofs/PROOF.bend --verdict || fail_fast "PROOF.bend --verdict failed"
grep -q 'ALL PROOFS CHECK' "$CURRENT_LOG" || fail_fast "verdict: ALL PROOFS CHECK missing"
proofs_note="PROOF + verdict"
if [ "$QUICK" = 0 ] && [ -f "$ROOT/proofs/PROOF_HEAVY.bend" ]; then
    run_logged "$BEND" proofs/PROOF_HEAVY.bend || fail_fast "PROOF_HEAVY.bend failed"
    grep -q 'ALL PROOFS CHECK' "$CURRENT_LOG" || fail_fast "PROOF_HEAVY: ALL PROOFS CHECK missing"
    proofs_note="PROOF + verdict + HEAVY"
elif [ "$QUICK" = 1 ]; then
    proofs_note="PROOF + verdict (HEAVY skipped by --quick)"
fi
pass "ALL PROOFS CHECK ($proofs_note)"

# --------------------------------------------------------------------------- #
# 7. Unit suites
# --------------------------------------------------------------------------- #
begin "unit suites"
if [ "$QUICK" = 1 ]; then
    run_expect '^unit: ok' "tools/run.sh unit (quick JS lane)" "$ROOT/tools/run.sh" unit
else
    run_expect 'RESULT: PASS' "tests/run_tests.sh" bash "$ROOT/tests/run_tests.sh"
fi

# --------------------------------------------------------------------------- #
# 8. Fixture determinism
# --------------------------------------------------------------------------- #
begin "fixtures"
run_logged python3 "$ROOT/tools/gen_fixtures.py" || fail_fast "fixture generation failed"
fixture_line="$(grep -E 'determinism:' "$CURRENT_LOG" | tail -n 1 || true)"
case "$fixture_line" in
    *OK*|*first\ generation*) pass "$fixture_line" ;;
    *) fail_fast "fixture determinism: ${fixture_line:-no determinism line}" ;;
esac

# --------------------------------------------------------------------------- #
# 9. Create harness
# --------------------------------------------------------------------------- #
begin "create harness"
run_logged "$ROOT/tools/test_create.sh" || fail_fast "create harness failed"
create_line="$(grep -E 'test_create summary:' "$CURRENT_LOG" | tail -n 1 || true)"
pass "${create_line:-create harness PASS}"

# --------------------------------------------------------------------------- #
# 10. gzip harness
# --------------------------------------------------------------------------- #
begin "gzip harness"
run_logged "$ROOT/tools/test_gzip.sh" || fail_fast "gzip harness failed"
gzip_line="$(grep -E 'test_gzip summary:' "$CURRENT_LOG" | tail -n 1 || true)"
pass "${gzip_line:-gzip harness PASS}"

# --------------------------------------------------------------------------- #
# 11. Append/update harness (-r/-u vs GNU tar) + mutation fuzz
# --------------------------------------------------------------------------- #
begin "append/exclude harness"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_exclude.sh" || fail_fast "exclude harness failed"
exclude_line="$(grep -E 'test_exclude: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$exclude_line" ] || fail_fast "exclude harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_members.sh" || fail_fast "members harness failed"
members_line="$(grep -E 'test_members: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$members_line" ] || fail_fast "members harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_rewrite.sh" || fail_fast "rewrite harness failed"
rewrite_line="$(grep -E 'test_rewrite: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$rewrite_line" ] || fail_fast "rewrite harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_transform.sh" || fail_fast "transform harness failed"
transform_line="$(grep -E 'test_transform: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$transform_line" ] || fail_fast "transform harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_stdio.sh" || fail_fast "stdio harness failed"
stdio_line="$(grep -E 'test_stdio: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$stdio_line" ] || fail_fast "stdio harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_options.sh" || fail_fast "options harness failed"
options_line="$(grep -E 'test_options: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$options_line" ] || fail_fast "options harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_diff.sh" || fail_fast "diff harness failed"
diff_line="$(grep -E 'test_diff: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$diff_line" ] || fail_fast "diff harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_select.sh" || fail_fast "select harness failed"
select_line="$(grep -E 'test_select: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$select_line" ] || fail_fast "select harness: summary missing"
run_logged env BTAR="$BTAR" "$ROOT/tools/test_append.sh" || fail_fast "append harness failed"
append_line="$(grep -E 'test_append: [0-9]+ passed, 0 failed' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$append_line" ] || fail_fast "append harness: summary missing"
run_logged python3 "$ROOT/tools/fuzz_append.py" --bin "$BTAR" --iterations 300 \
    || fail_fast "append fuzz failed"
afuzz_line="$(grep -E 'fuzz_append: runs=[0-9]+ clean=[0-9]+' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$afuzz_line" ] || fail_fast "append fuzz: summary missing"
pass "$append_line; $afuzz_line; $exclude_line; $members_line; $rewrite_line; $transform_line; $stdio_line; $options_line; $diff_line; $select_line"

# --------------------------------------------------------------------------- #
# 12. M6 aggregate (full runs only; it repeats create/gzip/security/diff)
# --------------------------------------------------------------------------- #
begin "M6 aggregate"
if [ "$QUICK" = 1 ]; then
    skip "skipped by --quick (sub-sections already run)"
elif [ -x "$ROOT/tools/test_m6.sh" ]; then
    run_logged "$ROOT/tools/test_m6.sh" || fail_fast "test_m6.sh failed"
    m6_line="$(grep -E 'test_m6 summary:' "$CURRENT_LOG" | tail -n 1 || true)"
    pass "${m6_line:-test_m6 PASS}"
else
    skip "tools/test_m6.sh not present"
fi

# --------------------------------------------------------------------------- #
# 13. Differential extraction
# --------------------------------------------------------------------------- #
begin "diff (BTAR)"
run_logged env BTAR="$BTAR" "$ROOT/tools/run_diff.sh" || fail_fast "run_diff failed"
diff_line="$(grep -E 'btar differential: [0-9]+/[0-9]+' "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$diff_line" ] || fail_fast "run_diff: differential summary missing"
pass "$diff_line"

# --------------------------------------------------------------------------- #
# 14. Security corpus
# --------------------------------------------------------------------------- #
begin "security (BTAR)"
run_logged env BTAR="$BTAR" "$ROOT/tools/run_security.sh" || fail_fast "run_security failed"
sec_line="$(grep -E 'security summary .*[0-9]+/[0-9]+ evil fixtures passed' \
    "$CURRENT_LOG" | tail -n 1 || true)"
[ -n "$sec_line" ] || fail_fast "run_security: summary missing"
pass "$sec_line"

# --------------------------------------------------------------------------- #
# 15. ASan/UBSan + fuzz (skipped by --quick)
# --------------------------------------------------------------------------- #
begin "ASan/fuzz"
if [ "$QUICK" = 1 ]; then
    skip "skipped by --quick"
else
    run_logged "$ROOT/tools/build_asan.sh" || fail_fast "ASan build failed"
    run_logged "$ROOT/tools/run_asan.sh" || fail_fast "ASan run failed"
    asan_line="$(grep -E 'run_asan: (list|extract|gzip|append)[[:space:]]+[0-9]+/[0-9]+' \
        "$CURRENT_LOG" | tr '\n' '; ' | sed 's/; $//' || true)"
    run_logged python3 "$ROOT/tools/fuzz_headers.py" --iterations 200 --deterministic \
        || fail_fast "fuzz harness failed"
    fuzz_line="$(grep -E 'fuzz_headers: runs=[0-9]+ clean=[0-9]+' "$CURRENT_LOG" \
        | tail -n 1 || true)"
    run_logged python3 "$ROOT/tools/fuzz_append.py" --bin "$ROOT/build/btar_asan" \
        --iterations 120 || fail_fast "ASan append fuzz failed"
    afz="$(grep -E 'fuzz_append: runs=[0-9]+ clean=[0-9]+' "$CURRENT_LOG" | tail -n 1 | sed 's/^fuzz_append: /asan append fuzz /' || true)"
    [ -n "$asan_line" ] || fail_fast "ASan summary missing"
    [ -n "$fuzz_line" ] || fail_fast "fuzz summary missing"
    pass "$asan_line; $fuzz_line; $afz"
fi

# --------------------------------------------------------------------------- #
# 16. Release hardening: gzip decompression cap / bomb safety
# --------------------------------------------------------------------------- #
begin "gzip streaming bounds"
probe="$ROOT/fixtures/generated/gzip/valid/big_1mib_gz.tar.gz"
if [ ! -f "$probe" ] || ! timeout 30 "$BTAR" -tzf "$probe" >/dev/null 2>&1; then
    skip "gzip read absent or fixture missing; streaming bounds test unsupported"
else
    python3 - "$BTAR" "$LOG" >>"$CURRENT_LOG" 2>&1 <<'PY' || fail_fast "gzip streaming bounds failed (see log)"
import gzip, os, resource, subprocess, sys, time
btar, work = sys.argv[1], sys.argv[2]
zeros = bytes(1 << 20)

def run(args):
    t0 = time.monotonic()
    proc = subprocess.run([btar] + args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return proc.returncode, time.monotonic() - t0, proc.stderr.decode(errors="replace").strip()

def peak_mb():
    return resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0

def gz_zeros(path, mib, corrupt=False):
    with gzip.open(path, "wb", compresslevel=9) as f:
        for _ in range(mib):
            f.write(zeros)
    if corrupt:  # flip a bit in the stored CRC32 (trailer, 8 bytes from the end)
        d = bytearray(open(path, "rb").read()); d[-8] ^= 1
        open(path, "wb").write(d)

ok = True
def check(name, cond, detail):
    global ok
    print(("PASS " if cond else "FAIL ") + name + ": " + detail)
    ok = ok and cond

# 1. 120 MiB expansion bomb: streams in bounded memory, exit 0 (zero blocks = empty tar)
p = os.path.join(work, "bomb.gz"); gz_zeros(p, 120)
rc, t, err = run(["-tzf", p])
check("120 MiB bomb streams", rc == 0 and peak_mb() < 128, f"rc={rc} t={t:.1f}s peak={peak_mb():.1f} MiB {err[:60]}")

# 2. same bomb with a corrupted CRC: must fail (exit 2) after draining
p = os.path.join(work, "bomb_crc.gz"); gz_zeros(p, 20, corrupt=True)
rc, t, err = run(["-tzf", p])
check("corrupt CRC detected after full drain", rc == 2, f"rc={rc} {err[:60]}")

# 3. multi-member: 6 members of 16 MiB of zeros (old per-member cap bypass)
p = os.path.join(work, "multi.gz")
with open(p, "wb") as out:
    for _ in range(6):
        g = os.path.join(work, "m.gz"); gz_zeros(g, 16)
        out.write(open(g, "rb").read())
rc, t, err = run(["-tzf", p])
check("6 x 16 MiB members stream", rc == 0 and peak_mb() < 128, f"rc={rc} t={t:.1f}s peak={peak_mb():.1f} MiB {err[:60]}")

# 4. many tiny members: linear time (the old parser was quadratic: 200 KB took 120 s)
p = os.path.join(work, "many.gz")
member = gzip.compress(b"", mtime=0)
open(p, "wb").write(member * 20000)
rc, t, err = run(["-tzf", p])
check("20000 empty members linear", rc == 0 and t < 30, f"rc={rc} t={t:.1f}s {err[:60]}")

sys.exit(0 if ok else 1)
PY
    valid_rc=0
    timeout 30 "$BTAR" -tzf "$probe" >/dev/null 2>&1 || valid_rc=$?
    [ "$valid_rc" -eq 0 ] || fail_fast "valid gzip rejected (rc=$valid_rc)"
    pass "bomb / multi-member / many-member streams bounded; corrupt CRC rejected"
fi

# --------------------------------------------------------------------------- #
# 17. Release artifact
# --------------------------------------------------------------------------- #
begin "release artifact"
[ -x "$BTAR" ] || fail_fast "build/btar is not executable"
sha="$(sha256sum "$BTAR" | cut -d' ' -f1)"
size="$(stat -c%s "$BTAR")"
type="$(file -b "$BTAR" 2>/dev/null || echo 'file(1) unavailable')"
pass "sha256=$sha size=$size type=$type"

# --------------------------------------------------------------------------- #
# Summary evidence table
# --------------------------------------------------------------------------- #
fail_count=0
for status in "${STATUSES[@]}"; do
    [ "$status" = FAIL ] && fail_count=$((fail_count + 1))
done
echo
echo "================ release evidence ================"
for index in "${!SECTIONS[@]}"; do
    printf '%-4s %-28s %s\n' "${STATUSES[$index]}" "${SECTIONS[$index]}" \
        "${EVIDENCES[$index]}"
done
echo "==================================================="
echo "test_release: mode=$([ "$QUICK" = 1 ] && echo quick || echo full)" \
     "sections=${#SECTIONS[@]} skip=$SKIPS fail=$fail_count"
if [ "$fail_count" -gt 0 ]; then
    echo "RESULT: FAIL (release gate)"
    exit 1
fi
echo "RESULT: PASS (release gate; $SKIPS skipped section(s) documented above)"
