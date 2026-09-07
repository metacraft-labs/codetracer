## test_view_vocabulary_cross_medium.nim — PLAT-3's first integration test:
## "one view written once in the vocabulary renders and behaves equivalently
## on the terminal and the web, asserted on keyboard contract and state
## transitions, not appearance".
##
## ## THE SHAPE, AND WHY IT IS THE EXISTING ONE
##
## `isonim-gpui/tests/test_cross_renderer.nim` already runs ONE component
## across `GpuiRenderer`, `MockRenderer` and `TerminalRenderer` by writing it
## generically over the backend and comparing `textContent` between the
## instantiations. This file is that pattern applied one layer up: ONE
## `ViewNode` tree, rendered by two independent bindings, compared on STATE
## rather than on text — because text is appearance and the milestone
## explicitly asks that appearance not be the assertion.
##
## What is compared is `StateFact` triples. Each binding projects its own
## rendered artefact down to them:
##
##   TERMINAL  `frontend/view_vocabulary/terminal_binding` builds real
##             isonim-tui widgets, fires a real `keydown` at the real widget
##             with isonim-tui's own key spelling, and reads the answer OUT OF
##             THE WIDGET — `CheckboxWidget.value`, `ListViewWidget`.
##             `highlightedIndex`, `TreeWidget.cursor`,
##             `DataTableWidget.selectedRow`, `ModalWidget.state`.
##
##   WEB       `frontend/view_vocabulary/web_binding` renders DOM elements
##             through isonim's `RendererBackend`, routes the key through
##             `behaviour.applyKey` after translating it into the DOM's own
##             `KeyboardEvent.key` spelling, and reads the answer back off the
##             rendered elements' `data-*` attributes.
##
## THE TERMINAL SIDE IS AN INDEPENDENT ORACLE and that is the point. It never
## calls `applyKey`. If this file drove both sides through the vocabulary's
## state machine it would be comparing one function with itself and would pass
## on a vocabulary no widget honours; instead, isonim-tui — a library this
## repository does not own and which was not written for this — decides what
## Down does to a list, and the assertion is that it agrees.
##
## ## NO MOCKS, AND THE TWO NAMES THAT LOOK LIKE ONE
##
## Two objects here carry names that read like mocks and are not, so both are
## justified by name as the workspace policy requires:
##
##   `isonim.testing.mock_dom.MockRenderer` — one of the FOUR renderer
##   backends isonim ships. It satisfies the same compile-time
##   `checkRendererBackend[B, E]()` conformance proof `WebRenderer` does, it is
##   the backend the product's own non-JS overload of every `isonim_*_view.nim`
##   is compiled against, and `test_cross_renderer.nim` uses it as one of its
##   three real renderers. It is a DOM implementation, not a stand-in for one.
##   The browser's `WebRenderer` cannot be used here because it compiles only
##   under `nim js` against a live document, and this lane compiles C.
##
##   `isonim_tui.testing.harness.TerminalTestHarness` — isonim-tui's own
##   headless bundle: renderer, headless driver, compositor, animator, focus
##   manager, worker manager and a virtual clock. Every one of isonim-tui's own
##   widget suites constructs one. Nothing in it is stubbed; it is the terminal
##   front-end's runtime minus the pty.
##
## ## THE TWO EXCLUSIONS, NAMED
##
## `Markdown.text` is not compared. `MarkdownWidget` parses its source into an
## `MdDocument` and does not keep the source, so the terminal side genuinely
## cannot report it; the binding returns "" rather than echoing the model, and
## this file drops the field BY NAME with the reason here. An unexplained
## exclusion is how a suite stops covering what it claims to cover.
##
## `Input.cursor` is compared, and only over ASCII. isonim-tui's
## `InputWidget.selection.cursor` is a GRAPHEME-CLUSTER index and the
## vocabulary's `Input.cursor` is a RUNE index; they agree on everything that
## is neither a combining sequence nor an emoji join. The rune-level editing is
## asserted against the vocabulary in `src/common/view_vocabulary_test.nim`,
## where there is no second definition to disagree with.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)

import std/[algorithm, strutils, tables, unittest]

import isonim/testing/mock_dom
import isonim_tui/testing/harness

import ../../../common/view_vocabulary
import ../../view_vocabulary/terminal_binding as tbind
import ../../view_vocabulary/web_binding as wbind

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 353
  ## Written from a run. See the final case.

const ExcludedFields = @["doc.text"]
  ## `Markdown`'s source; see the header. A LIST OF FULLY-QUALIFIED FIELD
  ## NAMES rather than a kind, so excluding a whole entry by accident is not
  ## possible and the exclusion is visible in one place.

# ---------------------------------------------------------------------------
# The view. Written ONCE, in the vocabulary, and rendered twice.
#
# It carries all sixteen entries because "one view renders equivalently" is a
# stronger claim the more of the vocabulary the view uses, and because an
# entry left out of it would be an entry whose mapping table row nothing
# checks.
# ---------------------------------------------------------------------------

proc opt(id, label: string; disabled = false): ViewOption =
  ViewOption(id: id, label: label, disabled: disabled)

proc settingsPanel(): ViewNode =
  viewCollapsible("panel", "Debug settings", @[
    viewText("title", "Settings"),
    viewButton("apply", "Apply"),
    viewCheckbox("wrap", "Wrap long values"),
    viewToggle("live", "Live update"),
    viewInput("filter", "abc"),
    viewSelect("lang", @[opt("rs", "Rust"), opt("py", "Python"),
                         opt("go", "Go")], selected = 0),
    # `beta` IS DISABLED, and that is not decoration. A list with no
    # unavailable member cannot show whether the two media agree about
    # SKIPPING one, and the mutation that removes the skip from
    # `behaviour.nextEnabled` left this suite fully green until this option
    # was marked — measured, in the falsification pass for this milestone.
    viewList("recent", @[opt("a", "alpha"), opt("b", "beta", disabled = true),
                         opt("c", "gamma")]),
    viewTreeNode("state", "locals", @[
      viewTreeNode("state.x", "x"),
      viewTreeNode("state.p", "p", @[viewTreeNode("state.p.y", "y")])],
      expanded = true),
    viewTable("tbl", @["name", "value"],
              @[@["a", "1"], @["b", "2"], @["c", "3"]]),
    viewTabs("panes", @[opt("t1", "Source"), opt("t2", "State")]),
    viewMenu("ctx", @[opt("m1", "Copy"), opt("m2", "Paste")]),
    viewProgress("load", 40),
    viewImage("shot", "image/png", "screenshot of the state panel", 2048),
    viewMarkdown("doc", "# Title\n\nbody"),
    viewModal("dlg", "Confirm", @[viewText("dlgtext", "Are you sure?")])],
    expanded = true)

# ---------------------------------------------------------------------------
# The two media, side by side
# ---------------------------------------------------------------------------

type
  CrossMedium = object
    ## Two bindings over two SEPARATE models of the same view.
    ##
    ## Separate deliberately: a shared `ViewNode` would let the web binding's
    ## `applyKey` mutate the object the terminal binding was built from, and
    ## the comparison would then be reading one state twice.
    terminal: TerminalBinding
    web: WebBinding[MockRenderer, MockNode]

proc newCrossMedium(): CrossMedium =
  let h = newTerminalTestHarness(200, 60)
  var mr = MockRenderer()
  CrossMedium(terminal: tbind.bindView(h, settingsPanel()),
              web: wbind.renderWeb[MockRenderer, MockNode](mr,
                     settingsPanel()))

proc factsOf(fs: seq[StateFact]): Table[string, string] =
  for f in fs:
    let key = f.id & "." & f.field
    if key notin ExcludedFields:
      result[key] = f.value

proc terminalFacts(c: CrossMedium): Table[string, string] =
  factsOf(tbind.readTerminalFacts(c.terminal))

proc webFacts(c: var CrossMedium): Table[string, string] =
  factsOf(wbind.readWebFacts(c.web))

proc divergences(c: var CrossMedium): seq[string] =
  let t = terminalFacts(c)
  let w = webFacts(c)
  var keys: seq[string] = @[]
  for k in t.keys: keys.add k
  for k in w.keys:
    if k notin t: keys.add k
  keys.sort()
  for k in keys:
    let tv = if k in t: t[k] else: "<absent on terminal>"
    let wv = if k in w: w[k] else: "<absent on web>"
    if tv != wv:
      result.add k & ": terminal=" & tv & " web=" & wv

proc factOf(c: var CrossMedium; key: string): tuple[terminal, web: string] =
  let t = terminalFacts(c)
  let w = webFacts(c)
  ((if key in t: t[key] else: "<absent>"),
   (if key in w: w[key] else: "<absent>"))

# THESE THREE ARE TEMPLATES AND NOT PROCS, AND THE REASON IS A TRAP THIS FILE
# WALKED INTO BEFORE IT WAS WRITTEN DOWN.
#
# `unittest.check` expands to code that assigns `testStatusIMPL`, which the
# `test` template injects as a LOCAL. Nim's `unittest` also declares a global
# `testStatusIMPL` as a fallback, so a `check` written inside an ordinary
# `proc` compiles — and sets the GLOBAL instead of the running test's status.
# The test then reports `[OK]` while its own transcript prints the failed
# comparison two lines above.
#
# Measured, on the first run of this file: `bothSay` was a `proc`, "Tabs: Left
# and Right" printed `panes.selected: terminal=0 web=1` and a `Check failed`
# line, AND REPORTED `[OK]`. That is Verification-Harness-Traps §10 —
# an assertion whose negative arm does nothing — arriving through the standard
# library rather than through a hand-written helper.
#
# As templates they expand INSIDE the test body, where `testStatusIMPL` is the
# test's own. The `[OK]` in the transcript is now a claim about the
# assertions.

template sendBoth(c: var CrossMedium; id: string; k: Key; ch = ' ') =
  ## The SAME vocabulary key, spelled each medium's own way by its own
  ## binding. That translation is the only thing that differs, which is the
  ## claim under test.
  ck tbind.sendKey(c.terminal, id, k, ch)
  discard wbind.sendKey[MockRenderer, MockNode](
    c.web, id, k, (if k == kChar: $ch else: ""))

template agree(c: var CrossMedium; after: string) =
  ## Both media report the same state, over a NON-EMPTY fact set.
  let t = terminalFacts(c)
  let d = divergences(c)
  if d.len > 0:
    checkpoint after & ":\n  " & d.join("\n  ")
  # THE POSITIVE CONTROL FIRST — Verification-Harness-Traps §4. A binding that
  # rendered nothing produces an empty projection, and two empty projections
  # agree about everything.
  ck t.len >= 20
  ck d.len == 0

template bothSay(c: var CrossMedium; key, value: string) =
  let (tf, wf) = factOf(c, key)
  if tf != value or wf != value:
    checkpoint key & ": terminal=" & tf & " web=" & wf & " expected=" & value
  ck tf == value
  ck wf == value

# ---------------------------------------------------------------------------

suite "PLAT-3: one view, two media, the same state":

  test "the view is portable before it is rendered anywhere":
    # If it were not, the rest of this file would be measuring the agreement
    # of two bindings on a view the vocabulary itself refuses.
    let v = settingsPanel()
    let r = checkPortable(v)
    if r.violations.len > 0:
      checkpoint describeReport(r)
    ck r.nodesVisited == 20
    ck r.violations.len == 0

  test "both media render every entry, and agree on the initial state":
    var c = newCrossMedium()
    let t = terminalFacts(c)
    let w = webFacts(c)
    # Sixteen entries plus the Modal's Text child plus the Tree's two visible
    # children, over the fields each declares, minus Markdown's excluded
    # field. Asserted as a NUMBER so a binding that quietly dropped an entry
    # is caught here rather than passing a comparison of two shorter lists.
    ck t.len == 28
    ck w.len == 28
    ck divergences(c).len == 0
    # And every one of the sixteen is actually present, by id. Read from the
    # UNFILTERED projections, because `doc`'s only field is the excluded one
    # and a presence check over the filtered set would report the Markdown
    # entry as missing when it is merely uncompared.
    var terminalIds: seq[string] = @[]
    for f in tbind.readTerminalFacts(c.terminal): terminalIds.add f.id
    var webIds: seq[string] = @[]
    for f in wbind.readWebFacts(c.web): webIds.add f.id
    for id in ["title", "apply", "wrap", "live", "filter", "lang", "recent",
               "state", "tbl", "panes", "ctx", "load", "shot", "doc", "dlg",
               "panel"]:
      ck id in terminalIds
      ck id in webIds

  test "Checkbox and Toggle: the keyboard contract, on both media":
    var c = newCrossMedium()
    bothSay(c, "wrap.checked", "false")
    sendBoth(c, "wrap", kSpace)
    bothSay(c, "wrap.checked", "true")
    agree(c, "space on the checkbox")
    sendBoth(c, "wrap", kEnter)
    bothSay(c, "wrap.checked", "false")
    sendBoth(c, "live", kSpace)
    bothSay(c, "live.checked", "true")
    agree(c, "space on the toggle")
    # A key OUTSIDE the contract changes nothing on either medium, which is
    # the half a "does the key work" test leaves out.
    sendBoth(c, "wrap", kDown)
    bothSay(c, "wrap.checked", "false")
    agree(c, "an unclaimed key on the checkbox")

  test "List: motion skips the unavailable member, on both media":
    var c = newCrossMedium()
    bothSay(c, "recent.highlight", "0")
    sendBoth(c, "recent", kDown)
    # PAST `beta`, WHICH IS DISABLED, and onto `gamma`. isonim-tui's ListView
    # decides this for itself; the vocabulary decides it in
    # `behaviour.nextEnabled`; the assertion is that they agree.
    bothSay(c, "recent.highlight", "2")
    sendBoth(c, "recent", kUp)
    bothSay(c, "recent.highlight", "0")
    sendBoth(c, "recent", kEnd)
    bothSay(c, "recent.highlight", "2")
    sendBoth(c, "recent", kDown)
    # NO WRAP, agreed by both. isonim-tui's ListView does not wrap and neither
    # does the vocabulary; if either changed its mind this is the case that
    # would say so.
    bothSay(c, "recent.highlight", "2")
    sendBoth(c, "recent", kHome)
    bothSay(c, "recent.highlight", "0")
    agree(c, "list motion")

  test "Tabs: Left and Right, not Up and Down":
    var c = newCrossMedium()
    bothSay(c, "panes.selected", "0")
    sendBoth(c, "panes", kDown)
    bothSay(c, "panes.selected", "0")
    sendBoth(c, "panes", kRight)
    bothSay(c, "panes.selected", "1")
    sendBoth(c, "panes", kHome)
    bothSay(c, "panes.selected", "0")
    agree(c, "tab motion")

  test "Tabs: THE ONE DIVERGENCE THIS SUITE FOUND — the widget wraps":
    # isonim-tui's `TabsWidget.moveRight` sets the FIRST tab when it is on the
    # last, and `moveLeft` sets the last when it is on the first
    # (widgets/tabs.nim, the two lines commented `# wrap`). The vocabulary's
    # Tabs does not wrap, and neither does any other isonim-tui WIDGET:
    # ListView, OptionList, Tree, DataTable, RadioSet, ContentSwitcher and
    # MarkdownViewer all clamp, read one by one rather than grepped —
    # `grep -n wrap widgets/*.nim` returns 34 lines and all but two of them
    # are TEXT wrapping or the word `wrapper`, so that grep is not evidence
    # of anything. Outside `widgets/`, `command/palette.nim` and
    # `focus/manager.nim` DO wrap; the claim is therefore about widgets, not
    # about the library, and `mappings.terminalMapping(pkTabs)` says so.
    #
    # It is asserted here AS A DIVERGENCE rather than hidden, for two reasons.
    # A suite that dropped the step would stop covering the entry at its
    # boundary, which is where every off-by-one lives. And a divergence
    # nothing asserts is one that can be silently fixed, silently widened, or
    # silently spread to a second widget.
    #
    # `mappings.terminalMapping(pkTabs)` is `msPartial` because of this, and
    # the mapping's note names it. When isonim-tui stops wrapping, THIS CASE
    # goes red and that note is what the reader is sent to.
    var c = newCrossMedium()
    sendBoth(c, "panes", kRight)
    bothSay(c, "panes.selected", "1")
    sendBoth(c, "panes", kRight)
    let (tw, ww) = factOf(c, "panes.selected")
    ck tw == "0"      # the widget wrapped to the first tab
    ck ww == "1"      # the vocabulary stopped at the last
    ck tw != ww
    ck terminalMapping(pkTabs).status == msPartial
    ck terminalMapping(pkTabs).note.contains("THE WIDGET WRAPS")
    # And it is the ONLY divergence in the whole view at this point: one
    # asserted difference, not a suite that has stopped comparing.
    ck divergences(c).len == 1

  test "Table: two dimensions, bounded in both":
    var c = newCrossMedium()
    bothSay(c, "tbl.row", "0")
    bothSay(c, "tbl.column", "0")
    sendBoth(c, "tbl", kDown)
    bothSay(c, "tbl.row", "1")
    sendBoth(c, "tbl", kRight)
    bothSay(c, "tbl.column", "1")
    sendBoth(c, "tbl", kRight)
    bothSay(c, "tbl.column", "1")
    sendBoth(c, "tbl", kEnd)
    bothSay(c, "tbl.row", "2")
    agree(c, "table motion")

  test "Tree: the cursor indexes visible rows on both media":
    var c = newCrossMedium()
    bothSay(c, "state.cursor", "0")
    bothSay(c, "state.p.expanded", "false")
    sendBoth(c, "state", kDown)
    sendBoth(c, "state", kDown)
    bothSay(c, "state.cursor", "2")
    sendBoth(c, "state", kRight)
    bothSay(c, "state.p.expanded", "true")
    agree(c, "expanding a tree node")
    # The child is now a fact on BOTH media, which it was not before — the
    # expansion changed the rendered set and not only an attribute.
    let (tv, wv) = factOf(c, "state.p.y.expanded")
    ck tv == "false"
    ck wv == "false"
    sendBoth(c, "state", kRight)
    bothSay(c, "state.cursor", "3")
    sendBoth(c, "state", kLeft)
    bothSay(c, "state.cursor", "2")
    sendBoth(c, "state", kLeft)
    bothSay(c, "state.p.expanded", "false")
    # And it is gone again from both.
    let (tg, wg) = factOf(c, "state.p.y.expanded")
    ck tg == "<absent>"
    ck wg == "<absent>"
    agree(c, "collapsing a tree node")

  test "Input: typing and deleting agree over ASCII":
    var c = newCrossMedium()
    bothSay(c, "filter.text", "abc")
    bothSay(c, "filter.cursor", "3")
    sendBoth(c, "filter", kLeft)
    bothSay(c, "filter.cursor", "2")
    sendBoth(c, "filter", kChar, 'Z')
    bothSay(c, "filter.text", "abZc")
    bothSay(c, "filter.cursor", "3")
    sendBoth(c, "filter", kBackspace)
    bothSay(c, "filter.text", "abc")
    sendBoth(c, "filter", kHome)
    bothSay(c, "filter.cursor", "0")
    sendBoth(c, "filter", kDelete)
    bothSay(c, "filter.text", "bc")
    agree(c, "input editing")

  test "Select: Escape does not commit the option that was passed over":
    var c = newCrossMedium()
    bothSay(c, "lang.selected", "0")
    bothSay(c, "lang.open", "false")
    sendBoth(c, "lang", kEnter)
    bothSay(c, "lang.open", "true")
    sendBoth(c, "lang", kDown)
    sendBoth(c, "lang", kDown)
    bothSay(c, "lang.highlight", "2")
    bothSay(c, "lang.selected", "0")
    sendBoth(c, "lang", kEscape)
    bothSay(c, "lang.open", "false")
    # THE ASSERTION THIS CASE EXISTS FOR, now with a second witness: isonim-tui
    # and the vocabulary independently agree that arrowing past an option and
    # dismissing has not chosen it.
    bothSay(c, "lang.selected", "0")
    bothSay(c, "lang.highlight", "0")
    agree(c, "dismissing a select")
    sendBoth(c, "lang", kEnter)
    sendBoth(c, "lang", kDown)
    sendBoth(c, "lang", kEnter)
    bothSay(c, "lang.selected", "1")
    bothSay(c, "lang.open", "false")
    agree(c, "committing a select")

  test "Modal: Escape dismisses, and its body leaves the rendered set":
    var c = newCrossMedium()
    bothSay(c, "dlg.open", "true")
    bothSay(c, "dlgtext.text", "Are you sure?")
    sendBoth(c, "dlg", kEscape)
    bothSay(c, "dlg.open", "false")
    # THE BODY IS ABSENT, not merely hidden. "Present or absent" is the
    # entry's own word, and an element left in the document with a style
    # applied would be present.
    bothSay(c, "dlgtext.text", "<absent>")
    agree(c, "dismissing a modal")

  test "Menu: motion and dismissal":
    var c = newCrossMedium()
    bothSay(c, "ctx.open", "true")
    bothSay(c, "ctx.highlight", "0")
    sendBoth(c, "ctx", kDown)
    bothSay(c, "ctx.highlight", "1")
    agree(c, "menu motion")
    sendBoth(c, "ctx", kEscape)
    bothSay(c, "ctx.open", "false")
    agree(c, "dismissing a menu")

  test "Collapsible: collapsing removes its body from both media":
    var c = newCrossMedium()
    bothSay(c, "panel.expanded", "true")
    ck terminalFacts(c).len == 28
    sendBoth(c, "panel", kSpace)
    bothSay(c, "panel.expanded", "false")
    let t = terminalFacts(c)
    let w = webFacts(c)
    # ONE FACT LEFT — the Collapsible's own. Asserted as a number, because
    # "the body is gone" is exactly the claim an empty comparison would also
    # satisfy.
    ck t.len == 1
    ck w.len == 1
    ck divergences(c).len == 0
    sendBoth(c, "panel", kEnter)
    bothSay(c, "panel.expanded", "true")
    ck terminalFacts(c).len == 28

  test "a long mixed key script leaves both media in the same state":
    # The cases above each drive one entry. This one interleaves them, because
    # a binding that re-rendered the wrong subtree would pass every isolated
    # case and fail here.
    var c = newCrossMedium()
    let script = @[
      ("wrap", kSpace), ("recent", kDown), ("panes", kRight),
      ("tbl", kDown), ("state", kDown), ("filter", kLeft),
      ("live", kSpace), ("recent", kDown), ("state", kRight),
      ("tbl", kRight), ("lang", kEnter), ("lang", kDown),
      ("ctx", kDown), ("panes", kLeft), ("filter", kHome),
      ("lang", kEscape), ("state", kLeft), ("wrap", kEnter),
      ("dlg", kEscape), ("recent", kHome)]
    for (id, k) in script:
      sendBoth(c, id, k)
      ck divergences(c).len == 0
    agree(c, "the whole script")
    ck script.len == 20

suite "PLAT-3: the terminal binding is a real terminal binding":

  test "every entry is bound to the isonim-tui widget the mapping names":
    # `mappings.terminalMapping` is a table of claims; this is the case that
    # reads it against what the binding actually built. A row that named a
    # widget the binding does not use would be a table nobody had checked.
    var c = newCrossMedium()
    var boundKinds: set[ViewKind] = {}
    for bw in c.terminal.bound:
      boundKinds.incl bw.kind
      ck terminalMapping(bw.kind).target.len > 0
    for k in ViewKind:
      ck k in boundKinds
    ck boundKinds.card == 16

  test "the key spellings are each medium's own":
    # If both bindings spelled keys the same way, the translation would not be
    # under test at all.
    ck tbind.terminalKeyName(kDown) == "down"
    ck wbind.domKeyName(kDown) == "ArrowDown"
    ck tbind.terminalKeyName(kEscape) == "escape"
    ck wbind.domKeyName(kEscape) == "Escape"
    ck tbind.terminalKeyName(kSpace) == "space"
    ck wbind.domKeyName(kSpace) == " "
    ck tbind.terminalKeyName(kDown) != wbind.domKeyName(kDown)

  test "the web binding emits the tags the mapping table names":
    for k in ViewKind:
      let tag = wbind.tagFor(k)
      ck tag.len > 0
      ck webMapping(k).target.contains("<" & tag)

suite "PLAT-3: assertion tally":

  test "every assertion above ran":
    if countedAssertions != ExpectedAssertions:
      checkpoint "assertion count is " & $countedAssertions &
        ", expected " & $ExpectedAssertions
    check countedAssertions == ExpectedAssertions
