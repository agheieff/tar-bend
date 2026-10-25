# AGENTS.md — tar-bend

Project-specific rules for agents working in this checkout. Global Arcadia rules apply
(`/home/agheieff/Arcadia/AGENTS.md`): use `uv` for Python, TypeScript over JS where relevant,
Arch/pacman ecosystem, small modular files, strict typing, 100-col, fail fast, concise output,
whitelist `.gitignore`.

## Objective

Implement the plan in `plan/full-tar.md`: a full tar archiver in Bend 2 (`btar`) with a proven pure
core (format, path policy, limits) and small trusted C effects for filesystem/syscall/data-plane
work. Read the plan before touching code.

## Toolchain

- Bend: **2.0.39** pinned, **project-local** at `.cache/toolchain/bin/bend` (the global `~/.bend` is
  2.0.38 and must not be used here). Setup: download
  `https://github.com/bendlang/bend/releases/download/v2.0.39/bend-2.0.39-linux-x64.tar.gz`,
  verify `sha256 6cf462fd8f70b094a4950ebb709a9c4ffd8f1d1189d9cedf1fd63cd5d041c7ab`, extract with
  `--strip-components=1` into `.cache/toolchain/`; then
  `export PATH="$PWD/.cache/toolchain/bin:$PATH"` and check `bend version` = `bend 2.0.39`.
  `bend guide`, `bend base`, `bend --help` work the same. `tools/run.sh` is the pinned gate.
- clang 14+ (19+ for GPU, not needed here); Linux x86-64, kernel ≥ 5.6 (openat2).
- No Node/Python at runtime; Python 3.11+ only for `tools/` fixture/diff scripts (`uv` for env if
  dependencies appear; prefer stdlib only).
- No C ABI is exposed by Bend: ship a CLI binary, never claim `libtar`-style embedding.

## Code rules

- `src/` is pure Bend: no effects, no `@unsafe`, must terminate structurally. This is the proof core.
- `effs/` is C + JS stubs and is the **only** trusted C. Effects are IO-only and ABI-coupled to the
  compiler: everything effect-facing lives here; each effect hands handles back on every path.
- Bytes are bytes: archive names/links/paths are `Bytes` (packed `Array<U32>` or `List<U32>`), never
  `String`. Human output may use `String`.
- Every array/list access is bounds-checked through the `Bytes` module; raw indexing is forbidden
  (Bend indices wrap silently).
- Small modules, explicit types, 100-col, fail fast (return `Result`; `IO.die` only for CLI fatal).
- No loops/if/goto in Bend: tail-recursive defs, shrinking argument first, no mutual recursion.
- `app/` and `effs/` are outside the proof target; `proofs/PROOF.bend` imports only pure modules.

## Gates

Before any commit/milestone:
1. `bend version` matches pin; `tools/abi_check.sh` passes before native builds.
2. `bend --check-only` on every `.bend`.
3. `bend PROOF.bend` → `ALL PROOFS CHECK`; `bend PROOF.bend --verdict` where feasible.
4. `./run.sh test` green (unit, differential vs GNU tar/bsdtar, security corpus, ASan suite).
5. No regression in `bench/` numbers beyond 20% without a note in docs.

## Safety invariants (non-negotiable)

- Reject absolute paths and `..`; apply strip-components before validation; enforce component/total
  path limits.
- Never follow symlinks during extraction (openat2 + O_NOFOLLOW); hardlinks only to previously
  extracted regular files under the destination root.
- Refuse device/FIFO creation; strip setuid/setgid by default; no chown unless root + explicit flag.
- Enforce member/size/header limits; refuse >4 GiB in v1 with a clear error (no wraparound).
- C effects take a directory handle + a Bend-validated relative byte path; no path joining in C.
- Dedicated regression tests for CVE-2026-18508 (`--one-top-level` hardlink escape) and the other
  archive CVEs listed in the plan.

## Testing

- `tests/*.bend` self-checks; `tools/gen_fixtures.py` regenerates valid+adversarial fixtures;
  `tools/run_diff.sh` compares against GNU tar/bsdtar; `tools/run_security.sh` proves no escape;
  fuzz under timeout; ASan/UBSan build for effects.
- No Bend test framework: failures exit non-zero (`IO.die`) with actionable messages.
- Test with the JS lane where possible (fast), native builds in CI; native is the release artifact.

## Workflow

- Shared task board; one owner per write scope. Do not edit another module's files without asking.
- Update `docs/` notes per milestone; keep `plan/full-tar.md` current when a decision changes.
- Report compiler bugs with minimal `.bend` repros under `docs/upstream/`; do not patch `~/.bend`.
- Keep generated fixtures out of git; whitelist is in `.gitignore`.
