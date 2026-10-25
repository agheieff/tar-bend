# btar 1.1.0 — release notes

Release date: 2026-10-25 · Linux x86-64 · Bend 2.0.39 · MIT.
Supersedes [1.0.0](release-notes-1.0.0.md); 1.0.0 notes are kept for history.

This release is a performance and robustness pass driven by an independent sanity check of the
1.0.0 release. The v1.0.0 archiver was correct and green, but its gzip implementation buffered whole
streams with 8/8/16 MiB caps, huge memory peaks and 200–880× slower gzip paths. 1.1.0 removes that
design: gzip is now fully streamed on read and segment-parallel on write.

## Highlights

- **Streaming gzip reader, no size caps.** A resumable table-driven inflate (`src/inflate.bend`,
  `src/gunzip.bend`) runs in a forked pump and feeds the unchanged tar reader through an anonymous
  pipe (`src/gzio.bend`, new `Fs.pipe`/`Stream.read_seg` effects). Memory is bounded by chunk and
  window sizes (~25 MiB), independent of archive size; multi-member streams are verified member by
  member (CRC-32/ISIZE), including a late error after large extraction.
- **Segment-parallel gzip writer with real DEFLATE compression.** `-czf` runs the tar writer into a
  pipe, splits input into 128 KiB segments, compresses segments in parallel (Bend fork-join), and
  emits the cheapest of **stored / fixed Huffman / dynamic Huffman** per block using a hash-chain
  LZ77 matcher. Output is deterministic and independent of thread count; `gzip -t`, Python zlib and
  GNU tar accept it. On the benchmark tree btar's archive is **48.0% of plain vs GNU gzip's 47.8%**
  (v1.0.0: 61.4%).
- **5 correctness/robustness defects fixed** (all found by the release sanity check; see
  [sanity-check.md](sanity-check.md)):
  1. 16 MiB decompression cap was per member, not per stream; a multi-member file could bypass it
     (96 MiB output → 2.67 GiB RSS; 8 MiB compressed limit allowed ~8 GB of output). Now no
     whole-stream buffering; the same 96 MiB case runs at ~47 MiB RSS.
  2. Quadratic gzip header parsing: 5 000 empty members took 31 s, 200 KB took 120 s. Bytes are now
     consumed from the head of the list; 20 000 members decode in <1 s (gate section 15).
  3. Archive inside the source tree was dumped into itself (truncated while read). The writer now
     checks regular-file `(dev, ino)` against the output archive and skips it with GNU's message.
  4. Plain create was quadratic in entry count: 38 604 entries took 53 s (GNU 0.55 s). The manifest
     is accumulated newest-first and reversed once; the same tree takes 2.2 s.
  5. Docs contradicted each other/code (caps, stored-only, binary sizes). README, gzip docs, man
     page, format/security/effects docs and tests were rewritten to the v1.1 implementation.

## Performance (5.1 MiB/412-entry and 160 MiB/3401-entry workloads, `bench/RESULTS.md`)

| workload | operation | btar 1.1.0 | GNU tar | ratio |
|---|---|---:|---:|---:|
| small | create plain | 19.5 ms / 11 MiB | 6.3 ms | 3.10× |
| small | create gzip | 132.1 ms / 119 MiB | 45.1 ms | 2.93× |
| small | list gzip | 108.3 ms / 28 MiB | 9.3 ms | 11.65× |
| small | extract gzip | 167.0 ms / 28 MiB | 10.8 ms | 15.46× |
| large | create plain | 193.3 ms / 13 MiB | 98.7 ms | 1.96× |
| large | create gzip | 5.66 s / 131 MiB | 2.28 s | 2.49× |
| large | list gzip | 3.60 s / 26 MiB | 0.46 s | 7.76× |
| large | extract gzip | 3.78 s / 26 MiB | 0.46 s | 8.17× |

v1.0.0 baseline for the same small tree: gzip create 8.87 s / 556 MiB RSS, list 8.10 s / 313 MiB,
extract 8.15 s / 313 MiB; plain create 37.7 ms (5.71× GNU). Compression memory grows with the thread
count (~25 MiB per in-flight segment on top of ~30 MiB); `BENDRTS="--threads 4"` or
`+RTS --threads 4 -RTS` bounds it (about 60 MiB). The output does not depend on the thread count.

## Verification

`./tools/test_release.sh` → **PASS, 16/16 sections, 0 fail, 0 skip** on the frozen build
(`btar 1.1.0`, 1,580,352 B). Gate highlights:

- create 21/21, gzip 37/37 (27 fixture checks + 10 streaming checks: large create/extract, GNU
  interop, determinism, memory, self-archive), extract differential 25/25, security 26/26 with zero
  outside-root changes, proofs 17 main + 15 heavy ALL PROOFS CHECK, unit suites PASS.
- ASan/UBSan: list 25/25, extract 25/25, gzip list+extract+create 14/14 clean; fuzz 400/400.
- new gate section: gzip streaming bounds (bomb, multi-member, many-member, corrupt CRC) PASS.
- determinism: 1-thread and default-thread `-czf` outputs are byte-identical (sha256 checked in
  `tools/test_gzip.sh`/unit tests; e.g. a mixed tree produces identical archives).

## Compatibility and limits

- No gzip size caps and no `-z` stdin/stdout (`-` archives) still unsupported. Big `.tar.gz` files
  are now supported but listing/extracting is single-threaded (slower than GNU, see table).
- Compression uses all cores by default and memory scales with the thread count; bound with
  `BENDRTS="--threads N"` or `+RTS --threads N -RTS`. Output is deterministic across N.
- Still ≤4 GiB member/archive (U32), Linux x86-64 only, no C ABI.
- Still no append/update (`-r`/`-u`), `--exclude`, `--transform`, incremental/multi-volume,
  sparse files, ACL/xattr/SELinux, or `--sort=inode`.
- Archives are not padded to GNU tar's 10 KiB blocking factor (both read fine everywhere tested).
- Plain list/extract remain several× slower than GNU tar; create is now within 2–3× on both
  benchmark sizes.

## Upgrade notes

- `VERSION`/`btar --version` → `1.1.0`; `tools/package.sh` writes
  `dist/btar-1.1.0-linux-x64.tar.gz`, `dist/tar-bend-1.1.0-src.tar.gz` and `dist/SHA256SUMS`.
- Scripts that relied on the v1.0.0 gzip caps/errors should be updated: caps are gone, errors are
  now streamed (a late CRC failure can occur after some entries were already extracted, like GNU
  tar), and `-czf` now uses multiple cores/memory.
- `btar` still may leave a partial plain/gzip archive after a fatal write error (like GNU tar).
  `-czf` collects the walk before creating output, so walk errors do not clobber an existing file.
