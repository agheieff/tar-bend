> Historical release notes (superseded by [1.1.0](release-notes-1.1.0.md); kept for reference).

# btar 1.0.0 — release notes

Release date: 2026-10-25 · Linux x86-64 · Bend 2.0.39 · MIT.

`btar` is a complete tar archiver written in Bend: create, list and extract archives with a
machine-checked pure core and a small audited C effect layer. This is the first release.

## Highlights

- **Create / list / extract** for v7, ustar, POSIX pax and the GNU longname/longlink/base-256
  extensions; writes ustar or pax. Hardlinks, symlinks, directories, long names, non-UTF-8 names,
  modes/mtimes.
- **gzip in Bend**: reads all mainstream GNU gzip streams (stored/fixed/dynamic Huffman, LZ77,
  multi-member) and writes valid gzip archives (fixed-Huffman + LZ77). Verified against `gzip -t`,
  Python `zlib`, GNU tar.
- **Safe extraction**: no absolute/`..` paths, no symlink following (`openat2` resolve flags +
  `O_NOFOLLOW`), hardlink containment, refused special files, bounds/limits, CVE-2026-18508
  `--one-top-level` regression covered.
- **Proofs**: 17 laws in the proven-kernel gate (`PROOF.bend` + `--verdict`) and 15 heavy concrete
  laws (writer-model round-trip, block layout/padding, encoders) in `PROOF_HEAVY.bend`.
- **Verification**: 21/21 create differential, 27/27 gzip, 25/25 extract differential, 26/26 evil
  fixtures with zero outside-root writes, ASan/UBSan 25/25 list+extract, fuzz 400/400, release gate 16/16 sections PASS / 0 skipped.
- CLI: byte-safe argv, individual and bundled flags, auto-detect gzip, `-C/-v/-p/-O`,
  `--strip-components`, `--one-top-level`, `--sort=name`, `--format=ustar|pax`, `--version`.

## Compatibility and limits

- **Read**: GNU tar/bsdtar-compatible for the formats above; sparse/dumpdir/multi-volume headers are
  refused; FIFO/device entries are listed but not extracted (warning, exit 1).
- **Write**: ustar/pax only (no GNU longname output; pax is used instead). No device/FIFO/sparse
  members; special source entries skipped with warning.
- **Sizes**: ≤ 4 GiB per member/archive (U32); >4 GiB refused explicitly.
- **gzip v1**: whole-stream buffered. Caps: 8 MiB compressed input, 8 MiB uncompressed create input,
  16 MiB decompressed output. Create emits fixed-Huffman/LZ77 only (real compression; larger than
  GNU gzip on some corpora); dynamic-Huffman encoding and hash-chain search are v1.1.
- Create source operands: absolute paths and `..` refused; names follow GNU spelling; duplicates
  archived twice.
- Not in v1: append/update (`-r`/`-u`), `--exclude`, `--transform`, incremental/multi-volume,
  ACL/xattr/SELinux, archive-to-stdout `-`, non-Linux platforms, C ABI/library embedding.

## Verification commands

```sh
./tools/run.sh test        # full suite
./tools/test_release.sh    # release gate (+ --quick)
./tools/bench_release.sh   # benchmark vs GNU tar -> bench/RESULTS.md
```

See [status.md](status.md), [release-verification.md](release-verification.md),
[security-model.md](security-model.md), [proofs.md](proofs.md), [format-support.md](format-support.md).

## Packaging (built 2026-10-25)

```
dist/btar-1.0.0-linux-x64.tar.gz   sha256 f0c351970d93b686e1180ea001a1cbe7944510c16146d66340f015de0901d388
dist/tar-bend-1.0.0-src.tar.gz     sha256 see dist/SHA256SUMS
dist/btar                          sha256 867540fa02706b64b67ce4ce34118ca47a66c8149dce475d9f3c0156a0ea340d
```

`tools/package.sh` writes these plus `dist/SHA256SUMS`.

`tools/package.sh` writes `dist/btar-1.0.0-linux-x64.tar.gz` (binary + README/LICENSE/man),
`dist/tar-bend-1.0.0-src.tar.gz`, and `dist/SHA256SUMS`.

## Credits

Built with Bend 2.0.39 (bendlang) and a lot of differential testing against GNU tar 1.35 and
libarchive/bsdtar 3.8.10. License: MIT.
