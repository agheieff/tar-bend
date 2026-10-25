#!/usr/bin/env bash
# tests/list_fixtures.sh — differential listing harness for btar -tf.
#
# 1. effectful app compile gate: `bend app/main.bend -o build/btar.c` must pass.
# 2. If fixtures/generated/valid exists (tools/gen_fixtures.py), compare
#    `btar -tf` names against `tar -tf` (and bsdtar -tf when available).
#    Fixtures that GNU tar itself cannot list are SKIPped.
# 3. If fixtures are absent, print SKIP and exit 0.
set -u
cd "$(dirname "$0")/.."
export PATH="$PWD/.cache/toolchain/bin:$PATH"

BTAR_JS=(bend app/main.bend --)
NATIVE="${BTAR_NATIVE:-build/btar}"
FIXTURES="fixtures/generated/valid"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== effectful app compile gate (emit C)"
if ! bend app/main.bend -o build/btar.c >/dev/null 2>&1; then
  echo "FAIL: bend app/main.bend -o build/btar.c"
  exit 1
fi
echo "OK"

list_btar() { # $1 archive -> stdout
  if [ -n "$NATIVE" ]; then
    "$NATIVE" -tf "$1"
  else
    "${BTAR_JS[@]}" -tf "$1"
  fi
}

if [ ! -d "$FIXTURES" ]; then
  echo "SKIP: $FIXTURES absent (run tools/gen_fixtures.py first)"
  exit 0
fi

# Native avoids the JS lane's limited call stack (1 MiB fixtures overflow it).
if [ ! -x "$NATIVE" ]; then
  mkdir -p build
  echo "== building native $NATIVE"
  if ! bend app/main.bend -o "$NATIVE" >/dev/null 2>&1; then
    echo "SKIP: native build failed; JS lane cannot list large fixtures"
    NATIVE=""
  fi
fi

pass=0 fail=0 skip=0
for a in "$FIXTURES"/*.tar; do
  name=$(basename "$a")
  case "$name" in
    non_utf8_name.tar)
      # GNU tar escapes non-UTF-8 names; btar emits raw archive bytes. Compare
      # against the raw member bytes recovered from the archive with tarfile.
      if ! python3 - "$a" >"$TMP/exp_raw.txt" <<'PY'
import sys, tarfile
t = tarfile.open(sys.argv[1])
for m in t.getmembers():
    sys.stdout.buffer.write(m.name.encode("utf-8", "surrogateescape") + b"\n")
PY
      then
        echo "FAIL $name: cannot recover raw member names"; fail=$((fail + 1)); continue
      fi
      if ! list_btar "$a" >"$TMP/got.txt" 2>"$TMP/err.txt"; then
        echo "FAIL $name: btar exited non-zero"; sed -n '1,3p' "$TMP/err.txt"
        fail=$((fail + 1)); continue
      fi
      if ! cmp -s "$TMP/exp_raw.txt" "$TMP/got.txt"; then
        echo "FAIL $name: raw name bytes differ from archive"
        od -An -tx1 "$TMP/exp_raw.txt"; od -An -tx1 "$TMP/got.txt"
        fail=$((fail + 1)); continue
      fi
      pass=$((pass + 1)); continue ;;
  esac
  if ! list_btar "$a" >"$TMP/got.txt" 2>"$TMP/err.txt"; then
    echo "FAIL $name: btar exited non-zero"; sed -n '1,3p' "$TMP/err.txt"
    fail=$((fail + 1)); continue
  fi
  if ! tar -tf "$a" >"$TMP/exp.txt" 2>/dev/null; then
    echo "SKIP $name: GNU tar cannot list it either"
    skip=$((skip + 1)); continue
  fi
  if ! diff -q "$TMP/exp.txt" "$TMP/got.txt" >/dev/null; then
    echo "FAIL $name: name list differs from tar -tf"
    diff "$TMP/exp.txt" "$TMP/got.txt" | sed -n '1,6p'
    fail=$((fail + 1)); continue
  fi
  if command -v bsdtar >/dev/null 2>&1; then
    if bsdtar -tf "$a" >"$TMP/bsd.txt" 2>/dev/null &&
       ! diff -q "$TMP/bsd.txt" "$TMP/got.txt" >/dev/null; then
      echo "FAIL $name: name list differs from bsdtar -tf"
      diff "$TMP/bsd.txt" "$TMP/got.txt" | sed -n '1,6p'
      fail=$((fail + 1)); continue
    fi
  fi
  pass=$((pass + 1))
done

echo "== valid fixtures: pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
