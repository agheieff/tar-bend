# btar 1.2.0 — release notes

Release date: 2026-10-25 · Linux x86-64 · Bend 2.0.39 · MIT.
Builds on [1.1.0](release-notes-1.1.0.md) (streaming/parallel gzip); nothing from 1.1.0 was redone.

This release is the **feature tier** after the performance pass: in-place append and update,
exclusion patterns, a CI entry point, and three extraction bugs found while testing them.

## Highlights

- **`-r` / `--append`** — append to an existing *uncompressed* archive (or create it): the old
  entries stay byte for byte, new entries overwrite the end-of-archive blocks, a fresh trailer is
  written and the stale tail is cut. The archive is validated first by a read-only scan; a
  corrupt, truncated, gzip or sparse/sized-link archive is refused with exit 2 and **left
  untouched**. Supports `-C`, `-v`, `-p`, `--format`, `--sort=name`, multiple operands, GNU operand
  policy, hardlink detection within the appended set, `--exclude*`, `--no-recursion`.
  [docs/append-update.md](append-update.md)
- **`-u` / `--update`** — appends only new names and entries whose mtime (whole seconds) is newer
  than every archived copy; archived directories are never re-added (GNU rule); type changes are
  appended. An O(log n) hash-keyed tree keeps a 20 101-entry no-op update at ~1.1 s (a plain list
  took 21 s).
- **`--exclude=PAT` / `--exclude PAT`, `--exclude-from=FILE` / `-X FILE`, `--no-recursion`** in
  create, append, update, list and extract, with a pure-Bend matcher that reproduces GNU's
  default semantics (unanchored, wildcards match `/`, leading-directory match, `[set]`, `\`
  escapes). 129 pattern × name cases match GNU tar 1.35 exactly. [docs/exclude.md](exclude.md)
- **CI**: `tools/ci.sh` (installs the sha256-pinned Bend 2.0.39, checks host tools, runs the
  release gate; `--quick` ≈ pull-request mode) and `.github/workflows/ci.yml`. Local equivalent:
  `./tools/ci.sh --quick`. [docs/ci.md](ci.md)
- Three new IO-only effects (`Fs.open_rw`, `Stream.seek`, `Fs.trunc_cur`, [effects.md](effects.md) §8);
  all append/update *policy* is pure Bend (`src/upd.bend`, the scanner state machine in
  `src/append.bend`). The ABI gate is unchanged (`ABI OK`).

## Bugs fixed (all pre-existing in 1.1.0; extraction side)

1. `btar -xf a.tar --strip-components=1` printed the create usage and exited 2 — the create-mode
   detector took any option token containing a `c` (`--strip-components`). Mode letters are now
   read from single-dash bundles only. (No gate covered `--strip-components` through the CLI.)
2. `--strip-components=N` on a regular file whose whole name is stripped skipped its payload
   without the padding (`checksum mismatch`, exit 2 on the next header).
3. `--strip-components=N` was not applied to hardlink targets (`hardlink target: No such file or
   directory`); an entirely stripped hardlink entry is now skipped like GNU does.

Regression cases: `tools/test_exclude.sh` (section C `--strip-components=1/2`, hardlinks) and
`tools/test_append.sh` (`e-strip-comp-still-works`).

## Verification

`./tools/test_release.sh` → **PASS, 17/17 sections, 0 fail, 0 skip** on the frozen build (`btar 1.2.0`, 1,898,112 bytes,
sha256 `b717df5770e8ad87830d447ba45b1ecad895072babf0bf19a41731e9ac53fca6`). New evidence on top of the 1.1.0 suites:

| harness | result |
|---|---|
| `tools/test_append.sh` (append/update vs GNU tar + error cases) | **68 passed, 0 failed** |
| `tools/fuzz_append.py` (release binary / ASan binary) | **300/300 clean** (release binary), **120/120 clean** (ASan binary) |
| `tools/test_exclude.sh` (matcher + create/append/update/list/extract) | **208 passed, 0 failed** |
| `tests/test_upd.bend`, `tests/test_glob.bend` | unit suites PASS |
| ASan/UBSan append phase over the 25 valid fixtures (`-rf` + `-uf`) | **25/25 clean** (`-rf` + `-uf`) |

Unchanged and still green: proofs 17 + 15 `ALL PROOFS CHECK`, create 21/21, gzip 37/37, extract
diff 25/25, security 26/26 with 0 outside-root changes, ASan/UBSan list/extract/gzip, header fuzz
400/400, fixture determinism, ABI check. Full table: [release-verification.md](release-verification.md).

Performance did not change beyond noise (create/list/extract plain, small and large workloads;
[bench/RESULTS.md](../bench/RESULTS.md)). Binary: 1,580,352 → 1,898,112 bytes.

## Known gaps / risks

- `-r`/`-u`: uncompressed archives only; no `-A`, `--delete`, `-d`; appended order under `-u`
  differs from GNU (same set of entries); no locking or crash atomicity during an in-place append;
  `-u` compares whole seconds (GNU also compares the fraction for pax archives).
- Exclusion: wildcard subset only (no POSIX classes, `--anchored`, VCS/tag excludes); `-X` is not
  accepted inside a bundle; options after operands apply globally (GNU applies them positionally).
- Still open from earlier releases: >4 GiB, `-T`, `--transform`, stdin/stdout `-`, incremental,
  sparse, ACL/xattr, bzip2/xz/zstd, multi-thread gzip *decoding*, proof depth (general-forall laws
  for L1/L4/L6/L8; `upd`/`glob` are unit-tested, not proven).
- CI is prepared but unexercised here: the project has no git remote and the sandbox cannot run
  GitHub Actions. No signing keys, release publishing or artifact attestation are configured
  ([ci.md](ci.md) lists what is missing).
