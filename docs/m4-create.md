# M4 — create mode (`btar -cf`)

Status: **delivered**. `btar` can create archives from the filesystem:
`tools/test_create.sh` → **9/9 PASS, 0 fail, 0 skip**, `tools/run.sh test`
green (build + unit/proofs + create + list + diff + security + ASan + fuzz);
GNU tar and bsdtar read the archives, extraction round-trips tree/modes/
symlinks/hardlinks, and list/extract behavior from M2/M3 is unchanged
(diff 25/25, security 26/26).

## CLI

```
btar -cf ARCHIVE [-C DIR] [-v] [-p] [--format=ustar|pax] .
btar -c -f ARCHIVE -C DIR .          # separate flags
btar -cvf ARCHIVE -C DIR .           # bundled
btar --format=pax -cf ARCHIVE -C DIR .
```

- `-C DIR`: source base directory (relative to the current directory or
  absolute); the source operand is `"."` (v1: root-of-`-C` only; other
  operands exit 2 with a clear message).
- `-v`: entry names to stderr (raw bytes, ASCII-escaped when needed).
- `-p`: accepted (create stores `mode & 07777` in both modes, matching GNU
  tar's create behavior; the flag is meaningful for extract, not create).
- `--format=ustar`: any entry whose header does not fit ustar is fatal
  (exit 2); `--format=pax` and the default `auto` emit a POSIX pax `x` header
  + payload for long names/links/oversized uid/gid and a canonical ustar
  header after it.
- Exit codes: 0 success, 1 completed with warnings (unsupported source file
  types skipped), 2 fatal (usage, I/O, limits, ustar-only overflow).
- argv is byte-safe end-to-end (`IO.args_bytes`); archive/`-C` paths never
  round-trip through `String`. `-t/-x` behavior is untouched.

## Implementation

- `src/write.bend`:
  - **Phase A — collect** (`collect`, one fuel-bounded state machine): opens
    the `-C` base dirfd (`Fs.open_dir`), reads names (`Fs.readdir`), lstats
    each entry (`Fs.statx`), reads symlink targets (`Fs.readlinkat`), descends
    with `Fs.openat_dir` and closes dirs on ascent. It produces a pure
    `List<&1,Ent>` manifest in DFS/readdir order: name bytes, tar typeflag,
    mode/uid/gid/size/mtime, linkname. Directories get a trailing `/`;
    multiply-linked regular files record `(dev,ino)` in a flat U32 registry and
    later occurrences become typeflag `1` entries with the first name as target;
    fifos/devices/sockets become skip entries (phase B warns and sets exit 1).
  - **Phase B — write** (`write_all`, structural recursion over the manifest):
    per entry, `H.encode` the canonical ustar block; on failure (and format
    allows) emit a pax `x` header (`P.emit` records for path/linkpath/uid/gid,
    `P.pad_payload`, header size = unpadded record length) followed by the real
    ustar header with covered fields blanked. Regular-file payloads are copied
    with `Data.copy` from an `Fs.openat_read` source (parent dir opened from
    `-C` + dirname bytes), padded with `Stream.write_zeros`; directories,
    symlinks and hardlinks write headers only. The two 512-byte end blocks are
    written with `Stream.write_zeros`, then the archive fd is closed.
    `Lim` enforces member count/total/per-member/name limits. Verbose names go
    through stderr; warnings skip the entry and force exit 1.
- `effs/effects.bend`, `effs/fs.c`, `effs/fs.js` (+ declarations, ABI check ok):
  - `Fs.statx(dir,name)` → `[type, mode, nlink, uid, gid, size, mtime,
    ino_lo, ino_hi, dev_lo, dev_hi]` from lstat (type = `S_IFMT>>12`: 8 reg,
    4 dir, 10 link, 1 fifo, 2 chr, 6 blk, 12 sock; size past U32 fails
    EOVERFLOW — 4 GiB v1 cap).
  - `Fs.openat_read(dir,name)` → `O_RDONLY|O_NOFOLLOW|O_CLOEXEC` via
    `openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS` (openat fallback).
  - `Stream.write_zeros(fd,n)` → EINTR-safe bounded zero writes (padding and
    end blocks).
  Two real effect bugs were found and fixed while landing M4: `Fs.statx`
  aliased its name buffer with the output buffer, and `Fs.readdir`'s name list
  build dropped a byte for all but the last directory entry (helpers now parse
  names forward into an offset/length table).
- `app/main.bend`: create-mode parser (bundled `-cvf`/`-cpf`, separate
  `-c -f`, `-C`, `-v`, `-p`, `--format=`), byte-safe positional handling,
  `File.open_bytes(archive,"w")` opened before the walk (truncates) and closed
  after the end blocks. `-t/-x/-O/--one-top-level` paths unchanged.

## Evidence

```
bend app/main.bend -o build/btar                          # rc 0
BTAR=$PWD/build/btar ./tools/test_create.sh               # 9 pass, 0 fail, 0 skip
BTAR=$PWD/build/btar ./tools/run_diff.sh                  # 25/25, -p 1/1, -O 1/1
BTAR=$PWD/build/btar ./tools/run_security.sh              # 26/26, 0 outside-root
bash tests/run_tests.sh                                   # RESULT: PASS
./tools/run.sh test                                       # TEST GATE: ok
```

`tools/test_create.sh` validates, for default / separate-flags / absolute-C /
relative-C / verbose / permissions-p / format-pax / empty-tree / special-fifo
cases: GNU tar readability, normalised `tar -tvf` equality (type, perms incl
setuid, size, name, link target), GNU extraction + `tools/compare_tree.py`
(contents, modes, symlink targets, hardlink groups), and that a FIFO source is
skipped with a warning (exit 1) while the archive stays valid.

## Limitations (documented v1 scope)

- Source operand must be `.` under `-C DIR`; other operands exit 2
  (directories outside the base are rejected rather than half-supported).
- uid/gid are stored numerically; uname/gname are empty; device entries are
  skipped with a warning; sparse files are stored as regular files (no `S`
  extension); 4 GiB member/archive cap (U32); mtime is second-granularity.
- No archive-to-stdout (`-` operand), no `--exclude`/`--no-recursion` etc.
- Global pax headers are not emitted (no need for the writer's own archives);
  reading `g` headers stays M3-capable.
