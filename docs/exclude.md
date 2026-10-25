# Exclusion — `--exclude`, `--exclude-from`, `-X`, `--no-recursion` (v1.2)

Supported in create (`-c`), append/update (`-r`/`-u`), list (`-t`) and extract (`-x`), plain or gzip.
Verified against GNU tar 1.35 by `tools/test_exclude.sh` (208 checks, incl. 129 pattern/name
list comparisons) and `tests/test_glob.bend` (unit table).

## Options

| Option | Meaning |
|---|---|
| `--exclude=PATTERN`, `--exclude PATTERN` | skip members/files matching PATTERN (repeatable) |
| `--exclude-from=FILE`, `--exclude-from FILE`, `-X FILE` | read patterns from FILE, one per line |
| `--no-recursion` | create/append/update: a directory operand is archived as a directory entry only |

Pattern files: split at `\n`; **trailing whitespace is stripped** (space, tab, `\r`, …), empty lines
are ignored, everything else is literal (there is no comment syntax; a line `#x` is a pattern).
Command-line patterns are used verbatim. Not supported: `-X` inside a bundle (`-cXf`), unambiguous
long-option abbreviations (`--excl=`), `--exclude-vcs`, `--exclude-caches*`, `--exclude-tag*`,
`--anchored`, `--no-anchored`, `--wildcards`, `--no-wildcards`, `--ignore-case`,
`--recursion`. Options may appear anywhere (GNU only applies `--exclude` to operands *after* it and
warns "has no effect" otherwise; btar applies every exclusion to the whole command line).

## Matching (GNU defaults)

A pattern is matched against the member name **as stored** (create: the archive name, e.g.
`src/t/foo` or `./foo`; the root operand `.` is matched as `.`; list/extract: the member name before
`--strip-components`), with trailing `/` removed. The name is excluded when the pattern matches

1. the whole name, or any suffix that follows a `/` (patterns are *not anchored*), and
2. either all of that candidate, or a leading part of it that ends before a `/`
   (`foo` excludes `a/foo`, `a/foo/b`, `a/foo/b/c`; it does not exclude `a/foo.c` or `a/bar/foo.txt`).

Wildcards are fnmatch-style with no `FNM_PATHNAME`/`FNM_PERIOD`: `*` and `?` and `[...]` also match
`/` and leading dots; case-sensitive; `\x` escapes `x` (also inside `[...]`); `[set]`, `[!set]`,
`[^set]`, ranges `[a-z]`, `]` first in a set is literal; an unterminated `[` is a literal. Not
supported: POSIX classes (`[[:alpha:]]`), `[=x=]`, `[.x.]`. A pattern with a trailing `/` never
matches (GNU: the name has no trailing slash). The matcher is the pure module `src/glob.bend`
(O(|pattern|·|name|) per candidate, one fuel-bounded loop, no backtracking explosion).

### Where exclusions apply

- **create/append/update**: checked before an entry is `stat`ed; an excluded directory is not
  descended into; an excluded operand is skipped entirely (`--exclude=a a` → empty archive).
  `-v` lists only what is archived.
- **list/extract**: checked per member after the header is parsed; an excluded member's payload
  is read past. An excluded hardlink *target* makes a later link to it fail at extraction with
  the same error GNU gives (`btar` stops at the first such error; GNU continues and exits 2).

## Related fixes shipped with 1.2.0

Found while building the exclusion tests (all pre-existing in 1.1.0, all covered by
`tools/test_exclude.sh` / `tools/test_append.sh` regression cases):

- `btar -xf a.tar --strip-components=1` printed the create usage and exited 2: the create-mode
  detector looked for a `c` in *any* option token (`--strip-components` contains one). Mode letters
  are now only taken from single-dash bundles.
- `--strip-components=N` on a regular file whose name is stripped away entirely skipped the data
  *without* its padding, desynchronising the stream (`checksum mismatch`, exit 2). Fixed.
- `--strip-components=N` was not applied to **hardlink targets** (`hardlink target: No such file or
  directory`). Link targets are stripped like member names now; an entirely stripped link entry is
  skipped (GNU behaviour).
- `-X`/`--exclude` patterns such as `*.zip` or `*.gz` must not look like `-z`: exclusion tokens are
  removed from argv before every other option scan.
