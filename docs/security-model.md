# Security model (btar 1.2.0)

## Threat model

The archive is **untrusted**; the destination root is chosen by the user. An attacker can craft
arbitrary headers, pax records, member names, link targets, sizes and compressed streams. Goals:
no writes outside the destination root, no symlink/hardlink escape, no device/FIFO creation, bounded
resource use, and no silent corruption/truncation.

## Enforced policy

1. **Path normalisation (pure, `src/path.bend`)**: reject absolute paths, NULs, empty names and any
   `..` component; drop `.`/empty components; component ≤ 255 B, total ≤ 4096 B; `--strip-components`
   applied before validation. Empty results are allowed only where the entry type permits.
2. **Symlinks**: created as recorded but **never followed during extraction**; all filesystem
   operations are dirfd-relative `openat2` with `RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS` and
   `O_NOFOLLOW`; replacement uses unlinkat + `O_EXCL`, never truncation through a symlink.
3. **Hardlinks**: target must be an already-extracted regular file under the destination root
   (normalised path registry, `fstatat` with no-follow); cross-directory links are walked by
   components; otherwise fatal. `--one-top-level` keeps all paths under the chosen directory; the
   CVE-2026-18508 hardlink-escape regression is in the permanent security corpus.
4. **Types**: regular files, directories, symlinks, hardlinks supported. FIFO/char/block/socket
   are listed but refused on extraction with a warning (exit 1); sparse/dumpdir/multi-volume headers
   are fatal.
5. **Modes/ownership**: mode applied as `mode & 07777`; setuid/setgid cleared unless `-p` and root;
   no chown in v1; numeric uid/gid recorded in create mode.
6. **Limits**: member count, per-member size, total bytes, path/component length and pax payload are
   bounded with overflow-checked U32 arithmetic; archive/member > 4 GiB refused.
7. **gzip**: decompression verifies header, DEFLATE structure, per-member CRC32 and ISIZE; malformed
   streams are fatal, never silently truncated. The decoder streams in bounded memory (256 KiB
   chunks, 32 KiB window): a decompression bomb costs time, not memory, and the tar limits above
   still bound what is extracted. The decoder runs the whole stream to the end (including the last
   CRC) even after the tar reader stops, and works linearly in the input (many tiny members cannot
   cause quadratic work). Create refuses to dump the output archive into itself.
8. **Exit codes**: 0 success, 1 completed-with-warnings (skipped special entries), 2 fatal.
9. **Append/update (v1.2)**: the archive is untrusted input *and* an output file. The logical end
   is found by a read-only validating scan (checksum/numerics, data inside the file, no sparse or
   sized link entries, 4 GiB cap) **before** the archive is opened for writing, so a corrupt or
   truncated archive is never modified (exit 2, byte-identical; a missing archive is not created
   by a failed run). Appended entries come from the create writer — absolute/`..` operands refused,
   source files opened no-follow, the archive's own `(dev, ino)` skipped — so their extraction is
   governed by policy 1–6 like any other archive. The archive path itself is opened with plain
   `open(2)` (a symlinked archive path is followed, as GNU tar does). No locking: concurrent
   writers can interleave. `-r`/`-u` are refused for gzip archives (no in-place rewrite).
10. **Exclusion (v1.2)**: `--exclude*` only ever *removes* work (entries are skipped at stat time on
    create, or read past on list/extract); it cannot add members, change names or relax any check.
    The matcher is pure, bounded (O(|pattern|·|name|), no recursion explosion) and byte-based.

## Proof boundary

Proven (pure Bend, `bend proofs/PROOF.bend` + `--verdict`, and concrete heavy proofs): header/pax
encoding and parsing invariants, checksum and octal/base-256 round-trips, path normalisation
properties (no-parent, idempotence where stated), block/padding/end-of-archive layout, concrete
writer-model round-trip, limits invariants where stated. Not proven: syscall effects (openat2,
readdir, statx, copy, memfd), gzip codec internals (tested against GNU gzip/Python zlib), CLI wiring,
the C compiler/runtime and the OS/VFS. Those are covered by the differential, adversarial, ASan/UBSan
and fuzz suites; see [proofs.md](proofs.md) and [release-verification.md](release-verification.md).

## Trusted base

- Bend toolchain pinned to 2.0.39 and its generated C/runtime; the C effect layer (`effs/fs.c`) is
  the only trusted C and is intentionally IO-only (no path joining/policy; v1.2 adds `open`/`lseek`/
  `ftruncate` for append, see [effects.md](effects.md)); the JS lane is not the release lane for
  gzip/native effects.
- Linux kernel path resolution semantics (`openat2` resolve flags), the filesystem, and libc.
- The test harness's use of GNU tar/bsdtar as a reference oracle (behavioural reference, not trusted
  for security decisions).
