# M6 — create/CLI hardening (`PATH...` operands, `--sort=name`, gzip warnings, perf)

> **v1.1.0 note:** gzip create/read are now streaming and parallel (see [gzip.md](gzip.md)); the
> performance and ratio remarks about stored-DEFLATE / whole-stream buffering below are historical.

Status: **delivered**. Full gate green: `./tools/run.sh test` → `TEST GATE: ok`
(create **18/18**, gzip **26 pass / 0 fail / 1 skip** (compression-ratio only),
diff 25/25, security 26/26, unit+proofs, ASan/fuzz).

## 1) Arbitrary create operands

```
btar -cf ARCHIVE [opts] PATH...          # zero/many operands, from cwd
btar -cf ARCHIVE -C DIR [opts] PATH...   # operands resolved under DIR
btar -cf ARCHIVE -C DIR .                # whole tree, GNU-compatible "./..." names
```

- Operands may be files, directories (recursed), symlinks; multiple operands
  and duplicates are archived in CLI order (GNU behavior). A directory operand
  emits its own `name/` entry then its subtree.
- Archive names are the operand spelling relative to `-C` (GNU semantics):
  `a.txt` → `a.txt`, `./a.txt` → `./a.txt`, `.` → `./` root entry with `./…`
  children, `dir` → `dir/…`. Empty operand list defaults to `.`.
- **Preflight before output**: every operand is validated (absolute paths and
  any `..` component are refused; must exist/lstat) before the archive file is
  opened, so a missing/refused operand is fatal exit 2 and writes **nothing**
  (`out_exists=no` in evidence).
- Hardlink detection is global across operands and recurse trees (same
  `(dev,ino)` → typeflag `'1'` with the first archived name as link target).
- Byte-safe argv maintained (`IO.args_bytes`); paths never go through `String`.

Evidence:
```
(cd tree && btar -cf op1.tar a.txt sub lnk)   -> rc 0: a.txt, sub/b.txt, lnk
btar -cf op2.tar -C tree a.txt sub            -> rc 0: a.txt, sub/, sub/b.txt
btar -cf op3.tar -C tree ./a.txt ./sub        -> rc 0: ./a.txt, ./sub/, ./sub/b.txt
btar -cf op5.tar -C tree sub                  -> rc 0: sub/, sub/b.txt (GNU parity)
btar -cf h.tar -C h d/orig link               -> rc 0: d/orig regular, link -> d/orig
btar -cf miss.tar -C tree nope                -> exit 2, no archive created
btar -cf abs.tar -C tree /etc/passwd          -> exit 2 "operand refused"
btar -cf dd.tar -C tree ../tree               -> exit 2 "operand refused"
```
`tools/test_create.sh` new M6 cases all pass: `operands-C`, `operands-cwd`,
`operands-dot`, `duplicates`, `absolute-operand`, `missing-operand`
(18 pass, 0 fail, 0 skip).

## 2) `--sort=name` deterministic ordering

- `--sort=name` (create only; also stripped for `-t/-x`, where it is a no-op)
  sorts every directory's readdir names by **raw name bytes** before recursing.
  Default stays readdir order.
- Deterministic bytes across runs; GNU `tar --sort=name` listing parity verified.
- Implemented as an insertion/selection over `List<List<U32>>` name bytes in
  `src/write.bend` (`sort_names`, `maybe_sort` in the collect frame builder), so
  hardlink targets are still the first entry in the *sorted* traversal.
- Known limitation: duplicate operands under `--sort=name` share parent keys, so
  their subtree groups can interleave; single `.` / distinct operand trees are
  deterministic (documented v1).

Evidence:
```
btar --sort=name -cf s1.tar -C tree . ; btar --sort=name -cf s2.tar -C tree .
sha256sum s1.tar s2.tar
fcf711e67f23b5a90d255648d454e8f080fb256fd14f497c19ed9d888bcc11ff  s1.tar
fcf711e67f23b5a90d255648d454e8f080fb256fd14f497c19ed9d888bcc11ff  s2.tar
tar --sort=name -cf sg.tar -C tree .   # tar -tf outputs identical to ours
btar -cf s3.tar ... -> different sha256 (default readdir order preserved)
```

## 3) gzip warning semantics (`-czf` + unsupported entries)

Previously `-czf` exited 1 from inside the create writer *before* the gzip
output existed. Now the two phases are separated in the app:

1. preflight operands → collect manifest (warnings become kind-99 skip entries),
2. write the tar stream to the memfd and get back a `warned: Bool` from
   `Wr.write_to` (no process exit in the writer),
3. read the memfd, `Gz.compress`, write the **complete valid gzip archive**,
   close the output, and only then `Wr.exit_w(warned)`.

So `-czf` on a tree with e.g. a FIFO: archive contains all supported entries,
`gzip -t` passes, GNU tar reads it, and the process exits 1. Corrupt/fatal I/O
still exits 2. Plain `-cf` warnings keep the M4 behavior (valid tar + exit 1).

Evidence:
```
mkdir wt; printf ok > wt/ok; mkfifo wt/fifo
btar -czf wt.tgz -C wt .        # stderr: skipping unsupported file type: ./fifo
rc=1  gzip -t rc=0  tar -tzf -> ./ ./ok
```

## 4) Create performance / memory

Measured with current build (`build/btar`, python `subprocess` timings, maxrss
of children), 5.1 MiB tree (1 MiB pseudo-random file + 4 MiB sparse-ish hole
file + small files), `/tmp` tmpfs:

| operation | wall | maxrss |
|---|---|---|
| plain `-cf` | 3 ms | 14.7 MB |
| `--sort=name -cf` | 3 ms | 14.7 MB |
| `-czf` (memfd + pure-Bend stored gzip) | 1492 ms | 349.9 MB |
| `-tzf` own archive | 737 ms | 349.9 MB |
| `-xzf` own archive | 737 ms | 349.9 MB |

Plain create is streaming with no whole-archive buffering (memory ~ process
baseline). Gzip create keeps the v1 documented whole-stream memfd buffering:
the tar stream + gzip bytes are held as pure Bend `List<U32>` terms, which is
the source of the ~350 MB peak for a 5 MiB tree (pure-list cell overhead);
`Gz` output/decompress caps remain 64 MiB / 64 MiB. This is the main perf gap
(streaming/packed bytes is M6-follow-up material). `tools/test_gzip.sh` timing
check passes (1.4 MB tree: create 264 ms, list 293 ms, extract 369 ms).

## Gates / evidence

```
bend app/main.bend -o build/btar                         # rc 0
BTAR=$PWD/build/btar ./tools/test_create.sh              # 18 pass, 0 fail, 0 skip
BTAR=$PWD/build/btar ./tools/test_gzip.sh                # 26 pass, 0 fail, 1 skip
BTAR=$PWD/build/btar ./tools/run_diff.sh                 # 25/25 (+ -p, -O)
BTAR=$PWD/build/btar ./tools/run_security.sh             # 26/26, 0 outside-root
bash tests/run_tests.sh                                  # PASS
./tools/run.sh test                                      # TEST GATE: ok
```

## Files changed

- `app/main.bend`: multi-operand create flow, `--sort=name` parse/strip,
  `--sort` flag plumbing, preflight-then-collect-then-write create for plain and
  gzip (`Wr.preflight` / `Wr.collect` / `Wr.write_to` returning `warned`),
  gzip warning exit now after the compressed output is written, usage text.
- `src/write.bend`: operand-aware collect state machine (`Cx` context, per
  operand `stat_path`/`open_dir`/`readdir`/`readlinkat`, `.` root with fstatx
  metadata, dir-operand entries, global hardlink registry), `preflight`,
  raw-name-byte `--sort=name` (`sort_names`), `write_to` returns `warned`
  instead of exiting, compatibility `create` wrapper.
- `effs/effects.bend`, `effs/fs.c`, `effs/fs.js`: `Fs.stat_path` (lstat whole
  operand path) and `Fs.readlink_path` (readlink operand symlinks) effects,
  C+JS twins; ABI gate green.
- `docs/m6-cli.md` (this file).

## Gaps / next

- `--sort=name` + duplicate operands can interleave shared-subtree groups
  (documented; distinct operands/. tree is deterministic).
- No `--sort=inode`, no `--no-recursion`, no `--exclude`.
- Absolute operands are refused (documented policy) rather than stripped; `..`
  anywhere is refused (no root escape).
- Gzip create still stored-DEFLATE (ratio ~99.8%) and whole-stream memfd
  buffered (~350 MB peak for a 5 MiB tree); streaming/packed bytes is next.
- Plain create of sparse files stores holes as data (no GNU `S` extension).
