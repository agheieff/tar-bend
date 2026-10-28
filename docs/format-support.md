# Format support (btar 1.3.0)

## Read

| Format / feature | Status | Notes |
|---|---|---|
| v7 headers | yes | magic absent; checksum validation |
| POSIX ustar | yes | `ustar\0`+`00`; name/prefix join; checksum |
| POSIX pax per-file `x` | yes | path, linkpath, size, mtime, uid, gid, uname, gname; unknown keys ignored |
| POSIX pax global `g` | yes | uid/gid/uname/gname/mtime applied to following entries with per-file precedence; global path/linkpath ignored |
| GNU longname `L`, longlink `K` | yes | payload blocks, NUL-trimmed |
| GNU base-256 numerics | yes | positive values with overflow → error; negative rejected |
| GNU sparse `S` | refused | list/extract error (fatal) |
| GNU dumpdir `D`, multi-volume `M`, volume label `V` | refused/skipped | fatal or warning per type |
| char/block/FIFO/socket entries | listed; extraction refused | warning + exit 1 |
| gzip (GNU gzip) | yes | stored/fixed/dynamic Huffman, LZ77, multi-member; streamed, no size caps |
| Concatenated archives | no | not part of v1 scope |

## Write

| Feature | Status | Notes |
|---|---|---|
| ustar | yes | when `H.fits` |
| POSIX pax headers | yes | emitted only when a header does not fit (long path/link, oversized numeric field) |
| GNU longname/longlink output | no | pax preferred |
| regular files | yes | payload copied byte-exactly via the data-plane effect |
| directories | yes | trailing `/`, root `./` metadata from the opened dir handle |
| symlinks | yes | target bytes recorded |
| hardlinks | yes | `(dev,ino)` registry; cross-directory targets; first occurrence stored as data |
| char/block/FIFO/socket | skipped | warning + exit 1, archive remains valid |
| sparse files | stored as regular data | no sparse mapping |
| uid/gid | numeric | uname/gname empty |
| mtime | second granularity | nanosecond part not represented by v1 header writer |
| > 4 GiB member/archive | refused | U32 representation; clear error |
| gzip output | yes | gzip header + DEFLATE (hash-chain LZ77, dynamic/fixed/stored blocks, parallel 128 KiB segments) + CRC-32/ISIZE |
| deterministic output | with `--sort=name` | raw-name sort per directory; default readdir order |

## Modes and selection (v1.2)

| Feature | Status | Notes |
|---|---|---|
| `-r` / `--append` | yes | uncompressed archives; creates a missing archive; existing bytes preserved; GNU-readable result ([append-update.md](append-update.md)) |
| `-u` / `--update` | yes | newer-than by whole-second mtime, new names, type changes; archived directories never re-added; appended order differs from GNU |
| `-r`/`-u` with `-z`, compressed archive, `-`, `-c/-t/-x/-O`, both `-r -u` | refused | exit 2, archive untouched |
| append to archives with sparse/dumpdir/multi-volume entries | refused | "unsupported tar entry type" |
| append to hardlinks of old members | stored as regular files | links are recorded only within the appended set (same as GNU) |
| `--exclude=P`, `--exclude P` | yes | create/append/update/list/extract; GNU default semantics: unanchored, wildcards match `/`, leading-directory match ([exclude.md](exclude.md)) |
| `--exclude-from=F`, `--exclude-from F`, `-X F` | yes | one pattern per line, trailing whitespace stripped, empty lines ignored |
| `--no-recursion` | yes | create/append/update |
| glob classes `[[:alpha:]]`, `[=x=]`, `[.x.]` | no | literal bracket handling only |
| member operands `-t/-x ARCHIVE NAME...` | yes | literal, anchored; selects the member and everything below it; trailing `/` ignored; unmatched operands print `Not found in archive` and exit 2 (same text as GNU) |
| `-T FILE`, `--files-from=FILE`, `--files-from FILE` | yes | create/append/update/list/extract; one name per line, names verbatim (no trimming), blank lines skipped; appended after command-line operands; not accepted in a bundle (`-cTf`); no `-T -`, `--null`, `-` option lines |
| `--delete -f ARCH NAME...` | yes | uncompressed archives, in place ([rewrite.md](rewrite.md)) |
| `-A` / `--concatenate -f DEST SRC...` | yes | uncompressed archives, in place ([rewrite.md](rewrite.md)) |
| `--transform=EXPR`, `--xform=EXPR` (also as separate argument; repeatable) | yes | create/append/update and extract; `s/RE/REPL/[gi]` ([transform.md](transform.md)) |
| `--exclude-vcs/-caches/-tag`, `--anchored`, `--wildcards`, `--ignore-case`, `-d` | no | |

## pax keys consumed

`path`, `linkpath`, `size`, `mtime`, `uid`, `gid`, `uname`, `gname` (per-file and global).
Other keys are ignored; malformed records are dropped/refused per parser rules.

## Limits

- member size / archive size: ≤ 4 GiB (U32); larger → explicit error.
- path: component ≤ 255 bytes, total ≤ 4096 bytes, depth bounded by fuel.
- member count: 1,000,000; totals bounded by limits state.
- pax header payload: ≤ 64 KiB.
- gzip: no size caps (streamed through pipes); trailing non-gzip bytes after the last member are rejected.
