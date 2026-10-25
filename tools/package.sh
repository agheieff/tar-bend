#!/bin/sh
# Build the btar release artifacts (version from VERSION):
#   dist/btar                                  native binary
#   dist/btar-<ver>-linux-x64.tar.gz           binary package (+ README/LICENSE/man/VERSION)
#   dist/tar-bend-<ver>-src.tar.gz             source package (no .cache/build/fixtures/dist)
#   dist/SHA256SUMS
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BEND=${BEND:-$ROOT/.cache/toolchain/bin/bend}
VER=$(cat "$ROOT/VERSION")
OUT="$ROOT/dist"

[ -x "$BEND" ] || { echo "package: missing Bend toolchain at $BEND" >&2; exit 2; }
[ "$("$BEND" version)" = "bend 2.0.39" ] || {
  echo "package: Bend 2.0.39 required, got '$("$BEND" version)'" >&2; exit 2; }

mkdir -p "$OUT"
rm -f "$OUT"/btar "$OUT"/btar-*.tar.gz "$OUT"/tar-bend-*.tar.gz "$OUT"/SHA256SUMS

echo "package: building native btar (same path as the release gate)"
mkdir -p "$ROOT/build"
( cd "$ROOT" && "$BEND" app/main.bend -o build/btar )
cp "$ROOT/build/btar" "$OUT/btar"
[ -x "$OUT/btar" ] || { echo "package: build produced no binary" >&2; exit 1; }
[ "$("$OUT/btar" --version 2>&1)" = "btar $VER" ] || {
  echo "package: binary --version does not match VERSION ($VER)" >&2; exit 1; }

echo "package: binary package"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$OUT/btar" "$STAGE/btar"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/VERSION" "$STAGE/"
cp "$ROOT/docs/btar.1" "$STAGE/btar.1"
cp -R "$ROOT/docs" "$STAGE/docs"
mkdir -p "$STAGE/plan" "$STAGE/bench"
cp "$ROOT/plan/full-tar.md" "$STAGE/plan/"
cp "$ROOT/bench/RESULTS.md" "$STAGE/bench/"
chmod 755 "$STAGE/btar"
chmod 644 "$STAGE/README.md" "$STAGE/LICENSE" "$STAGE/VERSION" "$STAGE/btar.1"
find "$STAGE/docs" "$STAGE/plan" "$STAGE/bench" -type f -exec chmod 644 {} +
( cd "$STAGE" && tar --owner=0 --group=0 --numeric-owner -czf \
    "$OUT/btar-$VER-linux-x64.tar.gz" btar README.md LICENSE VERSION btar.1 docs plan bench )

echo "package: source package"
( cd "$ROOT" && tar --owner=0 --group=0 --numeric-owner \
    --exclude='./.cache' --exclude='./build' --exclude='./dist' \
    --exclude='./fixtures/generated' --exclude='./.git' --exclude='__pycache__' \
    -czf "$OUT/tar-bend-$VER-src.tar.gz" . )

echo "package: checksums"
( cd "$OUT" && sha256sum btar "$(basename "$OUT/btar-$VER-linux-x64.tar.gz")" \
    "$(basename "$OUT/tar-bend-$VER-src.tar.gz")" > SHA256SUMS )

ls -l "$OUT"
echo "package: done ($OUT)"
