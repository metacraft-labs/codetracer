## view_vocabulary/behaviour.nim — PLAT-3. The keyboard contract of each entry,
## and the state machine that answers it.
##
## ## WHY THE CONTRACT IS DATA AND THE MACHINE IS ONE FUNCTION
##
## PLAT-3's integration test asks that one view "renders and behaves
## equivalently on the terminal and the web, asserted on keyboard contract and
## state transitions, not appearance". Two things have to exist for that to be
## assertable:
##
##   - `keyContract(kind)` — what each entry PROMISES, as data a test can read
##     and a front-end binding can advertise (a terminal footer, a DOM
##     `aria-keyshortcuts`, a GPUI hint bar all want the same list).
##   - `applyKey(node, key)` — what each entry DOES, in one place, so the
##     terminal and the web cannot drift into two definitions of what Down
##     means on a `List`.
##
## The bindings do NOT re-implement this. Each translates its medium's key
## representation into a `KeyPress` and hands it here; what differs per medium
## is the spelling of the key and nothing else. That is the claim the
## cross-medium suite checks, and it checks it by reading the state back out of
## each medium's own rendered tree rather than out of this module.
##
## ## KEYS THE VOCABULARY DELIBERATELY DOES NOT CLAIM
##
## Three, each because claiming it would be claiming something the medium
## already owns:
##
##   TAB / SHIFT+TAB — focus movement BETWEEN views. isonim-tui's
##       `focus/manager.nim` consumes Tab before any widget's own handler runs,
##       and the DOM's tab order is the browser's. An entry that answered Tab
##       would be fighting its host on every medium.
##
##   PAGE UP / PAGE DOWN — a "page" is a viewport height, which is a LAYOUT
##       fact and a medium-dependent one. isonim-tui's `ListView` and
##       `DataTable` both bind it, and both compute it from `viewportHeight`,
##       a field this vocabulary does not have and will not grow. The
##       terminal mapping records this as the one place where the widget
##       answers MORE keys than the contract, which is a superset and
##       therefore not a conflict.
##
##   MOUSE — every interactive entry accepts `acPointer` and none REQUIRES it.
##       See `vocabulary.Activation` and `portability.checkPortable`.
##
## ## PURITY
##
## `keyContract` is a `func`. `applyKey` is a `proc` because it mutates the
## node it is given — a `ViewNode` is a `ref` and the tree is what the binding
## re-renders from. It reads no clock, no environment and no global, and
## nothing in this module allocates outside its argument.

import std/[unicode, sequtils]

import ./vocabulary

type
  Key* = enum
    ## The medium-independent key set. TERMINAL-FIRST: every member here is a
    ## key a terminal can deliver without a modifier and without a pointer,
    ## which is the smaller set. `kChar` carries a printable rune.
    ##
    ## `kTab` and `kBackTab` are members so a binding can RECOGNISE them and
    ## decline them; no entry's contract contains either. See the header.
    kNone
    kChar
    kEnter
    kSpace
    kEscape
    kTab
    kBackTab
    kUp
    kDown
    kLeft
    kRight
    kHome
    kEnd
    kBackspace
    kDelete

  KeyPress* = object
    key*: Key
    ch*: Rune   ## meaningful only when `key == kChar`

  Transition* = enum
    ## What a key DID, named without reference to any medium. A binding may
    ## report these; a test asserts on them. The names are the vocabulary's
    ## own — `trHighlightNext` rather than "moved down", because on a
    ## horizontal `Tabs` the same idea is Right.
    trNone
    trActivate
    trCheck
    trUncheck
    trOn
    trOff
    trInsert
    trDeleteBack
    trDeleteForward
    trCaretLeft
    trCaretRight
    trCaretHome
    trCaretEnd
    trSubmit
    trOpen
    trCommit
    trDismiss
    trHighlightNext
    trHighlightPrev
    trHighlightFirst
    trHighlightLast
    trExpand
    trCollapse
    trCursorNext
    trCursorPrev
    trCursorFirst
    trCursorLast
    trColumnNext
    trColumnPrev

  KeyBinding* = object
    key*: Key
    transition*: Transition
    description*: string

  KeyOutcome* = object
    handled*: bool
      ## whether the entry consumed the key. An unhandled key belongs to the
      ## host — the focus manager, the layout, the command interpreter — and a
      ## binding must pass it on rather than swallow it.
    transition*: Transition

func outcome(t: Transition): KeyOutcome =
  KeyOutcome(handled: t != trNone, transition: t)

func ignored*(): KeyOutcome = KeyOutcome(handled: false, transition: trNone)

# ---------------------------------------------------------------------------
# The contract, as data
# ---------------------------------------------------------------------------

func b(key: Key; t: Transition; description: string): KeyBinding =
  KeyBinding(key: key, transition: t, description: description)

func keyContract*(k: ViewKind): seq[KeyBinding] =
  ## Every key the entry answers, in the order a hint bar would list them.
  ##
  ## EXHAUSTIVE OVER `ViewKind` ON PURPOSE: there is no `else`, so a
  ## seventeenth entry — or an entry someone adds to `PresentationKind` for a
  ## value-side reason — cannot arrive without this function refusing to
  ## compile. That is the closed-set property, held by the compiler rather than
  ## by a comment.
  case k
  of pkText, pkImage, pkMarkdown, pkProgressIndicator:
    @[]
  of pkButton:
    @[b(kEnter, trActivate, "invoke"), b(kSpace, trActivate, "invoke")]
  of pkCheckbox:
    @[b(kSpace, trCheck, "toggle"), b(kEnter, trCheck, "toggle")]
  of pkToggle:
    @[b(kSpace, trOn, "switch"), b(kEnter, trOn, "switch")]
  of pkInput:
    @[b(kChar, trInsert, "type"),
      b(kBackspace, trDeleteBack, "delete before caret"),
      b(kDelete, trDeleteForward, "delete at caret"),
      b(kLeft, trCaretLeft, "caret left"),
      b(kRight, trCaretRight, "caret right"),
      b(kHome, trCaretHome, "caret to start"),
      b(kEnd, trCaretEnd, "caret to end"),
      b(kEnter, trSubmit, "submit")]
  of pkSelect:
    @[b(kEnter, trOpen, "open, then commit"),
      b(kSpace, trOpen, "open"),
      b(kDown, trHighlightNext, "next choice"),
      b(kUp, trHighlightPrev, "previous choice"),
      b(kEscape, trDismiss, "close without choosing")]
  of pkList:
    @[b(kDown, trHighlightNext, "next item"),
      b(kUp, trHighlightPrev, "previous item"),
      b(kHome, trHighlightFirst, "first item"),
      b(kEnd, trHighlightLast, "last item"),
      b(kEnter, trActivate, "activate")]
  of pkTree:
    @[b(kDown, trCursorNext, "next row"),
      b(kUp, trCursorPrev, "previous row"),
      b(kRight, trExpand, "expand"),
      b(kLeft, trCollapse, "collapse"),
      b(kHome, trCursorFirst, "first row"),
      b(kEnd, trCursorLast, "last row"),
      b(kEnter, trActivate, "activate")]
  of pkTable:
    @[b(kDown, trCursorNext, "next row"),
      b(kUp, trCursorPrev, "previous row"),
      b(kRight, trColumnNext, "next column"),
      b(kLeft, trColumnPrev, "previous column"),
      b(kHome, trCursorFirst, "first row"),
      b(kEnd, trCursorLast, "last row"),
      b(kEnter, trActivate, "activate cell")]
  of pkTabs:
    @[b(kRight, trHighlightNext, "next tab"),
      b(kLeft, trHighlightPrev, "previous tab"),
      b(kHome, trHighlightFirst, "first tab"),
      b(kEnd, trHighlightLast, "last tab")]
  of pkCollapsible:
    @[b(kSpace, trExpand, "expand or collapse"),
      b(kEnter, trExpand, "expand or collapse")]
  of pkModal:
    @[b(kEscape, trDismiss, "dismiss")]
  of pkMenu:
    @[b(kDown, trHighlightNext, "next command"),
      b(kUp, trHighlightPrev, "previous command"),
      b(kEnter, trActivate, "run"),
      b(kEscape, trDismiss, "dismiss")]

func answersKey*(k: ViewKind; key: Key): bool =
  keyContract(k).anyIt(it.key == key)

# ---------------------------------------------------------------------------
# Option motion
#
# Shared by List, Menu and Select's open state, and by Tabs. Disabled options
# are SKIPPED rather than landed on and refused: a reader holding Down through
# a list of mostly-disabled commands would otherwise stop at the first one.
# ---------------------------------------------------------------------------

func nextEnabled(options: seq[ViewOption]; start, step: int): int =
  ## The nearest enabled index from `start` moving by `step`, or -1.
  ## Does NOT wrap: wrapping is a preference and this vocabulary does not
  ## carry preferences. `isonim_tui.ListView` does not wrap either.
  if options.len == 0: return -1
  var i = start
  while i >= 0 and i < options.len:
    if not options[i].disabled: return i
    i += step
  -1

func firstEnabled(options: seq[ViewOption]): int =
  nextEnabled(options, 0, 1)

func lastEnabled(options: seq[ViewOption]): int =
  nextEnabled(options, options.len - 1, -1)

proc moveHighlight(v: ViewNode; step: int): Transition =
  let target = nextEnabled(v.options, v.highlight + step, step)
  if target < 0: return trNone
  v.highlight = target
  if step > 0: trHighlightNext else: trHighlightPrev

proc moveSelected(v: ViewNode; step: int): Transition =
  ## `Tabs` moves its COMMITTED selection directly — activating a tab is the
  ## selection, which is the behavioural difference from `Select`.
  let target = nextEnabled(v.options, v.selected + step, step)
  if target < 0: return trNone
  v.selected = target
  if step > 0: trHighlightNext else: trHighlightPrev

# ---------------------------------------------------------------------------
# Input editing
# ---------------------------------------------------------------------------

func runeSplit(s: string; at: int): tuple[before, after: string] =
  ## Split `s` at rune index `at`. RUNES, not bytes: `Input.cursor` is a rune
  ## index because a byte index is a property of one encoding and a cell index
  ## is a property of one medium.
  var i = 0
  var bytes = 0
  for r in runes(s):
    if i >= at: break
    bytes += ($r).len
    inc i
  (s[0 ..< bytes], s[bytes .. ^1])

proc applyInputKey(v: ViewNode; kp: KeyPress): KeyOutcome =
  let n = v.text.runeLen
  case kp.key
  of kChar:
    let (before, after) = runeSplit(v.text, v.cursor)
    v.text = before & $kp.ch & after
    v.cursor = v.cursor + 1
    outcome(trInsert)
  of kBackspace:
    if v.cursor <= 0: return ignored()
    let (before, after) = runeSplit(v.text, v.cursor)
    var kept = before
    kept.setLen(kept.len - ($before.toRunes[^1]).len)
    v.text = kept & after
    v.cursor = v.cursor - 1
    outcome(trDeleteBack)
  of kDelete:
    if v.cursor >= n: return ignored()
    let (before, after) = runeSplit(v.text, v.cursor + 1)
    v.text = before[0 ..< before.len - ($before.toRunes[^1]).len] & after
    outcome(trDeleteForward)
  of kLeft:
    if v.cursor <= 0: return ignored()
    v.cursor = v.cursor - 1
    outcome(trCaretLeft)
  of kRight:
    if v.cursor >= n: return ignored()
    v.cursor = v.cursor + 1
    outcome(trCaretRight)
  of kHome:
    if v.cursor == 0: return ignored()
    v.cursor = 0
    outcome(trCaretHome)
  of kEnd:
    if v.cursor == n: return ignored()
    v.cursor = n
    outcome(trCaretEnd)
  of kEnter:
    outcome(trSubmit)
  else:
    ignored()

# ---------------------------------------------------------------------------
# Tree motion
#
# The cursor indexes `visibleRows(root)`, which is why collapsing has to move
# it: a cursor left pointing into rows that are no longer visible names a row
# no medium can draw.
# ---------------------------------------------------------------------------

func rowAt(root: ViewNode; index: int): ViewNode =
  let rows = visibleRows(root)
  if index < 0 or index >= rows.len: nil else: rows[index]

func parentOf(root, target: ViewNode): ViewNode =
  for n in walk(root):
    for c in n.children:
      if c == target: return n
  nil

func indexOfRow(root, target: ViewNode): int =
  let rows = visibleRows(root)
  for i, r in rows:
    if r == target: return i
  -1

proc applyTreeKey(v: ViewNode; kp: KeyPress): KeyOutcome =
  let rows = visibleRows(v)
  if rows.len == 0: return ignored()
  if v.cursor < 0 or v.cursor >= rows.len:
    v.cursor = 0
  let current = rows[v.cursor]
  case kp.key
  of kDown:
    if v.cursor + 1 >= rows.len: return ignored()
    v.cursor = v.cursor + 1
    outcome(trCursorNext)
  of kUp:
    if v.cursor <= 0: return ignored()
    v.cursor = v.cursor - 1
    outcome(trCursorPrev)
  of kRight:
    if current.children.len == 0: return ignored()
    if not current.expanded:
      current.expanded = true
      outcome(trExpand)
    else:
      # Already open: Right steps INTO the node, which is the motion every
      # tree in every medium performs and the reason Right is not simply
      # "expand".
      v.cursor = v.cursor + 1
      outcome(trCursorNext)
  of kLeft:
    if current.expanded and current.children.len > 0:
      current.expanded = false
      outcome(trCollapse)
    else:
      let p = parentOf(v, current)
      if p.isNil: return ignored()
      let idx = indexOfRow(v, p)
      if idx < 0: return ignored()
      v.cursor = idx
      outcome(trCursorPrev)
  of kHome:
    if v.cursor == 0: return ignored()
    v.cursor = 0
    outcome(trCursorFirst)
  of kEnd:
    if v.cursor == rows.len - 1: return ignored()
    v.cursor = rows.len - 1
    outcome(trCursorLast)
  of kEnter, kSpace:
    outcome(trActivate)
  else:
    ignored()

proc reseatCursorAfterCollapse*(v: ViewNode) =
  ## Clamp a `Tree` cursor that a collapse elsewhere has left past the end.
  ## Exposed because a caller that collapses a node PROGRAMMATICALLY — a
  ## "collapse all" command, a model reload — has the same problem the Left key
  ## has, and one implementation of it is the point of this module.
  let rows = visibleRows(v)
  if rows.len == 0:
    v.cursor = -1
  elif v.cursor >= rows.len:
    v.cursor = rows.len - 1
  elif v.cursor < 0:
    v.cursor = 0

# ---------------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------------

proc applyKey*(v: ViewNode; kp: KeyPress): KeyOutcome =
  ## Apply one key to one node. Returns what happened.
  ##
  ## A node that is `disabled`, non-interactive, or a native escape answers
  ## nothing — and answering nothing is `handled = false`, so the host gets the
  ## key back. A control that swallowed keys it did nothing with is how a
  ## terminal front-end stops responding to its own command line.
  if v.isNil: return ignored()
  if v.nativeMedium.len > 0: return ignored()
  if v.kind notin InteractiveKinds: return ignored()
  if v.disabled: return ignored()

  case v.kind
  of pkButton:
    if kp.key in {kEnter, kSpace}: outcome(trActivate) else: ignored()

  of pkCheckbox:
    if kp.key in {kEnter, kSpace}:
      v.checked = not v.checked
      outcome(if v.checked: trCheck else: trUncheck)
    else: ignored()

  of pkToggle:
    if kp.key in {kEnter, kSpace}:
      v.checked = not v.checked
      outcome(if v.checked: trOn else: trOff)
    else: ignored()

  of pkInput:
    applyInputKey(v, kp)

  of pkSelect:
    if not v.open:
      if kp.key in {kEnter, kSpace}:
        v.open = true
        if v.highlight < 0: v.highlight = firstEnabled(v.options)
        outcome(trOpen)
      else: ignored()
    else:
      case kp.key
      of kDown: outcome(moveHighlight(v, 1))
      of kUp: outcome(moveHighlight(v, -1))
      of kEnter:
        v.selected = v.highlight
        v.open = false
        outcome(trCommit)
      of kEscape:
        # THE HIGHLIGHT IS RETURNED TO THE COMMITTED CHOICE. A reader who
        # arrowed past three options and pressed Escape has not chosen any of
        # them, and a `Select` that reopened on the last one they passed over
        # would be remembering a decision they declined to make.
        v.open = false
        v.highlight = v.selected
        outcome(trDismiss)
      else: ignored()

  of pkList:
    case kp.key
    of kDown: outcome(moveHighlight(v, 1))
    of kUp: outcome(moveHighlight(v, -1))
    of kHome:
      let f = firstEnabled(v.options)
      if f < 0 or f == v.highlight: return ignored()
      v.highlight = f
      outcome(trHighlightFirst)
    of kEnd:
      let l = lastEnabled(v.options)
      if l < 0 or l == v.highlight: return ignored()
      v.highlight = l
      outcome(trHighlightLast)
    of kEnter:
      if v.highlight < 0: return ignored()
      outcome(trActivate)
    else: ignored()

  of pkTree:
    applyTreeKey(v, kp)

  of pkTable:
    if v.rows.len == 0: return ignored()
    case kp.key
    of kDown:
      if v.cursor + 1 >= v.rows.len: return ignored()
      v.cursor = v.cursor + 1
      outcome(trCursorNext)
    of kUp:
      if v.cursor <= 0: return ignored()
      v.cursor = v.cursor - 1
      outcome(trCursorPrev)
    of kRight:
      if v.column + 1 >= v.columns.len: return ignored()
      v.column = v.column + 1
      outcome(trColumnNext)
    of kLeft:
      if v.column <= 0: return ignored()
      v.column = v.column - 1
      outcome(trColumnPrev)
    of kHome:
      if v.cursor == 0: return ignored()
      v.cursor = 0
      outcome(trCursorFirst)
    of kEnd:
      if v.cursor == v.rows.len - 1: return ignored()
      v.cursor = v.rows.len - 1
      outcome(trCursorLast)
    of kEnter: outcome(trActivate)
    else: ignored()

  of pkTabs:
    case kp.key
    of kRight: outcome(moveSelected(v, 1))
    of kLeft: outcome(moveSelected(v, -1))
    of kHome:
      let f = firstEnabled(v.options)
      if f < 0 or f == v.selected: return ignored()
      v.selected = f
      outcome(trHighlightFirst)
    of kEnd:
      let l = lastEnabled(v.options)
      if l < 0 or l == v.selected: return ignored()
      v.selected = l
      outcome(trHighlightLast)
    else: ignored()

  of pkCollapsible:
    if kp.key in {kEnter, kSpace}:
      v.expanded = not v.expanded
      outcome(if v.expanded: trExpand else: trCollapse)
    else: ignored()

  of pkModal:
    if not v.open: return ignored()
    if kp.key == kEscape:
      v.open = false
      outcome(trDismiss)
    else: ignored()

  of pkMenu:
    if not v.open: return ignored()
    case kp.key
    of kDown: outcome(moveHighlight(v, 1))
    of kUp: outcome(moveHighlight(v, -1))
    of kEnter:
      if v.highlight < 0: return ignored()
      v.open = false
      outcome(trActivate)
    of kEscape:
      v.open = false
      outcome(trDismiss)
    else: ignored()

  # The four readings. Unreachable — `InteractiveKinds` excluded them above —
  # and written out rather than left to an `else` so that adding an entry to
  # `InteractiveKinds` without giving it behaviour is a compile error.
  of pkText, pkImage, pkMarkdown, pkProgressIndicator:
    ignored()

proc applyKeys*(v: ViewNode; keys: openArray[KeyPress]): seq[KeyOutcome] =
  for kp in keys:
    result.add applyKey(v, kp)

# ---------------------------------------------------------------------------
# Convenience constructors for tests and bindings
# ---------------------------------------------------------------------------

func press*(k: Key): KeyPress = KeyPress(key: k)

func typeChar*(c: char): KeyPress =
  KeyPress(key: kChar, ch: Rune(ord(c)))

func typeRune*(r: Rune): KeyPress = KeyPress(key: kChar, ch: r)
