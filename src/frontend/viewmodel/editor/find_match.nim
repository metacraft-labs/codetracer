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
## A LITERAL pattern (the editor core's import closure is an allow-list of
## `std/` modules, `ci/test/editor-import-closure.sh`, so no regular-expression
## engine is admitted here; Find in Files' regular expressions are
## `host/text_match.nim`'s, over files, not over this document):
##
## * **case** — `caseSensitive: false` folds each rune with Unicode's simple
##   lower-case mapping (`std/unicode.toLower`), so `Σ` finds `σ`. A pattern
##   that is all ASCII is folded byte by byte, the fast path, and then matches
##   only ASCII text — the Kelvin sign does not fold to `k` there (recorded in
##   the spec's §3.1 notes);
## * **whole word** — the rune before the match and the rune after it are not
##   word runes (`isWordRune`: a letter, a decimal digit or `_`, the editor's
##   own word class, so "a word" means what the word motions mean by it).
##   Vim's `\<…\>` and VS Code's Match Whole Word;
## * **non-overlapping, in document order** — `aa` in `aaaa` is two matches,
##   at 0 and 2 (Vim's, and CTUI-10's, rule: the count never exceeds the
##   places a reader can see);
## * **at a rune start** — a match never begins inside a UTF-8 sequence.
##
## Offsets are BYTES of the document, `[a, b)`.

import std/unicode

type
  MatchOptions* = object
    ## The toggles a match is computed with. Held with the pattern in
    ## `EditorState.search` (the one store), so `n` / `F3` after a find
    ## closes match exactly what the find highlighted.
    caseSensitive*: bool
    wholeWord*: bool

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

func `==`*(a, b: MatchOptions): bool =
  a.caseSensitive == b.caseSensitive and a.wholeWord == b.wholeWord

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

func matchLengthAt*(doc, pattern: string; options: MatchOptions;
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

func matchesOf*(doc, pattern: string; options: MatchOptions;
                limit = MatchesLimit): seq[MatchSpan] =
  ## Every non-overlapping match of `pattern` in `doc`, in document order,
  ## at most `limit` of them. An empty pattern matches nowhere.
  result = @[]
  if pattern.len == 0: return
  var i = 0
  while i < doc.len and result.len < limit:
    if isRuneStart(doc, i):
      let n = matchLengthAt(doc, pattern, options, i)
      if n > 0:
        result.add MatchSpan(a: i, b: i + n)
        i += n
        continue
    inc i

func firstAtOrAfter(doc, pattern: string; options: MatchOptions;
                    start: int): MatchSpan =
  ## The first match beginning at or after `start`; `a = -1` when none.
  var i = max(0, start)
  while i < doc.len:
    if isRuneStart(doc, i):
      let n = matchLengthAt(doc, pattern, options, i)
      if n > 0: return MatchSpan(a: i, b: i + n)
    inc i
  MatchSpan(a: -1, b: -1)

func lastBefore(doc, pattern: string; options: MatchOptions;
                start: int): MatchSpan =
  ## The last match beginning before `start`; `a = -1` when none.
  var i = min(start, doc.len) - 1
  while i >= 0:
    if isRuneStart(doc, i):
      let n = matchLengthAt(doc, pattern, options, i)
      if n > 0: return MatchSpan(a: i, b: i + n)
    dec i
  MatchSpan(a: -1, b: -1)

func nextMatchOf*(doc, pattern: string; options: MatchOptions; start: int;
                  forward: bool): MatchWalk =
  ## The walk: forward, the first match beginning at or after `start`, else
  ## the document's first (wrapped); backward, the last match beginning
  ## before `start`, else the document's last (wrapped). Not bounded by
  ## `MatchesLimit`.
  if pattern.len == 0: return MatchWalk()
  if forward:
    let m = firstAtOrAfter(doc, pattern, options, start)
    if m.a >= 0: return MatchWalk(found: true, span: m)
    let w = firstAtOrAfter(doc, pattern, options, 0)
    if w.a >= 0: return MatchWalk(found: true, span: w, wrapped: true)
  else:
    let m = lastBefore(doc, pattern, options, start)
    if m.a >= 0: return MatchWalk(found: true, span: m)
    let w = lastBefore(doc, pattern, options, doc.len)
    if w.a >= 0: return MatchWalk(found: true, span: w, wrapped: true)
  MatchWalk()

func isWholeWordText*(s: string): bool =
  ## Whether `s` is made only of word runes — the test Vim's `*` and
  ## Kakoune's `*` use to decide whether to add word boundaries.
  if s.len == 0: return false
  for r in s.runes:
    if not r.isWordRune: return false
  true
