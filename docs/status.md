# tar-bend status

Updated: 2026-10-25 (v1.2.0 — append/update, exclusion, CI; builds on v1.1.0 streaming/parallel gzip).

## Toolchain

- Project-local **Bend 2.0.39** at `.cache/toolchain/bin/bend`, pinned from the v2.0.39 Linux x64
  release (`sha256 6cf462fd...d041c7ab`); global `~/.bend` (2.0.38) untouched.
- clang 23.1.3, GNU tar 1.35, bsdtar 3.8.10, Python 3.11+, Linux x86-64 (`openat2`).
- Gates: `tools/run.sh test`, `tools/test_release.sh` (16 sections), `tools/bench_release.sh`,
  `tools/package.sh`.

## Milestones

| Milestone | Status | Notes |
|---|---|---|
| Plan + scaffold | **done** | `plan/full-tar.md`, README/AGENTS, whitelist `.gitignore` |
| M0 toolchain pin + effects + harness | **done** | ABI check, openat2/dirfd effects, data copy, fixture/diff/security harnesses |
| M1 pure parser + `btar -tf` | **done** | header/pax parser, lister, 25-fixture differential |
| M2 streaming extractor + safety | **done** | dirfd extraction, path/limits, ASan/fuzz, 26 evil fixtures |
| M3 links/policy/options/laws | **done** | cross-dir hardlinks, global pax, options, warnings, 10 laws + heavy proofs |
| M4 creator | **done** | two-phase writer, ustar/pax, hardlinks/symlinks, 21/21 create harness |
| M5 gzip | **done** | pure-Bend crc/inflate/gunzip/deflate/gzcomp/gzio; streaming read, parallel write |
| M6 hardening | **done** | multi-operand create, `--sort=name`, warnings, root metadata, hardlink fix |
| M7 release | **done** | 1.0.0 packaged; release gate + benchmark + docs |
| **v1.1 performance/streaming** | **done** | no gzip caps, ~25 MiB read RSS, parallel dynamic-Huffman create, 5 sanity fixes |
| **v1.2 append/update + exclusion + CI** | **done** | `-r`/`-u` (uncompressed), `--exclude*`/`--no-recursion`, 3 extraction bugfixes, `tools/ci.sh` + workflow |

v1.0.0 history: [release-notes-1.0.0.md](release-notes-1.0.0.md). v1.1.0:
[release-notes-1.1.0.md](release-notes-1.1.0.md), [sanity-check.md](sanity-check.md),
[gzip.md](gzip.md). **v1.2.0 (current)**: [release-notes-1.2.0.md](release-notes-1.2.0.md),
[release-verification.md](release-verification.md), [append-update.md](append-update.md),
[exclude.md](exclude.md), [ci.md](ci.md), [effects.md](effects.md).

## v1.2.0 headline evidence

- **Release gate**: `./tools/test_release.sh` → **PASS, 17/17 sections, 0 fail, 0 skip**; artifact `btar 1.2.0`, 1,898,112 bytes,
  sha256 `b717df5770e8ad87830d447ba45b1ecad895072babf0bf19a41731e9ac53fca6`. Package hashes: `dist/SHA256SUMS`.
- **New harnesses**: `tools/test_append.sh` **68 passed, 0 failed**; `tools/fuzz_append.py` **300/300 clean** (release binary), **120/120 clean** (ASan binary);
  `tools/test_exclude.sh` **208 passed, 0 failed**; ASan/UBSan append phase **25/25 clean** (`-rf` + `-uf`).
- **Unchanged and green**: proofs 17 + 15, create 21/21, gzip 37/37, extract diff 25/25, security
  26/26 (0 outside-root), ASan list/extract 25/25 + gzip 14/14, header fuzz 400/400, unit suites,
  fixture determinism, ABI check. No benchmark regression (plain create/list/extract within
  noise; `bench/RESULTS.md` regenerated for 1.2.0).
- **Landed in 1.2.0**: `-r`/`-u` append/update (scanner `src/append.bend`, table `src/upd.bend`, effects
  `Fs.open_rw`/`Stream.seek`/`Fs.trunc_cur`); `--exclude`, `--exclude-from`, `-X`, `--no-recursion`
  (matcher `src/glob.bend`); bugfixes: `--strip-components` misrouted to create mode, stripped-name
  payload padding, hardlink-target stripping; CI (`tools/ci.sh`, `.github/workflows/ci.yml`).

- **1.3.0 (in progress)**: member operands for `-t`/`-x` (`Glob.selected`, `Cfg.mem`), `-T`/`--files-from`
  `--delete`, `-A` ([rewrite.md](rewrite.md), 28 checks), `--transform` ([transform.md](transform.md), 54 + ~350 sed checks);
  member operands + `-T` (`tools/test_members.sh`, 30 checks, incl. "Not found in archive" vs GNU tar). See [format-support.md](format-support.md).

- **1.3.0 parity push** (+ `-d`/`--diff`, `tools/test_diff.sh`) (uncommitted at the time of writing): GNU-style option parser
  (`app/cli.bend` + generated `app/cli_table.bend`, all 173 GNU options recognised, see
  [options.md](options.md)); `-f -` stdin/stdout; GNU `-tv` listing format and name quoting;
  `uname`/`gname` on create; `--owner/--group/--mode/--mtime/--numeric-owner`; `-k`,
  `--skip-old-files`, `--keep-newer-files`, `-m`; `--delete`, `-A`, `--transform`, member
  operands, `-T`. Test scripts: `tools/test_{members,rewrite,transform,stdio,options}.sh`.
  Remaining roadmap (in order): `-d`/`--diff`; create-side selection (`-h`, `--one-file-system`,
  `-P`, `--newer*`, `--remove-files`, `--null`, `--exclude-vcs/-caches/-tag`, `-V`, `--totals`,
  `-l`, `--format=gnu|v7`); extract-side (ownership restore, `--no-overwrite-dir`,
  `--recursive-unlink`, `-i`, `-n`, `--to-command`, `--backup`, `-vv` on extract); xattr/ACL/
  SELinux (pax `SCHILY.*`); sparse read/write; incremental (`-g`, `-G`); multi-volume (`-M`);
  `--rsh-command`; other compressors (`-j -J --zstd -Z --lzip --lzma --lzop`, `-a`, `-I`);
  U64 (>4 GiB). Then proofs.

## Next agent: where to continue

1. Run `./tools/ci.sh --quick` (or `--full`) first; everything is expected green.
2. Open items (none blocks the release): `-d`/`--diff`, `--transform` extras (see transform.md), `-T` extras (`--null`, bundles); GNU-style
   positional option semantics for `--exclude`; POSIX classes in the matcher; `-X` in bundles;
   O(1) `-u` lookups are fine at 20k entries (~1.1 s) but a 1M-entry archive was not measured;
   `ws_end` always calls `Fs.trunc_cur` (cheap, but a refactor could make it append-only).
3. The CI workflow has never run on GitHub (no remote here); first run may need tweaks
   (runner image packages). Signing/publishing are not configured ([ci.md](ci.md)).
4. Proof gaps unchanged: general-forall laws L1/L4/L6/L8; `upd`/`glob` are tested, not proven.
5. Known divergences from GNU documented in [append-update.md](append-update.md) and
   [exclude.md](exclude.md) (order of `-u` appends, pax sub-second mtimes, positional options).

## v1.1.0 headline evidence

- **Release gate**: `./tools/test_release.sh` → **PASS, 16/16 sections, 0 fail, 0 skip**; artifact
  `btar 1.1.0`, 1,580,352 B, sha256
  `f28146d0c60fa47d397d00bc80f136dea49c31e89ffdaa2f84e9a56a7d73580b`.
- **Suites**: create 21/21, gzip 37/37 (27 fixture + 10 streaming), extract diff 25/25, security
  26/26 with 0 outside-root changes, ASan/UBSan list 25/25 + extract 25/25 + gzip 14/14 clean, fuzz
  400/400, proofs 17 main + 15 heavy ALL PROOFS CHECK, unit suites PASS, fixture determinism stable.
- **gzip**: streaming inflate (stored/fixed/dynamic Huffman, LZ77, multi-member, CRC/ISIZE) with no
  size caps (~25–28 MiB RSS read); segment-parallel writer with hash-chain LZ77 + dynamic Huffman.
  `-czf` output 48.0% of plain vs GNU gzip 47.8% on the 5.1 MiB bench tree (v1.0.0: 61.4%).
- **Perf vs GNU tar** (small 5.1 MiB / large 160 MiB): create plain 3.10×/1.96×, create gzip
  2.93×/2.49×, list plain 6.3×/10.3×, list gzip 11.7×/7.8×, extract plain 8.8×/2.95×, extract gzip
  15.5×/8.2×. Details: `bench/RESULTS.md`.
- **Packaging**: `dist/btar-1.1.0-linux-x64.tar.gz` (sha256 recorded
  in `dist/SHA256SUMS`),
  `dist/tar-bend-1.1.0-src.tar.gz`, `dist/SHA256SUMS`; packaged binary equals `build/btar`
  (`f28146d0…580b`).

## Sanity fixes in v1.1.0 (independently found, fixed)

1. 16 MiB cap was per member → multi-member gzip could bypass it (96 MiB output, 2.67 GiB RSS);
   streaming decode removes the class (same file ~47 MiB RSS).
2. Quadratic gzip header parsing (5 000 members: 31 s; 200 KB: 120 s) → head-of-list consumption;
   20 000 members < 1 s.
3. Archive inside its own source tree was dumped into itself (truncated while read) → writer skips
   its own `(dev, ino)` with GNU's message.
4. Plain create quadratic in entry count (38 604 entries: 53 s vs GNU 0.55 s) → 2.2 s.
5. Docs contradicted code/each other (caps, stored-only, sizes) → all rewritten.

## Decisions locked

- Full program = create/list/extract/append/update, v7/ustar/pax/GNU extensions, gzip in Bend,
  Linux x86-64.
- Trust boundary: pure metadata/format/policy in Bend (provable); small C effects for syscalls/data;
  gzip pump `src/gzio.bend` is effectful, the codec modules are pure and `--check-only` clean.
- ≤4 GiB member/archive (no U64 yet); CLI subset per plan §2.1; archive names/`./` semantics follow
  GNU; absolute and `..` create operands refused.
- Payloads through `Data.copy`; gzip read through a pipe; gzip write via forked tar writer + parallel
  segments. `-czf` output is deterministic and thread-count independent.
- Project-local compiler pin; effect ABI gate before native builds.

## Remaining gaps / next release

- `-A`/`--delete`/`-d`, `-T`, `--transform`, incremental/multi-volume, sparse files,
  ACL/xattr/SELinux, `--sort=inode`, stdin/stdout `-` archives.
- >4 GiB (needs U64), C ABI/library embedding, non-Linux platforms.
- gzip: dynamic-Huffman read is complete; encoder is dynamic/fixed/stored with hash-chain LZ77.
  Remaining perf: gzip list/extract is single-threaded and 8–15× GNU; plain list/extract 6–10×.
- Proof depth: general-forall laws L1/L4/L6/L8 (concrete versions proven); effects/gzip pump are
  tested (ASan/fuzz/differential), not proven.
- Packaging: no git repo/signing/publishing; CI is written but unexercised ([ci.md](ci.md)); no
  install script for the man page.
