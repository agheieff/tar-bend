# Option coverage (generated from `tools/gen_cli_table.py`)

Every GNU tar 1.35 option below is recognised by the parser (`app/cli.bend`); status shows what happens next.

| Option | Takes value | Status |
|---|---|---|
| `-A`, `--catenate` | no | implemented |
| `--concatenate` | no | implemented |
| `-c`, `--create` | no | implemented |
| `-d`, `--diff` | no | implemented |
| `--compare` | no | implemented |
| `--delete` | no | implemented |
| `-r`, `--append` | no | implemented |
| `-t`, `--list` | no | implemented |
| `--test-label` | no | refused (exit 2) |
| `-u`, `--update` | no | implemented |
| `-x`, `--extract` | no | implemented |
| `--get` | no | implemented |
| `--check-device` | no | accepted, no effect |
| `--no-check-device` | no | accepted, no effect |
| `-g`, `--listed-incremental` | yes | refused (exit 2) |
| `-G`, `--incremental` | no | refused (exit 2) |
| `--hole-detection` | yes | accepted, no effect |
| `--ignore-failed-read` | no | refused (exit 2) |
| `--level` | yes | refused (exit 2) |
| `-n`, `--seek` | no | accepted, no effect |
| `--no-seek` | no | accepted, no effect |
| `--occurrence` | optional | refused (exit 2) |
| `--sparse-version` | yes | refused (exit 2) |
| `-S`, `--sparse` | no | refused (exit 2) |
| `--keep-directory-symlink` | no | refused (exit 2) |
| `-k`, `--keep-old-files` | no | implemented |
| `--keep-newer-files` | no | implemented |
| `--no-overwrite-dir` | no | refused (exit 2) |
| `--one-top-level` | optional | implemented |
| `--overwrite` | no | implemented |
| `--overwrite-dir` | no | refused (exit 2) |
| `--recursive-unlink` | no | refused (exit 2) |
| `--remove-files` | no | implemented |
| `--skip-old-files` | no | implemented |
| `-U`, `--unlink-first` | no | implemented |
| `-W`, `--verify` | no | refused (exit 2) |
| `--ignore-command-error` | no | refused (exit 2) |
| `--no-ignore-command-error` | no | refused (exit 2) |
| `-O`, `--to-stdout` | no | implemented |
| `--to-command` | yes | refused (exit 2) |
| `--atime-preserve` | optional | refused (exit 2) |
| `-m`, `--touch` | no | implemented |
| `--delay-directory-restore` | no | accepted, no effect |
| `--no-delay-directory-restore` | no | accepted, no effect |
| `--group` | yes | implemented |
| `--group-map` | yes | refused (exit 2) |
| `--mode` | yes | implemented |
| `--mtime` | yes | implemented |
| `--no-same-owner` | no | refused (exit 2) |
| `--no-same-permissions` | no | refused (exit 2) |
| `--numeric-owner` | no | implemented |
| `-o` | no | refused (exit 2) |
| `--owner` | yes | implemented |
| `--owner-map` | yes | refused (exit 2) |
| `-p`, `--preserve-permissions` | no | implemented |
| `--same-permissions` | no | implemented |
| `--preserve` | no | refused (exit 2) |
| `-s`, `--preserve-order` | no | accepted, no effect |
| `--same-order` | no | accepted, no effect |
| `--same-owner` | no | refused (exit 2) |
| `--sort` | yes | implemented |
| `--acls` | no | refused (exit 2) |
| `--no-acls` | no | accepted, no effect |
| `--selinux` | no | refused (exit 2) |
| `--no-selinux` | no | accepted, no effect |
| `--xattrs` | no | refused (exit 2) |
| `--no-xattrs` | no | accepted, no effect |
| `--xattrs-include` | yes | refused (exit 2) |
| `--xattrs-exclude` | yes | refused (exit 2) |
| `--force-local` | no | accepted, no effect |
| `-f`, `--file` | yes | implemented |
| `-F`, `--info-script` | yes | refused (exit 2) |
| `--new-volume-script` | yes | refused (exit 2) |
| `-L`, `--tape-length` | yes | refused (exit 2) |
| `-M`, `--multi-volume` | no | refused (exit 2) |
| `--rmt-command` | yes | refused (exit 2) |
| `--rsh-command` | yes | refused (exit 2) |
| `--volno-file` | yes | refused (exit 2) |
| `-b`, `--blocking-factor` | yes | accepted, no effect |
| `-B`, `--read-full-records` | no | accepted, no effect |
| `-i`, `--ignore-zeros` | no | refused (exit 2) |
| `--record-size` | yes | accepted, no effect |
| `-H`, `--format` | yes | implemented |
| `--old-archive` | no | refused (exit 2) |
| `--portability` | no | refused (exit 2) |
| `--pax-option` | yes | refused (exit 2) |
| `--posix` | no | refused (exit 2) |
| `-V`, `--label` | yes | refused (exit 2) |
| `-a`, `--auto-compress` | no | refused (exit 2) |
| `-I`, `--use-compress-program` | yes | refused (exit 2) |
| `-j`, `--bzip2` | no | refused (exit 2) |
| `-J`, `--xz` | no | refused (exit 2) |
| `--lzip` | no | refused (exit 2) |
| `--lzma` | no | refused (exit 2) |
| `--lzop` | no | refused (exit 2) |
| `--no-auto-compress` | no | accepted, no effect |
| `-z`, `--gzip` | no | implemented |
| `--gunzip` | no | implemented |
| `--ungzip` | no | implemented |
| `-Z`, `--compress` | no | refused (exit 2) |
| `--uncompress` | no | refused (exit 2) |
| `--zstd` | no | refused (exit 2) |
| `--add-file` | yes | refused (exit 2) |
| `--backup` | optional | refused (exit 2) |
| `-C`, `--directory` | yes | implemented |
| `--exclude` | yes | implemented |
| `--exclude-backups` | no | implemented |
| `--exclude-caches` | no | refused (exit 2) |
| `--exclude-caches-all` | no | refused (exit 2) |
| `--exclude-caches-under` | no | refused (exit 2) |
| `--exclude-ignore` | yes | refused (exit 2) |
| `--exclude-ignore-recursive` | yes | refused (exit 2) |
| `--exclude-tag` | yes | refused (exit 2) |
| `--exclude-tag-all` | yes | refused (exit 2) |
| `--exclude-tag-under` | yes | refused (exit 2) |
| `--exclude-vcs` | no | implemented |
| `--exclude-vcs-ignores` | no | refused (exit 2) |
| `-h`, `--dereference` | no | refused (exit 2) |
| `--hard-dereference` | no | refused (exit 2) |
| `-K`, `--starting-file` | yes | refused (exit 2) |
| `--newer-mtime` | yes | implemented |
| `--no-null` | no | refused (exit 2) |
| `--no-recursion` | no | implemented |
| `--no-unquote` | no | refused (exit 2) |
| `--null` | no | refused (exit 2) |
| `-N`, `--newer` | yes | implemented |
| `--after-date` | yes | implemented |
| `--one-file-system` | no | refused (exit 2) |
| `-P`, `--absolute-names` | no | refused (exit 2) |
| `--recursion` | no | implemented |
| `--suffix` | yes | refused (exit 2) |
| `-T`, `--files-from` | yes | implemented |
| `--unquote` | no | refused (exit 2) |
| `-X`, `--exclude-from` | yes | implemented |
| `--verbatim-files-from` | no | refused (exit 2) |
| `--no-verbatim-files-from` | no | refused (exit 2) |
| `--anchored` | no | refused (exit 2) |
| `--no-anchored` | no | implemented |
| `--ignore-case` | no | refused (exit 2) |
| `--no-ignore-case` | no | implemented |
| `--wildcards` | no | refused (exit 2) |
| `--no-wildcards` | no | refused (exit 2) |
| `--wildcards-match-slash` | no | implemented |
| `--no-wildcards-match-slash` | no | refused (exit 2) |
| `--checkpoint` | optional | refused (exit 2) |
| `--checkpoint-action` | yes | refused (exit 2) |
| `--clamp-mtime` | no | refused (exit 2) |
| `--full-time` | no | implemented |
| `--index-file` | yes | refused (exit 2) |
| `-l`, `--check-links` | no | refused (exit 2) |
| `--no-quote-chars` | yes | accepted, no effect |
| `--quote-chars` | yes | accepted, no effect |
| `--quoting-style` | yes | accepted, no effect |
| `-R`, `--block-number` | no | refused (exit 2) |
| `--show-defaults` | no | refused (exit 2) |
| `--show-omitted-dirs` | no | refused (exit 2) |
| `--show-transformed-names` | no | refused (exit 2) |
| `--show-stored-names` | no | refused (exit 2) |
| `--totals` | optional | refused (exit 2) |
| `--utc` | no | implemented |
| `-v`, `--verbose` | no | implemented |
| `-w`, `--interactive` | no | refused (exit 2) |
| `--confirmation` | no | refused (exit 2) |
| `--warning` | yes | accepted, no effect |
| `--strip-components` | yes | implemented |
| `--transform` | yes | implemented |
| `--xform` | yes | implemented |
| `-q`, `--fast-read` | no | refused (exit 2) |
| `--restrict` | no | accepted, no effect |
| `--usage` | no | implemented |
| `-?`, `--help` | no | implemented |
| `--version` | no | implemented |
| `--quiet` | no | accepted, no effect |

56 implemented, 94 refused, 23 accepted and ignored.

Notes: `--newer` and `--after-date` compare mtime only (GNU also looks at ctime); `-vv` on create prints names like `-v`.
