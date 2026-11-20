## find_match.nim — THE ONE DOCUMENT MATCHER (Find-And-Incremental-Search.md
## §2 principle 3, FS-1).
##
## Owns: `matchesOf(document, pattern, options) → seq[MatchSpan]` and the
## walk beside it (`nextMatchOf`), the word-character rule a whole-word match
## and the editor's word motions share (`isWordRune`), and the cap on a match
## set (`MatchesLimit`, VS Code's `MATCHES_LIMIT`).
##
## Refuses to own: the find session (`viewmodels/find_vm.nim`), the pattern
## (`EditorState.search`, the one pattern store, §2 principle 2), and how a
## match is drawn (each front-end's painter, from the session's marks).
##
## Every caller of a match asks this module: the find session's highlights
## and walk, `search-next` / `search-prev`, the CUA `Ctrl+F3` launcher, the
## Vim `*` / `#` and Kakoune `*` macros (through `search-next`), the
## multi-cursor `add-cursor-at-next-match` family, and the terminal's
## `app/views/search.nim` (a caller, its own matcher deleted). FS-1's source
## gate (`ci/test/plat70c-one-matcher.sh`) refuses a second one.
##
## ## WHAT A MATCH IS
##
## A LITERAL pattern by default, or — with `regex` on (`find.toggle-regex`,
## `Alt+R`) — a regular expression (§3.1, OQ-F5: the user, 2026-11-20,
## admitted nim-regex to the editor core's closure,
## `ci/test/editor-import-closure.sh`; Find in Files' regular expressions are
## `host/text_match.nim`'s, over files, with `rg`'s refusals):
##
## * **case** — `caseSensitive: false` folds each rune with Unicode's simple
##   lower-case mapping (`std/unicode.toLower`), so `Σ` finds `σ`. A pattern
##   that is all ASCII is folded byte by byte, the fast path, and then matches
##   only ASCII text — the Kelvin sign does not fold to `k` there (recorded in
##   the spec's §3.1 notes). A regular expression is compiled caseless
##   (nim-regex's simple case folding);
## * **whole word** — the rune before the match and the rune after it are not
##   word runes (`isWordRune`: a letter, a decimal digit or `_`, the editor's
##   own word class, so "a word" means what the word motions mean by it).
##   Vim's `\<…\>` and VS Code's Match Whole Word, which for a regular
##   expression is the same test applied to each match the expression finds
##   (VS Code's `isValidMatch`);
## * **non-overlapping, in document order** — `aa` in `aaaa` is two matches,
##   at 0 and 2 (Vim's, and CTUI-10's, rule: the count never exceeds the
##   places a reader can see);
## * **at a rune start** — a match never begins inside a UTF-8 sequence.
##
## Offsets are BYTES of the document, `[a, b)`.
##
## ## A REGULAR EXPRESSION, AS VS CODE SEARCHES ONE
##
## * **line by line** unless the pattern can match a line break — a line
##   feed in it, or `\n`, `\r` or `\W` (VS Code's `isMultilineRegexSource`) —
##   in which case it runs over the whole text with `^` / `$` at line ends
##   (`regexMultiline`). `.` never matches a line break, as in JavaScript;
## * **an empty match counts** (`^`, `a*`): VS Code finds and counts it; it
##   is selected as a caret and drawn as nothing;
## * **a pattern that does not compile matches nowhere**, and
##   `patternError` says why (the count reads it, as VS Code reddens its
##   field);
## * **within a scope** (Find in Selection, `find.toggle-in-selection`,
##   `Alt+L`): each range of the scope is searched as if it were the whole
##   text, so `^` and a whole-word edge hold at a range's ends, as VS Code
##   searches its `searchScope`.
##
## ## THE GUARD AGAINST CATASTROPHIC PATTERNS
##
## nim-regex is a Thompson-NFA engine: no backtracking, so `(a+)+b` over a
## long run of `a`s costs time linear in the text (`test_plat70_find_regex`
## runs the classic exponential patterns over 20 000-character lines and
## asserts each finishes with the right answer — a backtracking engine never
## would). Two things it documents as NOT linear are refused before any text
## is searched (`patternError`):
##
## * **a look-around containing an unbounded repetition** (`(?<=a+)`,
##   `(?=.*x)`): *"lookarounds containing repetitions … may run in
##   polynomial time"* (nim-regex's own manual);
## * **a counted repetition that expands past `RegexSizeLimit` states**
##   (`(a{1000}){1000}`): the NFA is built by expansion, so its size, and the
##   compile's time and memory, is the product of the counts.

import std/unicode
from std/strutils import find

import regex

type
  MatchOptions* = object
    ## The toggles a match is computed with. Held with the pattern in
    ## `EditorState.search` (the one store), so `n` / `F3` after a find
    ## closes match exactly what the find highlighted.
    caseSensitive*: bool
    wholeWord*: bool
    regex*: bool
      ## The pattern is a regular expression (`find.toggle-regex`), not a
      ## literal.

  MatchSpan* = object
    ## One match: bytes `[a, b)` of the document.
    a*, b*: int

  MatchWalk* = object
    ## `nextMatchOf`'s answer.
    found*: bool
    span*: MatchSpan
    wrapped*: bool
      ## The walk passed the document's end (forward) or start (backward) to
      ## reach it — Vim's `search hit BOTTOM, continuing at TOP`.

const
  MatchesLimit* = 19_999
    ## VS Code's `MATCHES_LIMIT`: a match set holds at most this many spans.
    ## Past it a count reads `19999+`; a walk is not bounded by it, because it
    ## searches on from where it is (`nextMatchOf`) rather than indexing the
    ## capped list.
  RegexSizeLimit* = 10_000
    ## The most NFA states a regular expression's counted repetitions may
    ## expand to (see the header's guard).

func `==`*(a, b: MatchOptions): bool =
  a.caseSensitive == b.caseSensitive and a.wholeWord == b.wholeWord and
    a.regex == b.regex

func `==`*(a, b: MatchSpan): bool = a.a == b.a and a.b == b.b

func isWordRune*(r: Rune): bool =
  ## The editor's word class (Editing-Operations §2.2 A: *"word / space /
  ## other"*): `_`, a Unicode letter, or an ASCII digit. `operations.catOf`
  ## asks this, so a whole-word match and `w` agree on what a word is.
  r == Rune('_') or r.isAlpha() or
    (int(r) < 128 and char(int(r)) in {'0' .. '9'})

func runeStartBefore(s: string; pos: int): int =
  ## The start of the rune that ends at `pos` (`pos > 0`).
  var i = pos - 1
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec i
  i

func wordBefore(s: string; pos: int): bool =
  if pos <= 0: return false
  s.runeAt(runeStartBefore(s, pos)).isWordRune

func wordAt(s: string; pos: int): bool =
  if pos >= s.len: return false
  s.runeAt(pos).isWordRune

func isAsciiText(s: string): bool =
  for c in s:
    if ord(c) >= 128: return false
  true

func lowerAscii(c: char): char {.inline.} =
  if c in {'A' .. 'Z'}: char(ord(c) + 32) else: c

func literalLengthAt(doc, pattern: string; options: MatchOptions;
                     pos: int): int =
  ## How many bytes of `doc` from `pos` the pattern matches, or -1. Applies
  ## the whole-word test. `pos` must be a rune start.
  if pattern.len == 0 or pos < 0 or pos >= doc.len: return -1
  var stop = -1
  if options.caseSensitive:
    if pos + pattern.len > doc.len: return -1
    for i in 0 ..< pattern.len:
      if doc[pos + i] != pattern[i]: return -1
    stop = pos + pattern.len
  elif isAsciiText(pattern):
    if pos + pattern.len > doc.len: return -1
    for i in 0 ..< pattern.len:
      if lowerAscii(doc[pos + i]) != lowerAscii(pattern[i]): return -1
    stop = pos + pattern.len
  else:
    var p = 0
    var d = pos
    while p < pattern.len:
      if d >= doc.len: return -1
      var pr, dr: Rune
      fastRuneAt(pattern, p, pr, true)
      fastRuneAt(doc, d, dr, true)
      if pr != dr and pr.toLower != dr.toLower: return -1
    stop = d
  if options.wholeWord and (wordBefore(doc, pos) or wordAt(doc, stop)):
    return -1
  stop - pos

func isRuneStart(doc: string; i: int): bool {.inline.} =
  (ord(doc[i]) and 0xC0) != 0x80

func literalMatchesOf(doc, pattern: string; options: MatchOptions;
                      limit: int): seq[MatchSpan] =
  ## Every non-overlapping match of `pattern` in `doc`, in document order,
  ## at most `limit` of them. An empty pattern matches nowhere.
  result = @[]
  if pattern.len == 0: return
  var i = 0
  while i < doc.len and result.len < limit:
    if isRuneStart(doc, i):
      let n = literalLengthAt(doc, pattern, options, i)
      if n > 0:
        result.add MatchSpan(a: i, b: i + n)
        i += n
        continue
    inc i

func literalFirstAtOrAfter(doc, pattern: string; options: MatchOptions;
                           start: int): MatchSpan =
  ## The first match beginning at or after `start`; `a = -1` when none.
  var i = max(0, start)
  while i < doc.len:
    if isRuneStart(doc, i):
      let n = literalLengthAt(doc, pattern, options, i)
      if n > 0: return MatchSpan(a: i, b: i + n)
    inc i
  MatchSpan(a: -1, b: -1)

func literalLastBefore(doc, pattern: string; options: MatchOptions;
                       start: int): MatchSpan =
  ## The last match beginning before `start`; `a = -1` when none.
  var i = min(start, doc.len) - 1
  while i >= 0:
    if isRuneStart(doc, i):
      let n = literalLengthAt(doc, pattern, options, i)
      if n > 0: return MatchSpan(a: i, b: i + n)
    dec i
  MatchSpan(a: -1, b: -1)

# ---------------------------------------------------------------------------
# Regular expressions (OQ-F5)
# ---------------------------------------------------------------------------

type
  CompiledPattern = object
    ## A regular expression compiled once for one search.
    ok: bool
    multiline: bool
    rx: Regex2

func isMultilineSource*(pattern: string): bool =
  ## VS Code's `isMultilineRegexSource`: the expression can match a line
  ## break — a line feed in it, or `\n`, `\r` or `\W` — so it is searched
  ## over the whole text rather than line by line.
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c == '\n': return true
    if c == '\\':
      inc i
      if i >= pattern.len: break
      if pattern[i] in {'n', 'r', 'W'}: return true
    inc i
  false

func classEnd(p: string; i: int): int =
  ## The index just past the bracket class opening at `p[i] == '['`.
  var j = i + 1
  if j < p.len and p[j] == '^': inc j
  if j < p.len and p[j] == ']': inc j
  while j < p.len and p[j] != ']':
    if p[j] == '\\':
      j += 2
    elif p[j] == '[' and j + 1 < p.len and p[j + 1] == ':':
      let k = p.find(":]", j + 2)
      j = if k < 0: p.len else: k + 2
    else:
      inc j
  min(p.len, j + 1)

func escapeEnd(p: string; i: int): int =
  ## The index just past the escape opening at `p[i] == '\\'`, braces
  ## included (`\p{Greek}`, `\x{263a}`).
  var j = i + 2
  if i + 1 < p.len and p[i + 1] in {'p', 'P', 'x', 'u', 'U'} and
     j < p.len and p[j] == '{':
    while j < p.len and p[j] != '}': inc j
    inc j
  min(p.len, j)

func countedRepetition(p: string; i: int):
    tuple[ok: bool; lo, hi: int; unbounded: bool; stop: int] =
  ## `{m}`, `{m,}` or `{m,n}` at `p[i] == '{'`.
  var j = i + 1
  var lo, hi = 0
  var digits = 0
  while j < p.len and p[j] in {'0' .. '9'}:
    lo = min(lo * 10 + (ord(p[j]) - ord('0')), 1_000_000)
    inc j
    inc digits
  if digits == 0 or j >= p.len: return (false, 0, 0, false, i + 1)
  if p[j] == '}': return (true, lo, lo, false, j + 1)
  if p[j] != ',': return (false, 0, 0, false, i + 1)
  inc j
  if j < p.len and p[j] == '}': return (true, lo, lo, true, j + 1)
  digits = 0
  while j < p.len and p[j] in {'0' .. '9'}:
    hi = min(hi * 10 + (ord(p[j]) - ord('0')), 1_000_000)
    inc j
    inc digits
  if digits == 0 or j >= p.len or p[j] != '}': return (false, 0, 0, false, i + 1)
  (true, lo, max(lo, hi), false, j + 1)

func expandedSize*(p: string): int =
  ## An upper estimate of the NFA states `p` expands to: an atom is one, a
  ## group the sum of its alternatives, a counted repetition multiplies what
  ## it repeats by its larger count. Saturates rather than overflowing.
  const Cap = 1_000_000_000
  var stack: seq[tuple[sum, last: int]] = @[(0, 0)]
  template atom(n: int) =
    stack[^1].sum = min(Cap, stack[^1].sum + n)
    stack[^1].last = n
  var i = 0
  while i < p.len:
    case p[i]
    of '\\':
      atom(1)
      i = escapeEnd(p, i)
    of '[':
      atom(1)
      i = classEnd(p, i)
    of '(':
      stack.add (0, 0)
      inc i
    of ')':
      if stack.len > 1:
        let g = stack.pop()
        atom(max(1, g.sum))
      inc i
    of '|':
      stack[^1].last = 0
      inc i
    of '{':
      let r = countedRepetition(p, i)
      if r.ok:
        let k = max(1, r.hi)
        let last = stack[^1].last
        stack[^1].sum = min(Cap, stack[^1].sum + min(Cap, last * (k - 1)) + 1)
        stack[^1].last = min(Cap, last * k)
      else:
        atom(1)
      i = r.stop
    else:
      atom(1)
      inc i
  while stack.len > 1:
    let g = stack.pop()
    stack[^1].sum = min(Cap, stack[^1].sum + g.sum)
  stack[0].sum

func lookaroundRepeats*(p: string): bool =
  ## Whether a look-around in `p` contains an unbounded repetition (`*`,
  ## `+`, `{m,}`) — the one shape nim-regex documents as polynomial.
  var kinds: seq[bool] = @[]
    ## Per open group: is it a look-around.
  var inside = 0
  var i = 0
  while i < p.len:
    case p[i]
    of '\\':
      i = escapeEnd(p, i)
      continue
    of '[':
      i = classEnd(p, i)
      continue
    of '(':
      var look = false
      if i + 2 < p.len and p[i + 1] == '?':
        let k = p[i + 2]
        look = k in {'=', '!'} or
               (k == '<' and i + 3 < p.len and p[i + 3] in {'=', '!'})
      kinds.add look
      if look: inc inside
    of ')':
      if kinds.len > 0:
        if kinds.pop(): dec inside
    of '*', '+':
      if inside > 0: return true
    of '{':
      let r = countedRepetition(p, i)
      if r.ok and r.unbounded and inside > 0: return true
    else: discard
    inc i
  false

func patternError*(pattern: string; options: MatchOptions): string =
  ## Why `pattern` matches nowhere under `options` although it is not empty
  ## — "" when it searches. Only a regular expression can be refused: one
  ## that does not compile, or one the guard refuses (see the header).
  if not options.regex or pattern.len == 0: return ""
  if lookaroundRepeats(pattern):
    return "invalid regular expression: a look-around may not contain " &
           "a repetition (`*`, `+`, `{n,}`): it can take polynomial time"
  if expandedSize(pattern) > RegexSizeLimit:
    return "invalid regular expression: its repetitions expand past " &
           $RegexSizeLimit & " states"
  try:
    discard re2(pattern)
    ""
  except RegexError as e:
    "invalid regular expression: " & e.msg

func compilePattern(text, pattern: string;
                    options: MatchOptions): CompiledPattern =
  ## `pattern` compiled for searching `text`: caseless unless Match Case,
  ## multi-line when it can match a line break, and over arbitrary bytes
  ## when `text` is not valid UTF-8 (nim-regex's matching of invalid UTF-8
  ## is otherwise undefined).
  if patternError(pattern, options).len > 0: return CompiledPattern()
  var flags: RegexFlags = {}
  if not options.caseSensitive: flags.incl regexCaseless
  let multiline = isMultilineSource(pattern)
  if multiline: flags.incl regexMultiline
  if validateUtf8(text) >= 0: flags.incl regexArbitraryBytes
  try:
    CompiledPattern(ok: true, multiline: multiline, rx: re2(pattern, flags))
  except RegexError:
    CompiledPattern()

func pieceAt(text: string; cp: CompiledPattern; pos: int): MatchSpan =
  ## The piece of `text` searched as one string that holds `pos`: the whole
  ## text for a multi-line expression, else `pos`'s line.
  if cp.multiline: return MatchSpan(a: 0, b: text.len)
  var a = min(pos, text.len)
  while a > 0 and text[a - 1] != '\n': dec a
  var b = max(0, pos)
  while b < text.len and text[b] != '\n': inc b
  MatchSpan(a: a, b: b)

iterator piecesFrom(text: string; cp: CompiledPattern; pos: int;
                    forward: bool): MatchSpan =
  ## The pieces from the one holding `pos` onward (or backward).
  var p = pieceAt(text, cp, pos)
  while true:
    yield p
    if forward:
      if p.b >= text.len: break
      p = pieceAt(text, cp, p.b + 1)
    else:
      if p.a <= 0: break
      p = pieceAt(text, cp, p.a - 1)

iterator regexSpansIn(text: string; cp: CompiledPattern; piece: MatchSpan;
                      wholeWord: bool): MatchSpan =
  ## The expression's matches in one piece, in order, offsets in `text`.
  let s = text[piece.a ..< piece.b]
  for bd in findAllBounds(s, cp.rx):
    let a = bd.a
    let b = bd.b + 1
    if wholeWord and (wordBefore(s, a) or wordAt(s, b)): continue
    yield MatchSpan(a: piece.a + a, b: piece.a + b)

func regexMatchesOf(text: string; cp: CompiledPattern; wholeWord: bool;
                    limit: int): seq[MatchSpan] =
  result = @[]
  if not cp.ok or limit <= 0: return
  for piece in piecesFrom(text, cp, 0, forward = true):
    for m in regexSpansIn(text, cp, piece, wholeWord):
      result.add m
      if result.len >= limit: return

func regexFirstAtOrAfter(text: string; cp: CompiledPattern; wholeWord: bool;
                         start: int): MatchSpan =
  if cp.ok and start <= text.len:
    for piece in piecesFrom(text, cp, max(0, start), forward = true):
      for m in regexSpansIn(text, cp, piece, wholeWord):
        if m.a >= start: return m
  MatchSpan(a: -1, b: -1)

func regexLastBefore(text: string; cp: CompiledPattern; wholeWord: bool;
                     start: int): MatchSpan =
  result = MatchSpan(a: -1, b: -1)
  if not cp.ok or start <= 0: return
  for piece in piecesFrom(text, cp, min(start, text.len), forward = false):
    for m in regexSpansIn(text, cp, piece, wholeWord):
      if m.a < start: result = m
      else: break
    if result.a >= 0: return

# ---------------------------------------------------------------------------
# The one matcher (FS-1): literal or regular expression, whole text or scope
# ---------------------------------------------------------------------------

func rangesOf(doc: string; scope: openArray[MatchSpan]): seq[MatchSpan] =
  ## The ranges searched: the whole document, or the scope's ranges clipped
  ## to it, in document order.
  if scope.len == 0: return @[MatchSpan(a: 0, b: doc.len)]
  result = @[]
  for r in scope:
    let a = clamp(min(r.a, r.b), 0, doc.len)
    let b = clamp(max(r.a, r.b), 0, doc.len)
    if b > a: result.add MatchSpan(a: a, b: b)
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and result[j - 1].a > result[j].a:
      swap(result[j - 1], result[j])
      dec j

func textOf(doc: string; r: MatchSpan): string =
  if r.a == 0 and r.b == doc.len: doc else: doc[r.a ..< r.b]

func spansIn(doc, pattern: string; options: MatchOptions; r: MatchSpan;
             limit: int): seq[MatchSpan] =
  ## The matches inside one range, offsets in the document.
  let t = textOf(doc, r)
  result = if options.regex:
             regexMatchesOf(t, compilePattern(t, pattern, options),
                            options.wholeWord, limit)
           else:
             literalMatchesOf(t, pattern, options, limit)
  if r.a != 0:
    for m in result.mitems:
      m.a += r.a
      m.b += r.a

func matchesOf*(doc, pattern: string; options: MatchOptions;
                limit = MatchesLimit;
                scope: openArray[MatchSpan] = []): seq[MatchSpan] =
  ## Every non-overlapping match of `pattern` in `doc` — or, with a
  ## `scope`, in its ranges only (Find in Selection) — in document order,
  ## at most `limit` of them. An empty pattern, and a regular expression
  ## `patternError` refuses, match nowhere.
  result = @[]
  if pattern.len == 0: return
  for r in rangesOf(doc, scope):
    if result.len >= limit: break
    result.add spansIn(doc, pattern, options, r, limit - result.len)

func matchLengthAt*(doc, pattern: string; options: MatchOptions;
                    pos: int): int =
  ## How many bytes of `doc` from `pos` the pattern matches, or -1. Applies
  ## the whole-word test. `pos` must be a rune start. A regular expression
  ## answers the match its search of `pos`'s line finds beginning at `pos`
  ## (0 for an empty one).
  if not options.regex:
    return literalLengthAt(doc, pattern, options, pos)
  if pattern.len == 0 or pos < 0 or pos > doc.len: return -1
  let cp = compilePattern(doc, pattern, options)
  if not cp.ok: return -1
  for m in regexSpansIn(doc, cp, pieceAt(doc, cp, pos), options.wholeWord):
    if m.a == pos: return m.b - m.a
    if m.a > pos: break
  -1

func firstIn(doc, pattern: string; options: MatchOptions; r: MatchSpan;
             start: int): MatchSpan =
  ## The first match in range `r` beginning at or after `start` (a document
  ## offset); `a = -1` when none.
  let t = textOf(doc, r)
  let s = start - r.a
  result = if options.regex:
             regexFirstAtOrAfter(t, compilePattern(t, pattern, options),
                                 options.wholeWord, s)
           else:
             literalFirstAtOrAfter(t, pattern, options, s)
  if result.a >= 0:
    result.a += r.a
    result.b += r.a

func lastIn(doc, pattern: string; options: MatchOptions; r: MatchSpan;
            start: int): MatchSpan =
  ## The last match in range `r` beginning before `start`.
  let t = textOf(doc, r)
  let s = start - r.a
  result = if options.regex:
             regexLastBefore(t, compilePattern(t, pattern, options),
                             options.wholeWord, s)
           else:
             literalLastBefore(t, pattern, options, s)
  if result.a >= 0:
    result.a += r.a
    result.b += r.a

func nextMatchOf*(doc, pattern: string; options: MatchOptions; start: int;
                  forward: bool;
                  scope: openArray[MatchSpan] = []): MatchWalk =
  ## The walk: forward, the first match beginning at or after `start`, else
  ## the first (wrapped); backward, the last match beginning before
  ## `start`, else the last (wrapped) — of the document, or of the scope's
  ## ranges. Not bounded by `MatchesLimit`.
  if pattern.len == 0: return MatchWalk()
  let ranges = rangesOf(doc, scope)
  if forward:
    for r in ranges:
      if r.b < start: continue
      let m = firstIn(doc, pattern, options, r, max(start, r.a))
      if m.a >= 0: return MatchWalk(found: true, span: m)
    for r in ranges:
      let m = firstIn(doc, pattern, options, r, r.a)
      if m.a >= 0: return MatchWalk(found: true, span: m, wrapped: true)
  else:
    for i in countdown(ranges.high, 0):
      let r = ranges[i]
      if r.a >= start: continue
      let m = lastIn(doc, pattern, options, r, min(start, r.b + 1))
      if m.a >= 0: return MatchWalk(found: true, span: m)
    for i in countdown(ranges.high, 0):
      let r = ranges[i]
      let m = lastIn(doc, pattern, options, r, r.b + 1)
      if m.a >= 0: return MatchWalk(found: true, span: m, wrapped: true)
  MatchWalk()

func literalPattern*(text: string; options: MatchOptions): string =
  ## `text` as a pattern that finds it verbatim under `options`: escaped
  ## when the pattern is a regular expression (VS Code escapes a seed taken
  ## from the selection the same way).
  if options.regex: escapeRe(text) else: text

func isWholeWordText*(s: string): bool =
  ## Whether `s` is made only of word runes — the test Vim's `*` and
  ## Kakoune's `*` use to decide whether to add word boundaries.
  if s.len == 0: return false
  for r in s.runes:
    if not r.isWordRune: return false
  true
