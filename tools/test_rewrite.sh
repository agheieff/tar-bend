#!/usr/bin/env bash
# test_rewrite.sh — v1.3 --delete and -A/--concatenate vs GNU tar.
#
#   A. --delete: member sets, long (pax) names, directories, unmatched operands
#      (stderr + exit 2), listing and content equal to GNU's result.
#   B. -A: one/several sources, empty/missing destination, content equality.
#   C. refusals leave the archive byte-identical (gzip archive, bad source, '-').
#
# Usage: ./tools/test_rewrite.sh [--keep]    (BTAR=/path/to/btar to override)
set -u
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BTAR="${BTAR:-$ROOT/build/btar}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
for tool in python3 tar gzip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "test_rewrite: need $tool" >&2; exit 2; }
done
[ -x "$BTAR" ] || { echo "test_rewrite: BTAR not executable: $BTAR" >&2; exit 2; }

umask 022
export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-rewrite.XXXXXX")"
trap '[ "$KEEP" = 1 ] || rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2

pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

L="$(python3 -c "print('l'*120)")"; M="$(python3 -c "print('m'*120)")"
mkdir -p src/d/sub src/e "src/$L/$M"
echo a > src/a; echo bb > src/d/b; echo ccc > src/d/sub/c; echo e > src/e/f; echo ab > src/ab
python3 -c "print('x'*70000)" > src/big; echo q > "src/$L/$M/file"
(cd src && tar --sort=name -cf ../o.tar .)

same() { # archive archive  -> listing and content identical
    [ "$(tar -tf "$1")" = "$(tar -tf "$2")" ] \
        && [ "$(tar -xOf "$1" | md5sum)" = "$(tar -xOf "$2" | md5sum)" ]
}

# ---- A. --delete -------------------------------------------------------------
for ops in "./a" "./d" "./d/" "./d/sub" "./a ./ab ./big" "./nope" "./a ./nope" \
           "./e/f ./d/b" "./$L" "./$L/$M/file" "./ab ./a" "./big ./a"; do
    cp o.tar g.tar; cp o.tar b.tar
    # shellcheck disable=SC2086
    tar --delete -f g.tar $ops 2>g.err; gr=$?
    # shellcheck disable=SC2086
    "$BTAR" --delete -f b.tar $ops 2>b.err; br=$?
    sed -i 's/^btar:/tar:/' b.err
    if [ "$gr" = "$br" ] && diff -q g.err b.err >/dev/null && same g.tar b.tar; then ok
    else bad "delete [${ops:0:40}] gnu=$gr btar=$br"; fi
done
cp o.tar b.tar; "$BTAR" --delete -f b.tar >/dev/null 2>&1; cmp -s o.tar b.tar && ok || bad "delete no operands"
cp o.tar b.tar; "$BTAR" --delete -f b.tar ./nope 2>/dev/null; cmp -s o.tar b.tar && ok \
    || bad "delete unmatched leaves archive"
cp o.tar b.tar; "$BTAR" --delete -f b.tar ./a ./d ./e ./ab ./big "./$L" . >/dev/null 2>&1
[ "$(tar -tf b.tar | wc -l)" = 0 ] && ok || bad "delete everything"

# ---- B. -A -------------------------------------------------------------------
(cd src && tar -cf ../p1.tar a ab && tar -cf ../p2.tar big e && tar -cf ../p3.tar "$L")
# Expected result = the member lists/contents of the inputs, in order.  (GNU 1.35 drops
# the members of a later source when it holds pax long-name headers, so it is not the
# reference here; the single-source case is compared with GNU directly.)
for srcs in "p2.tar" "p2.tar p3.tar" "p3.tar p2.tar p2.tar"; do
    cp p1.tar b.tar
    # shellcheck disable=SC2086
    "$BTAR" -Af b.tar $srcs || { bad "concat [$srcs] rc"; continue; }
    want_t="$(for f in p1.tar $srcs; do tar -tf "$f"; done)"
    want_c="$(for f in p1.tar $srcs; do tar -xOf "$f"; done | md5sum)"
    [ "$want_t" = "$(tar -tf b.tar)" ] && [ "$want_c" = "$(tar -xOf b.tar | md5sum)" ] \
        && ok || bad "concat [$srcs]"
done
cp p1.tar g.tar; cp p1.tar b.tar; tar -Af g.tar p2.tar; "$BTAR" -Af b.tar p2.tar
same g.tar b.tar && ok || bad "concat vs GNU"
cp p1.tar b.tar; "$BTAR" --concatenate -f b.tar p2.tar && [ "$(tar -tf b.tar | wc -l)" = 5 ] \
    && ok || bad "--concatenate"
: > e.tar; "$BTAR" -Af e.tar p2.tar && same e.tar p2.tar && ok || bad "concat into empty"
cp p1.tar b.tar; "$BTAR" -Af b.tar p2.tar && "$BTAR" -rf b.tar src/a 2>/dev/null; tar -tf b.tar >/dev/null && ok \
    || bad "concat then append"

# ---- C. refusals ---------------------------------------------------------------
gzip -c p2.tar > p2.tgz; printf 'garbage' > junk.tar
cp p1.tar b.tar
"$BTAR" -Af b.tar p2.tgz >/dev/null 2>&1; [ $? = 2 ] && cmp -s p1.tar b.tar && ok || bad "gz source"
"$BTAR" -Af b.tar junk.tar >/dev/null 2>&1; [ $? = 2 ] && cmp -s p1.tar b.tar && ok || bad "junk source"
"$BTAR" -Af b.tar p2.tar nonexistent.tar >/dev/null 2>&1; [ $? = 2 ] && cmp -s p1.tar b.tar \
    && ok || bad "missing source"
"$BTAR" -Af - p2.tar >/dev/null 2>&1; [ $? = 2 ] && ok || bad "dash archive"
"$BTAR" --delete -zf b.tar ./a >/dev/null 2>&1; [ $? = 2 ] && cmp -s p1.tar b.tar && ok || bad "delete -z"
"$BTAR" -rA -f b.tar p2.tar >/dev/null 2>&1; [ $? = 2 ] && cmp -s p1.tar b.tar && ok || bad "-r with -A"

echo "test_rewrite: $pass passed, $fail failed"
[ "$fail" = 0 ]
