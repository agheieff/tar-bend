# M7 — v1.0.0 release hardening (memory caps, `--version`, robustness, RSS)

> **v1.1.0 note:** the gzip caps and whole-stream buffering described in sections 1 and 3 below were
> removed by the streaming rewrite ([gzip.md](gzip.md)); the sanity check in
> [sanity-check.md](sanity-check.md) documents why (the 16 MiB cap was per member, header parsing was
> quadratic). The rest of this page (version flag, archive guards, robustness fixes) still applies.

Status: **delivered**. `btar 1.0.0`. Full gate green: `./tools/run.sh test` →
`TEST GATE: ok` (create 18/18, gzip 27/27, diff 25/25, security 26/26,
unit+proofs, ASan/fuzz). All documented caps fail closed with **exit 2** and a
clear message; `-czf` never leaves a partial/invalid output on a cap fatal.

## 1) gzip memory caps (v1 whole-stream buffering)

The v1 gzip path buffers whole streams in pure-Bend byte lists (no streaming
inflate/deflate yet), so release builds enforce three caps:

| cap | where enforced | message | exit |
|---|---|---|---|
| **8 MiB compressed input** | app, `Fs.fstatx` on the opened archive **before** `Stream.read_file` (`cap_file`, `gz_inflate`) | `btar: gzip input exceeds the 8 MiB compressed v1 cap` | 2 |
| **8 MiB uncompressed tar stream** (`-czf` only) | app, `Fs.fstatx` on the memfd dup **after** the tar writer finishes, before `Gz.compress` (`cap_file` in `dup_split`) | `btar: tar stream exceeds the 8 MiB uncompressed v1 cap (-czf)` | 2 |
| **16 MiB decompressed output** | app pre-check on the gzip trailer ISIZE (last 4 bytes LE) after reading the 8 MiB-capped input; plus post-decompress length check; plus `Gz`'s own `gz_cap()=16 MiB` (`GzSize`) | `btar: gzip output exceeds the 16 MiB decompressed v1 cap` | 2 |

Notes:
- The compressed cap is checked for both explicit `-z` and content
  auto-detect, because both funnel through `gz_inflate`.
- `-z` on non-gzip input remains a fatal error (`btar: -z given but the input
  is not gzip data`), as do corrupt/truncated/CRC/ISIZE failures.
- The ISIZE pre-check is an early, exact check for single-member streams; for
  multi-member streams (`decompress` supports them) it only reflects the last
  member, and the `Gz` output cap / post-decompress length check still apply.
- **No partial output**: gzip create opens/truncates the output file only after
  collect + memfd write + cap checks + `Gz.compress` have all succeeded, so a
  cap fatal leaves no output file (verified `out_exists=no`). Plain `-cf` is
  streaming; a fatal mid-write there can leave a partial tar and is documented
  as-is (exit 2, no archive truncate/remove recovery).
- `-czf` warning trees (unsupported entries) still finish a valid gzip archive
  and exit 1 when under the caps; if such a tree also exceeds the tar cap the
  run is fatal exit 2 with **no** output (warning message may be printed first).

Evidence:
```
# 9 MiB random tar.gz (9,438,868 B compressed)
btar -tzf big.tar.gz          -> "btar: gzip input exceeds the 8 MiB compressed v1 cap", exit 2
btar -z -tf big.tar.gz        -> same (explicit -z), exit 2
btar -tzf mid.tgz             # 8,001,495 B compressed -> pre-check passes, lists OK, exit 0

# -czf on a 9 MiB source tree (tar stream > 8 MiB)
btar -czf out9.tgz -C src9 .  -> "btar: tar stream exceeds the 8 MiB uncompressed v1 cap (-czf)",
                                 exit 2, out9.tgz absent
# 7.9 MiB source: rc 0, gzip -t OK

# 17/20 MiB decompressed, compressed input tiny (0x41 runs, gzip -9)
btar -tzf zz.tar.gz           -> "btar: gzip output exceeds the 16 MiB decompressed v1 cap", exit 2
# 15 MiB decompressed -> lists OK exit 0; 16 MiB boundary enforced by pre-check + Gz cap
```

## 2) `--version` / `-V`

```
btar --version   -> btar 1.0.0   (stdout, exit 0)
btar -V          -> btar 1.0.0   (stdout, exit 0)
btar -V -tf x    -> btar 1.0.0   (version wins, exit 0, nothing else runs)
```
Detection scans raw byte argv before dispatch, so it is byte-safe and works
in any position. Usage strings now include `[--version]` and a one-line caps
summary.

## 3) Robustness pass

- **Missing archive**: `btar -tf /nope.tar` →
  `btar: cannot open archive '/nope.tar': No such file or directory`, exit 2
  (previously a bare `No such file or directory`).
- **`-` archive/operand**: `btar -tf -`, `btar -cf - ...` →
  `btar: '-' (stdin/stdout) is not supported as an archive or operand in v1`,
  exit 2 (previously a generic usage error).
- **Fatal mid-write**: plain `-cf` writes the output file directly (streaming);
  a fatal error mid-write leaves a partial file (documented, exit 2). `-czf`
  is not affected: its output file is created only after all buffered work
  succeeds (cap/warning/compression), so fatal paths leave no output.
- **Warnings**: `-czf` under the caps still produces a complete valid gzip
  archive containing supported entries and exits 1 (`gzip -t` rc 0, GNU tar
  readable); cap fatals override warnings with exit 2 and no output.
- No behavior regressions: create 18/18, gzip 27/27, diff 25/25 (+ `-p`, `-O`),
  security 26/26 with 0 outside-root changes, ASan 25/25 clean, fuzz 400/400.

## 4) Peak RSS / perf evidence (1 MiB tree)

Measured with `os.posix_spawn` + `os.wait4` per child (`ru_maxrss`), tree = one
1 MiB random file + one small text file, `/tmp` tmpfs, current `build/btar`:

| operation | wall | peak RSS |
|---|---|---|
| plain `-cf` create | 2 ms | 15.8 MiB |
| plain `-tf` list | 1 ms | 15.8 MiB |
| plain `-xf` extract | 2 ms | 15.8 MiB |
| `-czf` create (memfd + pure-Bend gzip) | 2282 ms | 129.0 MiB |
| `-tzf` list | 173 ms | 78.6 MiB |
| `-xzf` extract | 171 ms | 78.5 MiB |

Interpretation: plain mode is streaming (≈ process baseline, open/close + one
listed file). Gzip mode is bounded by the documented caps: ≤8 MiB compressed
input / ≤8 MiB uncompressed tar + ≤16 MiB decompressed output held as pure
Bend `List<U32>` terms, which is why peak RSS is tens of MiB even for a 1 MiB
tree (pure-list cell overhead), and why the 8 MiB create-tar cap exists — it
keeps `-czf` well away from the previous ~350 MB unbounded peak. The
compressed-input cap now also makes gzip reads fail fast instead of inflating
arbitrarily large streams.

Closest GNU reference on the same tree: `gzip -t`/`tar -xzf` are C
implementations with ~1–2 MiB RSS; the gap is the known whole-stream
pure-Bend v1 architecture (streaming/packed-bytes is the follow-up).

## Gates / evidence

```
bend app/main.bend -o build/btar                         # rc 0
btar --version / -V                                      # btar 1.0.0, exit 0
BTAR=$PWD/build/btar ./tools/test_create.sh              # 18 pass, 0 fail, 0 skip
BTAR=$PWD/build/btar ./tools/test_gzip.sh                # 27 pass, 0 fail, 0 skip
BTAR=$PWD/build/btar ./tools/run_diff.sh                 # 25/25 (+ -p, -O)
BTAR=$PWD/build/btar ./tools/run_security.sh             # 26/26, 0 outside-root
bash tests/run_tests.sh                                  # PASS
./tools/run.sh test                                      # TEST GATE: ok
```

## Files changed (M7)

- `app/main.bend`: `--version`/`-V` gate, `-` archive/operand gate, clearer
  missing-archive message, `cap_file`/`cap_after` (fstatx size cap returning
  the handle), compressed-input cap in `gz_inflate`, tar-stream cap in
  `dup_split` (`-czf`), gzip trailer ISIZE pre-scan (`iz_run` 4-byte rolling
  window) + post-decompress length check for the 16 MiB decompressed cap,
  clearer `GzSize` message, usage text with caps/version.
- No new effects were needed (`Fs.fstatx`/`Fs.stat_path` from M6 suffice); no
  files outside the M7 write scope were touched.

## Gaps / next

- Gzip remains whole-stream buffered in pure Bend (v1 caps are the mitigation);
  streaming inflate with packed bytes is the follow-up.
- ISIZE pre-check covers the common single-member gzip; multi-member streams
  rely on the `Gz` 16 MiB cap and the post-decompress length check.
- Plain `-cf` fatal mid-write can leave a partial archive (streaming trade-off;
  documented, exit 2).
- `-` archives (stdin/stdout) and `--exclude`/`--no-recursion` are out of v1
  scope.

## Release-blocker fix: hardlink targets with `./` (task-29)

Symptom (found by the release benchmark): extracting a hardlink whose stored
linkname had a leading `./` failed with `btar: hardlink target: Invalid
argument` — both plain and gzip, including archives created by btar itself
(our writer stores `./hard`-style targets for a `.`-rooted walk, as GNU tar
does). `X.split_last("./a")` produced a `.` parent component that the dirfd
walk/`fstatat` rejects, and the seen-path lookup missed.

Fix in `src/read_stream.bend` (`hard_target`): hardlink targets are now
normalised through `Pth.safe(max_component(), max_total(), target)` before
`split_last`, the seen lookup and the dirfd walk — empty/`.` components are
dropped, and absolute paths, `..` traversal, overlong paths and bad components
are refused with `btar: hardlink target unsafe: <reason>` (fatal exit 2, no
outside-root writes). Symlink targets stay **literal** (not normalised) —
verified `./t` and `sub/../t` symlink targets round-trip verbatim.

Evidence (current `build/btar`):
```
# own writer -> own extractor, root/nested/cross-dir hardlinks, plain + gzip:
btar -cf o.tar -C src .   ; btar -xf o.tar -C out    # rc 0
btar -czf o.tgz -C src .  ; btar -xzf o.tgz -C out   # rc 0
find out -type f -printf '%i %n %p\n'                # pairs share inode, nlink=2
# GNU-created archive:  tar -cf gnu.tar -C src . ; btar -xf gnu.tar -C gout  # rc 0
# security fixtures stay fatal:
btar -xf fixtures/generated/evil/hardlink_escape.tar -C /tmp
  -> btar: hardlink target unsafe: parent traversal refused   (exit 2)
btar -xf fixtures/generated/evil/hardlink_to_symlink.tar -C /tmp
  -> btar: hardlink target is not a regular file              (exit 2)
# symlinks stay literal: readlink out/rel == "./t", readlink out/weird == "sub/../t"
```
Regressions green after the fix: create 18/18, gzip 27/27, diff 25/25 (+ -p,
-O), security 26/26 with 0 outside-root changes, `./tools/run.sh test` →
`TEST GATE: ok`.
