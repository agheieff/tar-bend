# Release verification — tar-bend v1.2.0

Final release gate and benchmark for `btar` v1.2.0 (Bend 2.0.39, Linux x86-64). v1.2.0 adds
append/update, exclusion and CI on top of the v1.1.0 release ([release-notes-1.1.0.md](release-notes-1.1.0.md),
independent sanity check in [sanity-check.md](sanity-check.md)); 1.0.0 evidence is in the
[1.0.0 release notes](release-notes-1.0.0.md).

Artifact under verification: `build/btar` v1.2.0, **1,898,112 bytes**, ELF 64-bit LSB pie,
sha256 `b717df5770e8ad87830d447ba45b1ecad895072babf0bf19a41731e9ac53fca6`. The packaged `dist/btar` is byte-identical (checked by `tools/package.sh` and
re-verified with `cmp`); package hashes are in `dist/SHA256SUMS` (the single source for package
hashes — this document does not embed them).

## 1. Release gate — `./tools/test_release.sh`

```
test_release: mode=full sections=17 skip=0 fail=0
RESULT: PASS (release gate; 0 skipped section(s) documented above)
```

| # | section | command | result |
|---|---|---|---|
| 1 | toolchain pin | `bend version` | `bend 2.0.39` |
| 2 | effect ABI | `tools/abi_check.sh` | `ABI OK` (unchanged; 3 new effects are registered the same way) |
| 3 | native build | `bend app/main.bend -o build/btar` | 1,898,112 B ELF |
| 4 | release version | `build/btar --version` | `btar 1.2.0` |
| 5 | pure core + app compile | `bend --check-only` (16 pure modules incl. `upd`, `glob`) + app compile | PASS |
| 6 | proofs | `PROOF.bend` + `--verdict` + `PROOF_HEAVY.bend` | ALL PROOFS CHECK (17 + 15) |
| 7 | unit suites | `tests/run_tests.sh` (incl. `test_upd`, `test_glob`) | RESULT: PASS |
| 8 | fixture determinism | 72 fixture sha256 values | unchanged |
| 9 | create harness | `tools/test_create.sh` | 21 pass, 0 fail, 0 skip |
| 10 | gzip harness | `tools/test_gzip.sh` | 37 pass, 0 fail, 0 skip |
| 11 | append / exclude harnesses | `tools/test_append.sh`, `fuzz_append.py`, `test_exclude.sh` | test_append 68/68, fuzz_append 300/300, test_exclude 208/208 |
| 12 | M6 aggregate | `tools/test_m6.sh` | 4 pass, 0 fail, 0 skip |
| 13 | extract differential | `BTAR=build/btar tools/run_diff.sh` | 25/25 identical |
| 14 | security corpus | `BTAR=build/btar tools/run_security.sh` | 26/26, 0 outside-root; exit classes 0=5 / 1=6 / 2=15 |
| 15 | ASan/UBSan + fuzz | `build_asan.sh`, `run_asan.sh`, `fuzz_headers.py`, `fuzz_append.py` | list 25/25, extract 25/25, gzip 14/14, append 25/25 clean; header fuzz 400/400, 0 findings; append fuzz 120/120 |
| 16 | gzip streaming bounds | bomb / multi-member / 20 000-member / corrupt CRC | bounded, exit 2, no OOM; PASS |
| 17 | release artifact | sha256 / file type | `b717df57…fca6`, ELF pie |

The gate-built binary is reproducible (`bend app/main.bend -o build/btar` re-run to the same sha).

### Evidence added in 1.2.0

- **Append/update vs GNU tar** (`tools/test_append.sh`, **68 passed, 0 failed**): same exit status; original bytes
  preserved up to the old logical end; exact 1024-byte trailer (independent oracle
  `tools/tar_end.py`); GNU tar and bsdtar read the result; normalised listing and extracted tree equal;
  corrupt/garbage/bad-checksum/truncated/gzip archives, missing/absolute/`..` operands, `-z`,
  option clashes, directory and `-` archives → exit 2 with the archive byte-identical.
- **Mutation fuzz** (`tools/fuzz_append.py`, **300/300 clean** (release binary), **120/120 clean** (ASan binary)): exit ∈ {0,1,2}; exit 2 ⇒ untouched; success ⇒
  prefix + trailer intact and GNU readability preserved.
- **Exclusion** (`tools/test_exclude.sh`, **208 passed, 0 failed**): 129 pattern/name list comparisons plus
  create/append/update/list/extract, gzip, pattern files, `--strip-components` regressions.
- **ASan/UBSan** over `-rf`/`-uf` on every valid fixture: **25/25 clean** (`-rf` + `-uf`).
- **Scale**: unchanged 20 101-entry tree, `-u` check 1.1 s (GNU 0.04 s); `-r` of one directory into the
  20 MiB archive 0.5 s.

## 2. Benchmark — `./tools/bench_release.sh` → [bench/RESULTS.md](../bench/RESULTS.md)

Host: 24-core Ryzen 9 7900X, 61.9 GiB RAM, Linux 7.2.11 (Arch), tmpfs `/tmp`, warm cache; GNU tar
1.35, gzip 1.15, Bend 2.0.39. Median wall time; peak RSS via `wait4`. The 1.1.0 → 1.2.0 deltas are
within the 20 % rule, but the gzip *create* rows moved most (+8 % small, +14 % large; a second
3-repetition large run gave 6.45 s again, the first 1.2.0 run 5.63 s), so it was A/B-checked: the
packaged 1.1.0 binary and the 1.2.0 binary, alternating, `-czf` of the same 122 MiB tree
(`/usr/share/man`, 3 runs each): **1.1.0 42.6 / 40.0 / 39.5 s, 1.2.0 39.5 / 39.7 / 39.9 s** — no
difference. The delta is machine-state noise in the multi-threaded compressor, not the code (the
`-czf` path only gained a `Fs.trunc_cur` call that is a no-op on a pipe).

### Small workload (5.1 MiB, 412 entries)

| operation | btar ms | btar RSS MiB | GNU ms | GNU RSS MiB | btar/GNU | 1.1.0 btar ms |
|---|---:|---:|---:|---:|---:|---:|
| create plain | 19.5 | 11 | 6.1 | 11 | 3.20× | 19.5 |
| create gzip | 142.7 | 119 | 44.5 | 11 | 3.21× | 132.1 |
| list plain | 11.2 | 11 | 1.8 | 11 | 6.22× | 11.4 |
| list gzip | 112.4 | 28 | 8.9 | 11 | 12.63× | 108.3 |
| extract plain | 58.1 | 11 | 7.4 | 11 | 7.85× | 61.8 |
| extract gzip | 168.7 | 28 | 10.5 | 11 | 16.07× | 167.0 |

Archive size: plain 5,520,896 B (GNU 5,529,600 B); gzip 2,647,557 B = **48.0%** of plain
(GNU 2,644,306 B = 47.8%) — identical to 1.1.0.

### Large workload (160.0 MiB, 3401 entries)

| operation | btar ms | btar RSS MiB | GNU ms | GNU RSS MiB | btar/GNU | 1.1.0 btar ms |
|---|---:|---:|---:|---:|---:|---:|
| create plain | 199.1 | 13 | 100.0 | 11 | 1.99× | 193.3 |
| create gzip | 6497.9 | 131 | 2267.7 | 11 | 2.87× | 5658.9 |
| list plain | 98.4 | 11 | 9.6 | 11 | 10.25× | 95.9 |
| list gzip | 3716.1 | 26 | 459.1 | 11 | 8.09× | 3595.4 |
| extract plain | 272.5 | 11 | 100.7 | 11 | 2.71× | 286.8 |
| extract gzip | 3935.4 | 26 | 460.1 | 11 | 8.55× | 3781.6 |

Archive size: gzip 89,220,462 B = 52.4% of plain (GNU 51.5%). Reading a 160 MiB GNU-made `.tar.gz`
uses ~26 MiB RSS; memory is independent of archive size (streaming). `-czf` memory scales with
threads, bounded via `BENDRTS="--threads N"` or `+RTS --threads N -RTS`.

Append/update scale check (20 101-entry, 20 MiB tree): `-rf` of one 200-file directory 0.5 s;
`-uf` of the unchanged tree 1.1 s (GNU tar 0.04 s) — dominated by building the archive table in Bend.

## 3. Sanity-check findings fixed in 1.1.0 (carried forward, still covered)

Full details/evidence: [sanity-check.md](sanity-check.md).

| # | v1.0.0 defect | v1.1.0 resolution |
|---|---|---|
| 1 | 16 MiB decompression cap was per member; multi-member gzip bypassed it (96 MiB output → 2.67 GiB RSS; possible OOM via 8 MiB compressed input) | streaming decode, no caps; same file ~47 MiB RSS |
| 2 | quadratic gzip header parsing (5 000 members: 31 s; 200 KB: 120 s; CPU DoS) | head-of-list byte consumption; 20 000 members < 1 s (gate §15) |
| 3 | archive inside source tree dumped into itself (truncated while read) | writer skips its own `(dev, ino)` with GNU's message |
| 4 | plain create quadratic in entry count (38 604 entries: 53 s vs GNU 0.55 s) | newest-first manifest + one reverse: 2.2 s |
| 5 | docs contradicted code/each other (caps, stored-only, binary sizes) | all docs rewritten to v1.1 implementation |

## 4. Release checklist (1.2.0)

- [x] Phase 0: rebuilt 1.1.0 (`f28146d0…580b` reproduced) and `--quick` gate green before any change.
- [x] `-r`/`-u` landed with differential + error + fuzz + ASan coverage ([append-update.md](append-update.md)).
- [x] `--exclude`/`--exclude-from`/`-X`/`--no-recursion` for create/append/update/list/extract
      ([exclude.md](exclude.md)).
- [x] Three pre-existing extraction bugs fixed with regression cases (see release notes).
- [x] `tools/ci.sh` + `.github/workflows/ci.yml` ([ci.md](ci.md)); `./tools/ci.sh --quick --no-install`
      run locally.
- [x] `./tools/test_release.sh` full → **PASS, 17/17 sections, 0 fail, 0 skip**.
- [x] `./tools/bench_release.sh` regenerated `bench/RESULTS.md` for 1.2.0 (no regression > 20 %).
- [x] Docs: README, man page, format-support, security-model, effects, testing-harness, status,
      release notes, plan.
- [x] `tools/package.sh`; `dist/btar` equals `build/btar`; `dist/SHA256SUMS` written.
- [ ] Not done (documented): signing/publishing, a first real GitHub Actions run, `-A`/`--delete`/`-d`,
      `-T`, `--transform`, >4 GiB.

## 5. Known limitations / waivers (v1.2.0)

- **gzip read/list** is single-threaded and still 8–15× slower than GNU tar; plain list/extract 6–11×
  on the small tree (see §2). Unchanged from 1.1.0.
- **Compression memory** grows with threads (see 1.1.0 notes); output is independent of thread count.
- `-r`/`-u`: uncompressed archives only, in-place (no locking/crash atomicity), `-u` order differs
  from GNU, whole-second mtime comparison; exclusion is a documented wildcard subset with global
  (not positional) option scope.
- ≤4 GiB member/archive (U32); no sparse files, device nodes, ACL/xattr/SELinux, `-A`/`--delete`/
  `-d`/`-T`/`--transform`, incremental/multi-volume, `--sort=inode`, stdin/stdout `-` archives.
- No C ABI/library; Linux x86-64 only. Archives are not padded to GNU's 10 KiB blocking factor
  (an appended-to GNU archive loses its padding).
- uid/gid numeric, uname/gname empty; mtime second granularity; special entries skipped with warning.
- Effects (now including `open_rw`/`seek`/`trunc_cur`) and the gzip pump remain trusted/tested (not
  proven); `upd` and `glob` are unit/differentially tested, not proven. See
  [security-model.md](security-model.md) and [proofs.md](proofs.md).
- CI is unexercised on GitHub; no signing or publishing.

## 6. Release artifacts and reproduction

`tools/package.sh` writes the binary package, source package and checksums. Authoritative hashes
for **all** artifacts live in `dist/SHA256SUMS` (not repeated here); the binary is
`sha256 b717df5770e8ad87830d447ba45b1ecad895072babf0bf19a41731e9ac53fca6`.

```
dist/btar                          native binary (== build/btar)
dist/btar-1.2.0-linux-x64.tar.gz   binary package
dist/tar-bend-1.2.0-src.tar.gz     source package
dist/SHA256SUMS                    checksums for the three files above
```

The binary package contains `btar`, `README.md`, `LICENSE`, `VERSION`, `btar.1`, the `docs/` tree,
`plan/full-tar.md` and `bench/RESULTS.md`; the source package contains the full tree (including
`tools/ci.sh` and `.github/`) minus `.cache/`, `build/`, `dist/`, `.git/`, `__pycache__` and generated
fixtures. The 1.1.0 packages are not kept in `dist/`.

```console
$ export PATH=$PWD/.cache/toolchain/bin:$PATH
$ ./tools/ci.sh --full                     # installs the pinned toolchain if needed, runs the gate
$ ./tools/test_release.sh --verbose        # full gate (17 sections)
$ ./tools/test_release.sh --quick          # fast pre-check
$ ./tools/bench_release.sh                 # benchmark -> bench/RESULTS.md
$ ./tools/test_append.sh && ./tools/test_exclude.sh && python3 tools/fuzz_append.py
$ python3 tools/test_gzip_stream.py build/btar   # large gzip streaming interop/memory
$ ./tools/package.sh                       # dist/ + SHA256SUMS
$ sha256sum build/btar dist/btar           # both hashes must match
```
