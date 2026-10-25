#!/usr/bin/env python3
"""Independent logical-end finder for uncompressed tar archives (test oracle).

Prints `END <offset>` (offset of the first all-zero 512-byte block, or the file
size when the end blocks are missing) and, with --strict, exits 1 unless the
file is exactly END + 1024 bytes of zeros (btar's own trailer, no padding).
Exit 2 on a malformed/truncated archive.
"""
import sys

DATA = set(b"0\x007xgLKDSMVN")


def num(field: bytes) -> int:
    if field[0] & 0x80:
        return int.from_bytes(bytes([field[0] & 0x7F]) + field[1:], "big")
    text = field.split(b"\0")[0].strip()
    return int(text or b"0", 8)


def end_of(data: bytes) -> int:
    off = 0
    while off < len(data):
        blk = data[off:off + 512]
        if len(blk) < 512:
            raise ValueError(f"partial header block at {off}")
        if blk == b"\0" * 512:
            return off
        size = num(blk[124:136]) if blk[156] in DATA else 0
        off += 512 + (size + 511) // 512 * 512
        if off > len(data):
            raise ValueError("member data past EOF")
    return len(data)


def main() -> int:
    strict = "--strict" in sys.argv
    path = [a for a in sys.argv[1:] if not a.startswith("--")][0]
    data = open(path, "rb").read()
    try:
        end = end_of(data)
    except (ValueError, IndexError) as exc:
        print(f"BAD {exc}")
        return 2
    print(f"END {end}")
    if strict and data[end:] != b"\0" * 1024:
        print(f"TRAILER {len(data) - end} bytes")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
