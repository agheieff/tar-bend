#!/usr/bin/env bash
# test_stdio.sh — `-f -` (stdin/stdout archives) vs GNU tar: plain and gzip, list/extract/create,
# pipes in both directions, empty and garbage input, -r/-u/-A/--delete refusals.
set -u
set -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BTAR="${BTAR:-$ROOT/build/btar}"
COMPARE="$ROOT/tools/compare_tree.py"
[ -x "$BTAR" ] || { echo "test_stdio: BTAR not executable: $BTAR" >&2; exit 2; }
umask 022; export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-stdio.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

mkdir -p src/d; echo a > src/a; echo b > src/d/b; head -c 3000000 /dev/urandom > src/big
tar -C src --sort=name -cf g.tar .; tar -C src --sort=name -czf g.tgz .

[ "$("$BTAR" -tf - < g.tar)" = "$(tar -tf g.tar)" ] && ok || bad "list stdin"
[ "$(cat g.tar | "$BTAR" -tf -)" = "$(tar -tf g.tar)" ] && ok || bad "list pipe"
[ "$(cat g.tgz | "$BTAR" -tf -)" = "$(tar -tf g.tar)" ] && ok || bad "list gzip pipe"
[ "$(cat g.tgz | "$BTAR" -tzf -)" = "$(tar -tf g.tar)" ] && ok || bad "list -z pipe"
[ "$(cat g.tgz | "$BTAR" -tf /dev/stdin)" = "$(tar -tf g.tar)" ] && ok || bad "list /dev/stdin"
for src in g.tar g.tgz; do
    rm -rf x; mkdir x; cat $src | "$BTAR" -xf - -C x && python3 "$COMPARE" src x >/dev/null \
        && ok || bad "extract pipe $src"
done
rm -rf x; mkdir x; "$BTAR" -xf - -C x < g.tar && python3 "$COMPARE" src x >/dev/null && ok || bad "extract stdin file"
"$BTAR" -C src --sort=name -cf - . | tar -tf - | cmp -s - <(tar -tf g.tar) && ok || bad "create stdout"
"$BTAR" -C src --sort=name -czf - . | tar -tzf - | cmp -s - <(tar -tf g.tar) && ok || bad "create gzip stdout"
"$BTAR" -C src --sort=name -cf - . | "$BTAR" -tf - | cmp -s - <(tar -tf g.tar) && ok || bad "btar | btar"
rm -rf x; mkdir x; "$BTAR" -C src -czf - . | "$BTAR" -xf - -C x && python3 "$COMPARE" src x >/dev/null \
    && ok || bad "btar gz | btar"
"$BTAR" -tf - < g.tar | head -1 | grep -q . && ok || bad "early reader exit"
: | "$BTAR" -tf - >/dev/null 2>&1; [ $? = 0 ] && ok || bad "empty stdin"
head -c 100 /dev/urandom | "$BTAR" -tf - >/dev/null 2>&1; [ $? = 2 ] && ok || bad "garbage stdin"
head -c 300 g.tar | "$BTAR" -tf - >/dev/null 2>&1; [ $? = 2 ] && ok || bad "truncated stdin"
for m in "-rf" "-uf" "-Af" "--delete -f"; do
    # shellcheck disable=SC2086
    "$BTAR" $m - src/a >/dev/null 2>&1 < /dev/null; [ $? = 2 ] && ok || bad "refuse $m -"
done
echo "test_stdio: $pass passed, $fail failed"
[ "$fail" = 0 ]
