#!/usr/bin/env bash
# build_asan.sh — build btar with AddressSanitizer + UndefinedBehaviorSanitizer.
#
# Emits the native C for app/main.bend with the pinned Bend compiler, applies the
# Stiff sanitizer ABI patch (ASan does not preserve its state across Bend's
# preserve_none work-loop attribute), then compiles an ASan/UBSan binary.
#
# Outputs (build/** is gitignored; build/btar is never touched):
#   build/btar.c            raw C emitted by Bend
#   build/btar.sanitized.c  patched copy (PRESERVE(preserve_none) stripped)
#   build/btar_asan         clang ASan+UBSan binary
#
# Usage:
#   ./tools/build_asan.sh                 # BEND/CC can be overridden from the env
#   BEND=/path/to/bend CC=clang ./tools/build_asan.sh
#
# Exit codes: 0 built, 1 build/ABI layout failure, 2 toolchain/setup problem.
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BEND="${BEND:-$ROOT/.cache/toolchain/bin/bend}"
CC="${CC:-clang}"
EXPECTED_BEND="bend 2.0.39"
SRC="$ROOT/app/main.bend"
BUILD="$ROOT/build"
RAW_C="$BUILD/btar.c"
PATCHED_C="$BUILD/btar.sanitized.c"
BIN="$BUILD/btar_asan"

die() { echo "build_asan: $*" >&2; exit 2; }
fail() { echo "build_asan: ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    -h|--help)
        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac

command -v "$BEND" >/dev/null 2>&1 || die \
    "Bend not found: $BEND (expected the project-local 2.0.39 toolchain)"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
command -v sed >/dev/null 2>&1 || die "sed not found"
[ -f "$SRC" ] || die "missing $SRC (app/main.bend not implemented yet?)"

bend_version="$("$BEND" version 2>/dev/null || true)"
[ "$bend_version" = "$EXPECTED_BEND" ] || die \
    "wrong Bend pin: expected '$EXPECTED_BEND', got '$bend_version'" \
    "(the effect ABI is compiler-coupled; use the project toolchain)"
cc_version="$("$CC" --version 2>/dev/null || true)"
cc_version="${cc_version%%$'\n'*}"
mkdir -p "$BUILD"
rm -f "$RAW_C" "$PATCHED_C" "$BIN.tmp"

echo "build_asan: $bend_version ($BEND)"
echo "build_asan: $cc_version"

# 1. Emit native C. BEND_NO_TELEMETRY keeps the build quiet/reproducible.
( cd "$ROOT" && BEND_NO_TELEMETRY=1 "$BEND" app/main.bend -o build/btar.c ) || \
    fail "bend C emission failed"
[ -s "$RAW_C" ] || fail "bend emitted no C ($RAW_C is empty)"

# 2. Assert the private effect ABI before touching the C, like Stiff does.
grep -qFx 'static void io_eff(u32 cid, Effect run) {' "$RAW_C" || fail \
    "ABI mismatch: missing 'static void io_eff(u32 cid, Effect run) {'" \
    "(Bend effect ABI changed; review the contract)"
grep -qFx 'typedef Term (*Effect)(Env e, Term* f, IoWork* w);' "$RAW_C" || fail \
    "ABI mismatch: missing 'typedef Term (*Effect)(Env e, Term* f, IoWork* w);'" \
    "(Bend effect ABI changed; review the contract)"

# 3. Assert the preserve_none layout, then strip the attribute.
#    Bend emits two textual uses (the WL_FN define and the WlFn typedef); ASan's
#    instrumentation state is not preserved across preserve_none entries, so the
#    work-loop trampolines must compile as ordinary functions. preserve_most on
#    OUTLINE helpers is kept. Update this patch only with a reviewed compiler bump.
uses="$(grep -oF 'PRESERVE(preserve_none)' "$RAW_C" | wc -l | tr -d ' ')" || uses=0
defines="$(grep -cFx '#define PRESERVE(A) __attribute__((A))' "$RAW_C" || true)"
[ "$uses" = 2 ] || fail \
    "unexpected preserve_none layout: found $uses uses, expected 2" \
    "(Bend emission changed; review the sanitizer patch before proceeding)"
[ "$defines" = 1 ] || fail \
    "unexpected PRESERVE definition: found $defines, expected exactly 1" \
    "of '#define PRESERVE(A) __attribute__((A))'"
sed 's/PRESERVE(preserve_none)//g' "$RAW_C" >"$PATCHED_C"
patched_uses="$(grep -oF 'PRESERVE(preserve_none)' "$PATCHED_C" | wc -l | tr -d ' ')" \
    || patched_uses=0
[ "$patched_uses" = 0 ] || fail "sanitizer patch left $patched_uses PRESERVE(preserve_none) use(s)"
cmp -s "$RAW_C" "$PATCHED_C" && fail "sanitizer patch did not change the C (layout changed?)"
echo "build_asan: ABI ok; preserve_none uses 2 -> 0 (PRESERVE define kept for preserve_most)"

# 4. Compile: -O1 -g so reports have frames, no-recover so UBSan aborts, frame
#    pointers for usable ASan stacks. -fbracket-depth guards deeply nested
#    generated match chains (Stiff-proven hardening on clang 19+).
# shellcheck disable=SC2086
"$CC" -std=c11 -fbracket-depth=1024 \
    -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
    -fno-omit-frame-pointer \
    "$PATCHED_C" -lpthread -lm -o "$BIN.tmp" || fail "clang ASan/UBSan build failed"
[ -s "$BIN.tmp" ] || fail "clang produced no binary"
mv "$BIN.tmp" "$BIN"

echo "build_asan: emitted build/btar.c ($(wc -c <"$RAW_C" | tr -d ' ') bytes)"
echo "build_asan: patched build/btar.sanitized.c ($(wc -c <"$PATCHED_C" | tr -d ' ') bytes)"
echo "build_asan: binary build/btar_asan ($(wc -c <"$BIN" | tr -d ' ') bytes)"
echo "build_asan: done (build/btar untouched)"
echo "next: ./tools/run_asan.sh"
echo "note: run_asan auto-detects -xf extraction once app/main.bend implements it"
