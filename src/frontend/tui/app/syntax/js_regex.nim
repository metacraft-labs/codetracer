## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header. This module reaches `std/*` and nothing else.
##
## app/syntax/js_regex.nim — a backtracking matcher for the JavaScript
## regular expressions Monaco's Monarch tokenizers are written in (PLAT-47,
## B4).
##
## ## Why a matcher of our own
##
## The terminal colours source as the desktop's Monaco does by running Monaco's
## own Monarch definitions (`monarch.nim`), and those are JavaScript regexes.
## `std/re` binds PCRE at run time — a shared library the shipped terminal does
## not otherwise need — and PCRE's semantics are not JavaScript's in the places
## Monarch leans on (an empty-matching iteration of a quantifier, `\s`, `.`).
## What the definitions use is a small subset, measured over every exported
## rule (`scripts/monarch-languages.mjs`): literals and escapes, classes,
## `.`, `^` / `$` (never multiline), `\b` / `\B`, capturing and non-capturing
## groups, alternation, greedy and lazy quantifiers (`*`, `+`, `?`, `{n,m}`),
## positive and negative lookahead, and the `i` flag (the shell definition).
## No lookbehind, no named group, no backreference, no `\p{..}` — the parser
## REFUSES those by name rather than approximating them, so a Monaco upgrade
## that starts using one fails loudly.
##
## ## Semantics kept from ECMAScript (ECMA-262 §22.2)
##
##   * Alternatives are tried left to right, quantifiers greedy unless `?`
##     follows; the first overall match wins (backtracking, not longest).
##   * A quantifier iteration that matched the EMPTY string ends the loop
##     (RepeatMatcher's "min is zero and y's endIndex = x's endIndex").
##   * Captures inside a quantified group are reset at each iteration.
##   * `.` matches anything but a line terminator; `\s` is JavaScript's white
##     space set; `\w`, `\d`, `\b` are ASCII (no `u` flag is used).
##   * Matching works on code points of the UTF-8 line (one JavaScript
##     "character" is one BMP code point), so a class or `.` consumes a whole
##     multi-byte character, as it does in the browser.
##
## A match is always attempted at ONE position (`matchAt`), with that position
## treated as the start of the input: Monarch matches `^(?:rule)` against
## `line.substr(pos)`, so `^` and a `\b` at the position see "start of input".

import std/[strutils, unicode]

type
  RxKind = enum
    rkChar        ## one code point (case-folded under `i` at match time)
    rkAny         ## `.`
    rkClass       ## `[...]`, `\d`, `\w`, `\s` and their negations
    rkStart       ## `^`
    rkEnd         ## `$`
    rkWordB       ## `\b`
    rkNotWordB    ## `\B`
    rkGroup       ## `( )` / `(?: )`
    rkAlt         ## `a|b`
    rkConcat
    rkRepeat
    rkLook        ## `(?= )` / `(?! )`
    rkEmpty

  RxNode = ref object
    case kind: RxKind
    of rkChar:
      ch: int32
    of rkClass:
      ranges: seq[(int32, int32)]
      negated: bool
    of rkGroup:
      capture: int          ## capture index, or -1 for `(?: )`
      body: RxNode
    of rkAlt:
      alts: seq[RxNode]
    of rkConcat:
      items: seq[RxNode]
    of rkRepeat:
      inner: RxNode
      minCount, maxCount: int  ## maxCount -1: unbounded
      lazy: bool
      firstCapture, lastCapture: int  ## captures reset per iteration
    of rkLook:
      look: RxNode
      negative: bool
    else:
      discard

  JsRegex* = object
    ## A compiled expression. `source` is kept for messages.
    source*: string
    root: RxNode
    groups*: int             ## number of capturing groups
    ignoreCase*: bool
    firstBytes: set[char]    ## every byte a non-empty match can start with
    canBeEmpty: bool         ## whether the expression can match ""

  JsRegexError* = object of ValueError
    ## A source using a construct this matcher does not implement.

  Captures* = seq[(int, int)]
    ## Index 0 is the whole match; `(-1, -1)` is an unset group.

# ---------------------------------------------------------------------------
# Character sets
# ---------------------------------------------------------------------------

const
  DigitRanges = @[(int32('0'), int32('9'))]
  WordRanges = @[(int32('0'), int32('9')), (int32('A'), int32('Z')),
                 (int32('_'), int32('_')), (int32('a'), int32('z'))]
  SpaceRanges = @[(9'i32, 13'i32), (32'i32, 32'i32), (0xA0'i32, 0xA0'i32),
                  (0x1680'i32, 0x1680'i32), (0x2000'i32, 0x200A'i32),
                  (0x2028'i32, 0x2029'i32), (0x202F'i32, 0x202F'i32),
                  (0x205F'i32, 0x205F'i32), (0x3000'i32, 0x3000'i32),
                  (0xFEFF'i32, 0xFEFF'i32)]
    ## ECMAScript's WhiteSpace and LineTerminator code points (`\s`).

func negate(ranges: seq[(int32, int32)]): seq[(int32, int32)] =
  ## The complement of sorted, possibly overlapping ranges over 0..0x10FFFF.
  var sorted = ranges
  for i in 1 ..< sorted.len:
    var j = i
    while j > 0 and sorted[j - 1][0] > sorted[j][0]:
      swap(sorted[j - 1], sorted[j])
      dec j
  var next = 0'i32
  for (lo, hi) in sorted:
    if lo > next:
      result.add (next, lo - 1)
    if hi + 1 > next:
      next = hi + 1
  if next <= 0x10FFFF'i32:
    result.add (next, 0x10FFFF'i32)

func inRanges(ranges: seq[(int32, int32)]; c: int32): bool =
  for (lo, hi) in ranges:
    if c >= lo and c <= hi:
      return true
  false

func isWordChar(c: int32): bool =
  (c >= int32('a') and c <= int32('z')) or (c >= int32('A') and c <= int32('Z')) or
    (c >= int32('0') and c <= int32('9')) or c == int32('_')

func isLineTerminator(c: int32): bool =
  c == 10 or c == 13 or c == 0x2028 or c == 0x2029

func foldCase(c: int32): int32 =
  ## ECMAScript Canonicalize for a non-unicode `i` regex, over the cases the
  ## definitions meet: ASCII and the simple one-to-one Unicode case pairs.
  if c >= int32('a') and c <= int32('z'):
    return c - 32
  if c < 128:
    return c
  int32(toUpper(Rune(c)))

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

type
  Parser = object
    src: string
    pos: int
    groups: int

proc fail(p: Parser; msg: string) {.noreturn.} =
  raise newException(JsRegexError,
    "JavaScript regex `" & p.src & "` at " & $p.pos & ": " & msg)

proc atEnd(p: Parser): bool = p.pos >= p.src.len
proc peek(p: Parser): char = (if p.pos < p.src.len: p.src[p.pos] else: '\0')

proc readRune(p: var Parser): int32 =
  var r: Rune
  fastRuneAt(p.src, p.pos, r, true)
  int32(r)

proc hexValue(p: var Parser; digits: int): int32 =
  if p.pos + digits > p.src.len:
    p.fail("truncated hex escape")
  var v = 0
  for i in 0 ..< digits:
    let c = p.src[p.pos + i]
    let d =
      if c in {'0'..'9'}: ord(c) - ord('0')
      elif c in {'a'..'f'}: ord(c) - ord('a') + 10
      elif c in {'A'..'F'}: ord(c) - ord('A') + 10
      else: -1
    if d < 0:
      p.fail("bad hex digit")
    v = v * 16 + d
  p.pos += digits
  int32(v)

proc parseEscape(p: var Parser; inClass: bool):
    tuple[single: int32; ranges: seq[(int32, int32)]; isSet: bool;
          node: RxNode] =
  ## After a `\`. A class escape answers a range set; a character escape one
  ## code point; `\b` / `\B` outside a class answer an assertion node.
  if p.atEnd:
    p.fail("trailing backslash")
  let c = p.src[p.pos]
  inc p.pos
  case c
  of 'd': result = (0'i32, DigitRanges, true, nil)
  of 'D': result = (0'i32, negate(DigitRanges), true, nil)
  of 'w': result = (0'i32, WordRanges, true, nil)
  of 'W': result = (0'i32, negate(WordRanges), true, nil)
  of 's': result = (0'i32, SpaceRanges, true, nil)
  of 'S': result = (0'i32, negate(SpaceRanges), true, nil)
  of 'b':
    if inClass: result = (8'i32, @[], false, nil)
    else: result = (0'i32, @[], false, RxNode(kind: rkWordB))
  of 'B':
    if inClass: p.fail("\\B inside a class")
    result = (0'i32, @[], false, RxNode(kind: rkNotWordB))
  of 'n': result = (10'i32, @[], false, nil)
  of 'r': result = (13'i32, @[], false, nil)
  of 't': result = (9'i32, @[], false, nil)
  of 'v': result = (11'i32, @[], false, nil)
  of 'f': result = (12'i32, @[], false, nil)
  of '0':
    if p.peek in {'0'..'9'}: p.fail("octal escape")
    result = (0'i32, @[], false, nil)
  of 'x': result = (p.hexValue(2), @[], false, nil)
  of 'u':
    if p.peek == '{': p.fail("\\u{...} needs the u flag")
    result = (p.hexValue(4), @[], false, nil)
  of 'c':
    let l = p.peek
    if l in {'a'..'z', 'A'..'Z'}:
      inc p.pos
      result = (int32(ord(l) mod 32), @[], false, nil)
    else:
      result = (int32('\\'), @[], false, nil)
      dec p.pos
  of '1'..'9':
    if inClass: p.fail("octal escape in a class")
    p.fail("backreference")
  of 'p', 'P', 'k':
    p.fail("\\" & $c & " is not supported")
  else:
    # An identity escape: the character itself (`\.`, `\/`, `\-`, `\$`, ...).
    dec p.pos
    result = (p.readRune(), @[], false, nil)

proc parseClass(p: var Parser): RxNode =
  ## After `[`.
  result = RxNode(kind: rkClass)
  if p.peek == '^':
    result.negated = true
    inc p.pos
  var first = true
  while true:
    if p.atEnd:
      p.fail("unterminated class")
    if p.peek == ']' and not first:
      inc p.pos
      break
    if p.peek == ']' and first:
      # `[]` matches nothing, `[^]` anything.
      inc p.pos
      break
    first = false
    var lo: int32
    var isSet = false
    if p.peek == '\\':
      inc p.pos
      let e = p.parseEscape(inClass = true)
      if e.isSet:
        result.ranges.add e.ranges
        isSet = true
      else:
        lo = e.single
    else:
      lo = p.readRune()
    if isSet:
      continue
    if p.peek == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']':
      inc p.pos
      var hi: int32
      if p.peek == '\\':
        inc p.pos
        let e = p.parseEscape(inClass = true)
        if e.isSet:
          # `[a-\d]` is Annex B's "-" as a literal between two atoms.
          result.ranges.add (lo, lo)
          result.ranges.add (int32('-'), int32('-'))
          result.ranges.add e.ranges
          continue
        hi = e.single
      else:
        hi = p.readRune()
      if hi < lo:
        p.fail("class range out of order")
      result.ranges.add (lo, hi)
    else:
      result.ranges.add (lo, lo)

proc parseAlternation(p: var Parser): RxNode

proc tryQuantifierBraces(p: var Parser): tuple[ok: bool; lo, hi: int] =
  ## `{n}`, `{n,}`, `{n,m}` at `p.pos` (on the `{`); otherwise not a
  ## quantifier and the `{` is a literal (Annex B).
  var i = p.pos + 1
  var lo = 0
  var digits = 0
  while i < p.src.len and p.src[i] in {'0'..'9'}:
    lo = lo * 10 + (ord(p.src[i]) - ord('0'))
    inc i
    inc digits
  if digits == 0:
    return (false, 0, 0)
  var hi = lo
  if i < p.src.len and p.src[i] == ',':
    inc i
    if i < p.src.len and p.src[i] in {'0'..'9'}:
      hi = 0
      while i < p.src.len and p.src[i] in {'0'..'9'}:
        hi = hi * 10 + (ord(p.src[i]) - ord('0'))
        inc i
    else:
      hi = -1
  if i >= p.src.len or p.src[i] != '}':
    return (false, 0, 0)
  p.pos = i + 1
  (true, lo, hi)

proc parseTerm(p: var Parser): RxNode =
  ## One atom and its quantifier, or nil at `|` / `)` / end.
  if p.atEnd or p.peek in {'|', ')'}:
    return nil
  let capturesBefore = p.groups
  var atom: RxNode
  let c = p.peek
  case c
  of '^':
    inc p.pos
    return RxNode(kind: rkStart)
  of '$':
    inc p.pos
    return RxNode(kind: rkEnd)
  of '.':
    inc p.pos
    atom = RxNode(kind: rkAny)
  of '[':
    inc p.pos
    atom = p.parseClass()
  of '(':
    inc p.pos
    if p.peek == '?':
      inc p.pos
      let k = p.peek
      inc p.pos
      case k
      of ':':
        atom = RxNode(kind: rkGroup, capture: -1, body: p.parseAlternation())
      of '=', '!':
        atom = RxNode(kind: rkLook, look: p.parseAlternation(),
                      negative: k == '!')
      of '<':
        p.fail("lookbehind or a named group is not supported")
      else:
        p.fail("unknown group kind (?" & $k)
    else:
      inc p.groups
      let idx = p.groups
      atom = RxNode(kind: rkGroup, capture: idx, body: p.parseAlternation())
    if p.peek != ')':
      p.fail("unterminated group")
    inc p.pos
    if atom.kind == rkLook:
      # A lookahead is an assertion; Annex B allows a quantifier after it
      # but none of the definitions writes one.
      return atom
  of '\\':
    inc p.pos
    let e = p.parseEscape(inClass = false)
    if not e.node.isNil:
      return e.node
    if e.isSet:
      atom = RxNode(kind: rkClass, ranges: e.ranges)
    else:
      atom = RxNode(kind: rkChar, ch: e.single)
  of '*', '+', '?':
    p.fail("nothing to repeat")
  of '{':
    let save = p.pos
    let q = p.tryQuantifierBraces()
    if q.ok:
      p.fail("nothing to repeat")
    p.pos = save + 1
    atom = RxNode(kind: rkChar, ch: int32('{'))
  else:
    atom = RxNode(kind: rkChar, ch: p.readRune())
  # The quantifier.
  var lo, hi: int
  var quantified = true
  case p.peek
  of '*': (lo, hi) = (0, -1); inc p.pos
  of '+': (lo, hi) = (1, -1); inc p.pos
  of '?': (lo, hi) = (0, 1); inc p.pos
  of '{':
    let q = p.tryQuantifierBraces()
    if q.ok: (lo, hi) = (q.lo, q.hi)
    else: quantified = false
  else: quantified = false
  if not quantified:
    return atom
  var lazy = false
  if p.peek == '?':
    lazy = true
    inc p.pos
  RxNode(kind: rkRepeat, inner: atom, minCount: lo, maxCount: hi, lazy: lazy,
         firstCapture: capturesBefore + 1, lastCapture: p.groups)

proc parseConcat(p: var Parser): RxNode =
  var items: seq[RxNode] = @[]
  while true:
    let t = p.parseTerm()
    if t.isNil:
      break
    items.add t
  if items.len == 0: RxNode(kind: rkEmpty)
  elif items.len == 1: items[0]
  else: RxNode(kind: rkConcat, items: items)

proc parseAlternation(p: var Parser): RxNode =
  var alts = @[p.parseConcat()]
  while p.peek == '|':
    inc p.pos
    alts.add p.parseConcat()
  if alts.len == 1: alts[0] else: RxNode(kind: rkAlt, alts: alts)

# ---------------------------------------------------------------------------
# A pre-filter: which bytes can a match start with
# ---------------------------------------------------------------------------
#
# Monarch tries every rule of a state at every position, and almost every
# attempt fails on its first character. Knowing, per expression, the set of
# bytes a non-empty match can start with (and whether it can match empty)
# turns those attempts into one set lookup — measured: the tokenizer's cost per
# line fell several-fold. The set is CONSERVATIVE: a lookahead, `\b` or `^`
# contributes nothing and lets the next item decide, and a code point above
# 127 admits every non-ASCII lead byte.

const NonAsciiLeads = {'\x80'..'\xFF'}

proc addCodePoint(s: var set[char]; c: int32; icase: bool) =
  if c < 128:
    s.incl char(c)
    if icase and char(c) in {'a'..'z', 'A'..'Z'}:
      s.incl char(ord(char(c)) xor 0x20)
  else:
    s = s + NonAsciiLeads
    if icase:
      # A non-ASCII letter can fold onto an ASCII one (the Kelvin sign onto
      # `k`): admit the ASCII letters too rather than reason about it.
      s = s + {'a'..'z', 'A'..'Z'}

proc firstInfo(n: RxNode; icase: bool): tuple[bytes: set[char]; empty: bool] =
  case n.kind
  of rkEmpty, rkStart, rkEnd, rkWordB, rkNotWordB, rkLook:
    (bytes: {}, empty: true)
  of rkChar:
    var s: set[char] = {}
    s.addCodePoint(n.ch, icase)
    (bytes: s, empty: false)
  of rkAny:
    (bytes: {'\x00'..'\xFF'} - {'\n', '\r'}, empty: false)
  of rkClass:
    var s: set[char] = {}
    if n.negated:
      # Everything except what the class lists; conservatively all bytes.
      s = {'\x00'..'\xFF'}
    else:
      for (lo, hi) in n.ranges:
        if lo < 128:
          for c in lo .. min(hi, 127'i32):
            s.addCodePoint(c, icase)
        if hi >= 128:
          s = s + NonAsciiLeads
          if icase: s = s + {'a'..'z', 'A'..'Z'}
    (bytes: s, empty: false)
  of rkGroup:
    firstInfo(n.body, icase)
  of rkAlt:
    var s: set[char] = {}
    var e = false
    for a in n.alts:
      let (b, ae) = firstInfo(a, icase)
      s = s + b
      e = e or ae
    (bytes: s, empty: e)
  of rkConcat:
    var s: set[char] = {}
    for it in n.items:
      let (b, e) = firstInfo(it, icase)
      s = s + b
      if not e:
        return (bytes: s, empty: false)
    (bytes: s, empty: true)
  of rkRepeat:
    let (b, e) = firstInfo(n.inner, icase)
    (bytes: b, empty: e or n.minCount == 0)

proc compileJsRegex*(source: string; ignoreCase = false): JsRegex =
  ## Parse `source` (a JavaScript regex body, no slashes). Raises
  ## `JsRegexError` naming a construct this matcher does not implement.
  var p = Parser(src: source, pos: 0, groups: 0)
  let root = p.parseAlternation()
  if not p.atEnd:
    p.fail("unbalanced `)`")
  let (bytes, empty) = firstInfo(root, ignoreCase)
  JsRegex(source: source, root: root, groups: p.groups, ignoreCase: ignoreCase,
          firstBytes: bytes, canBeEmpty: empty)

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

type
  Matcher = object
    s: string
    base: int              ## where the input "starts" (Monarch's `pos`)
    icase: bool
    caps: Captures
    steps: int             ## a budget, so a pathological rule cannot hang

  ContClosure = proc(m: var Matcher; i: int): bool {.closure.}

const StepBudget = 200_000
  ## Backtracking steps one `matchAt` may take. The definitions' rules are
  ## linear in practice (measured: the whole `calc` file takes a few thousand
  ## steps per line); the budget turns a catastrophic case into "no match"
  ## rather than a frozen terminal.

proc runeAt(m: Matcher; i: int): tuple[c: int32; len: int] {.inline.} =
  let b = m.s[i]
  if ord(b) < 0x80:
    return (int32(ord(b)), 1)
  var r: Rune
  var j = i
  fastRuneAt(m.s, j, r, true)
  (int32(r), j - i)

proc prevIsWord(m: Matcher; i: int): bool =
  if i <= m.base:
    return false
  isWordChar(int32(ord(m.s[i - 1])))

proc nextIsWord(m: Matcher; i: int): bool =
  if i >= m.s.len:
    return false
  isWordChar(int32(ord(m.s[i])))

proc charMatches(m: Matcher; n: RxNode; c: int32): bool =
  case n.kind
  of rkChar:
    if m.icase: foldCase(c) == foldCase(n.ch) else: c == n.ch
  of rkAny:
    not isLineTerminator(c)
  of rkClass:
    var hit = inRanges(n.ranges, c)
    if not hit and m.icase:
      let f = foldCase(c)
      hit = inRanges(n.ranges, f) or inRanges(n.ranges, int32(toLower(Rune(c))))
    hit xor n.negated
  else:
    false

proc matchNode(m: var Matcher; n: RxNode; i: int; k: ContClosure): bool

proc matchSeq(m: var Matcher; items: seq[RxNode]; idx, i: int;
              k: ContClosure): bool =
  if idx >= items.len:
    return k(m, i)
  let rest = proc(mm: var Matcher; j: int): bool =
    matchSeq(mm, items, idx + 1, j, k)
  matchNode(m, items[idx], i, rest)

proc matchRepeat(m: var Matcher; n: RxNode; count, i: int;
                 k: ContClosure): bool =
  inc m.steps
  if m.steps > StepBudget:
    return false
  let canStop = count >= n.minCount
  let canGo = n.maxCount < 0 or count < n.maxCount
  proc iterate(mm: var Matcher): bool =
    # Reset the captures inside the group for this iteration (§22.2.2.3.1).
    var saved: seq[(int, int)] = @[]
    for g in n.firstCapture .. n.lastCapture:
      saved.add mm.caps[g]
      mm.caps[g] = (-1, -1)
    let after = proc(m2: var Matcher; j: int): bool =
      # An iteration that consumed nothing ends the loop once min is met.
      if j == i and count + 1 > n.minCount:
        return false
      matchRepeat(m2, n, count + 1, j, k)
    result = matchNode(mm, n.inner, i, after)
    if not result:
      var idx = 0
      for g in n.firstCapture .. n.lastCapture:
        mm.caps[g] = saved[idx]
        inc idx
  if n.lazy:
    if canStop and k(m, i):
      return true
    if canGo:
      return iterate(m)
    return false
  if canGo and iterate(m):
    return true
  canStop and k(m, i)

proc matchNode(m: var Matcher; n: RxNode; i: int; k: ContClosure): bool =
  inc m.steps
  if m.steps > StepBudget:
    return false
  case n.kind
  of rkEmpty:
    k(m, i)
  of rkChar, rkAny, rkClass:
    if i >= m.s.len:
      return false
    let (c, len) = m.runeAt(i)
    if not m.charMatches(n, c):
      return false
    k(m, i + len)
  of rkStart:
    i == m.base and k(m, i)
  of rkEnd:
    i == m.s.len and k(m, i)
  of rkWordB:
    (m.prevIsWord(i) != m.nextIsWord(i)) and k(m, i)
  of rkNotWordB:
    (m.prevIsWord(i) == m.nextIsWord(i)) and k(m, i)
  of rkConcat:
    matchSeq(m, n.items, 0, i, k)
  of rkAlt:
    for a in n.alts:
      if matchNode(m, a, i, k):
        return true
    false
  of rkGroup:
    if n.capture < 0:
      return matchNode(m, n.body, i, k)
    let saved = m.caps[n.capture]
    let close = proc(mm: var Matcher; j: int): bool =
      let before = mm.caps[n.capture]
      mm.caps[n.capture] = (i, j)
      if k(mm, j):
        return true
      mm.caps[n.capture] = before
      false
    if matchNode(m, n.body, i, close):
      return true
    m.caps[n.capture] = saved
    false
  of rkRepeat:
    matchRepeat(m, n, 0, i, k)
  of rkLook:
    # A lookahead's own captures survive a positive assertion (§22.2.2.4);
    # it is matched to completion on its own and never backtracked into.
    let savedCaps = m.caps
    let found = matchNode(m, n.look, i,
                          proc(mm: var Matcher; j: int): bool = true)
    if n.negative:
      m.caps = savedCaps
      if found: false else: k(m, i)
    else:
      if not found:
        m.caps = savedCaps
        return false
      if k(m, i):
        return true
      m.caps = savedCaps
      false

proc matchAt*(re: JsRegex; s: string; pos: int; caps: var Captures): bool =
  ## Whether `re` matches `s` starting at `pos`, with `pos` treated as the
  ## start of the input (`^` matches there, `\b` sees nothing before it).
  ## On success `caps[0]` is the whole match and `caps[g]` each group, as byte
  ## offsets into `s`; an unset group is `(-1, -1)`.
  if not re.canBeEmpty and (pos >= s.len or s[pos] notin re.firstBytes):
    return false
  var m = Matcher(s: s, base: pos, icase: re.ignoreCase,
                  caps: newSeq[(int, int)](re.groups + 1))
  for g in 0 .. re.groups:
    m.caps[g] = (-1, -1)
  var endAt = -1
  let done = proc(mm: var Matcher; j: int): bool =
    endAt = j
    true
  if matchNode(m, re.root, pos, done):
    m.caps[0] = (pos, endAt)
    caps = m.caps
    return true
  false

proc escapeRegExpCharacters*(s: string): string =
  ## Monaco's `strings.escapeRegExpCharacters`: every character of
  ## `\{}*+?|^$.[]()` escaped (a `$Sn` substitution goes through it).
  for c in s:
    if c in {'\\', '{', '}', '*', '+', '?', '|', '^', '$', '.', '[', ']',
             '(', ')'}:
      result.add '\\'
    result.add c
