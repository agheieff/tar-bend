#!/usr/bin/env bash
# test_options.sh — GNU option parity (v1.3): long listing (-tv), uname/gname on create,
# --owner/--group/--mode/--mtime/--numeric-owner, extraction overwrite policies
# (-k, --skip-old-files, --keep-newer-files, -m), option parsing (bundles, abbreviations,
# old-style first argument, refused options).  Reference: GNU tar 1.35.
set -u
set -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BTAR="${BTAR:-$ROOT/build/btar}"
[ -x "$BTAR" ] || { echo "test_options: BTAR not executable: $BTAR" >&2; exit 2; }
umask 022; export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-options.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

mkdir s; echo hi > s/f; mkdir s/d; chmod 640 s/f; chmod 750 s/d; ln -s f s/l; ln s/f s/h
head -c 123456 /dev/zero > s/big; chmod 4755 s/h; mkdir s/t; chmod 1777 s/t
printf x > "s/we ird
name"
ents() { python3 - "$1" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    for m in sorted(t.getmembers(), key=lambda m: m.name):
        print(m.name, oct(m.mode), m.uid, m.gid, m.uname, m.gname, m.mtime, m.type.decode(), m.linkname, sep="\t")
PY
}

# ---- listing ------------------------------------------------------------------------
tar -C s --sort=name -cf a.tar .
for o in "" "-v" "-vv" "--numeric-owner -v" "--utc -v" "--full-time -v"; do
    # shellcheck disable=SC2086
    [ "$(tar -tf a.tar $o 2>&1 | head -50)" = "$("$BTAR" -tf a.tar $o 2>&1 | head -50)" ] \
        && ok || bad "list [$o]"
done
tar -C s --sort=name -cf - . | "$BTAR" -tvf - | cmp -s - <(tar -tvf a.tar) && ok || bad "list -tv stdin"

# ---- create: names and overrides ------------------------------------------------------
for o in "" "--owner=0 --group=0" "--owner=root --group=root" "--owner=foo:1234 --group=bar:77"
do :; done
OPTS=("" "--owner=0 --group=0" "--owner=root --group=root" "--owner=foo:1234 --group=bar:77"
      "--numeric-owner" "--mode=a+r" "--mode=go-rwx" "--mode=0644" "--mode=u=rw,g=r,o="
      "--mode=u+rwX,go+rX" "--mode=a-x" "--mode=+t" "--mode=u+s,g+s" "--mode=a=rx"
      "--mtime=@1000000000" "--mtime=2020-01-02" "--mtime=2020-01-02T03:04:05"
      "--owner=0 --group=0 --numeric-owner --mtime=@0 --mode=u+rwX,go-w")
for o in "${OPTS[@]}"; do
    # shellcheck disable=SC2086
    tar -C s --sort=name -cf g.tar $o . 2>/dev/null; gr=$?
    # shellcheck disable=SC2086
    "$BTAR" -C s --sort=name -cf b.tar $o . 2>/dev/null; br=$?
    [ "$gr" = "$br" ] && [ "$(ents g.tar)" = "$(ents b.tar)" ] && ok || bad "create [$o]"
done
for bad_o in "--mode=g=u" "--mode=zz" "--owner=:" "--mtime=@x"; do
    "$BTAR" -C s -cf e.tar $bad_o . >/dev/null 2>&1; [ $? = 2 ] && ok || bad "invalid [$bad_o]"
done

# ---- extraction overwrite policies ---------------------------------------------------
mkdir o; echo new > o/f; echo new > o/g; ln -s f o/l; touch -d 2020-01-01 o/f
tar -C o -cf ow.tar f g l
setup() { rm -rf "$1"; mkdir "$1"; echo old > "$1/f"; echo old > "$1/g"
          touch -d 2030-01-01 "$1/g"; touch -d 2001-01-01 "$1/f"; ln -s /etc/passwd "$1/l"; }
state() { (cd "$1" && for f in f g; do echo "$f $(cat $f) $(stat -c %Y $f)"; done; readlink l); }
for o in "" "-k" "--keep-old-files" "--skip-old-files" "--keep-newer-files" "-m" "--touch"; do
    setup xg; setup xb
    # shellcheck disable=SC2086
    tar -xf ow.tar -C xg $o 2>g.err; gr=$?
    # shellcheck disable=SC2086
    "$BTAR" -xf ow.tar -C xb $o 2>b.err; br=$?
    sed -i 's/^btar:/tar:/' b.err
    # GNU quotes follow the locale (ASCII under LC_ALL=C); btar always prints typographic quotes
    python3 - b.err <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read().replace("\u2018", "'").replace("\u2019", "'")
open(p, "w", encoding="utf-8").write(t)
PY
    # -m: only the (unset) mtimes may differ from GNU by the extraction instant
    if [ "$o" = "-m" ] || [ "$o" = "--touch" ]; then
        [ "$gr" = "$br" ] && [ "$(state xg | grep -v '^[fg] ')" = "$(state xb | grep -v '^[fg] ')" ] \
            && [ "$(cat xb/f)" = new ] && ok || bad "extract [$o]"
    else
        [ "$gr" = "$br" ] && [ "$(state xg)" = "$(state xb)" ] && diff -q g.err b.err >/dev/null \
            && ok || { bad "extract [$o] gnu=$gr btar=$br"; diff g.err b.err; diff <(state xg) <(state xb); }
    fi
done

# ---- option parsing ---------------------------------------------------------------------
"$BTAR" cf p.tar -C s f && [ "$(tar -tf p.tar)" = f ] && ok || bad "old-style first argument"
"$BTAR" -cvf q.tar -C s f 2>/dev/null && ok || bad "bundle -cvf"
"$BTAR" -tf q.tar --list >/dev/null 2>&1; [ $? = 0 ] && ok || bad "repeated mode"
"$BTAR" --crea -f r.tar -C s f && ok || bad "long option prefix"
"$BTAR" --ex -tf q.tar >/dev/null 2>&1; [ $? = 2 ] && ok || bad "ambiguous prefix"
"$BTAR" -cf r.tar -C s -- f && ok || bad "double dash"
"$BTAR" --ignore-failed-read -cf r.tar f >/dev/null 2>&1; [ $? = 2 ] && ok || bad "refused option"
"$BTAR" -xf >/dev/null 2>&1; [ $? = 2 ] && ok || bad "missing -f argument"
"$BTAR" --version | grep -q '^btar ' && ok || bad "--version"
"$BTAR" --help | grep -q Usage && ok || bad "--help"

echo "test_options: $pass passed, $fail failed"
[ "$fail" = 0 ]
