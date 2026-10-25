# Full tar in Bend — implementation plan

Status: **v1.2.0 RELEASED 2026-10-25** — append/update (`-r`/`-u`), `--exclude*`/`--no-recursion`, CI; release gate 17/17 PASS (v1.1.0: streaming/parallel gzip); see docs/status.md, docs/release-notes-1.2.0.md, docs/release-notes-1.1.0.md, docs/release-verification.md · project root `/home/agheieff/Arcadia/tar-bend`
Target: **Bend 2.0.39** (project-local `.cache/toolchain`, pin) on Linux x86-64 (openat2, kernel ≥ 5.6), clang 14+.
Predecessor evidence: `/home/agheieff/Arcadia/sqlite-bend/research/` (Bend capability audit, empirical
probes, custom-effect prototypes, Stiff/MyLSM prior art, frontier analysis). Binary name: **`btar`**.

---------------------------------------------------------------------------------------------------

## 1. Objective

Build a **complete, standalone tar archiver written in Bend** — create, list and extract — for the
mainstream tar format family, with a **machine-checked safety core** and a differential-test harness
against GNU tar / bsdtar. The point is not to clone every GNU tar option; it is to deliver the full
archiver (all three modes, real archives, real files, real edge cases) and prove the properties whose
violation is the tar CVE class: path containment, link policy, resource limits, parser bounds, and
round-trip correctness.

Why tar (recap from the frontier analysis): importance/popularity 5/5; a full **standalone** program
(no C ABI needed); streaming format that matches Bend's sequential I/O; public spec and test corpora;
recent, active exploitation class (CVE-2026-18508 GNU tar hardlink escape, CVE-2026-16517 libarchive
ZIP-writer overflow, CVE-2026-104025 PeaZip path traversal, CVE-2026-107335 Malcolm extraction limits,
RUSTSEC-2026-0297 unzip zip-slip); and a small, formalizable security policy. PHP/GitLab class
incidents (PHP2Shell, CVE-2026-110264 Onigmo regex RCE) establish the cost of memory-unsafe C parsing,
but those codebases are not Bend-replaceable; a safe archive tool is.

## 2. Scope — what "full tar" means here

### 2.1 Deliverable v1 (the release gate)

A single static-ish Linux binary `btar` implementing:

| Mode | CLI (v1) |
|---|---|
| create | `btar -cf ARCHIVE [opts] PATH...` |
| list | `btar -tf ARCHIVE [opts]` |
| extract | `btar -xf ARCHIVE [opts]` |
| options | `-v`, `-f -` (stdin/stdout), `-z` (gzip), `-C DIR`, `-p`/`--preserve-permissions`, `--strip-components=N`, `--one-top-level[=DIR]`, `--no-same-owner`, `--format=ustar\|pax` (create), `-O` (extract to stdout) |
| exit codes | 0 success, 1 warnings (skipped/refused entries), 2 fatal |

Read formats: **v7**, **ustar**, **POSIX pax** (per-file `x`, global `g`), **GNU longname `L` /
longlink `K`**, GNU **base-256** numerics. Reject with a clear error: sparse (`S`), dumpdir (`D`),
multi-volume (`M`), volume label (`V`, skip with warning), device/FIFO extraction (list ok, refuse
extraction by default; `--allow-special` out of scope). Write formats: **ustar** when the entry fits,
**pax** otherwise (long path/link, size, mtime, uid/gid > octal range). Write `--format=gnu`
(lone `L`/`K`/base-256) later.

Compression v1: **gzip (RFC 1952 + DEFLATE RFC 1951) implemented in Bend**, `-z` and auto-detect on
read from magic bytes; multi-member gzip. bzip2/xz/zstd: v2 (design keeps a compression interface).

Size limits v1: per-member ≤ 4 GiB and total extracted ≤ 4 GiB (U32 counters; Bend has no U64). Larger
member/archive sizes are detected and rejected with a clear message. This is the one deliberate
compatibility gap; the parser still validates full 64-bit field encodings (octal, base-256) and errors
rather than wrapping. A v2 lift uses hi/lo counters, then native U64 when Bend ships it (#1027 SOON).

Names: tar names are **byte strings**, not UTF-8. Core and effects treat names/link targets as
`Bytes`; do not round-trip archive names through Bend `String` (lossy). CLI path arguments use
`IO.args_bytes` (2.0.39) and `File.open_bytes` where needed.

### 2.2 v1.1 / v1.2 (follow-on, same architecture)

v1.1 delivered streaming/parallel gzip. **v1.2 delivered** `-r` append and `-u` update (uncompressed
archives; three small effects `Fs.open_rw`, `Stream.seek`, `Fs.trunc_cur`; pure scanner/policy in
`src/append.bend` + `src/upd.bend`; see docs/append-update.md) and `--exclude`/`--exclude-from`/`-X`/
`--no-recursion` with a pure GNU-semantics glob matcher (`src/glob.bend`, docs/exclude.md). Still
open: `-T` files-from, `--transform` (no), incremental (no), `--delete`/`-A`/`-d`.

### 2.3 Explicit non-goals (v1/v2)

Bug-for-bug GNU option parity; incremental dumps; multi-volume; remote/SSH; ACL/xattr/SELinux;
sparse-file creation (read/list may refuse); Windows/macOS; C ABI/library embedding (Bend cannot);
parallel (multi-thread) compression; `--delete`, `--concatenate`, `--diff`; full GNU `--transform`
and exclusion grammar beyond the documented wildcard subset; compression other than gzip; >4 GiB members; non-Linux FS semantics.

## 3. Bend constraints and design responses

| Constraint (Bend 2.0.38/39) | Response |
|---|---|
| Only `U32/F32/Nat/Char`; no U64/I64/U8/F64 | All sizes/offsets/counters in `U32` with explicit overflow checks; 64-bit field decoding verified then clipped/errored; v1 4 GiB cap documented |
| `File` API: modes r/w/a only, no pwrite/fsync/stat/readdir; `read_at` offset U32; `File.size` >4 GiB → EOVERFLOW | Custom **C effects** for all FS metadata/mutation and for bulk data copy; Base `File.open`/read/write for archive streams where sufficient |
| No directory/symlink/chmod/utime syscalls in Base | `Fs` C effect library built on `openat2(2)` + dirfds: `open_dir`, `openat_file`, `mkdirat`, `symlinkat`, `linkat`, `fstatat`, `readlinkat`, `readdir`, `unlinkat`, `renameat`, `fchmodat`, `utimensat`, `fchownat` (privileged, off by default) |
| Effects are IO-only, ABI unstable (no promise; rebuild each release) | Pin Bend version; dedicate `effs/` module; vendor ABI check script (Stiff pattern); CI gate on `bend version`; JS stubs for checker/JS lane, native-only semantics |
| No C ABI | CLI binary only; JS module later if wanted; no library replacement claim |
| Termination check mandatory; no mutual recursion; no loops/if/goto; computed match rejected | Metadata/policy as pure structural recursion; driver as one def with a state sum type + fuel counter; pair-threading helper idiom; each module small |
| Arrays are affine, fixed power-of-two, indices wrap silently | `Bytes` module wraps access in bounds-checked `at`/`slice` returning `Maybe`; never index unchecked; Array<U32> is native flat (C-fast) |
| Strings are cons lists of code points (lossy for bytes) | Byte paths/names never in `String`; use `Bytes`/`List<U32>`; only human output uses String |
| No debugger/profiler/test framework | Custom harness: `bend --check-only` all files, self-check `.bend` tests, shell differential harness, ASan/UBSan build of generated C (Stiff pattern), valgrind, fixture corpus |
| Proofs exclude effects/foreign code; `--verdict` rejects them | `proofs/PROOF.bend` imports only pure modules; app/effects are outside the proof target; trust boundary documented |
| One C file/per-program, no incremental builds; native builds slow for big programs | Module design keeps single app; use JS lane for fast inner-loop checks; native builds in CI only |

## 4. Architecture

### 4.1 Trust boundary (central decision)

**Metadata, format, path policy and limits are pure Bend and provable. Bytes on the data plane and
filesystem/syscall operations live in small C effects and are trusted/tested, not proven.** This is
the same trade-off as Bend's own runtime: effects are foreign. It is what makes a *fast full tar*
possible in Bend today. A pure-Bend data plane (Option B) is kept behind the same interfaces for a
later verification experiment; v1 uses Option A.

- Option A (default): C effect `copy_data(in_fd, out_fd, size)` moves file payloads; Bend never sees
  file bytes. Headers/pax records (≤64 KiB) do enter Bend as `List<U32>`/`Bytes`.
- Option B (future): Bend streams payload bytes through `Bytes`; slower (cons-cell tax) and provable
  end-to-end; interface-compatible.

### 4.2 Reader state machine (list/extract)

States: `WantHeader`, `WantPaxData(px)`, `WantLongName`, `WantLongLink`, `WantData(entry)`, `Done`,
`Failed`. One driver def:
`drive(fuel: Nat, state: State, ctx: Ctx) -> IO(Result<Unit, Error>)` — recursion on `fuel` (Nat,
decreasing) so the checker accepts it; `match state` dispatches; no mutual recursion. `fuel` bounded
by the configured limits (max headers/data blocks). Each `WantHeader` reads exactly 512 bytes, parses,
verifies checksum, applies pending pax/global overrides, then either emits entry (list) or builds an
extraction plan (extract) and copies/skips data.

### 4.3 Writer

Create mode builds a **manifest** first via `Fs.readdir`/`fstatat`/`readlinkat` (bounded by limits;
v1 simplicity, no streaming tree walk), then writes headers with `write_bytes` and payloads with
`copy_data`. Manifest entries are ordered as given by `argv`/directory traversal (deterministic sort
option later). Header bytes are assembled in `Bytes` (512 bytes) by the pure encoder.

### 4.4 Modules (repo layout)

```
tar-bend/
  plan/full-tar.md            this plan
  README.md, AGENTS.md
  src/
    bytes.bend                Bytes: new/size/get/set/span/at-bounds, List<->Bytes, hex/octal helpers
    num.bend                  octal + base-256 field decode/encode with overflow checks; u64 hi/lo helpers
    checksum.bend             tar header checksum
    header.bend               Header type, 512-byte parse/encode, validation
    pax.bend                  pax record parse/emit; key overrides; global vs per-file
    links.bend                GNU L/K payload handling
    entry.bend                Entry{name, mode, uid, gid, size, mtime, type, linkname, ...}
    path.bend                 byte-path normalisation + policy (pure)
    limits.bend               limits and counters (pure)
    read.bend                 stream reader/state machine + listing
    extract.bend              extraction plan + apply (calls Fs/Data effects)
    write.bend                manifest -> archive writer (ustar/pax selection)
    cli.bend                  arg parsing, dispatch, diagnostics
    gzip/{inflate,deflate,crc,header}.bend
  app/main.bend               CLI entry
  effs/                       fs.c, fs.js, io.c, io.js, data.c, data.js (+ ABI check)
  laws/LAWS.bend  proofs/PROOF.bend
  tests/                      *.bend self-checks; generated fixtures live in fixtures/ (gitignored)
  tools/                      gen_fixtures.py, compare_tree.py, run_diff.sh, run_security.sh, bench.sh
  bench/                      benchmark workloads + results
  docs/                       security-model.md, format-support.md, effects.md, trusted-base.md, m1..m7 notes
```

### 4.5 Effects API sketch (all Linux, dirfd-relative, no-follow)

- `Fs.open_dir(path: Bytes) -> IO(Result<..., File>)` — openat2 O_DIRECTORY|O_PATH? use O_RDONLY|O_DIRECTORY.
- `Fs.openat_file(dir: File, name: Bytes, mode: U32) -> IO(File & Result<..., File>)` —
  O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW; openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS.
- `Fs.mkdirat(dir, name, mode)`, `Fs.symlinkat(dir, name, target: Bytes)`,
  `Fs.linkat(olddir, oldname, newdir, newname)`, `Fs.fstatat(dir, name) -> Meta`,
  `Fs.readlinkat(dir, name) -> Bytes`, `Fs.readdir(dir) -> List<Bytes>` (or iterator),
  `Fs.unlinkat(dir, name)`, `Fs.fchmodat(dir, name, mode)`, `Fs.utimensat(dir, name, mtime)`,
  `Fs.renameat(dir, from, dir, to)`; `Fs.fchownat` only with explicit flag + root.
- `Data.copy(in: File, out: File, size: U32) -> IO(Result<..., Unit>)` — read/write loop, EINTR-safe.
- Archive stream helpers: `read_exact(fd, n) -> (File & Result<..., Bytes>)`, `write_bytes(fd, Bytes)`,
  `write_zeros(fd, n)`.
- All failures are `Result<&1, &1, U32 & String, A>`; every handle-taking effect hands the handle back
  on every path (affine).
- Handle reuse: directory fds are carried as `File` handles (Base's opaque fd type); no user handle
  types exist (WONTFIX in Bend). Document this.
- `File.open`/`read`/`write` from Base only for the archive file itself where possible; stdin/stdout
  use `/dev/stdin` / `/dev/stdout` or a stream effect.

## 5. Security model

Assume the archive is **untrusted**; the destination root is a directory the user chose. Defaults are
conservative; any GNU-compat difference is documented in `docs/format-support.md`.

Rules (pure, provable where possible):
1. **Path**: reject empty names and NULs; reject absolute paths (`/` prefix); split on `/`, ignore
   empty and `.` components, **reject `..`**; reject component >255 bytes, total >4096 bytes,
   depth >1024; apply `--strip-components` before validation; a stripped path that becomes empty is
   skipped for regular files, means root for dirs.
2. **Symlinks**: create exactly the recorded target (tar semantics), but **never follow a symlink
   during extraction** (openat2 `RESOLVE_NO_SYMLINKS` + `O_NOFOLLOW`); replacing an existing path uses
   unlinkat then O_EXCL create, never truncate-through-symlink. Absolute symlink targets allowed by
   default (tar-compatible) but extraction of later entries cannot traverse them; `--one-top-level`
   keeps all created entries under the chosen directory.
3. **Hardlinks**: target must name an entry already extracted in this run, with a safe normalised path;
   linkat with no-follow; never a device/symlink; record (dev,ino) to verify link count semantics.
4. **Types**: regular, dir, symlink, hardlink implemented. FIFO/device/socket headers: list ok,
   extraction refused with warning + exit 1 (default; `--allow-special` out of scope).
5. **Overwrite**: regular file → open O_CREAT|O_EXCL after unlinkat if needed; directory → mkdirat,
   ignore EEXIST only if it is a real directory (fstatat, no-follow); type conflicts are errors.
6. **Mode/owner**: mode applied as `mode & 07777`; setuid/setgid stripped unless `-p` AND explicitly
   allowed (root default: strip); chown only root + `--same-owner`; umask applied unless `-p`.
7. **Limits (defaults, configurable)**: max members 1,000,000; max PAX/longname payload 64 KiB; max
   path/link 4096 B; max member size 4 GiB; max total extracted 4 GiB; fuel bound derived from limits.
8. **`--one-top-level`**: implemented as root = `<dest>/<dirname>`; hardlink escape (CVE-2026-18508)
   has a dedicated regression test.
9. **No privilege**: never mknod; no setuid binaries; refuse to extract into `/` by default.

## 6. Verification plan (Bend laws)

`bend PROOF.bend` is the gate. `proofs/PROOF.bend` imports only pure modules (`bytes`, `num`,
`checksum`, `header`, `pax`, `entry`, `path`, `limits`, write/read pure models) and `laws/LAWS.bend`.
Effects/app are outside the proof target (documented trusted base). `bend PROOF.bend --verdict` runs
the proven BendTT kernel on the translation. All proofs are by induction/rewrite; no tactics.

Laws (initial set):
- `L1` checksum: `checksum(encode_header(h)) == chksum_field(h)` for canonical headers; header field
  spans sum correctly (chksum treated as spaces).
- `L2` octal round-trip: for `0 <= n < 2^32`, `decode_octal(encode_octal(n)) == n`; malformed inputs
  rejected; no overflow.
- `L3` base-256 round-trip within range; sign handling negative → error.
- `L4` header encode/decode round-trip: `decode(encode(h)) == h` field-wise for ustar entries (names,
  mode, uid/gid, size, mtime, type, linkname, prefix, magic/version).
- `L5` pax record round-trip: `parse(emit(k,v)) == Some(k,v)`; length prefix consistency; unknown keys
  are ignored by policy, not lost.
- `L6` path normalisation: idempotent; output has no `.`/`..`/empty components; absolute input
  rejected; every normalised valid path satisfies no-escape (prefix property); component/total length
  bounds.
- `L7` strip-components: result equals `drop` of first N components; no underflow; empty-result policy.
- `L8` limits: parser/plan rejects as soon as count/bytes would exceed limit; arithmetic is
  overflow-checked (U32 safe add) — prove the checked-add helpers.
- `L9` writer: for a manifest of supported entries, `parse_archive(write(manifest)) == manifest`
  (names/modes/sizes/types/links/data lengths), and block/padding math is exact.
- `L10` data-skip math: reader consumes exactly `ceil(size/512)*512` bytes after an entry; end-of-
  archive is exactly two zero blocks (writer) / accepted EOF (reader).

Trusted base (documented in `docs/trusted-base.md`): C effects and syscall semantics (openat2,
O_NOFOLLOW, linkat, ...), Linux VFS/path resolution, clang/generated C, Bend checker internals (its
kernel is proven only for `--verdict` translations), the Bend runtime, test harness assumptions, and
the OS/kernel model behind crash-free filesystem behavior. Data-copy correctness (no payload checksum
exists in tar) is established by differential tests, not proofs.

## 7. Test strategy

### 7.1 Fixtures (`tools/gen_fixtures.py`, GNU tar + Python tarfile + raw writer)

Valid: empty archive; single file; dirs; nested; symlinks relative/absolute; hardlinks; modes; empty
files; large-ish files (64 MiB); long names (>100, >255 via pax); GNU longname (`--format=gnu`);
base-256 mtime/size; pax per-file keys; pax global; latin-1/non-UTF-8 name bytes; trailing `/`;
duplicate entries; `./` prefixes; `-C` paths; multi-member gzip.
Adversarial (raw headers): absolute path; `..` components; symlink then file through it; symlink escape;
hardlink to `../../etc/passwd`; hardlink to a symlink; `--one-top-level` hardlink escape
(CVE-2026-18508); FIFO/device/char/block types; sparse `S`, dumpdir `D`, multi-volume `M`; bad
checksum; truncated header/data; zero-block edge cases; oversized pax (>64 KiB); pax length overflow;
non-NUL-terminated names; path exactly 4096/4097 bytes; 255/256-byte component; bomb-shaped archives
(1M members, huge sizes with small data); duplicate hardlink weirdness.

### 7.2 Harnesses

- `tests/*.bend` — self-check modules: run under `bend tests/x.bend` (JS lane fast) and native; failures
  `IO.die` with context; assert pure functions and small integration cases.
- `tools/run_diff.sh` — for every valid fixture: GNU tar extract into `A`, `btar` extract into `B`,
  `compare_tree.py A B`; normalize `-tvf` listings (size/date/name/type/link) and diff; cross-create:
  `btar -cf ours.tar tree` → GNU tar `-tvf` + extract compare; GNU tar create → `btar -tf/-xf` compare.
  Also run with `bsdtar` when available.
- `tools/compare_tree.py` — compare types, modes (masked), contents (SHA-256), symlink targets,
  hardlink groups (normalized), mtimes (tolerance/optional), ignore uid/gid/ctime; print actionable
  diffs; exit nonzero.
- `tools/run_security.sh` — fresh temp root + parent sentinel; extract adversarial fixture; assert
  exit code policy, no entries outside root, no symlinks followed, sentinel files untouched; run a
  second pass with `strace -f -e trace=openat2,openat,linkat,symlinkat,mkdirat` and assert resolution
  flags/paths; report refused-entry warnings.
- `tools/gen_fixtures.py` is deterministic and regenerates `fixtures/generated/` with a manifest JSON
  (sha256 per file) so tests are reproducible; `fixtures/` content is not committed.
- Fuzz: `tools/fuzz_headers.py` mutates valid headers (flip bytes, lengths, checksums, types), runs
  `btar -tf` and `-xf` under timeout; crash/wrong-write is a failure. Optional AFL-style corpus later.
- Sanitizers: compile the generated C with `-fsanitize=address,undefined` (Stiff's patched-ABI route)
  for effect-layer tests; run fixture + adversarial corpus; no reports allowed. Also valgrind on a
  subset (native binary not stripped; gdb works per prior probes).
- Performance: `bench/` workloads (10k small files, 1 × 512 MiB file, 100k-entry list, 1 GiB
  extraction) measured with `/usr/bin/time`, `hyperfine` when present; compare GNU tar/bsdtar;
  record RSS; targets: listing ≥ 20k entries/s, extraction ≥ 50 MB/s large-file, create ≥ 30 MB/s,
  and ≤ 3× slower than GNU tar on the same workload (revisit after M0 measurements).

### 7.3 CI gate (`run.sh test` / `run.sh release`)

1. `bend version` matches pin; 2. `bend --check-only` on every `.bend`; 3. `bend PROOF.bend` prints
ALL PROOFS CHECK; 4. `bend PROOF.bend --verdict`; 5. unit self-checks; 6. fixture diff; 7. security
suite; 8. sanitizer suite; 9. bench smoke; 10. package checksum. Effects ABI script runs before any
native build (Stiff pattern).

## 8. Performance plan

- Archive stream path: Base read/write of headers; 512-byte headers + 64 KiB pax cap; convert List<U32>
  to `Bytes` once per header (512 cells) — acceptable; optimize with direct `Array<U32>` marshalling
  in effects if the M0 spike shows it is easy (then header reads/writes get cheaper).
- Data plane: C copy effect, 64 KiB–1 MiB buffers, EINTR-safe loop; write with sequential `write(2)`;
  no fsync by default (tar doesn't fsync; document durability caveat), optional `--fsync` later.
- Extraction creates files with openat2; avoid per-entry directory opens where possible (cache current
  dir handle as a File; but affine model makes caching awkward — M0 measures; fallback open dir per
  entry, likely fine for small files).
- **Known ceiling**: Bend-side per-byte work is ~254× slower than C in the worst measured case; therefore
  no payload bytes in Bend v1, and headers are the only per-block cost. If M0 finds `Array<U32>`
  marshalling hard, accept List for headers; listing 100k entries is the stress case.
- Memory: streaming O(buffer + largest pax header + limits state); no archive-sized allocations.

## 9. Milestones (AI-assisted solo; parallelizable)

| # | Milestone | Deliverable / exit criteria | Est. |
|---|---|---|---|
| **M0** | Toolchain + effect spike | Repo, Bend 2.0.39 pin + ABI check script; `effs/` prototype: `open_dir`, `openat_file`, `mkdirat`, `symlinkat`, `fstatat`, `readlinkat`, `readdir`, `copy_data`; native demo creating/extracting a file tree under /tmp; decision memo on Bytes/Array marshalling | 2–3 d |
| **M1** | Header + lister | `src/bytes,num,checksum,header,pax,links,entry`; `btar -tf` on all valid fixtures incl. long names/pax/GNU; corruption rejected; L1–L5 laws pass; CLI skeleton | 5–7 d |
| **M2** | Extractor core | regular files + dirs; pure path policy + limits; `Fs` effects wired; `run_diff` extracts GNU-tar-created fixtures identically (content/types/modes); security corpus: traversal/symlink/absolute refused, no writes outside root; ASan clean | 7–10 d |
| **M3** | Links + semantics | symlink/hardlink extraction, overwrite/type-conflict policy, `-p`, `--strip-components`, `--one-top-level` (CVE regression), `-C`, verbose, `-O`; L6–L8 proofs; security suite green | 5–7 d |
| **M4** | Creator | manifest via readdir/fstatat/readlinkat; ustar+pax writer; `-cf` round-trips both directions vs GNU tar (`-tvf`, extract compare); L9–L10 proofs; deterministic test corpus | 7–10 d |
| **M5** | gzip | inflate + deflate (stored → fixed Huffman → dynamic), CRC32, gzip header/trailer, multi-member; `-z` + magic auto-detect; RFC/zlib test vectors; compressed fixtures diff; performance | 10–15 d |
| **M6** | Hardening | fuzz corpus, ASan/valgrind runs, large corpus (Debian source tarballs or libarchive test data), 4 GiB boundary, performance tuning, append/update (v1.1) if time | 7–10 d |
| **M7** | Release | docs (`README`, security model, trusted base, format support, man page), proofs+verdict green, bench report, packaged binary/tarball | 4–5 d |

MVP = **M1–M3** (~3–4 weeks): safe lister/extractor for uncompressed ustar/pax/GNU archives.
Full v1 = **M0–M5, M7** (~7–10 weeks); M6 stretches to 11–12. With 2–3 agents on disjoint modules
(M0 effects ∥ M1 parser ∥ test harness; then extract/write/gzip), wall-clock ~5–7 weeks. Treat all
estimates as ±50%; M0/M1 calibrate.

## 10. Team execution plan (Agent Teams)

Shared task board; one owner per write scope; Lead integrates, reviews diffs, runs gate.

| Agent | Scope (write) | Deliverables |
|---|---|---|
| Lead | plan/, docs/, integration, final review | plan, decisions, release gate, PR-style review of every module |
| effects | effs/, tools/abi_check.sh | `Fs`/`Data`/`Stream` effects + JS stubs; native demo; ASan build recipe |
| core-parser | src/{bytes,num,checksum,header,pax,links,entry}.bend, tests/unit_* | M1 parser+lister; laws L1–L5 |
| policy-proofs | src/{path,limits}.bend, laws/, proofs/ | M2–M3 policy; laws L6–L8; `PROOF.bend`+`--verdict` |
| reader-extract | src/read.bend, src/extract.bend, app/ | M2–M3 list/extract CLI |
| writer | src/write.bend | M4 create mode; L9–L10 |
| gzip | src/gzip/, tests/gzip_* | M5 codec + `-z` |
| harness | tools/, tests/integration, fixtures generator, bench/ | differential/security/fuzz/bench harness |

Rules: no agent writes another's scope without asking; each merged module must pass
`bend --check-only`, its unit tests, and (if pure) relevant laws; effects merges must include ABI
check + JS stub; Lead runs full gate before each milestone tag.

## 11. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| openat2/dirfd effect can't be expressed cleanly through Bend's handle/effect API (user handle types WONTFIX) | medium | M0 spike; represent dir fds as `File` handles; fallback absolute-path ops with strict policy + TOCTOU caveat only if unavoidable (document; prefer no fallback) |
| Bytes/Array marshalling to/from C effects is awkward/absent | medium | Start with `List<U32>` for headers (512 cells/header) and C `copy_data` for payload; optimize later; M0 decision memo |
| Bend compiler bugs/blind spots surface at scale (effects, large matches, arity >247 #1069, repeated-work slowdown #1007) | medium | Keep defs small; pin compiler; ABI check; report minimal repros upstream; avoid >247-live-word segments |
| PAX/GNU edge cases exceed plan | medium | Corpus-driven; explicit support matrix; reject unknown types with clear errors; differential tests |
| Path-policy proof is subtle (symlink/hardlink/TOCTOU) | high | openat2 `RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS` + O_NOFOLLOW; pure policy + proofs with stated kernel assumptions; dedicated adversarial suite; external review; conservative defaults |
| gzip/DEFLATE implementation is large and slow | medium | Staged decoder (stored → fixed → dynamic Huffman); RFC/test vectors; could ship v1 without `-z` if schedule slips (documented) |
| Effects ABI churn across Bend releases | high | Pin version; ABI check; everything effect-facing in one module; upgrade only at milestone boundaries with full gate |
| Performance below GNU tar | medium | C data plane; chunked IO; benchmark M0/M1; realistic targets; accept 2–3× slower |
| Missing U64 / 4 GiB cap limits real use | high (known) | Clear errors; hi/lo helpers for field validation; v2 lift; document compatibility divergence |
| Test corpus licensing | low | Generated fixtures + libarchive test data (BSD-2-Clause) + Python-crafted headers; no GNU tar test scripts copied |
| Security regression in C effects (path handling) | medium | Effects minimal and audited; all path decisions in pure Bend; effects take dirfd + validated relative bytes; ASan; dedicated red-team suite; strace assertions |

## 12. Defaults / decisions to confirm

1. **CLI**: GNU-compatible subset in §2.1, not every GNU option — default yes.
2. **gzip in v1**: yes (M5); bzip2/xz later; if schedule slips, ship uncompressed v1 first — default.
3. **4 GiB cap in v1**: yes; u64 pair/streaming lift in v2 — default.
4. **Data plane in C effects** (Option A) with pure-Bend Option B behind same interface — default.
5. **Linux x86-64 only**, openat2 required — default.
6. **Write format**: ustar when fits, pax otherwise — default.
7. **Security defaults**: reject `..`/absolute, refuse special files, strip setuid, no chown by default — default.
8. **Proof scope**: pure metadata/policy; effects trusted/tested — default.
9. **binary name `btar`**, project `tar-bend` — default.

## 13. Immediate next actions (M0)

1. `curl -fsSL https://bend-lang.com/install.sh | sh` → Bend **2.0.39**; record `bend version` and
   `~/.bend/bin/bend`; write `tools/abi_check.sh` (expected `io_eff`/`Effect` signatures + version).
2. Spike `effs/fs.c` + `.js` stubs: `open_dir`, `openat_file(O_CREAT|O_EXCL|O_NOFOLLOW, mode)`,
   `mkdirat`, `symlinkat`, `fstatat`, `readlinkat`, `readdir`, `unlinkat`, `fchmodat`, `utimensat`,
   `copy_data`; native Bend program creates `/tmp/btar-spike/{dir,file,link}` and verifies.
3. Spike header read/write path: `read_exact(fd, 512) -> List<U32>`; test whether an effect can
   return `Array<U32>` directly (inspect generated runtime helpers); write decision memo.
4. `tools/gen_fixtures.py` + `tools/compare_tree.py` + `tools/run_diff.sh` skeleton; generate the
   valid/evil corpus with GNU tar 1.35+ and Python; run against GNU tar only (baseline sanity).
5. Record M0 numbers in `docs/m0-effects.md`; update this plan if a route is blocked.

## Appendix A — ustar header layout (512 bytes)

| off | len | field | encoding |
|---|---|---|---|
| 0 | 100 | name | bytes, NUL-padded |
| 100 | 8 | mode | octal, e.g. `0000644\0` |
| 108 | 8 | uid | octal |
| 116 | 8 | gid | octal |
| 124 | 12 | size | octal 11 digits + NUL/space, or GNU base-256 |
| 136 | 12 | mtime | octal seconds |
| 148 | 8 | chksum | octal, computed with field as spaces |
| 156 | 1 | typeflag | `'0'`/`'\0'` regular, `1` hardlink, `2` symlink, `3`/`4` device, `5` dir, `6` fifo, `7` contiguous, `x`/`g` pax, `L`/`K` GNU long name/link |
| 157 | 100 | linkname | bytes |
| 257 | 6 | magic | `ustar\0` (POSIX) / `ustar ` (GNU, 8-byte magic+version variant) |
| 263 | 2 | version | `00` |
| 265 | 32 | uname | bytes |
| 297 | 32 | gname | bytes |
| 329 | 8 | devmajor | octal |
| 337 | 8 | devminor | octal |
| 345 | 155 | prefix | bytes (ustar name = prefix + "/" + name) |
| 500 | 12 | padding | zeros |
| data | | | `ceil(size/512)*512` bytes; end = two 512-byte zero blocks |

## Appendix B — references

- POSIX.1 pax/ustar format; GNU tar manual "Standard" and "Formats" chapters.
- libarchive (BSD-2-Clause) format docs + test suite; Go `archive/tar` (BSD) and Rust `tar` crate as
  independent reference implementations (read-only cross-checks).
- RFC 1951 (DEFLATE), RFC 1952 (gzip); zlib test vectors.
- Bend 2 guide, EFFECTS.md, CHANGELOG; issues #1843 (file primitives), #1573 (read into Array),
  #1069 (arity), #1007 (runtime slowdown); prior probes in
  `/home/agheieff/Arcadia/sqlite-bend/research/bend-probes.md` and `prototype/`.
- Stiff native build/ABI-check pattern (`/tmp/stiff/scripts/build-native.sh`) and MyLSM `Fs` effect
  prior art (BSD-3).
- Security evidence: CVE-2026-18508 (GNU tar hardlink escape), CVE-2026-16517 (libarchive ZIP writer),
  CVE-2026-104025 (PeaZip path traversal), CVE-2026-107335 (Malcolm extraction limits),
  RUSTSEC-2026-0297 (unzip crate zip-slip), PHP2Shell CVE-2026-109618/109619, CVE-2026-110264
  (GitLab/Onigmo regex RCE).
