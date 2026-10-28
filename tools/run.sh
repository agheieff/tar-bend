#!/bin/sh
# tar-bend gate runner. Usage: ./tools/run.sh [check|proofs|unit|fixtures|diff|security|build|test|all]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BEND=${BEND:-$ROOT/.cache/toolchain/bin/bend}
EXPECTED_VERSION="bend 2.0.39"

usage() {
  cat <<EOF
usage: tools/run.sh <command>
  check      bend --check-only on every .bend outside .cache/fixtures
  proofs     proofs/PROOF.bend gate (+ --verdict)
  unit       run tests/*.bend self-checks (JS lane)
  fixtures   generate fixtures if missing
  list       compare btar -tf vs tar -tf on valid fixtures (requires build/btar)
  create     create-mode differential harness (btar -cf vs GNU tar)
  gzip       gzip differential harness (auto-detect, -z, -czf, corrupt)
  append     append/update + exclude harnesses (btar vs GNU tar) + mutation fuzz
  diff       differential harness (baseline GNU/bsdtar; BTAR_DIFF=1 enables btar extraction)
  security   adversarial harness (baseline controls; BTAR_SECURITY=1 enables btar extraction)
  build      build ./btar from app/main.bend
  asan       build + run the ASan/UBSan binary and fuzz corpus
  test       check + proofs + unit + fixtures + build + list + diff + security + asan
EOF
}

version() {
  [ -x "$BEND" ] || { echo "missing Bend toolchain: $BEND" >&2; exit 2; }
  got=$("$BEND" version)
  [ "$got" = "$EXPECTED_VERSION" ] || {
    echo "wrong Bend version: expected '$EXPECTED_VERSION', got '$got'" >&2
    exit 2
  }
  echo "toolchain: $got ($BEND)"
}

bend_files() {
  find "$ROOT/src" "$ROOT/app" "$ROOT/tests" "$ROOT/proofs" -type f -name '*.bend' 2>/dev/null || true
}

check() {
  version
  for f in $(bend_files); do
    case "$f" in
      */src/read_stream.bend|*/src/extract.bend|*/src/write.bend|*/src/gzio.bend|*/src/append.bend|*/src/rewrite.bend|*/app/main.bend) continue ;; # effects
    esac
    echo "check $f"
    "$BEND" --check-only "$f" >/dev/null
  done
  echo "check effectful app (compile gate)"
  mkdir -p "$ROOT/build"
  ( cd "$ROOT" && "$BEND" app/main.bend -o build/btar.c >/dev/null )
  echo "check: ok"
}

proofs() {
  version
  if [ -f "$ROOT/proofs/PROOF.bend" ]; then
    ( cd "$ROOT" && "$BEND" proofs/PROOF.bend )
    ( cd "$ROOT" && "$BEND" proofs/PROOF.bend --verdict )
    if [ -f "$ROOT/proofs/PROOF_HEAVY.bend" ]; then
      # L1/L4 concrete canonical proofs; not in --verdict (BendTT out-of-fuel on
      # 512-byte block normalisation — documented in docs/proofs.md).
      ( cd "$ROOT" && "$BEND" proofs/PROOF_HEAVY.bend )
    fi
    echo "proofs: ok"
  else
    echo "proofs: SKIP (proofs/PROOF.bend not implemented yet)"
  fi
}

unit() {
  version
  found=0
  for f in "$ROOT"/tests/*.bend; do
    [ -e "$f" ] || continue
    found=1
    echo "run $f"
    "$BEND" "$f" >/dev/null
  done
  [ "$found" = 1 ] || { echo "unit: SKIP (no tests/*.bend yet)"; return 0; }
  echo "unit: ok"
}

fixtures() {
  if [ -f "$ROOT/fixtures/generated/manifest.json" ]; then
    echo "fixtures: present"
    return 0
  fi
  if [ -f "$ROOT/tools/gen_fixtures.py" ]; then
    python3 "$ROOT/tools/gen_fixtures.py"
  else
    echo "fixtures: SKIP (tools/gen_fixtures.py not implemented yet)"
  fi
}

BTAR_BIN="$ROOT/build/btar"

diff() {
  if [ -f "$ROOT/tools/run_diff.sh" ]; then
    # M2+: extraction is implemented. Disable with BTAR_DIFF=0 if needed.
    if [ "${BTAR_DIFF:-1}" = 1 ] && [ -x "$BTAR_BIN" ]; then
      BTAR="$BTAR_BIN" "$ROOT/tools/run_diff.sh"
    else
      "$ROOT/tools/run_diff.sh"
    fi
  else
    echo "diff: SKIP (tools/run_diff.sh not implemented yet)"
  fi
}

security() {
  if [ -f "$ROOT/tools/run_security.sh" ]; then
    if [ "${BTAR_SECURITY:-1}" = 1 ] && [ -x "$BTAR_BIN" ]; then
      BTAR="$BTAR_BIN" "$ROOT/tools/run_security.sh"
    else
      "$ROOT/tools/run_security.sh"
    fi
  else
    echo "security: SKIP (tools/run_security.sh not implemented yet)"
  fi
}

build() {
  version
  [ -f "$ROOT/app/main.bend" ] || { echo "build: SKIP (app/main.bend not implemented yet)"; return 0; }
  mkdir -p "$ROOT/build"
  ( cd "$ROOT" && "$BEND" app/main.bend -o build/btar )
  echo "build: $BTAR_BIN"
}

list() {
  [ -f "$ROOT/tests/list_fixtures.sh" ] || { echo "list: SKIP (no tests/list_fixtures.sh)"; return 0; }
  [ -d "$ROOT/fixtures/generated/valid" ] || { echo "list: SKIP (fixtures missing)"; return 0; }
  ( cd "$ROOT" && bash tests/list_fixtures.sh )
}

create() {
  if [ -f "$ROOT/tools/test_create.sh" ]; then
    BTAR="$BTAR_BIN" "$ROOT/tools/test_create.sh"
  else
    echo "create: SKIP (tools/test_create.sh not implemented yet)"
  fi
}

gzip_test() {
  if [ -f "$ROOT/tools/test_gzip.sh" ]; then
    BTAR="$BTAR_BIN" "$ROOT/tools/test_gzip.sh"
  else
    echo "gzip: SKIP (tools/test_gzip.sh not implemented yet)"
  fi
}

append_test() {
  if [ -f "$ROOT/tools/test_append.sh" ]; then
    BTAR="$BTAR_BIN" "$ROOT/tools/test_append.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_exclude.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_members.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_rewrite.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_transform.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_stdio.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_options.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_diff.sh"
    BTAR="$BTAR_BIN" "$ROOT/tools/test_select.sh"
    python3 "$ROOT/tools/fuzz_append.py" --bin "$BTAR_BIN" --iterations 300
  else
    echo "append: SKIP (tools/test_append.sh missing)"
  fi
}

asan() {
  if [ -f "$ROOT/tools/build_asan.sh" ] && [ -f "$ROOT/tools/run_asan.sh" ]; then
    "$ROOT/tools/build_asan.sh"
    "$ROOT/tools/run_asan.sh"
    if [ -f "$ROOT/tools/fuzz_headers.py" ]; then
      python3 "$ROOT/tools/fuzz_headers.py" --iterations 200 --deterministic
    fi
  else
    echo "asan: SKIP (tools/build_asan.sh or tools/run_asan.sh missing)"
  fi
}

cmd=${1:-test}
case "$cmd" in
  check) check ;;
  proofs) proofs ;;
  unit) unit ;;
  fixtures) fixtures ;;
  list) list ;;
  create) create ;;
  gzip) gzip_test ;;
  append) append_test ;;
  diff) diff ;;
  security) security ;;
  build) build ;;
  asan) asan ;;
  test)
    check
    proofs
    unit
    fixtures
    build
    list
    create
    gzip_test
    append_test
    diff
    security
    asan
    echo "TEST GATE: ok"
    ;;
  all) test ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
