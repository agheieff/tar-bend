# Testing harness (M0–M6)

> **v1.1.0 note:** `tools/test_gzip.sh` now also runs `tools/test_gzip_stream.py` (large create/extract,
> GNU interop at scale, thread-count determinism, bounded memory, self-archive guard) and the ratio
> gate is a real gate (dynamic Huffman); statements below about stored-only create are historical.

Deterministic fixture corpus + differential, adversarial and create-mode harnesses for `tar-bend`.
Everything here runs without a Bend toolchain: GNU tar 1.35, bsdtar 3.8.10 (libarchive), Python 3
stdlib and bash only.

| file | purpose |
|---|---|
| `tools/gen_fixtures.py` | regenerate `fixtures/generated/` and its `manifest.json` |
| `tools/compare_tree.py` | compare two extracted trees, or two `tar -tvf` listings |
| `tools/run_diff.sh` | differential extraction: GNU tar vs bsdtar (always), optional `BTAR` |
| `tools/run_security.sh` | adversarial extraction sandbox; optional `BTAR`; GNU/bsdtar controls |
| `tools/test_create.sh` | create-mode differential: `"$BTAR" -cf` vs GNU tar (M4) |
| `tools/test_gzip.sh` | compressed corpus differential: gzip read/create + ratio/timing gates (M5/M6) |
| `tools/test_m6.sh` | optional aggregate M6 runner: create + gzip + security/diff baselines |
| `fixtures/generated/` | generated corpus, **not committed** (`.gitignore`: `fixtures/**`) |

Observed environment for the runs below: GNU tar 1.35, bsdtar 3.8.10 / libarchive 3.8.10,
Python 3.14.8, Linux x86-64.

## 1. Generating fixtures

```console
$ python3 tools/gen_fixtures.py
wrote 25 valid + 26 evil + 14 gzip-valid + 7 gzip-evil fixtures to fixtures/generated (1363 KiB, limits 100 MiB / 50 MiB gzip) in 0.02s
determinism: OK (72 sha256 values unchanged)
```

First generation prints `determinism: no previous manifest (first generation)`; any later run that
would change a fixture sha256 fails with `determinism: FAILED, changed fixtures: ...` and exit 1.
`--regen` on the harness scripts regenerates first if the corpus is stale; `--keep-sources` keeps
the temporary source tree; `--verbose` prints one line per fixture.

Determinism mechanics:

- GNU-tar-created fixtures pin all metadata: `--format=... --mtime=@0 --owner=0 --group=0
  --numeric-owner --sort=name`. For `--format=posix` the pax extended-header name is pinned with
  `--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime`, because the GNU default
  embeds the tar PID and writes live `atime`/`ctime` values into the header.
- Raw-writer fixtures (base-256 numbers, pax records, non-UTF-8 names, corrupt/truncated archives)
  are byte-exact in `gen_fixtures.py`: fixed 512-byte headers, correct checksums, fixed uid/gid/mtime.
- The corpus is ~1.36 MiB (including the ~15 KiB compressed corpus), well below the
100 MiB total / 50 MiB gzip guards enforced by the generator.
- `manifest.json` is sorted, JSON-indented and carries no timestamps, so it only changes when a
  fixture's bytes change. It records per fixture: `name`, `kind`, `file`, `format`, `tool`, `size`,
  `sha256`, expected member names (`valid.members`), the expected outcome
  (`valid.expected` / `evil.expected`), and the M3 harness hooks
  (`btar_args`, `reference_args`, `stdout_check`, `baseline_bsdtar`). Compressed
  fixtures live in separate `gzip_valid`/`gzip_evil` sections (`compression: "gzip"`,
  `source`, `profile`, `gzip_level`) so the uncompressed gates keep their fixture sets.

Example manifest records:

```json
{
  "name": "single_file", "kind": "valid", "file": "valid/single_file.tar",
  "format": "ustar", "tool": "tar (GNU tar) 1.35", "size": 10240,
  "sha256": "…", "members": ["hello.txt"],
  "expected": {"extract": "ok", "exit": 0}
}
```

```json
{
  "name": "truncated_data", "kind": "evil", "file": "evil/truncated_data.tar",
  "format": "ustar-raw", "tool": "python 3.14.8 raw-writer", "size": 612,
  "sha256": "…", "entries": ["truncated-data.txt (size 1024, 100 data bytes)"],
  "expected": {"policy": "refuse", "btar_exit": "nonzero",
               "checks": ["no-large-file"], "btar_args": [],
               "note": "declared 1024-byte payload, archive ends after 100 bytes"}
}
```

Evil policy vocabulary:

| field | values | meaning |
|---|---|---|
| `policy` | `refuse` | extractor must reject the member/archive (GNU-compatible warning + nonzero exit acceptable) |
| | `allow` | tar-compatible behaviour is allowed (e.g. creating an absolute symlink *inside* the root); it must never be followed |
| | `limit-accept` | value is exactly on the accepted side of a limit (255-byte component, 4096-byte path) |
| | `eof-tolerant` | either accept the lone zero block or refuse; must never decode it as a member |
| `btar_exit` | `nonzero` / `zero` / `either` | the exit-code assertion `run_security.sh` applies to `BTAR` |
| `checks` | `no-special-files`, `no-large-file`, `no-symlink-follow` | fixture-specific assertions (outside-root writes are always checked) |
| `btar_args` | e.g. `["--one-top-level"]` | extra arguments the security harness passes to `BTAR` |

Valid-fixture harness hooks (M3):

| field | meaning |
|---|---|
| `btar_args` | extra `BTAR -xf` extraction flags (e.g. `["-p"]` on `modes_preserve`) |
| `reference_args` | GNU tar reference args for the strict-mode compare (`["-p"]`); absence = plain A/C compare |
| `stdout_check` | run `BTAR -xOf` and compare bytes with `tar -xOf` (currently `single_file`) |
| `baseline_bsdtar` | `"refuse"` = GNU-only baseline: bsdtar is expected to reject the archive, tree/listing comparison uses GNU tar only |

## 2. Valid fixtures (25)

Extraction comparison is `run_diff.sh`'s job; the table lists what each archive must contain
after extraction. `members` comes from the manifest (long names shortened); extra columns show
the M3 harness hooks: `btar_args` (extract flags), `ref` (GNU reference args for strict-mode
compare), `-O` (stdout byte check) and `bsd` (baseline handling).

| fixture | format | tool | members (expected) | hooks |
|---|---|---|---|---|
| `base256_numeric` | ustar+base256 | python 3.14.8 raw-writer | base256.bin — *size and mtime fields are base-256* | - |
| `big_1mib` | ustar | tar (GNU tar) 1.35 | big.bin | - |
| `cross_dir_hardlink` | ustar | tar (GNU tar) 1.35 | cross/a/one.txt, cross/b/two.txt — *cross-directory hardlink: b/two.txt is typeflag '1' to a/one.txt; compare_tree hardlink groups must match* | - |
| `dirs_nested` | ustar | tar (GNU tar) 1.35 | dirs/, dirs/nested/, dirs/nested/deep.txt, dirs/top.txt | - |
| `duplicate_entries` | ustar | python 3.14.8 raw-writer | dup.txt, dup.txt — *two members named dup.txt; GNU tar and bsdtar both keep the last content* | - |
| `empty` | ustar | tar (GNU tar) 1.35 | (none) — *two zero blocks, no members* | - |
| `empty_file` | ustar | tar (GNU tar) 1.35 | empty.txt | - |
| `global_pax_raw` | pax | python 3.14.8 raw-writer | global-meta.txt — *g header with uid=123/gid=456/mtime=1234567890; GNU tar applies those to the following member. bsdtar 3.8.10 refuses non-comment global pax keys, so the GNU-vs-bsdtar baseline treats this fixture as GNU-only (documented)* | bsd=refuse (GNU-only) |
| `gnu_longname` | gnu | tar (GNU tar) 1.35 | gnu-long/ggggggggggggggggggggggggggggggggggggggggggggggggggggggg...(len=143) | - |
| `hardlink` | ustar | tar (GNU tar) 1.35 | hard/, hard/link.bin, hard/orig.bin | - |
| `long_name_pax` | posix | tar (GNU tar) 1.35 | long/lllllllllllllllllllllllllllllllllllllllllllllllllllllllllll...(len=133) | - |
| `modes` | ustar | tar (GNU tar) 1.35 | mods/, mods/mode_0600.secret, mods/mode_0644.txt, mods/mode_0755.sh | - |
| `modes_preserve` | ustar | tar (GNU tar) 1.35 | modes_preserve/, modes_preserve/keep_0640.txt, modes_preserve/keep_0660.txt, modes_preserve/keep_0750.sh, modes_preserve/setuid_4755.bin — *0640/0750/0660 plus setuid 04755; default extraction applies umask and strips setuid, -p preserves 07777 except setuid/setgid (non-root policy). run_diff compares -p trees with --strict-modes against GNU tar -xpf with setuid/setgid cleared (plan rule 6)* | args=-p<br>ref=-p |
| `non_utf8_name` | ustar | python 3.14.8 raw-writer | caf\xe9.txt — *name bytes are caf\xe9.txt (latin-1), not UTF-8* | - |
| `pad_4096` | ustar | tar (GNU tar) 1.35 | pad_4096.bin | - |
| `pad_511` | ustar | tar (GNU tar) 1.35 | pad_511.bin | - |
| `pad_512` | ustar | tar (GNU tar) 1.35 | pad_512.bin | - |
| `pad_513` | ustar | tar (GNU tar) 1.35 | pad_513.bin | - |
| `pax_global` | pax | python 3.14.8 raw-writer | global-after.txt — *g header carries a comment only; bsdtar rejects non-portable global keys* | - |
| `pax_perfile` | pax | python 3.14.8 raw-writer | renamed-pax.txt — *x header overrides path/mtime/uid* | - |
| `single_file` | ustar | tar (GNU tar) 1.35 | hello.txt — *single regular file; the -O check compares btar -xOf stdout with GNU tar -xOf* | -O |
| `symlink_absolute` | ustar | tar (GNU tar) 1.35 | links/abs-link | - |
| `symlink_meta` | pax | python 3.14.8 raw-writer | target.txt, links/symlink-meta — *x header overrides the symlink path and mtime; compare checks the target, mtime stays opt-in* | - |
| `symlink_relative` | ustar | tar (GNU tar) 1.35 | hello.txt, links/rel-link | - |
| `trailing_slash_dir` | ustar | tar (GNU tar) 1.35 | emptydir/ | - |

## 3. Evil fixtures (26)

`GNU/bsdtar control rc` is the observed exit code with the default (safe) settings; `btar exit`
is the manifest expectation against the plan §2.1 contract (0 ok, 1 warning, 2 fatal):
`nonzero` means 1 or 2, `either` means 0/1/2.

| fixture | format | policy | btar exit | checks | control rc gnu/bsd | expected behaviour |
|---|---|---|---|---|---|---|
| `absolute_path` | ustar-raw | refuse | nonzero | - | 0/0 | absolute member name; GNU tar and bsdtar strip the leading '/', btar policy rejects absolute paths (AGENTS.md) |
| `absolute_symlink` | ustar-raw | allow | zero | - | 0/0 | absolute symlink target: allowed by plan (tar-compatible); only the link is created inside root, it must never be traversed |
| `bad_checksum` | ustar-raw | refuse | nonzero | - | 2/1 | header checksum does not match field bytes |
| `block_device` | ustar-raw | refuse | nonzero | no-special-files | 2/1 | block device 8,0 member: listable but extraction refused by default |
| `bomb_huge_size_small_data` | ustar-raw | refuse | nonzero | no-large-file | 2/1 | header declares 1 TiB of data but only 4 bytes follow; must abort without allocating/writing the declared size |
| `char_device` | ustar-raw | refuse | nonzero | no-special-files | 2/1 | character device 1,3 (/dev/null) member: listable but extraction refused by default |
| `component_255` | ustar-raw | limit-accept | zero | - | 0/0 | single path component of exactly 255 bytes: allowed by the limit policy (component >255 is rejected) |
| `component_256` | ustar-raw | refuse | nonzero | - | 2/1 | single path component of 256 bytes exceeds the component limit |
| `cross_dir_hardlink_escape` | ustar-raw | refuse | nonzero | - | 0/1 | cross-directory hardlink whose target contains '..'; M3 link policy must refuse it (no path escape, no outside inode) |
| `dotdot_traversal` | ustar-raw | refuse | nonzero | - | 2/1 | '..' component; both control tools refuse to write outside root |
| `dumpdir_D` | ustar-raw | refuse | nonzero | - | 0/0 | GNU dumpdir header: not supported, extraction must not guess |
| `duplicate_hardlink_targets` | ustar-raw | allow | either | - | 0/0 | several hardlinks to the same target plus a hardlink-to-hardlink; link count semantics, all must resolve inside root |
| `fifo` | ustar-raw | refuse | nonzero | no-special-files | 0/0 | FIFO member: listable but extraction refused by default |
| `hardlink_escape` | ustar-raw | refuse | nonzero | - | 2/1 | hardlink target outside the destination root |
| `hardlink_to_symlink` | ustar-raw | refuse | nonzero | - | 0/0 | hardlinks may only target regular files extracted in this run |
| `multivolume_M` | ustar-raw | refuse | nonzero | - | 2/0 | GNU multi-volume continuation: not supported, extraction must not guess |
| `one_top_level_hardlink_escape` | ustar-raw | refuse | nonzero | - | 2/1 | CVE-2026-18508 style: --one-top-level + hardlink whose target traverses out of the chosen top-level directory |
| `one_zero_block_eof` | ustar-raw | eof-tolerant | either | - | 0/0 | single zero block then EOF; GNU warns 'lone zero block', bsdtar accepts; either tolerance or refusal is allowed, never a member |
| `oversized_pax` | ustar-raw | refuse | nonzero | - | 0/0 | pax record ~70 KiB; btar caps pax payload at 64 KiB (GNU/bsdtar happen to accept it) |
| `path_4096` | ustar-raw | limit-accept | either | - | 2/0 | total path length exactly 4096: accepted by policy, but the host filesystem (PATH_MAX) may still fail extraction; must not escape |
| `path_4097` | ustar-raw | refuse | nonzero | - | 2/0 | total path length 4097 exceeds the total-path limit |
| `pax_length_overflow` | ustar-raw | refuse | nonzero | - | 2/1 | pax record length prefix exceeds u64; malformed extended header |
| `sparse_S` | ustar-raw | refuse | nonzero | - | 0/0 | old GNU sparse header: not supported, extraction must not guess |
| `symlink_then_file_through_symlink` | ustar-raw | refuse | nonzero | no-symlink-follow | 2/1 | symlink then regular file below it; extraction must not follow the link out of the destination root |
| `truncated_data` | ustar-raw | refuse | nonzero | no-large-file | 2/1 | declared 1024-byte payload, archive ends after 100 bytes |
| `truncated_header` | ustar-raw | refuse | nonzero | - | 2/1 | archive ends in the middle of a 512-byte header |

## 4. `tools/compare_tree.py`

Compares two extracted roots: entry sets, types, modes, file contents (sha256), symlink targets,
normalised hardlink groups, optionally mtimes. uid/gid/ctime are always ignored.

```console
$ python3 tools/compare_tree.py A B [--mtime] [--mtime-tol SECONDS] [--strict-modes] [--max-diffs N]
$ python3 tools/compare_tree.py --listings GNU.list BSD.list
```

- modes are masked with `0777` by default; `--strict-modes` compares `07777` (setuid/setgid/sticky).
- hardlink groups are normalised by member names: `{a,b}` in A and `{a,b}` in B compare equal even
  though inode numbers differ; a group that exists only in one tree is a diff.
- `--mtime` compares `mtime` for regular files and directories with tolerance `--mtime-tol`
  (default 1.0 s); symlink mtimes are deliberately excluded (not preserved by every tool).
- listing mode normalises GNU `tar -tvf` and `bsdtar -tvf` output to `(type, perms, size, name,
  link target)`, ignoring date/owner/group, then diffs it. `h` hardlinks print as
  `h <perms> <size> <name> link to <target>`, symlinks as `l <perms> <size> <name> -> <target>`.
- exit codes: `0` identical, `1` differences, `2` usage/IO error. Diffs are actionable:
  `only in A: 'x' (file, mode 0644)`, `type: 'x': file in A, dir in B`,
  `mode: 'x': 0644 in A, 0600 in B (mask 7777)`, `content: 'x': sha256 … in A, … in B`,
  `symlink target: 'x': …`, `hardlink groups only in A: [[…]]`, `mtime: …`.

Sample failure output:

```console
$ python3 tools/compare_tree.py --strict-modes A B
diff: mode: 'mods/mode_0644.txt': 0644 in A, 0600 in B (mask 7777)
diff: content: 'mods/mode_0755.sh': sha256 29900186… in A, 92e78d0b… in B
compare_tree: 2 difference(s): trees A vs B
```

(`--mtime --strict-modes` passes for the 24 GNU-vs-bsdtar valid fixtures; `global_pax_raw` is
GNU-only because bsdtar refuses its global pax keys.)

## 5. `tools/run_diff.sh` — differential baseline

For each valid fixture: verify sha256 against the manifest (stale corpus → FAIL + `--regen` hint),
extract with GNU tar into `A`, with bsdtar into `B`, then `compare_tree.py A B`; normalised
`tar -tvf` vs `bsdtar -tvf` listings are compared too. Fixtures flagged
`baseline_bsdtar: "refuse"` are GNU-only: libarchive refuses non-comment global pax keys, so bsdtar's
refusal is expected and only GNU tar is used for the baseline (currently `global_pax_raw`). All temp
work lives in `mktemp -d` under `$TMPDIR`, removed by a trap unless `--keep`; kept on failure.

With `BTAR` set (must resolve to an executable) the M3 checks are:

- extract `"$BTAR" -xf FIXTURE -C C ${btar_args[@]}` and compare `A`/`C` (tree semantics);
- fixtures with `reference_args` (e.g. `-p` on `modes_preserve`) are compared with
  `compare_tree.py --strict-modes` against GNU tar extracted with the same reference args. GNU's
  reference setuid/setgid bits are cleared first to match plan rule 6 (non-root strip; `-p` keeps
  07777 minus setuid/setgid), so this checks umask bypass plus full mode bits;
- fixtures with `stdout_check` compare `"$BTAR" -xOf FIXTURE` bytes with `tar -xOf FIXTURE`
  (currently `single_file`).

Observed baseline (BTAR unset, green):

```console
$ ./tools/run_diff.sh
[ 1/25] PASS base256_numeric
[ 2/25] PASS big_1mib
[ 3/25] PASS cross_dir_hardlink
[ 4/25] PASS dirs_nested
[ 5/25] PASS duplicate_entries
[ 6/25] PASS empty
[ 7/25] PASS empty_file
[ 8/25] PASS global_pax_raw
[ 9/25] PASS gnu_longname
[10/25] PASS hardlink
[11/25] PASS long_name_pax
[12/25] PASS modes
[13/25] PASS modes_preserve
[14/25] PASS non_utf8_name
[15/25] PASS pad_4096
[16/25] PASS pad_511
[17/25] PASS pad_512
[18/25] PASS pad_513
[19/25] PASS pax_global
[20/25] PASS pax_perfile
[21/25] PASS single_file
[22/25] PASS symlink_absolute
[23/25] PASS symlink_meta
[24/25] PASS symlink_relative
[25/25] PASS trailing_slash_dir

baseline (GNU tar 1.35 vs bsdtar): 25/25 pass (24 GNU-vs-bsdtar identical, 1 GNU-only: bsdtar refuses non-comment global pax keys)
btar differential: SKIP (BTAR unset)
btar -p/-O checks: SKIP (BTAR unset)
RESULT: PASS
```

BTAR status snapshots (tar-effects rebuilds `build/btar` while M3 semantics land):

**M2 snapshot** (`build/btar` built 01:32; three expected M3 gaps):

```console
$ BTAR=$PWD/build/btar ./tools/run_diff.sh
btar binary: /home/agheieff/Arcadia/tar-bend/build/btar
[ 1/25] PASS base256_numeric
[ 2/25] PASS big_1mib
[ 3/25] FAIL cross_dir_hardlink: btar extract rc=2 (args: none)
[ 4/25] PASS dirs_nested
[ 5/25] PASS duplicate_entries
[ 6/25] PASS empty
[ 7/25] PASS empty_file
[ 8/25] PASS global_pax_raw
[ 9/25] PASS gnu_longname
[10/25] PASS hardlink
[11/25] PASS long_name_pax
[12/25] PASS modes
[13/25] FAIL modes_preserve: btar extract rc=2 (args: -p)
[14/25] PASS non_utf8_name
[15/25] PASS pad_4096
[16/25] PASS pad_511
[17/25] PASS pad_512
[18/25] PASS pad_513
[19/25] PASS pax_global
[20/25] PASS pax_perfile
[21/25] FAIL single_file: stdout extraction rc btar=2 gnu=0
[22/25] PASS symlink_absolute
[23/25] PASS symlink_meta
[24/25] PASS symlink_relative
[25/25] PASS trailing_slash_dir

baseline (GNU tar 1.35 vs bsdtar): 25/25 pass (24 GNU-vs-bsdtar identical, 1 GNU-only: bsdtar refuses non-comment global pax keys)
btar differential: 22/25 fixtures identical (/home/agheieff/Arcadia/tar-bend/build/btar)
btar -O stdout: 0/1 fixtures byte-identical to GNU tar -xOf

failures:
  - cross_dir_hardlink: btar extract rc=2 (args: none)
  - modes_preserve: btar extract rc=2 (args: -p)
  - single_file: stdout extraction rc btar=2 gnu=0
RESULT: FAIL (3 fixture(s))
artifacts: /tmp/tar-bend-diff.puKZMX
```

**Report-time snapshot** (`app/main.bend` 01:38, `build/btar` 01:39 — tar-effects' in-progress M3
CLI): `-tf` still works, but every `-xf` exits 2 with the usage message while the extraction dispatch
is being rewritten, so the harness reports 0/25 with `btar extract rc=2` for all fixtures. The
BTAR-unset baseline stays 25/25 green; this is a concurrent-work state, not a harness regression —
rerun after the extractor lands, no harness edits needed.

Harness check-path validation: GNU tar used as the `BTAR` stand-in exercises the `-p`/`-O` code
paths (`/usr/bin/tar` supports `-xf ... -C ... -p` and `-xOf`):

```console
$ BTAR=/usr/bin/tar ./tools/run_diff.sh
btar differential: 24/25 fixtures identical (/usr/bin/tar)
btar -p/strict modes: 0/1 fixtures match GNU tar reference (setuid/setgid cleared)
btar -O stdout: 1/1 fixtures byte-identical to GNU tar -xOf

failures:
  - modes_preserve: strict-mode compare against GNU -p failed
RESULT: FAIL (1 fixture(s))
artifacts: /tmp/tar-bend-diff.2g2WQz
```

`-O` is byte-identical; the `-p` strict check fires exactly as designed because GNU `-p` preserves
setuid 04755 while the btar policy under test strips setuid/setgid even with `-p` (plan rule 6).
The harness itself is correct; btar M3 is expected to match the normalized reference.

## 6. `tools/run_security.sh` — adversarial sandbox

```console
$ ./tools/run_security.sh              # validate fixtures + record controls, BTAR checks SKIP
$ BTAR=/path/to/btar ./tools/run_security.sh
$ STRACE=1 BTAR=/path/to/btar ./tools/run_security.sh
```

Sandbox per case: `<case>/container/root/` is the destination passed via `-C`; siblings
`container/sentinel.txt` and `container/outside/sentinel.txt` are sentinel files. Before/after each
extraction the harness snapshots every path outside `root` (types and symlink targets) and compares
content sha256 plus inode/hardlink-count fingerprints of both sentinels (this also catches a
hardlink from inside root to a sentinel inode). Fixture-specific checks from the manifest apply
(`no-special-files`, `no-large-file`).

With `BTAR` set, per fixture the harness asserts the manifest `btar_exit` policy against the plan
§2.1 exit contract: **0 success / 1 warnings (skipped/refused entries) / 2 fatal**. `nonzero`
accepts 1 or 2, `either` accepts 0/1/2, and `warn`/`fatal` pin one class exactly; a btar-specific
`checks` list and the universal no-outside-root/sentinel assertions always apply. Failures keep the
sandbox and print stderr. `STRACE=1` wraps the btar call with
`strace -f -e trace=openat2,openat,linkat,symlinkat,mkdirat -o <case>/strace.log` for later
resolution-flag inspection; **strace was not installed in this environment, so that branch is
untested**.

Observed output without `BTAR` (controls recorded, safe-mode pass is green):

```console
$ ./tools/run_security.sh
[ 1/26] CONTROL evil/absolute_path                      gnu rc=0 bsdtar rc=0 [-P: skipped] btar=SKIP
[ 2/26] CONTROL evil/absolute_symlink                   gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[ 3/26] CONTROL evil/bad_checksum                       gnu rc=2 bsdtar rc=1 (list -P: gnu=2 bsdtar=1) [-P: gnu=2 bsdtar=1] btar=SKIP
[ 4/26] CONTROL evil/block_device                       gnu rc=2 bsdtar rc=1 [-P: gnu=2 bsdtar=1] btar=SKIP
[ 5/26] CONTROL evil/bomb_huge_size_small_data          gnu rc=2 bsdtar rc=1 (list -P: gnu=2 bsdtar=1) [-P: gnu=2 bsdtar=1] btar=SKIP
[ 6/26] CONTROL evil/char_device                        gnu rc=2 bsdtar rc=1 [-P: gnu=2 bsdtar=1] btar=SKIP
[ 7/26] CONTROL evil/component_255                      gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[ 8/26] CONTROL evil/component_256                      gnu rc=2 bsdtar rc=1 [-P: gnu=2 bsdtar=1] btar=SKIP
[ 9/26] CONTROL evil/cross_dir_hardlink_escape          gnu rc=0 bsdtar rc=1 [-P: gnu=2 bsdtar=1] btar=SKIP
[10/26] CONTROL evil/dotdot_traversal                   gnu rc=2 bsdtar rc=1 [-P: gnu=0 bsdtar=0 outside:changed/changed] btar=SKIP
[11/26] CONTROL evil/dumpdir_D                          gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[12/26] CONTROL evil/duplicate_hardlink_targets         gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[13/26] CONTROL evil/fifo                               gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[14/26] CONTROL evil/hardlink_escape                    gnu rc=2 bsdtar rc=1 [-P: gnu=2 bsdtar=1] btar=SKIP
[15/26] CONTROL evil/hardlink_to_symlink                gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[16/26] CONTROL evil/multivolume_M                      gnu rc=2 bsdtar rc=0 [-P: gnu=2 bsdtar=0] btar=SKIP
[17/26] CONTROL evil/one_top_level_hardlink_escape      gnu rc=2 bsdtar rc=1 [-P: gnu=2 bsdtar=1] btar=SKIP
[18/26] CONTROL evil/one_zero_block_eof                 gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[19/26] CONTROL evil/oversized_pax                      gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[20/26] CONTROL evil/path_4096                          gnu rc=2 bsdtar rc=0 [-P: gnu=2 bsdtar=0] btar=SKIP
[21/26] CONTROL evil/path_4097                          gnu rc=2 bsdtar rc=0 [-P: gnu=2 bsdtar=0] btar=SKIP
[22/26] CONTROL evil/pax_length_overflow                gnu rc=2 bsdtar rc=1 (list -P: gnu=2 bsdtar=1) [-P: gnu=2 bsdtar=1] btar=SKIP
[23/26] CONTROL evil/sparse_S                           gnu rc=0 bsdtar rc=0 [-P: gnu=0 bsdtar=0] btar=SKIP
[24/26] CONTROL evil/symlink_then_file_through_symlink  gnu rc=2 bsdtar rc=1 [-P: gnu=0 bsdtar=0 outside:changed/changed] btar=SKIP
[25/26] CONTROL evil/truncated_data                     gnu rc=2 bsdtar rc=1 (list -P: gnu=2 bsdtar=1) [-P: gnu=2 bsdtar=1] btar=SKIP
[26/26] CONTROL evil/truncated_header                   gnu rc=2 bsdtar rc=1 (list -P: gnu=2 bsdtar=1) [-P: gnu=2 bsdtar=1] btar=SKIP

security summary (BTAR unset): fixtures 26/26 valid;  controls gnu=26 bsdtar=26;  safe-mode outside-root changes: 0;  -P controls: runs=50 outside-root changes=4;  BTAR checks: SKIP
RESULT: PASS
```

Each control runs twice: first the default safe pass, then a sandboxed `-P` pass (absolute-names
mode) in its own container, to record how the reference tools behave when their safety checks are
disabled. Everything stays inside the `mktemp -d` sandbox: `..` and symlink escapes from the sandbox
root are detected (and recorded, not fatal) by the outside-root snapshot. The `-P` pass is skipped
for `absolute_path`, whose member name is a fixed host path, so the harness never writes to the
host. Listing with `-P` is recorded as well.

BTAR status snapshots (same concurrent-M3 caveat as §5):

**M2 snapshot** (`build/btar` built 01:32; 26/26):

```console
$ BTAR=$PWD/build/btar ./tools/run_security.sh
[26/26] PASS evil/truncated_header                   policy=refuse       rc=2 outside=clean

security summary (BTAR=/home/agheieff/Arcadia/tar-bend/build/btar): 26/26 evil fixtures passed
btar exit classes (plan 2.1): 0-success=5 1-warning=0 2-fatal=21
outside-root changes: 0
RESULT: PASS
```

**Report-time snapshot** (`build/btar` 01:39, in-progress M3 CLI): the sandbox harness reports
24/26 — every exit is fatal (2), so the two fixtures whose policy expects exit 0 (`allow` on
`absolute_symlink`, `limit-accept` on `component_255`) fail while everything else passes with
0 outside-root changes. Listing still works; extraction is mid-refactor upstream. Rerun when the
extractor settles.

The M3 exit-contract acceptance (1 = warnings, 2 = fatal) is already exercised: refusals come back
as exit 2 here; a future warn-and-skip policy for special types will be accepted as exit 1 without
harness changes. New `cross_dir_hardlink_escape` is included automatically via the manifest.

With a stand-in `BTAR=bsdtar`, the harness discriminates as intended (17/26 pass; the 9 failures
are GNU-compatible behaviours that btar must tighten, now including the `fifo` special-file check):

```console
$ BTAR=bsdtar ./tools/run_security.sh
btar binary: /usr/bin/bsdtar
[ 1/26] FAIL evil/absolute_path                      policy=refuse       rc=0: expected warning/fatal exit (1/2), got 0
…
  - absolute_path: expected warning/fatal exit (1/2), got 0 (log: /tmp/tar-bend-sec.hXBBjI/cases/absolute_path/btar.err)
  - bomb_huge_size_small_data: suspicious large file created (log: /tmp/tar-bend-sec.hXBBjI/cases/bomb_huge_size_small_data/btar.err)
  - dumpdir_D: expected warning/fatal exit (1/2), got 0 (log: /tmp/tar-bend-sec.hXBBjI/cases/dumpdir_D/btar.err)
  - fifo: expected warning/fatal exit (1/2), got 0; special file created (log: /tmp/tar-bend-sec.hXBBjI/cases/fifo/btar.err)
  - hardlink_to_symlink: expected warning/fatal exit (1/2), got 0 (log: /tmp/tar-bend-sec.hXBBjI/cases/hardlink_to_symlink/btar.err)
  - multivolume_M: expected warning/fatal exit (1/2), got 0 (log: /tmp/tar-bend-sec.hXBBjI/cases/multivolume_M/btar.err)
  - oversized_pax: expected warning/fatal exit (1/2), got 0 (log: /tmp/tar-bend-sec.hXBBjI/cases/oversized_pax/btar.err)
  - path_4097: expected warning/fatal exit (1/2), got 0 (log: /tmp/tar-bend-sec.hXBBjI/cases/path_4097/btar.err)
  - sparse_S: expected warning/fatal exit (1/2), got 0 (log: /tmp/tar-bend-sec.hXBBjI/cases/sparse_S/btar.err)
RESULT: FAIL (9 fixture(s))
artifacts: /tmp/tar-bend-sec.hXBBjI
```

The harness assumes the planned GNU-compatible CLI: `btar -xf ARCHIVE -C DIR`, plus per-fixture
`btar_args` (e.g. `--one-top-level`). If the CLI lands differently, update `run_btar()` in
`tools/run_security.sh` and the manifest `btar_args` field.

## 7. How M1 / M2 / M3 / M4 / M5 / M6 use this

**M1 (header + lister).** Keep using fixture creation plus `compare_tree.py --listings` against
GNU/bsdtar `-tvf` output; corruption cases (`bad_checksum`, `truncated_header`,
`pax_length_overflow`, …) grade the lister's error path.

**M2 (extract).** Gate:

```console
$ BTAR=/path/to/btar ./tools/run_diff.sh     # valid corpus (25 fixtures)
$ BTAR=/path/to/btar ./tools/run_security.sh # evil corpus (26 fixtures)
```

Status snapshots: the M2 binary (01:32) was `run_diff` 22/25 (the three reds were the M3 features
`cross_dir_hardlink`, `-p` on `modes_preserve`, `-O` on `single_file`) and `run_security` 26/26 with
0 outside-root changes. The report-time in-progress M3 CLI (01:39) rejects every `-xf` with the
usage/exit-2 path, so both BTAR-enabled runs go red until tar-effects lands the extractor; the
BTAR-unset baseline is green in all cases and needs no changes. Security exit classes are accepted
as 0/1/2 per plan §2.1.

**M3 (links + semantics).** New fixtures/hooks added for this milestone:

- `cross_dir_hardlink` — hardlink in `cross/b/` to `cross/a/one.txt`; `compare_tree.py`
  hardlink-group normalisation is the acceptance check.
- `cross_dir_hardlink_escape` — evil: `b/escape` hardlinked to `../a/one.txt`; must be refused
  (exit 1/2) with no outside-root change or inode escape.
- `global_pax_raw` — pax global header with `uid=123`/`gid=456`/`mtime=1234567890`; btar must
  apply them to the following member (mtime check is opt-in via `compare_tree.py --mtime`).
- `symlink_meta` — pax `path` + `mtime` override on a symlink; compare the target (mtime opt-in).
- `modes_preserve` — 0640/0750/0660 + setuid 04755; extracted with `-p` (`btar_args`) and compared
  strictly against the normalized GNU `-xpf` reference.
- `single_file` — `-O`: `btar -xOf` stdout must be byte-identical to `tar -xOf`.
- Exit contract: 0 ok / 1 warnings / 2 fatal; `run_security.sh` and `fuzz_headers.py` accept all
  three for mutated/adversarial inputs, so warning-mode skips are legitimate.

**M6 (hardening).** `test_create.sh` gained multi-operand/ordering/gzip-warning cases (§8) and
`test_gzip.sh` gained the deflate ratio + timing gate (§9); `tools/test_m6.sh` is an optional
aggregate runner (create + gzip + BTAR-unset security/diff baselines). Final M6 state (stable
`build/btar` 09:36): create **18 pass / 0 fail / 0 skip**, gzip **26/0/1** (ratio SKIP while
stored-only; timing green), aggregate **4/4 PASS**, security and diff baselines green.

**M4 (create round-trip).** `tools/test_create.sh` is the dedicated create-mode gate (see §8):
`"$BTAR" -cf` archives are compared with GNU tar by normalized listings and GNU-extracted tree
equivalence. `duplicate_entries`, `hardlink`, `cross_dir_hardlink` and
`duplicate_hardlink_targets` cover last-wins/link-group semantics on the extract side;
`compare_tree.py` hardlink-group normalisation is the shared acceptance check. The
`fixtures/generated/` corpus stays the extract oracle and is unchanged; create source trees are
generated deterministically in `/tmp` per run, so no new committed archives were needed. Current
M4 state: `run_diff.sh` 25/25, security 26/26, `test_create.sh` 9/9 — all green.

**M5 (gzip).** `tools/test_gzip.sh` is the compressed-corpus gate (see §9): deterministic
`.tar.gz` fixtures (`gzip -1/-9 -n`, Python zlib stored blocks, two-member concatenation) plus
corrupt streams; auto-detect/explicit `-z` listing+extraction parity vs GNU tar, `-O`, fatal-exit-2
corruption policy, and (once the writer supports it) `-czf` create validation with a compression
ratio report. Compressed fixtures are intentionally not part of `run_diff.sh`/`run_security.sh`.

## 8. `tools/test_create.sh` — create-mode differential harness (M4)

Builds deterministic source trees in a temp dir (no committed fixtures), creates archives with GNU
tar (reference) and `"$BTAR"` (candidate), then validates the candidate.

Trees: basic files/dirs/empty, 1 MiB file plus a 4 MiB sparse-ish file, 511/512/513/4096-byte
padding edges, relative + absolute symlinks, a hardlink pair (same inode, nlink 2), modes
0640/0755/0660 and setuid 04755, a >100-byte filename component (pax territory) and a >255-byte
nested path, a non-UTF-8 name (`caf\xe9.txt`), an empty tree, and a tree containing a FIFO. All
mtimes are pinned so repeated runs are comparable.

Checks per case:

- GNU tar must read the btar archive cleanly (`tar -tf` rc 0, no read warnings) — this accepts the
  writer's end blocks / trailing padding;
- normalised `tar -tvf` listing equality (type/perms/size/name/link target; dates/owners ignored),
  which also verifies stored mode bits including setuid, hardlink link targets and long names;
- GNU extraction of both archives into separate dirs plus `tools/compare_tree.py` — contents,
  modes, symlink targets and hardlink groups must match; mtime comparison stays off;
- bsdtar cross-reader sanity when installed.

Cases: default `-cf`, separate `-c -f`, `-cvf` (verbose output must be non-empty), relative and
absolute `-C`, `-cpf` (permissions; stored setuid bit checked via the listing), `--format=pax` on
the long-name tree (auto-SKIP with a note if the option is not implemented yet), empty tree, and a
FIFO source tree. FIFO policy accepts either tar-compatible archiving (exit 0) or warn-and-skip
(exit 1 with a warning); in both cases the archive must stay GNU-readable and the remaining entries
tree-equivalent.

Usage:

```console
$ ./tools/test_create.sh                 # BTAR defaults to $PWD/build/btar
$ BTAR=/path/to/btar ./tools/test_create.sh --keep
```

Observed now (`build/btar` built from `app/main.bend` 01:46; create mode not implemented yet):

```console
$ ./tools/test_create.sh
test_create: btar=/home/agheieff/Arcadia/tar-bend/build/btar
test_create: source trees under /tmp/tar-bend-create.gmv3N2/src (base, empty, special)
test_create: SKIP: btar -cf unsupported (probe rc=2): usage: btar -tf ARCHIVE | btar -xf ARCHIVE ...
RESULT: SKIP (create mode not implemented yet; harness ready for M4)
```

Exit codes: 0 PASS or SKIP (create mode unimplemented — keeps the gate honest), 1 FAIL, 2 setup
error. `--keep` keeps the generated trees/archives/logs (kept automatically on failure).

The harness was validated on its PASS path with GNU tar used as a `BTAR` stand-in (including a
`--format=pax` → GNU `--format=posix` wrapper): **9/9 cases pass** with the same checks, so once
tar-effects lands the writer it will report real results without harness edits.

M4/M5 integration: run after `app/`/writer changes; the reverse direction (btar reading
GNU-created archives) is already covered by `run_diff.sh`; M5 gzip will add `-z` variants to this
harness (not implemented yet). `tools/run.sh` wiring is the Lead's; `run_diff.sh` is intentionally
not modified.

### M6 additions (multi-operand, ordering, gzip warnings)

`test_create.sh` also probes and grades the M6 create-hardening features; when a feature is absent
the cases print SKIP with the observed probe reason instead of going red:

- **multi-operand** (probe: `-cf out -C base hello.txt dirs`): `-C`-relative operands,
  cwd-relative operands (`base/hello.txt base/dirs`), leading `./` operands, duplicate operands
  (documented policy, not a parity requirement), absolute operand policy (reject with exit 2 or
  strip like GNU both accepted), and a missing operand (must be fatal exit 2 with no valid archive).
- **`--sort=name`**: two runs byte-identical (sha256), GNU `--sort=name` listing/extraction parity,
  plus deterministic `-czf --sort=name` creation (gzip header mtime stays fixed).
- **gzip warning semantics**: FIFO source + `-czf` must exit **1** while still writing a valid
  archive (`gzip -t` rc 0) that GNU tar can list and extract.

Current status with the stable M6 binary (`build/btar` 09:36):

```console
$ ./tools/test_create.sh
test_create: probing M6 features (multi-operand, --sort=name, -czf warnings)
[10] PASS operands-C       (-C base hello.txt dirs)
[11] PASS operands-cwd     (cwd-relative base/hello.txt base/dirs)
[12] PASS operands-dot     (leading './' operands)
[13] PASS duplicates       (btar=2 GNU=2 entries; duplicate policy documented)
[14] PASS absolute-operand (absolute operand rejected, exit 2)
[15] PASS missing-operand  (fatal exit 2, no valid output)
[17] PASS sort-name        (two runs byte-identical, GNU --sort=name parity)
[18] PASS sort-name-gzip   (deterministic gzip, fixed header mtime)
[19] PASS gzip-warning     (exit 1, valid gzip archive, GNU-readable)
test_create summary: 18 pass, 0 fail, 0 skip (create mode)
RESULT: PASS
```

During M6 bring-up the harness briefly caught a real GNU-parity divergence: for
`-C base ./hello.txt ./dirs`, btar initially stored `hello.txt`/`dirs/...` while GNU tar keeps the
`./` prefix; tar-effects fixed the operand handling while this task ran, and the final binary passes
all nine M6 cases. That sequence (red -> fixed -> green, without harness edits) is the intended
use of the SKIP/FAIL probes.

## 9. `tools/test_gzip.sh` — compressed corpus & gzip differential (M5)

Compressed fixtures live under `fixtures/generated/gzip/` and are recorded in the manifest's
`gzip_valid` / `gzip_evil` sections (`compression: "gzip"`, `source`, `profile`, `gzip_level`).
They are kept out of the uncompressed `valid`/`evil` sections so the M0–M4 gates keep their exact
fixture sets. Generation is deterministic: GNU `gzip -1/-9 -n` (no name/mtime in the header),
Python zlib level 0 for stored DEFLATE blocks, and two independently compressed chunks concatenated
for the multi-member case. The compressed corpus is ~15 KiB (budget 50 MiB).

### Compressed corpus: valid (14)

| fixture | profile | gzip | source | size | notes |
|---|---|---|---|---|---|
| `big_1mib_gz` | deflate | -9 | `valid/big_1mib.tar` | 2146 B | gzip -9 -n of big_1mib.tar |
| `dirs_nested_gz` | deflate | -1 | `valid/dirs_nested.tar` | 234 B | gzip -1 -n of dirs_nested.tar |
| `gnu_longname_gz` | deflate | -9 | `valid/gnu_longname.tar` | 153 B | gzip -9 -n of gnu_longname.tar |
| `hardlink_gz` | deflate | -9 | `valid/hardlink.tar` | 153 B | gzip -9 -n of hardlink.tar |
| `long_name_pax_gz` | deflate | -9 | `valid/long_name_pax.tar` | 162 B | gzip -9 -n of long_name_pax.tar |
| `multi_member_gz` | multi-member | -1/-9 | `valid/dirs_nested.tar` | 247 B | two concatenated gzip members over one tar stream |
| `non_utf8_name_gz` | deflate | -1 | `valid/non_utf8_name.tar` | 109 B | gzip -1 -n of non_utf8_name.tar |
| `pad_4096_gz` | deflate | -9 | `valid/pad_4096.tar` | 125 B | gzip -9 -n of pad_4096.tar |
| `pad_511_gz` | deflate | -9 | `valid/pad_511.tar` | 122 B | gzip -9 -n of pad_511.tar |
| `pad_512_gz` | deflate | -9 | `valid/pad_512.tar` | 119 B | gzip -9 -n of pad_512.tar |
| `pad_513_gz` | deflate | -9 | `valid/pad_513.tar` | 120 B | gzip -9 -n of pad_513.tar |
| `single_file_gz` | deflate | -9 | `valid/single_file.tar` | 113 B | gzip -9 -n of single_file.tar |
| `stored_level_gz` | stored | 0 | `valid/dirs_nested.tar` | 10263 B | gzip container with stored (uncompressed) DEFLATE blocks |
| `symlink_relative_gz` | deflate | -1 | `valid/symlink_relative.tar` | 202 B | gzip -1 -n of symlink_relative.tar |

### Compressed corpus: corrupt (7)

| fixture | expected | corruption |
|---|---|---|
| `gzip_bad_cm` | fatal exit 2 | compression method CM=7; only CM=8 (deflate) is supported |
| `gzip_bad_crc` | fatal exit 2 | trailer CRC32 does not match the decompressed payload |
| `gzip_bad_isize` | fatal exit 2 | trailer ISIZE (mod 2^32 size) does not match the output |
| `gzip_bad_magic` | fatal exit 2 | gzip magic is not 1f 8b; -z must reject and auto-detect must not guess gzip |
| `gzip_bomb_isize` | fatal exit 2 | ISIZE claims 4 GiB - 1 output; reader must detect the size mismatch without materialising/allocating the declared size |
| `gzip_truncated_deflate` | fatal exit 2 | stream ends in the middle of the DEFLATE data |
| `gzip_truncated_header` | fatal exit 2 | gzip stream ends inside the 10-byte header |

Commands:

```console
$ ./tools/test_gzip.sh                  # BTAR defaults to $PWD/build/btar
$ BTAR=/path/to/btar ./tools/test_gzip.sh --keep
```

Support detection probes `"$BTAR" -tzf` (explicit `-z`) and `"$BTAR" -tf` (auto-detect) on
`gzip/valid/single_file_gz.tar.gz`. If both are absent the harness prints the observed rc/reason
and `RESULT: SKIP` with exit 0, so the gate stays honest while integration is in flight. If one
mode works it becomes the primary mode and the other mode / `-O` / create sub-checks are reported
as SKIP until wired; when both work the harness also checks explicit-vs-auto agreement.

Valid checks (per fixture): gzip-mode listing vs `tar -tzf` — GNU octal escapes are normalized to
raw bytes so the latin-1 `caf\xe9.txt` name compares correctly — plus extraction into fresh dirs
and `tools/compare_tree.py` against `tar -xzf` (contents, modes, symlink targets, hardlink groups,
long/pax names, padding edges, multi-member streams). `-O` output is compared byte-for-byte with
`tar -xOzf` on the single-file fixture. Corrupt fixtures must exit fatal **2** with a non-empty
diagnostic and must not hang (30 s timeout): bad magic, bad CM, truncated header, bad CRC32, bad
ISIZE, truncated DEFLATE, and a gzip trailer with ISIZE `2^32-1` (bomb). Bad magic with explicit
`-z` must be a gzip error; with auto-detect only it is rejected as an invalid tar stream (also
fatal 2) — documented expected behaviour, not a pass-through.

Create direction (gated on a `-czf` probe): bundled `"$BTAR" -czf ours.tgz -C tree .` and separated
`-c -z -f` archives are validated with `gzip -t`, GNU `tar -tzf` name parity against a
`tar -czf` reference, GNU `tar -xzf` extraction tree equality via `compare_tree.py`, and a
compression-ratio print (`ours/ref=…%`; informational, no hard threshold).

Observed now (`build/btar` M4; gzip read not integrated yet):

```console
$ ./tools/test_gzip.sh
test_gzip: btar=/home/agheieff/Arcadia/tar-bend/build/btar
test_gzip: fixtures=/home/agheieff/Arcadia/tar-bend/fixtures/generated/gzip (14 valid, 7 evil)
test_gzip: support probe: explicit -tzf rc=2, auto -tf rc=2
test_gzip: SKIP: gzip read integration absent
  -tzf: usage: btar -tf ARCHIVE | btar -xf ARCHIVE [-C DIR] [-v] [-p] [-O] [--strip-components=N] [--one-top-level[=DIR]]
  -tf : btar: malformed numeric header field
RESULT: SKIP (gzip read not implemented yet; corpus/harness ready for M5)
```

The PASS path was validated with GNU tar as the `BTAR` stand-in — **25/25 checks pass** (14
fixtures × list+extract, explicit/auto parity, `-O`, 7 corrupt fatal, 2 create styles):

```console
$ BTAR=/usr/bin/tar ./tools/test_gzip.sh

test_gzip: modes explicit-z=1 auto-detect=1 primary=explicit -z
test_gzip summary: 25 pass, 0 fail, 0 skip (gzip mode)
RESULT: PASS
```

### M6 ratio / timing gate

After the create cases, `test_gzip.sh` builds a compressible tree (1 MiB zeros + 2 MiB "ABCD"
text + repeated text) and adds two checks:

- **compression ratio**: `btar -czf` size must be < 50% of the plain tar; the harness prints
  `ratio plain=… ours=… (…%) gnu=… (…%) deflate-btype=…`. If the first DEFLATE block is stored
  (`BTYPE=0`) it prints `SKIP compression-ratio` with the reason instead of failing, so it becomes
  a real gate once the fixed-Huffman/LZ77 create encoder lands; a real-DEFLATE archive that is
  still ≥50% of plain is a failure.
- **timing**: an ~1.4 MiB tree with 200 small files is created, listed and extracted with wall
  time; a single operation >30 s fails, otherwise the harness prints ms and create MB/s.

Observed now (stored-only create encoder still in place; stable `build/btar` 09:36): timing passes
— plain tree 1.44 MB, create 260 ms, list 286 ms, extract 363 ms (~5.6 MB/s); ratio check SKIPs —
plain=3,287,040 B, ours=3,280,657 B (99.8%), GNU `tar -czf`=4,327 B (0.1%), BTYPE=0. (During
bring-up, a transient mid-rebuild binary read stored-DEFLATE streams back as `gzip: corrupt deflate
data`; the stable binary is green. The ratio gate flips to a hard `<50%` assertion automatically
once the fixed-Huffman/LZ77 create encoder lands.)

M5/M6 integration: run after `src/gzip.bend` + app `-z`/auto-detect/memfd wiring; compressed runs
should keep fatal errors at exit 2 and warnings at 1. The gzip corpus is excluded from
`run_diff.sh`/`run_security.sh` by design (the uncompressed corpus stays the extract oracle); M6
fuzz/perf can reuse the fixtures and the ASan gate via `run.sh` (Lead wiring).

## 10. Control-tool divergences worth knowing

These are recorded baseline facts, not btar requirements:

- GNU tar and bsdtar strip a leading `/` (exit 0); both refuse `..` members (GNU exit 2, bsdtar
  exit 1) and hardlink targets with `..`; both refuse extraction through a symlink.
- Non-comment pax **global** keys (`uid`, `gid`, `mtime`, `uname`, `gname`): GNU tar applies them to
  following members; bsdtar 3.8.10 refuses both listing and extraction (exit 1). Hence
  `global_pax_raw` has `baseline_bsdtar: "refuse"` and the baseline is GNU-only for it.
- Both silently accept/ignore `D` (dumpdir) and `S` (sparse) headers, and both create FIFOs
  (exit 0). btar policy refuses unsupported types and special files.
- Both allow a hardlink to a symlink (exit 0). btar policy allows hardlinks only to regular files.
- bsdtar accepts the 1 TiB bomb by creating a sparse 1 TiB file (exit 1 only at EOF) — it is a DoS
  vector, not a safe control; GNU tar aborts.
- bsdtar accepts `M` (multi-volume) headers silently; GNU tar refuses.
- Oversized pax records (~70 KiB) are accepted by both controls; btar's 64 KiB cap rejects them.
- The 4096-byte path is rejected by GNU tar (PATH_MAX) and silently skipped by bsdtar; btar policy
  accepts it, but OS extraction may fail — hence `btar_exit: either` with the universal no-escape
  assertion.
- Single zero block + EOF: GNU warns (`A lone zero block`) and accepts, bsdtar accepts silently.

## 11. Limitations

- **Fixtures are not committed.** `.gitignore` blocks `fixtures/**`; only `fixtures/.gitkeep` is
  kept. Regenerate before a gate (`run_diff.sh`/`run_security.sh` do it automatically when
  `manifest.json` is missing; `--regen` forces it).
- **Determinism is tool-version-scoped.** Metadata is pinned, but a different GNU tar major version
  could produce different header details; the manifest records the exact `tools.gnu_tar` and
  `tools.python`. A changed generator intentionally trips the manifest check once — rerun twice to
  confirm stability.
- M5 gzip read/create is integrated (`test_gzip.sh` 26 pass / 0 fail / 1 skip); the compression
  ratio gate still SKIPs because `-czf` uses stored-only DEFLATE (BTYPE=0, 99.8% of plain) until
  the real fixed-Huffman/LZ77 encoder lands. No large-file cases >1 MiB; mtime and symlink
  metadata checks are opt-in (`compare_tree.py --mtime`); uid/gid are ignored (non-root).
- M6 create hardening landed during this task: multi-operand, leading `./`, duplicates, absolute
  policy, missing operand, `--sort=name` determinism and gzip warning-exit semantics are covered
  and green (18/0/0). The ratio/timing gates described in §9 are green/SKIP on the stable binary;
  the ratio gate becomes a hard `<50%` assertion once the real fixed-Huffman/LZ77 create encoder
  lands. `tools/test_m6.sh` aggregates create+gzip+security/diff (4/4 PASS).
- Listing normalization parses `-tv` text, so it assumes names that don't contain `" -> "` or
  `" link to "`; the current corpus names are safe. Dates/owners are ignored by design.
- The `-p` reference is normalized by clearing setuid/setgid on the GNU `-xpf` tree (plan rule 6:
  non-root `-p` keeps 07777 minus setuid/setgid), so the strict check encodes the documented policy,
  not GNU bug-for-bug behavior.
- `build/btar` is rebuilt by other agents while milestones land; snapshot blocks in §5/§6 record
  the transient M3 state (0/25 diff, 24/26 security at one point). At report time the M4 binary is
  green on every gate (diff 25/25, `-p`/`-O` 1/1, security 26/26, create 9/9, fuzz 400/400).
- gzip is not integrated yet (M5 in progress): `test_gzip.sh` detects this and prints
  `RESULT: SKIP` (exit 0) with the observed probe rc/stderr; compressed fixtures stay out of the
  extract/security gates. Multi-member gzip is accepted by GNU tar/bsdtar and is a required M5 case.
- Create mode was SKIP until M4 landed; `test_create.sh` now grades the writer (see §8) and still
  probes `-cf` first, so a future create-mode regression produces a clean SKIP with the observed
  reason instead of a false-red gate. No committed create fixtures are needed (source trees are
  generated per run).
- `fuzz_headers.py` accepts exit codes 0/1/2 and now runs list+extract per case once the binary
  supports `-xf` (200 iterations = 400 runs, 400/400 clean, deterministic corpus sha on the current
  ASan binary — see `docs/sanitizers.md`).
- All control extraction, including the sandboxed `-P` pass, stays inside the `mktemp -d` sandbox;
  `-P` extraction of `absolute_path` (fixed host path) is skipped on purpose. `STRACE=1` is a
  skeleton because `strace` is absent here.
- `run_security.sh` always snapshots with GNU `find -printf`; the scripts require Linux/GNU
  userland (Arch default).

## 12. v1.2 harnesses — append/update, exclusion, fuzz

| Tool | Cases | What it proves |
|---|---|---|
| `tools/test_append.sh` | 68 | `btar -rf/-uf` vs GNU tar 1.35: same exit status, original bytes preserved up to the old logical end, exact 1024-byte trailer (`tools/tar_end.py` is an independent oracle), GNU/bsdtar read the result, normalised `tar -tv` listing and extracted tree equal. Error cases (corrupt/truncated/gzip archive, missing/absolute/`..` operand, `-z`, option clashes, directory/`-` as archive) require exit 2 and a byte-identical archive. `-u`: newer/older/equal mtime, size-only change, new names, deleted files, dir mtime, hardlink pairs, type changes, symlink retarget, long names, pax archives, `-C .`, repeated updates. |
| `tools/fuzz_append.py` | N (seeded) | mutated archives (3 formats) through `-rf`/`-uf`: exit ∈ {0,1,2}; exit 2 ⇒ byte-identical; success ⇒ prefix + trailer intact and GNU readability preserved. Run on the release binary (300) and the ASan binary (120). |
| `tools/test_exclude.sh` | 208 | 129 pattern × name list comparisons against GNU (one archive of ~90 hand-picked names), create/append/update/list/extract with `--exclude`, `--exclude-from`, `-X`, `--no-recursion`, gzip, `-v`, `--strip-components` regressions, pattern-file whitespace rules, error exits. |
| `tests/test_upd.bend`, `tests/test_glob.bend` | unit | `-u` name normalisation/lookup tree; 70 pattern/name expectations recorded from GNU. |
| `tools/run_asan.sh` (append phase) | 25 | `-rf` + `-uf` over every valid fixture under ASan/UBSan (exit 2 allowed, sanitizer reports are failures). |

`tools/compare_tree.py --unordered` compares listings as sorted multisets (used for `-u`, where GNU's
append order differs).
