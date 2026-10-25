# M3 — links/policy hardening, options, exit classes (`btar` M3)

Status: **M3 delivered**. All M3 harness targets green: differential **25/25**
(including `cross_dir_hardlink`, `global_pax_raw`, `symlink_meta`,
`modes_preserve`), `-p`/strict mode **1/1**, `-xOf` stdout **1/1**, security
**26/26** with **0** outside-root changes and exit classes
0-success=5 / 1-warning=6 / 2-fatal=15.

## Files (M3 deltas)

- `effs/effects.bend`, `effs/fs.c`, `effs/fs.js` — new effects:
  `Fs.linkat_at(from_dir, from_name, to_dir, to_name)` (cross-directory linkat,
  both components validated, both dir handles returned on every path),
  `Fs.euid()` (setuid/setgid policy), `Data.copy_stdout(in, size)` (byte-exact
  raw-fd1 payload copy for `-O`; native-only, JS twin ENOSYS).
- `src/read_stream.bend` — cross-directory hardlinks, global-pax mtime
  precedence, `-O` state, warning/exit-1 state, `-p` mode policy, symlink
  mtime, `Cfg` extension.
- `src/extract.bend` — chmod mask widened to `mode & 07777` (the policy mask is
  decided in the driver); everything else reused.
- `app/main.bend` — byte-safe argv parser (`IO.args_bytes` end to end; archive
  and `-C` paths are `List<&2,U32>`, never `String`), bundled short options,
  `-p/--preserve-permissions`, `-O`, `--one-top-level[=DIR]`, bare positional
  archive argument, warnings/exit-code plumbing.
- `docs/m3-extract.md` — this file.

## Options (evidence)

```bash
export PATH=$PWD/.cache/toolchain/bin:$PATH
bend app/main.bend -o build/btar
BTAR=$PWD/build/btar ./tools/run_diff.sh     # 25/25 identical; -p strict 1/1; -O stdout 1/1
BTAR=$PWD/build/btar ./tools/run_security.sh # 26/26; 0 outside-root changes
```

| feature | command | observed |
|---|---|---|
| cross-dir hardlink | `btar -xf fixtures/generated/valid/cross_dir_hardlink.tar -C d` | `cross/a/one.txt` and `cross/b/two.txt` share inode, `nlink=2`, exit 0 |
| `-p` preserve | `btar -xpf modes_preserve.tar -C d` | 0640/0660/0750 kept; `4755` → `0755` (non-root: setuid/setgid cleared) |
| default mode | `btar -xf modes_preserve.tar -C d` | `mode & 0777` (setuid stripped), files created 0640/0660/0750 |
| `-O` stdout | `btar -xOf single_file.tar` | 12 bytes `hello world\n`, byte-identical to `tar -xOf`; no files created |
| bundled flags | `btar -xOOf`, `btar -xpf`, `btar -xOf ARCHIVE` | parsed GNU-style; `f`/`C` must be last in a cluster (value = next argv) |
| `--one-top-level` | `btar -xf single_file.tar -C d --one-top-level` | creates `d/single_file/hello.txt` (archive basename minus `.tar`) |
| `--one-top-level=DIR` | `btar -xf single_file.tar -C d --one-top-level=custom` | creates `d/custom/hello.txt` |
| global pax | `btar -xf global_pax_raw.tar -C d` | `global-meta.txt` mtime `1234567890` == GNU tar extraction (identical `%T@`) |
| symlink mtime | `btar -xf symlink_meta.tar -C d`; `stat -c %Y d/links/symlink-meta` | `1234567890`, lstat/AT_SYMLINK_NOFOLLOW == GNU tar |
| warnings exit 1 | `btar -xf evil/fifo.tar -C d` | stderr `btar: skipping unsupported entry type in archive`, no file created, exit **1** |
| fatal exit 2 | `btar -xf evil/dotdot_traversal.tar -C d` | exit **2**, nothing outside `-C` |
| byte-safe `-C` | `btar -xf non_utf8_name.tar -C /tmp/caf$'\351'` | file created as raw byte `caf\xE9.txt` (no String round-trip) |

## Semantics implemented

- **Cross-directory hardlinks** (`src/read_stream.bend`): the target path is
  normalised with `Pth.safe` and must already be in the `seen` registry of
  extracted members; the destination parent chain is opened as before, then a
  second `X.walk_dirs` chain is opened for the *target* parent; `fstatat`
  requires the target to be a regular file (never a symlink), then
  `Fs.linkat_at(target_parent, target_name, dest_parent, dest_name)` runs.
  Both chains are closed after the link; no chmod/utime is applied to a link
  entry (shared inode keeps the target's metadata). Failure to reach/stat a
  target is fatal exit 2 (`hardlink_escape`,
  `one_top_level_hardlink_escape`, `hardlink_to_symlink` stay refused; the
  CVE-2026-18508 `--one-top-level` case stays contained).
- **Global pax** (`g` records): applied to subsequent entries; per-file `x`
  pax wins, then global pax, then the header. M3 applies **mtime** (used for
  files/dirs/symlinks; fractional seconds truncated to the integer part, as
  the M2 effect API has second granularity). `uid/gid/uname/gname` are
  parsed/preserved but not applied (v1 never chowns; that needs root-only
  `--same-owner` semantics). Global `path/linkpath` are ignored (they are
  invalid for globals; a warning path exists via the generic metadata
  dispatch).
- **Mode policy** (`-p`): default `mode & 0777`; with `-p`/`--preserve-permissions`
  `mode & 07777` only when `euid == 0`, otherwise still `mode & 0777` (so
  setuid/setgid are written only by root). Directories get the same policy;
  implicit parents are 0755. Symlinks are never chmod'ed.
- **Symlink mtime**: after `symlinkat` the driver applies
  `Fs.utimensat(parent, name, mtime)` with `AT_SYMLINK_NOFOLLOW` (no follow, no
  chmod), then closes the chain.
- **`-O`**: extraction mode only writes regular-file payloads to raw fd 1
  (`Data.copy_stdout`, C loop, EINTR-safe, byte-exact `==` `tar -xOf`), padding
  is skipped to the `/dev/null` sink, nothing is created on disk; `-O` selects
  extract mode.
- **Warnings vs fatal**: unsupported/skipped entry types (char/block/fifo/
  contig/other, e.g. sparse/dumpdir/multi-volume headers) print
  `btar: skipping unsupported entry type in archive` to stderr, skip the
  payload, and the run exits **1**; security violations (absolute/`..`, symlink
  escape, hardlink escape/unsafe target, bad checksum, truncated header/data,
  limit violations, malformed pax) remain fatal exit **2**. Success is 0.
- **Byte-safe CLI**: argv stays bytes from `IO.args_bytes`; option tokens are
  matched against ASCII byte literals, archive/`-C`/`--one-top-level=DIR` values
  are kept as `List<&2,U32>` and passed straight to
  `File.open_bytes`/`Fs.open_dir`/`Fs.mkdir_path`. No filesystem path is ever
  decoded through `String` (verified with a `0xE9` `-C` path and the
  `non_utf8_name` fixture).

## Incidental project bug found (reported to tar-parser)

`src/bytes.bend` `eq_list(xs, ys, same)` ignores the final element comparison
(and the caller-provided `same` flag) at the `Nil` base case, so e.g.
`"-f"` and `"-t"` compare equal. `app/main.bend` therefore carries its own
state-machine `beq_go`-based equality and recommends fixing `eq_list` +
adding a unit test; `read_stream.bend` no longer depends on `B.eq_list` for the
hardlink parent comparison (removed with cross-directory support).

## Remaining gaps / notes

- `uid/gid/uname/gname` from global/per-file pax are resolved but not applied
  (no chown in v1; needs root + explicit flag). `atime` is not restored.
- Hardlink targets must be members extracted earlier in the same run; a
  target that was skipped/refused earlier makes the link entry fatal (safe,
  matches GNU for already-extracted-content expectations).
- `-t` lists special types without warning (GNU-compatible); warnings/exit 1
  are extraction-only. `-t --strip-components` stays a no-op (GNU-consistent).
- `-p` keeps group/other bits for all users; ownership is never set. 4 GiB
  cap, second-granularity mtime, native-lane-only `-O`/raw stdout (JS lane
  ENOSYS) unchanged from M2.
- `docs/status.md` update and byte-equality fix are outside this task's write
  scope (owned by lead/tar-parser respectively).
