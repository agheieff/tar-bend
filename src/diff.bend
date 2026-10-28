# Module: Diff — `btar -d`: compare one archive header with the file system (pure part).
#
# `st` is the lstat vector of Fs.stat_path: [type, mode, nlink, uid, gid, size, mtime,
# ino_lo, ino_hi, dev_lo, dev_hi] with type = S_IFMT >> 12 (8 reg, 4 dir, 10 link, ...).
# Messages are the GNU texts; the caller prints "NAME: message".
import Base
import ./bytes.bend as B
import ./num.bend as N

type Dm is Data:
  MkDm{msgs: List<&2, List<&2, U32>>, cmp: Bool}

def bs(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bs(t)

def msg_if(bad: Bool, m: String, rest: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match bad:
    case True{}:
      bs(m) <> rest
    case False{}:
      rest

# Expected S_IFMT>>12 for a tar typeflag (0 when the type is not checked).
def want_type(+tf: U32) -> U32:
  match tf:
    case 0:
      8
    case 48:
      8
    case 55:
      8
    case 53:
      4
    case 50:
      10
    case 51:
      2
    case 52:
      6
    case 54:
      1
    case _:
      0

def ne(+a: U32, +b: U32) -> Bool:
  Bool.not(U32.is_eq(a, b))

# Metadata messages shared by files and directories (mtime only for files).
def meta_msgs(+mode: U32, +uid: U32, +gid: U32, +mt: U32, +file: Bool,
  +st: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  msg_if(ne(U32.and(mode, 4095), N.nth(st, 1n)), "Mode differs",
    msg_if(ne(uid, N.nth(st, 3n)), "Uid differs",
      msg_if(ne(gid, N.nth(st, 4n)), "Gid differs",
        msg_if(Bool.and(file, ne(mt, N.nth(st, 6n))), "Mod time differs", rest))))

def by_type(+want: U32, +have: U32, +mode: U32, +uid: U32, +gid: U32, +mt: U32,
  +size: U32, +st: List<&2, U32>) -> Dm:
  match want:
    case 8:
      MkDm{meta_msgs(mode, uid, gid, mt, True{}, st,
        msg_if(ne(size, N.nth(st, 5n)), "Size differs", Nil{})),
        U32.is_eq(size, N.nth(st, 5n))}
    case 4:
      MkDm{meta_msgs(mode, uid, gid, mt, False{}, st, Nil{}), False{}}
    case _:
      MkDm{Nil{}, False{}}

def check2(same: Bool, +tf: U32, +mode: U32, +uid: U32, +gid: U32, +mt: U32,
  +size: U32, +st: List<&2, U32>) -> Dm:
  match same:
    case True{}:
      by_type(want_type(tf), N.nth(st, 0n), mode, uid, gid, mt, size, st)
    case False{}:
      MkDm{bs("File type differs") <> Nil{}, False{}}

def check(+tf: U32, +mode: U32, +uid: U32, +gid: U32, +mt: U32, +size: U32,
  +st: List<&2, U32>) -> Dm:
  check2(U32.is_eq(want_type(tf), N.nth(st, 0n)), tf, mode, uid, gid, mt, size, st)

# Same inode on the same device (hard links).
def same_file(+a: List<&2, U32>, +b: List<&2, U32>) -> Bool:
  Bool.and(U32.is_eq(N.nth(a, 7n), N.nth(b, 7n)),
    Bool.and(U32.is_eq(N.nth(a, 8n), N.nth(b, 8n)),
      Bool.and(U32.is_eq(N.nth(a, 9n), N.nth(b, 9n)),
        U32.is_eq(N.nth(a, 10n), N.nth(b, 10n)))))
