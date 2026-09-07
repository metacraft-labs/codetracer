## view_vocabulary_test.nim — PLAT-3's contract suite for the vocabulary
## itself: the closed set, the keyboard contract, the state machine, the
## portability check, the admission test and the three mapping tables.
##
## ## NO MOCKS
##
## There is no mock in this file and none is justified, because there is
## nothing to mock. `common/view_vocabulary/` imports `std/strutils`,
## `std/tables`, `std/unicode` and `common/value_presentation/vocabulary`, and
## nothing else. Every `ViewNode` below is DATA — the same object a binding
## renders — not a stand-in for a collaborator.
##
## The RENDERED half of PLAT-3's tests is
## `src/frontend/tui/tests/test_view_vocabulary_cross_medium.nim`, which
## renders one view onto isonim-tui's real widgets and onto DOM elements and
## drives both with keys. Both are required: this one can reach states no
## binding produces (a pointer-only node, a ragged table), and that one can
## prove a real widget honours the contract, which no constructed node can.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## Every assertion goes through `ck`, and the last case asserts the tally
## against a number written from a run. A branch that returned early, a loop
## that skipped an entry, or a `continue` that dropped a case cannot reach the
## end of this file with the right count.
##
## ## THE ONE ARM THAT MAY NOT RUN, AND HOW IT SAYS SO
##
## "the GPUI tag map is a faithful copy" reads `isonim-gpui`'s own source.
## `isonim-gpui` is an ADVISORY sibling of this repository
## (`scripts/require-siblings.sh`) and — measured, in
## `.github/actions/provision-repro-lock-siblings/action.yml` — is provisioned
## by NO CI job. So the arm is two-armed rather than skipped: it says NOT RUN
## by name, and the assertion tally has a declared value for each arm, so a
## silently smaller run is still caught. That is the same shape
## `value-presentation-boundary-test.sh` uses for its `nim check` arm.

import std/[os, strutils, unittest]

import view_vocabulary

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  ExpectedAssertionsWithGpui = 707
  ExpectedAssertionsWithoutGpui = 636
    ## Both written from a run. See the final case.
    ##
    ## The difference is 71: the GPUI arm contributes 72 assertions when it
    ## runs (a length check, an equality against the copy, and 35 in each
    ## direction over the tag set) and 1 when it does not.

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc opt(id, label: string; disabled = false): ViewOption =
  ViewOption(id: id, label: label, disabled: disabled)

proc smallTree(): ViewNode =
  viewTreeNode("root", "locals", @[
    viewTreeNode("x", "x"),
    viewTreeNode("p", "p", @[viewTreeNode("p.y", "y")]),
    viewTreeNode("z", "z")], expanded = true)

# ---------------------------------------------------------------------------

suite "PLAT-3: the vocabulary is closed, and it is PLAT-2's enum extended":

  test "sixteen entries, spelled the way PLAT-3 spells them":
    const Plat3Vocabulary = ["Text", "Button", "Checkbox", "Toggle", "Input",
      "Select", "List", "Tree", "Table", "Tabs", "Collapsible", "Modal",
      "Menu", "ProgressIndicator", "Image", "Markdown"]
    var seen = 0
    for k in ViewKind:
      ck vocabularyName(k) in Plat3Vocabulary
      inc seen
    # THE COUNT, not "at least one" — Verification-Harness-Traps §4b. PLAT-2's
    # own version of this case asserted `== 5`; this is the same assertion
    # after the extension, which is what makes the extension visible here
    # rather than silent.
    ck seen == 16
    ck seen == Plat3Vocabulary.len

  test "PLAT-2's five are still the same five, at the same names":
    # The extension contract PLAT-2's header wrote down: "PLAT-3 adds the
    # eleven entries this module does not name, and renames nothing". If any
    # of the five had been renamed, this file would still compile — the enum
    # is one type — and this is the case that would not.
    ck vocabularyName(pkText) == "Text"
    ck vocabularyName(pkList) == "List"
    ck vocabularyName(pkTree) == "Tree"
    ck vocabularyName(pkTable) == "Table"
    ck vocabularyName(pkImage) == "Image"

  test "twelve entries are interactive and four are readings":
    ck InteractiveKinds.card == 12
    for k in ViewKind:
      ck (k in InteractiveKinds) == (keyContract(k).len > 0)
    ck pkText notin InteractiveKinds
    ck pkImage notin InteractiveKinds
    ck pkMarkdown notin InteractiveKinds
    ck pkProgressIndicator notin InteractiveKinds

  test "the vocabulary's own invariants hold":
    let problems = vocabularyInvariants()
    if problems.len > 0:
      checkpoint problems.join("\n")
    ck problems.len == 0

suite "PLAT-3: the keyboard contract":

  test "every interactive entry answers keys, and none claims Tab":
    var bindings = 0
    for k in ViewKind:
      for b in keyContract(k):
        inc bindings
        ck b.key notin {kTab, kBackTab, kNone}
        ck b.description.len > 0
        ck b.transition != trNone
    # The fingerprint. A contract that lost a binding to an editing accident
    # would otherwise pass every assertion above it.
    ck bindings == 49

  test "answersKey agrees with the contract":
    ck answersKey(pkList, kDown)
    ck answersKey(pkList, kEnter)
    ck not answersKey(pkList, kEscape)
    ck answersKey(pkModal, kEscape)
    ck not answersKey(pkText, kEnter)

  test "PageUp and PageDown are not in the vocabulary at all":
    # A page is a viewport height, which is a layout fact and a
    # medium-dependent one. Asserted as an absence from the KEY ENUM rather
    # than from the contracts, because an entry could otherwise grow one.
    var names: seq[string] = @[]
    for k in Key: names.add $k
    ck "kPageUp" notin names
    ck "kPageDown" notin names
    ck names.len == 15

suite "PLAT-3: state transitions, per entry":

  test "Button raises activate once and a disabled one raises nothing":
    let b = viewButton("b", "Apply")
    ck applyKey(b, press(kEnter)).transition == trActivate
    ck applyKey(b, press(kSpace)).transition == trActivate
    ck applyKey(b, press(kDown)).handled == false
    let d = viewButton("d", "Apply", disabled = true)
    ck applyKey(d, press(kEnter)).handled == false

  test "Checkbox and Toggle flip, and report different transitions":
    let c = viewCheckbox("c", "wrap")
    ck applyKey(c, press(kSpace)).transition == trCheck
    ck c.checked
    ck applyKey(c, press(kSpace)).transition == trUncheck
    ck not c.checked
    let t = viewToggle("t", "live")
    # THE STATE CHANGE IS THE SAME AND THE TRANSITION IS NOT, which is the
    # whole reason they are two entries: a reader has to be able to tell "I
    # have asked for this" from "this is now so".
    ck applyKey(t, press(kSpace)).transition == trOn
    ck t.checked
    ck applyKey(t, press(kSpace)).transition == trOff

  test "Input edits at a RUNE caret, not a byte one":
    let i = viewInput("i", "naïve")
    ck i.cursor == 5
    ck applyKey(i, press(kHome)).transition == trCaretHome
    ck i.cursor == 0
    ck applyKey(i, press(kRight)).transition == trCaretRight
    ck applyKey(i, press(kRight)).transition == trCaretRight
    ck i.cursor == 2
    ck applyKey(i, typeChar('X')).transition == trInsert
    ck i.text == "naXïve"
    ck i.cursor == 3
    # Backspace over the inserted X, then over `a`, then delete forward over
    # the MULTI-BYTE `ï`. A byte-indexed implementation cuts it in half here
    # and produces invalid UTF-8; this is the case that would say so.
    ck applyKey(i, press(kBackspace)).transition == trDeleteBack
    ck i.text == "naïve"
    ck applyKey(i, press(kDelete)).transition == trDeleteForward
    ck i.text == "nave"
    ck applyKey(i, press(kEnd)).transition == trCaretEnd
    ck i.cursor == 4
    ck applyKey(i, press(kRight)).handled == false
    ck applyKey(i, press(kEnter)).transition == trSubmit

  test "Select keeps the committed choice when it is dismissed":
    let s = viewSelect("s", @[opt("a", "A"), opt("b", "B"), opt("c", "C")],
                       selected = 0)
    ck applyKey(s, press(kEnter)).transition == trOpen
    ck s.open
    ck applyKey(s, press(kDown)).transition == trHighlightNext
    ck applyKey(s, press(kDown)).transition == trHighlightNext
    ck s.highlight == 2
    ck s.selected == 0
    ck applyKey(s, press(kEscape)).transition == trDismiss
    ck not s.open
    # THE ASSERTION THIS CASE EXISTS FOR. A reader who arrowed past two
    # options and pressed Escape has not chosen either, and a Select that
    # reopened on the last one they passed over would be remembering a
    # decision they declined to make.
    ck s.selected == 0
    ck s.highlight == 0
    ck applyKey(s, press(kEnter)).transition == trOpen
    ck applyKey(s, press(kDown)).transition == trHighlightNext
    ck applyKey(s, press(kEnter)).transition == trCommit
    ck s.selected == 1
    ck not s.open

  test "List motion skips disabled members and does not wrap":
    let l = viewList("l", @[opt("a", "A"), opt("b", "B", disabled = true),
                            opt("c", "C")])
    ck l.highlight == 0
    ck applyKey(l, press(kDown)).transition == trHighlightNext
    # Landed on C, not on the disabled B — a reader holding Down through a
    # list of mostly-unavailable commands would otherwise stop at the first.
    ck l.highlight == 2
    ck applyKey(l, press(kDown)).handled == false
    ck l.highlight == 2
    ck applyKey(l, press(kHome)).transition == trHighlightFirst
    ck l.highlight == 0
    ck applyKey(l, press(kEnd)).transition == trHighlightLast
    ck l.highlight == 2
    ck applyKey(l, press(kEnter)).transition == trActivate

  test "Tree cursor indexes the visible rows, and Right descends when open":
    let t = smallTree()
    ck visibleRows(t).len == 4
    ck applyKey(t, press(kDown)).transition == trCursorNext
    ck applyKey(t, press(kDown)).transition == trCursorNext
    ck t.cursor == 2
    ck applyKey(t, press(kRight)).transition == trExpand
    ck visibleRows(t).len == 5
    ck applyKey(t, press(kRight)).transition == trCursorNext
    ck t.cursor == 3
    ck applyKey(t, press(kLeft)).transition == trCursorPrev
    ck t.cursor == 2
    ck applyKey(t, press(kLeft)).transition == trCollapse
    ck visibleRows(t).len == 4
    ck applyKey(t, press(kEnd)).transition == trCursorLast
    ck t.cursor == 3
    ck applyKey(t, press(kHome)).transition == trCursorFirst
    ck t.cursor == 0

  test "a collapse that strands the cursor is reseated":
    let t = smallTree()
    t.children[1].expanded = true
    t.cursor = 4
    ck visibleRows(t).len == 5
    t.children[1].expanded = false
    # WITHOUT `reseatCursorAfterCollapse` the cursor names row 4 of a
    # four-row tree, which no medium can draw. A "collapse all" command has
    # exactly this problem and does not go through the Left key.
    reseatCursorAfterCollapse(t)
    ck t.cursor == 3
    ck visibleRows(t).len == 4

  test "Table moves in two dimensions":
    let tb = viewTable("t", @["name", "value"],
                       @[@["a", "1"], @["b", "2"], @["c", "3"]])
    ck tb.cursor == 0
    ck tb.column == 0
    ck applyKey(tb, press(kLeft)).handled == false
    ck applyKey(tb, press(kRight)).transition == trColumnNext
    ck tb.column == 1
    ck applyKey(tb, press(kRight)).handled == false
    ck applyKey(tb, press(kEnd)).transition == trCursorLast
    ck tb.cursor == 2
    ck applyKey(tb, press(kDown)).handled == false

  test "Tabs commits by moving — there is no uncommitted highlight":
    let t = viewTabs("t", @[opt("1", "Source"), opt("2", "State"),
                            opt("3", "Flow")])
    ck t.selected == 0
    ck applyKey(t, press(kRight)).transition == trHighlightNext
    ck t.selected == 1
    ck t.highlight == -1
    ck applyKey(t, press(kEnd)).transition == trHighlightLast
    ck t.selected == 2
    ck applyKey(t, press(kRight)).handled == false
    ck applyKey(t, press(kEscape)).handled == false

  test "Collapsible, Modal and Menu":
    let c = viewCollapsible("c", "Settings")
    ck applyKey(c, press(kSpace)).transition == trExpand
    ck c.expanded
    ck applyKey(c, press(kEnter)).transition == trCollapse
    let mo = viewModal("m", "Confirm")
    ck mo.open
    ck applyKey(mo, press(kEnter)).handled == false
    ck applyKey(mo, press(kEscape)).transition == trDismiss
    ck not mo.open
    # A CLOSED MODAL ANSWERS NOTHING, including Escape. A dismissed dialog
    # that kept swallowing Escape is how a front-end stops responding to its
    # own command line.
    ck applyKey(mo, press(kEscape)).handled == false
    let me = viewMenu("me", @[opt("1", "Copy"), opt("2", "Paste")])
    ck applyKey(me, press(kDown)).transition == trHighlightNext
    ck me.highlight == 1
    ck applyKey(me, press(kEnter)).transition == trActivate
    ck not me.open

  test "the four readings answer nothing at all":
    for v in [viewText("a", "hello"),
              viewImage("b", "image/png", "a chart"),
              viewMarkdown("c", "# hi"),
              viewProgress("d", 40)]:
      for k in Key:
        if k == kNone: continue
        ck applyKey(v, press(k)).handled == false

suite "PLAT-3: the vocabulary's own check rejects medium-specific escapes":

  test "a well-formed view passes, and the scan says how much it read":
    let v = viewCollapsible("panel", "Settings", @[
      viewText("t", "Hello"),
      viewCheckbox("c", "wrap"),
      viewImage("i", "image/png", "a screenshot")], expanded = true)
    let r = checkPortable(v)
    # THE POSITIVE CONTROL, first. An empty scan satisfies every "no
    # violations" assertion below it — Verification-Harness-Traps §4.
    ck r.nodesVisited == 4
    ck r.violations.len == 0
    ck isPortable(v)
    ck describeReport(r).contains("portable: 4 nodes")

  test "a scan that read nothing is NOT a pass":
    let empty = checkPortable(nil)
    ck empty.nodesVisited == 0
    ck empty.violations.len == 0
    ck not isPortable(nil)
    ck describeReport(empty).contains("read NO nodes")

  test "PLAT-9's native view is refused, and named":
    let v = viewCollapsible("panel", "Settings", @[
      viewText("t", "Hello"),
      nativeEscape("frame", "gpui", "codetracer.frameViewer")], expanded = true)
    let r = checkPortable(v)
    ck r.nodesVisited == 3
    ck r.violations.len == 1
    ck r.violations[0].kind == pvNativeEscape
    ck r.violations[0].nodeId == "frame"
    ck r.violations[0].detail.contains("gpui")
    ck r.violations[0].detail.contains("codetracer.frameViewer")
    ck not isPortable(v)
    # AND THE SAME TREE PASSES WITH THE ESCAPE REMOVED. Without this half the
    # case proves the checker says no, not that it says no TO THIS.
    let cleaned = viewCollapsible("panel", "Settings", @[
      viewText("t", "Hello")], expanded = true)
    ck isPortable(cleaned)

  test "a pointer-only control is refused — the terminal-first rule":
    let b = viewButton("b", "Apply")
    ck isPortable(b)
    b.activation = {acPointer}
    let r = checkPortable(b)
    ck r.violations.len == 1
    ck r.violations[0].kind == pvPointerOnly
    ck r.violations[0].detail.contains("no pointer")
    b.activation = {acKeyboard}
    ck isPortable(b)

  test "an actuatable reading is refused":
    let t = viewText("t", "Click here")
    ck isPortable(t)
    t.activation = {acKeyboard, acPointer}
    let r = checkPortable(t)
    ck r.violations.len == 1
    ck r.violations[0].kind == pvActuationOnReading
    ck r.violations[0].detail.contains("use a Button")

  test "an Image with no text equivalent is refused":
    let i = viewImage("i", "image/png", "")
    let r = checkPortable(i)
    ck r.nodesVisited == 1
    ck r.violations.len == 1
    ck r.violations[0].kind == pvNoTextEquivalent
    i.alt = "a flame graph"
    ck isPortable(i)

  test "terminal control bytes and HTML in text are both refused":
    let ansi = viewText("t", "\e[31mred\e[0m")
    let ra = checkPortable(ansi)
    ck ra.violations.len == 1
    ck ra.violations[0].kind == pvMediumMarkup
    let html = viewText("t", "<span class=\"err\">boom</span>")
    let rh = checkPortable(html)
    ck rh.violations.len == 1
    ck rh.violations[0].kind == pvMediumMarkup
    # THE BOUND, ASSERTED RATHER THAN DESCRIBED. A generic type name is not
    # markup, and a rule that rejected it would be a rule nobody could keep.
    ck isPortable(viewText("t", "Vec<T>"))
    ck isPortable(viewText("t", "HashMap<String, i32>"))
    ck isPortable(viewText("t", "a < b && b > c"))
    # And Markdown may contain inline HTML by specification, so the HTML arm
    # does not apply to it — while the ANSI arm still does.
    ck isPortable(viewMarkdown("m", "line one<br>line two"))
    ck not isPortable(viewMarkdown("m", "\e[1mbold\e[0m"))

  test "structural refusals: duplicate ids, no id, a ragged table":
    let dup = viewCollapsible("panel", "S", @[
      viewText("t", "a"), viewText("t", "b")], expanded = true)
    let rd = checkPortable(dup)
    ck rd.violations.len == 1
    ck rd.violations[0].kind == pvStructural
    ck rd.violations[0].detail.contains("more than one node")
    let noId = viewText("", "a")
    ck checkPortable(noId).violations[0].kind == pvStructural
    let ragged = viewTable("t", @["a", "b"], @[@["1", "2"], @["3"]])
    let rr = checkPortable(ragged)
    ck rr.violations.len == 1
    ck rr.violations[0].detail.contains("1 cells against 2 columns")

  test "describeViolation names the rule, the entry and the node":
    let v = nativeEscape("frame", "terminal", "ct.sourceEditor")
    let line = describeViolation(checkPortable(v).violations[0])
    ck line.startsWith("pvNativeEscape")
    ck line.contains("frame")
    ck line.contains("terminal")

suite "PLAT-3: the admission test, applied to every entry":

  test "all sixteen are admitted, and each names the front-ends that have it":
    var admitted = 0
    for k in ViewKind:
      let a = admission(k)
      ck a.admitted
      ck a.frontEnds.card > 0
      ck a.semantics.len > 40
      inc admitted
    ck admitted == 16

  test "no entry's semantics are stated in one medium's words":
    for k in ViewKind:
      let found = mediumWordsIn(semanticsOf(k))
      if found.len > 0:
        checkpoint vocabularyName(k) & ": " & found.join(", ")
      ck found.len == 0
    # THE SCAN'S OWN POSITIVE CONTROL. Sixteen sentences that contain no
    # medium word is indistinguishable from a word list that matches nothing,
    # so the list is proved live against a sentence written to trip it.
    let planted = mediumWordsIn(
      "A control the reader clicks with the mouse to redraw the terminal.")
    # TWO, not four: the scan matches WHOLE WORDS, so `clicks` is not
    # `click` and `redraw` is not `draw`. That is the cost of the fix for the
    # `transient`/`ansi` collision below, it is stated here rather than
    # discovered later, and it is the bound on this arm.
    ck planted.len == 2
    ck "click" notin planted
    ck "mouse" in planted
    ck "terminal" in planted
    ck "draw" notin planted
    # AND THE TRAP THAT WAS ACTUALLY WALKED INTO. `ansi` is a substring of
    # `transient`, which is the word `Menu`'s semantics open with; a
    # `contains` scan reported the vocabulary's own sentence as
    # medium-specific. Verification-Harness-Traps §4d, from the other side.
    ck mediumWordsIn("A transient ordered set of named actions.").len == 0

  test "half two is derived from the mappings, not restated beside them":
    for k in ViewKind:
      for fe in FrontEnd:
        ck (fe in frontEndsHaving(k)) ==
           (mappingFor(fe, k).status != msAbsent)

  test "the rejections are recorded, and each fails a stated half":
    ck Rejections.len == 8
    for r in Rejections:
      ck r.name.len > 0
      ck r.reason.len > 60
    # Two of the eight fail NEITHER half and are refused on other grounds,
    # which is the pair that says the admission test is necessary and not
    # sufficient. Asserted rather than described.
    var passBoth = 0
    for r in Rejections:
      if not r.failsMediumIndependence and not r.failsExistingFrontEnd:
        inc passBoth
    ck passBoth == 2

suite "PLAT-3: the three front-end mappings":

  test "every entry has a mapping on every front-end, with a target":
    var cells = 0
    for k in ViewKind:
      for fe in FrontEnd:
        let mp = mappingFor(fe, k)
        ck mp.target.len > 0
        # AN ABSENT OR PARTIAL MAPPING MUST SAY WHY. A status with no note is
        # a gap papered over.
        if mp.status != msComplete:
          ck mp.note.len > 40
        inc cells
    ck cells == 48

  test "the terminal is complete on fourteen of sixteen, and names the two":
    var complete = 0
    var partial: seq[string] = @[]
    for k in ViewKind:
      case terminalMapping(k).status
      of msComplete: inc complete
      of msPartial: partial.add vocabularyName(k)
      of msAbsent: partial.add "ABSENT:" & vocabularyName(k)
    ck complete == 14
    # TWO partials, and they are partial for different reasons: Menu has no
    # widget at all, and Tabs has one that behaves differently. The second was
    # found by the cross-medium suite rather than by reading the library.
    ck partial == @["Tabs", "Menu"]
    ck terminalMapping(pkMenu).note.contains("NO MENU WIDGET")
    ck terminalMapping(pkTabs).note.contains("THE WIDGET WRAPS")

  test "the web is complete on fifteen of sixteen, and Markdown is the one":
    var complete = 0
    var partial: seq[string] = @[]
    for k in ViewKind:
      case webMapping(k).status
      of msComplete: inc complete
      of msPartial: partial.add vocabularyName(k)
      of msAbsent: partial.add "ABSENT:" & vocabularyName(k)
    ck complete == 15
    ck partial == @["Markdown"]

  test "GPUI is absent on exactly three entries, and they are named":
    var absent: seq[string] = @[]
    var complete: seq[string] = @[]
    for k in ViewKind:
      case gpuiMapping(k).status
      of msAbsent: absent.add vocabularyName(k)
      of msComplete: complete.add vocabularyName(k)
      of msPartial: discard
    # PLAT-21's verification gate asks that every entry needing a
    # GPUI-specific escape be "a named, filed vocabulary defect". These are
    # the three, named here so the gate has something to read.
    ck absent == @["Table", "Modal", "ProgressIndicator"]
    ck complete == @["Text", "Image"]

  test "the GPUI mapping is consistent with the tag table it rests on":
    # `Table`, `Modal` and `ProgressIndicator` are absent BECAUSE their tags
    # are not in the map; the rest are present because theirs are. Asserted
    # from the tag table rather than restated, so the two cannot disagree.
    ck not gpuiKnowsTag("table")
    ck not gpuiKnowsTag("dialog")
    ck not gpuiKnowsTag("progress")
    ck not gpuiKnowsTag("a")
    ck gpuiKnowsTag("button")
    ck gpuiKnowsTag("input")
    ck gpuiKnowsTag("img")
    ck gpuiPassesThrough("span")
    ck gpuiPassesThrough("img")
    ck not gpuiPassesThrough("button")
    ck not gpuiPassesThrough("li")
    ck GpuiTagMap.len == 35
    ck GpuiPassThroughTags.len == 16

  test "the summary reports all sixteen rows":
    let s = mappingSummary()
    ck s.splitLines.len == 17     # a header plus sixteen entries
    ck s.contains("ProgressIndicator   complete   complete   ABSENT")
    ck s.contains("Menu                partial    complete   partial")
    ck s.contains("Tabs                partial    complete   partial")
    let a = admissionSummary()
    ck a.splitLines.len == 16
    ck a.contains("Menu: ADMITTED (front-ends having it: terminal, web, gpui)")

# ---------------------------------------------------------------------------
# The cross-repository arm
# ---------------------------------------------------------------------------

proc isonimGpuiRenderer(): string =
  ## `../isonim-gpui/src/isonim_gpui/renderer.nim`, resolved from THIS source
  ## file rather than from the working directory, so the answer does not
  ## depend on where the test binary was launched from.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "isonim-gpui" / "src" / "isonim_gpui" / "renderer.nim"

proc parseGpuiTagKeys(source: string): seq[string] =
  ## The keys of `const tagMap = { ... }.toTable`, read out of the source.
  var inMap = false
  for raw in source.splitLines:
    let line = raw.strip
    if not inMap:
      if line.startsWith("const tagMap"):
        inMap = true
      continue
    if line.startsWith("}.toTable"):
      break
    if not line.startsWith("\""):
      continue
    let closing = line.find('"', 1)
    if closing > 1:
      result.add line[1 ..< closing]

var gpuiArmRan = false

suite "PLAT-3: the GPUI tag table this repository copied":

  test "the copy matches isonim-gpui's own source":
    let path = isonimGpuiRenderer()
    if not fileExists(path):
      # NOT RUN, BY NAME. `isonim-gpui` is an advisory sibling and is
      # provisioned by no CI job; see this file's header. The tally in the
      # final case has a declared value for this arm not running, so a
      # silently smaller run is still caught.
      checkpoint "NOT RUN: isonim-gpui is not checked out at " & path &
        " — `repro ws enable isonim` provides it"
      ck true
    else:
      gpuiArmRan = true
      let keys = parseGpuiTagKeys(readFile(path))
      # THE POSITIVE CONTROL. A parser that matched nothing would satisfy
      # every "every tag we name is in there" assertion below.
      ck keys.len == 35
      ck keys.len == GpuiTagMap.len
      for tag in GpuiTagMap:
        ck tag in keys
      for tag in keys:
        ck tag in GpuiTagMap

suite "PLAT-3: assertion tally":

  test "every assertion above ran":
    let expected =
      if gpuiArmRan: ExpectedAssertionsWithGpui
      else: ExpectedAssertionsWithoutGpui
    # DECLARE THE TALLY TO THE LANE. `run-nim-test-lane.sh` reads `CHECKS: <n>`
    # and otherwise falls back to a `const ExpectedAssertions = <n>` it can
    # grep — this file has neither name, because its expected count is
    # two-armed, so without this line the lane counts the file as declaring
    # nothing and its own report says the case count is then the only
    # evidence. `CHECKS:` is also the better of the two: it is the RUNTIME
    # count, so it reports the arm that actually ran.
    echo "CHECKS: " & $countedAssertions
    checkpoint "gpui arm ran: " & $gpuiArmRan
    if countedAssertions != expected:
      checkpoint "assertion count is " & $countedAssertions &
        ", expected " & $expected
    check countedAssertions == expected
