#!/usr/bin/env bash
# test_select.sh — create-side selection vs GNU tar: --exclude-vcs, --exclude-backups,
# --newer-mtime / --newer / --after-date / -N (mtime only), --remove-files, and where -v
# prints (stdout, or stderr when the archive is stdout).
set -u
set -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BTAR="${BTAR:-$ROOT/build/btar}"
[ -x "$BTAR" ] || { echo "test_select: BTAR not executable: $BTAR" >&2; exit 2; }
umask 022; export LC_ALL=C
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tar-bend-select.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 2
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

same_list() { # label -- options...   (btar vs GNU member lists of a tree)
    local label="$1" want got; shift
    want="$(tar -C s --sort=name -cf - "$@" . 2>/dev/null | tar -tf -)"
    got="$("$BTAR" -C s --sort=name -cf - "$@" . 2>/dev/null | tar -tf -)"
    if [ "$want" = "$got" ]; then ok; else
        bad "$label"; printf '    GNU:  %s\n    btar: %s\n' "$(echo $want)" "$(echo $got)"
    fi
}

# ---- exclusion sets -----------------------------------------------------------------
mkdir s; cd s || exit 2
for n in .git .gitignore CVS '{arch}' keep 'a~' '#x#' '.#x' '%x' .hgsub .svn _darcs .bzr .bzrrules; do mkdir -p "$n"; done
echo x > .git/f; echo y > keep/y; echo z > 'keep/z~'; cd ..
same_list vcs --exclude-vcs
same_list backups --exclude-backups
same_list both --exclude-vcs --exclude-backups
same_list "vcs+pattern" --exclude-vcs --exclude='keep'

# ---- --newer family -------------------------------------------------------------------
rm -rf s; mkdir -p s/old s/new; echo a > s/old/a; echo b > s/new/b; echo c > s/c; ln -s c s/l
touch -d 2001-01-01 s/old/a s/old s/c s; touch -d 2030-01-01 s/new s/new/b
for o in "--newer-mtime=2010-01-01" "--newer-mtime=@1000000000" "--newer-mtime=@0" "--newer-mtime=2031-01-01"; do
    # shellcheck disable=SC2086
    same_list "$o" $o
done
# --newer / -N / --after-date also look at ctime in GNU; with fresh ctimes everything is newer
for o in "--newer=@1893456000" "-N @1893456000" "--after-date=@1893456000"; do
    # shellcheck disable=SC2086
    same_list "$o (future date)" $o
done

# ---- --remove-files ------------------------------------------------------------------
mk() { rm -rf "$1"; mkdir -p "$1/d/e"; echo a > "$1/f"; echo b > "$1/d/e/g"; ln -s f "$1/l"; }
mk rg; mk rb
tar -C rg -cf g.tar --remove-files .; "$BTAR" -C rb -cf b.tar --remove-files .
[ "$(tar -tf g.tar | sort)" = "$(tar -tf b.tar | sort)" ] && [ ! -e rb ] && [ ! -e rg ] && ok || bad "remove-files tree"
mk rg; mk rb
tar -C rg -cf g.tar --remove-files f d; "$BTAR" -C rb -cf b.tar --remove-files f d
[ "$(find rg | sort)" = "$(find rb | sort | sed 's/^rb/rg/')" ] && [ "$(tar -tf g.tar | sort)" = "$(tar -tf b.tar | sort)" ] \
    && ok || bad "remove-files operands"
mk rb; "$BTAR" -C rb -czf b.tgz --remove-files f d && [ ! -e rb/f ] && [ ! -e rb/d ] && [ -L rb/l ] && ok || bad "remove-files gzip"
mk rb; "$BTAR" -C rb -cf b.tar --remove-files nothing >/dev/null 2>&1; [ $? = 2 ] && [ -e rb/f ] && ok || bad "remove-files keeps files on error"

# ---- -v destination ---------------------------------------------------------------------
mk vs
[ "$(tar -C vs -cvf v.tar . 2>/dev/null | sort)" = "$("$BTAR" -C vs -cvf v2.tar . 2>/dev/null | sort)" ] && ok || bad "-cv names on stdout"
[ -z "$("$BTAR" -C vs -cvf - . 2>/dev/null >/dev/null; true)" ] && ok || bad "-cvf - leaves stdout for the archive"
"$BTAR" -C vs -cvf - . 2>v.err | tar -tf - >/dev/null && [ "$(sort v.err)" = "$(tar -tf v2.tar | sort)" ] && ok || bad "-cvf - names on stderr"

echo "test_select: $pass passed, $fail failed"
[ "$fail" = 0 ]
