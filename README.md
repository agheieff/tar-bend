# tar-bend

`btar`: a tar archiver written in [Bend 2](https://github.com/bendlang/bend) (pinned to 2.0.39).
It creates, lists, extracts, appends to, updates and edits real tar archives (v7, ustar, POSIX pax,
GNU long names) and reads and writes `.tar.gz` with a gzip codec written in Bend, too.

Version **1.3.0** · Linux x86-64 only · MIT · a CLI, not a library (Bend has no C ABI).

It is a correctness experiment first. A pure Bend core (format, path policy, limits) is
machine-checked, and a small C layer (about 2,400 lines in `effs/`) does the syscalls. Behaviour is
compared with GNU tar 1.35 and bsdtar 3.8. **It is slower than GNU tar** and covers only part of
GNU's option set (below).

## What works

- **Modes**: `-c` `-t` `-x` `-r` `-u` `-A` `--delete` `-d`/`--diff`. `-r`, `-u`, `-A` and `--delete`
  work in place on uncompressed archives only.
- **Archive I/O**: `-f FILE`, `-f -` for stdin/stdout, `-C`, `-z` (gzip, auto-detected on read),
  member operands, `-T`, `-O`, `-k`, `-m`, `-p`.
- **Selection and rewriting**: `--exclude*`, `-X`, `--no-recursion`, `--exclude-vcs`,
  `--exclude-backups`, `--newer*`, `--remove-files`, `--strip-components`, `--one-top-level`,
  `--transform` (a POSIX BRE subset), `--owner`, `--group`, `--mode`, `--mtime`, `--sort=name`,
  `--format=ustar|pax`.
- **Gzip in Bend**: streaming decoder (about 25 MiB of memory at any size), segment-parallel encoder
  with deterministic output, about 2 % larger than `gzip -6`.
- **Safe extraction by default**: no absolute paths or `..`, no symlink following (`openat2` with
  `RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS`), contained hardlinks, no devices or FIFOs, size limits, setuid
  stripped for non-root.
- **Option parser**: all 173 GNU tar 1.35 options are recognised. 56 are implemented, 23 accepted
  with no effect, and 94 refused with exit 2 instead of being silently ignored
  ([docs/options.md](docs/options.md)).

## What is missing, or different from GNU tar

- Linux x86-64 only. Members and archives over **4 GiB** are refused (32-bit sizes in Bend).
- **No** sparse files, incremental (`-g`, `-G`), multi-volume, xattrs/ACLs/SELinux, `-h`, `-P`,
  `--one-file-system`, `--null`, `-i`, `-W`, `--to-command`, `--exclude-tag`.
- **No** bzip2, xz, zstd or `-I`; gzip only, with no level choice. Decoding is single-threaded.
- `--same-owner`, `--no-same-owner` and `--owner-map` are refused, so ownership is not restored on
  extract. Special files (devices, FIFOs) are skipped with a warning and exit 1. Times are whole
  seconds.
- `--transform` handles a POSIX BRE subset without back-references; glob classes such as
  `[[:alpha:]]` are not supported. `-u` appends in a different order than GNU.
- In-place edits are not atomic: a crash during `--delete` or `-A` can damage the archive.
- Known GNU differences are listed in [docs/append-update.md](docs/append-update.md),
  [docs/exclude.md](docs/exclude.md) and [docs/rewrite.md](docs/rewrite.md).

## Performance

Measured against GNU tar 1.35 for v1.2.0, on a 24-core Ryzen 9 7900X with tmpfs: btar is
**2–16× slower in wall time** (create 2–3×, list 6–12×, extract 3–16×; gzip operations are the
slow end). It uses 11 to 131 MiB of memory. The 1.3.0 additions are not benchmarked. Details are in
[bench/RESULTS.md](bench/RESULTS.md).

## Build and use

The project pins Bend 2.0.39 in `.cache/toolchain` (it never touches a global install). It needs
clang 14+, GNU tar, bsdtar, gzip and Python 3.11+ for the tests, and Lean v4.34.0 (via elan) for the proof check. `tools/ci.sh` downloads and
sha256-checks the toolchain and runs the gate:

```sh
./tools/ci.sh --quick          # about 2 minutes; --full adds ASan/UBSan, fuzzing, heavy proofs (about 8)
export PATH="$PWD/.cache/toolchain/bin:$PATH" && ./tools/run.sh build   # -> build/btar

./build/btar -czf backup.tgz -C ~/dir --sort=name .
./build/btar -tvf backup.tgz
./build/btar -xzf backup.tgz -C /tmp/restore
./build/btar -rf backup.tar -C ~/dir new-dir        # append (uncompressed)
./build/btar -cf src.tar --exclude='*.o' --transform='s,^src,project,' src
```

## Verification

Full release gate on 2026-10-30 (`./tools/ci.sh --full`): 17 of 17 sections pass, 0 skipped.

- Differential against GNU tar: create 21/21, gzip 37/37, extract 25/25, append/update 68/68,
  exclusion 208/208, members 30/30, rewrite 28/28, transform 54/54 (+ about 350 sed comparisons),
  diff 15/15, selection 18/18.
- Security corpus: 26/26 malicious archives, with no file written outside the extraction root.
- ASan/UBSan on list, extract, gzip and append: clean. Header fuzzing: 400/400 clean.
- Proofs: 17 laws in `bend proofs/PROOF.bend`, plus 15 heavy concrete laws. The `upd`, `glob`,
  `xform` and gzip modules are tested, not proven.
- This is differential and adversarial testing, not independent review or wide real-world use.

## Layout

`src/` pure Bend (the proof target) · `effs/` the only C · `app/` CLI · `laws/`, `proofs/` ·
`tests/` unit tests · `tools/` harnesses and gates · `docs/` design notes, man page `btar.1` ·
`plan/full-tar.md` the original plan.

MIT, see [LICENSE](LICENSE).
