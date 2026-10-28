#!/usr/bin/env bash
# tests/run_tests.sh — M1 pure-core self-checks (Bend JS lane) + check-only gate.
set -u
cd "$(dirname "$0")/.."
export PATH="$PWD/.cache/toolchain/bin:$PATH"

fail=0
echo "== bend --check-only (pure modules)"
for f in src/*.bend; do
  case "$f" in
    src/read_stream.bend|src/extract.bend|src/write.bend|src/gzio.bend|src/append.bend|src/rewrite.bend) continue ;;  # effects: foreign defs, see compile gate
  esac
  if ! out=$(bend --check-only "$f" 2>&1); then
    echo "FAIL check-only: $f"; echo "$out" | tail -5; fail=1
  fi
done

echo "== effectful app compile gate (emit C)"
if ! out=$(bend app/main.bend -o build/btar.c 2>&1); then
  echo "FAIL compile: app/main.bend"; echo "$out" | tail -8; fail=1
else
  echo "OK app/main.bend -> build/btar.c"
fi

echo "== self-check tests (bend tests/x.bend, JS lane)"
for t in tests/test_*.bend; do
  printf '  %-22s ' "$(basename "$t")"
  if out=$(bend "$t" 2>&1); then
    echo "$out" | tail -1
  else
    echo "FAIL"; echo "$out" | tail -8; fail=1
  fi
done

echo "== M2 laws gate (bend proofs/PROOF.bend)"
if [ -f proofs/PROOF.bend ]; then
  if out=$(bend proofs/PROOF.bend 2>&1); then
    echo "$out" | tail -1
  else
    echo "FAIL proofs/PROOF.bend"; echo "$out" | tail -12; fail=1
  fi
fi

echo "== M3 heavy encoder proofs (L1/L4 concrete; excluded from --verdict)"
if [ -f proofs/PROOF_HEAVY.bend ]; then
  if out=$(bend proofs/PROOF_HEAVY.bend 2>&1); then
    echo "$out" | tail -1
  else
    echo "FAIL proofs/PROOF_HEAVY.bend"; echo "$out" | tail -12; fail=1
  fi
fi

echo "== gzip codec (self-check: inflate, gunzip chunking, deflate round trips)"
if ! out=$(bend tests/test_gzip.bend 2>&1); then
  echo "FAIL tests/test_gzip.bend"; echo "$out" | tail -10; fail=1
else
  echo "$out" | tail -1
fi

# Shared tests/lib.bend and canonical data modules have no main; not run.
if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
