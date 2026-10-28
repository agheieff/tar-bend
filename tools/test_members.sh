#!/usr/bin/env bash
# test_members.sh — v1.3 member operands (-t/-x) and -T/--files-from vs GNU tar.
#
#   A. list: operands select the member and everything below it (dir/, trailing slashes).
#   B. extract: selected members only; trees equal GNU's.
#   C. -T / --files-from: create/append/list/extract, verbatim names (trailing blank kept).
#   D. errors: unreadable -T file => exit 2.
#
# Usage: ./tools/test_members.sh [--keep]    (BTAR=/path/to/btar to override)
set -u
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE="$ROOT/tools/compare_tree.py"
BTAR="${BTAR:-$ROOT/build/btar}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
for tool in python3 tar; do
    command -v "$tool" >/dev/null 2>&1 || { echo "test_members: need $tool" >&2; exit 2; }
done
[ -x "$BTAR" ] || { echo "test_members: BTAR not executable: $BTAR" >&2; exit 2; }

umask 022
export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-members.XXXXXX")"
trap '[ "$KEEP" = 1 ] || rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2

pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

mkdir -p src/d/sub src/e "src/sp"
echo a > src/a; echo b > src/d/b; echo c > src/d/sub/c; echo e > src/e/f
echo z > "src/sp/x y "; echo ab > src/ab
(cd src && tar --sort=name -cf ../g.tar .)

# ---- A. list ----------------------------------------------------------------
for ops in "./a" "./d" "./d/" "./d//" "./d/sub" "./d/sub/c" "./ab" "./a ./e" "./d ./d/b" \
           "./" "." "a" "./nope"; do
    # shellcheck disable=SC2086
    want="$(tar -tf g.tar $ops 2>/dev/null)"
    # shellcheck disable=SC2086
    got="$("$BTAR" -tf g.tar $ops 2>/dev/null)"
    [ "$want" = "$got" ] && ok || bad "list [$ops]"
done
want="$(tar -tf g.tar --exclude=sub ./d)"; got="$("$BTAR" -tf g.tar --exclude=sub ./d)"
[ "$want" = "$got" ] && ok || bad "list + exclude"
[ "$("$BTAR" -tf g.tar -v ./a | wc -l)" = 1 ] && ok || bad "list -v"

# ---- B. extract ---------------------------------------------------------------
for ops in "./a" "./d" "./d/sub" "./a ./e/f"; do
    rm -rf xg xb; mkdir xg xb
    # shellcheck disable=SC2086
    tar -xf g.tar -C xg $ops 2>/dev/null
    # shellcheck disable=SC2086
    "$BTAR" -xf g.tar -C xb $ops 2>/dev/null
    python3 "$COMPARE" xg xb >/dev/null && ok || bad "extract [$ops]"
done
rm -rf xg xb; mkdir xg xb
tar -xf g.tar -C xg --strip-components=1 ./d; "$BTAR" -xf g.tar -C xb --strip-components=1 ./d
python3 "$COMPARE" xg xb >/dev/null && ok || bad "extract strip + operand"

# ---- C. -T --------------------------------------------------------------------
printf 'a\nd/b\nsp/x y \n\nab\n' > list
for form in "-T ../list" "--files-from=../list" "--files-from ../list"; do
    rm -f tg.tar tb.tar
    # shellcheck disable=SC2086
    (cd src && tar --no-recursion -cf ../tg.tar $form)
    # shellcheck disable=SC2086
    (cd src && "$BTAR" --no-recursion -cf ../tb.tar $form)
    [ "$(tar -tf tg.tar | sed 's/$/|/')" = "$("$BTAR" -tf tb.tar | sed 's/$/|/')" ] \
        && [ "$(tar -tf tb.tar | wc -l)" = 4 ] && ok || bad "create [$form]"
done
printf 'a\nab\n' > l2
[ "$("$BTAR" -tf tb.tar -T l2)" = "$(tar -tf tb.tar -T l2)" ] && ok || bad "list -T"
rm -rf xg xb; mkdir xg xb
tar -xf tb.tar -C xg -T l2; "$BTAR" -xf tb.tar -C xb -T l2
[ -f xb/a ] && [ -f xb/ab ] && [ ! -e xb/d ] && python3 "$COMPARE" xg xb >/dev/null \
    && ok || bad "extract -T"
rm -f ap.tar; (cd src && tar -cf ../ap.tar a); (cd src && "$BTAR" -rf ../ap.tar -T ../l2)
[ "$(tar -tf ap.tar | tail -n 2)" = "$(printf 'a\nab')" ] && ok || bad "append -T"

# ---- D0. not-found operands ----------------------------------------------------
for ops in "./nope" "./a ./nope ./zz" "./d ./x"; do
    # shellcheck disable=SC2086
    want="$(tar -tf g.tar $ops 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    got="$("$BTAR" -tf g.tar $ops 2>&1 | sed 's/^btar:/tar:/'; echo "rc=${PIPESTATUS[0]}")"
    [ "$want" = "$got" ] && ok || bad "not found [$ops]"
done

# ---- D. errors ----------------------------------------------------------------
"$BTAR" -cf e.tar -T /nonexistent >/dev/null 2>&1; [ $? = 2 ] && ok || bad "missing -T file"

echo "test_members: $pass passed, $fail failed"
[ "$fail" = 0 ]
