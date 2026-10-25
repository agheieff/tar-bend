# tests/test_encode.bend — M3 encoders: ustar header + pax records.
import Base
import ../src/header.bend as H
import ../src/bytes.bend as B
import ../src/checksum.bend as C
import ../src/pax.bend as P
import ../src/num.bend as N
import ./canon_ustar.bend as Canon
import ./lib.bend as T

def rep(+v: U32, n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      v <> rep(v, p)

def blk_show(blk: List<&2, U32>) -> IO(Unit):
  IO.print("block len=" ++ Nat.show(List.length(&2, U32, blk)))

# ---- header round-trip ------------------------------------------------

def mk_header(
  name: List<&2, U32>, mode: U32, uid: U32, gid: U32, size: U32,
  mtime: U32, tflag: U32, link: List<&2, U32>, uname: List<&2, U32>,
  gname: List<&2, U32>
) -> H.Header:
  H.MkHeader{name, mode, uid, gid, size, mtime, tflag, link, 1, uname, gname,
    0, 0, Nil{}}

def check_hdr(+orig: H.Header, +got: H.Header) -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- T.check(
      B.eq_list(H.full_name(orig), H.full_name(got), True{}),
      "round-trip full name")
    +b : Unit <- T.check_u32(H.h_mode(got), H.h_mode(orig), "mode")
    +c : Unit <- T.check_u32(H.h_uid(got), H.h_uid(orig), "uid")
    +d : Unit <- T.check_u32(H.h_gid(got), H.h_gid(orig), "gid")
    +e : Unit <- T.check_u32(H.h_size(got), H.h_size(orig), "size")
    +f : Unit <- T.check_u32(H.h_mtime(got), H.h_mtime(orig), "mtime")
    +g : Unit <- T.check_u32(H.h_typeflag(got), H.h_typeflag(orig), "typeflag")
    +i : Unit <- T.check(
      B.eq_list(H.h_linkname(got), H.h_linkname(orig), True{}), "linkname")
    +j : Unit <- T.check(
      B.eq_list(H.h_uname(got), H.h_uname(orig), True{}), "uname")
    +k : Unit <- T.check(
      B.eq_list(H.h_gname(got), H.h_gname(orig), True{}), "gname")
    IO.pure(Unit, Unit{})

def check_parse(+orig: H.Header, r: Result<&1, &1, String, H.Header>) -> IO(Unit):
  match r:
    case Fail{msg}:
      IO.die(Unit, 1, "FAIL: encoded block does not parse: " ++ msg)
    case Done{got}:
      check_hdr(orig, got)

def check_parse2(orig: H.Header, r: Result<&1, &1, String, H.Header>) -> IO(Unit):
  match r:
    case Fail{msg}:
      IO.die(Unit, 1, "FAIL: encoded block does not parse: " ++ msg)
    case Done{got}:
      check_hdr(orig, got)

def enc_pair(
  +orig: H.Header, r: Result<&1, &1, H.EncErr, List<&2, U32>>
) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.die(Unit, 1, "FAIL: encode rejected: " ++ H.enc_err_show(e))
    case Done{+blk}:
      do IO<Unit>:
        T.check_nat(List.length(&2, U32, blk), 512n,
          "encoded block length 512")
        T.check_u32(N.or0(N.decode_octal(B.slice_list(blk, 148n, 8n))),
          C.compute_list(blk), "chksum field == checksum of block")
        check_parse2(orig, H.parse(B.from_list(blk)))

def roundtrip() -> IO(Unit):
  +b : H.Header = mk_header([97, 98, 99], 420, 1000, 1000, 123, 1700000000,
    48, Nil{}, [117, 115, 101, 114], [103, 114, 111, 117, 112])
  enc_pair(b, H.encode(b))

def roundtrip_dir() -> IO(Unit):
  +b : H.Header = mk_header([100, 105, 114, 47], 493, 0, 0, 0, 1700000001,
    53, Nil{}, Nil{}, Nil{})
  enc_pair(b, H.encode(b))

def long_name() -> IO(Unit):
  +long = B.list_cat(rep(112, 60n), B.list_cat(47 <> Nil{}, rep(97, 80n)))
  +b : H.Header = mk_header(long, 420, 0, 0, 7, 1700000002, 48, Nil{}, Nil{},
    Nil{})
  enc_pair(b, H.encode(b))

def enc_fail_field(
  r: Result<&1, &1, H.EncErr, List<&2, U32>>, msg: String
) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case H.EncField{}:
          IO.pure(Unit, Unit{})
        case H.EncName{}:
          IO.die(Unit, 1, "FAIL: " ++ msg ++ " gave EncName")
        case H.EncLink{}:
          IO.die(Unit, 1, "FAIL: " ++ msg ++ " gave EncLink")
    case Done{+blk}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " was accepted")

def overflow() -> IO(Unit):
  +b : H.Header = mk_header([97], 3000000, 0, 0, 0, 0, 48, Nil{}, Nil{},
    Nil{})
  enc_fail_field(H.encode(b), "mode overflow")

def enc_fail_name(
  r: Result<&1, &1, H.EncErr, List<&2, U32>>, msg: String
) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case H.EncName{}:
          IO.pure(Unit, Unit{})
        case H.EncField{}:
          IO.die(Unit, 1, "FAIL: " ++ msg ++ " gave EncField")
        case H.EncLink{}:
          IO.die(Unit, 1, "FAIL: " ++ msg ++ " gave EncLink")
    case Done{+blk}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " was accepted")

def bad_name() -> IO(Unit):
  +name = rep(97, 101n)
  +b : H.Header = mk_header(name, 420, 0, 0, 0, 0, 48, Nil{}, Nil{}, Nil{})
  enc_fail_name(H.encode(b), "long name without split")

def enc_fail_link(
  r: Result<&1, &1, H.EncErr, List<&2, U32>>, msg: String
) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case H.EncLink{}:
          IO.pure(Unit, Unit{})
        case H.EncField{}:
          IO.die(Unit, 1, "FAIL: " ++ msg ++ " gave EncField")
        case H.EncName{}:
          IO.die(Unit, 1, "FAIL: " ++ msg ++ " gave EncName")
    case Done{+blk}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " was accepted")

# ---- pax round-trip ---------------------------------------------------

def bad_link() -> IO(Unit):
  +link = rep(108, 101n)
  +b : H.Header = mk_header([97], 420, 0, 0, 0, 0, 50, link, Nil{}, Nil{})
  enc_fail_link(H.encode(b), "link too long")

def key_path() -> List<&2, U32>:
  112 <> (97 <> (116 <> (104 <> Nil{})))

def key_size() -> List<&2, U32>:
  115 <> (105 <> (122 <> (101 <> Nil{})))

def path_ok(m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: pax path missing")
    case Some{v}:
      T.check(B.eq_list(v, [97, 98, 99], True{}), "pax path round-trip")

def size_ok(m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: pax size missing")
    case Some{v}:
      T.check(B.eq_list(v, [52, 50], True{}), "pax size round-trip")

def none_list(m: Maybe<&2, List<&2, U32>>, msg: String) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{v}:
      False{}

def pax_check(p: P.Pax) -> IO(Unit):
  match p:
    case P.MkPax{path, linkpath, size, mtime, uid, gid, uname, gname}:
      do IO<Unit>:
        path_ok(path)
        size_ok(size)
        T.check(none_list(linkpath, "linkpath"), "pax linkpath absent")
        T.check(none_list(mtime, "mtime"), "pax mtime absent")
        IO.pure(Unit, Unit{})

def pax_parse(p: P.Pax) -> IO(Unit):
  pax_check(p)

def pax_emit() -> IO(Unit):
  +records : List<&2, P.Kv> = [P.Kv{key_path(), [97, 98, 99]}, P.Kv{key_size(), [52, 50]}]
  +payload = P.emit(records)
  +want : List<&2, U32> = [49, 50, 32, 112, 97, 116, 104, 61, 97, 98, 99, 10,
    49, 49, 32, 115, 105, 122, 101, 61, 52, 50, 10]
  +padded = P.pad_payload(payload)
  +plen = List.length(&2, U32, payload)
  do IO<Unit>:
    T.check(B.eq_list(payload, want, True{}), "pax record bytes/lengths")
    pax_check(P.parse(payload))
    T.check_u32(U32.from_nat(Nat.mod(List.length(&2, U32, padded), 512n)),
      0, "pax padding multiple of 512")
    T.check(B.eq_list(B.slice_list(padded, 0n, plen), payload, True{}),
      "pax padding preserves payload")

def main() -> IO(Unit):
  do IO<Unit>:
    u0 : Unit <- roundtrip()
    u1 : Unit <- roundtrip_dir()
    u2 : Unit <- long_name()
    u3 : Unit <- overflow()
    u4 : Unit <- bad_name()
    u5 : Unit <- bad_link()
    u6 : Unit <- pax_emit()
    IO.print("test_encode: OK")
