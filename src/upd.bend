# Module: Upd — pure helpers for `btar -u` (update): member-name
# normalisation, a small hash, and the "is the archived copy at least as new"
# test.
#
# The archive table is a flat list of Am{hash, mtime, name}; names are
# normalised (leading "./" and trailing "/" removed) so that "d/", "./d" and
# "d" are one member. A disk entry is skipped when some archived entry of the
# same normalised name has mtime >= the disk mtime (GNU `tar -u`: only
# strictly newer files are appended; seconds granularity).
import Base
import ./bytes.bend as B

type Am is Data:
  MkAm{h: U32, mt: U32, name: List<&2, U32>, raw: List<&2, U32>, end: U32}

# Remove every leading "./".
def strip_lead(fuel: Nat, xs: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      xs
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case h <> t:
          match h:
            case 46:
              match t:
                case Nil{}:
                  h <> t
                case h2 <> t2:
                  match h2:
                    case 47:
                      strip_lead(p, t2)
                    case _:
                      h <> (h2 <> t2)
            case _:
              h <> t

# Length of the trailing run of '/' bytes.
def trail_run(fuel: Nat, xs: List<&2, U32>, run: Nat) -> Nat:
  match fuel:
    case 0n:
      run
    case 1n+p:
      match xs:
        case Nil{}:
          run
        case h <> t:
          trail_run(p, t,
            Bool.pick(Nat, U32.is_eq(h, 47), Nat.add(run, 1n), 0n))

def norm_cut(+xs: List<&2, U32>) -> List<&2, U32>:
  +n = List.length(&2, U32, xs)
  List.take(&2, U32, xs,
    Nat.sub(n, trail_run(Nat.add(n, 1n), xs, 0n)))

def norm(xs: List<&2, U32>) -> List<&2, U32>:
  norm_cut(strip_lead(8192n, xs))

def hash_go(fuel: Nat, xs: List<&2, U32>, +acc: U32) -> U32:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case h <> t:
          hash_go(p, t, U32.add(U32.mul(acc, 31), U32.add(h, 1)))

def hash(+xs: List<&2, U32>) -> U32:
  hash_go(Nat.add(List.length(&2, U32, xs), 1n), xs, 5381)

# Table entry for an archive member (name already resolved: pax/longname).
def am_span(+name: List<&2, U32>, mt: U32, end: U32) -> Am:
  +n = norm(name)
  MkAm{hash(n), mt, n, name, end}

def am_new(name: List<&2, U32>, mt: U32) -> Am:
  am_span(name, mt, 0)

def am_match(a: Am, +h: U32, +nm: List<&2, U32>, +mt: U32) -> Bool:
  match a:
    case MkAm{ah, amt, an, _, _}:
      Bool.and(U32.is_eq(ah, h),
        Bool.and(U32.is_ge(amt, mt), B.eq_list(an, nm, True{})))

def am_h(a: Am) -> U32:
  match a:
    case MkAm{ah, amt, an, _, _}:
      ah

# `found` is threaded through so the scan stops at the first hit without a
# second (mutually recursive) helper.
def am_hit(fuel: Nat, found: Bool, xs: List<&2, Am>, +h: U32,
  +nm: List<&2, U32>, +mt: U32) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+p:
      match found:
        case True{}:
          True{}
        case False{}:
          match xs:
            case Nil{}:
              False{}
            case a <> t:
              am_hit(p, am_match(a, h, nm, mt), t, h, nm, mt)

def am_len(xs: List<&2, Am>) -> Nat:
  List.length(&2, Am, xs)

# The archive table: an unbalanced binary search tree keyed by name hash
# (hashes are well spread, so the depth stays ~2 log n); members with the
# same hash share a node's list.  Lookups are O(log n), not O(members).
type Tab is Data:
  TNil{}
  TNode{h: U32, es: List<&2, Am>, l: Tab, r: Tab}

def tab_ins(fuel: Nat, t: Tab, +a: Am) -> Tab:
  match fuel:
    case 0n:
      t
    case 1n+p:
      match t:
        case TNil{}:
          TNode{am_h(a), a <> Nil{}, TNil{}, TNil{}}
        case TNode{+h, +es, +l, +r}:
          +ah = am_h(a)
          +eq = U32.is_eq(ah, h)
          +lt = U32.is_lt(ah, h)
          +sub = tab_ins(p, Bool.pick(Tab, lt, l, r), a)
          TNode{h, Bool.pick(List<&2, Am>, eq, a <> es, es),
            Bool.pick(Tab, eq, l, Bool.pick(Tab, lt, sub, l)),
            Bool.pick(Tab, eq, r, Bool.pick(Tab, lt, r, sub))}

def tab_find(fuel: Nat, t: Tab, +h: U32, +nm: List<&2, U32>, +mt: U32) ->
  Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match t:
        case TNil{}:
          False{}
        case TNode{+th, +es, +l, +r}:
          +eq = U32.is_eq(h, th)
          Bool.pick(Bool, eq,
            am_hit(Nat.add(am_len(es), 1n), False{}, es, h, nm, mt),
            tab_find(p, Bool.pick(Tab, U32.is_lt(h, th), l, r), h, nm, mt))

def tab_add(t: Tab, a: Am) -> Tab:
  tab_ins(1048576n, t, a)

def skip_norm(+t: Tab, +nm: List<&2, U32>, +mt: U32) -> Bool:
  tab_find(1048576n, t, hash(nm), nm, mt)

# True when the archive already holds this name at least as new as `mt`.
# An empty table (create/append) never skips.
def skip(+t: Tab, name: List<&2, U32>, mt: U32) -> Bool:
  match t:
    case TNil{}:
      False{}
    case TNode{_, _, _, _}:
      skip_norm(t, norm(name), mt)

# ---- ordered member spans (--delete) ---------------------------------------
#
# The scan stores each member's raw stored name and the offset just past its
# data; sorted by that offset the table gives the member spans in archive
# order (member i covers [end(i-1), end(i)); metadata headers belong to the
# member that follows them).

def am_cat(xs: List<&2, Am>, ys: List<&2, Am>) -> List<&2, Am>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> am_cat(t, ys)

def tab_flat(+fuel: Nat, t: Tab, acc: List<&2, Am>) -> List<&2, Am>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match t:
        case TNil{}:
          acc
        case TNode{_, es, l, r}:
          tab_flat(p, l, am_cat(es, tab_flat(p, r, acc)))

def am_raw(a: Am) -> List<&2, U32>:
  match a:
    case MkAm{_, _, _, r, _}:
      r

def am_end(a: Am) -> U32:
  match a:
    case MkAm{_, _, _, _, e}:
      e

def am_merge(fuel: Nat, xs: List<&2, Am>, ys: List<&2, Am>) -> List<&2, Am>:
  match fuel:
    case 0n:
      am_cat(xs, ys)
    case 1n+p:
      match xs:
        case Nil{}:
          ys
        case +x <> +xt:
          match ys:
            case Nil{}:
              x <> xt
            case +y <> +yt:
              +xf = U32.is_le(am_end(x), am_end(y))
              Bool.pick(Am, xf, x, y) <> am_merge(p,
                Bool.pick(List<&2, Am>, xf, xt, x <> xt),
                Bool.pick(List<&2, Am>, xf, y <> yt, yt))

# Every other element, starting with the first / second.
def am_keep(first: Bool, x: Am, rest: List<&2, Am>) -> List<&2, Am>:
  match first:
    case True{}:
      x <> rest
    case False{}:
      rest

def am_alt(xs: List<&2, Am>, +first: Bool) -> List<&2, Am>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      am_keep(first, x, am_alt(t, Bool.not(first)))

def am_sort(+fuel: Nat, +xs: List<&2, Am>) -> List<&2, Am>:
  match fuel:
    case 0n:
      xs
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case x <> rest:
          match rest:
            case Nil{}:
              x <> Nil{}
            case _ <> _:
              am_merge(Nat.add(am_len(xs), 1n),
                am_sort(p, am_alt(xs, True{})), am_sort(p, am_alt(xs, False{})))

# Archive members in order of position.
def tab_spans(+t: Tab) -> List<&2, Am>:
  +all = tab_flat(1048576n, t, Nil{})
  am_sort(Nat.add(am_len(all), 1n), all)
