#!/usr/bin/env bash
# test_diff.sh — `btar -d` (--diff/--compare) vs GNU tar: stdout, stderr and exit status for each
# kind of difference (contents, mtime, mode, uid via chown is skipped, symlink, hardlink,
# missing file, type change, size), plus -v, member operands and stdin archives.
set -u
set -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BTAR="${BTAR:-$ROOT/build/btar}"
[ -x "$BTAR" ] || { echo "test_diff: BTAR not executable: $BTAR" >&2; exit 2; }
umask 022; export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-diff.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

mkdir s; echo hi > s/f; mkdir s/d; ln -s f s/l; ln s/f s/h; echo x > s/g
head -c 300000 /dev/urandom > s/big
tar -C s --sort=name -cf a.tar .

run() { # label [extra args]
    local label="$1"; shift
    tar -df a.tar -C s "$@" >g.out 2>g.err; local gr=$?
    "$BTAR" -df a.tar -C s "$@" >b.out 2>b.err; local br=$?
    sed -i 's/^btar:/tar:/' b.err
    if [ "$gr" = "$br" ] && cmp -s g.out b.out && cmp -s g.err b.err; then ok
    else bad "$label (rc gnu=$gr btar=$br)"; diff g.out b.out | head -4; diff g.err b.err | head -4; fi
}

run unchanged
echo ho > s/f; run contents
touch -d 2001-01-01 s/f; run mtime
chmod 600 s/g; run mode
rm s/l; ln -s zz s/l; run symlink
rm s/h; ln -s q s/h; run hardlink
rm s/g; run missing
rm -r s/d; echo z > s/d; run type
head -c 10 /dev/zero >> s/f; run size
python3 - <<'PY'
d = open("s/big", "rb").read()
open("s/big", "wb").write(d[:200000] + bytes([d[200000] ^ 1]) + d[200001:])
PY
touch -r a.tar s/big; run bigcontents
run verbose -v
run operand ./f
run operand-missing ./nope
tar -cf - -C s . | "$BTAR" -df - -C s >/dev/null 2>&1; [ $? -le 1 ] && ok || bad "stdin archive"
gzip -c a.tar > a.tgz; tar -dzf a.tgz -C s >g.out 2>g.err; gr=$?
"$BTAR" -df a.tgz -C s >b.out 2>b.err; br=$?; sed -i 's/^btar:/tar:/' b.err
[ "$gr" = "$br" ] && cmp -s g.out b.out && cmp -s g.err b.err && ok || bad "gzip archive"

echo "test_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
