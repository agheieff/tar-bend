#!/usr/bin/env bash
# test_exclude.sh — v1.2 --exclude / --exclude-from / -X / --no-recursion vs GNU tar.
#
#   A. matcher: one archive of ~90 hand-picked member names, ~110 patterns;
#      `btar -tf A --exclude=P` must print exactly what `tar -tf A --exclude=P` prints.
#   B. create: exclusions and --no-recursion over a real tree (plain, -C, ./ operands,
#      -z, -r, -u) compared as GNU-readable listings.
#   C. extract: --exclude with and without --strip-components; extracted trees equal.
#   D. pattern files: --exclude-from=F, --exclude-from F, -X F, blank/space handling.
#   E. errors: unreadable pattern file => exit 2.
#
# Usage: ./tools/test_exclude.sh [--keep]    (BTAR=/path/to/btar to override)
set -u
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE="$ROOT/tools/compare_tree.py"
BTAR="${BTAR:-$ROOT/build/btar}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
for tool in python3 tar gzip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "test_exclude: need $tool" >&2; exit 2; }
done
[ -x "$BTAR" ] || { echo "test_exclude: BTAR not executable: $BTAR" >&2; exit 2; }

umask 022
export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-exclude.XXXXXX")"
trap '[ "$KEEP" = 1 ] || rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2

pass=0; fail=0; failures=""
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); failures+="$1"$'\n'; printf '  FAIL %s\n' "$1"; }

# ---- A. matcher over member names -------------------------------------------
python3 - "$TMP/names.tar" <<'PY'
import io, sys, tarfile
names = """
a/ a/foo/ a/foo/b/ a/foo/b/c.txt a/foo.c a/x.o a/bar/ a/bar/foo.txt a/bar/foo/ a/bar/foo/q
a/z/foo/q a/z/ a/zfoo a/.hidden a/.hidden/x a/with space a/with space/in side a/star*name a/q?mark
a/[br]acket a/b/c/d/e/f.txt a/dir.d/ a/dir.d/f a/foo.o a/foo.o.bak a/Foo/ a/FOO a/foo-1 a/foo_2
./b/ ./b/foo ./b/bar.o ./c ./c/d ./c/d/foo ./c/dfoo foo foo/ foo/x foo.txt bar bar/foo x.o y.o/ y.o/z
dotted.name .dot .dot/file a.b.c a.b/c.d lonely/ trailing/slash/ deep/er/est/foo deep/er/est/bar
back\\slash a/ba\\ck x[1] x1 [x] x]y a-b a-b/c a--b ab/c/ä/ü ä ü/ä.txt tab\there
""".split()
with tarfile.open(sys.argv[1], "w", format=tarfile.GNU_FORMAT) as tf:
    for n in names:
        n = n.replace("\\t", "\t")
        ti = tarfile.TarInfo(n.rstrip("/") if n.endswith("/") else n)
        if n.endswith("/"):
            ti.type = tarfile.DIRTYPE; ti.name = n; ti.mode = 0o755
        else:
            ti.size = 0
        ti.mtime = 1577836800
        tf.addfile(ti, io.BytesIO(b""))
PY
patterns=(
 'foo' 'foo*' '*foo' '*foo*' 'fo?' 'f?o' '?oo' 'foo?' '*.o' '*.o*' 'a/foo' 'a/foo*' 'a/*' 'a/*/foo' '*/foo'
 '*/foo/*' 'foo/b' 'foo/b/c.txt' 'b' 'bar' 'bar/foo' 'a' 'a/' 'a/foo/' './b' './b/foo' './c' 'c' 'c/d' 'd/foo'
 '[fb]a*' '[!f]*' '[^f]*' 'a/[!f]*' 'a/[b-z]*' '[a-c]' '[a-c]*' '[]]' '[!]]*' 'x[1]' 'x\[1\]' 'x[[]1]' '[x]' '\[x\]'
 '[' 'a[' '[a' 'a/[' '[a-' '[a-]' '[-a]' '[z-a]' '[a-a]' 'x[1' '\*' 'star\*name' 'star*name' 'q\?mark' 'q?mark'
 'a\' '\a' '\\' 'back\\slash' 'with space' 'with*space' 'with?space' '* *' ' ' '' '.' '.*' '*.' '.hidden' '.hid*'
 '*' '**' '*/*' '*/*/*' '?' '??' '???' '?/?' 'a/?' 'a/??' 'lonely' 'lonely/' 'trailing' 'trailing/slash'
 'slash' 'Foo' 'FOO' '[F]oo' 'foo.o' 'foo.o.bak' 'foo-*' 'foo_?' 'a.b' 'a.b.c' 'a.b/c.d' 'dir.d' 'dir.*'
 'est' 'est/foo' 'er/est' 'deep' 'deep/*' 'deep/*/foo' '*/est/*' 'ä' 'ü*' '[ä]' 'tab*' 'a-b' 'a-*' 'a--b' 'a?b'
 '*bar' 'bar*' 'bar/*' '*/bar/*' '*z*' 'z*' '*/*/*/*/*' 'a/b/c' 'c/d/e/f' 'f.txt' '*.txt' '*.txt*'
)
echo "== A. matcher (${#patterns[@]} patterns) =="
for p in "${patterns[@]}"; do
    g="$(tar --quoting-style=literal -tf names.tar --exclude="$p" 2>&1)"; grc=$?
    b="$("$BTAR" -tf names.tar --exclude="$p" 2>&1)"; brc=$?
    if [ "$g" = "$b" ] && [ "$grc" = "$brc" ]; then ok; else
        bad "list --exclude='$p' (rc GNU=$grc btar=$brc)"
        diff <(printf '%s\n' "$g") <(printf '%s\n' "$b") | head -6 | sed 's/^/      /'
    fi
done
# separate-argument form and multiple patterns
g="$(tar --quoting-style=literal -tf names.tar --exclude foo --exclude '*.o' --exclude=a/bar 2>&1)"
b="$("$BTAR" -tf names.tar --exclude foo --exclude '*.o' --exclude=a/bar 2>&1)"
[ "$g" = "$b" ] && ok || bad "multiple --exclude (space form)"
echo "  matcher done: $pass ok, $fail failed"

# ---- tree for B/C ------------------------------------------------------------
mkdir -p src/t/foo/b src/t/bar src/t/z/foo src/t/sub src/t/.hid
echo 1 >src/t/foo/b/c.txt; echo 2 >src/t/bar/foo.txt; echo 3 >src/t/x.o; echo 4 >src/t/foo.c
echo 5 >src/t/z/foo/q; echo 6 >src/t/sub/keep.txt; echo 7 >src/t/sub/skip.zip; echo 8 >src/t/.hid/f
echo 9 >src/t/a.tmp; ln -s foo.c src/t/lnk; ln src/t/foo.c src/t/hard
find src -exec touch -h -d '2020-01-01 00:00:00' {} +
cmp_list() { # label gnu_archive ours_archive
    if tar -tf "$2" >g.l 2>/dev/null && tar -tf "$3" >b.l 2>/dev/null && cmp -s g.l b.l; then ok
    else bad "$1"; diff g.l b.l 2>&1 | head -6 | sed 's/^/      /'; fi
}

echo "== B. create =="
create_cases=(
 "--exclude=foo src/t" "--exclude=*.o --exclude=*.zip src/t" "--exclude=src/t/foo src/t" "--exclude=t/z src/t"
 "--exclude=foo/b src/t" "--exclude=.hid src/t" "--exclude=.* src/t" "--exclude=*.tmp --exclude=lnk src/t"
 "--exclude=src src/t" "--exclude=./src/t/foo ./src/t" "--exclude=t/foo ./src/t" "--exclude=foo -C src t"
 "--exclude=foo -C src/t ." "--exclude=. -C src/t ." "--exclude=*.zip -C src t" "--exclude=sub -C src ./t"
 "--exclude=foo.c src/t" "--exclude=hard src/t" "--exclude=foo* src/t" "--exclude=[fb]a* src/t"
 "--exclude=*/foo src/t" "--exclude=zip src/t" "--exclude=skip.zip src/t/sub src/t/foo"
 "--no-recursion src/t" "--no-recursion src/t src/t/foo" "--no-recursion -C src t" "--no-recursion -C src/t ."
 "--no-recursion -C src/t ./foo ./bar ./x.o" "--no-recursion --exclude=bar src/t/foo src/t/bar"
 "--exclude=foo --no-recursion src/t/foo src/t/sub" "--no-recursion src/t/x.o src/t/lnk"
)
for c in "${create_cases[@]}"; do
    # shellcheck disable=SC2086
    tar -cf g.tar --sort=name $c 2>/dev/null
    # shellcheck disable=SC2086
    "$BTAR" -cf b.tar --sort=name $c 2>b.err; rc=$?
    [ "$rc" -le 1 ] || { bad "create '$c' (btar rc=$rc: $(head -n1 b.err))"; continue; }
    cmp_list "create '$c'" g.tar b.tar
done
# options after the operands: GNU ignores them (warns); btar applies them everywhere. Documented.
# gzip create, then GNU lists it
"$BTAR" -czf b.tgz --sort=name --exclude=foo --exclude='*.o' src/t 2>/dev/null
tar -czf g.tgz --sort=name --exclude=foo --exclude='*.o' src/t 2>/dev/null
cmp_list "create -z with excludes" g.tgz b.tgz
# list a gzip archive with exclusions
g="$(tar -tzf g.tgz --exclude=sub 2>&1)"; b="$("$BTAR" -tzf g.tgz --exclude=sub 2>&1)"
[ "$g" = "$b" ] && ok || bad "list -z with exclude"
# -v prints only what is archived
"$BTAR" -cvf b.tar --sort=name --exclude=foo src/t >b.out 2>b.err
if ! grep -Fxq 'src/t/foo/' b.err b.out && grep -Fxq 'src/t/x.o' b.err b.out; then ok; else bad "verbose lists excluded entries"; fi

echo "== B2. append / update with exclusions =="
tar -cf g.tar --sort=name src/t/sub; cp g.tar b.tar
tar -rf g.tar --sort=name --exclude='*.o' --exclude=foo src/t
"$BTAR" -rf b.tar --sort=name --exclude='*.o' --exclude=foo src/t 2>/dev/null
cmp_list "append with excludes" g.tar b.tar
# update: archive written by one create (GNU -u misbehaves on archives that list a
# subtree before its parent directory, so the base archive is a plain create)
tar -cf g.tar --sort=name --exclude='*.o' --exclude=foo src/t; cp g.tar b.tar
touch -d '2024-01-01' src/t/sub/keep.txt src/t/bar/foo.txt src/t/x.o
tar -uf g.tar --sort=name --exclude='*.o' src/t
"$BTAR" -uf b.tar --sort=name --exclude='*.o' src/t 2>/dev/null
tar -tf g.tar | sort >g.l; tar -tf b.tar | sort >b.l
cmp -s g.l b.l && ok || { bad "update with excludes"; diff g.l b.l | head -6 | sed 's/^/      /'; }

echo "== C. extract =="
tar -cf full.tar -C src t
extract_cases=("--exclude=foo" "--exclude=*.o --exclude=*.zip" "--exclude=t/z" "--exclude=sub --exclude=bar"
 "--exclude=foo --strip-components=1" "--exclude=t --strip-components=1" "--exclude=.hid --exclude=lnk"
 "--exclude=hard --exclude=foo.c" "--exclude=t/foo/b" "--exclude=*"
 "--strip-components=1" "--strip-components=2" "--strip-components=1 --exclude=hard --exclude=foo.c")
n=0
for c in "${extract_cases[@]}"; do
    n=$((n + 1)); rm -rf xg xb; mkdir xg xb
    # shellcheck disable=SC2086
    tar -xf full.tar -C xg $c 2>/dev/null
    # shellcheck disable=SC2086
    "$BTAR" -xf full.tar -C xb $c 2>b.err; rc=$?
    grc=0; rm -rf xg2; mkdir xg2
    # shellcheck disable=SC2086
    tar -xf full.tar -C xg2 $c >/dev/null 2>&1 || grc=$?
    if [ "$rc" != "$grc" ]; then bad "extract '$c' (rc GNU=$grc btar=$rc: $(head -n1 b.err))"; continue; fi
    if python3 "$COMPARE" xg xb >cmp.out 2>&1; then ok; else bad "extract '$c' tree differs"; head -5 cmp.out | sed 's/^/      /'; fi
done
# listing with -v
g="$(tar --quoting-style=literal -tf full.tar --exclude=foo)"
b="$("$BTAR" -tvf full.tar --exclude=foo 2>&1)"
[ "$g" = "$b" ] && ok || bad "verbose list with exclude"

echo "== D. pattern files =="
printf 'foo\n*.o\n' >pf1
printf 'foo  \n\n  \n*.o\t\r\n' >pf2          # trailing blanks stripped, empty lines ignored
printf '*.zip\nsub/keep.txt' >pf3             # no final newline
printf ' x.o\nfoo.c \n' >pf4                  # leading blank is part of the pattern
for pf in pf1 pf2 pf3 pf4; do
    for form in "--exclude-from=$pf" "-X $pf" "--exclude-from $pf"; do
        # shellcheck disable=SC2086
        g="$(tar -tf full.tar $form 2>&1)"; b="$("$BTAR" -tf full.tar $form 2>&1)"
        [ "$g" = "$b" ] && ok || { bad "list $form"; diff <(echo "$g") <(echo "$b") | head -4 | sed 's/^/      /'; }
        # shellcheck disable=SC2086
        tar -cf g.tar --sort=name $form src/t 2>/dev/null
        # shellcheck disable=SC2086
        "$BTAR" -cf b.tar --sort=name $form src/t 2>/dev/null
        cmp_list "create $form" g.tar b.tar
    done
done
g="$(tar -tf full.tar --exclude-from=pf1 --exclude-from=pf3 --exclude=bar 2>&1)"
b="$("$BTAR" -tf full.tar --exclude-from=pf1 --exclude-from=pf3 --exclude=bar 2>&1)"
[ "$g" = "$b" ] && ok || bad "several pattern sources"

echo "== E. errors =="
"$BTAR" -tf full.tar --exclude-from=/nonexistent/patterns >/dev/null 2>e.err; rc=$?
[ "$rc" -eq 2 ] && ok || bad "missing pattern file: rc=$rc"
"$BTAR" -cf e.tar --exclude-from=/nonexistent/patterns src/t >/dev/null 2>e.err; rc=$?
[ "$rc" -eq 2 ] && [ ! -e e.tar ] && ok || bad "missing pattern file on create: rc=$rc"
"$BTAR" -tf full.tar --exclude='*.zip' >/dev/null 2>e.err; rc=$?
[ "$rc" -eq 0 ] && ok || bad "--exclude='*.zip' must not trigger -z (rc=$rc)"
"$BTAR" -tf full.tar --exclude='*.gz' --exclude='-rz' >/dev/null 2>e.err; rc=$?
[ "$rc" -eq 0 ] && ok || bad "exclusion patterns that look like options (rc=$rc)"

echo
echo "test_exclude: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    printf '%s' "$failures" >&2
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
