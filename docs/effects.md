# Effects: tar-bend's filesystem + data-plane layer (M0, Bend 2.0.39)

Status: **M0 spike + M2 additions, verified natively** · 2026-10-25 · owners task-6 (M0), Lead (M2 additions).
Scope: `effs/fs.c` + `effs/fs.js` (C bodies + JS twins), `spike/effects.bend` (effect
declarations), `spike/fs_effects.bend` (native demo), `spike/array_probe.*` (Array<U32> probe),
`spike/copy_bench.bend` (throughput), `tools/abi_check.sh` (ABI gate).

The layer is **expressible and fast enough**: every filesystem op the tar plan needs in M1 has
a working C effect; `Data.copy` moves 256 MiB page-cached in 97–99 ms (~2.7 GB/s, cp is
91–93 ms); headers round-trip byte-exactly as 512-byte `List<U32>`. Effects stay IO-only and
trusted; the pure Bend core is unchanged.

Read first: `.cache/toolchain/guide/EFFECTS.md` (compiler contract), `plan/full-tar.md` §3–4
(architecture), `AGENTS.md` (gates). Predecessor evidence: `sqlite-bend/research/bend-probes.md`
(same effect pattern and gotchas).

## 1. Trust boundary

- `src/` is pure Bend, proven: format, path policy, limits, header/pax encode+parse.
- `effs/` is the only trusted C. It is IO-only: no tar logic, no path joining, no policy.
  Bend validates a relative component path and passes a directory `File` handle; C calls the
  *at(2) syscall and returns data/handles/errno.
- Effects are ABI-coupled to the compiler: private names, no ABI promise, rebuild every Bend
  release. Pin is **2.0.39**; `tools/abi_check.sh` is gate 1.

## 2. Effect API

Declared in `effs/effects.bend`, imported as `import ../effs/effects.bend as Fx` (calls are
`Fx.Fs.*`, `Fx.Data.copy`, `Fx.Stream.*`, `Fx.Stdout.write`). All bodies import both twins:

```python
def Fs.open_dir(path: List<&2, U32>) -> IO(Result<&1, &1, U32 & String, File>):
  import "../effs/fs.c"
  import "../effs/fs.js"
```

`Bytes` is `List<&2, U32>` for now (§5). Every handle-taking effect answers
`handle & Result<...>` (affine: the handle comes back on failure too). `Result` is
`Result<&1, &1, U32 & String, A>`: `Fail{(errno, message)}` with `strerror` text.

| Effect | Signature (after `IO`) | C body | Notes / failure |
|---|---|---|---|
| `Fs.open_dir` | `Bytes -> Result<..., File>` | `openat2(AT_FDCWD, O_RDONLY\|O_DIRECTORY\|O_CLOEXEC, resolve=0)`; fallback `open` on ENOSYS | Absolute Bend-validated path only. No `RESOLVE_BENEATH` (absolute paths would fail it); M1 adds a dirfd-relative variant. Produces the fd open. |
| `Fs.openat_dir` | `File & Bytes -> File & Result<..., File>` | `openat2(dirfd, name, O_RDONLY\|O_DIRECTORY\|O_NOFOLLOW\|O_CLOEXEC, resolve=BENEATH\|NO_SYMLINKS)`; fallback `openat` | M2 addition (Lead): dirfd-relative subdirectory open for safe component-by-component extraction walk. One component, no `/`. |
| `Fs.openat_file` | `File & (Bytes, U32) -> File & Result<..., File>` | `openat2(dirfd, O_WRONLY\|O_CREAT\|O_EXCL\|O_NOFOLLOW\|O_CLOEXEC, resolve=BENEATH\|NO_SYMLINKS)`; fallback `openat` | One component, no `/`. mode masked `07777`. ENOSYS fallback keeps `O_NOFOLLOW\|O_EXCL` but loses resolution flags (logged in docs, not silent). |
| `Fs.mkdirat` | `File, Bytes, U32 -> File & Result<..., Unit>` | `mkdirat` | One component. |
| `Fs.symlinkat` | `File, Bytes, Bytes -> File & Result<..., Unit>` | `symlinkat(target, dirfd, name)` | Target is arbitrary bytes (no NUL), never resolved. |
| `Fs.linkat` | `File, Bytes, Bytes -> File & Result<..., Unit>` | `linkat(dirfd, old, dirfd, new, 0)` | Same directory; links the entry (not through a symlink). Target policy is Bend's. |
| `Fs.fstatat` | `File, Bytes -> File & Result<..., U32 & U32>` | `fstatat(..., AT_SYMLINK_NOFOLLOW)` | Value `(meta, size)`: `meta = ((S_IFMT>>12)<<12) \| (mode & 07777)`, type 8=regular, 4=dir, 10=link, 1=fifo, 2=chr, 6=blk, 12=sock. `size > U32_MAX` → EOVERFLOW. |
| `Fs.readlinkat` | `File, Bytes -> File & Result<..., Bytes>` | `readlinkat`, buffer starts 256 B and doubles to 64 KiB | Target bytes, no UTF-8. `>= 64 KiB` → ENAMETOOLONG. |
| `Fs.readdir` | `File -> File & Result<..., List<Bytes>>` | fresh `openat(dirfd,".")`, `fdopendir`, skip `.`/`..` | Host order (Bend sorts when determinism is needed). New fd: `dup` would share the directory offset. |
| `Fs.unlinkat` | `File, Bytes -> File & Result<..., Unit>` | `unlinkat(..., 0)` | Files only (no rmdir); refuses `.`/`..`/`/`. |
| `Fs.fchmodat` | `File, Bytes, U32 -> File & Result<..., Unit>` | `fchmodat2(..., AT_SYMLINK_NOFOLLOW)` (syscall 452, kernel ≥ 6.5); ENOSYS fallback `fchmodat(...,0)` | Fallback follows symlinks; caller must have validated the entry type (documented residual, M1 moves to fd-based chmod). |
| `Fs.utimensat` | `File, Bytes, U32 -> File & Result<..., Unit>` | `utimensat(ts=[mtime,mtime], AT_SYMLINK_NOFOLLOW)` | Sets atime = mtime (GNU tar default without atime-preserve). |
| `Fs.renameat` | `File, Bytes, Bytes -> File & Result<..., Unit>` | `renameat(dirfd, from, dirfd, to)` | Same directory; cross-dir form is an M1 addition if needed. |
| `Fs.mkdir_path` | `Bytes, U32 -> Result<..., Unit>` | `mkdir(path, mode)`, `EEXIST` is success | The one absolute-path helper, for the extraction root only. |
| `Data.copy` | `File, File, U32 -> File & File & Result<..., Unit>` | 256 KiB read/write loop, EINTR-safe | Byte-exact: reads exactly size, premature EOF → EIO, short writes looped. 4 GiB cap via U32 size. |
| `Stream.read_exact` | `File, U32 -> File & Result<..., Bytes>` | `read` loop until n / EOF, EINTR-safe | Up to n bytes; short only at EOF. Cap 16 MiB (EFBIG-free fail-fast EINVAL): headers/pax are ≤ 64 KiB. |
| `Stdout.write` | `Bytes -> Result<..., Unit>` | `io_cbuf` then `io_out(stdout, ...)` on fd 1 | M2 addition (Lead): raw byte output for `btar -t` so non-UTF-8 names survive. Native only; `out.js` returns ENOSYS (JS lane must not corrupt bytes). |
| `Stream.write_bytes` | `File, Bytes -> File & Result<..., Unit>` | `io_cbuf` then EINTR-safe write loop | Fails EINVAL if a value is > 255. |

`File.close` from Base closes archive files *and* directory fds (it is a plain `close(2)`); no
separate close effect is needed. `File.size` (Base) and `fstatat` share the 4 GiB EOVERFLOW
limit.

## 3. Exact commands and observed output

All commands from `/home/agheieff/Arcadia/tar-bend` with
`export PATH=$PWD/.cache/toolchain/bin:$PATH`. Evidence transcripts:
`/tmp/btar-m0-evidence-part1.txt`, `/tmp/btar-m0-evidence-part2.txt`.

```
$ bend version
bend 2.0.39
$ ./tools/abi_check.sh
ABI OK: bend 2.0.39 effect ABI matches effs/fs.c (.../abi.out.c)
$ bend spike/fs_effects.bend -o /tmp/btar-spike
$ rm -rf /tmp/btar-spike-root && /tmp/btar-spike
mkdirat/openat_file/write_bytes/fchmodat/utimensat ok
symlinkat/linkat ok
readlinkat ok: link -> file.bin
fstatat ok: regular, mode 0640, size 512
readdir ok: 4 entries (sub, file.bin, link, hard.bin)
write_bytes ok: payload.bin = 4096 bytes
Data.copy ok: payload.bin -> copy.bin, 4096 bytes
header round trip ok: 512 bytes written, read_exact == input
read_exact ok: payload and copy both match expected 4096 bytes
unlinkat ok: hard.bin gone, fstatat gives ENOENT
renameat ok: copy.bin -> renamed.bin
readdir ok: 6 entries after mutation
SPIKE OK: fs + data-plane effects verified
```

Independent shell verification (the demo deliberately leaves the tree readable):

```
$ find /tmp/btar-spike-root -printf '%y %m %s %p\n' | sort
d 755 160 /tmp/btar-spike-root
d 755 40  /tmp/btar-spike-root/sub
f 640 512 /tmp/btar-spike-root/file.bin
f 644 4096 /tmp/btar-spike-root/payload.bin
f 644 4096 /tmp/btar-spike-root/renamed.bin
f 644 512 /tmp/btar-spike-root/expected.bin
l 777 8   /tmp/btar-spike-root/link
$ readlink /tmp/btar-spike-root/link
file.bin
$ cmp /tmp/btar-spike-root/payload.bin /tmp/btar-spike-root/renamed.bin && echo OK
cmp payload/renamed: OK
$ cmp /tmp/btar-spike-root/file.bin /tmp/btar-spike-root/expected.bin && echo OK
cmp file/expected: OK
$ stat -c 'file.bin mode=%a size=%s mtime=%Y' /tmp/btar-spike-root/file.bin
file.bin mode=640 size=512 mtime=1234567890
```

`file.bin` is the 512-byte header pattern (index*37+11 mod 256); `expected.bin` is the same list
written a second time, so the shell `cmp` is an external byte-exactness check of
`write_bytes`. `read_exact` re-opens `file.bin` with Base `File.open_bytes` and compares in Bend.
The demo also proves Base `File` handles and effect `File` handles are the same representation.

JS lane (same source, `effs/fs.js` twins, `bend prog.bend`):

```
$ rm -rf /tmp/btar-spike-root && bend spike/fs_effects.bend | tail -1
SPIKE OK: fs + data-plane effects verified
```

Array<U32> probe (`spike/array_probe.bend`, native and JS lane):

```
$ bend spike/array_probe.bend -o /tmp/btar-arrprobe && /tmp/btar-arrprobe
accept Array<U32> ok: sum(10..17) = 108
return Array<U32> ok: sum = 84
ARRAY PROBE OK: Array<U32> crosses an effect (flat class-3 block)
```

Throughput (`spike/copy_bench.bend`; source is a 256 MiB `dd if=/dev/zero` file, page cache
warm; `sync` before runs):

```
$ /tmp/btar-copybench /tmp/btar-src.bin      # 3 runs: 99, 99, 97 ms
copied 268435456 bytes byte-exactly
Data.copy wall time: 99 ms
$ time cp /tmp/btar-src.bin /tmp/btar-bench/cp.bin    # 3 runs: 91, 93, 91 ms
real 0m0.091s
```

`Data.copy` is ~2.7 GB/s, within 9% of `cp` on this workload. A tar writer that spends one
`Data.copy` per member pays essentially the kernel's copy cost, not Bend's cons-cell tax.

## 4. Handle representation decision

**Directory fds are Base `File` handles.** Bend has no user-defined handle law (WONTFIX); a
handle is one packed word and the type must be a Base handle law, so `File` is the type for
directories, archive streams and stdin/stdout alike. `File.close` works on all of them; there is
no separate `Dir` type.

Rules enforced in `effs/fs.c` and exercised by the demo:

1. A handle-producing effect (`open_dir`, plus the new fd in `openat_file`'s Result) gives its fd
   away open; it never closes or keeps it.
2. A handle-taking effect **borrows** the fd and returns `io_tup(io_hand(h), result)` on every
   path, including EINVAL validation failures and io_work failures. The demo folds this with
   `unit_op`/`keep` helpers.
3. Nothing else closes an fd: a fd that never becomes a handle is closed by the effect on every
   path (only `readdir`'s temporary fd, and the buffers in packs).
4. Multi-handle returns are right-nested pairs (`File & (File & Result)`), built with
   `io_tup(e, h1, io_tup(e, h2, r))`. Because a 2.0.39 do-block cannot destructure tuples, every
   pair-returning effect is consumed by a small helper def in the app (see
   `spike/fs_effects.bend`); this is a language-shape cost, not an effect cost. `Fs.linkat` takes
   one directory precisely so it does not return the same fd twice.

## 5. Bytes and marshalling decision

- **Bytes = `List<&2, U32>`** (a list of 0..255). C reads it with
  `io_cbuf(e, term, &len, CID(Con))` (malloc'ed, NUL-terminated, rejects values > 255) and writes
  it with `io_list(e, buf, len)`. Base 2.0.39 already speaks this shape:
  `File.open_bytes(path: List<&2,U32>)`, `File.write_bytes`, `IO.args_bytes`. So archive
  names/link targets stay byte strings end to end; no `String` round-trip (documented in
  `AGENTS.md`).
- **Headers/pax use the List route.** A 512-byte header costs 512 cons cells (~16 B each in the
  runtime) and two linear marshals per block (`io_cbuf` in, `io_list` out) — small against a
  512 B–64 KiB header budget, and the pure `Bytes`/`header.bend` modules need it.
- **Payloads do not enter Bend.** `Data.copy(in_fd, out_fd, size)` moves the bytes; the C loop is
  the trusted data plane. Recommendation stands: use `Data.copy` for tar payloads in M1
  (options A in the plan). Routing payloads through `List<U32>` would pay ~12x RSS and the
  cons-cell tax documented in `sqlite-bend/research/bend-probes.md` (254x slower on 4 KiB
  checksums).
- **`Array<U32>` across an effect: feasible, not adopted.** Probe result: an effect can accept
  and return `Array<U32>`. The generated C shows `Array<U32>` is a `TAG_BUF` block of `2^cls`
  packed u32 slots: elements at `((u32*)e.mem)[blk_loc + i]`, capacity `1 << blk_cls(term)`.
  There is **no runtime helper** for it (io_list/io_cbuf/io_hand cover List/strings/handles
  only), so the probe reaches the block layout with `term_tag`/`blk_cls`/`blk_loc`/
  `term_drop`/`heap_alloc`/`term_blk` — all ABI-internal, none documented for effects. The
  return path must allocate with the right size class (`blk_wcls`) or the runtime frees the wrong
  class. Verdict: **List<&2,U32> for headers/pax (512 B–64 KiB); Data.copy for payloads; direct
  Array<U32> effects are a documented escape hatch only**, to be considered later for a
  64 KiB+ in-Bend data path (e.g. gzip buffers) if the cons tax shows up. `File.read_bytes`
  (Base) already returns a List, so no array conversion exists in the toolchain anyway.
  Evidence: `/tmp/array_probe_out.c` (`blk_new(e, 0, 3ull, 0, 1, ...)`, `blk_read(e.mem, 0,
  ...)` for the literal) and the probe output above.

## 6. Error convention

- Every effect answers `Result<&1,&1,U32 & String, A>`. The C builds it with
  `io_res(e, w, value)` (`io_done` if `w->code == 0`, `io_fail(e, code, NULL)` otherwise, so the
  message is `strerror`). Explicit text is only for cases where errno is absent
  (`io_fail(e, EINVAL, "...")` is available).
- `io_sys_end(w, n)` is used only for a single syscall: it stores `errno` when `n < 0`. Loops
  (`Data.copy`, `read_exact`, `write_bytes`, `readdir`) set `w->code` themselves and retry
  EINTR; a zero-progress write is EIO (never an infinite retry).
- Validation in C is fail-closed: EINVAL for a bad component (`""`, `.`, `..`, `/`, NUL,
  `> NAME_MAX`), EILSEQ never needed because names are byte lists (no UTF-8 validation).
  Semantics stay in Bend: C does not decide what a tar tool may do.
- `IO.die`/`IO.try` in the app turn `Fail` into a clear CLI fatal; M1 keeps exit codes 0/1/2.

## 7. ABI pinning and the gate

There is no C ABI promise (`EFFECTS.md`): every name in the effect contract is a private
compiler/runtime internal and may move between releases. Therefore:

- the toolchain is pinned at **bend 2.0.39**;
- all effect-facing C lives in `effs/` and is rebuilt from source on every build (single C file,
  no incremental object);
- `tools/abi_check.sh` runs before native builds: it checks `bend version` is exactly
  `bend 2.0.39`, builds a tiny two-effect program to C (it also calls `Process.run`, so Base's
  reference process_run.c body is part of the check), and `grep -F`-asserts the exact contract
  lines: `typedef Term (*Effect)(Env e, Term* f, IoWork* w);`,
  `static void io_eff(u32 cid, Effect run) {`, the run signature
  `Term <name>_run(Env e, Term* f, IoWork* w) {`, the registration
  `io_eff(CID_<def>, <name>_run);`, Base's effective request-processing signature
  (`Term process_run_run(Env e, Term* f, IoWork* w) {` in the spliced process_run.c) and the
  effect dispatch call site (`io_eff_rows[c](e, fs, a)` inside `static void io_step(Env e,
  IoWork* a) {`), plus the runtime helpers `io_hand_v`, `io_res`, `io_tup`, `io_cbuf`,
  `io_list`, `io_sys_end`, `io_work`.
  Any mismatch fails with "Bend's effect ABI moved".

## 8. Gotchas (observed while building this)

1. **JS twin is mandatory** even if only native is released: a def body imports both files and
   the compiler/checker wants both. The JS twins are functional (not native-noop) and were used
   for the whole demo; the JS lane is the fast inner loop, native is the release artifact.
2. **The JS lane is not security-equivalent.** Node/Bun have no `openat2`; `fs.js` resolves
   dirfd-relative names through `/proc/self/fd/<fd>/<name>`, so there is no
   `RESOLVE_BENEATH|NO_SYMLINKS`, and `chmodSync` follows symlinks. Fine for trusted fixtures and
   tests, not for the security corpus; those run natively.
3. **Affine handle returns**: forgetting `io_tup(io_hand(h), r)` on the failure path leaks the
   handle in the typed world and breaks the next step. Every effect in `fs.c` funnels through
   `fs_unit_pack`/dedicated packs that return the handle first.
4. **IoWork is reused across steps.** Packs must free *and clear* `w->data`/`w->text`; the first
   demo build crashed with `free(): double free detected in tcache 2` because a later pack freed
   a stale pointer left by an earlier effect. `fs_clear(w)` is the fix and the pattern for new
   effects.
5. **`CID(Name)` resolution**: a def declared in an imported module gets `CID_<module>_<name>`
   after macro expansion (`spike/effects.bend` → `CID_effects_Fs_open_dir`). Registration rows
   are wrapped in `#ifdef CID(Fs.x)` so a program that uses a subset still compiles (an unused
   effect has no CID). Import the module with an alias (`import ./effects.bend as Fx`) and call
   `Fx.Fs.open_dir`; effect import paths are relative to the *declaring* file.
6. **One C file, many imports**: all 16 defs import the same `../effs/fs.c`; the compiler splices
   it once. The `#ifndef BTAR_EFFS_FS_C` guard keeps that safe if that ever changes, and the one
   constructor registers all used rows.
7. **`io_work` parks** (`IO_PARK`): the run function must malloc all inputs, the call runs on a
   helper thread without `Env`, and the pack runs later on the loop thread. Mutating
   `w->size`/`w->word` in the call is intentional (`read_exact` returns the actual count).
   Effects that can block on a real filesystem (open, mkdir, chmod, copy, read/write) use
   `io_work`; there is still no effect that waits on poll (not needed for tar v1).
8. **`Bend 2.0.39` shape limits that shaped the app code** (all hit while writing the demo):
   do-blocks cannot destructure a tuple let or bind a `handle & Result` pair; `match` may only
   head a def body, not sit inside a do-block; defs must precede their use (no forward refs);
   a `+`-reusable binder must be `Data` (a `List` of handles/Type is not), and cheap `U32`
   values are still affine unless bound with `+`; a pattern-bound `Nat` cannot be used twice
   (use it as fuel only); arithmetic needs `(a + b : T)` annotations; effect def signatures use
   `IO(...)` parens while statements use `do IO<...>:`. The helper wrappers in the spike files
   are the reusable workaround recipe for M1.
9. **openat2 availability**: kernel ≥ 5.6 required by the plan; `openat2` is called via
   `syscall(SYS_openat2)` (no glibc wrapper) with a documented `openat` fallback on ENOSYS.
   `fchmodat2` (452) needs kernel ≥ 6.5; ENOSYS falls back to `fchmodat(2)`.
10. **readdir needs a fresh fd** (`openat(dirfd, ".", O_RDONLY|O_DIRECTORY)`); `dup` shares the
    directory offset. Returned order is the host's; the reader sorts for determinism.
11. **Limits are deliberate and documented**: component ≤ NAME_MAX, symlink target ≤ 64 KiB
    (ENAMETOOLONG), `read_exact` ≤ 16 MiB (EINVAL), sizes ≤ U32_MAX (EOVERFLOW), `Data.copy`
    size is U32. v1's 4 GiB cap lives in the same place.

## 9. Recommendations for M1/M2/M3

**M1 (create/list/extract on real archives)**
- Use this layer as-is for the FS side: `open_dir` + component-wise `openat_file`/`mkdirat` for
  extraction (never a joined path), `readdir`+`fstatat`+`readlinkat` for the create manifest,
  `linkat`/`symlinkat`/`fchmodat`/`utimensat`/`unlinkat` for apply, `Data.copy` for payloads,
  `Stream.read_exact`/`write_bytes` for headers and pax records.
- Add to `Fs.fstatat` (or a new `Fs.idfileat`) the **inode identity** needed by create mode:
  `(dev, ino)` is required to emit hardlinks; today the effect returns type/mode/size only.
  Format: `(meta, size)` can stay; return `U32 & U32 & U32` or a packed pair of new fields.
- Add `Fs.fsync(File)` for archive durability once `-f` writes are closed out (plan's C list) and
  consider `Fs.write_zeros(File, U32)` for header padding (list-of-zeros is cheap at 512 B, but a
  helper avoids per-block allocation for large zero runs).
- Keep `namei` policy (strip-components, absolute/`..` rejection, component limits, symlink no-follow)
  in pure Bend; add a security test that a symlink swapped into a validated path cannot escape —
  this is what `RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS` plus dirfds are for.
- Gate: `./tools/abi_check.sh`, then a native ASan/UBSan build of the generated C (Stiff pattern)
  over the security corpus.

**M2 (pax/longname, gzip, limits)**
- pax headers/longname payloads are ≤ 64 KiB: keep the `List<U32>` route; measure `read_exact`
  + parse cost on the fixture corpus before considering the Array<U32> escape hatch.
- gzip output writes go through `Stream.write_bytes` in 64 KiB chunks; if profiling shows the
  cons tax dominating, revisit direct `Array<U32>` effects (probe is ready but ABI-internal).
- If a directory is huge, `readdir` returning a full `List<Bytes>` is memory; add a bounded
  iterator effect (open/next/close) only when the manifest memory budget demands it.

**M3 (v2 features)**
- Compression codecs stay pure Bend on `Bytes`; the effect layer stays syscall-only.
- Larger-than-4 GiB support needs U64 offsets: `Data.copy` gains `(hi, lo)` or a seek effect; the
  current API deliberately fails EOVERFLOW rather than wrapping.
- No custom handle types (WONTFIX): if a future Bend release adds handle laws for `Dir`, the
  effect table can switch types without changing the app shape.

## 8. M2 additions (Lead, 2026-10-25)

- `effs/effects.bend` is now the **canonical** declarations module (import from `src/`/`app/` as
  `../effs/effects.bend`). `spike/effects.bend` remains the M0 copy and is not used by the app.
- `Fs.openat_dir(dir, name)` — `openat2` with `RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS` and
  `O_DIRECTORY|O_NOFOLLOW`; validated per-component name. Needed by the M2 extractor to walk and
  create parent directories without following symlinks. Native test: `spike/openat_dir_test.bend`
  (`openat_dir ok`, creates `/tmp/btar-m2-dir`).
- `Stdout.write(bytes)` — raw `write(1)` of the byte list (`io_cbuf` + `io_out(stdout, ...)`), so
  `btar -t` can print non-UTF-8 member names without the `String` U+FFFD conversion. Native test:
  `spike/stdout_test.bend` emits `ff 00 41 0a` (`od -An -tx1`). JS twin fails ENOSYS by design;
  the JS lane is not the release lane for byte-exact listing.
- ABI gate still green after both additions: `./tools/abi_check.sh` → `ABI OK`.

## 7. v1.1 additions: pipes, segments, inline execution

New effects (declared in `effs/effects.bend`, C bodies in `effs/fs.c`, ENOSYS twins in `effs/fs.js`):

| Effect | Signature (after `IO`) | C body | Notes |
|---|---|---|---|
| `Fs.pipe` | `Result<..., File & File>` | `pipe2(O_CLOEXEC)` | `(read end, write end)`; connects a forked decoder/tar-writer to its consumer |
| `Stream.read_seg` | `File, U32, U32 -> File & Result<..., Bytes & Bytes>` | `read` loop (like `read_exact`) | up to `n` bytes plus a second list with the last `min(tail, got)` of them, both built in C; the compressor gets a segment and its dictionary tail without slicing a long list in Bend (slicing cost ~45 ms per MiB serial) |

**Execution rule.** A helper-thread round trip costs ~12 µs (queue, wake pipe, poll); a short
local syscall costs 0.3–3 µs. `fs_inline` therefore runs the effect on the event-loop thread for:
all path operations (`open*`, `mkdir*`, `symlinkat`, `linkat`, `stat*`, `readlink*`, `readdir`,
`unlinkat`, `fchmodat`, `utimensat`, `renameat`, `memfd_write`, `dup_file`, `pipe`, `rewind`), and for
`Stream.read_exact`/`read_seg`/`Data.copy`/`Data.copy_stdout` when the **input** descriptor is a
regular file and `Stream.write_bytes`/`write_zeros`/`Data.copy` when the **output** is a regular file
or character device (`fstat` decides per call). Pipes and sockets stay on the helper pool: an inline
read from a pipe would block the event loop that has to run the forked decoder/tar writer at the
other end. This took plain `-tf` of a 38 604-entry tree from 4.6 s to 1.0 s and extraction from
9.0 s to 2.7 s.

Honest limits: an inline read from a slow device blocks the loop for its duration (nothing else is
waiting on it except a gzip peer, which merely idles); all effects remain IO-only, with no policy
and no path joining. `tools/abi_check.sh` still reports `ABI OK`.

## 8. v1.2 additions: append/update (`-r`/`-u`)

Three new effects, all IO-only (no policy, no path joining), declared in `effs/effects.bend`, C
bodies in `effs/fs.c`, ENOSYS twins in `effs/fs.js` (native-only, like pipes/memfd). The ABI gate
(`tools/abi_check.sh`) is unchanged and still `ABI OK`; the effects are exercised under ASan/UBSan by
`tools/run_asan.sh` (append phase over the whole valid corpus) and `tools/fuzz_append.py`.

| Effect | Signature (after `IO`) | C body | Notes |
|---|---|---|---|
| `Fs.open_rw` | `Bytes -> Result<..., File>` | `open(path, O_RDWR\|O_CREAT\|O_CLOEXEC, 0666)` | The CLI archive operand, same trust as Base `File.open_bytes`. **No truncation** (Base only offers `r`/`w`/`a`); `O_CREAT` so `-rf` on a missing archive creates it (GNU). NUL in the path → EINVAL. Gives the fd away open. |
| `Stream.seek` | `File, U32, U32 -> File & Result<..., U32>` | `lseek(fd, off, whence)` | `whence` 0/1/2 only (else EINVAL); the resulting offset must fit U32 (`EOVERFLOW`, the v1 4 GiB cap). Returns the new absolute offset. Inline for every fd (a seek never blocks). Used to skip member payloads while scanning and to position at the logical end. |
| `Fs.trunc_cur` | `File -> File & Result<..., Unit>` | `fstat`; if regular: `ftruncate(fd, lseek(fd,0,SEEK_CUR))` | Cuts the file at the current write position after the end blocks are written (drops the stale tail of an in-place append, e.g. GNU's 10240-byte padding). **A no-op success on anything that is not a regular file** (pipe, `/dev/null`, tty), so the shared writer calls it unconditionally: for create it is a no-op (position == size). |

Resulting division of labour: *what* the end of the archive is, which headers are valid, which
entries are newer and the exit policy are pure Bend (`src/upd.bend`, `src/append.bend`'s state
machine, `src/write.bend`); the C only performs `open`/`lseek`/`ftruncate`. The scanner reads
headers through the existing `Stream.read_exact` and `Fs.statx`/`fstatx`; appended entries are
written through the existing `Stream.write_bytes`/`Data.copy`/`Stream.write_zeros`.

Safety notes: the write phase starts only after the read-only scan and the manifest collection
succeeded; `fstatx` on the opened read-write fd gives the `(dev, ino)` that keeps the archive out
of its own manifest; if the file is shorter than the scanned end by then (concurrent truncation)
the run aborts before writing ("archive changed while appending"). There is no locking.
