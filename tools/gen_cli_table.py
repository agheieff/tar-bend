#!/usr/bin/env python3
"""Generate app/cli_table.bend (option ids, spec table, support status) from SPEC below.

status: I implemented, U accepted by the parser but refused with exit 2 (not implemented),
        N accepted and ignored (no effect on a regular-file archive).
takes:  0 none, 1 required argument, 2 optional (attached with '=' or in the same cluster).
Run: python3 tools/gen_cli_table.py > app/cli_table.bend
"""
# (name, long, short, takes, status)
SPEC = [
    # operations
    ("catenate", "catenate", "A", 0, "I"), ("concat", "concatenate", None, 0, "I"),
    ("create", "create", "c", 0, "I"), ("diff", "diff", "d", 0, "I"), ("compare", "compare", None, 0, "I"),
    ("delete", "delete", None, 0, "I"), ("append", "append", "r", 0, "I"), ("list", "list", "t", 0, "I"),
    ("test_label", "test-label", None, 0, "U"), ("update", "update", "u", 0, "I"),
    ("extract", "extract", "x", 0, "I"), ("get", "get", None, 0, "I"),
    # operation modifiers
    ("check_device", "check-device", None, 0, "N"), ("no_check_device", "no-check-device", None, 0, "N"),
    ("listed_incremental", "listed-incremental", "g", 1, "U"), ("incremental", "incremental", "G", 0, "U"),
    ("hole_detection", "hole-detection", None, 1, "N"), ("ignore_failed_read", "ignore-failed-read", None, 0, "U"),
    ("level", "level", None, 1, "U"), ("seek", "seek", "n", 0, "N"), ("no_seek", "no-seek", None, 0, "N"),
    ("occurrence", "occurrence", None, 2, "U"), ("sparse_version", "sparse-version", None, 1, "U"),
    ("sparse", "sparse", "S", 0, "U"),
    # overwrite control
    ("keep_directory_symlink", "keep-directory-symlink", None, 0, "U"),
    ("keep_old_files", "keep-old-files", "k", 0, "I"), ("keep_newer_files", "keep-newer-files", None, 0, "I"),
    ("no_overwrite_dir", "no-overwrite-dir", None, 0, "U"), ("one_top_level", "one-top-level", None, 2, "I"),
    ("overwrite", "overwrite", None, 0, "I"), ("overwrite_dir", "overwrite-dir", None, 0, "U"),
    ("recursive_unlink", "recursive-unlink", None, 0, "U"), ("remove_files", "remove-files", None, 0, "I"),
    ("skip_old_files", "skip-old-files", None, 0, "I"), ("unlink_first", "unlink-first", "U", 0, "I"),
    ("verify", "verify", "W", 0, "U"),
    # output selection
    ("ignore_command_error", "ignore-command-error", None, 0, "U"),
    ("no_ignore_command_error", "no-ignore-command-error", None, 0, "U"),
    ("to_stdout", "to-stdout", "O", 0, "I"), ("to_command", "to-command", None, 1, "U"),
    # attributes
    ("atime_preserve", "atime-preserve", None, 2, "U"), ("touch", "touch", "m", 0, "I"),
    ("delay_directory_restore", "delay-directory-restore", None, 0, "N"),
    ("no_delay_directory_restore", "no-delay-directory-restore", None, 0, "N"),
    ("group", "group", None, 1, "I"), ("group_map", "group-map", None, 1, "U"), ("mode", "mode", None, 1, "I"),
    ("mtime", "mtime", None, 1, "I"), ("no_same_owner", "no-same-owner", None, 0, "U"),
    ("no_same_permissions", "no-same-permissions", None, 0, "U"), ("numeric_owner", "numeric-owner", None, 0, "I"),
    ("old_archive_o", None, "o", 0, "U"), ("owner", "owner", None, 1, "I"), ("owner_map", "owner-map", None, 1, "U"),
    ("preserve_permissions", "preserve-permissions", "p", 0, "I"), ("same_permissions", "same-permissions", None, 0, "I"),
    ("preserve", "preserve", None, 0, "U"), ("preserve_order", "preserve-order", "s", 0, "N"),
    ("same_order", "same-order", None, 0, "N"), ("same_owner", "same-owner", None, 0, "U"),
    ("sort", "sort", None, 1, "I"), ("acls", "acls", None, 0, "U"), ("no_acls", "no-acls", None, 0, "N"),
    ("selinux", "selinux", None, 0, "U"), ("no_selinux", "no-selinux", None, 0, "N"),
    ("xattrs", "xattrs", None, 0, "U"), ("no_xattrs", "no-xattrs", None, 0, "N"),
    ("xattrs_include", "xattrs-include", None, 1, "U"), ("xattrs_exclude", "xattrs-exclude", None, 1, "U"),
    # device / volume
    ("force_local", "force-local", None, 0, "N"), ("file", "file", "f", 1, "I"),
    ("info_script", "info-script", "F", 1, "U"), ("new_volume_script", "new-volume-script", None, 1, "U"),
    ("tape_length", "tape-length", "L", 1, "U"), ("multi_volume", "multi-volume", "M", 0, "U"),
    ("rmt_command", "rmt-command", None, 1, "U"), ("rsh_command", "rsh-command", None, 1, "U"),
    ("volno_file", "volno-file", None, 1, "U"),
    ("blocking_factor", "blocking-factor", "b", 1, "N"), ("read_full_records", "read-full-records", "B", 0, "N"),
    ("ignore_zeros", "ignore-zeros", "i", 0, "U"), ("record_size", "record-size", None, 1, "N"),
    # format
    ("format", "format", "H", 1, "I"), ("old_archive", "old-archive", None, 0, "U"),
    ("portability", "portability", None, 0, "U"), ("pax_option", "pax-option", None, 1, "U"),
    ("posix", "posix", None, 0, "U"), ("label", "label", "V", 1, "U"),
    # compression
    ("auto_compress", "auto-compress", "a", 0, "U"), ("use_compress_program", "use-compress-program", "I", 1, "U"),
    ("bzip2", "bzip2", "j", 0, "U"), ("xz", "xz", "J", 0, "U"), ("lzip", "lzip", None, 0, "U"),
    ("lzma", "lzma", None, 0, "U"), ("lzop", "lzop", None, 0, "U"), ("no_auto_compress", "no-auto-compress", None, 0, "N"),
    ("gzip", "gzip", "z", 0, "I"), ("gunzip", "gunzip", None, 0, "I"), ("ungzip", "ungzip", None, 0, "I"),
    ("compress", "compress", "Z", 0, "U"), ("uncompress", "uncompress", None, 0, "U"), ("zstd", "zstd", None, 0, "U"),
    # file selection
    ("add_file", "add-file", None, 1, "U"), ("backup", "backup", None, 2, "U"), ("directory", "directory", "C", 1, "I"),
    ("exclude", "exclude", None, 1, "I"), ("exclude_backups", "exclude-backups", None, 0, "I"),
    ("exclude_caches", "exclude-caches", None, 0, "U"), ("exclude_caches_all", "exclude-caches-all", None, 0, "U"),
    ("exclude_caches_under", "exclude-caches-under", None, 0, "U"), ("exclude_ignore", "exclude-ignore", None, 1, "U"),
    ("exclude_ignore_recursive", "exclude-ignore-recursive", None, 1, "U"),
    ("exclude_tag", "exclude-tag", None, 1, "U"), ("exclude_tag_all", "exclude-tag-all", None, 1, "U"),
    ("exclude_tag_under", "exclude-tag-under", None, 1, "U"), ("exclude_vcs", "exclude-vcs", None, 0, "I"),
    ("exclude_vcs_ignores", "exclude-vcs-ignores", None, 0, "U"),
    ("dereference", "dereference", "h", 0, "U"), ("hard_dereference", "hard-dereference", None, 0, "U"),
    ("starting_file", "starting-file", "K", 1, "U"), ("newer_mtime", "newer-mtime", None, 1, "I"),
    ("no_null", "no-null", None, 0, "U"), ("no_recursion", "no-recursion", None, 0, "I"),
    ("no_unquote", "no-unquote", None, 0, "U"), ("null", "null", None, 0, "U"),
    ("newer", "newer", "N", 1, "I"), ("after_date", "after-date", None, 1, "I"),
    ("one_file_system", "one-file-system", None, 0, "U"), ("absolute_names", "absolute-names", "P", 0, "U"),
    ("recursion", "recursion", None, 0, "I"), ("suffix", "suffix", None, 1, "U"),
    ("files_from", "files-from", "T", 1, "I"), ("unquote", "unquote", None, 0, "U"),
    ("exclude_from", "exclude-from", "X", 1, "I"), ("verbatim_files_from", "verbatim-files-from", None, 0, "U"),
    ("no_verbatim_files_from", "no-verbatim-files-from", None, 0, "U"),
    # name matching
    ("anchored", "anchored", None, 0, "U"), ("no_anchored", "no-anchored", None, 0, "I"),
    ("ignore_case", "ignore-case", None, 0, "U"), ("no_ignore_case", "no-ignore-case", None, 0, "I"),
    ("wildcards", "wildcards", None, 0, "U"), ("no_wildcards", "no-wildcards", None, 0, "U"),
    ("wildcards_match_slash", "wildcards-match-slash", None, 0, "I"),
    ("no_wildcards_match_slash", "no-wildcards-match-slash", None, 0, "U"),
    # informative
    ("checkpoint", "checkpoint", None, 2, "U"), ("checkpoint_action", "checkpoint-action", None, 1, "U"),
    ("clamp_mtime", "clamp-mtime", None, 0, "U"), ("full_time", "full-time", None, 0, "I"),
    ("index_file", "index-file", None, 1, "U"), ("check_links", "check-links", "l", 0, "U"),
    ("no_quote_chars", "no-quote-chars", None, 1, "N"), ("quote_chars", "quote-chars", None, 1, "N"),
    ("quoting_style", "quoting-style", None, 1, "N"), ("block_number", "block-number", "R", 0, "U"),
    ("show_defaults", "show-defaults", None, 0, "U"), ("show_omitted_dirs", "show-omitted-dirs", None, 0, "U"),
    ("show_transformed_names", "show-transformed-names", None, 0, "U"),
    ("show_stored_names", "show-stored-names", None, 0, "U"),
    ("totals", "totals", None, 2, "U"), ("utc", "utc", None, 0, "I"), ("verbose", "verbose", "v", 0, "I"),
    ("interactive", "interactive", "w", 0, "U"), ("confirmation", "confirmation", None, 0, "U"),
    # compatibility / misc
    ("warning", "warning", None, 1, "N"), ("strip_components", "strip-components", None, 1, "I"),
    ("transform", "transform", None, 1, "I"), ("xform", "xform", None, 1, "I"),
    ("fast_read", "fast-read", "q", 0, "U"), ("restrict", "restrict", None, 0, "N"),
    ("usage", "usage", None, 0, "I"), ("help", "help", "?", 0, "I"), ("version", "version", None, 0, "I"),
    ("quiet", "quiet", None, 0, "N"),
]

def main() -> None:
    out = ["# GENERATED by tools/gen_cli_table.py — do not edit.",
           "# Option ids, the spec table and the support status (I implemented, U refused, N ignored).",
           "import Base", "import ./cli_types.bend as T", ""]
    for i, (n, *_r) in enumerate(SPEC, start=2):
        out.append(f"def o_{n}() -> U32:\n  {i}\n")
    out.append("def table() -> List<&2, T.Sp>:")
    entries = []
    for i, (n, lg, sh, tk, _st) in enumerate(SPEC, start=2):
        lgs = f'T.bstr("{lg}")' if lg else "Nil{}"
        shs = str(ord(sh)) if sh else "0"
        entries.append(f"T.MkSp{{{lgs}, {shs}, {tk}, {i}}}")
    out.append("  " + " <>\n  ".join(entries) + " <>\n  Nil{}\n")
    # status: U ids -> True (refuse), N -> noop
    for kind, name in (("U", "refused"), ("N", "ignored")):
        ids = [i for i, (_n, _l, _s, _t, st) in enumerate(SPEC, start=2) if st == kind]
        out.append(f"def {name}(+id: U32) -> Bool:\n  match id:")
        for i in ids:
            out.append(f"    case {i}:\n      True{{}}")
        out.append("    case _:\n      False{}\n")
    # names for diagnostics
    out.append("def long_name(+id: U32) -> String:\n  match id:")
    for i, (n, lg, sh, _t, _st) in enumerate(SPEC, start=2):
        label = f"--{lg}" if lg else f"-{sh}"
        out.append(f'    case {i}:\n      "{label}"')
    out.append('    case _:\n      "option"\n')
    print("\n".join(out))

main()
