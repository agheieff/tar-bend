# M2 — streaming extractor + CLI (`btar -xf` / `-tf`)

Status: **M2 delivered**. Streaming reader/extractor in `src/read_stream.bend` +
`src/extract.bend`, CLI in `app/main.bend`; differential extraction and the security
manifest are green with the M2 binary. Pure policy modules `src/path.bend` and
`src/limits.bend` (owned by tar-parser) are wired in.

## Commands and observed results

```bash
export PATH=$PWD/.cache/toolchain/bin:$PATH        # bend 2.0.39
bend app/main.bend -o build/btar                   # builds (native, clang)
./build/btar -tf fixtures/generated/valid/dirs_nested.tar
# dirs/  dirs/nested/  dirs/nested/deep.txt  dirs/top.txt
./build/btar -xf fixtures/generated/valid/dirs_nested.tar -C /tmp/out
# /tmp/out/dirs/{nested/deep.txt,top.txt} with archive modes/mtime
./build/btar -tf ARCHIVE --strip-components=1      # names unchanged for -t
./build/btar -xf ARCHIVE -C DIR --strip-components=1
```

Harness results (native `build/btar`):

| check | command | result |
|---|---|---|
| differential extraction vs GNU tar | `BTAR=$PWD/build/btar ./tools/run_diff.sh` | **21/21** fixtures identical, `RESULT: PASS` |
| security policy corpus | `BTAR=$PWD/build/btar ./tools/run_security.sh` | **25/25** evil fixtures pass, **0 outside-root changes**, `RESULT: PASS` |
| listing vs GNU tar | loop `build/btar -tf` vs `tar -tf` | **20/20** compare equal; `non_utf8_name` prints the raw archive byte `0xE9` (GNU/bsdtar print `\351`; raw bytes are the documented plan behavior) |
| strip / CLI / exit codes | manual | `--strip-components=1` re-roots correctly; usage error and missing archive exit 2; `-C` creates nothing outside the root |

Integration caveat (outside this task's write scope): `tests/list_fixtures.sh` first runs
`bend --check-only app/main.bend`, which cannot pass once `app/` imports effects (Bend reports
"SOME PROOFS FAIL: defs rely on foreign effects" — same compiler behavior as the M0 probes).
The harness gate needs `bend app/main.bend -o /tmp/btar.c` (build-to-C type check) instead, and
the hardcoded `non_utf8_name` SKIP case can be dropped (output is now raw bytes). Likewise
`tools/run.sh check` checks every `*.bend` including effect-importing `app/` and
`src/read_stream.bend`; those need the build-to-C check. Both files are owned by tar-harness.
Also `src/extract.bend` reports the same foreign-code proof message on `--check-only` (expected).

## Streaming design (src/read_stream.bend)

- One driver def `drive(fuel: Nat, d: D) -> IO(Unit)`; D holds the archive/sink handles, the
  destination root *path bytes*, config, `Lim.State`, seen hardlink paths, global pax and the
  current state. Exactly one effect call per state, then a pure helper builds the next D — no
  mutual recursion, fuel shrinks every step.
- Header: `Stream.read_exact(archive, 512)`; short read = truncated header (exit 2); all-zero
  block = EOF (single-zero-block lenient, like M1); `H.parse` validates magic/checksum/numerics.
- Metadata `x`/`g`/`L`/`K`: payload read with `read_exact` (cap 64 KiB → `oversized_pax` refused),
  padded with `Data.copy` to the `/dev/null` sink, pax records parsed by `P.parse` (L/K payloads
  are plain NUL-trimmed bytes, **not** pax records), per-file overrides applied to the next entry.
  Malformed pax length prefix (overflow past U32) is refused by a dedicated first-record check
  (`pax_length_overflow`), which `P.parse` alone would silently drop.
- Payloads: `-t` skips `size + pad` bytes with `Data.copy` to the sink; `-x` copies exactly
  `size` bytes to the destination fd and then skips the `pad` bytes — **payload bytes never enter
  Bend**, only headers/pax records do.
- Offsets/limits are U32 with checked block math (`next_off`); sizes > U32 are rejected by the
  header parser (M1 rule), which also covers `bomb_huge_size_small_data`.

## Extraction design (src/extract.bend)

- Destination root is a *path*; each entry opens the root (`Fs.open_dir`), then descends one
  component at a time with `Fs.openat_dir` (`O_NOFOLLOW` + openat2
  `RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS`), creating missing parents `mkdirat(0755)`. A symlink
  planted mid-path is therefore never followed (`symlink_then_file_through_symlink` → exit 2).
- Pth policy runs in the driver: `Pth.strip(--strip-components)`, then
  `Pth.safe(255, 4096)` (absolute/`..`/NUL/overlong refused); `Lim.check_name`, `Lim.check_pax`,
  `Lim.add_member` enforce the name/pax/member/total limits. Every entry is counted;
  `component_255` accepted, `component_256`/`path_4097`/`absolute_path`/`dotdot_traversal`
  refused with exit 2.
- Regular files: `Fs.openat_file` (`O_CREAT|O_EXCL|O_NOFOLLOW`); on EEXIST `unlinkat` then retry
  (safe overwrite; duplicate_entries fixture). After the payload copy the file is closed, then
  `fchmodat(mode & 0777)` and `utimensat(mtime)` are applied (`--preserve-permissions` semantics
  are the default; setuid/setgid stripped by the 0777 mask).
- Directories: `mkdirat` (EEXIST tolerated) then chmod/utime; implicit parents are 0755.
- Symlinks: `Fs.symlinkat` with the raw target bytes (absolute targets allowed, as the plan and
  `absolute_symlink` manifest expect; the link is never traversed).
- Hardlinks: target must normalise safely, live in the *same parent directory* as the new name
  (the M2 effect set has same-dir `linkat` only), be a previously reachable entry and pass an
  `Fs.fstatat` regular-file check before `Fs.linkat` — `hardlink_escape`, `hardlink_to_symlink`
  and `one_top_level_hardlink_escape` are all refused; `hardlink.tar` and
  `duplicate_hardlink_targets` extract with the right inode groups.
- Special types (char/block/fifo/contig/other): listed fine by `-t`, refused by `-x` with exit 2
  before any file is created (`no-special-files` checks pass). M3 adds link policy hardening.
- Errors are fatal exit 2 with `btar: <reason>`; `-t` writes name bytes + `\n` through
  `Stdout.write` so non-UTF-8 names survive natively (JS lane returns ENOSYS as documented).

## CLI (app/main.bend)

`-t`, `-x`, `-f FILE`, combined `-tf`/`-xf`, `--list`, `-C DIR`, `-v`, `--strip-components=N`,
options before/after each other; args parsed via `IO.args_bytes` (byte-safe archive/C paths).
Exit 0 success, 2 fatal/usage. `-t` always prints names; `-x -v` prints each name before
extracting.

## Remaining gaps / next

- `tests/list_fixtures.sh` and `tools/run.sh check` need the effect-program check gate fixed
  (build-to-C instead of `--check-only`); `non_utf8_name` SKIP can be removed (raw bytes).
- `-C`/archive args are converted through a Bend `String` for option parsing (ASCII paths fine;
  byte-exact arbitrary paths need `IO.args_bytes` plumbing into the parser — M3 polish).
- No gzip (`-z`, M5), no create mode (M4), no global-pax application beyond retention, no
  `-p/--preserve-permissions` flag (preserve is the M2 default), 4 GiB/U32 cap.
- Hardlinks are same-directory only in M2; other cross-directory archive entries are refused
  with exit 2 (reported, not silently escaped).
- Performance: header per `read_exact` + one `Data.copy` per payload; no buffering layer yet.
  `Data.copy` measured at ~2.7 GB/s on 256 MiB in M0, so the streaming reader is I/O-bound.

## Lead integration note (2026-10-25)

- The effectful app cannot pass `bend --check-only` (foreign effects); gates now use
  `bend app/main.bend -o build/btar.c` as the compile check (`tools/run.sh check`,
  `tests/run_tests.sh`, `tests/list_fixtures.sh`).
- `tests/list_fixtures.sh` no longer skips `non_utf8_name.tar`: it compares raw member bytes while
  GNU tar escapes them, so listing is now 21/21 including the non-UTF-8 case.
- Fuzz found a real CLI-contract bug: fatal driver errors exited with the raw errno (e.g. 5 EIO).
  Fixed in `src/read_stream.bend` (`EvFail` → exit 2, 0=ok/2=fatal per plan §2.1); ASan fuzz gate now
  400/400 clean. The errno remains in the message.
- `tools/run.sh test` includes the ASan build/run and 200-case fuzz; full gate: `TEST GATE: ok`.
