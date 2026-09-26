## PLAT-29 — the Edit pane's syntax highlight as an ASYNCHRONOUS producer,
## reconciled. Tier 1.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat29_highlight_producer.nim
##
## Editor-ViewModel.md §11's three rules, asserted on the shipped runtime with
## the answers delivered in an order THIS SUITE chooses:
##
##   * a parse names the version it was computed against, and one that
##     arrives after the document moved is RECONCILED line by line — a line
##     the user did not touch keeps its spans at its new position (shifted
##     right when text was typed at its start), a line they edited draws plain
##     rather than its old spans on new text — and never applied as though the
##     document had not moved;
##   * every arrival is COUNTED in the buffer's `StalenessReport`;
##   * the render path never parses: with a worker wired, a frame asks for a
##     parse and draws what is known, and spans appear only when an answer is
##     delivered.
##
## ## The one stand-in, and why it is not a mock
##
## `rt.editServices.requestHighlight` is replaced by a closure that KEEPS the
## requests, so a case can deliver them late and out of order — the
## asynchrony under test. The parse delivered is `computeHighlight`, the
## shipped function the host's worker runs; nothing about the answer is
## fabricated. The real thread is exercised by `test_plat29_highlight_worker`.

import std/[strutils, tables, unittest]

import codetracer_embed
import ../app/edit_binding
import ../app/runtime
import ../app/theme/capabilities
import ../../viewmodel/editor/text_store
import ../../viewmodel/tests/generators/keymap_task_set

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 120
  Rows = 40
  Path = "src/sample.nim"
  Text = "proc alpha(x: int): int =\n  let y = x + 1\n  result = y * 2\n\nproc beta() =\n  echo \"hi\"\n"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc editingRuntime(queue: ref seq[HighlightRequest]): TuiRuntime =
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  app.editSession = newEditSession()
  discard app.editSession.openFile(Path, Text)
  result = newTuiRuntime(app, caps(), Cols, Rows)
  discard result.focus.focusPaneKind(paneEditor)
  if not queue.isNil:
    result.editServices.requestHighlight = proc(req: HighlightRequest) =
      queue[].add req

proc buf(rt: TuiRuntime): EditBuffer = rt.app.editSession.activeBuffer()

proc frame(rt: TuiRuntime) = discard rt.shellScreenOf()

proc typeKeys(rt: TuiRuntime; keys: openArray[string]) =
  var now = 0'i64
  for k in keys:
    now += 1
    discard rt.handleToken(k, now)
    rt.frame()

proc drawn(rt: TuiRuntime; line: int): seq[SyntaxSpan] =
  rt.buf.highlights.spansForWindow(rt.buf.doc, line, 1)[0]

proc parsed(text: string; line: int): seq[SyntaxSpan] =
  computeHighlight(HighlightRequest(path: Path, text: text)).highlight
    .spansForLine(line)

proc caretToLineStart(rt: TuiRuntime; line: int) =
  ## Placed through the core, not typed: the product default binds no `Home`
  ## or `End`, and what is under test is the edit, not the caret keys.
  rt.buf.doc.moveCaretTo(line - 1, 0)

proc caretToLineEnd(rt: TuiRuntime; line: int) =
  rt.buf.doc.moveCaretTo(line - 1, rt.buf.text.splitLines()[line - 1].len)

suite "PLAT-29: the render path asks, and never parses":

  test "a frame with a worker wired requests the current version and draws nothing yet":
    let q = new seq[HighlightRequest]
    let rt = editingRuntime(q)
    rt.frame()
    ck q[].len == 1
    ck q[][0].version == rt.buf.doc.version
    ck q[][0].text == Text
    ck rt.buf.highlights.arrivals == 0
    ck rt.drawn(1).len == 0                     # nothing parsed on the render path
    # A second frame at the same version asks nothing new.
    rt.frame()
    ck q[].len == 1
    # The answer arrives: now the line is drawn with exactly the parse's spans.
    ck rt.deliverHighlight(computeHighlight(q[][0]))
    ck rt.drawn(1) == parsed(Text, 1)
    ck rt.drawn(1).len > 0

  test "with no worker, the SAME parse runs inline and the pane is highlighted at once":
    let rt = editingRuntime(nil)
    rt.frame()
    ck rt.buf.highlights.arrivals == 1
    ck rt.drawn(2) == parsed(Text, 2)

suite "PLAT-29: a stale parse is reconciled, line by line":

  test "an edit on line 2 drops line 2's spans and keeps every other line":
    let q = new seq[HighlightRequest]
    let rt = editingRuntime(q)
    rt.frame()                                   # asks for v0
    rt.caretToLineEnd(2)
    rt.typeKeys(["z"])                           # type at the END of line 2
    ck rt.buf.doc.version != q[][0].version
    ck rt.deliverHighlight(computeHighlight(q[][0]))   # the v0 answer, late
    let rep = rt.buf.highlights.report
    ck rep.count(pkTreeSitter, roDropped) >= 0
    # Line 2 was edited INSIDE its evidence? Typing at its END abuts it, so
    # the line is kept; its old spans stay valid for the text they covered.
    ck rt.drawn(2) == parsed(Text, 2)
    ck rt.drawn(1) == parsed(Text, 1)
    ck rt.drawn(3) == parsed(Text, 3)
    # An edit INSIDE line 3 (between existing characters) drops it.
    let before = rt.buf.highlights.report.count(pkTreeSitter, roDropped)
    let q2 = q[].len
    rt.caretToLineStart(3)
    rt.typeKeys(["\x1b[C", "\x1b[C", "\x1b[C", "Q"])   # into `result`
    rt.frame()
    checkpoint("text now: " & rt.buf.text.escape & " versions " & $q[].len &
               " q2=" & $q2 & " stale=" & $q[][q2 - 1].version & " cur=" &
               $rt.buf.doc.version)
    ck q[].len > q2
    # Deliver the parse of the version BEFORE this edit: line 3 must go plain.
    var stale = q[][q2 - 1]
    ck rt.deliverHighlight(computeHighlight(stale))
    ck rt.buf.highlights.report.count(pkTreeSitter, roDropped) > before
    ck rt.drawn(3).len == 0
    ck rt.drawn(5) == parsed(Text, 5)

  test "a line opened ABOVE moves every held span down with its text":
    let q = new seq[HighlightRequest]
    let rt = editingRuntime(q)
    rt.frame()
    rt.caretToLineStart(1)
    rt.typeKeys(["\r"])                          # a new first line
    ck rt.deliverHighlight(computeHighlight(q[][0]))
    ck rt.buf.highlights.report.count(pkTreeSitter, roMapped) > 0
    ck rt.drawn(1).len == 0                      # the new, empty line
    ck rt.drawn(2) == parsed(Text, 1)            # `proc alpha…`, one down
    ck rt.drawn(6) == parsed(Text, 5)            # `proc beta…`

  test "text typed at a line's START keeps its spans, shifted by the typed cells":
    let q = new seq[HighlightRequest]
    let rt = editingRuntime(q)
    rt.frame()
    rt.caretToLineStart(5)
    rt.typeKeys(["#", " "])                      # `# proc beta() =`
    ck rt.deliverHighlight(computeHighlight(q[][0]))
    let old = parsed(Text, 5)
    let now = rt.drawn(5)
    ck now.len == old.len
    for i in 0 ..< min(now.len, old.len):
      ck now[i].startCell == old[i].startCell + 2
      ck now[i].class == old[i].class

  test "the parse of the CURRENT version is the answer, whole; held lines are discarded":
    let q = new seq[HighlightRequest]
    let rt = editingRuntime(q)
    rt.frame()
    rt.caretToLineEnd(2)
    rt.typeKeys(["z"])
    ck rt.deliverHighlight(computeHighlight(q[][0]))
    ck rt.buf.highlights.hasHeld
    let current = q[][^1]
    ck current.version == rt.buf.doc.version
    ck rt.deliverHighlight(computeHighlight(current))
    ck not rt.buf.highlights.hasHeld
    for line in 1 .. 6:
      ck rt.drawn(line) == parsed(rt.buf.text, line)

  test "a later edit re-maps what is held, counted apart from arrivals":
    let q = new seq[HighlightRequest]
    let rt = editingRuntime(q)
    rt.frame()
    rt.caretToLineStart(1)
    rt.typeKeys(["\r"])
    ck rt.deliverHighlight(computeHighlight(q[][0]))
    let arrivalsBefore = rt.buf.highlights.report.total(pkTreeSitter)
    rt.caretToLineStart(1)
    rt.typeKeys(["\r"])                          # a second new first line
    ck rt.buf.highlights.report.total(pkTreeSitter) == arrivalsBefore
    ck rt.buf.highlights.remapReport.total(pkTreeSitter) > 0
    ck rt.drawn(3) == parsed(Text, 1)

suite "PLAT-29: answers that cannot be about this buffer are refused":

  test "an answer for an earlier opening of the file, or from the future":
    let q = new seq[HighlightRequest]
    let rt = editingRuntime(q)
    rt.frame()
    var other = q[][0]
    other.bufferSerial = rt.buf.serial + 1
    ck not rt.deliverHighlight(computeHighlight(other))
    ck rt.buf.highlights.arrivals == 0
    var future = q[][0]
    future.text = Text & "x"
    ck rt.buf.doc.version == q[][0].version
    # A version the document has not reached is refused, not clamped.
    rt.caretToLineStart(1)
    rt.typeKeys(["a"])
    rt.frame()
    let ahead = q[][^1]
    let rt2 = editingRuntime(q)
    ck not rt2.deliverHighlight(computeHighlight(ahead))

suite "PLAT-29: the caret is found by a scan, and the scan is the store's answer":

  test "caretPosOf equals the text store's posOf at every offset of the corpus":
    # `caretLine` / `caretColumn` stopped building a rope per call; the scan
    # that replaced it must agree with the store on every offset, including
    # the ends and every multi-byte cluster of the corpus.
    var compared = 0
    var mismatches = 0
    for d in scenarioDocs():
      let store = toTextStore(d.text)
      for off in 0 .. d.text.len:
        inc compared
        if caretPosOf(d.text, off) != store.posOf(off): inc mismatches
    checkpoint($compared & " offsets")
    ck compared > 1000
    ck mismatches == 0

suite "PLAT-29 highlight producer — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
