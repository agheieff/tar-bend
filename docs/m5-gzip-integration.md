# gzip integration in `btar` (`-z`, auto-detect, `-czf`) — CLI contract

> **Superseded in v1.1.0.** The M5/v1.0 implementation (whole-stream buffering in `List<U32>`,
> memfd staging, 8 / 8 / 16 MiB caps, stored-then-fixed-Huffman compression) was replaced by the
> streaming codec described in [gzip.md](gzip.md). The command-line behavior below is unchanged;
> the limits and the buffering strategy of v1.0 no longer apply (see
> [sanity-check.md](sanity-check.md) for the defects that motivated the rewrite).

## CLI and behavior

```
btar -tzf ARCHIVE        btar -tf ARCHIVE             # explicit -z / auto-detect
btar -xzf ARCHIVE -C D   btar -xf ARCHIVE -C D       # list/extract gzip
btar -czf OUT.tar.gz -C DIR .                        # create gzip (bundled)
btar -cvzf ...   btar -c -z -f ...   btar --gzip ... # other spellings
```

- `-z`/`--gzip` accepted for list/extract/create. Bundled forms (`-tzf`, `-xzf`, `-cvzf`, `-O`
  combos, `-c -z -f`) are handled by scanning byte tokens for the `z` flag char, then stripping it
  before the byte-safe parsers; argv stays raw bytes end to end.
- **Read**: the archive is opened with `File.open_bytes`; the first two bytes are probed with
  `Stream.read_exact(2)`. A non-gzip file is rewound and read by the unchanged streaming reader. On
  gzip magic (or any input with explicit `-z`) the file is rewound and a forked decoder pump feeds
  the same reader through a pipe — so `-t/-x/-O/-C/-v/-p/--one-top-level/--strip-components`
  semantics are identical to plain tar. `-z` on non-gzip input is fatal exit 2; corrupt, truncated,
  bad CRC/ISIZE and invalid DEFLATE data exit 2 with a gzip-specific message
  (`btar: gzip: truncated gzip stream`, `corrupt or invalid gzip data`, `bad gzip magic`, …).
- **Create**: without `-z` the writer streams to the output file. With `-z` the writer runs in a
  fork feeding a pipe and the main computation compresses it into the output file; exit codes
  0/1/2 are preserved (a skipped special file still gives exit 1 with a valid archive).
- **Root metadata**: `collect` `fstatx`es the opened root dirfd and emits the real `./` entry
  (mode/uid/gid/mtime) like GNU tar.

## Effects used by the gzip paths

| effect | purpose |
|---|---|
| `Fs.pipe()` | anonymous pipe `(read end, write end)` between the pump and the tar reader/writer |
| `Fs.dup_file(fd)` | duplicate the read end so the reader may close its copy while the caller drains |
| `Stream.read_exact(fd, n)` | decoder input chunks (256 KiB); tar-writer pipe reads are done with `read_seg` |
| `Stream.read_seg(fd, n, tail)` | compressor input: a segment plus its last `tail` bytes, built in C |
| `Stream.write_bytes(fd, bytes)` | decoder output into the pipe; compressed pieces into the file |
| `Stream.rewind(fd)` | auto-detect probe and restart of the decoder |

See [effects.md](effects.md) for the signatures and the inline-vs-helper-thread execution rule.

## Evidence

`tools/test_gzip.sh` (27 fixture checks + 10 streaming checks), `tests/test_gzip.bend`,
`tools/test_gzip_stream.py`, release gate section 15 — see [release-verification.md](release-verification.md).
