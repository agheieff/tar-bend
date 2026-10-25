# Append and update — `btar -r` / `btar -u` (v1.2)

`btar -rf ARCHIVE PATH...` appends entries to an **uncompressed** tar archive;
`btar -uf ARCHIVE PATH...` appends only entries that are new or newer than the archived copy.
Both follow GNU tar 1.35 for the supported subset and are verified against it by
`tools/test_append.sh` (68 differential/error cases) and `tools/fuzz_append.py` (mutation fuzz).

## Behaviour

| | `-r` | `-u` |
|---|---|---|
| archive missing | created (no entries are lost) | created |
| archive empty (0 bytes) | treated as an empty archive | same |
| existing entries | preserved **byte for byte** (only the end-of-archive region is rewritten) | same |
| operands | same policy as create: `-C`, `./x`, absolute/`..` refused, `--sort=name`, `-v`, `-p`, `--format`, `--exclude*`, `--no-recursion` | same |
| no operands | nothing is appended; the archive is validated and its trailer normalised | same |
| entry selection | all operands | an entry is skipped when the archive holds the same name with mtime ≥ the disk mtime (see below) |

Rejected with exit status 2 (usage/fatal), archive untouched: `-r`/`-u` together with `-z` or
`--gzip`, with `-c`, `-t`, `-x`, `-O`, with each other (`-ru`), a gzip-compressed archive file
("cannot append to or update a compressed archive"), `-` (stdin/stdout) as archive, a directory
or non-regular file as archive.

### How the end of the archive is found

A read-only pass (`src/append.bend`) walks the headers: one `Stream.read_exact` per 512-byte
header, payloads skipped with `Stream.seek`. The logical end is the offset of the **first
all-zero block**, or EOF when the end blocks are missing (GNU does the same). pax `x`/`g` and GNU
`L`/`K` headers are parsed (they affect names/sizes). The pass fails — before the archive is
opened for writing — on:

- a bad checksum/magic/numeric field ("not a valid tar archive … at offset N");
- a partial header block or member data that runs past EOF ("truncated archive …");
- GNU sparse/dumpdir/multi-volume entries ("unsupported tar entry type");
- a size field on a link, device, FIFO or directory entry (GNU and `btar -x` disagree about
  such sizes, so the logical end would be ambiguous);
- member sizes that overflow the 4 GiB v1 limit.

Because operand validation, the scan and the manifest collection all happen **before**
`open(O_RDWR)`, every error path leaves the archive byte-identical (and does not create a missing
archive). The write itself is: open read-write (no truncation), `seek` to the logical end, write
the new entries exactly as create would, write two zero blocks, `ftruncate` to the write position
(dropping the stale tail, e.g. GNU's 10240-byte padding), close.

### `-u` semantics (GNU subset)

`src/upd.bend` keeps an in-memory table of the archive (name hash → members) built during the
scan; names are normalised (leading `./` and trailing `/` removed) so `d`, `d/` and `./d` are one
name. For each candidate entry:

- a non-directory is skipped when **some** archived member of the same name has
  `archived mtime ≥ disk mtime` (seconds; `lstat` mtime for symlinks) — so newer files, new names
  and type changes (symlink→file, dir→file) are appended, unchanged/older ones are not;
- a **directory** is skipped whenever its name is already archived, however new its mtime
  (GNU never re-adds an archived directory; its members are still compared individually);
- the walk still descends into skipped directories; a skipped file does not enter the hardlink
  registry, so a later link to it is stored as a regular file (GNU does the same).

Lookups are O(log n) (a hash-keyed search tree); an unchanged 20 101-entry tree is `-u`-checked in
~1.1 s (GNU tar: 0.04 s).

## Differences from GNU tar

- **Order of appended entries under `-u`**: GNU visits the non-directory entries of a directory
  before its subdirectories; btar uses create order (`--sort=name` or readdir order). The set of
  appended entries is the same; `tools/test_append.sh` compares `-u` results as sorted multisets.
- Sub-second times: both tools compare whole seconds for archives written by GNU/btar ustar
  headers; for a pax archive with fractional `mtime` GNU compares the fractional part too, btar
  compares the integer seconds (so a file modified within the same second as its archived copy is
  not re-added).
- GNU's `-u` has surprising behaviour on archives that list a subtree before its parent
  directory (it can silently skip updates); btar applies the rule above uniformly.
- Hardlinks: as in GNU, only links *within the appended set* are recorded as hardlinks; a file
  that is a hardlink of an old member is appended as a regular file (old members are not
  registered). This keeps the appended region self-contained.
- `-r`/`-u` without `-f` treat the first positional argument as the archive (same as create).
- A failed operand (missing file) fails the whole run before anything is written; GNU appends the
  operands that worked and exits 2.
- No `-A` (concatenate), `--delete`, `-d`/`--diff`, incremental or multi-volume modes.
- Archives are appended in place; there is no locking and no crash-atomicity (a crash mid-append
  leaves a valid prefix followed by a partial member, as with GNU tar).
- The archive path is opened with `open(2)` like GNU tar does (a symlink archive path is
  followed). The *appended entries* are read with the create-time no-follow rules.

## Security

- Entries are produced by the same writer as create: absolute and `..` operands are refused,
  names are bounded, special files are skipped with a warning (exit 1, archive still valid), and
  the archive's own `(dev, ino)` is excluded from the manifest. The output of `-r` passes the
  same extraction policy as any other archive (`btar -x`, `tools/test_append.sh` extracts every
  result with GNU tar and compares trees; `tools/run_asan.sh` runs `-rf`/`-uf` over the whole
  valid fixture corpus under ASan/UBSan).
- Only three effects touch the archive file (`Fs.open_rw`, `Stream.seek`, `Fs.trunc_cur`, see
  [effects.md](effects.md)); policy (what is the end, what is valid, what is newer) lives in
  pure Bend (`upd.bend`) and the scanner state machine.
- `tools/fuzz_append.py` mutates archives (header byte flips, whole-block randomisation, size
  lies with fixed checksums, typeflag swaps, truncation, trailing garbage) and checks: exit
  status ∈ {0,1,2}; exit 2 ⇒ archive byte-identical; success ⇒ original prefix preserved, exact
  1024-byte trailer, and GNU tar reads the result iff it read the input. 600 mutations clean
  (release gate: 300 on the release binary + 120 on the ASan binary).
