# `--delete` and `-A` / `--concatenate` (v1.3)

Both rewrite an **uncompressed** archive in place at the byte level (no member is re-encoded) and
are checked against GNU tar 1.35 by `tools/test_rewrite.sh` (28 checks). Module: `src/rewrite.bend`
(effectful, outside the proof core); the member table comes from the `-r/-u` scanner
(`src/append.bend`, `Upd.tab_spans`).

## `btar --delete -f ARCHIVE NAME...`

- Operands select like list/extract operands: literal, anchored, a directory removes everything
  below it; trailing `/` ignored.
- Unmatched operands print `btar: NAME: Not found in archive` plus the GNU trailer line, exit 2;
  matched members are still deleted (as GNU). No operands: archive untouched.
- The scan validates the whole archive first (same errors as `-r`: corrupt, truncated, sparse…).
  Kept byte runs are then moved down inside the file (`Data.copy`, runs already in place are not
  copied), two zero blocks are written and the file is truncated.
- Metadata headers (pax `x`, GNU `L`/`K`) travel with the member that follows them. A pax *global*
  header (`g`) is treated the same way, so deleting the member right after it also drops it.
- Hardlinks whose target is deleted are left as they are (dangling), like GNU.
- Not atomic: a crash mid-rewrite can leave the archive damaged. `-z`, `-` and combining with
  `-r/-u/-A` are refused (exit 2).

## `btar -A -f DEST SRC...` (`--concatenate`, `--catenate`)

- Every source is checked (exists, valid, uncompressed) before DEST is opened for writing; any
  failure leaves DEST byte-identical. DEST must exist.
- Each source's logical contents (up to its first zero block) are appended at DEST's logical end,
  then two zero blocks; stale bytes after that are truncated.
- Divergence: GNU 1.35 loses the members of a later source that contains pax long-name headers
  (observed with a 120+120-byte path); btar keeps them.

## Effect fix found on the way

`Stream.seek` / `Fs.trunc_cur` freed a stale `IoWork` buffer when they ran right after a Base
`File.open_bytes` (double free, found with the ASan build). Both now clear `data`/`text` first.
