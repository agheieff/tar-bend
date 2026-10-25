#!/usr/bin/env bash
# ci.sh — CI entry point (also the local "run what CI runs" command).
#
#   1. checks the host tools the gate needs;
#   2. installs the pinned Bend 2.0.39 toolchain into .cache/toolchain (sha256-verified),
#      unless it is already there;
#   3. runs ./tools/test_release.sh (--quick on pull requests, full otherwise);
#   4. prints the artifact hash.
#
# Usage:
#   ./tools/ci.sh [--quick|--full] [--no-install]
#     --quick       skip ASan/fuzz, PROOF_HEAVY and the M6 aggregate (~2 min)
#     --full        the whole 17-section release gate (default)
#     --no-install  fail instead of downloading the toolchain
# Environment:
#   BEND_URL      override the download URL (mirror); the sha256 below is still enforced
#
# Exit codes: 0 gate PASS, 1 gate FAIL, 2 setup error (missing tool/toolchain).
set -eu
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BEND_VERSION="2.0.39"
BEND_SHA256="6cf462fd8f70b094a4950ebb709a9c4ffd8f1d1189d9cedf1fd63cd5d041c7ab"
BEND_URL="${BEND_URL:-https://github.com/bendlang/bend/releases/download/v${BEND_VERSION}/bend-${BEND_VERSION}-linux-x64.tar.gz}"
TOOLCHAIN="$ROOT/.cache/toolchain"

MODE=full
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --quick) MODE=quick ;;
        --full) MODE=full ;;
        --no-install) INSTALL=0 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ci: unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
    echo "ci: Linux x86-64 only (found $(uname -s) $(uname -m))" >&2; exit 2; }

missing=0
need() { command -v "$1" >/dev/null 2>&1 || { echo "ci: missing tool: $1 ($2)" >&2; missing=1; }; }
need clang "apt: clang | pacman: clang (>= 14)"
need tar "GNU tar 1.35 is the reference implementation"
need bsdtar "apt: libarchive-tools | pacman: libarchive"
need gzip "gzip"
need python3 "Python >= 3.11, stdlib only"
need sha256sum "coreutils"
need timeout "coreutils"
need file "apt: file"
tar --version 2>/dev/null | head -n 1 | grep -q 'GNU tar' || { echo "ci: 'tar' is not GNU tar" >&2; missing=1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null \
    || { echo "ci: python3 >= 3.11 required" >&2; missing=1; }
[ "$missing" = 0 ] || exit 2

bend_ok() { [ -x "$TOOLCHAIN/bin/bend" ] && [ "$("$TOOLCHAIN/bin/bend" version 2>/dev/null)" = "bend $BEND_VERSION" ]; }
if ! bend_ok; then
    [ "$INSTALL" = 1 ] || { echo "ci: pinned Bend $BEND_VERSION not found in $TOOLCHAIN (--no-install)" >&2; exit 2; }
    echo "ci: installing Bend $BEND_VERSION from $BEND_URL"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$tmp/bend.tar.gz" "$BEND_URL"
    elif command -v wget >/dev/null 2>&1; then wget -q -O "$tmp/bend.tar.gz" "$BEND_URL"
    else echo "ci: need curl or wget to download the toolchain" >&2; exit 2; fi
    got="$(sha256sum "$tmp/bend.tar.gz" | cut -d' ' -f1)"
    [ "$got" = "$BEND_SHA256" ] || { echo "ci: toolchain sha256 mismatch: $got" >&2; exit 2; }
    rm -rf "$TOOLCHAIN"; mkdir -p "$TOOLCHAIN"
    tar -xzf "$tmp/bend.tar.gz" -C "$TOOLCHAIN" --strip-components=1
    bend_ok || { echo "ci: installed toolchain does not report 'bend $BEND_VERSION'" >&2; exit 2; }
fi
export PATH="$TOOLCHAIN/bin:$PATH"
echo "ci: $(bend version), clang $(clang --version | head -n 1 | sed 's/.*version //;s/ .*//'), $(tar --version | head -n 1), bsdtar $(bsdtar --version | cut -d' ' -f2)"

cd "$ROOT"
rc=0
if [ "$MODE" = quick ]; then ./tools/test_release.sh --quick || rc=$?; else ./tools/test_release.sh || rc=$?; fi
if [ -x build/btar ]; then
    echo "ci: $(build/btar --version)  sha256=$(sha256sum build/btar | cut -d' ' -f1)"
fi
exit "$rc"
