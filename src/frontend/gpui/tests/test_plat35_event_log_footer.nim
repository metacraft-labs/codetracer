## test_plat35_event_log_footer.nim — **TIER 3 OVER THE EVENT LOG'S FOOTER AND
## ITS HEADER ROW: `PLAT35-F5` and `PLAT35-F12`.**
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat35_event_log_footer.nim
##
## Nothing here opens a window. The ViewModel is constructed in process and
## the window it holds is SEEDED through the store's own producer entry point
## (`applyEventLogRows`), which is what makes the central claim of this file
## assertable at all — see "the trap" below. The frame-level reading is the
## capture lane's (`ci/test/plat35-gpui-capture.sh`) and the tier-4 ledger's.
##
## ## The two findings, and what they were measured as
##
## `PLAT35-F5` (P1): *"the event-log pane shows no row count in its footer."*
## RE-MEASURED at `codetracer@agents` `3e2a5c5ba` and it still reproduced:
## `grep -i footer src/frontend/gpui/app/leaves.nim` returned **nothing**, and
## `renderPaneView` had exactly two native arms (`paneCalltrace`, `paneState`)
## with the event log falling through to the generic vocabulary binding, which
## has no footer word.
##
## `PLAT35-F12` (P2): *"the event-log table has no header rule, no column
## dividers and no zebra, and its header row is the same weight and colour as a
## data row."* RE-MEASURED at `3e2a5c5ba` and the weight/colour half
## reproduced for a reason the finding did not name: `gpui_binding.layOutRow`
## applies the SAME three declarations — `display: flex`, `gap: 12px`,
## `white-space: nowrap` — to the header `tr` and to every body `tr`, and
## nothing else styles either. One function, both rows, so they could not
## differ.
##
## ## THE TRAP THIS FILE EXISTS TO HOLD SHUT
##
## A footer that counted the rows it holds would read `6` on a recording with
## thousands of events. `Event-Log-Pane.md`'s Requirement is explicit that it
## cannot be computed that way — the counts come from `ct/update-table`'s
## `recordsTotal` / `recordsFiltered`, and *"no single window can supply them:
## they describe the whole log and the whole filtered log, not the rows in
## hand"* — and `rows` IS one window, with `store.eventLog.loadedStart` saying
## which. So `rows.len` is not merely imprecise, it is wrong outright on any
## window after the first.
##
## **AND A NAIVE EXISTENCE CHECK CANNOT TELL THE TWO APART.** On the capture
## scenario the whole log is six rows, so `of 6` and `of <rows.len>` are the
## same six characters. Every case below that touches the count therefore
## seeds a window where the two answers DIFFER — six rows at offset 240 of a
## 1000-row log — which is the arm-C shape: a mutation that satisfies "a
## footer exists and carries a number" and violates the real invariant.
##
## ## What is grounded, and what is deliberately NOT drawn
##
## `PLAT35-F12` names THREE things, and they do not have the same standing.
## Grepped over `codetracer-specs@90ff8fce`'s `Event-Log-Pane.md` for
## zebra / divider / header rule / alternat / stripe / border: **zero hits for
## all six terms.** So no sub-claim is spec-grounded, and two of the three are
## not grounded at all:
##
##   | sub-claim        | standing                                          |
##   | header rule      | PUBLISHED TOKEN + convergence — drawn             |
##   | header weight    | PUBLISHED TOKEN + convergence — drawn             |
##   | column dividers  | **Not specified. Not drawn.** residue             |
##   | zebra striping   | **Not specified. Not drawn.** residue             |
##
## The two that are drawn take `dtColorsUiBorderPrimary` and
## `dtColorsUiTextPrimaryCaptionSubtle` — the tokens the state pane's rule and
## header already take — and converge on the terminal, which rules its own
## event-log title row (`PaneRule` at `RuleStyle = srBorderPane`) and bolds its
## column header (`HeaderStyle = CellStyle(role: srChromeMuted, bold: true)`,
## `tui/app/views/event_log.nim:223`). Two front-ends distinguish the header by
## colour AND weight together, so this one does both.
##
## The two that are not drawn are left as RECORDED RESIDUE, on `PLAT35-F10`'s
## reasoning — a thing the design system publishes no value for is blocked, not
## pending. Electron cannot be copied here either: `PLAT35-PD2` records that
## the desktop event log *has no column headers at all*, so it is WORSE than
## GPUI on this point and is not the reference for it. Suite 4 asserts the
## residue is still residue, so a later pass that invents a divider or a zebra
## trips a case that names the missing grounding rather than landing silently.
##
## ## Trap 13 / §29
##
## Every helper that calls `check` is a `template`. The `proc`s return values.

import std/[json, strutils, unittest]

import isonim/core/async_compat
import isonim/core/[signals, computation]
import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree
import codetracer_embed
import gpui/app/leaves
import view_vocabulary/pane_views
# `ViewIdAttribute` reaches `leaves.nim` through a `from … import`, which does
# NOT re-export, and the design tokens are not re-exported either — so both are
# named from where they are declared. The token import is what makes the
# "published token and not a literal" case assert anything: it compares the
# renderer's constant against the GENERATED table rather than against a copy.
from view_vocabulary/fact_reader import ViewIdAttribute
import styles/generated/design_tokens

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 157
    ## Written from a run, not estimated: **18** cases — four in suite 1, six
    ## in suite 2, five in suite 3, two in suite 4 and this count case — over
    ## one seeded window. `std/unittest` prints one `[OK]` per test BLOCK and
    ## never one per `check`, so a file of empty cases scores a full pass; this
    ## count is what makes a case that stopped running fail instead (§7).
    ##
    ## Most of the 157 are the per-row and per-cell loops: six body rows times
    ## four cells, read for weight and for colour, is where the bulk sits.
  WindowStart = 240
  WindowRows = 6
  WholeLog = 1000
    ## **THE THREE NUMBERS THE ARM-C DISTINCTION RESTS ON**, and none of them
    ## may be equal to another: `WindowRows` is what a rows-in-hand footer
    ## would report, `WholeLog` is what the spec's `recordsTotal` reports, and
    ## `WindowStart` is what makes the FIRST field wrong too for an
    ## implementation that forgot the offset.

# ---------------------------------------------------------------------------
# A seeded event log, in process
# ---------------------------------------------------------------------------

proc seededVm(start, shown, total: int): EventLogVM =
  ## An `EventLogVM` holding ONE WINDOW of a larger log.
  ##
  ## Seeded through `ReplayDataStore.applyEventLogRows` — the store's own
  ## documented producer entry point, *"the ONE place every producer ends"* —
  ## rather than by writing the ViewModel's signals, so the window this test
  ## renders is one the real `ct/update-table` path can produce. Its
  ## `recordsTotal` argument is taken VERBATIM when supplied (the store's own
  ## comment: *"A producer that DOES know … passes it and it is taken
  ## verbatim"*), which is what lets the total differ from the rows in hand.
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  result = createEventLogVM(store)
  var rows: seq[EventLogRow] = @[]
  for i in 0 ..< shown:
    rows.add EventLogRow(eventIndex: start + i, kind: "stdout",
                         value: "line " & $(start + i),
                         rrTicks: uint64((start + i) * 10))
  store.applyEventLogRows(rows, start, total, total, elwsTable)
  drainPlatformCallbacks()

type Drawn = object
  plan: JsonNode
  drew: bool

proc drawEventLog(vm: EventLogVM): Drawn =
  ## Render the pane the way `renderPaneView`'s event-log arm does, and return
  ## the render plan GPUI would execute.
  gpui_reset_tree()
  let r = GpuiRenderer()
  let parent = r.createElement("div")
  var pv = eventLogPaneView(vm)
  result.drew = renderEventLog(r, parent, vm, pv)
  result.plan = parseJson(r.renderPlanJson(parent))

# ---------------------------------------------------------------------------
# Plan readers — `test_plat40_state_pane_columns.nim`'s, same spellings
# ---------------------------------------------------------------------------

proc attr(n: JsonNode; name: string): string =
  if n.isNil: return ""
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  not n.isNil and n{"attributes"}.kind == JObject and
    n["attributes"].hasKey(name)

proc style(n: JsonNode; name: string): string =
  if n.isNil: return ""
  n{"styles"}{name}.getStr

proc kids(n: JsonNode): seq[JsonNode] =
  ## A node's children, @[] for a nil node. `n{"children"}.len` on a nil
  ## `JsonNode` SEGFAULTS, and a red control that removes a node reaches this
  ## line holding nil — which is §69's MIS-ATTRIBUTED arm rather than a killed
  ## one, so the nil is absorbed here on purpose.
  if n.isNil: return @[]
  n{"children"}.getElems

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.isNil or n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  ## A node's own text plus its descendants', in plan order. The footer's text
  ## is in a child text node, not on the element.
  if n.isNil or n.kind != JObject: return ""
  result = n{"text"}.getStr
  for c in n.kids: result.add c.textOf

proc firstWith(plan: JsonNode; attribute: string): JsonNode =
  let all = plan.nodesWith(attribute)
  if all.len == 0: nil else: all[0]

# ---------------------------------------------------------------------------

suite "PLAT35-F5: the footer's text is the window AND the whole log":

  test "the desktop's own footer, to the byte (PLAT35-PD2)":
    # `PLAT35-PD2` records the Electron pane's footer as `Rows 1 to 6 of 6`,
    # and §6 makes the desktop the reference. This is that string.
    ck eventLogFooterText(0, 6, 6) == "Rows 1 to 6 of 6"

  test "the count is the WHOLE log, not the rows in hand":
    # The case the whole file exists for. Six rows, a thousand-event log.
    ck eventLogFooterText(0, WindowRows, WholeLog) ==
       "Rows 1 to 6 of 1000"
    ck not eventLogFooterText(0, WindowRows, WholeLog).endsWith("of 6")

  test "a paged window names its own offset, so the FIRST field moves too":
    ck eventLogFooterText(WindowStart, WindowRows, WholeLog) ==
       "Rows 241 to 246 of 1000"

  test "the total is floored by the window, so it never reads `of 0`":
    # `store.eventLog.recordsTotal` is documented as a HIGH-WATER MARK, and
    # the store floors it the same way when a producer supplies none
    # (`replay_data_store.nim:1640-1641`). A footer printing `of 0` over six
    # drawn rows would visibly disagree with the rows above it.
    ck eventLogFooterText(0, 6, 0) == "Rows 1 to 6 of 6"
    ck eventLogFooterText(WindowStart, WindowRows, 0) ==
       "Rows 241 to 246 of 246"

suite "PLAT35-F5: the DRAWN footer reads the ViewModel's total":

  setup:
    let vm = seededVm(WindowStart, WindowRows, WholeLog)
    let d = drawEventLog(vm)

  test "the ViewModel really does hold a window smaller than its log":
    # A POSITIVE CONTROL on the fixture itself. If the seeding silently failed
    # — a producer path that ignored `recordsTotal`, a `drain` that did not
    # run — every count case below would be comparing two sixes and passing
    # for the wrong reason.
    ck vm.eventRows.val.len == WindowRows
    ck vm.totalEventCount.val == WholeLog
    ck vm.store.eventLog.loadedStart.val == WindowStart
    ck vm.totalEventCount.val != vm.eventRows.val.len

  test "the pane drew data, and drew exactly one footer":
    ck d.drew
    ck d.plan.nodesWith(EventLogFooterAttribute).len == 1

  test "the footer's text names the window and the whole log":
    let f = d.plan.firstWith(EventLogFooterAttribute)
    ck f.textOf == "Rows 241 to 246 of 1000"

  test "the published total is the ViewModel's, NOT the rows in hand":
    # The arm-C invariant, asserted on the attribute rather than on the text,
    # so a footer that printed the right string from the wrong number still
    # fails.
    let f = d.plan.firstWith(EventLogFooterAttribute)
    ck f.attr(EventLogTotalAttribute) == $WholeLog
    ck f.attr(EventLogTotalAttribute) != $WindowRows
    ck f.attr(EventLogTotalAttribute) != $(d.plan.nodesWith(
      "data-row-index").len)

  test "the footer carries NO column index, so a click cannot re-sort the log":
    # `window_clicks.nim:211-217` classifies a press inside the `eventLog`
    # context as a HEADER CELL when the element has a `data-column-index` and
    # its parent has no `data-row-index` — exactly the shape a footer built
    # out of column cells would have. Such a footer would re-order the event
    # log when clicked, which is `PLAT35-F7`'s clause in reverse.
    let f = d.plan.firstWith(EventLogFooterAttribute)
    ck not f.has("data-column-index")
    ck f.nodesWith("data-column-index").len == 0
    ck not f.has("data-row-index")

  test "the footer is OUTSIDE the table, so the table's subtree is untouched":
    # The vocabulary binding's own tree is left byte-for-byte as it was: the
    # footer is a sibling of the table element, not a child of it.
    let tables = d.plan.nodesWith(ViewIdAttribute)
    var tableNode: JsonNode = nil
    for t in tables:
      if t.attr(ViewIdAttribute) == "eventLog": tableNode = t
    ck not tableNode.isNil
    ck tableNode.nodesWith(EventLogFooterAttribute).len == 0

suite "PLAT35-F12: the header row reads as a header":

  setup:
    let vm = seededVm(WindowStart, WindowRows, WholeLog)
    let d = drawEventLog(vm)

  test "exactly one row is marked the header, and it is the row with no index":
    ck d.plan.nodesWith(EventLogHeaderAttribute).len == 1
    let h = d.plan.firstWith(EventLogHeaderAttribute)
    # The click classifier's own definition of the header row
    # (`window_clicks.nim:211-213`). One definition, two readers.
    ck not h.has("data-row-index")
    ck h.kids.len > 0

  test "the header carries the rule, in the PUBLISHED token":
    let h = d.plan.firstWith(EventLogHeaderAttribute)
    ck h.style("border_bottom_width") == "1px"
    # **AGAINST THE GENERATED TABLE, NOT AGAINST THE RENDERER'S OWN
    # CONSTANT.** The rendered value is compared to `DesignTokenHex` directly,
    # so a rule drawn in ANY other value — including a plausible wrong token,
    # which is what arm `N4` now substitutes — fails here.
    ck h.style("border_color") == DesignTokenHex[dtColorsUiBorderPrimary][dmDark]
    # And the constant agrees with what was drawn, so the two cannot drift.
    ck h.style("border_color") == EventLogRuleColour
    #
    # **WHAT THIS CASE CANNOT DO, STATED RATHER THAN IMPLIED.** It cannot
    # catch a HEX LITERAL that is numerically equal to the token. That was
    # MEASURED, not reasoned: arm `N4` originally replaced
    # `DesignTokenHex[dtColorsUiBorderPrimary][dmDark]` with the literal
    # `"#565656"` — its own correct dark value — and the arm **SURVIVED**,
    # because every runtime comparison available here is between two strings
    # that are equal. A literal is a SOURCE property and no assertion over the
    # render plan can see it; claiming otherwise would be a check that reads
    # as teeth and has none. The arm was re-aimed at a wrong token, which this
    # case does catch, and the literal question is left to review.

  test "no DATA row carries the rule — it is the header's, not every row's":
    for row in d.plan.nodesWith("data-row-index"):
      ck row.style("border_bottom_width") == ""

  test "the header's cells differ from a data row's in COLOUR and in WEIGHT":
    # The finding's own words: *"its header row is the same weight and colour
    # as a data row"*. Both halves are asserted, because `layOutRow` gave the
    # two rows one style object and either half alone could be restored
    # without the other.
    let h = d.plan.firstWith(EventLogHeaderAttribute)
    ck h.kids.len > 0
    for cell in h.kids:
      ck cell.style("font_weight") == "bold"
      ck cell.style("text_color") == EventLogHeaderColour
    let rows = d.plan.nodesWith("data-row-index")
    ck rows.len == WindowRows
    for row in rows:
      ck row.kids.len > 0
      for cell in row.kids:
        ck cell.style("font_weight") != "bold"
        ck cell.style("text_color") != EventLogHeaderColour

  test "the header's style object is no longer a data row's":
    # Stated as the finding stated it — one style object shared by every row —
    # so the case reads as the refutation of the measurement it answers.
    let h = d.plan.firstWith(EventLogHeaderAttribute)
    for row in d.plan.nodesWith("data-row-index"):
      ck h{"styles"} != row{"styles"}

suite "PLAT35-F12: what is NOT drawn, and why it is residue":

  setup:
    let vm = seededVm(WindowStart, WindowRows, WholeLog)
    let d = drawEventLog(vm)

  test "NO zebra: no row carries a background at all":
    # **Not specified. Not drawn.** `Event-Log-Pane.md` at `90ff8fce` says
    # nothing about alternating backgrounds (zero hits for zebra / alternat /
    # stripe), the terminal's event log draws none, and the design system
    # publishes no pair of row grounds to alternate between — which is
    # `PLAT35-F10`'s situation exactly: blocked for want of a published
    # value, not pending. Drawing one here would be this renderer inventing a
    # visual language, so the finding's third sub-claim stays OPEN and this
    # case holds the invention shut.
    for row in d.plan.nodesWith("data-row-index"):
      ck row.style("bg") == ""

  test "NO column dividers: no cell carries a rule of its own":
    # **Not specified. Not drawn.** The state pane's single column rule is
    # published — thirteen of its spec's wireframed rows carry a `|` at a
    # constant column — and the event log's spec publishes no such thing for
    # any of its columns. `PLAT35-PD2` records that Electron's event log has
    # NO COLUMN HEADERS AT ALL, so the desktop is worse here than GPUI and
    # cannot be the reference for dividers either.
    for row in d.plan.nodesWith("data-row-index"):
      for cell in row.kids:
        ck cell.style("border_left_width") == ""
        ck cell.style("border_right_width") == ""

suite "PLAT35-F5 / F12: every case in this file ran":

  test "the assertion count is the one this file declares":
    checkpoint("counted " & $CHECKS & ", expected " & $ExpectedAssertions)
    doAssert CHECKS == ExpectedAssertions,
      "counted " & $CHECKS & " assertions, declared " &
      $ExpectedAssertions &
      " — a case stopped running, or one was added without updating the count"
