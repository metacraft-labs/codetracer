## find_vm.nim — PLAT-70 Part C: THE FIND SESSION every base drives
## (Find-And-Incremental-Search.md §3, §4).
##
## Owns: `FindVM` — one session per editor element (§3.6): open / closed,
## the direction, the case rule its base gives it, the ORIGIN taken once when
## it opens (every range of the selection, the vertical top, the horizontal
## left column, and the document version they were taken at), the match set
## of the query over the whole document (capped at `MatchesLimit`), the
## current match and whether the last move wrapped; the field's text and
## caret while it is open. And its operations: open with a seed (§4.1),
## typing (§3.3), the walk (§3.4), accept and cancel (§3.5), the toggles,
## Emacs's `C-w` (`yankWord`) and `M-s .` (`openSymbolAtCaret`), the closed
## walk (`F3` / `n` after the session closed) and CUA's `Ctrl+F3`
## (`nextSelectionMatch`, the one named operation of §4.2, because a macro
## row has no `if`).
##
## Refuses to own:
##
## * **the pattern.** It is `EditorState.search` — the one pattern store
##   (§2 principle 2). While the session is open the field's text IS
##   `state.search.pattern`, written on every change; the only copy this
##   holds is the pattern the session REPLACED (`previousPattern`), for
##   `C-s C-s` / Vim's `/<CR>` on an empty field and for a cancel that
##   restores it, and it is dropped when the session closes (FS-2: *"No
##   FindVM field holds the pattern after close"*);
## * **the matcher.** `editor/find_match.matchesOf` (FS-1);
## * **drawing.** Each front-end paints the marks this answers
##   (`marksInWindow`) in its own medium: the terminal and GPUI in the editor
##   itself (§3.3: *"a change in the editor surface, not an overlay"*), the
##   desktop through Monaco's own widget;
## * **keys.** A front-end's router resolves a key to `find.*` and calls the
##   operation here; nothing in this module reads a key name (IR-1).
##
## Every operation takes the document it searches as `var EditingDocument`
## and the viewport as numbers: a value in, a value out, so the terminal's and
## GPUI's sessions are the same computation and a suite drives it with no
## front-end at all (`test_plat70c_find_vm.nim`, C and JS).

import std/[strutils, unicode]

import ../editing_core

export find_match

type
  FindCaseRule* = enum
    ## §3.1's per-base defaults for Match Case.
    fcrInsensitive = "insensitive"  ## CUA: VS Code's default
    fcrSensitive = "sensitive"      ## Vim's `noignorecase`, Kakoune's regex
    fcrSmart = "smart"
      ## Emacs's `case-fold-search` with `search-upper-case`: folding until
      ## the query has an upper-case letter.

  FindSeed* = enum
    ## What `open` puts in the field (§4.1).
    fsNone = "none"
      ## Vim's `/`, Kakoune's `/`, Emacs's `C-s`: the prompt opens empty.
    fsSelectionOrWord = "selection-or-word"
      ## `Ctrl+F` / `find.open` under CUA: a one-line selection, else the
      ## word at the caret, else the last pattern (VS Code's
      ## `seedSearchStringFromSelection: "always"`).

  FindSelect* = enum
    ## How a base shows the current match in the document.
    fselSpan = "span"
      ## The match selected (VS Code, isearch, Kakoune).
    fselCaretAtStart = "caret-at-start"
      ## The caret on the match's first character (Vim's `incsearch`: Vim's
      ## normal mode has no selection).

  FindOrigin* = object
    ## §3.1: where the find started — taken ONCE, when the session opens.
    selection*: EditorSelection
      ## Every range, not only the primary.
    top*: int
      ## The first line the pane showed (1-based).
    leftCol*: int
      ## The horizontal view's left column.
    version*: DocumentVersion
      ## The document's version at that moment, so a cancel maps the
      ## selection through any edit made while the session was open (§3.5).
    searchFrom*: int
      ## Where "the first match at or after the origin" is measured from: the
      ## selection's start, or — for `M-s .` — the end of the symbol it
      ## pulled in, so the first match is the NEXT occurrence.

  FindVM* = object
    open*: bool
    owner*: string
      ## The editor element the session belongs to (Base-Keymaps §5.3).
    modal*: bool
      ## The base is modal (Vim, Kakoune): `find.next` follows the session's
      ## direction, as `n` does; under CUA and Emacs it is absolute.
    direction*: SearchDirection
    caseRule*: FindCaseRule
    caseExplicit*: bool
      ## The case toggle was used in this session, so `fcrSmart` stops
      ## deciding (Emacs's `M-c`).
    select*: FindSelect
    origin*: FindOrigin
    matches*: seq[MatchSpan]
      ## The query's matches over the WHOLE document, in document order,
      ## recomputed on every change (CTUI-10's rule: never narrowed).
    capped*: bool
      ## `matches` stopped at `MatchesLimit`; the count reads `19999+`.
    current*: MatchSpan
      ## The current match; `a = -1` for none.
    wrapped*: bool
      ## The last move wrapped (Vim's `search hit BOTTOM, continuing at TOP`).
    field*: string
      ## The field's text while open — `state.search.pattern` exactly.
    cursor*: int
      ## The field's caret, a byte offset into `field`.
    fieldSelected*: bool
      ## The seed is selected in the field, so the first typed character
      ## replaces it (§3.2).
    previousPattern: string
    previousOptions: MatchOptions
      ## The pattern and toggles the session replaced (see the header).
    windowCache: tuple[key: string; marks: seq[FindMark]]

  FindMark* = object
    ## One painted highlight: a 1-based line and 1-based cell columns
    ## `[fromColumn, toColumn)` (`editing_core.selectionCells`' units), and
    ## whether it is the current match (drawn in the distinct style, §3.3).
    line*, fromColumn*, toColumn*: int
    current*: bool

  FindReveal* = object
    ## What a move asks of the view: the line to bring into view (0 for
    ## nothing) — vertically centred when it was off-screen (§3.3 step 3);
    ## the horizontal view follows the caret (Horizontal-Overflow §4.5).
    line*: int

const
  NoMatchesText* = "no matches"
  NoPreviousPatternText* = "no previous search pattern"
    ## Vim's `E35`.
  WrappedForwardText* = "search hit BOTTOM, continuing at TOP"
  WrappedBackwardText* = "search hit TOP, continuing at BOTTOM"
  HighlightMarginLines* = 50
    ## With the match set capped, only the matches in and near the viewport
    ## are highlighted (§3.1): this many lines above and below it.

func noSpan(): MatchSpan = MatchSpan(a: -1, b: -1)

func hasCurrent*(f: FindVM): bool = f.current.a >= 0

func caseRuleFor*(model: BaseKeymap): FindCaseRule =
  case model
  of bkCua: fcrInsensitive
  of bkEmacs: fcrSmart
  of bkVim, bkKakoune: fcrSensitive

func selectFor*(model: BaseKeymap): FindSelect =
  if model == bkVim: fselCaretAtStart else: fselSpan

func hasUpper(s: string): bool =
  for r in s.runes:
    if r.isUpper: return true
  false

# ---------------------------------------------------------------------------
# The match set
# ---------------------------------------------------------------------------

proc recompute(f: var FindVM; d: EditingDocument) =
  let st = d.state.search
  f.matches = matchesOf(d.state.doc, st.pattern, st.options)
  f.capped = f.matches.len >= MatchesLimit
  f.windowCache = ("", @[])

func currentIndex*(f: FindVM): int =
  ## The current match's index in `matches`, or -1 (none, or past the cap).
  if not f.hasCurrent: return -1
  var lo = 0
  var hi = f.matches.high
  while lo <= hi:
    let mid = (lo + hi) div 2
    if f.matches[mid].a == f.current.a: return mid
    if f.matches[mid].a < f.current.a: lo = mid + 1 else: hi = mid - 1
  -1

proc showCurrent(f: FindVM; d: var EditingDocument) =
  ## Select the current match in the document as the base shows one.
  if not f.hasCurrent: return
  case f.select
  of fselSpan: d.selectSpan(f.current.a, f.current.b)
  of fselCaretAtStart: d.selectSpan(f.current.a, f.current.a)

func revealOf(d: EditingDocument; span: MatchSpan): FindReveal =
  if span.a < 0: FindReveal() else:
    FindReveal(line: caretPosOf(d.state.doc, span.a).line + 1)

func revealTop*(top, rows, line: int): int =
  ## The pane's top after revealing `line`: unchanged when it is already in
  ## view, else the line vertically centred (§3.3 step 3).
  if line <= 0 or rows <= 0: return top
  if line >= top and line <= top + rows - 1: return top
  max(1, line - (rows - 1) div 2)

proc pickFromOrigin(f: var FindVM; d: var EditingDocument): FindReveal =
  ## §3.3 steps 2–3: the first match at or after the ORIGIN in the session's
  ## direction (not after the previous current match), selected and
  ## revealed; with none, the origin's selection put back.
  let st = d.state.search
  f.wrapped = false
  f.current = noSpan()
  if st.pattern.len > 0:
    let w = nextMatchOf(d.state.doc, st.pattern, st.options,
                        f.origin.searchFrom,
                        forward = f.direction == sdForward)
    if w.found:
      f.current = w.span
      f.wrapped = w.wrapped
  if f.hasCurrent:
    f.showCurrent(d)
    return revealOf(d, f.current)
  d.state.selection = f.origin.selection
  FindReveal()

proc applyCase(f: FindVM; d: var EditingDocument) =
  if f.caseRule == fcrSmart and not f.caseExplicit:
    d.state.search.options.caseSensitive = hasUpper(d.state.search.pattern)

# ---------------------------------------------------------------------------
# Opening
# ---------------------------------------------------------------------------

proc wordAtCaret*(d: EditingDocument): tuple[a, b: int] =
  ## The word at the caret — the `select-inner-word` span, without changing
  ## the selection — or `(-1, -1)` when the caret is not on a word.
  let r = applyOperation(d.state, "select-inner-word", OpArgs(), d.settings,
                         d.viewportRows)
  let m = r.state.selection.mainRange
  let a = m.rangeFrom
  let b = min(m.rangeTo, d.state.doc.len)
  if b > a and isWholeWordText(d.state.doc[a ..< b]): (a, b) else: (-1, -1)

func selectionText*(d: EditingDocument): string =
  ## The main selection's text ("" for a caret) — what §4.1's seed and Find
  ## in Files' seed (§5.2, `search_results_vm.findInFilesSeed`) start from.
  let m = d.state.selection.mainRange
  if m.isEmpty: "" else: d.state.doc[m.rangeFrom ..< min(m.rangeTo, d.state.doc.len)]

proc seedOf(d: EditingDocument; seed: FindSeed): string =
  ## §4.1, in its order.
  case seed
  of fsNone: ""
  of fsSelectionOrWord:
    let t = selectionText(d)
    if t.len > 0:
      if '\n' notin t: return t
      return d.state.search.pattern
    let w = wordAtCaret(d)
    if w.a >= 0: d.state.doc[w.a ..< w.b] else: d.state.search.pattern

proc openFind*(f: var FindVM; d: var EditingDocument; model: BaseKeymap;
           owner: string; backward: bool; seed: FindSeed;
           top, leftCol: int): FindReveal =
  ## `find.open` / `find.open-backward` (§3.2): the origin taken, the field
  ## seeded (and selected, so typing replaces it), the seed's matches
  ## highlighted and the match at or after the caret made current. **Opening
  ## does not move the caret.**
  let caseSensitive = d.state.search.options.caseSensitive
  f = FindVM(open: true, owner: owner, modal: isModal(model),
             direction: (if backward: sdBackward else: sdForward),
             caseRule: caseRuleFor(model), select: selectFor(model))
  f.previousPattern = d.state.search.pattern
  f.previousOptions = d.state.search.options
  f.origin = FindOrigin(selection: d.state.selection, top: top,
                        leftCol: leftCol, version: d.version,
                        searchFrom: (if backward:
                                       d.state.selection.mainRange.rangeTo
                                     else:
                                       d.state.selection.mainRange.rangeFrom))
  let text = seedOf(d, seed)
  f.field = text
  f.cursor = text.len
  f.fieldSelected = text.len > 0
  d.state.search.direction = f.direction
  d.state.search.pattern = text
  d.state.search.options = MatchOptions(
    caseSensitive: (case f.caseRule
                    of fcrInsensitive: false
                    of fcrSensitive: true
                    of fcrSmart: caseSensitive),
    wholeWord: false)
  f.applyCase(d)
  f.recompute(d)
  if text.len > 0:
    let w = nextMatchOf(d.state.doc, text, d.state.search.options,
                        f.origin.searchFrom, forward = not backward)
    if w.found: f.current = w.span
  revealOf(d, f.current)

proc openSymbolAtCaret*(f: var FindVM; d: var EditingDocument;
                        model: BaseKeymap; owner: string;
                        top, leftCol: int): FindReveal =
  ## Emacs's `M-s .` (`isearch-forward-symbol-at-point`, §4.5): the macro
  ## `[select-inner-word, find.open-with-selection-whole-word]` — the session
  ## opened on the symbol at the caret with whole word set, its next
  ## occurrence current.
  let w = wordAtCaret(d)
  if w.a < 0:
    return f.openFind(d, model, owner, backward = false, fsNone, top, leftCol)
  discard f.openFind(d, model, owner, backward = false, fsNone, top, leftCol)
  f.origin.searchFrom = w.b
  f.field = d.state.doc[w.a ..< w.b]
  f.cursor = f.field.len
  f.fieldSelected = false
  d.state.search.pattern = f.field
  d.state.search.options.wholeWord = true
  f.applyCase(d)
  f.recompute(d)
  f.pickFromOrigin(d)

# ---------------------------------------------------------------------------
# Typing (§3.3)
# ---------------------------------------------------------------------------

proc setQuery*(f: var FindVM; d: var EditingDocument; text: string;
               cursor = -1): FindReveal =
  ## Every change to the query — typing, deleting, pasting: the pattern
  ## store written, the match set recomputed, the first match at or after
  ## the origin selected and revealed.
  f.field = text
  f.cursor = if cursor < 0: text.len else: clamp(cursor, 0, text.len)
  f.fieldSelected = false
  d.state.search.pattern = text
  f.applyCase(d)
  f.recompute(d)
  f.pickFromOrigin(d)

proc typeText*(f: var FindVM; d: var EditingDocument; s: string): FindReveal =
  ## Characters typed into the field: a selected seed is replaced.
  if f.fieldSelected:
    return f.setQuery(d, s)
  let text = f.field[0 ..< f.cursor] & s & f.field[f.cursor .. ^1]
  f.setQuery(d, text, f.cursor + s.len)

proc runeStartBefore(s: string; i: int): int =
  var j = i - 1
  while j > 0 and (ord(s[j]) and 0xC0) == 0x80: dec j
  max(0, j)

proc deleteBackward*(f: var FindVM; d: var EditingDocument): FindReveal =
  if f.fieldSelected:
    return f.setQuery(d, "")
  if f.cursor <= 0: return revealOf(d, f.current)
  let a = runeStartBefore(f.field, f.cursor)
  f.setQuery(d, f.field[0 ..< a] & f.field[f.cursor .. ^1], a)

proc deleteForward*(f: var FindVM; d: var EditingDocument): FindReveal =
  if f.fieldSelected:
    return f.setQuery(d, "")
  if f.cursor >= f.field.len: return revealOf(d, f.current)
  var b = f.cursor + 1
  while b < f.field.len and (ord(f.field[b]) and 0xC0) == 0x80: inc b
  f.setQuery(d, f.field[0 ..< f.cursor] & f.field[b .. ^1], f.cursor)

proc moveFieldCursor*(f: var FindVM; delta: int) =
  ## `input.move-left` / `-right` in the field (by rune).
  f.fieldSelected = false
  if delta < 0 and f.cursor > 0:
    f.cursor = runeStartBefore(f.field, f.cursor)
  elif delta > 0 and f.cursor < f.field.len:
    inc f.cursor
    while f.cursor < f.field.len and
          (ord(f.field[f.cursor]) and 0xC0) == 0x80:
      inc f.cursor

proc fieldHome*(f: var FindVM) =
  f.fieldSelected = false
  f.cursor = 0

proc fieldEnd*(f: var FindVM) =
  f.fieldSelected = false
  f.cursor = f.field.len

proc toggleCase*(f: var FindVM; d: var EditingDocument): FindReveal =
  ## `find.toggle-case` (`Alt+C`, Emacs `M-c`): the store's toggle flipped,
  ## the search run again from the origin.
  f.caseExplicit = true
  d.state.search.options.caseSensitive = not d.state.search.options.caseSensitive
  f.recompute(d)
  f.pickFromOrigin(d)

proc toggleWholeWord*(f: var FindVM; d: var EditingDocument): FindReveal =
  ## `find.toggle-whole-word` (`Alt+W`).
  d.state.search.options.wholeWord = not d.state.search.options.wholeWord
  f.recompute(d)
  f.pickFromOrigin(d)

# ---------------------------------------------------------------------------
# Walking (§3.4)
# ---------------------------------------------------------------------------

proc step*(f: var FindVM; d: var EditingDocument; next: bool): FindReveal =
  ## `find.next` / `find.previous` with the session open: the current match
  ## moved forward / backward from the current one (from the origin when
  ## there is none), wrapping at the ends, selected and revealed. Under a
  ## modal base `next` is ONWARD in the session's direction (`n` after `?`
  ## walks backward); under CUA and Emacs it is absolute.
  let st = d.state.search
  if st.pattern.len == 0:
    if f.previousPattern.len == 0: return FindReveal()
    # `C-s C-s` on an empty field: the last pattern (§4.1).
    return f.setQuery(d, f.previousPattern)
  let forward = if f.modal: (f.direction == sdForward) == next else: next
  let start =
    if f.hasCurrent: (if forward: f.current.a + 1 else: f.current.a)
    else: f.origin.searchFrom
  let w = nextMatchOf(d.state.doc, st.pattern, st.options, start, forward)
  f.wrapped = w.wrapped
  if not w.found:
    f.current = noSpan()
    return FindReveal()
  f.current = w.span
  f.showCurrent(d)
  revealOf(d, f.current)

proc walkClosed*(d: var EditingDocument; model: BaseKeymap;
                 next: bool): tuple[reveal: FindReveal; wrapped: bool;
                                    message: string] =
  ## `find.next` / `find.previous` with no session open (§3.4): the last
  ## pattern walked from the selection — so `F3` after the widget closed and
  ## Vim's `n` continue the search. With no pattern, CUA's `F3` first seeds
  ## from the word at the caret (VS Code); the others report Vim's `E35`.
  if d.state.search.pattern.len == 0:
    let w = wordAtCaret(d)
    if model != bkCua or w.a < 0:
      return (FindReveal(), false, NoPreviousPatternText)
    d.state.search.pattern = d.state.doc[w.a ..< w.b]
    d.state.search.options.wholeWord = false
  let st = d.state.search
  let forward = if isModal(model): (st.direction == sdForward) == next
                else: next
  let m = d.state.selection.mainRange
  let start = if forward: min(m.rangeFrom + 1, d.state.doc.len)
              else: m.rangeFrom
  let w = nextMatchOf(d.state.doc, st.pattern, st.options, start, forward)
  if not w.found:
    return (FindReveal(), false, NoMatchesText)
  case selectFor(model)
  of fselSpan: d.selectSpan(w.span.a, w.span.b)
  of fselCaretAtStart: d.selectSpan(w.span.a, w.span.a)
  (revealOf(d, w.span), w.wrapped,
   (if not w.wrapped: ""
    elif forward: WrappedForwardText else: WrappedBackwardText))

proc nextSelectionMatch*(d: var EditingDocument; backward: bool;
                         nowMs: int64): tuple[reveal: FindReveal;
                                              message: string] =
  ## CUA's `Ctrl+F3` / `Ctrl+Shift+F3` (§4.2), VS Code's
  ## `nextSelectionMatchFindAction`: ONE NAMED OPERATION over the
  ## vocabulary's primitives, because its first step is conditional —
  ##
  ## ```text
  ## [ if empty selection: select-inner-word, search-selection-whole-word
  ##   else:                search-selection ;
  ##   search-forward | search-backward ; search-next ]
  ## ```
  ##
  ## — then the match the caret landed on selected (VS Code selects it).
  ## The find widget is not opened.
  let wasEmpty = d.state.selection.mainRange.isEmpty
  if wasEmpty:
    if wordAtCaret(d).a < 0:
      return (FindReveal(), "find: no word at the caret")
    discard d.applyNamed("select-inner-word", OpArgs(), nowMs)
    discard d.applyNamed("search-selection-whole-word", OpArgs(), nowMs)
  else:
    discard d.applyNamed("search-selection", OpArgs(), nowMs)
  discard d.applyNamed((if backward: "search-backward" else: "search-forward"),
                       OpArgs(), nowMs)
  # From the selection's START, so the occurrence selected now is left
  # behind in both directions (the motion searches from the head).
  let m = d.state.selection.mainRange
  d.selectSpan(m.rangeTo, m.rangeFrom)
  if d.applyNamed("move-search-next", OpArgs(), nowMs) == eoIgnored:
    return (FindReveal(), NoMatchesText)
  let at = d.state.selection.mainRange.head
  let n = matchLengthAt(d.state.doc, d.state.search.pattern,
                        d.state.search.options, at)
  if n > 0: d.selectSpan(at, at + n)
  (FindReveal(line: caretPosOf(d.state.doc, at).line + 1), "")

# ---------------------------------------------------------------------------
# Emacs: `C-w` (§4.5)
# ---------------------------------------------------------------------------

proc yankWord*(f: var FindVM; d: var EditingDocument): FindReveal =
  ## `find.yank-word` — `isearch-yank-word-or-char`: the text from the end
  ## of the current match (the first time, from the caret) through the end
  ## of the next word, appended to the query. "A word" is the editor's: the
  ## `group-right` motion, taken until it has crossed a word.
  let doc = d.state.doc
  let start = if f.hasCurrent: f.current.b
              else: d.state.selection.mainRange.head
  if start >= doc.len: return revealOf(d, f.current)
  var probe = d.state
  probe.selection = caretSelection(start)
  var stop = start
  while stop < doc.len:
    let r = applyOperation(probe, "move-group-right", OpArgs(), d.settings,
                           d.viewportRows)
    let p = r.state.selection.mainRange.head
    if p <= stop: break
    stop = p
    probe = r.state
    var crossed = false
    for ru in doc[start ..< stop].runes:
      if ru.isWordRune: crossed = true
    if crossed: break
  if stop <= start: return revealOf(d, f.current)
  # The origin stays where the session opened, so the grown query's first
  # match at or after it is the match it grew from.
  f.setQuery(d, f.field & doc[start ..< stop])

# ---------------------------------------------------------------------------
# Leaving (§3.5)
# ---------------------------------------------------------------------------

proc close(f: var FindVM) =
  ## Popped: nothing of the session survives but the pattern in the store.
  f = FindVM()

proc accept*(f: var FindVM; d: var EditingDocument): FindReveal =
  ## `find.accept` (and CUA's `find.close`): close and KEEP the current match
  ## selected. The pattern stays the editor's. An empty field reuses the last
  ## pattern and walks to it (Vim's `/<CR>`, Emacs's `C-s RET` on an empty
  ## query).
  result = FindReveal()
  if f.field.len == 0 and f.previousPattern.len > 0:
    d.state.search.pattern = f.previousPattern
    d.state.search.options = f.previousOptions
    let w = nextMatchOf(d.state.doc, f.previousPattern, f.previousOptions,
                        f.origin.searchFrom + (if f.direction == sdForward: 1
                                               else: 0),
                        forward = f.direction == sdForward)
    if w.found:
      f.current = w.span
      f.showCurrent(d)
      result = revealOf(d, w.span)
  f.close()

proc cancel*(f: var FindVM; d: var EditingDocument):
    tuple[top, leftCol: int] =
  ## `find.cancel` (Emacs `C-g`, Vim and Kakoune `Escape`, the palette's
  ## **Find: Cancel and Return**): close and restore the ORIGIN exactly —
  ## every range of the selection (mapped through any edit made meanwhile,
  ## §3.5), and both scroll offsets, which are answered for the front-end to
  ## set on its view. The pattern stays (an empty field's cancel leaves the
  ## previous one).
  var sel = f.origin.selection
  if d.version != f.origin.version and d.timeline.knows(f.origin.version):
    sel = mapSelection(sel, d.timeline.delta(f.origin.version))
  d.state.selection = sel
  if f.field.len == 0:
    d.state.search.pattern = f.previousPattern
    d.state.search.options = f.previousOptions
  result = (f.origin.top, f.origin.leftCol)
  f.close()

# ---------------------------------------------------------------------------
# What the user sees
# ---------------------------------------------------------------------------

func countText*(f: FindVM; d: EditingDocument): string =
  ## §3.3 step 5: `3 of 17`, `19999+` past the cap, `no matches`.
  if d.state.search.pattern.len == 0: return ""
  if f.matches.len == 0: return NoMatchesText
  let total = if f.capped: $MatchesLimit & "+" else: $f.matches.len
  let i = f.currentIndex
  if i < 0: (if f.hasCurrent: "? of " & total else: total)
  else: $(i + 1) & " of " & total

func wrapText*(f: FindVM): string =
  if not f.wrapped: ""
  elif f.direction == sdForward: WrappedForwardText
  else: WrappedBackwardText

func statusText*(f: FindVM; d: EditingDocument): string =
  ## The terminal's status-line form of the field: the count and the wrap.
  result = f.countText(d)
  let w = f.wrapText
  if w.len > 0:
    result.add (if result.len > 0: "  " else: "") & w

func closedHighlightActive*(d: EditingDocument): bool =
  ## With no session open, the highlights stay while the selection is ON a
  ## match (§4.2: *"drawn until the selection moves off a match"*): the
  ## selection is exactly one, or the caret sits at one's start (Vim's `*`).
  let st = d.state.search
  if st.pattern.len == 0: return false
  let m = d.state.selection.mainRange
  let n = matchLengthAt(d.state.doc, st.pattern, st.options, m.rangeFrom)
  n > 0 and (m.isEmpty or m.rangeTo - m.rangeFrom == n)

proc lineStartsIn(doc: string; firstLine, lastLine: int):
    tuple[first: int; starts: seq[int]] =
  ## The byte offsets of lines `firstLine .. lastLine + 1` (1-based), by one
  ## scan; `first` is the line the first entry belongs to.
  var line = 1
  var starts: seq[int] = @[]
  if firstLine <= 1: starts.add 0
  for i, c in doc:
    if c == '\n':
      inc line
      if line >= firstLine and line <= lastLine + 1:
        starts.add i + 1
      elif line > lastLine + 1:
        break
  (max(1, firstLine), starts)

proc marksInWindow*(f: var FindVM; d: EditingDocument;
                    firstLine, rows: int): seq[FindMark] =
  ## THE HIGHLIGHTS (§3.3 step 4) on lines `firstLine ..< firstLine + rows`:
  ## every match as a mark, the current one flagged. With the session
  ## closed, the store's pattern's matches while `closedHighlightActive`.
  ## Past the cap only the matches in and near the window are drawn (§3.1),
  ## so the window's are computed over the window's text when capped.
  if rows <= 0: return @[]
  let st = d.state.search
  if st.pattern.len == 0: return @[]
  if not f.open and not closedHighlightActive(d): return @[]
  let lastLine = firstLine + rows - 1
  let key = $d.version & "|" & st.pattern & "|" & $st.options.caseSensitive &
            $st.options.wholeWord & "|" & $firstLine & "|" & $rows & "|" &
            $f.open & "|" & $f.current.a & "|" &
            $d.state.selection.mainRange.rangeFrom
  if f.windowCache.key == key:
    return f.windowCache.marks
  let doc = d.state.doc
  let (first, starts) = lineStartsIn(doc, firstLine - HighlightMarginLines,
                                     lastLine + HighlightMarginLines)
  if starts.len == 0: return @[]
  let winA = starts[0]
  let winB = if starts.len > lastLine + HighlightMarginLines - first + 1:
               starts[^1] else: doc.len
  var spans: seq[MatchSpan]
  if f.open and not f.capped:
    for m in f.matches:
      if m.b > winA and m.a < winB: spans.add m
  else:
    for m in matchesOf(doc[winA ..< winB], st.pattern, st.options):
      spans.add MatchSpan(a: m.a + winA, b: m.b + winA)
  var current = f.current
  if not f.open:
    let m = d.state.selection.mainRange
    current = MatchSpan(a: m.rangeFrom, b: m.rangeFrom + matchLengthAt(doc,
                          st.pattern, st.options, m.rangeFrom))
  result = @[]
  var li = 0
  for s in spans:
    # The line `s.a` is on: `starts` is ascending, and so are the spans.
    while li + 1 < starts.len and starts[li + 1] <= s.a: inc li
    var line = first + li
    var at = s.a
    var lj = li
    while at < s.b:
      let lineStart = starts[lj]
      let lineEnd = if lj + 1 < starts.len: starts[lj + 1] - 1 else: doc.len
      let stop = min(s.b, lineEnd)
      if line >= firstLine and line <= lastLine:
        let text = doc[lineStart ..< lineEnd]
        let fromCol = columnAt(text, at - lineStart)
        let toCol = if s.b > lineEnd: columnAt(text, text.len) + 1
                    else: columnAt(text, stop - lineStart)
        if toCol > fromCol:
          result.add FindMark(line: line, fromColumn: fromCol + 1,
                              toColumn: toCol + 1,
                              current: s.a == current.a and current.a >= 0)
      if s.b <= lineEnd or lj + 1 >= starts.len: break
      inc lj
      inc line
      at = starts[lj]
  f.windowCache = (key, result)
