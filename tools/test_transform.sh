#!/usr/bin/env bash
# test_transform.sh — v1.3 --transform / --xform vs GNU tar.
#
#   A. create: archive entries (name, type, link target) equal GNU's for a set of
#      expressions over a tree with files, dirs, a hardlink and a symlink.
#   B. extract: resulting trees equal GNU's (transform first, then --strip-components).
#   C. errors: invalid expressions exit 2 and write nothing.
#
# Usage: ./tools/test_transform.sh [--keep]    (BTAR=/path/to/btar to override)
set -u
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE="$ROOT/tools/compare_tree.py"
BTAR="${BTAR:-$ROOT/build/btar}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
for tool in python3 tar; do
    command -v "$tool" >/dev/null 2>&1 || { echo "test_transform: need $tool" >&2; exit 2; }
done
[ -x "$BTAR" ] || { echo "test_transform: BTAR not executable: $BTAR" >&2; exit 2; }

umask 022
export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-transform.XXXXXX")"
trap '[ "$KEEP" = 1 ] || rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2

pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

mkdir -p src/dir/sub src/other
echo a > src/a; echo b > src/dir/b; echo c > src/dir/sub/c.txt; echo o > src/other/o
ln src/a src/hl; ln -s a src/sl; ln -s dir/b src/sl2

# name<TAB>type<TAB>linkname, sorted
entries() {
    python3 - "$1" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    for m in sorted(t.getmembers(), key=lambda m: m.name):
        print(m.name, m.type.decode(), m.linkname, sep="\t")
PY
}

EXPRS=('s,^,pre/,' 's/a/X/g' 's/^dir\///' 's/b$/B/' 's/\(.\)\/\(.\)/\2\/\1/' 's/.*/Z/'
       's/d/D/i' 's/[0-9]\+/N/g' 's|/|::|g' 's/\.txt$/.md/' 's/sub/s&s/'
       's/c/&&/g' 's/.*\///' 's/^\(.\)\(.*\)$/\2\1/')

# (GNU 1.35 loops forever on `s/o*/-/g` for some names, so empty-match globs are covered only
# by tests/test_xform.bend against sed.)
# ---- A. create ----------------------------------------------------------------
for e in "${EXPRS[@]}"; do
    for ops in "." "a dir hl sl sl2 other"; do
        # shellcheck disable=SC2086
        tar -C src -cf g.tar --transform="$e" $ops 2>/dev/null; gr=$?
        # shellcheck disable=SC2086
        "$BTAR" -C src -cf b.tar --transform="$e" $ops 2>/dev/null; br=$?
        if [ "$gr" = "$br" ] && [ "$(entries g.tar 2>&1)" = "$(entries b.tar 2>&1)" ]; then ok
        else bad "create [$e] [$ops] gnu=$gr btar=$br"; fi
    done
done
# option spellings
for form in "--transform=s,a,X," "--xform=s,a,X," ; do
    tar -C src -cf g.tar "$form" a dir; "$BTAR" -C src -cf b.tar "$form" a dir
    [ "$(entries g.tar)" = "$(entries b.tar)" ] && ok || bad "spelling $form"
done
tar -C src -cf g.tar --transform 's,a,X,' a dir; "$BTAR" -C src -cf b.tar --transform 's,a,X,' a dir
[ "$(entries g.tar)" = "$(entries b.tar)" ] && ok || bad "separate argument"
tar -C src -cf g.tar --transform='s,a,X,' --transform='s,X,Y,g' a dir
"$BTAR" -C src -cf b.tar --transform='s,a,X,' --xform='s,X,Y,g' a dir
[ "$(entries g.tar)" = "$(entries b.tar)" ] && ok || bad "two expressions"
"$BTAR" -C src -cvf b.tar --transform='s,^,P/,' a 2>&1 | grep -qx 'P/a' && ok || bad "verbose name"

# ---- B. extract ---------------------------------------------------------------
tar -C src -cf all.tar .
for e in 's,^\./,,' 's/^\.\/dir/D/' 's/a/X/g' 's/sub\///' 's/\.txt$//' 's,^,pre/,'; do
    for strip in 0 1; do
        rm -rf xg xb; mkdir xg xb
        tar -xf all.tar -C xg --transform="$e" --strip-components=$strip 2>/dev/null
        "$BTAR" -xf all.tar -C xb --transform="$e" --strip-components=$strip 2>/dev/null
        python3 "$COMPARE" xg xb >/dev/null && ok || bad "extract [$e] strip=$strip"
    done
done

# ---- C. errors ----------------------------------------------------------------
for bad_e in 'x/a/b/' 's/a/b' 's/\(a/b/' 's/a\)/b/' 's/[a/b/' 's/a/b/z' 's/\(a\)\1/b/' 's/a\|b/c/' ''; do
    rm -f e.tar
    "$BTAR" -C src -cf e.tar --transform="$bad_e" a >/dev/null 2>&1; rc=$?
    [ "$rc" = 2 ] && [ ! -e e.tar ] && ok || bad "invalid [$bad_e] rc=$rc"
done

echo "test_transform: $pass passed, $fail failed"
[ "$fail" = 0 ]
