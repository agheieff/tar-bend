# `--transform` / `--xform` (v1.3)

`--transform=s/REGEXP/REPLACEMENT/[FLAGS]` (also `--xform`, and as a separate argument; repeatable,
applied in command-line order) rewrites member names and link targets.

| Where | What is rewritten |
|---|---|
| create / append / update | stored name, symlink target, hardlink target (the file is still read from its real path); `-v` prints the new name |
| extract | name and link targets, **before** `--strip-components`; the result still goes through the path policy (absolute/`..` refused) |
| list, `--exclude`, member operands | not affected (they see stored names), as in GNU |

Directory names are transformed without their trailing `/` (GNU); a hardlink target loses leading
`/` after the transform on create.

## Supported syntax

Regexp (POSIX BRE subset): literals, `.`, `[set]`, `[^set]` with ranges, `*`, `\+`, `\?` on one
atom, `^` / `$` anchors, `\(...\)` groups (not quantifiable). Replacement: literals, `&`, `\0`–`\9`,
`\n`. The delimiter may be any byte; `\<delim>` is a literal delimiter. Flags: `g`, `i` (ASCII).

Refused with exit 2 before anything is written: back-references in the regexp, `\|`, `\{…\}`,
unterminated `[` or `\(`, flags other than `g`/`i` (`x`, `r`, `s`, `h`), malformed `s///`.
A `/` inside `[...]` ends the regexp part (as in GNU tar, unlike sed).

## Verification

`src/xform.bend` is pure; `tests/test_xform.bend` compares ~350 expression/name pairs with GNU
sed (including `g`, `i`, groups, anchors, empty matches). `tools/test_transform.sh` (54 checks)
compares created archives (name, type, link target) and extracted trees with GNU tar 1.35.

Notes: matching is backtracking greedy with a step budget (a budget overrun means "no match",
never a hang); GNU 1.35 itself loops forever on `s/o*/-/g` for some names, so that case is covered
only against sed.
