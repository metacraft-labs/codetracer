## rope.nim — the balanced text tree the PLAT-24 measurement selected.
##
## Editor-ViewModel.md §4 gates every layer above it on one question: what is
## an editable source document stored in? PLAT-24 answers it by measurement,
## and this module is the structure that measurement chose. It is deliberately
## NOT the public storage interface — that is `editor/text_store.nim`, which is
## seven operations wide so the choice stays reversible. This file knows only
## about bytes.
##
## THE SHAPE, and why this one
## ---------------------------
## A **uniform-depth tree over UTF-8 chunks**, in the family CodeMirror 6,
## Zed's `SumTree` and xi-editor's rope all belong to:
##
##   * every leaf holds at most `MaxLeafBytes` bytes of text;
##   * every internal node holds between 2 and `MaxChildren` children;
##   * **all leaves sit at the same depth**, which is the invariant that makes
##     the depth bound structural rather than statistical: with at least two
##     children per internal node, `height <= log2(leafCount) + 1`, always.
##
## Each node caches the two summaries the editor asks for — total `bytes` and
## total `newlines` — so a line index is a descent rather than a scan. Index,
## slice, insert and delete are therefore O(log n) in the document, plus O(1)
## in `MaxLeafBytes`.
##
## Two properties are worth naming because they are what distinguishes a real
## rope from a wrapper that still shifts:
##
##   * `replaceBytes` takes a **leaf-local fast path** when the edit fits
##     inside one chunk (which is every ordinary keystroke, `Enter` included):
##     it rewrites the O(log n) nodes on the path to that leaf and touches
##     nothing else. There is no per-line array to shift, so the cost does not
##     depend on WHERE in the document the edit lands.
##   * the general path is `split` + `concat`, both height-aware, and `concat`
##     merges the two chunks at the seam when they are small enough. Without
##     that merge a long editing session fragments the leaves into one-byte
##     chunks and the "balanced" tree grows a depth proportional to the number
##     of edits.
##
## `checkInvariants` asserts all of the above and is what the suite uses to
## refuse a structure that merely behaves correctly. A rope that passes the
## behavioural cases and fails `checkInvariants` is the wrapper PLAT-24's risk
## section names.
##
## Offsets are **byte** offsets into the document's UTF-8 bytes. Splitting a
## multi-byte code point is a caller error; `text_store.nim` is where that is
## checked, because that is where the coordinates come from.

const
  MaxLeafBytes* = 256
    ## Bytes per chunk. Small enough that an in-leaf rewrite is cheap, large
    ## enough that a 6 MB document is ~24,000 leaves rather than millions.
  MaxChildren* = 8
    ## Fan-out. A node is split when it would exceed this.

type
  RopeNode = ref object
    ## `height == 0` means a leaf and `text` is its content; otherwise `kids`
    ## holds between 2 and `MaxChildren` children, all of height `height - 1`.
    bytes: int
    newlines: int
    height: int
    text: string
    kids: seq[RopeNode]

  Rope* = object
    ## A whole document. `root` is never nil: an empty document is one empty
    ## leaf, so every traversal below can read `root.bytes` unguarded.
    root: RopeNode

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newLeaf(text: string): RopeNode =
  var nl = 0
  for ch in text:
    if ch == '\n': inc nl
  RopeNode(bytes: text.len, newlines: nl, height: 0, text: text)

proc newBranch(kids: seq[RopeNode]): RopeNode =
  var b = 0
  var nl = 0
  for k in kids:
    b += k.bytes
    nl += k.newlines
  RopeNode(bytes: b, newlines: nl, height: kids[0].height + 1, kids: kids)

proc fromKids(kids: seq[RopeNode]): RopeNode =
  ## A node over `kids`, collapsing the two degenerate arities. One child
  ## collapses to the child itself — which LOWERS the height, and is exactly
  ## why every join below is height-aware rather than assuming a level.
  if kids.len == 0: nil
  elif kids.len == 1: kids[0]
  else: newBranch(kids)

func utf8Start(s: string; i: int): int =
  ## The largest `j <= i` that is not a UTF-8 continuation byte.
  var j = i
  while j > 0 and j < s.len and (uint8(s[j]) and 0xC0'u8) == 0x80'u8:
    dec j
  j

proc buildLeaves(s: string): seq[RopeNode] =
  ## Chunk `s` into leaves. A chunk prefers to end just after a newline so a
  ## line rarely straddles two chunks, and never ends inside a code point.
  result = @[]
  var i = 0
  while i < s.len:
    var stop = min(i + MaxLeafBytes, s.len)
    if stop < s.len:
      var nlAt = -1
      var k = stop - 1
      let floorK = i + (MaxLeafBytes div 2)
      while k >= floorK:
        if s[k] == '\n':
          nlAt = k
          break
        dec k
      if nlAt >= 0:
        stop = nlAt + 1
      else:
        let b = utf8Start(s, stop)
        stop = if b > i: b else: min(i + MaxLeafBytes, s.len)
    result.add newLeaf(s[i ..< stop])
    i = stop

proc treeFromLeaves(leaves: seq[RopeNode]): RopeNode =
  ## Bottom-up build. Each pass groups the level into nodes of at most
  ## `MaxChildren`, never leaving a remainder of exactly one — a one-child
  ## group would collapse to a node one level shallower than its siblings and
  ## break the uniform-depth invariant this whole structure rests on.
  if leaves.len == 0: return newLeaf("")
  var level = leaves
  while level.len > 1:
    var next: seq[RopeNode] = @[]
    var i = 0
    while i < level.len:
      var take = min(MaxChildren, level.len - i)
      if level.len - i - take == 1: dec take
      next.add newBranch(level[i ..< i + take])
      i += take
    level = next
  level[0]

proc initRope*(text: string): Rope =
  Rope(root: treeFromLeaves(buildLeaves(text)))

# ---------------------------------------------------------------------------
# Join and split
# ---------------------------------------------------------------------------

proc concatNodes(a, b: RopeNode): RopeNode

proc splitOversized(kids: seq[RopeNode]): RopeNode =
  if kids.len <= MaxChildren: return newBranch(kids)
  let mid = kids.len div 2
  newBranch(@[newBranch(kids[0 ..< mid]), newBranch(kids[mid ..< kids.len])])

proc appendRight(a, b: RopeNode): RopeNode =
  ## `a` then `b`, with `a.height > b.height`. Descends `a`'s right spine to
  ## the level `b` belongs at, splices it in, and splits upward on overflow.
  var kids = a.kids
  if a.height == b.height + 1:
    if b.height == 0 and kids[^1].height == 0 and
       kids[^1].bytes + b.bytes <= MaxLeafBytes:
      # The seam merge. Without it, every split/concat pair leaves two short
      # chunks behind and a long session fragments the tree.
      kids[^1] = newLeaf(kids[^1].text & b.text)
      return newBranch(kids)
    kids.add b
  else:
    let merged = appendRight(kids[^1], b)
    if merged.height == kids[^1].height:
      kids[^1] = merged
      return newBranch(kids)
    kids.setLen(kids.len - 1)
    for k in merged.kids: kids.add k
  splitOversized(kids)

proc prependLeft(a, b: RopeNode): RopeNode =
  ## `b` then `a`, with `a.height > b.height`. The mirror of `appendRight`.
  var kids = a.kids
  if a.height == b.height + 1:
    if b.height == 0 and kids[0].height == 0 and
       kids[0].bytes + b.bytes <= MaxLeafBytes:
      kids[0] = newLeaf(b.text & kids[0].text)
      return newBranch(kids)
    kids.insert(b, 0)
  else:
    let merged = prependLeft(kids[0], b)
    if merged.height == kids[0].height:
      kids[0] = merged
      return newBranch(kids)
    let rest = kids[1 ..< kids.len]
    kids = merged.kids
    for k in rest: kids.add k
  splitOversized(kids)

proc concatNodes(a, b: RopeNode): RopeNode =
  if a.isNil: return b
  if b.isNil: return a
  if a.height == 0 and a.bytes == 0: return b
  if b.height == 0 and b.bytes == 0: return a
  if a.height == b.height:
    if a.height == 0 and a.bytes + b.bytes <= MaxLeafBytes:
      return newLeaf(a.text & b.text)
    return newBranch(@[a, b])
  if a.height > b.height: appendRight(a, b)
  else: prependLeft(b, a)

proc splitNode(n: RopeNode; at: int): (RopeNode, RopeNode) =
  if n.isNil: return (nil, nil)
  if at <= 0: return (nil, n)
  if at >= n.bytes: return (n, nil)
  if n.height == 0:
    return (newLeaf(n.text[0 ..< at]), newLeaf(n.text[at ..< n.text.len]))
  var acc = 0
  var i = 0
  while i < n.kids.len and acc + n.kids[i].bytes <= at:
    acc += n.kids[i].bytes
    inc i
  if acc == at:
    return (fromKids(n.kids[0 ..< i]), fromKids(n.kids[i ..< n.kids.len]))
  let (a, b) = splitNode(n.kids[i], at - acc)
  (concatNodes(fromKids(n.kids[0 ..< i]), a),
   concatNodes(b, fromKids(n.kids[i + 1 ..< n.kids.len])))

# ---------------------------------------------------------------------------
# Lengths
# ---------------------------------------------------------------------------

func len*(r: Rope): int =
  ## Total byte length of the document.
  r.root.bytes

func newlineCount*(r: Rope): int =
  ## Number of `'\n'` bytes in the document. `lineCount` is one more.
  r.root.newlines

# ---------------------------------------------------------------------------
# The line index
# ---------------------------------------------------------------------------

proc offsetOfNewline(n: RopeNode; k: int): int =
  ## Byte offset of the `k`-th (0-based) newline inside `n`. -1 if there are
  ## fewer than `k + 1` of them, which callers treat as "past the last line".
  if n.height == 0:
    var seen = 0
    for i in 0 ..< n.text.len:
      if n.text[i] == '\n':
        if seen == k: return i
        inc seen
    return -1
  var acc = 0
  var rem = k
  for kid in n.kids:
    if rem < kid.newlines:
      let inner = offsetOfNewline(kid, rem)
      return if inner < 0: -1 else: acc + inner
    rem -= kid.newlines
    acc += kid.bytes
  -1

proc newlinesBefore(n: RopeNode; offset: int): int =
  ## How many newlines lie strictly before `offset` inside `n`.
  if offset <= 0: return 0
  if offset >= n.bytes: return n.newlines
  if n.height == 0:
    var c = 0
    for i in 0 ..< min(offset, n.text.len):
      if n.text[i] == '\n': inc c
    return c
  var acc = 0
  var c = 0
  for kid in n.kids:
    if offset <= acc: break
    if offset >= acc + kid.bytes:
      c += kid.newlines
    else:
      c += newlinesBefore(kid, offset - acc)
      break
    acc += kid.bytes
  c

proc lineStartOffset*(r: Rope; line: int): int =
  ## Byte offset where `line` (0-based) begins. Clamped at both ends.
  if line <= 0: return 0
  if line > r.root.newlines: return r.root.bytes
  let at = offsetOfNewline(r.root, line - 1)
  if at < 0: r.root.bytes else: at + 1

proc lineOfOffset*(r: Rope; offset: int): int =
  ## The 0-based line `offset` falls on.
  newlinesBefore(r.root, offset)

# ---------------------------------------------------------------------------
# Slice
# ---------------------------------------------------------------------------

proc appendSlice(n: RopeNode; a, b: int; dest: var string) =
  if n.isNil or b <= 0 or a >= n.bytes or a >= b: return
  if n.height == 0:
    dest.add n.text[max(a, 0) ..< min(b, n.text.len)]
    return
  var acc = 0
  for kid in n.kids:
    if acc >= b: break
    if acc + kid.bytes > a:
      appendSlice(kid, a - acc, b - acc, dest)
    acc += kid.bytes

proc sliceBytes*(r: Rope; a, b: int): string =
  let lo = max(0, min(a, r.root.bytes))
  let hi = max(lo, min(b, r.root.bytes))
  result = newStringOfCap(hi - lo)
  appendSlice(r.root, lo, hi, result)

proc text*(r: Rope): string =
  r.sliceBytes(0, r.root.bytes)

proc byteAt*(r: Rope; offset: int): int =
  ## The byte at `offset` as 0..255, or -1 when out of range. One descent and
  ## no allocation: `text_store.replaceRange` calls this twice per edit to
  ## refuse an offset inside a UTF-8 code point, and that check sits on the
  ## per-keystroke path the PLAT-24 measurement times.
  if offset < 0 or offset >= r.root.bytes: return -1
  var n = r.root
  var off = offset
  while n.height > 0:
    var descended = false
    for kid in n.kids:
      if off < kid.bytes:
        n = kid
        descended = true
        break
      off -= kid.bytes
    if not descended: return -1
  int(uint8(n.text[off]))

# ---------------------------------------------------------------------------
# Replace
# ---------------------------------------------------------------------------

proc tryLeafEdit(n: RopeNode; a, b: int; s: string): RopeNode =
  ## The fast path: if `[a, b)` lies inside a single leaf and the rewritten
  ## leaf still fits, return a copy of the O(log n) nodes on the path to it.
  ## nil when the edit does not fit that shape.
  if n.height == 0:
    if a >= 0 and b <= n.bytes and n.bytes - (b - a) + s.len <= MaxLeafBytes:
      # One allocation, not three: this is the per-keystroke path.
      var rewritten = newStringOfCap(n.bytes - (b - a) + s.len)
      for i in 0 ..< a: rewritten.add n.text[i]
      rewritten.add s
      for i in b ..< n.text.len: rewritten.add n.text[i]
      return newLeaf(rewritten)
    return nil
  var acc = 0
  for i in 0 ..< n.kids.len:
    let kid = n.kids[i]
    if a >= acc and b <= acc + kid.bytes:
      let rewritten = tryLeafEdit(kid, a - acc, b - acc, s)
      if rewritten.isNil: return nil
      var kids = n.kids
      kids[i] = rewritten
      return newBranch(kids)
    acc += kid.bytes
  nil

proc replaceBytes*(r: var Rope; a, b: int; s: string) =
  ## Replace the byte range `[a, b)` with `s`.
  let lo = max(0, min(a, r.root.bytes))
  let hi = max(lo, min(b, r.root.bytes))
  let fast = tryLeafEdit(r.root, lo, hi, s)
  if not fast.isNil:
    r.root = fast
    return
  let (left, rest) = splitNode(r.root, lo)
  let (_, right) = splitNode(rest, hi - lo)
  let middle = if s.len == 0: nil else: treeFromLeaves(buildLeaves(s))
  var joined = concatNodes(concatNodes(left, middle), right)
  if joined.isNil: joined = newLeaf("")
  r.root = joined

# ---------------------------------------------------------------------------
# Invariants — what makes this a rope rather than a wrapper
# ---------------------------------------------------------------------------

type
  RopeStats* = object
    ## What `checkInvariants` measured while walking the tree.
    leaves*: int
    nodes*: int
    height*: int
    maxLeafBytes*: int
    minFanout*: int
    maxFanout*: int

proc walkCheck(n: RopeNode; depth: int; leafDepth: var int;
               st: var RopeStats): string =
  ## Returns "" when the subtree is sound, or the first violation found.
  if n.isNil: return "a nil node"
  inc st.nodes
  if n.height == 0:
    inc st.leaves
    if n.text.len != n.bytes:
      return "leaf byte summary " & $n.bytes & " != " & $n.text.len
    var nl = 0
    for ch in n.text:
      if ch == '\n': inc nl
    if nl != n.newlines:
      return "leaf newline summary " & $n.newlines & " != " & $nl
    if n.bytes > MaxLeafBytes:
      return "leaf of " & $n.bytes & " bytes exceeds MaxLeafBytes"
    st.maxLeafBytes = max(st.maxLeafBytes, n.bytes)
    if leafDepth < 0: leafDepth = depth
    elif leafDepth != depth:
      return "leaves at two depths: " & $leafDepth & " and " & $depth
    return ""
  if n.kids.len < 2:
    return "internal node with " & $n.kids.len & " children"
  if n.kids.len > MaxChildren:
    return "internal node with " & $n.kids.len & " children exceeds MaxChildren"
  st.minFanout = min(st.minFanout, n.kids.len)
  st.maxFanout = max(st.maxFanout, n.kids.len)
  var b = 0
  var nl = 0
  for kid in n.kids:
    if kid.isNil: return "nil child"
    if kid.height != n.height - 1:
      return "child height " & $kid.height & " under node height " & $n.height
    let bad = walkCheck(kid, depth + 1, leafDepth, st)
    if bad.len > 0: return bad
    b += kid.bytes
    nl += kid.newlines
  if b != n.bytes:
    return "branch byte summary " & $n.bytes & " != " & $b
  if nl != n.newlines:
    return "branch newline summary " & $n.newlines & " != " & $nl
  ""

proc checkInvariants*(r: Rope; st: var RopeStats): string =
  ## "" when sound, otherwise the first violation, named. The caller asserts
  ## on the string so a failure says WHICH invariant broke.
  st = RopeStats(minFanout: high(int))
  var leafDepth = -1
  let bad = walkCheck(r.root, 0, leafDepth, st)
  if bad.len > 0: return bad
  st.height = r.root.height
  if st.minFanout == high(int): st.minFanout = 0
  # The depth bound, stated structurally: with at least two children per
  # internal node and every leaf at the same depth, a tree of L leaves cannot
  # be taller than log2(L) + 1. This is the assertion that separates a rope
  # from a list wearing one.
  var bound = 1
  var cap = 1
  while cap < st.leaves:
    cap *= 2
    inc bound
  if st.height > bound:
    return "height " & $st.height & " exceeds log2 bound " & $bound &
           " for " & $st.leaves & " leaves"
  ""
