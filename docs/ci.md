# Continuous integration

Everything CI does goes through one script, so the local and the hosted runs are the same thing:

```sh
./tools/ci.sh --quick      # pull-request mode: ~2 min, 17 sections, ASan/fuzz/HEAVY proofs skipped
./tools/ci.sh --full       # default: the whole release gate (ASan/UBSan, fuzz, heavy proofs, M6)
./tools/ci.sh --no-install # fail instead of downloading the toolchain
```

`tools/ci.sh`

1. checks the host tools (clang ≥ 14, **GNU** tar, bsdtar, gzip, python3 ≥ 3.11, sha256sum,
   timeout, file; Linux x86-64 only);
2. installs the pinned Bend **2.0.39** into `.cache/toolchain` unless it is already there
   (`bend-2.0.39-linux-x64.tar.gz`, sha256
   `6cf462fd8f70b094a4950ebb709a9c4ffd8f1d1189d9cedf1fd63cd5d041c7ab`, enforced even with
   `BEND_URL=<mirror>`; the global `~/.bend` is never used);
3. runs `./tools/test_release.sh` (`--quick` or full) and prints the `btar --version` and sha256.

Exit status: 0 gate PASS, 1 gate FAIL, 2 setup error.

## GitHub Actions — `.github/workflows/ci.yml`

| trigger | job | runs |
|---|---|---|
| pull request | `gate` | `tools/ci.sh --quick` |
| push to `main`, weekly cron (`17 3 * * 1`), manual | `gate` | `tools/ci.sh --full`, then `tools/package.sh`, checks `dist/btar == build/btar`, uploads `dist/{btar,*.tar.gz,SHA256SUMS}` as an unsigned workflow artifact |

Runner `ubuntu-24.04` (kernel ≥ 6.x for `openat2`, GNU tar 1.35, clang 18); the Bend toolchain is
cached by its pinned sha256. The workflow file has been parsed (`yaml.safe_load`) but **has not been
run**: this checkout has no git remote and no network access to GitHub from the build sandbox.

## What is intentionally missing

- **Signing / provenance**: no GPG/minisign/cosign key, no SLSA/artifact attestation — the workflow
  uploads unsigned artifacts plus `SHA256SUMS`. To add: a signing key in repository secrets and a
  `cosign sign-blob` / `minisign` step after `package.sh`.
- **Publishing**: no GitHub Release creation, no package-registry push, no tag automation (needs a
  git repository with tags and a token with `contents: write`). `dist/` is the hand-off point.
- **Other platforms**: Linux x86-64 only (openat2/Bend native target); no macOS/Windows/arm64 jobs.
- **Toolchain mirror**: the Bend release is fetched from GitHub; air-gapped CI should set
  `BEND_URL` to an internal mirror (the sha256 is still checked).
- **Performance tracking**: `tools/bench_release.sh` is not run in CI (shared-runner noise); run it
  locally and commit `bench/RESULTS.md`.

## Release checklist (manual, in this order)

1. `./tools/ci.sh --full` — all 17 sections PASS, 0 fail, 0 skip.
2. `./tools/package.sh` — rebuilds `build/btar` the same way as the gate, checks that
   `btar --version` equals `VERSION`, writes `dist/btar`, `dist/btar-<ver>-linux-x64.tar.gz`,
   `dist/tar-bend-<ver>-src.tar.gz` and `dist/SHA256SUMS` (the single place package hashes are
   recorded; documents refer to that file instead of embedding their own package hash).
3. `cmp build/btar dist/btar` and compare with the sha256 in `docs/release-verification.md`.
4. (Not automated) sign `dist/SHA256SUMS`, tag, publish.
