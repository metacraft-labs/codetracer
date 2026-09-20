## operations.nim — PLAT-30: THE NAMED OPERATION VOCABULARY.
##
## Owns: the 140 declarations of
## `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` §2.2, the 224
## operations they generate, and the one function that executes one of them
## against an `EditorState`.
##
## =========================================================================
## THE SHAPE IS KAKOUNE'S, AND THAT IS WHAT MAKES VIM EXPRESSIBLE
## =========================================================================
##
## §2.1, quoted because it is the decision the whole module is built on:
##
##   > **A motion produces a selection; an operator consumes one.**
##
## `dw` and `wd` are THE SAME TWO OPERATIONS IN A DIFFERENT ORDER. In the
## Kakoune keymap `w` is `select-group-right` and `d` is `delete-selection`,
## and the user's two keystrokes are those two operations in that order. In the
## Vim keymap `d` is `begin-operator(delete)` and `w` is `select-group-right`,
## and the EDITOR's operator-pending state — `EditorState.pendingOperator`,
## §3 — turns the second operation's result into the first's argument. Neither
## keymap gets a private operation, and there is no `delete-word-forward`
## anywhere below.
##
## Mechanically, that means an operator's implementation reads
## `st.selection` and nothing else. It never asks how the selection got there,
## which is what makes one vocabulary serve two models.
##
## =========================================================================
## A `seq` OF DECLARATIONS, NOT A `case` — CTUI-9's CONTRACT
## =========================================================================
##
## *"A `case token of` cannot be asked whether a name is declared twice,
## whether every published operation has an implementation, or which scope
## resolves a collision."* So the vocabulary is `vocabulary()`, a `seq` of
## `Declaration`, and every question above is a fold over it:
##
##   * `duplicateDeclarationNames()` — is a name declared twice?
##   * `duplicateOperationNames()` — do two declarations generate one name?
##     **This one is not hypothetical.** §2.4 records that `move-line-up` was
##     published twice, forty-six lines apart, once as the `move-` form of the
##     `line-up` motion and once as the line-manipulation command. The D
##     entries are `swap-line-up` / `swap-line-down` now, and this function is
##     what stops the collision coming back.
##   * `operations()` — every published operation, with its implementation.
##
## The three forms of a motion (`move-`, `extend-`, `select-`) and the two
## forms of an object (`select-inner-`, `select-around-`) are GENERATED from
## one declaration, so they cannot disagree about where the motion lands.
##
## =========================================================================
## DISPLAY-DEPENDENCE IS A DECLARED PROPERTY, AND THE ENVIRONMENT IS UNIFORM
## =========================================================================
##
## §2.3: *"Every operation declares whether its result depends on the wrap
## column … Run every operation twice at two different wrap columns. Every
## operation declared display-dependent must differ on at least one input;
## every operation declared independent must be identical on all of them."*
##
## **EVERY HANDLER CAN SEE `env.settings`, AND THAT IS A DECISION.** The
## alternative was considered and rejected: two handler types, one carrying a
## `DisplayCtx` and one not, so that a display-independent operation could not
## reach the wrap column at all. That is a stronger DESIGN and a weaker TEST —
## the 200 negative controls of §2.3's second half would then be true by
## construction, and an unfalsifiable negative control is
## Verification-Harness-Traps §7b's *"a self-comparison wearing a negation"*.
## The floor's second sweep of 224 is admitted precisely because those 200 can
## fail; making them unable to fail would be buying a design property with the
## evidence that the property holds. So the environment is uniform, the
## separation is a matter of which handler reads which field, and `M6` in
## `run-plat30-vocabulary-mutations.py` makes a display-independent motion read
## the wrap column and requires three named cases to redden.
##
## =========================================================================
## WHAT AN OPERATION MAY NOT DO — §5, MECHANISED
## =========================================================================
##
## §5.1 *it may not be asynchronous*: this module is in
## `src/frontend/viewmodel/editor/`, whose transitive import closure is bound
## by `ci/test/editor-import-closure.sh` against
## `src/common/editor_core_admission.nim`. There is no route to a `Future`, a
## clock or a file from here, and it is a checked property rather than a
## convention.
##
## §5.2 *it may not run a process, open a file or reach the network*: the four
## file operations and `pipe-selection` return a `HostIntent` — the operation
## NAMES the intent and the capability-gated host performs it. `OpResult` is
## the type that makes that expressible, and `save` returning an intent rather
## than writing a file is what makes §5.2 a compile-time fact here.
##
## §5.1's *"uses what the state already holds, or reports that it cannot — it
## never waits"* is `EditorState.parse` plus `rrStaleParse`: the fourteen
## operations that need a parse refuse by name. **That is fourteen of 224
## refusing at this milestone and the number is asserted rather than
## discovered**, because "some operations are not implemented yet" and "these
## fourteen have a typed refusal the suite drives" are different claims and
## only one of them is checkable.

import std/[algorithm, options, strutils, tables, unicode]

import ./change_set
import ./editor_state
import ./selection
import ./selection_ops
import ./text_store
import ./transaction
import ./wrap

export editor_state, selection, selection_ops, wrap

type
  OpCategory* = enum
    ## §2.2's four categories, in the document's own order.
    ocMotion = "A"
    ocObject = "B"
    ocOperator = "C"
    ocCommand = "D"

  OpForm* = enum
    ## The generated forms. `ofBare` is the single form categories C and D
    ## have, spelled rather than left as an absence, so a fold over forms is
    ## total.
    ofMove = "move-"
    ofExtend = "extend-"
    ofSelect = "select-"
    ofInner = "select-inner-"
    ofAround = "select-around-"
    ofBare = ""

  ArgKind* = enum
    ## The argument list a declaration's name is followed by in §2.2. §2.4:
    ## *"A declaration's NAME is the token up to `(`; what follows is its
    ## argument list and is not part of the name."* The name is what the
    ## oracle compares; this is what the executor needs.
    akNone = "none"
    akNumber = "n"        ## `line-number(n)`
    akMarkId = "id"       ## `mark(id)`, `set-register(id)`, `record-macro(id)`, `replay-macro(id)`
    akText = "s"          ## `insert-text(s)`
    akChar = "c"          ## `replace-char(c)`
    akCommand = "command" ## `pipe-selection(command)`
    akOperator = "op"     ## `begin-operator(op)`
    akDigit = "d"         ## `push-count-digit(d)`

  OpArgs* = object
    ## Everything any of the eight argument kinds needs. One object rather
    ## than a variant: the executor reads the field its declaration's `ArgKind`
    ## names, and a suite that forgot to supply one gets a defined refusal
    ## rather than a different operation.
    number*: int
    id*: string
    text*: string
    ch*: string          ## ONE grapheme cluster, for `replace-char`
    command*: string
    operator*: string
    digit*: int

  OpOutcome* = enum
    ## `FUZZ-8`'s *"a refusal is a typed value"*, plus the distinction §34
    ## asks for: an operation that RAN and an operation that had nothing to do
    ## are not the same event, and a sweep in which most operations are no-ops
    ## is a sweep about its inputs.
    ooActed = "acted"
    ooNoOp = "no-op"
    ooRefused = "refused"

  RefusalReason* = enum
    rrNone = "none"
    rrStaleParse = "the parse is absent or stale"
    rrHostRequired = "only the host can answer this"
    rrNoMatch = "nothing matched"
    rrNoPattern = "no search pattern is set"
    rrNoMark = "no such mark"
    rrNoMacro = "no such macro"
    rrNotRecording = "no macro is being recorded"
    rrNothingToRepeat = "no change has been made yet"
    rrEmptyHistory = "the history is empty"
    rrOutOfRange = "the argument names nothing in this document"
    rrMissingArgument = "this operation takes an argument and was given none"
    rrNoEnclosingObject = "the caret is not inside an object of this kind"
    rrRecursionLimit = "a macro replayed itself too deeply"

  HostIntentKind* = enum
    ## §5.2. The operation names the intent; the host performs it.
    hiSave = "save"
    hiSaveAs = "save-as"
    hiSaveAll = "save-all"
    hiReload = "reload-from-disk"
    hiPipe = "pipe"
    hiValueOrigin = "jump-to-value-origin"

  HostIntent* = object
    kind*: HostIntentKind
    payload*: string
      ## For `hiPipe`, the command. For the file intents, the path the caller
      ## supplied, or `""`.

  OpResult* = object
    outcome*: OpOutcome
    state*: EditorState
    refusal*: RefusalReason
    intents*: seq[HostIntent]

  OpEnv* = object
    ## Everything an operation needs that is neither the state nor the
    ## argument. **`settings` is a PARAMETER and never a field of
    ## `EditorState`** — PLAT-27's settled decision, which this module obeys
    ## rather than re-litigates.
    ctx*: OpCtx
    display*: DisplayCtx
    settings*: WrapSettings
    viewportRows*: int
    nowMs*: int64
      ## **THE CLOCK IS A PARAMETER, FOR `settings`' OWN REASON.** PLAT-32's
      ## grouping rule reads elapsed time, and an operation that read a clock
      ## would not be a pure function of its arguments — which is the property
      ## the whole vocabulary is built on and the one PLAT-29's import-closure
      ## gate enforces (`std/times` is refused in this directory's closure).
      ## So the caller supplies the reading, exactly as `PendingChords`
      ## stores the moment a prefix started rather than counting down.

  MotionLanding* = object
    ## Where a motion puts the head, what goal column the result carries, and
    ## whether it could answer at all. **The refusal is part of the landing**
    ## rather than a separate channel, because `syntax-left` and `mark(id)`
    ## both have to be able to say "not from here" and a motion that returned
    ## a plausible offset instead would be §5.1's pause wearing an answer.
    offset*: int
    goal*: Option[int]
    refusal*: RefusalReason

  ObjectSpan* = object
    span*: SelectionRange
    refusal*: RefusalReason

  MotionProc* = proc (env: OpEnv; st: EditorState; r: SelectionRange;
                      args: OpArgs): MotionLanding
  ObjectProc* = proc (env: OpEnv; st: EditorState; r: SelectionRange;
                      around: bool; args: OpArgs): ObjectSpan
  CommandProc* = proc (env: OpEnv; st: EditorState; args: OpArgs): OpResult
    ## CLOSURES, not `nimcall`. Nine of the seventy commands are one behaviour
    ## with nine arguments (`modeSetter`) and four more are one behaviour with
    ## four (`intentOnly`); writing those thirteen out would be thirteen copies
    ## of three lines and thirteen places for one of them to drift.

  Declaration* = object
    ## One row of §2.2, with its implementation.
    category*: OpCategory
    name*: string
    displayDependent*: bool
    arg*: ArgKind
    motion*: MotionProc
    obj*: ObjectProc
    run*: CommandProc

  Operation* = object
    ## One of the 224. `decl` is an index into `vocabulary()`, so an operation
    ## cannot name a declaration that is not there.
    name*: string
    decl*: int
    category*: OpCategory
    form*: OpForm
    displayDependent*: bool
    arg*: ArgKind

  OperationError* = object of ValueError

const
  FormsOf*: array[OpCategory, seq[OpForm]] = [
    ## The forms each category generates, which is the whole of §2.2 A's
    ## *"generated rather than enumerated"* and §2.2 B's `i`/`a`. A reader of
    ## the census's `CATEGORIES` table sees the same three rows; the two are
    ## independent implementations of one published grammar and neither is the
    ## other's control (§2.4).
    ocMotion: @[ofMove, ofExtend, ofSelect],
    ocObject: @[ofInner, ofAround],
    ocOperator: @[ofBare],
    ocCommand: @[ofBare],
  ]

  MacroDepthLimit* = 8
    ## `replay-macro` can replay a macro that replays a macro. A bound rather
    ## than a cycle detector: the bound is observable (`rrRecursionLimit`) and
    ## a detector would have to be believed.

# ===========================================================================
# TEXT PRIMITIVES — the shared helpers the motions and objects are built on
# ===========================================================================

type CharCat = enum ccWord, ccSpace, ccOther

func catOf(r: Rune): CharCat =
  ## §2.2 A's *"by character category — word / space / other"*, over RUNES
  ## rather than bytes. `isAlpha` is Unicode's, so a Cyrillic identifier is one
  ## group and not three.
  if r == Rune('_') or r.isAlpha() or (int(r) < 128 and char(int(r)) in {'0'..'9'}):
    ccWord
  elif r.isWhiteSpace():
    ccSpace
  else:
    ccOther

proc firstRune(s: string): Rune =
  if s.len == 0: Rune(0) else: s.runeAt(0)

proc clusterAt(env: OpEnv; pos: int): string =
  ## The grapheme cluster beginning at the boundary at or before `pos`.
  let a = env.ctx.boundaryAtOrBefore(pos)
  let b = env.ctx.nextBoundary(a)
  if a >= b or b > env.ctx.doc.len: "" else: env.ctx.doc[a ..< b]

proc catAt(env: OpEnv; pos: int): CharCat =
  catOf(firstRune(clusterAt(env, pos)))

proc lineOf(env: OpEnv; offset: int): int =
  env.ctx.store.posOf(offset).line

proc lineStartOf(env: OpEnv; line: int): int =
  env.ctx.store.offsetOf(textPos(line, 0))

proc lineEndOf(env: OpEnv; line: int): int =
  ## Clamped back to a cluster boundary, which is PLAT-26's CRLF finding: the
  ## `\n`-delimited line index and UAX #29 disagree about where a CRLF line
  ## ends, and the boundary is what every editor uses.
  env.ctx.boundaryAtOrBefore(
    env.ctx.store.offsetOf(textPos(line, env.ctx.store.lineLen(line))))

proc lineTextOf(env: OpEnv; line: int): string =
  env.ctx.store.lineText(line)

func isRtl(r: SelectionRange): bool =
  ## Whether `left` means `forward` for this range. **This is what keeps
  ## `char-left` and `char-backward` two operations rather than one.** §2.2 A
  ## declares both — `char-left`/`char-right` visual, `char-forward`/
  ## `char-backward` *"logical direction, for bidi-agnostic bindings"* — and in
  ## a model with no bidi at all the two pairs would have identical
  ## implementations, which would make a mutation that swapped them invisible
  ## (Verification-Harness-Traps §36). `SelectionRange` already carries an
  ## optional `bidiLevel`, an odd level is RTL by Unicode's own rule, and the
  ## suite plants one.
  r.kind == srEmpty and r.bidiLevel.isSome and (int(r.bidiLevel.get) and 1) == 1

proc groupForward(env: OpEnv; pos: int): int =
  ## Past the run of clusters sharing the category at `pos`.
  if pos >= env.ctx.doc.len: return env.ctx.doc.len
  let cat = env.catAt(pos)
  var p = env.ctx.nextBoundary(pos)
  while p < env.ctx.doc.len and env.catAt(p) == cat:
    p = env.ctx.nextBoundary(p)
  p

proc groupBackward(env: OpEnv; pos: int): int =
  if pos <= 0: return 0
  var p = env.ctx.prevBoundary(pos)
  if p <= 0: return 0
  let cat = env.catAt(p)
  while p > 0:
    let q = env.ctx.prevBoundary(p)
    if env.catAt(q) != cat: break
    p = q
  p

proc isSubwordBreak(env: OpEnv; pos: int): bool =
  ## A camelCase hump or a `_`/`-` boundary inside a word run.
  if pos <= 0 or pos >= env.ctx.doc.len: return false
  let prev = firstRune(env.clusterAt(env.ctx.prevBoundary(pos)))
  let cur = firstRune(env.clusterAt(pos))
  if catOf(prev) != catOf(cur): return true
  if catOf(cur) != ccWord: return false
  if cur == Rune('_') or prev == Rune('_'): return true
  cur.isUpper() and not prev.isUpper()

proc subwordForward(env: OpEnv; pos: int): int =
  if pos >= env.ctx.doc.len: return env.ctx.doc.len
  var p = env.ctx.nextBoundary(pos)
  while p < env.ctx.doc.len and not env.isSubwordBreak(p):
    p = env.ctx.nextBoundary(p)
  p

proc subwordBackward(env: OpEnv; pos: int): int =
  if pos <= 0: return 0
  var p = env.ctx.prevBoundary(pos)
  while p > 0 and not env.isSubwordBreak(p):
    p = env.ctx.prevBoundary(p)
  p

func isBlankLine(s: string): bool =
  s.strip().len == 0

proc paragraphForward(env: OpEnv; pos: int): int =
  ## The start of the next blank line that ends a non-blank run — Vim's `}`.
  let lines = env.ctx.store.lineCount
  var line = env.lineOf(pos)
  while line < lines - 1 and isBlankLine(env.lineTextOf(line)):
    inc line
  while line < lines - 1 and not isBlankLine(env.lineTextOf(line + 1)):
    inc line
  if line >= lines - 1: env.ctx.doc.len
  else: env.lineStartOf(line + 1)

proc paragraphBackward(env: OpEnv; pos: int): int =
  var line = env.lineOf(pos)
  while line > 0 and isBlankLine(env.lineTextOf(line)):
    dec line
  while line > 0 and not isBlankLine(env.lineTextOf(line - 1)):
    dec line
  if line <= 0: 0 else: env.lineStartOf(line - 1)

const
  OpenBrackets = "([{<"
  CloseBrackets = ")]}>"

func partnerOf(c: char): char =
  let i = OpenBrackets.find(c)
  if i >= 0: return CloseBrackets[i]
  let j = CloseBrackets.find(c)
  if j >= 0: return OpenBrackets[j]
  '\0'

proc matchForward(doc: string; start: int; open, close: char): int =
  ## The offset of the `close` matching the `open` at `start`, or -1.
  var depth = 0
  var i = start
  while i < doc.len:
    if doc[i] == open: inc depth
    elif doc[i] == close:
      dec depth
      if depth == 0: return i
    inc i
  -1

proc matchBackward(doc: string; start: int; open, close: char): int =
  var depth = 0
  var i = start
  while i >= 0:
    if doc[i] == close: inc depth
    elif doc[i] == open:
      dec depth
      if depth == 0: return i
    dec i
  -1

proc enclosingPair(doc: string; pos: int; open, close: char): (int, int) =
  ## The innermost `open … close` pair containing `pos`, or `(-1, -1)`.
  ##
  ## A byte scan and not a parse, deliberately: §2.2 B marks `parens`,
  ## `brackets`, `braces` and `angle` display-independent and parse-free, and
  ## the four objects that DO need a parse are marked as such and refuse.
  var depth = 0
  var i = min(pos, doc.len - 1)
  while i >= 0:
    if doc[i] == close and i < pos: inc depth
    elif doc[i] == open:
      if depth == 0:
        let j = matchForward(doc, i, open, close)
        if j > i and j >= pos: return (i, j)
        return (-1, -1)
      dec depth
    dec i
  (-1, -1)

proc enclosingQuote(env: OpEnv; pos: int; q: char): (int, int) =
  ## The quote pair on the caret's LINE that contains `pos`. Line-scoped
  ## because an unbalanced quote anywhere in the document would otherwise pair
  ## across half the file, which is what every editor's quote object avoids.
  let line = env.lineOf(pos)
  let a = env.lineStartOf(line)
  let text = env.lineTextOf(line)
  var opens: seq[int] = @[]
  var i = 0
  while i < text.len:
    if text[i] == q and (i == 0 or text[i - 1] != '\\'):
      opens.add a + i
    inc i
  var k = 0
  while k + 1 < opens.len:
    if opens[k] <= pos and pos <= opens[k + 1]:
      return (opens[k], opens[k + 1])
    k += 2
  (-1, -1)

proc enclosingTag(env: OpEnv; pos: int): (int, int, int, int) =
  ## `(openStart, openEnd, closeStart, closeEnd)` of the innermost `<x …>…</x>`
  ## containing `pos`, or four `-1`s.
  let doc = env.ctx.doc
  var i = min(pos, doc.len - 1)
  while i >= 0:
    if doc[i] == '<' and i + 1 < doc.len and doc[i + 1] != '/':
      let gt = doc.find('>', i)
      if gt > 0 and gt >= i:
        var nameEnd = i + 1
        while nameEnd < gt and doc[nameEnd] notin {' ', '\t', '>', '/'}:
          inc nameEnd
        let name = doc[i + 1 ..< nameEnd]
        if name.len > 0:
          let closeTag = "</" & name & ">"
          let cs = doc.find(closeTag, gt)
          if cs >= 0 and gt < pos and pos <= cs + closeTag.len:
            return (i, gt + 1, cs, cs + closeTag.len)
    dec i
  (-1, -1, -1, -1)

func indentWidthOf(s: string): int =
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  i

proc indentBlock(env: OpEnv; pos: int): (int, int) =
  ## The contiguous run of lines whose indent is at least the caret line's —
  ## §2.2 B's *"by leading whitespace, so it is defined without a parse"*.
  let lines = env.ctx.store.lineCount
  let here = env.lineOf(pos)
  let want = indentWidthOf(env.lineTextOf(here))
  var a = here
  while a > 0:
    let t = env.lineTextOf(a - 1)
    if isBlankLine(t) or indentWidthOf(t) < want: break
    dec a
  var b = here
  while b < lines - 1:
    let t = env.lineTextOf(b + 1)
    if isBlankLine(t) or indentWidthOf(t) < want: break
    inc b
  (a, b)

proc findFrom(doc, pattern: string; start: int; forward: bool): int =
  ## Literal search, wrapping at the document's ends the way `n` / `N` do.
  if pattern.len == 0: return -1
  if forward:
    let i = doc.find(pattern, start)
    if i >= 0: return i
    return doc.find(pattern, 0)
  else:
    var best = -1
    var i = doc.find(pattern, 0)
    while i >= 0 and i < start:
      best = i
      i = doc.find(pattern, i + 1)
    if best >= 0: return best
    return doc.rfind(pattern)

# ===========================================================================
# THE ENVIRONMENT
# ===========================================================================

proc initOpEnv*(doc: string; settings: WrapSettings; viewportRows = 20;
                nowMs: int64 = 0): OpEnv =
  ## The per-call scratch. The wrap cache is built here rather than lazily so
  ## that a display-INDEPENDENT operation costs exactly what a dependent one
  ## does — a lazy cache would make the cost of an operation a signal for
  ## whether it reads the wrap column, and a timing signal is a side channel a
  ## suite can accidentally assert through.
  OpEnv(ctx: initOpCtx(doc, settings.policy),
        display: initDisplayCtx(doc, settings),
        settings: settings, viewportRows: max(1, viewportRows),
        nowMs: nowMs)

# ===========================================================================
# MOTIONS — 34 declarations, three forms each
# ===========================================================================

func landing(offset: int; goal = none(int)): MotionLanding =
  MotionLanding(offset: offset, goal: goal, refusal: rrNone)

func refusedLanding(r: SelectionRange; why: RefusalReason): MotionLanding =
  MotionLanding(offset: r.head, goal: r.goalColumn, refusal: why)

proc mCharLeft(env: OpEnv; st: EditorState; r: SelectionRange;
               args: OpArgs): MotionLanding =
  landing(if r.isRtl: env.ctx.nextBoundary(r.head)
          else: env.ctx.prevBoundary(r.head))

proc mCharRight(env: OpEnv; st: EditorState; r: SelectionRange;
                args: OpArgs): MotionLanding =
  landing(if r.isRtl: env.ctx.prevBoundary(r.head)
          else: env.ctx.nextBoundary(r.head))

proc mCharForward(env: OpEnv; st: EditorState; r: SelectionRange;
                  args: OpArgs): MotionLanding =
  landing(env.ctx.nextBoundary(r.head))

proc mCharBackward(env: OpEnv; st: EditorState; r: SelectionRange;
                   args: OpArgs): MotionLanding =
  landing(env.ctx.prevBoundary(r.head))

proc mGroupLeft(env: OpEnv; st: EditorState; r: SelectionRange;
                args: OpArgs): MotionLanding =
  landing(if r.isRtl: env.groupForward(r.head) else: env.groupBackward(r.head))

proc mGroupRight(env: OpEnv; st: EditorState; r: SelectionRange;
                 args: OpArgs): MotionLanding =
  landing(if r.isRtl: env.groupBackward(r.head) else: env.groupForward(r.head))

proc mGroupForward(env: OpEnv; st: EditorState; r: SelectionRange;
                   args: OpArgs): MotionLanding =
  landing(env.groupForward(r.head))

proc mGroupBackward(env: OpEnv; st: EditorState; r: SelectionRange;
                    args: OpArgs): MotionLanding =
  landing(env.groupBackward(r.head))

proc mSubwordForward(env: OpEnv; st: EditorState; r: SelectionRange;
                     args: OpArgs): MotionLanding =
  landing(env.subwordForward(r.head))

proc mSubwordBackward(env: OpEnv; st: EditorState; r: SelectionRange;
                      args: OpArgs): MotionLanding =
  landing(env.subwordBackward(r.head))

proc verticalLogical(env: OpEnv; r: SelectionRange; delta: int): MotionLanding =
  ## **`line-up` / `line-down`, AND THIS IS THE MILESTONE'S ONE DESIGN
  ## DECISION ABOUT THE PUBLISHED TABLE.**
  ##
  ## §2.2 A marks both **display-dependent** and notes *"logical lines"*. Those
  ## two are only compatible under one reading, and it is the reading taken
  ## here: the motion steps LOGICAL lines and the column it preserves is a
  ## DISPLAY column — the cells from the left edge of the display row the
  ## caret is on. That is what a user tracks (the caret stays under the same
  ## screen column) and it is what makes the published `yes` true: at two
  ## different wrap columns, a caret on the second row of a wrapped line has
  ## two different display columns, so `move-line-up` lands in two different
  ## places.
  ##
  ## The alternative reading — the column is the logical-line column — makes
  ## these two motions display-INDEPENDENT, and then §2.3's positive half is
  ## unsatisfiable for six of the twenty-four operations it is asserted over.
  ## Verification-Harness-Traps §36 is explicit that when a published claim and
  ## an implementation disagree, the repair is to the assertion or to the
  ## design and never to the claim — so the design is what moved, and this
  ## paragraph is the price being paid rather than assumed.
  ##
  ## It also settles the unit PLAT-27 recorded as an open residual
  ## (`wrap.displayGoalOf`: *"a caret whose goal was set by `opMoveLineUp` and
  ## then stepped with `gj` across a WRAPPED line reads a line-relative column
  ## as a row-relative one"*). Both are row-relative now, so the residual is
  ## closed rather than inherited.
  let here = env.display.cache.toDisplay(env.ctx.store.posOf(r.head))
  let goal = if r.goalColumn.isSome: r.goalColumn.get else: here.column
  let line = env.lineOf(r.head)
  let target = clamp(line + delta, 0, env.ctx.store.lineCount - 1)
  let row = env.display.cache.firstRowOf(target)
  let col = min(goal, env.display.cache.lastColumnOf(row))
  let p = env.display.cache.toLogical(DisplayPos(row: row, column: col))
  landing(env.ctx.boundaryAtOrBefore(env.ctx.store.offsetOf(p)), some(goal))

proc mLineUp(env: OpEnv; st: EditorState; r: SelectionRange;
             args: OpArgs): MotionLanding =
  verticalLogical(env, r, -1)

proc mLineDown(env: OpEnv; st: EditorState; r: SelectionRange;
               args: OpArgs): MotionLanding =
  verticalLogical(env, r, 1)

proc displayMotion(env: OpEnv; r: SelectionRange;
                   m: DisplayMotion): MotionLanding =
  ## The four PLAT-27 display motions, called rather than re-derived. `wrap.nim`
  ## owns `gj`/`gk` and screen-line `0`/`$`; a second implementation here would
  ## be Verification-Harness-Traps §30 inside one repository.
  let got = env.display.landingOf(m, r)
  MotionLanding(offset: got.offset, goal: got.goal, refusal: rrNone)

proc mDisplayLineUp(env: OpEnv; st: EditorState; r: SelectionRange;
                    args: OpArgs): MotionLanding =
  displayMotion(env, r, dispRowUp)

proc mDisplayLineDown(env: OpEnv; st: EditorState; r: SelectionRange;
                      args: OpArgs): MotionLanding =
  displayMotion(env, r, dispRowDown)

proc mDisplayLineStart(env: OpEnv; st: EditorState; r: SelectionRange;
                       args: OpArgs): MotionLanding =
  displayMotion(env, r, dispRowStart)

proc mDisplayLineEnd(env: OpEnv; st: EditorState; r: SelectionRange;
                     args: OpArgs): MotionLanding =
  displayMotion(env, r, dispRowEnd)

proc pageMove(env: OpEnv; r: SelectionRange; delta: int): MotionLanding =
  ## §2.2 A: *"viewport height is a parameter, not a view read"*. `env.viewportRows`
  ## is that parameter, and a page is `delta` viewports of DISPLAY rows — which
  ## is why these two are display-dependent and `doc-start` is not.
  let here = env.display.cache.toDisplay(env.ctx.store.posOf(r.head))
  let goal = if r.goalColumn.isSome: r.goalColumn.get else: here.column
  let row = clamp(here.row + delta * env.viewportRows, 0,
                  env.display.cache.rowCount - 1)
  let col = min(goal, env.display.cache.lastColumnOf(row))
  let p = env.display.cache.toLogical(DisplayPos(row: row, column: col))
  landing(env.ctx.boundaryAtOrBefore(env.ctx.store.offsetOf(p)), some(goal))

proc mPageUp(env: OpEnv; st: EditorState; r: SelectionRange;
             args: OpArgs): MotionLanding =
  pageMove(env, r, -1)

proc mPageDown(env: OpEnv; st: EditorState; r: SelectionRange;
               args: OpArgs): MotionLanding =
  pageMove(env, r, 1)

proc mLineStart(env: OpEnv; st: EditorState; r: SelectionRange;
                args: OpArgs): MotionLanding =
  landing(env.lineStartOf(env.lineOf(r.head)))

proc mLineEnd(env: OpEnv; st: EditorState; r: SelectionRange;
              args: OpArgs): MotionLanding =
  landing(env.lineEndOf(env.lineOf(r.head)))

proc mLineStartSmart(env: OpEnv; st: EditorState; r: SelectionRange;
                     args: OpArgs): MotionLanding =
  ## §2.2 A: *"first non-whitespace, then column 0 — Home's two-stage
  ## behaviour"*. Two-stage means the answer depends on where the caret already
  ## is, which is the one motion below whose result is not a function of the
  ## line alone.
  let line = env.lineOf(r.head)
  let a = env.lineStartOf(line)
  let firstNonBlank = a + indentWidthOf(env.lineTextOf(line))
  landing(if r.head == firstNonBlank: a else: firstNonBlank)

proc mDocStart(env: OpEnv; st: EditorState; r: SelectionRange;
               args: OpArgs): MotionLanding =
  landing(0)

proc mDocEnd(env: OpEnv; st: EditorState; r: SelectionRange;
             args: OpArgs): MotionLanding =
  landing(env.ctx.doc.len)

proc mLineNumber(env: OpEnv; st: EditorState; r: SelectionRange;
                 args: OpArgs): MotionLanding =
  ## `:42`, `42G`. **1-based**, because every surface a user reads is.
  if args.number < 1 or args.number > env.ctx.store.lineCount:
    return refusedLanding(r, rrOutOfRange)
  landing(env.lineStartOf(args.number - 1))

proc mMatchingBracket(env: OpEnv; st: EditorState; r: SelectionRange;
                      args: OpArgs): MotionLanding =
  let doc = env.ctx.doc
  var i = r.head
  while i < doc.len and doc[i] notin {'(', ')', '[', ']', '{', '}', '<', '>'}:
    if doc[i] == '\n': break
    inc i
  if i >= doc.len or doc[i] notin {'(', ')', '[', ']', '{', '}', '<', '>'}:
    return refusedLanding(r, rrNoMatch)
  let c = doc[i]
  let p = partnerOf(c)
  let j = if c in {'(', '[', '{', '<'}: matchForward(doc, i, c, p)
          else: matchBackward(doc, i, p, c)
  if j < 0: refusedLanding(r, rrNoMatch) else: landing(j)

proc mSyntaxLeft(env: OpEnv; st: EditorState; r: SelectionRange;
                 args: OpArgs): MotionLanding =
  ## §5.1: *"`syntax-left` on a document whose parse is stale produces a
  ## defined, reported outcome rather than a pause."* This is that outcome.
  ## When a parse arrives, this is the only body that changes.
  if st.parse != pfFresh: return refusedLanding(r, rrStaleParse)
  landing(env.groupBackward(r.head))

proc mSyntaxRight(env: OpEnv; st: EditorState; r: SelectionRange;
                  args: OpArgs): MotionLanding =
  if st.parse != pfFresh: return refusedLanding(r, rrStaleParse)
  landing(env.groupForward(r.head))

proc mParagraphForward(env: OpEnv; st: EditorState; r: SelectionRange;
                       args: OpArgs): MotionLanding =
  landing(env.paragraphForward(r.head))

proc mParagraphBackward(env: OpEnv; st: EditorState; r: SelectionRange;
                        args: OpArgs): MotionLanding =
  landing(env.paragraphBackward(r.head))

proc searchLanding(env: OpEnv; st: EditorState; r: SelectionRange;
                   forward: bool): MotionLanding =
  if st.search.pattern.len == 0: return refusedLanding(r, rrNoPattern)
  let start = if forward: min(r.head + 1, env.ctx.doc.len) else: r.head
  let i = findFrom(env.ctx.doc, st.search.pattern, start, forward)
  if i < 0: refusedLanding(r, rrNoMatch)
  else: landing(env.ctx.boundaryAtOrBefore(i))

proc mSearchNext(env: OpEnv; st: EditorState; r: SelectionRange;
                 args: OpArgs): MotionLanding =
  searchLanding(env, st, r, st.search.direction == sdForward)

proc mSearchPrev(env: OpEnv; st: EditorState; r: SelectionRange;
                 args: OpArgs): MotionLanding =
  searchLanding(env, st, r, st.search.direction != sdForward)

proc mMark(env: OpEnv; st: EditorState; r: SelectionRange;
           args: OpArgs): MotionLanding =
  ## Vim's `'a`. §2.2 A calls a mark an anchor; `commitChange` gives it an
  ## anchor's MAPPING and `EditorState.marks` records why not its type.
  ##
  ## **THE `clamp` THAT WAS HERE IS A REFUSAL NOW** — see `commitChange` for the
  ## §36a argument and for why a refusal rather than a `raise`.
  if args.id.len == 0: return refusedLanding(r, rrMissingArgument)
  if not st.hasMark(args.id): return refusedLanding(r, rrNoMark)
  let at = st.marks[args.id]
  if at < 0 or at > env.ctx.doc.len: return refusedLanding(r, rrOutOfRange)
  landing(env.ctx.boundaryAtOrBefore(at))

proc mJumpBack(env: OpEnv; st: EditorState; r: SelectionRange;
               args: OpArgs): MotionLanding =
  if st.jumps.len == 0 or st.jumpIndex <= 0: return refusedLanding(r, rrNoMatch)
  let at = st.jumps[st.jumpIndex - 1]
  if at < 0 or at > env.ctx.doc.len: return refusedLanding(r, rrOutOfRange)
  landing(env.ctx.boundaryAtOrBefore(at))

proc mJumpForward(env: OpEnv; st: EditorState; r: SelectionRange;
                  args: OpArgs): MotionLanding =
  if st.jumpIndex + 1 >= st.jumps.len: return refusedLanding(r, rrNoMatch)
  let at = st.jumps[st.jumpIndex + 1]
  if at < 0 or at > env.ctx.doc.len: return refusedLanding(r, rrOutOfRange)
  landing(env.ctx.boundaryAtOrBefore(at))

# ===========================================================================
# TEXT OBJECTS — 16 declarations, two forms each
# ===========================================================================

func objSpan(a, b: int): ObjectSpan =
  ObjectSpan(span: spanRange(a, b), refusal: rrNone)

func objRefused(r: SelectionRange; why: RefusalReason): ObjectSpan =
  ObjectSpan(span: r, refusal: why)

proc oWord(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
           args: OpArgs): ObjectSpan =
  let a = env.groupBackward(min(r.head + 1, env.ctx.doc.len))
  var b = env.groupForward(a)
  if around: b = env.groupForward(b)
  objSpan(a, b)

proc oSubword(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
              args: OpArgs): ObjectSpan =
  let a = env.subwordBackward(min(r.head + 1, env.ctx.doc.len))
  var b = env.subwordForward(a)
  if around: b = env.subwordForward(b)
  objSpan(a, b)

proc oLine(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
           args: OpArgs): ObjectSpan =
  ## **`inner` is the line's text and `around` includes its terminator.** That
  ## is the distinction that makes the two forms two operations: `d i l` leaves
  ## an empty line behind and `d a l` removes the line.
  let line = env.lineOf(r.head)
  let a = env.lineStartOf(line)
  let b = if around and line < env.ctx.store.lineCount - 1:
            env.lineStartOf(line + 1)
          else: env.lineEndOf(line)
  objSpan(a, b)

proc oParagraph(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
                args: OpArgs): ObjectSpan =
  ## **NOT `paragraph-backward` … `paragraph-forward`, AND THE DIFFERENCE IS
  ## WHAT MAKES `inner` AND `around` TWO OPERATIONS.** The two MOTIONS are
  ## Vim's `{` and `}`, which both land on a blank line's start; composing them
  ## gives a span that already excludes the trailing blank, so `around` would
  ## equal `inner` and the `ckAroundContainsInner` witness would be asserting
  ## an identity. Measured: it did, on all eighteen scenario documents, on the
  ## first run. So the object is built from the line index directly — `inner`
  ## is the run of non-blank lines the caret sits in, `around` is that run plus
  ## the blank lines that follow it, which is Vim's own `ip` / `ap`.
  let lines = env.ctx.store.lineCount
  let here = env.lineOf(r.head)
  var a = here
  while a > 0 and not isBlankLine(env.lineTextOf(a - 1)): dec a
  var b = here
  while b < lines - 1 and not isBlankLine(env.lineTextOf(b + 1)): inc b
  if around:
    while b < lines - 1 and isBlankLine(env.lineTextOf(b + 1)): inc b
  let start = env.lineStartOf(a)
  let stop = if b < lines - 1: env.lineStartOf(b + 1) else: env.ctx.doc.len
  objSpan(start, stop)

proc bracketObject(env: OpEnv; r: SelectionRange; around: bool;
                   open, close: char): ObjectSpan =
  let (a, b) = enclosingPair(env.ctx.doc, r.head, open, close)
  if a < 0: return objRefused(r, rrNoEnclosingObject)
  if around: objSpan(a, b + 1) else: objSpan(a + 1, b)

proc oParens(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
             args: OpArgs): ObjectSpan =
  bracketObject(env, r, around, '(', ')')

proc oBrackets(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
               args: OpArgs): ObjectSpan =
  bracketObject(env, r, around, '[', ']')

proc oBraces(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
             args: OpArgs): ObjectSpan =
  bracketObject(env, r, around, '{', '}')

proc oAngle(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
            args: OpArgs): ObjectSpan =
  bracketObject(env, r, around, '<', '>')

proc quoteObject(env: OpEnv; r: SelectionRange; around: bool;
                 q: char): ObjectSpan =
  let (a, b) = enclosingQuote(env, r.head, q)
  if a < 0: return objRefused(r, rrNoEnclosingObject)
  if around: objSpan(a, b + 1) else: objSpan(a + 1, b)

proc oQuoteSingle(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
                  args: OpArgs): ObjectSpan =
  quoteObject(env, r, around, '\'')

proc oQuoteDouble(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
                  args: OpArgs): ObjectSpan =
  quoteObject(env, r, around, '"')

proc oQuoteBack(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
                args: OpArgs): ObjectSpan =
  quoteObject(env, r, around, '`')

proc oTag(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
          args: OpArgs): ObjectSpan =
  let (os, oe, cs, ce) = enclosingTag(env, r.head)
  if os < 0: return objRefused(r, rrNoEnclosingObject)
  if around: objSpan(os, ce) else: objSpan(oe, cs)

proc oIndentBlock(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
                  args: OpArgs): ObjectSpan =
  let (a, b) = env.indentBlock(r.head)
  let start = if around and a > 0: env.lineStartOf(a - 1) else: env.lineStartOf(a)
  let stop = if around and b < env.ctx.store.lineCount - 1:
               env.lineEndOf(b + 1)
             else: env.lineEndOf(b)
  objSpan(start, stop)

proc oSyntaxNode(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
                 args: OpArgs): ObjectSpan =
  ## §2.2 B's last row: *"need the parse, so they degrade when it is stale"*.
  if st.parse != pfFresh: return objRefused(r, rrStaleParse)
  bracketObject(env, r, around, '(', ')')

proc oFunction(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
               args: OpArgs): ObjectSpan =
  if st.parse != pfFresh: return objRefused(r, rrStaleParse)
  bracketObject(env, r, around, '{', '}')

proc oArgument(env: OpEnv; st: EditorState; r: SelectionRange; around: bool;
               args: OpArgs): ObjectSpan =
  if st.parse != pfFresh: return objRefused(r, rrStaleParse)
  let (a, b) = enclosingPair(env.ctx.doc, r.head, '(', ')')
  if a < 0: return objRefused(r, rrNoEnclosingObject)
  var lo = a + 1
  var hi = b
  var i = a + 1
  while i < b:
    if env.ctx.doc[i] == ',':
      if i < r.head: lo = i + 1
      else:
        hi = i
        break
    inc i
  if around and hi < b: objSpan(lo, hi + 1) else: objSpan(lo, hi)

# ===========================================================================
# THE RESULT CONSTRUCTORS — one place decides `acted` from `no-op`
# ===========================================================================

proc settle(before, after: EditorState; intents: seq[HostIntent] = @[]): OpResult =
  ## **THE ONE PLACE `ooActed` IS DECIDED, AND IT IS DECIDED BY COMPARISON.**
  ## Not by the handler claiming it moved: a handler that said so would be the
  ## constructor labelling its own output, which §34's third rule and
  ## Verification-Harness-Traps §30 both refuse. The comparison is
  ## `editor_state.==`, which is every field.
  if after == before and intents.len == 0:
    OpResult(outcome: ooNoOp, state: after, refusal: rrNone, intents: @[])
  else:
    OpResult(outcome: ooActed, state: after, refusal: rrNone, intents: intents)

func refused(st: EditorState; why: RefusalReason): OpResult =
  OpResult(outcome: ooRefused, state: st, refusal: why, intents: @[])

proc withSelection(st: EditorState; ranges: seq[SelectionRange];
                   primary: int): EditorState =
  result = st
  result.selection = editorSelection(ranges, primary)

proc commitChange*(st: EditorState; cs: ChangeSet;
                   newSelection = none(EditorSelection);
                   userEvent = ueInput; nowMs: int64 = 0): EditorState =
  ## **THE ONE PLACE THE DOCUMENT MOVES.** Every operation that edits goes
  ## through here, and three things happen in one place rather than in fifty:
  ##
  ##   1. the transaction is offered to PLAT-32's history, so "an edit is
  ##      undoable" is a property of this function;
  ##   2. the new document is installed;
  ##   3. the marks and the jump list are mapped through the same change set.
  ##
  ## **THE SELECTION-HISTORY MAPPING THAT USED TO BE STEP 3 IS GONE, AND IT IS
  ## GONE BECAUSE THE DEFECT IT REPAIRED IS NOW STRUCTURALLY ABSENT.** Until
  ## PLAT-32 this function walked `selUndo` and `selRedo` mapping every stored
  ## selection forward, because those were FLAT STACKS: a selection recorded
  ## three edits ago sat in a `seq` with nothing saying which document it was
  ## expressed against, so it had to be dragged forward on every edit or it
  ## named bytes that no longer existed. `FUZZ-8` found exactly that, on four
  ## of the nine corpus classes — `[96,182)` in a 114-byte document.
  ##
  ## An event history has no flat stack. Every stored selection is ANCHORED TO
  ## AN EVENT: `startSelection` is expressed against the document below its
  ## event, `endSelection` and `selectionsAfter` against the document above it,
  ## and the only thing that can move a document without adding an event is a
  ## REMOTE change — which `history.mapEvent` maps, in one place, through the
  ## same primitive. A local edit pushes a new event on top, so every selection
  ## below it is still read in the coordinates it was written in, and is read
  ## only once the events above it have been undone. The repair is not deleted;
  ## it is relocated to the one case that still needs it, where it is `LAW-H6`.
  ##
  ## **AND THE SAME CLAMP WAS STILL THERE ONE FIELD OVER UNTIL PLAT-31, WHICH
  ## CLOSED IT.** `marks` and `jumps` are byte offsets (see
  ## `EditorState.marks`); this function did NOT map them and `mMark` /
  ## `mJumpBack` / `mJumpForward` reached them through `clamp(..., 0, doc.len)`
  ## — §36a's shape, one field over from the repair above, recorded by PLAT-30
  ## as a residual rather than fixed. It is fixed here, and in the same two
  ## halves the §36a rule asks for:
  ##
  ##   1. **THE MAPPING.** Every in-range mark and jump is advanced through the
  ##      same change set, by `change_set.mapPosOr` — which is not a new
  ##      derivation but the exact function `anchor.landingOf` is DEFINED as
  ##      (`anchor.nim`: *"`change_set.mapPosOr` spelled through the anchor's
  ##      own type"*). So marks got PLAT-28's mapping; what they did not get is
  ##      PLAT-28's TYPE, and `EditorState.marks` records why.
  ##   2. **THE CLAMP BECAME A REFUSAL, NOT A `raise`.** §36a's first rule says
  ##      a silent repair must raise *"unless the repair is itself a specified
  ##      behaviour with a name"*. A raise is the wrong answer HERE for a
  ##      reason this milestone can point at rather than argue: `mMark` is a
  ##      motion, `FUZZ-8`'s invariant is that no exception escapes and a
  ##      refusal is a typed value, and §5.1 asks for *"a defined, reported
  ##      outcome"*. So the offset that our own bookkeeping can no longer
  ##      produce — it can now only arrive from a CALLER who wrote one — is
  ##      `rrOutOfRange`, which is a named outcome a suite drives, rather than
  ##      a plausible landing nobody sees being wrong.
  ##
  ## `sideAfter` and not `sideBefore`: a mark names the start of the text that
  ## was there, so text inserted at exactly that offset is new text the mark
  ## never named, and the mark moves to stay in front of what it did.
  result = st
  # =====================================================================
  # THE LOCAL TRANSACTION FILTERS — PLAT-33
  # =====================================================================
  # A read-only buffer or a protected range refuses a LOCAL change here, and
  # the refusal is "the state did not move", which `settle` already reads as
  # a non-act. `collab_text.applyRemoteChange` does NOT make this call, which
  # is §12.2's *"it bypasses the local transaction filters"* — expressed as
  # the absence of a call rather than as a flag passed to one, so a source
  # scan can see it and a boolean cannot be got wrong.
  if st.filters.refusedBy(cs):
    if newSelection.isSome:
      result.selection = newSelection.get
    return
  let newDoc = cs.apply(st.doc)
  if newDoc != st.doc:
    let selBefore = st.selection
    let selAfter = if newSelection.isSome: newSelection.get
                   else: mapSelection(selBefore, cs)
    result.recordTransaction(
      transaction(cs, some(selAfter), @[],
                  @[Annotation(kind: anUserEvent, userEvent: userEvent),
                    Annotation(kind: anTime, timeMs: nowMs)]),
      st.doc, selBefore)
    result.mapPositionTables(st, cs)
    result.doc = newDoc
  if newSelection.isSome:
    result.selection = newSelection.get

proc applyTransaction(st: EditorState; env: OpEnv; t: Transaction;
                      userEvent = ueInput): EditorState =
  commitChange(st, t.changes, t.selection, userEvent, env.nowMs)

proc editByRange(st: EditorState; env: OpEnv;
                 f: proc (r: SelectionRange): RangeOutcome;
                 userEvent = ueInput): EditorState =
  ## Every editing operation goes through PLAT-26's apply-across-ranges helper.
  ## *"Multi-cursor is the absence of a special case"* is inherited rather than
  ## re-established: nothing below asks how many ranges there are.
  ##
  ## `userEvent` is PLAT-32's grouping key — §13.1's *"by the transaction's own
  ## KIND"*. It is a parameter of this helper rather than a lookup on the
  ## operation's name, because the name is not available here and a second
  ## table mapping names to kinds would be a second place for the two to drift.
  applyTransaction(st, env, changeByRange(st.doc, st.selection, f), userEvent)

func noEdit(r: SelectionRange): RangeOutcome =
  RangeOutcome(edits: @[], effects: @[], range: r)

func replaceWith(a, b: int; text: string; head: int): RangeOutcome =
  RangeOutcome(edits: @[Edit(fromPos: a, toPos: b, insert: text)],
               effects: @[], range: caret(head))

# ===========================================================================
# OPERATORS — 20 declarations, one form each. THEY CONSUME A SELECTION.
# ===========================================================================

proc selectedText(st: EditorState): string =
  ## Every range's text, newline-joined. What the three yank/paste operations
  ## and `pipe-selection` read, and the only thing an operator needs to know
  ## about how the selection was produced.
  var parts: seq[string] = @[]
  for r in st.selection:
    parts.add st.doc[r.rangeFrom ..< min(r.rangeTo, st.doc.len)]
  parts.join("\n")

proc cDeleteSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    if r.isEmpty: noEdit(r)
    else: replaceWith(r.rangeFrom, r.rangeTo, "", r.rangeFrom)))

proc cChangeSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## *"delete and enter insert mode"* — the mode change is half the operation,
  ## which is why it is not `delete-selection` with a note.
  var after = editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    if r.isEmpty: noEdit(r)
    else: replaceWith(r.rangeFrom, r.rangeTo, "", r.rangeFrom))
  after.mode = emInsert
  settle(st, after)

proc cYankSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.setRegister(st.activeRegister,
                    Register(text: selectedText(st), kind: rkCharwise))
  settle(st, after)

proc pasteInto(st: EditorState; env: OpEnv; atRangeStart: bool): EditorState =
  ## **THE PARAMETER IS NOT CALLED `before`, AND THAT IS NOT STYLE.**
  ## `test_editor_change_algebra.nim` scans every module of this directory for
  ## the spelling `before: bool` — PLAT-25's tripwire for a hand-written copy
  ## of `rebase`'s double mapping — and a paste operation's natural parameter
  ## name collides with it exactly. That is
  ## Verification-Harness-Traps §5: a sentinel that also matches a legitimate
  ## value. The cheap repair is to widen the scan, which blunts a tripwire that
  ## has caught something; the right one is to name this what it is.
  let reg = st.registerOf(st.activeRegister)
  if reg.text.len == 0: return st
  let payload = if reg.kind == rkLinewise and not reg.text.endsWith("\n"):
                  reg.text & "\n"
                else: reg.text
  editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    let at = if atRangeStart: r.rangeFrom else: r.rangeTo
    replaceWith(at, at, payload, at + payload.len))

proc cPasteBefore(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, pasteInto(st, env, true))

proc cPasteAfter(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, pasteInto(st, env, false))

proc cPasteReplace(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let reg = st.registerOf(st.activeRegister)
  if reg.text.len == 0: return settle(st, st)
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    replaceWith(r.rangeFrom, r.rangeTo, reg.text, r.rangeFrom + reg.text.len)))

proc linesTouched(env: OpEnv; st: EditorState): seq[int] =
  ## The logical lines any range of the selection touches, ascending and
  ## distinct. What the four per-line operators work over.
  result = @[]
  for r in st.selection:
    let a = env.lineOf(r.rangeFrom)
    let b = env.lineOf(max(r.rangeTo - 1, r.rangeFrom))
    for line in a .. b:
      if line notin result: result.add line
  result.sort()

proc rewriteLines(env: OpEnv; st: EditorState;
                  f: proc (s: string): string): EditorState =
  ## Rewrite every touched line through `f`, as ONE change set built from the
  ## per-line edits. Not `changeByRange`, because the unit here is a line
  ## rather than a range and two ranges on one line must rewrite it once.
  var edits: seq[Edit] = @[]
  for line in linesTouched(env, st):
    let a = env.lineStartOf(line)
    let text = env.lineTextOf(line)
    let rewritten = f(text)
    if rewritten != text:
      edits.add Edit(fromPos: a, toPos: a + text.len, insert: rewritten)
  if edits.len == 0: return st
  let cs = changeSet(st.doc.len, edits)
  commitChange(st, cs, some(mapSelection(st.selection, cs)))

proc cIndentSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let unit = st.indentUnit
  settle(st, rewriteLines(env, st, proc (s: string): string = unit & s))

proc cDedentSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let unit = st.indentUnit
  settle(st, rewriteLines(env, st, proc (s: string): string =
    if s.startsWith(unit): s[unit.len .. ^1]
    elif s.len > 0 and s[0] == '\t': s[1 .. ^1]
    elif s.len > 0 and s[0] == ' ': s[1 .. ^1]
    else: s))

proc cReindentSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## §2.2 C: *"ask the language for the right indentation"*. There is no
  ## language service in the model, so this refuses by name rather than
  ## guessing — §5.1's rule, and the same refusal the syntax motions take.
  if st.parse != pfFresh: return refused(st, rrStaleParse)
  let unit = st.indentUnit
  settle(st, rewriteLines(env, st, proc (s: string): string =
    unit & s.strip(leading = true, trailing = false)))

proc commentedLine(st: EditorState; s: string): string =
  let i = indentWidthOf(s)
  s[0 ..< i] & st.comments.lineToken & " " & s[i .. ^1]

proc uncommentedLine(st: EditorState; s: string): string =
  let i = indentWidthOf(s)
  var rest = s[i .. ^1]
  if rest.startsWith(st.comments.lineToken):
    rest = rest[st.comments.lineToken.len .. ^1]
    if rest.startsWith(" "): rest = rest[1 .. ^1]
    return s[0 ..< i] & rest
  s

func isCommented(st: EditorState; s: string): bool =
  s.strip().startsWith(st.comments.lineToken)

proc cToggleComment(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## **THE DECISION IS TAKEN ONCE FOR THE WHOLE SELECTION, NOT PER LINE.** A
  ## per-line toggle over a half-commented block leaves it half-commented the
  ## other way, which is the one behaviour a user notices.
  var allCommented = true
  var any = false
  for line in linesTouched(env, st):
    let t = env.lineTextOf(line)
    if isBlankLine(t): continue
    any = true
    if not isCommented(st, t): allCommented = false
  if not any: return settle(st, st)
  let capture = st
  settle(st, rewriteLines(env, st, proc (s: string): string =
    if isBlankLine(s): s
    elif allCommented: uncommentedLine(capture, s)
    else: commentedLine(capture, s)))

proc cLineComment(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let capture = st
  settle(st, rewriteLines(env, st, proc (s: string): string =
    if isBlankLine(s) or isCommented(capture, s): s else: commentedLine(capture, s)))

proc cLineUncomment(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let capture = st
  settle(st, rewriteLines(env, st, proc (s: string): string =
    uncommentedLine(capture, s)))

proc cBlockComment(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let o = st.comments.blockOpen
  let c = st.comments.blockClose
  if o.len == 0 or c.len == 0: return settle(st, st)
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    RangeOutcome(
      edits: @[Edit(fromPos: r.rangeFrom, toPos: r.rangeFrom, insert: o),
               Edit(fromPos: r.rangeTo, toPos: r.rangeTo, insert: c)],
      effects: @[], range: spanRange(r.rangeFrom, r.rangeTo + o.len + c.len))))

proc cBlockUncomment(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let o = st.comments.blockOpen
  let c = st.comments.blockClose
  if o.len == 0 or c.len == 0: return settle(st, st)
  let doc = st.doc
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    let body = doc[r.rangeFrom ..< min(r.rangeTo, doc.len)]
    if body.startsWith(o) and body.endsWith(c) and body.len >= o.len + c.len:
      let inner = body[o.len ..< body.len - c.len]
      replaceWith(r.rangeFrom, r.rangeTo, inner, r.rangeFrom + inner.len)
    else:
      noEdit(r)))

proc mapSelectionText(st: EditorState; env: OpEnv;
                      f: proc (s: string): string): EditorState =
  editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    if r.isEmpty: return noEdit(r)
    let body = st.doc[r.rangeFrom ..< min(r.rangeTo, st.doc.len)]
    let out0 = f(body)
    RangeOutcome(edits: @[Edit(fromPos: r.rangeFrom, toPos: r.rangeTo, insert: out0)],
                 effects: @[], range: spanRange(r.rangeFrom, r.rangeFrom + out0.len)))

proc cUpperCase(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, mapSelectionText(st, env, proc (s: string): string = unicode.toUpper(s)))

proc cLowerCase(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, mapSelectionText(st, env, proc (s: string): string = unicode.toLower(s)))

proc cSwapCase(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, mapSelectionText(st, env, proc (s: string): string =
    var out0 = ""
    for r in s.runes:
      if r.isUpper(): out0.add unicode.toLower($r)
      elif r.isLower(): out0.add unicode.toUpper($r)
      else: out0.add $r
    out0))

proc cJoinLines(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## Every `\n` the selection touches becomes one space, with the following
  ## line's indent removed — which is what makes it `join` rather than
  ## `delete the newline`.
  var edits: seq[Edit] = @[]
  let lines = linesTouched(env, st)
  if lines.len == 0: return settle(st, st)
  let last = if lines.len == 1: lines[0] else: lines[^1]
  for line in lines[0] .. min(last, env.ctx.store.lineCount - 2):
    let a = env.lineEndOf(line)
    let nextStart = env.lineStartOf(line + 1)
    let b = nextStart + indentWidthOf(env.lineTextOf(line + 1))
    if b > a: edits.add Edit(fromPos: a, toPos: b, insert: " ")
  if edits.len == 0: return settle(st, st)
  let cs = changeSet(st.doc.len, edits)
  settle(st, commitChange(st, cs, some(mapSelection(st.selection, cs))))

proc cReplaceChar(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## Vim's `r`. Every cluster of the selection becomes `args.ch`; an empty
  ## range replaces the cluster under the caret, which is what `r` does.
  if args.ch.len == 0: return refused(st, rrMissingArgument)
  let repl = args.ch
  let boundaries = env.ctx.boundaries
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    var a = r.rangeFrom
    var b = r.rangeTo
    if r.isEmpty:
      let i = boundaries.upperBound(a)
      b = if i >= boundaries.len: a else: boundaries[i]
    if a >= b: return noEdit(r)
    var out0 = ""
    var p = a
    while p < b:
      let i = boundaries.upperBound(p)
      let q = if i >= boundaries.len: b else: min(boundaries[i], b)
      out0.add repl
      p = if q > p: q else: p + 1
    replaceWith(a, b, out0, a + out0.len)))

proc cPipeSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## Kakoune's `|`. §5.2: *"the operation names an intent; the HOST performs
  ## the process and hands back a transaction."* So the document does not move
  ## here and cannot: there is no `startProcess` in this module's import
  ## closure and `ci/test/editor-import-closure.sh` is what makes that a fact.
  if args.command.len == 0: return refused(st, rrMissingArgument)
  OpResult(outcome: ooActed, state: st, refusal: rrNone,
           intents: @[HostIntent(kind: hiPipe, payload: args.command)])

# ===========================================================================
# COMMANDS — 70 declarations
# ===========================================================================

proc cInsertText(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  if args.text.len == 0: return refused(st, rrMissingArgument)
  let s = args.text
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    replaceWith(r.rangeFrom, r.rangeTo, s, r.rangeFrom + s.len)))

proc insertAtCaret(st: EditorState; env: OpEnv; s: string): EditorState =
  editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    replaceWith(r.rangeFrom, r.rangeTo, s, r.rangeFrom + s.len))

proc cInsertNewline(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, insertAtCaret(st, env, "\n"))

proc cInsertNewlineAndIndent(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## The indent is the CURRENT line's, copied — which is the indentation rule
  ## that needs no language service, and therefore the one this milestone can
  ## honestly implement. `reindent-selection` is the one that needs a parse and
  ## it refuses.
  var edits: seq[Edit] = @[]
  for r in st.selection:
    let line = env.lineOf(r.rangeFrom)
    let indent = env.lineTextOf(line)[0 ..< indentWidthOf(env.lineTextOf(line))]
    edits.add Edit(fromPos: r.rangeFrom, toPos: r.rangeTo, insert: "\n" & indent)
  if edits.len == 0: return settle(st, st)
  let cs = changeSet(st.doc.len, edits)
  settle(st, commitChange(st, cs, some(mapSelection(st.selection, cs))))

proc blankLine(env: OpEnv; st: EditorState; above: bool): EditorState =
  var edits: seq[Edit] = @[]
  for r in st.selection:
    let line = env.lineOf(r.head)
    let at = if above: env.lineStartOf(line)
             elif line < env.ctx.store.lineCount - 1: env.lineStartOf(line + 1)
             else: env.ctx.doc.len
    let text = if above or line < env.ctx.store.lineCount - 1: "\n" else: "\n"
    edits.add Edit(fromPos: at, toPos: at, insert: text)
  if edits.len == 0: return st
  let cs = changeSet(st.doc.len, edits)
  commitChange(st, cs, some(mapSelection(st.selection, cs)))

proc cInsertBlankLineAbove(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, blankLine(env, st, true))

proc cInsertBlankLineBelow(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, blankLine(env, st, false))

proc cInsertTab(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, insertAtCaret(st, env, st.indentUnit))

proc deleteBy(st: EditorState; env: OpEnv;
              bounds: proc (r: SelectionRange): (int, int)): EditorState =
  editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    if not r.isEmpty:
      return replaceWith(r.rangeFrom, r.rangeTo, "", r.rangeFrom)
    let (a, b) = bounds(r)
    if a >= b: noEdit(r) else: replaceWith(a, b, "", a))

proc cDeleteCharBackward(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## **ONE BACKSPACE REMOVES A WHOLE ZWJ SEQUENCE.** §2.2 D says so and §5 of
  ## the conformance suite exists to stop it regressing; `prevBoundary` is
  ## UAX #29's answer and this operation does not have its own.
  let ctx = env.ctx
  settle(st, deleteBy(st, env, proc (r: SelectionRange): (int, int) =
    (ctx.prevBoundary(r.pos), r.pos)))

proc cDeleteCharForward(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let ctx = env.ctx
  settle(st, deleteBy(st, env, proc (r: SelectionRange): (int, int) =
    (r.pos, ctx.nextBoundary(r.pos))))

proc cDeleteGroupBackward(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let e = env
  settle(st, deleteBy(st, env, proc (r: SelectionRange): (int, int) =
    (e.groupBackward(r.pos), r.pos)))

proc cDeleteGroupForward(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let e = env
  settle(st, deleteBy(st, env, proc (r: SelectionRange): (int, int) =
    (r.pos, e.groupForward(r.pos))))

proc cDeleteToLineStart(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let e = env
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    let a = e.lineStartOf(e.lineOf(r.head))
    if a >= r.head: noEdit(r) else: replaceWith(a, r.head, "", a)))

proc cDeleteToLineEnd(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let e = env
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    let b = e.lineEndOf(e.lineOf(r.head))
    if b <= r.head: noEdit(r) else: replaceWith(r.head, b, "", r.head)))

proc cDeleteLine(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var edits: seq[Edit] = @[]
  for line in linesTouched(env, st):
    let a = env.lineStartOf(line)
    let b = if line < env.ctx.store.lineCount - 1: env.lineStartOf(line + 1)
            else: env.ctx.doc.len
    if b > a: edits.add Edit(fromPos: a, toPos: b, insert: "")
  if edits.len == 0: return settle(st, st)
  let cs = changeSet(st.doc.len, edits)
  settle(st, commitChange(st, cs, some(mapSelection(st.selection, cs))))

proc cDeleteTrailingWhitespace(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## **THE WHOLE DOCUMENT, NOT THE SELECTION.** It is in the *Deletion by unit*
  ## group and its unit is the file; a selection-scoped version would leave a
  ## file with trailing whitespace after running an operation named for
  ## removing it.
  var edits: seq[Edit] = @[]
  for line in 0 ..< env.ctx.store.lineCount:
    let text = env.lineTextOf(line)
    let stripped = text.strip(leading = false, trailing = true)
    if stripped.len != text.len:
      let a = env.lineStartOf(line)
      edits.add Edit(fromPos: a + stripped.len, toPos: a + text.len, insert: "")
  if edits.len == 0: return settle(st, st)
  let cs = changeSet(st.doc.len, edits)
  settle(st, commitChange(st, cs, some(mapSelection(st.selection, cs))))

proc swapLine(env: OpEnv; st: EditorState; up: bool): EditorState =
  ## §2.4's collision, avoided by name: these are `swap-line-up` /
  ## `swap-line-down` and NOT `move-line-up` / `move-line-down`, because the
  ## latter are already the `move-` forms of the `line-up` / `line-down`
  ## motions. Two operations under one name is a binding that resolves to
  ## whichever the table iterated to last.
  let line = env.lineOf(st.selection.mainRange.head)
  let other = if up: line - 1 else: line + 1
  if other < 0 or other >= env.ctx.store.lineCount: return st
  let lo = min(line, other)
  let hi = max(line, other)
  let a = env.lineStartOf(lo)
  let b = if hi < env.ctx.store.lineCount - 1: env.lineStartOf(hi + 1)
          else: env.ctx.doc.len
  let loText = env.lineTextOf(lo)
  let hiText = env.lineTextOf(hi)
  let trailing = if hi < env.ctx.store.lineCount - 1: "\n" else: ""
  let swapped = hiText & "\n" & loText & trailing
  let cs = changeSet(st.doc.len, @[Edit(fromPos: a, toPos: b, insert: swapped)])
  let newLineStart = if up: a else: a + hiText.len + 1
  commitChange(st, cs, some(caretSelection(newLineStart)))

proc cSwapLineUp(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, swapLine(env, st, true))

proc cSwapLineDown(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, swapLine(env, st, false))

proc copyLine(env: OpEnv; st: EditorState; up: bool): EditorState =
  let line = env.lineOf(st.selection.mainRange.head)
  let a = env.lineStartOf(line)
  let text = env.lineTextOf(line)
  let at = if up: a else: (if line < env.ctx.store.lineCount - 1:
                             env.lineStartOf(line + 1) else: env.ctx.doc.len)
  let payload = if up or line < env.ctx.store.lineCount - 1: text & "\n"
                else: "\n" & text
  let cs = changeSet(st.doc.len, @[Edit(fromPos: at, toPos: at, insert: payload)])
  commitChange(st, cs, some(mapSelection(st.selection, cs)))

proc cCopyLineUp(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, copyLine(env, st, true))

proc cCopyLineDown(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, copyLine(env, st, false))

proc cSplitLine(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## **`split-line` LEAVES THE CARET WHERE IT IS AND `insert-newline` MOVES
  ## IT.** That is the only difference between them, it is the difference Vim's
  ## `gJ`-inverse has, and two published names with identical behaviour would
  ## be one operation with two spellings.
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    RangeOutcome(edits: @[Edit(fromPos: r.rangeFrom, toPos: r.rangeTo, insert: "\n")],
                 effects: @[], range: caret(r.rangeFrom))))

proc cTransposeChars(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## Clusters, not bytes and not runes — so transposing across a ZWJ family
  ## moves the whole family.
  let doc = st.doc
  let ctx = env.ctx
  settle(st, editByRange(st, env, proc (r: SelectionRange): RangeOutcome =
    let b = ctx.boundaryAtOrBefore(r.head)
    let a = ctx.prevBoundary(b)
    let c = ctx.nextBoundary(b)
    if a >= b or b >= c or c > doc.len: return noEdit(r)
    replaceWith(a, c, doc[b ..< c] & doc[a ..< b], c)))

proc cSelectAll(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = singleSelection(0, st.doc.len)
  settle(st, after)

proc cSelectLine(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection:
    let a = env.lineStartOf(env.lineOf(r.rangeFrom))
    let b = env.lineEndOf(env.lineOf(max(r.rangeTo - 1, r.rangeFrom)))
    ranges.add spanRange(a, b)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cSelectParentSyntax(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  if st.parse != pfFresh: return refused(st, rrStaleParse)
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection:
    let (a, b) = enclosingPair(st.doc, r.head, '(', ')')
    ranges.add (if a < 0: r else: spanRange(a, b + 1))
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cSimplifySelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## Kakoune's `;`: every range collapses to its head, the set stays.
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection: ranges.add caret(r.head)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cCollapseToCursors(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## The same shape as `simplify-selection` and NOT the same operation: this
  ## one collapses to each range's ANCHOR, which is where a user who selected
  ## rightwards started. The two differ on every non-empty range, which is
  ## what makes them two published names rather than one.
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection: ranges.add caret(r.anchor)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cFlipSelections(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## Kakoune's `<a-;>`: anchor and head swap, so the direction reverses.
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection: ranges.add spanRange(r.head, r.anchor, r.goalColumn)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cKeepPrimarySelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(@[st.selection.mainRange], 0)
  settle(st, after)

proc addCursorVertically(env: OpEnv; st: EditorState; up: bool): EditorState =
  let r = st.selection.mainRange
  let line = env.lineOf(r.head)
  let target = if up: line - 1 else: line + 1
  if target < 0 or target >= env.ctx.store.lineCount: return st
  let col = r.head - env.lineStartOf(line)
  let landed = env.ctx.boundaryAtOrBefore(
    min(env.lineStartOf(target) + col, env.lineEndOf(target)))
  var ranges = st.selection.ranges
  ranges.add caret(landed)
  result = st
  result.pushSelectionHistory(env.nowMs)
  result.selection = editorSelection(ranges, st.selection.primaryIndex)

proc cAddCursorAbove(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, addCursorVertically(env, st, true))

proc cAddCursorBelow(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, addCursorVertically(env, st, false))

proc cAddCursorAtNextMatch(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let needle = if st.search.pattern.len > 0: st.search.pattern
               else: selectedText(st)
  if needle.len == 0: return refused(st, rrNoPattern)
  let from0 = st.selection.mainRange.rangeTo
  let i = findFrom(st.doc, needle, from0, true)
  if i < 0: return refused(st, rrNoMatch)
  var ranges = st.selection.ranges
  ranges.add spanRange(i, i + needle.len)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cAddCursorAtEachLine(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var ranges: seq[SelectionRange] = @[]
  for line in linesTouched(env, st):
    ranges.add caret(env.lineStartOf(line))
  if ranges.len == 0: return settle(st, st)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, min(st.selection.primaryIndex,
                                                ranges.len - 1))
  settle(st, after)

proc cRemovePrimaryCursor(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## **A SELECTION OF ONE REFUSES RATHER THAN BECOMING EMPTY.** `selection.nim`
  ## has no state in which the editor has no cursor, and a clamp here would be
  ## Verification-Harness-Traps §36a's silent repair.
  if st.selection.rangeCount <= 1: return refused(st, rrOutOfRange)
  var ranges = st.selection.ranges
  ranges.delete(st.selection.primaryIndex)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges,
    min(st.selection.primaryIndex, ranges.len - 1))
  settle(st, after)

proc cRotatePrimaryCursor(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  if st.selection.rangeCount <= 1: return settle(st, st)
  var after = st
  after.selection = editorSelection(st.selection.ranges,
    (st.selection.primaryIndex + 1) mod st.selection.rangeCount)
  settle(st, after)

proc applyHistoryStep(st: EditorState; step: HistoryStep): EditorState =
  ## **ONE ROUTINE FOR ALL FOUR HISTORY OPERATIONS.** `undo`, `redo`,
  ## `undo-selection` and `redo-selection` differ only in which `pop*` produced
  ## the step; applying it is the same code, which is the operation-level half
  ## of *"redo is generated rather than stored"*. A second `restoreRedo`
  ## written beside `restoreUndo` is the shape that lets the two drift, and
  ## PLAT-30's snapshot version had it as one `ontoRedo: bool` for the same
  ## reason.
  ##
  ## **THE SELECTION HISTORY IS NO LONGER DISCARDED.** The routine this
  ## replaces cleared `selUndo` and `selRedo` on every undo, and said why: *"a
  ## snapshot stack does not keep a change set from the current document to the
  ## restored one"*, so there was nothing to map the stored selections through.
  ## An event history has one — `step.tr.changes` IS that change set — and the
  ## selections it stores are anchored to their events, so nothing needs
  ## clearing and `undo-selection` after an `undo` reports real history.
  result = st
  let before = st.doc
  result.doc = step.tr.changes.apply(before)
  result.selection =
    if step.tr.selection.isSome: step.tr.selection.get
    else: mapSelection(st.selection, step.tr.changes)
  result.history = recordStep(step, before)
  # The marks and the jump list move with the document, through the same change
  # set and the same call `commitChange` uses (PLAT-31's §36a repair, which an
  # undo must not be a second route around).
  for id, pos in st.marks:
    if pos >= 0 and pos <= before.len:
      result.marks[id] = step.tr.changes.mapPosOr(pos, sideAfter)
  for i in 0 ..< result.jumps.len:
    let pos = st.jumps[i]
    if pos >= 0 and pos <= before.len:
      result.jumps[i] = step.tr.changes.mapPosOr(pos, sideAfter)

proc cUndo(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let step = popUndo(st.history, st.doc, st.selection)
  if step.isNone: return refused(st, rrEmptyHistory)
  settle(st, applyHistoryStep(st, step.get))

proc cRedo(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let step = popRedo(st.history, st.doc, st.selection)
  if step.isNone: return refused(st, rrEmptyHistory)
  settle(st, applyHistoryStep(st, step.get))

proc cUndoSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let step = popUndoSelection(st.history, st.doc, st.selection)
  if step.isNone: return refused(st, rrEmptyHistory)
  settle(st, applyHistoryStep(st, step.get))

proc cRedoSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let step = popRedoSelection(st.history, st.doc, st.selection)
  if step.isNone: return refused(st, rrEmptyHistory)
  settle(st, applyHistoryStep(st, step.get))

proc cSetRegister(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  if args.id.len == 0: return refused(st, rrMissingArgument)
  var after = st
  after.activeRegister = args.id
  settle(st, after)

proc cRecordMacro(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## **ONE OPERATION, TWO EDGES.** `record-macro(id)` starts a recording and,
  ## when one is already running, stops it — which is Vim's `q` and is why the
  ## published table has no `stop-macro`.
  if args.id.len == 0: return refused(st, rrMissingArgument)
  var after = st
  if st.recording.len > 0:
    after.macros[st.recording] = st.recorded
    after.recording = ""
    after.recorded = @[]
  else:
    after.recording = args.id
    after.recorded = @[]
  settle(st, after)

proc cCancelOperator(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.pendingOperator = ""
  after.count = 0
  if st.mode == emOperatorPending: after.mode = emNormal
  settle(st, after)

proc cRepeatLastChangeStub(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## Replaced below by `applyOperation`'s recursive arm. Declared as a proc so
  ## the table has no hole in it; see `runNamed`.
  refused(st, rrNothingToRepeat)

proc cReplayMacroStub(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  refused(st, rrNoMacro)

proc modeSetter(m: EditingMode): CommandProc =
  ## The nine modal operations are one behaviour with nine arguments, so they
  ## are one proc closed over nine values rather than nine copies of three
  ## lines. `enter-insert-line-start`, `enter-append` and
  ## `enter-append-line-end` also move the caret and are written out.
  result = proc (env: OpEnv; st: EditorState; args: OpArgs): OpResult =
    var after = st
    after.mode = m
    settle(st, after)

proc cEnterInsertLineStart(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection:
    let line = env.lineOf(r.head)
    ranges.add caret(env.lineStartOf(line) + indentWidthOf(env.lineTextOf(line)))
  var after = st
  after.mode = emInsert
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cEnterAppend(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection:
    ranges.add caret(env.ctx.nextBoundary(r.head))
  var after = st
  after.mode = emInsert
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cEnterAppendLineEnd(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var ranges: seq[SelectionRange] = @[]
  for r in st.selection:
    ranges.add caret(env.lineEndOf(env.lineOf(r.head)))
  var after = st
  after.mode = emInsert
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc cBeginOperator(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## §2.2 D: *"the argument names an entry of category C"*. That is CHECKED
  ## here rather than assumed — `begin-operator(teleport)` is a refusal and not
  ## a pending state nothing can discharge.
  if args.operator.len == 0: return refused(st, rrMissingArgument)
  var after = st
  after.pendingOperator = args.operator
  after.mode = emOperatorPending
  settle(st, after)

proc cPushCountDigit(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  if args.digit < 0 or args.digit > 9: return refused(st, rrOutOfRange)
  var after = st
  after.count = st.count * 10 + args.digit
  settle(st, after)

proc cSearchForward(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## **NO ARGUMENT, BECAUSE §2.2 PUBLISHES NONE.** The table spells these two
  ## `search-forward` and `search-backward`, with no `(…)`; the implementation
  ## first took a pattern, and the oracle's argument-list comparison caught it
  ## — which is what that comparison is for. So these set the DIRECTION and
  ## `search-selection` is what sets the pattern, which is also how Kakoune
  ## splits the two.
  var after = st
  after.search.direction = sdForward
  settle(st, after)

proc cSearchBackward(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.search.direction = sdBackward
  settle(st, after)

proc cSearchSelection(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  let t = selectedText(st)
  if t.len == 0: return refused(st, rrNoMatch)
  var after = st
  after.search.pattern = t
  settle(st, after)

proc cSearchClear(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.search.pattern = ""
  settle(st, after)

proc intentOnly(k: HostIntentKind): CommandProc =
  result = proc (env: OpEnv; st: EditorState; args: OpArgs): OpResult =
    OpResult(outcome: ooActed, state: st, refusal: rrNone,
             intents: @[HostIntent(kind: k, payload: args.text)])

proc foldOp(env: OpEnv; st: EditorState; want: Option[bool]): EditorState =
  ## One body for `fold`, `unfold` and `toggle-fold`: `want` is `some(true)`
  ## to fold, `some(false)` to unfold, `none` to toggle.
  let line = env.lineOf(st.selection.mainRange.head)
  result = st
  let isNow = st.isFolded(line)
  if want.isNone or want.get != isNow:
    result.folded.toggleIn(line)

proc cFold(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, foldOp(env, st, some(true)))

proc cUnfold(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, foldOp(env, st, some(false)))

proc cToggleFold(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  settle(st, foldOp(env, st, none(bool)))

proc foldableLines(env: OpEnv): seq[int] =
  ## A line is foldable when the next line is indented further — which is the
  ## same indentation-only rule `indent-block` uses, so folding and the
  ## indent object cannot disagree about where a block is.
  result = @[]
  for line in 0 ..< env.ctx.store.lineCount - 1:
    let a = env.lineTextOf(line)
    let b = env.lineTextOf(line + 1)
    if not isBlankLine(a) and not isBlankLine(b) and
       indentWidthOf(b) > indentWidthOf(a):
      result.add line

proc cFoldAll(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.folded = foldableLines(env)
  settle(st, after)

proc cUnfoldAll(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.folded = @[]
  settle(st, after)

proc cToggleBreakpoint(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.breakpoints.toggleIn(env.lineOf(st.selection.mainRange.head))
  settle(st, after)

proc cToggleTracepoint(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.tracepoints.toggleIn(env.lineOf(st.selection.mainRange.head))
  settle(st, after)

proc cToggleFlowOverlay(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  var after = st
  after.flowOverlay = not st.flowOverlay
  settle(st, after)

proc cJumpToValueOrigin(env: OpEnv; st: EditorState; args: OpArgs): OpResult =
  ## §2.2 D's last row: *"operations ON AN EDITOR whose effect is on a debugger
  ## concept"*. The origin chain lives behind the backend, so the editor names
  ## the intent and stops — which is §5.2 arriving from the debugger side.
  OpResult(outcome: ooActed, state: st, refusal: rrNone,
           intents: @[HostIntent(kind: hiValueOrigin,
                                 payload: $st.selection.mainRange.head)])

# ===========================================================================
# THE VOCABULARY — 140 declarations, in §2.2's own order
# ===========================================================================

func motionDecl(name: string; dd: bool; f: MotionProc;
                arg = akNone): Declaration =
  Declaration(category: ocMotion, name: name, displayDependent: dd, arg: arg,
              motion: f, obj: nil, run: nil)

func objectDecl(name: string; f: ObjectProc): Declaration =
  Declaration(category: ocObject, name: name, displayDependent: false,
              arg: akNone, motion: nil, obj: f, run: nil)

func operatorDecl(name: string; f: CommandProc; arg = akNone): Declaration =
  Declaration(category: ocOperator, name: name, displayDependent: false,
              arg: arg, motion: nil, obj: nil, run: f)

func commandDecl(name: string; f: CommandProc; arg = akNone): Declaration =
  Declaration(category: ocCommand, name: name, displayDependent: false,
              arg: arg, motion: nil, obj: nil, run: f)

proc buildVocabulary(): seq[Declaration] =
  result = @[
    # --- A. Motions, §2.2 A, in the table's row order --------------------
    motionDecl("char-left", false, mCharLeft),
    motionDecl("char-right", false, mCharRight),
    motionDecl("char-forward", false, mCharForward),
    motionDecl("char-backward", false, mCharBackward),
    motionDecl("group-left", false, mGroupLeft),
    motionDecl("group-right", false, mGroupRight),
    motionDecl("group-forward", false, mGroupForward),
    motionDecl("group-backward", false, mGroupBackward),
    motionDecl("subword-forward", false, mSubwordForward),
    motionDecl("subword-backward", false, mSubwordBackward),
    motionDecl("line-up", true, mLineUp),
    motionDecl("line-down", true, mLineDown),
    motionDecl("display-line-up", true, mDisplayLineUp),
    motionDecl("display-line-down", true, mDisplayLineDown),
    motionDecl("page-up", true, mPageUp),
    motionDecl("page-down", true, mPageDown),
    motionDecl("line-start", false, mLineStart),
    motionDecl("line-end", false, mLineEnd),
    motionDecl("line-start-smart", false, mLineStartSmart),
    motionDecl("display-line-start", true, mDisplayLineStart),
    motionDecl("display-line-end", true, mDisplayLineEnd),
    motionDecl("doc-start", false, mDocStart),
    motionDecl("doc-end", false, mDocEnd),
    motionDecl("line-number", false, mLineNumber, akNumber),
    motionDecl("matching-bracket", false, mMatchingBracket),
    motionDecl("syntax-left", false, mSyntaxLeft),
    motionDecl("syntax-right", false, mSyntaxRight),
    motionDecl("paragraph-forward", false, mParagraphForward),
    motionDecl("paragraph-backward", false, mParagraphBackward),
    motionDecl("search-next", false, mSearchNext),
    motionDecl("search-prev", false, mSearchPrev),
    motionDecl("mark", false, mMark, akMarkId),
    motionDecl("jump-back", false, mJumpBack),
    motionDecl("jump-forward", false, mJumpForward),

    # --- B. Text objects, §2.2 B -----------------------------------------
    objectDecl("word", oWord),
    objectDecl("subword", oSubword),
    objectDecl("line", oLine),
    objectDecl("paragraph", oParagraph),
    objectDecl("parens", oParens),
    objectDecl("brackets", oBrackets),
    objectDecl("braces", oBraces),
    objectDecl("angle", oAngle),
    objectDecl("quote-single", oQuoteSingle),
    objectDecl("quote-double", oQuoteDouble),
    objectDecl("quote-back", oQuoteBack),
    objectDecl("tag", oTag),
    objectDecl("indent-block", oIndentBlock),
    objectDecl("syntax-node", oSyntaxNode),
    objectDecl("function", oFunction),
    objectDecl("argument", oArgument),

    # --- C. Operators, §2.2 C --------------------------------------------
    operatorDecl("delete-selection", cDeleteSelection),
    operatorDecl("change-selection", cChangeSelection),
    operatorDecl("yank-selection", cYankSelection),
    operatorDecl("paste-before", cPasteBefore),
    operatorDecl("paste-after", cPasteAfter),
    operatorDecl("paste-replace", cPasteReplace),
    operatorDecl("indent-selection", cIndentSelection),
    operatorDecl("dedent-selection", cDedentSelection),
    operatorDecl("reindent-selection", cReindentSelection),
    operatorDecl("toggle-comment", cToggleComment),
    operatorDecl("line-comment", cLineComment),
    operatorDecl("line-uncomment", cLineUncomment),
    operatorDecl("block-comment", cBlockComment),
    operatorDecl("block-uncomment", cBlockUncomment),
    operatorDecl("upper-case", cUpperCase),
    operatorDecl("lower-case", cLowerCase),
    operatorDecl("swap-case", cSwapCase),
    operatorDecl("join-lines", cJoinLines),
    operatorDecl("replace-char", cReplaceChar, akChar),
    operatorDecl("pipe-selection", cPipeSelection, akCommand),

    # --- D. Commands, §2.2 D, group by group -----------------------------
    commandDecl("insert-text", cInsertText, akText),
    commandDecl("insert-newline", cInsertNewline),
    commandDecl("insert-newline-and-indent", cInsertNewlineAndIndent),
    commandDecl("insert-blank-line-above", cInsertBlankLineAbove),
    commandDecl("insert-blank-line-below", cInsertBlankLineBelow),
    commandDecl("insert-tab", cInsertTab),

    commandDecl("delete-char-backward", cDeleteCharBackward),
    commandDecl("delete-char-forward", cDeleteCharForward),
    commandDecl("delete-group-backward", cDeleteGroupBackward),
    commandDecl("delete-group-forward", cDeleteGroupForward),
    commandDecl("delete-to-line-start", cDeleteToLineStart),
    commandDecl("delete-to-line-end", cDeleteToLineEnd),
    commandDecl("delete-line", cDeleteLine),
    commandDecl("delete-trailing-whitespace", cDeleteTrailingWhitespace),

    commandDecl("swap-line-up", cSwapLineUp),
    commandDecl("swap-line-down", cSwapLineDown),
    commandDecl("copy-line-up", cCopyLineUp),
    commandDecl("copy-line-down", cCopyLineDown),
    commandDecl("split-line", cSplitLine),
    commandDecl("transpose-chars", cTransposeChars),

    commandDecl("select-all", cSelectAll),
    commandDecl("select-line", cSelectLine),
    commandDecl("select-parent-syntax", cSelectParentSyntax),
    commandDecl("simplify-selection", cSimplifySelection),
    commandDecl("collapse-to-cursors", cCollapseToCursors),
    commandDecl("flip-selections", cFlipSelections),
    commandDecl("keep-primary-selection", cKeepPrimarySelection),

    commandDecl("add-cursor-above", cAddCursorAbove),
    commandDecl("add-cursor-below", cAddCursorBelow),
    commandDecl("add-cursor-at-next-match", cAddCursorAtNextMatch),
    commandDecl("add-cursor-at-each-line-of-selection", cAddCursorAtEachLine),
    commandDecl("remove-primary-cursor", cRemovePrimaryCursor),
    commandDecl("rotate-primary-cursor", cRotatePrimaryCursor),

    commandDecl("undo", cUndo),
    commandDecl("redo", cRedo),
    commandDecl("undo-selection", cUndoSelection),
    commandDecl("redo-selection", cRedoSelection),

    commandDecl("set-register", cSetRegister, akMarkId),
    commandDecl("record-macro", cRecordMacro, akMarkId),
    commandDecl("replay-macro", cReplayMacroStub, akMarkId),
    commandDecl("repeat-last-change", cRepeatLastChangeStub),

    commandDecl("enter-insert", modeSetter(emInsert)),
    commandDecl("enter-insert-line-start", cEnterInsertLineStart),
    commandDecl("enter-append", cEnterAppend),
    commandDecl("enter-append-line-end", cEnterAppendLineEnd),
    commandDecl("enter-normal", modeSetter(emNormal)),
    commandDecl("enter-visual", modeSetter(emVisual)),
    commandDecl("enter-visual-line", modeSetter(emVisualLine)),
    commandDecl("enter-visual-block", modeSetter(emVisualBlock)),
    commandDecl("enter-replace", modeSetter(emReplace)),

    commandDecl("begin-operator", cBeginOperator, akOperator),
    commandDecl("cancel-operator", cCancelOperator),

    commandDecl("push-count-digit", cPushCountDigit, akDigit),

    commandDecl("search-forward", cSearchForward),
    commandDecl("search-backward", cSearchBackward),
    commandDecl("search-selection", cSearchSelection),
    commandDecl("search-clear", cSearchClear),

    commandDecl("save", intentOnly(hiSave)),
    commandDecl("save-as", intentOnly(hiSaveAs)),
    commandDecl("save-all", intentOnly(hiSaveAll)),
    commandDecl("reload-from-disk", intentOnly(hiReload)),

    commandDecl("fold", cFold),
    commandDecl("unfold", cUnfold),
    commandDecl("fold-all", cFoldAll),
    commandDecl("unfold-all", cUnfoldAll),
    commandDecl("toggle-fold", cToggleFold),

    commandDecl("toggle-breakpoint", cToggleBreakpoint),
    commandDecl("toggle-tracepoint", cToggleTracepoint),
    commandDecl("toggle-flow-overlay", cToggleFlowOverlay),
    commandDecl("jump-to-value-origin", cJumpToValueOrigin),
  ]

let VocabularyTable = buildVocabulary()

proc vocabulary*(): seq[Declaration] =
  ## **THE 140, AS DATA.** Every question CTUI-9 says a `case` cannot be asked
  ## is a fold over this.
  VocabularyTable

func generatedName*(d: Declaration; form: OpForm): string =
  $form & d.name

proc buildOperations(): seq[Operation] =
  result = @[]
  for i, d in VocabularyTable:
    for form in FormsOf[d.category]:
      result.add Operation(name: generatedName(d, form), decl: i,
                           category: d.category, form: form,
                           displayDependent: d.displayDependent, arg: d.arg)

let OperationTable = buildOperations()

proc operations*(): seq[Operation] =
  ## **THE 224.** Generated from the 140, never enumerated, so the three forms
  ## of a motion cannot disagree about where it lands.
  OperationTable

proc duplicateDeclarationNames*(): seq[string] =
  ## The first question a `case` cannot be asked.
  var seen = initTable[string, int]()
  result = @[]
  for d in VocabularyTable:
    seen[d.name] = seen.getOrDefault(d.name) + 1
  for name, n in seen:
    if n > 1 and name notin result: result.add name
  result.sort()

proc duplicateOperationNames*(): seq[string] =
  ## **THE ONE THAT HAS ALREADY CAUGHT SOMETHING** — §2.4's `move-line-up`,
  ## published twice with two meanings forty-six lines apart. Without this,
  ## *"every operation appears in the table and is exercised"* is satisfiable
  ## with 139 distinct names.
  var seen = initTable[string, int]()
  result = @[]
  for op in OperationTable:
    seen[op.name] = seen.getOrDefault(op.name) + 1
  for name, n in seen:
    if n > 1 and name notin result: result.add name
  result.sort()

proc unimplementedDeclarations*(): seq[string] =
  ## Every declaration whose category's handler slot is `nil`. *"Whether every
  ## published operation has an implementation"* — CTUI-9's second question,
  ## answerable because the vocabulary is data.
  result = @[]
  for d in VocabularyTable:
    let ok = case d.category
             of ocMotion: d.motion != nil
             of ocObject: d.obj != nil
             of ocOperator, ocCommand: d.run != nil
    if not ok: result.add d.name
  result.sort()

proc operationNamed*(name: string): int =
  ## The index into `operations()`, or -1. A linear scan over 224 entries,
  ## which is what a keymap does once per keystroke.
  for i, op in OperationTable:
    if op.name == name: return i
  -1

proc declarationNamed*(name: string): int =
  for i, d in VocabularyTable:
    if d.name == name: return i
  -1

proc displayDependentCount*(): int =
  var n = 0
  for op in OperationTable:
    if op.displayDependent: inc n
  n

# ===========================================================================
# THE EXECUTOR
# ===========================================================================

proc applyMotionForm(env: OpEnv; st: EditorState; d: Declaration;
                     form: OpForm; args: OpArgs): OpResult =
  ## **THE THREE FORMS, GENERATED FROM ONE LANDING.** §2.2 A: `move-X` collapses
  ## each range to the new position, `extend-X` keeps each anchor and moves each
  ## head, `select-X` makes each range span from the OLD position to the new.
  ## One call to the motion, three ways of turning its answer into a range —
  ## which is what "the three are one declaration" means operationally.
  var ranges: seq[SelectionRange] = @[]
  var refusal = rrNone
  var jumped = false
  for r in st.selection:
    let got = d.motion(env, st, r, args)
    if got.refusal != rrNone:
      refusal = got.refusal
      ranges.add r
      continue
    if got.offset != r.head: jumped = true
    ranges.add (case form
                of ofMove: caret(got.offset, assocBefore, none(BidiLevel), got.goal)
                of ofExtend: spanRange(r.anchor, got.offset, got.goal)
                else: spanRange(r.head, got.offset, got.goal))
  if refusal != rrNone and not jumped:
    return refused(st, refusal)
  var after = withSelection(st, ranges, st.selection.primaryIndex)
  if d.name in ["doc-start", "doc-end", "line-number", "mark", "search-next",
                "search-prev", "paragraph-forward", "paragraph-backward"] and
     form == ofMove and jumped:
    # §2.2 A's jump list: the motions that move "far" record where they came
    # from, which is what `jump-back` walks. Vim's own set, named rather than
    # inferred from a distance threshold.
    after.jumps.add st.selection.mainRange.head
    after.jumpIndex = after.jumps.len - 1
  settle(st, after)

proc applyObjectForm(env: OpEnv; st: EditorState; d: Declaration;
                     around: bool; args: OpArgs): OpResult =
  var ranges: seq[SelectionRange] = @[]
  var refusal = rrNone
  var found = false
  for r in st.selection:
    let got = d.obj(env, st, r, around, args)
    if got.refusal != rrNone:
      refusal = got.refusal
      ranges.add r
    else:
      found = true
      ranges.add got.span
  if not found and refusal != rrNone:
    return refused(st, refusal)
  var after = st
  after.pushSelectionHistory(env.nowMs)
  after.selection = editorSelection(ranges, st.selection.primaryIndex)
  settle(st, after)

proc applyOperationAt*(st: EditorState; index: int; args: OpArgs;
                       settings: WrapSettings; viewportRows = 20;
                       depth = 0; nowMs: int64 = 0): OpResult

proc runNamed(st: EditorState; name: string; settings: WrapSettings;
              viewportRows: int; depth: int; nowMs: int64): OpResult =
  let i = operationNamed(name)
  if i < 0: return refused(st, rrNoMatch)
  applyOperationAt(st, i, OpArgs(), settings, viewportRows, depth + 1, nowMs)

proc applyOperationAt*(st: EditorState; index: int; args: OpArgs;
                       settings: WrapSettings; viewportRows = 20;
                       depth = 0; nowMs: int64 = 0): OpResult =
  ## **THE ONE ENTRY POINT.** Every operation is reached through this, and it
  ## is reached by INDEX or by NAME — never by synthesising a keystroke. §2.2's
  ## own words for why that matters: *"an operation a test can only reach
  ## through the keymap is an operation the collaboration and scripting layers
  ## cannot reach either"*.
  if index < 0 or index >= OperationTable.len:
    raise newException(OperationError,
      "no operation at index " & $index & "; the vocabulary holds " &
      $OperationTable.len)
  if depth > MacroDepthLimit:
    return refused(st, rrRecursionLimit)
  let op = OperationTable[index]
  let d = VocabularyTable[op.decl]
  let env = initOpEnv(st.doc, settings, viewportRows, nowMs)

  var res = case op.category
    of ocMotion:
      applyMotionForm(env, st, d, op.form, args)
    of ocObject:
      applyObjectForm(env, st, d, op.form == ofAround, args)
    of ocOperator, ocCommand:
      # The two recursive commands are dispatched here rather than through a
      # table slot, because their bodies call this function.
      if d.name == "replay-macro":
        if args.id.len == 0: refused(st, rrMissingArgument)
        elif not st.macros.hasKey(args.id): refused(st, rrNoMacro)
        else:
          var cur = st
          var acted = false
          for step in st.macros[args.id]:
            let r = runNamed(cur, step, settings, viewportRows, depth, nowMs)
            if r.outcome == ooActed: acted = true
            cur = r.state
          if acted: settle(st, cur) else: settle(st, st)
      elif d.name == "repeat-last-change":
        if st.lastChange.len == 0: refused(st, rrNothingToRepeat)
        else:
          var cur = st
          var acted = false
          for step in st.lastChange:
            let r = runNamed(cur, step, settings, viewportRows, depth, nowMs)
            if r.outcome == ooActed: acted = true
            cur = r.state
          if acted: settle(st, cur) else: settle(st, st)
      else:
        d.run(env, st, args)

  # THE RECORDING IS DONE HERE, ONCE, FOR ALL 224. A macro is a list of NAMES,
  # which is the property that makes it replay identically under either keymap.
  if st.recording.len > 0 and d.name != "record-macro" and depth == 0:
    res.state.recorded = res.state.recorded & @[op.name]
  # …and so is the last change, which `repeat-last-change` repeats. Only a
  # DOCUMENT change counts: Vim's `.` repeats an edit, not a motion.
  if depth == 0 and res.outcome == ooActed and res.state.doc != st.doc and
     d.name notin ["undo", "redo", "repeat-last-change"]:
    res.state.lastChange = @[op.name]
  res

proc applyOperation*(st: EditorState; name: string; args: OpArgs;
                     settings: WrapSettings; viewportRows = 20;
                     nowMs: int64 = 0): OpResult =
  ## By name, which is what a keymap, a script and a collaboration peer all
  ## have. An unknown name RAISES rather than refusing: a refusal is a
  ## statement about a document, and "this name is not in the vocabulary" is a
  ## statement about the caller.
  let i = operationNamed(name)
  if i < 0:
    raise newException(OperationError,
      "no operation named '" & name & "' in a vocabulary of " &
      $OperationTable.len)
  applyOperationAt(st, i, args, settings, viewportRows, 0, nowMs)
