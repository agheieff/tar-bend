# Sanity check of the v1.0.0 release (2026-10-25)

Independent re-verification of the v1.0.0 claims before the v1.1 work. Host: Arch Linux, 24 cores,
GNU tar 1.35, bsdtar 3.8.10, gzip 1.15, clang 23, project-local Bend 2.0.39.

## What reproduced

- Clean rebuild: `bend app/main.bend -o build/btar` gives the same sha256 as the packaged
  `dist/btar` (`867540fa…340d`, 1 528 344 B) — the build is reproducible. `btar --version` and
  `dist/btar --version` print `btar 1.0.0`; `tools/abi_check.sh` → `ABI OK`.
- Full release gate `./tools/test_release.sh`: **16/16 sections PASS, 0 skipped**, 2 m 43 s
  (create 21/21, gzip 27/27, diff 25/25, security 26/26, ASan 25+25, fuzz 400/400, proofs 17+15).
- `tools/bench_release.sh` reproduced every published number within ±2 %
  (create 37.0 ms, list 46.8 ms, extract 111.8 ms plain; gzip create 8.9 s / 557 MiB, list 8.0 s /
  313 MiB, extract 8.1 s / 313 MiB; ratio 61.4 % vs GNU 47.8 %).
- Spot checks that held: create operand policy (`./`, `/abs` and `..` refused with exit 2,
  duplicate operands archived twice, `--sort=name` byte-deterministic), cross-directory hardlink
  self round trip (same inode, nlink 2) for btar-made, `-czf`-made and GNU-made `./`-prefixed
  archives, symlink targets kept literal (`/etc/passwd`, `../../etc` not followed), FIFO warning →
  exit 1 with a valid archive (plain and `-czf`), `-` operand and missing archive → exit 2,
  junk/truncated archives → exit 2, 8 MiB `-czf` and 8 MiB compressed-read caps enforced with
  clear messages and no output file, ISIZE pre-check rejects a single 16 MiB+1 member in 2 ms and
  accepts exactly 16 MiB.

## Defects found (all fixed in v1.1.0)

| # | finding | evidence | v1.1 resolution |
|---|---|---|---|
| 1 | **The 16 MiB decompression cap was per member**, not per stream; the app's ISIZE pre-check only looks at the *last* member. A multi-member `.gz` bypassed it. | 6 members × 16 MiB zeros (96 MiB of output, 100 KB file) listed with rc 0 and **2.67 GiB RSS**; the 8 MiB compressed limit would allow ~500 such members (≈ 8 GB of output → OOM) | no whole-stream buffering at all: output streams through a pipe; the same file runs at 47 MiB RSS |
| 2 | **Quadratic header parsing** for many-member gzip: every header byte was fetched with an O(position) list walk. | a 100 KB file of 5 000 empty members took **31 s**, 200 KB took **120 s** (8 MiB would take hours) — a CPU DoS | decoder consumes bytes from the head of a list; 20 000 members now take < 1 s (release gate section 15) |
| 3 | **Archive inside the source tree was dumped into itself.** With an existing `self/me.tar`, `btar -cf self/me.tar -C self .` archived `me.tar` (truncated while being read) instead of skipping it; GNU tar prints `archive cannot contain itself; not dumped`. | listing showed `./me.tar` size 2560 inside the archive | writer compares each regular file's (dev, ino) with the archive's and skips it with GNU's message (plain and `-czf`) |
| 4 | **Plain create was quadratic** in the entry count (manifest appended one entry at a time). Not visible on the 412-entry benchmark tree. | 38 604 entries: **53 s** (GNU 0.55 s) | accumulate newest-first, reverse once: 2.2 s |
| 5 | Docs contradicted each other and the code: `docs/m5-gzip-integration.md` claimed 64 MiB caps and stored-only compression, `docs/gzip.md` 8/8/16 MiB, README "fixed Huffman only"; release notes quote 1 528 352 B vs 1 528 344 B for the same binary; usage text advertised caps. | grep | rewritten |

## Observations (not defects)

- `-czf` creates the output file only after the directory walk is collected, so walk errors do
  not clobber an existing archive; write errors after that leave a partial file (as GNU tar).
- The gzip decompressor rejects trailing bytes after the last member (GNU gzip only warns).
- `non-UTF-8` names list byte-exactly; human output of `-v` modes still prints names only.
- Archives made by btar are not padded to the 10 KiB blocking factor (GNU tar pads); both read
  fine everywhere tested.
- `git`: the working tree has no repository (the task brief says there is none); a backup of the
  v1.0.0 tree is at `/tmp/tar-bend-pre-claude.tar.gz`.

## Latent items checked and left as they are

- `grep TODO|FIXME` only finds `mktemp` templates and the documented unproven laws
  (L6/L8 forall, header-forall L1/L4) in `docs/proofs.md`.
- Effect error paths: every handle-taking effect returns the handle on failure (verified by the
  fuzz/ASan runs); `Stream.write_bytes`/`Data.copy` loop on short writes and EINTR; no partial
  state is visible after a failed `openat_file` (O_EXCL create).
