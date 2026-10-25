# tar-bend — a full tar archiver written in Bend

`btar` is a complete tar implementation — **create, list, extract, append, update** — written in
[Bend 2](https://github.com/bendlang/bend) (2.0.39), with a machine-checked pure core and a small
audited C effect layer for syscalls and the data plane. It reads and writes real archives that GNU tar
and bsdtar accept, including `.tar.gz`, and it refuses path-traversal/symlink/hardlink/limits attacks
with a dedicated adversarial corpus.

Version **1.2.0** · Linux x86-64 · Bend 2.0.39 · MIT.

## Features

- **Modes**: `-c` create, `-t` list, `-x` extract, **`-r`/`--append`**, **`-u`/`--update`**;
  `-f`, `-C DIR`, `-v`, `-p`, `--strip-components=N`, `--one-top-level[=DIR]`, `-O` (extract to
  stdout), `-z`/`--gzip`, `--sort=name` (create), `--format=ustar|pax` (create),
  **`--exclude=PAT`, `--exclude-from=FILE`/`-X FILE`, `--no-recursion`**, `--version`.
  Bundled short flags (`-czf`, `-xzf`, `-tvf`, `-rvf`, …) and separated flags both work.
- **Append / update** (uncompressed archives): `-rf A PATH…` appends in place — the existing
  entries stay byte for byte, a missing archive is created, a corrupt/truncated/compressed archive is
  refused (exit 2) and left untouched; `-uf` appends only new or newer entries (GNU rules: whole
  seconds, archived directories never re-added). See [docs/append-update.md](docs/append-update.md).
- **Exclusion** with GNU semantics (unanchored wildcards that also match `/`, leading-directory
  match, pattern files) in create, append, update, list and extract — pure Bend matcher
  verified against GNU tar on 129 pattern/name cases. See [docs/exclude.md](docs/exclude.md).
- **Read formats**: v7, ustar, POSIX pax (`x`/`g`), GNU longname/longlink (`L`/`K`), GNU base-256
  numerics; per-file and global pax overrides (path/linkpath/size/mtime/uid/gid precedence).
- **Write formats**: ustar when a header fits; a POSIX pax extended header otherwise. Hardlinks,
  symlinks, directories, nested paths, long names, non-UTF-8 names, numeric uid/gid, modes and
  second-granularity mtimes.
- **gzip implemented in Bend, streaming**: a table-driven resumable inflate (stored/fixed/dynamic
  Huffman, LZ77, multi-member, CRC-32/ISIZE checked) feeds the tar reader through a pipe, so
  gzip streams of any size (tar members inside still obey the 4 GiB/member limits) list/extract in ~25 MiB of memory with no gzip size caps; `-czf` runs the tar
  writer into a pipe and compresses 128 KiB segments **in parallel** (hash-chain LZ77, dynamic
  Huffman, stored/fixed fallback) with deterministic output. `gzip -t`, Python `zlib` and GNU tar
  all validate `btar -czf` output, which is within ~2 % of `gzip -6` in size. See
  [docs/gzip.md](docs/gzip.md).
- **Safe extraction by default**: rejects absolute paths and `..`, never follows symlinks
  (`openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS` + `O_NOFOLLOW`), refuses device/FIFO/special
  entries, contains hardlinks to already-extracted regular files under the root, strips
  setuid/setgid when not root, enforces member/size/path/header limits, and keeps the
  `--one-top-level` hardlink-escape class (CVE-2026-18508) refused.
- **Machine-checked pure core**: 17 laws in the main proof gate (`bend proofs/PROOF.bend`,
  `--verdict` green) + 15 heavy concrete laws (including an L9 writer-model round trip and L10
  layout/padding) in `proofs/PROOF_HEAVY.bend`. See [docs/proofs.md](docs/proofs.md).
- **Verified by differential + adversarial testing** against GNU tar 1.35 and bsdtar 3.8.10, with
  ASan/UBSan coverage of the effect layer and a deterministic header fuzzer.

## Quick start

The project pins **Bend 2.0.39** in a project-local toolchain (the global install is not touched):

```sh
git clone <this-repo> tar-bend && cd tar-bend
curl -fsSL -o /tmp/bend-2.0.39.tar.gz \
  https://github.com/bendlang/bend/releases/download/v2.0.39/bend-2.0.39-linux-x64.tar.gz
sha256sum /tmp/bend-2.0.39.tar.gz   # 6cf462fd8f70b094a4950ebb709a9c4ffd8f1d1189d9cedf1fd63cd5d041c7ab
mkdir -p .cache/toolchain && tar xzf /tmp/bend-2.0.39.tar.gz -C .cache/toolchain --strip-components=1

export PATH="$PWD/.cache/toolchain/bin:$PATH"
bend version           # bend 2.0.39
./tools/run.sh build   # native ./build/btar
./build/btar --version # btar 1.2.0
```

Examples:

```sh
./build/btar -cf backup.tar -C /home/me/dir .              # create
./build/btar -czf backup.tgz -C /home/me/dir --sort=name . # deterministic gzip create
./build/btar -tvf backup.tgz                               # list (auto-detect gzip)
./build/btar -xzf backup.tgz -C /tmp/restore              # extract
./build/btar -xOf backup.tar path/in/archive > file        # extract one member to stdout
./build/btar -rf backup.tar -C /home/me/dir new-dir        # append to an uncompressed archive
./build/btar -uf backup.tar -C /home/me/dir .              # append only new/newer files
./build/btar -cf src.tar --exclude='*.o' --exclude=.git src # exclusions (GNU semantics)
```

## Verification

```sh
./tools/run.sh test          # full gate: check, proofs, unit, create, gzip, diff, security, ASan, fuzz
./tools/test_release.sh      # release gate (ordered, evidence table; --quick skips ASan/fuzz)
./tools/ci.sh --quick        # what CI runs: pins/installs Bend 2.0.39, then the release gate
./tools/bench_release.sh     # benchmark report vs GNU tar -> bench/RESULTS.md
```

Current evidence (v1.2.0): create differential **21/21**, gzip **37/37**, extract differential
**25/25** (+ `-p` strict, `-O` bytes), security **26/26** evil fixtures with **0** outside-root
changes, **append/update vs GNU tar 68/68** (+ 300 + 120 mutation-fuzz runs clean), **exclusion vs GNU
tar 208/208**, ASan/UBSan list/extract **25/25**, gzip **14/14** and append **25/25** clean, header
fuzz **400/400**, proofs 17 + 15 ALL PROOFS CHECK, unit suites PASS, release gate **17/17 sections
PASS / 0 skipped**. Performance against GNU tar (unchanged from 1.1.0 within noise):
[bench/RESULTS.md](bench/RESULTS.md). Details: [docs/status.md](docs/status.md),
[docs/release-verification.md](docs/release-verification.md),
[docs/sanity-check.md](docs/sanity-check.md), CI: [docs/ci.md](docs/ci.md).

## Limits and non-goals (v1.2.0)

- Linux x86-64 only; no C ABI (this is a CLI, not a `libtar` replacement); no Windows/macOS.
- U32 sizes: archives/members > 4 GiB are refused; no sparse files, device nodes or FIFOs.
- gzip has **no size caps** (streamed). `-czf` uses all cores (`+RTS --threads N` bounds the CPU
  count and the memory that grows with it: ~100 MiB at 24 threads, ~35 MiB at 1); decoding is
  single-threaded. No gzip levels, no bzip2/xz/zstd, no `-` (stdin/stdout) archives.
- Create operand policy: absolute paths and `..` are refused; archive names follow GNU spelling
  (`a.txt`, `./a.txt`, `.` → `./`); duplicate operands are archived twice.
- `-r`/`-u` only on uncompressed archives (as GNU tar), no `-A`/`--delete`/`-d`; exclusion supports
  the wildcard subset in [docs/exclude.md](docs/exclude.md) (no POSIX classes, `--anchored`, VCS
  or tag excludes). No `--transform`, `-T`, incremental dumps, multi-volume, ACL/xattr/SELinux,
  archive-to-stdout `-`, or `--sort=inode`.
- uid/gid numeric, uname/gname empty; mtime second granularity; special entries skipped with a
  warning (exit 1).

## Architecture

```
src/        pure Bend: bytes, num, checksum, header, pax, links, entry, path, limits,
            crc, inflate, gunzip, deflate, gzcomp, upd (-u table), glob (--exclude matcher)
            (the provable core; gzio is the effectful gzip pump, read_stream/extract/write/
            append the effectful tar drivers)
effs/       the only trusted C: openat2/dirfd filesystem effects, data copy, pipe, memfd,
            read_exact/read_seg/write_zeros, open_rw/seek/trunc_cur (append), stdout —
            IO-only, no policy/path joining
app/        CLI (byte-safe argv, mode dispatch, gzip detection, caps, exit codes)
laws/ proofs/  LAWS.bend + PROOF.bend (verdict gate) + PROOF_HEAVY.bend (concrete)
tests/      Bend self-checks (JS lane) + differential/security/gzip/create harness drivers
tools/      fixtures, compare/diff/security/create/gzip/append/exclude/release/bench harnesses, ci.sh
bench/      benchmark workload + RESULTS.md
docs/       status, design/security/effects/proofs/testing/release notes, btar(1) man page
fixtures/   generated deterministic corpus (not committed)
```

Trust boundary: the pure core is proven; the C effect layer (syscalls/data copy/pipes) is
small, audited and covered by differential, security, ASan and fuzz tests, not proofs. See
[docs/effects.md](docs/effects.md) and [docs/proofs.md](docs/proofs.md).

## Release artifacts

`tools/package.sh` -> `dist/btar-1.2.0-linux-x64.tar.gz` (binary + README/LICENSE/VERSION/man +
full docs/plan/bench), `dist/tar-bend-1.2.0-src.tar.gz` and `dist/SHA256SUMS` (the authoritative
package hashes). The final release gate run rebuilt `build/btar` to the same sha256 as the packaged
binary (`b717df57…fca6`). What changed in 1.2.0: [release notes](docs/release-notes-1.2.0.md).

## License

MIT — see [LICENSE](LICENSE). Vendored test fixtures are generated; the harness uses the system GNU
tar/bsdtar for reference only. Prior art consulted: GNU tar/bsdtar, libarchive, Go `archive/tar`,
Rust `tar`.
