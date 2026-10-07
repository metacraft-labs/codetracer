## test_plat40_state_pane_columns.nim — **TIER 3 OVER THE STATE PANE'S TWO
## COLUMNS: `PLAT35-F4`, AND ITS ACTIVE TAB'S WORD: `PLAT35-F9`.**
##
## The second finding is here rather than in a suite of its own because it is
## the same pane and the same instrument, and because what closed it was
## `PLAT35-F4`'s own `leaves.renderState` — see the case *"the pane draws its
## ACTIVE TAB's word exactly ONCE"* for what it asserts, what would satisfy it
## if it stood alone, and which half of the finding is deliberately left to
## the UNSTEPPED case below it.
##
## Run (needs the real `isonim-gpui` shim at the baked path and the built
## binary, like every suite that imports `app/leaves` AND reads
## `--report-window-plan`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat40_state_pane_columns.nim
##
## ## The finding, and what it was measured as
##
## `PLAT35-F4`: *"the state pane's rows are flat `name: value` strings: no
## type field, and no column structure, so name, type and value cannot be
## distinguished and nothing aligns vertically."* Measured at `73e8c3dc4` and
## RE-measured at `42655fd72`, over all seven `scenarios.json` plans: the pane
## body was `Collapsible state -> Tabs state.tabs -> Tree state.root` with one
## `Tree` node per name whose **entire text was one run** — `__file__: "…"`,
## `add: <function add at 0x10666c2c0>`, `__cached__: nil` — and `data-column`
## occurred **ZERO** times in the subtree. Four independent pixel readers:
## *"the value begins immediately after the colon following the name, so its
## starting x-position varies per row … Nothing is vertically aligned into a
## column"*, *"no header row"*.
##
## ## WHAT THE SPEC PUBLISHES, AND THEREFORE WHAT THIS SUITE ASSERTS
##
## `codetracer-specs/spec/GUI/Core-Panes/Variable-State-Pane.md`
## §"Variable Display" publishes a table of **TWO** columns:
##
##     | Column | Description                                  |
##     | Name   | Variable or expression name                  |
##     | Value  | Current value (expandable for complex types) |
##
## and §"Column Resizing" draws the same two over a `| Name | Value |` header
## with *"The Name/Value column separator can be dragged to resize"*. The
## pane's ASCII Reference wireframe shows `| Name | Value |` too.
##
## **THERE IS NO TYPE COLUMN IN THE SPEC, AND THIS SUITE DOES NOT ASSERT
## ONE.** The finding was filed against `tools/visual-review-brief.md`'s
## `editor` block, which asks for *"name, type and value per row"*; the brief
## is the review instrument and the spec is the published specification, and
## on this point they disagree. `store_types.Variable.typeName` is in reach of
## `leaves.renderState` and is deliberately not drawn — see that proc's
## `StateHeaderValueLabel` comment and `PLAT35-F4.specCorrection`. A type
## column is a spec change (it moves Electron and the design system too) and
## is not taken here.
##
## **THE NAME/VALUE COLUMN RULE IS DRAWN, AND THE SPEC DOES PUBLISH IT. THE
## TEXT THAT STOOD HERE SAID THE OPPOSITE AND IS RETRACTED.** The census that
## settles it, by CODEPOINT and COLUMN INDEX over **all five** fenced
## wireframes of `Variable-State-Pane.md` — measured at the THIRD adversarial
## review of 2026-10-04 (the one that read the wireframes; three reviews
## share that date and are distinguished here by what each measured), and
## re-measured from this pass before being written down:
##
##     | block   | section                | interior U+007C rows | col |
##     | 47–56   | Value Expansion        | 0 — AND NO OUTER FRAME | — |
##     | 75–82   | Value History          | 0                    | —   |
##     | 92–98   | Column Resizing        | 2 (94, 96)           | 14  |
##     | 191–214 | ## Wireframe (ASCII …) | 10 (197, 199–206, 208) | 26 |
##     | 254–263 | Desired Future Design  | 1 (256)              | 28  |
##
## THIRTEEN wireframed rows carry the bar at a CONSTANT column, with the
## ASCII Reference's outer frame at 0 and 67. Block 47–56 draws no `|` at
## all, outer or interior — it is a frameless tree diagram — so its silence
## about an interior rule is not a statement about one, and the retracted
## text rested its whole case on that silence.
##
## **THREE RETRACTIONS, IN THE WORDS THEY WERE PUBLISHED IN.**
##  1. RETRACTED: *"the `+---...---+` rules bracketing them carry no `+` at
##     the column position."* **THE PROBE FAILS ITS OWN POSITIVE CONTROL.**
##     §"Column Resizing" guarantees the subject in prose — *"The Name/Value
##     column separator can be dragged to resize"* — and its rules carry `+`
##     at columns 0 and 28 and **none at column 14**, where both of its rows
##     put the bar. A probe that answers "no boundary" where the boundary is
##     textually guaranteed is measuring the wrong thing
##     (`Verification-Harness-Traps` §67).
##  2. RETRACTED as evidence: *"`State.ColumnResize` is ranked `Low`."* It
##     ranks the DRAG's test priority, and its own description — *"Drag
##     column separator to resize"* — names the separator as existing.
##  3. RETRACTED as evidence: the *"no separator element"* row at line 148.
##     It is the **BlockTracer** column of §"Applicability: this pane is
##     CodeTracer-only", which excludes it from this pane.
##
## **WHAT STANDS FROM THE EARLIER PASSES, BECAUSE IT WAS MEASURED:** the rule
## paints iff it declares its OWN height (four arms; a row's `height: 26px`
## does not reach a childless child), and the frame holds `#47494C` and never
## the declared `#565656` — that token over the pane's `#1b222c` ground at
## coverage ≈ 0.75. An exact-token probe returns zero in a WORKING build, and
## that false negative is what deleted the rule twice.
## `leaves.StateSeparatorAttribute` carries both arms.
##
## **SO THE CASE BELOW IS RE-POINTED RATHER THAN DELETED** — it was
## *"at <vp> NO column boundary is drawn, and none is faked"* and its own
## comment asked a later pass to re-point it; this is that pass. It now
## asserts the rule's GEOMETRY and the arithmetic from its declared token to
## the colour a framebuffer actually holds. **THE DRAG IS STILL NOT DRAWN AND
## THE CASE STILL GATES THAT**: no `data-ct-drag`, no `cursor`, no click
## handler anywhere in the row, the rule included — §7a and
## `Cross-Renderer-Visual-Alignment.md`'s *"A rendered affordance must do the
## thing it advertises, or not be rendered"*. A static rule is not an
## affordance; a `col-resize` cursor over no drag would be.
##
## **THE RENDERED COLOUR IS NOT THIS SUITE'S TO MEASURE AND IT SAYS SO.**
## Nothing here opens a window. What the case asserts is the DECLARED token,
## read off the plan, and the composite it becomes — so that no later probe
## searches a framebuffer for `#565656` again. The frame-level reading is the
## capture lane's, and `PLAT35-F4.confirmedBy` carries it with its positive
## control.
##
## ## §7 / §7b: what each case would be satisfied by if it stood alone
##
## Stated because an assertion that cannot fail is the defect this campaign is
## about, and this finding has a named trap: **columns that exist but do not
## align**. A `data-column` census alone is satisfied by two cells per row
## that both start at x = 0.
##
##   1. *`data-column` is present* — satisfied by any two cells, aligned or
##      not, and by a header with no rows under it. So the census is never
##      asserted alone: the pane case requires the count to be exactly
##      `2 * (rows + 1)`, the cells to be `name` then `value` **in that
##      order**, and the pane to hold more than one row.
##   2. *a header exists* — satisfied by a bare `data-state-header`
##      attribute. So the header's own two cells are required to carry the
##      spec's two headings, `Name` and `Value`, as their text.
##   3. *the columns align* — **this is arm C's target.** Satisfied by every
##      name cell being content-sized if nobody compares them, and satisfied
##      vacuously if every row's name happens to be the same length. So:
##      every `name` cell's width is required to be ONE distinct value; the
##      value column's x is recomputed from the drawn BOXES — the name cell's
##      width, the rule's width and the value cell's inset, which is the sum
##      a layout engine adds up — and required to
##      be identical on every row; it is required to be **non-zero** (the
##      "all at x=0" trap); and the body rows are required to contain **at
##      least two different name lengths**, without which equal widths would
##      prove nothing.
##   4. *the width is right* — satisfied by a constant. So suite 1 pins
##      `stateNameColumnPx` against LITERALS over row sets no recording has
##      to reach (empty, one short name, a deep row, a name past the
##      ceiling), and the pane case then requires the DRAWN width to equal
##      what that rule answers for the pane's own drawn names.
##
##      **AND THAT WAS NOT ENOUGH UNTIL A THIRD STOP WAS ADDED — CAUGHT AT
##      ADVERSARIAL REVIEW, 2026-10-04.** The drawn-width case compares
##      `stateNameColumnPx(drawn)` against what the plan drew, and **both of
##      the two original `PopulatedOps` stops answer 96 px**. So a renderer
##      that HARDCODED `96px` passed the drawn-width case, the alignment case
##      and all of suite 1, with nothing in the file catching it. (The earlier
##      wording here, *"a constant passes neither"*, overstated: a constant
##      equal to the one answer both stops give passed both.) `stepIn=21,
##      stepOut=1` — `scenarios.json`'s `returned-calltrace` — is the third
##      stop, and it answers a DIFFERENT width: measured on this host at both
##      viewports, **19 body rows, name column 88 px, `data-state-value-x`
##      95**, because its widest drawn name is `EXPRESSIONS` (11) and not
##      `__builtins__` (12). A hardcoded 96 now reddens the drawn-width case
##      at both viewports, which is the arm-E red control in the ledger.
##      **Two stops with the same answer are one stop.**
##   5. *the rows are the ViewModel's* — satisfied by a renderer that
##      invented them. `leaves.stateRows` re-derives the expansion rule that
##      `pane_views.variableRow` owns (two derivations of one rule is §30), so
##      suite 2 compares its paths against `statePaneView`'s own visible
##      `Tree` row ids for the same ViewModel and fails if they differ.
##   6. *the pane still works* — satisfied by a pane that lost its tab strip.
##      `renderState` takes over `state.root` ONLY; the case asserts the
##      vocabulary `Tabs` is still there (three options, `Locals` highlighted)
##      and that the unstepped scenario still draws the vocabulary's own
##      report with `data-ct-state: pane-report` and no columns at all.
##   7. *the column rule is drawn* — **satisfied by an INVISIBLE element, and
##      that is not hypothetical: it is what happened.** A `div` carrying
##      `data-state-separator` and a background but no height of its own
##      occupies its 1 px of layout width and paints nothing (four measured
##      arms on `leaves.StateSeparatorAttribute`), so a census of the
##      attribute is worth nothing on its own. The case therefore requires
##      the two declarations that make it paint — its own `height` equal to
##      the row pitch, and `flex-shrink: 0` — plus its width, its position
##      BETWEEN the two cells, and one per row INCLUDING the header's; and it
##      requires the declared colour to be the token rather than a hex
##      somebody typed, with the composite the frame actually holds pinned
##      beside it so the next probe does not look for the wrong bytes.
##
## ## §4: SCOPED TO THE PANE
##
## Every plan assertion is made inside the subtree whose `data-ct-pane` is
## `state`. The first draft of `test_plat40_calltrace_current_frame.nim` was
## scoped to the whole plan and went red at 3 because the STATE pane's tab
## strip is a vocabulary `List`; this suite's mirror of that mistake would be
## counting `data-column` over the whole window — and that is not
## hypothetical. **`data-column` IS ALREADY TAKEN.** The vocabulary binding
## publishes a `Table`'s own `column` field as a fact under exactly that name,
## and the EVENT LOG is a `Table`: measured on this host's plan, `data-column`
## occurs **25** times in the window and **24** in the state pane, the odd one
## being `data-column: "0"` on the event log's `Table` node. The name is kept
## — it is the one `PLAT35-F4`'s remedy asks for — and the collision is a
## case of its own rather than a footnote.
##
## ## The one thing this suite does NOT assert
##
## Pixels. Nothing here opens a window. The frame-level reading is the capture
## lane's (`ci/test/plat35-gpui-capture.sh`) and the tier-4 ledger's. What is
## asserted is the shipped binary's own reported plan at both of
## `scenarios.json`'s viewports.
##
## ## Trap 13 / §29
##
## Every helper that calls `check` is a `template`. The `proc`s return values.

import std/[json, os, osproc, sets, streams, strtabs, strutils, tables,
            tempfiles, unittest]

import codetracer_embed
import gpui/app/leaves
import view_vocabulary/pane_views

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 1747
    ## Written from a run, not estimated: **31** cases (six in suite 1, four
    ## in suite 2, TEN × two viewports in suite 3, and the count case) over
    ## this host's plan at both viewports and three populated stops. It was
    ## 27 cases / 1299 assertions before the pass that drew the column rule,
    ## which re-pointed one case and added a second beside it. The 362 new
    ## assertions are mostly the per-row loop over the rule: thirteen rows and
    ## a header, times fifteen readings, times three stops is where they are.
    ##
    ## **1661 → 1705 AT THE PLAT-50 MERGE, 2026-10-05, AND THE CASE COUNT DID
    ## NOT MOVE.** The tab-strip case stopped asserting one thing per
    ## `data-view-id` node it happened to find — a contribution that moved
    ## with the rows — and now asserts a FIXED pair (the state tree has
    ## exactly one owner, and it is the table) plus two readings per body row
    ## (that each row is a vocabulary `Tree` row and names its variable),
    ## which is the PLAT-50 click contract this renderer now relies on. The
    ## +44 is MEASURED from the run, not derived: no case was added or
    ## removed.
    ##
    ## **1705 → 1747, 2026-10-07, AND THIS TIME A CASE WAS ADDED** — the
    ## tenth in suite 3, *"the pane draws its ACTIVE TAB's word exactly
    ## ONCE"*, which gates `PLAT35-F9`'s residue. **+42 = 7 readings x 3
    ## populated stops x 2 viewports**, and the arithmetic is checkable rather
    ## than asserted: this suite's counted total was 1641 against a declared
    ## 1705 at `bc915c73d` before the case existed and 1683 against 1747
    ## after, so the shortfall is 64 in both runs. A contribution that was not
    ## exactly 42 would have moved it. (The 64 itself is this suite's known
    ## pre-existing red and is NOT this case's: it predates it at the
    ## unmodified bytes.)
    ## `std/unittest` prints one `[OK]` per test BLOCK and
    ## never one per `check`, so a file of empty cases scores a full pass; this
    ## is what makes a case that stopped running fail instead (§7).
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  Viewports = [(1920, 1080), (1440, 900)]
    ## `scenarios.json`'s two, which are the two the finding was measured at.
  PopulatedOps = ["stepIn=5", "stepIn=5,next=3", "stepIn=21,stepOut=1"]
    ## `stepped-editor`'s, `advanced-state`'s and `returned-calltrace`'s
    ## operation sequences — the three `scenarios.json` stops at which the
    ## pane has variables to put in columns. FIVE stepIns, not six, since the
    ## engine opens a recording in the program's entry call rather than on the
    ## trace root's synthetic entry step one step earlier: the same stops
    ## (line 44, and three `next`s on), as `scenarios.json` records.
    ##
    ## **THE THIRD ONE IS HERE BECAUSE THE FIRST TWO BOTH ANSWER 96 px.**
    ## Measured on this host at both viewports: `stepIn=5` draws 11 body rows
    ## and `stepIn=5,next=3` draws 12, and BOTH get a 96 px name column and
    ## `data-state-value-x` 103, because `__builtins__` (12 chars) is the
    ## widest drawn name in each. So the drawn-width case below — the one that
    ## is supposed to catch a width that is not the rule's answer — was
    ## satisfied by a HARDCODED 96. `stepIn=21,stepOut=1` is the stop a frame
    ## has been entered and RETURNED FROM, and its pane carries no
    ## `__builtins__` at all — the names it draws are `EXPRESSIONS`,
    ## `OPERATIONS`, the seven surviving dunders, and `add` … `value` — so its
    ## widest name is `EXPRESSIONS` (11) and the column is **88 px with
    ## `data-state-value-x` 95, over 19 body rows**, at both viewports. A
    ## second answer is what makes the correspondence falsifiable (§7b).
  UnsteppedOps = ""
    ## `entry-shell`'s. The population control for case 6: at entry the pane
    ## has no variables and must still be the vocabulary's report.
  StateGroundHex = "#282828"
    ## The state pane's own background, as the plan reports it. Asserted
    ## against the plan rather than assumed, because it is one end of the
    ## blend the column rule's rendered colour is.
    ##
    ## **RE-MEASURED AT THE PLAT-50 MERGE (2026-10-05), AND IT MOVED.** It
    ## read `#1b222c` until then. PLAT-50 (`0a52bd0aa`, *"the desktop's chrome
    ## colours"*) re-grounded the panes on the DESKTOP'S measured tokens —
    ## `main.PanelGround = "#282828"  # ui/surface/base/panel, Dark` — and
    ## that commit's own notes name `#1b222c` as the value it replaced and
    ## describe the border *"(#565656) over the #282828 panes"*. So this is
    ## upstream's deliberate change showing through a carried literal, not a
    ## regression here: the rule's GEOMETRY did not move at all (x 767, 277 of
    ## 277 rows, y 176-452 contiguous, measured both before and after).
  SeparatorRenderedHex = "#4b4b4b"
    ## **WHAT THE FRAMEBUFFER HOLDS WHERE THE RULE IS DRAWN**, and it is NOT
    ## `leaves.StateSeparatorColour`. `(75, 75, 75)`, MEASURED in
    ## `build/plat35/gpui/state.png` at the merged bytes — the declared
    ## `#565656` over `StateGroundHex` at coverage ≈ 0.76. A CARRIED
    ## measurement: nothing in this file opens a window, and the case that
    ## uses it says so and asserts the arithmetic instead.
    ##
    ## **RE-MEASURED AT THE PLAT-50 MERGE, AND IT MOVED WITH THE GROUND.** It
    ## read `#47494c` = `(71, 73, 76)` over the old `#1b222c`. The rule still
    ## declares the same token; only the ground under it changed, so the
    ## composite did. Found by a STRUCTURAL probe that discovers the rule
    ## rather than searching for a colour — the column where one pixel sits
    ## between two pixels of the same ground on the most rows — which answered
    ## x = 767 on 281 rows against 28 for the runner-up, and the colour was
    ## then READ OFF those rows. The declared `#565656` meanwhile counts 429
    ## in this very frame, which is why an exact-token probe is not merely
    ## blind here but insensitive (`Verification-Harness-Traps` §67).
  PaneAttr = "data-ct-pane"               # `leaves.PaneRoleAttribute`
  StateAttr = "data-ct-state"             # `leaves.StateAttribute`
  HighlightedAttr = "data-highlighted"    # the vocabulary binding's
  ViewKindAttr = "data-view-kind"
  ViewIdAttr = "data-view-id"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                     repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

# ---------------------------------------------------------------------------
# Reading the shipped binary's plan
# ---------------------------------------------------------------------------

var planCache = initTable[string, JsonNode]()

proc windowPlan(width, height: int; ops: string): JsonNode =
  ## The window's root as the shipped binary reports it, at `width`x`height`
  ## after the replay operations `ops`. Cached: one process per distinct
  ## reading.
  ##
  ## `--report-window-plan` and NOT `--report-plan`: the two instruments are
  ## different readers of one tree and only the first serialises an attribute
  ## map (`leaves.PaneRoleAttribute`'s own comment says so, measured). A suite
  ## that asked `--report-plan` for `data-column` would get an empty answer,
  ## and an empty answer satisfies every assertion anybody would write over
  ## it (Verification-Harness-Traps §4).
  let key = $width & "x" & $height & "|" & ops
  if key in planCache:
    return planCache[key]
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if not dirExists(calc):
    raise newException(IOError, "prerequisite missing: " & calc &
                       " (run 'just test-tui' once)")
  let state = createTempDir("plat40-statecols-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env["DYLD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("DYLD_LIBRARY_PATH"): ":" & getEnv("DYLD_LIBRARY_PATH")
     else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  var args = @["--report-window-plan", "--width=" & $width,
               "--height=" & $height]
  if ops.len > 0:
    args.add "--replay-ops=" & ops
  args.add calc
  let errFile = genTempPath("plat40-statecols-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result = parseJson(output)
  planCache[key] = result

# **EVERY READER BELOW TOLERATES A NIL NODE, AND THAT IS A HARNESS
# REQUIREMENT RATHER THAN DEFENSIVENESS.** A red control removes a node this
# suite asserts the existence of; `ck` records a failure and KEEPS GOING
# (`std/unittest`'s `check` is not an abort), so the next line is reached with
# `nil` in hand. The first draft of this file SEGFAULTED under arm A instead of
# failing — and a crashed arm scores MIS-ATTRIBUTED, not KILLED, which is the
# difference between a demonstrated red control and a broken one.
#
# **AND THE RULE WAS NOT YET KEPT EVERYWHERE: ARM A STILL RAISED `IndexDefect`
# AT ITERATION 8**, on `pane.bodyRows[0]` in the drawn-width case, at BOTH
# viewports. The reason it survived two graded runs is worth the line: the case
# printed a `[FAILED]` verdict anyway, because `std/unittest` catches the
# defect — so in the log an ABORTED case is indistinguishable from a FAILED
# one, and only one of them ran its remaining assertions. `bodyRowAt` and
# `cellAt` close it; see `bodyRowAt`.
proc attr(n: JsonNode; name: string): string =
  if n.isNil: return ""
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  not n.isNil and n{"attributes"}.kind == JObject and
    n["attributes"].hasKey(name)

proc style(n: JsonNode; name: string): string =
  if n.isNil: return ""
  n{"styles"}{name}.getStr

proc pxStyle(n: JsonNode; name: string): int =
  ## A `<n>px` style as an int. -1 when absent, nil or unparseable, so a
  ## missing width cannot read as zero and quietly satisfy an equality.
  let raw = n.style(name)
  if not raw.endsWith("px"):
    return -1
  try: parseInt(raw[0 ..< raw.len - 2])
  except ValueError: -1

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.isNil or n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc kids(n: JsonNode): seq[JsonNode] =
  ## A node's children, @[] for a nil node. `n{"children"}.len` on a nil
  ## `JsonNode` SEGFAULTS, and a red control that removes a node reaches this
  ## line holding nil — see the comment above `attr`. Arm A and arm B both
  ## crashed here before this helper existed.
  if n.isNil: return @[]
  n{"children"}.getElems

proc textOf(n: JsonNode): string =
  if n.isNil: return ""
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc textNodeCount(n: JsonNode): int =
  if n.isNil: return 0
  if n{"kind"}.getStr == "TextNode": return 1
  for c in n{"children"}.getElems: result += textNodeCount(c)

proc textNodes(n: JsonNode): seq[string] =
  ## Every TEXT NODE's own text, separately, in document order.
  ##
  ## `textOf` is the wrong instrument for PLAT35-F9's question and that is why
  ## this exists beside it: `textOf` CONCATENATES a subtree into one string, so
  ## "the pane draws `Locals` twice, in two places" and "the pane draws one
  ## label that happens to contain the word twice" become the same string, and
  ## a `count` over the join cannot separate them. The finding is about two
  ## DRAWN LABELS, so the instrument counts labels.
  if n.isNil: return @[]
  if n{"kind"}.getStr == "TextNode": return @[n{"text"}.getStr]
  for c in n{"children"}.getElems: result.add textNodes(c)

proc nodesWithOutside(plan: JsonNode; attribute, pane: string): seq[JsonNode] =
  ## Every node carrying `attribute` that is NOT inside the pane whose
  ## `data-ct-pane` is `pane`.
  ##
  ## A walk that STOPS at the pane's root rather than a set difference:
  ## `JsonNode` is a ref whose `==` is STRUCTURAL (std/json), so two cells
  ## with identical attributes and styles compare equal and a set difference
  ## would silently drop the wrong ones. Measured the hard way.
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.isNil or n.kind != JObject: return
    if n.attr(PaneAttr) == pane: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc paneOf(plan: JsonNode; pane: string): JsonNode =
  ## The subtree of the pane whose `data-ct-pane` is `pane`. Nil when the pane
  ## is not in the plan, which every caller asserts against.
  for n in plan.nodesWith(PaneAttr):
    if n.attr(PaneAttr) == pane: return n
  nil

proc tableOf(pane: JsonNode): JsonNode =
  if pane.isNil: return nil
  for n in pane.nodesWith(StateTableAttribute): return n
  nil

proc headerRow(pane: JsonNode): JsonNode =
  if pane.isNil: return nil
  for n in pane.nodesWith(StateHeaderAttribute):
    if n.attr(StateHeaderAttribute) == "true": return n
  nil

proc bodyRows(pane: JsonNode): seq[JsonNode] =
  if pane.isNil: return @[]
  pane.nodesWith(StateRowAttribute)

proc cells(row: JsonNode): seq[JsonNode] =
  if row.isNil: return @[]
  for c in row{"children"}.getElems:
    if c.has(StateColumnAttribute): result.add c

proc cell(row: JsonNode; column: string): JsonNode =
  for c in row.cells:
    if c.attr(StateColumnAttribute) == column: return c
  nil

func channels(hex: string): array[3, int] =
  ## `#rrggbb` as three ints, `[-1, -1, -1]` for anything else — so a hex
  ## that stopped parsing cannot read as black and satisfy an inequality.
  if hex.len != 7 or hex[0] != '#': return [-1, -1, -1]
  for i in 0 .. 2:
    try:
      result[i] = parseHexInt(hex[1 + 2 * i .. 2 + 2 * i])
    except ValueError:
      return [-1, -1, -1]

func mixAtThreeQuarters(fg, bg: string): array[3, int] =
  ## `fg` over `bg` at coverage 3/4, per channel, truncated — the composite a
  ## 1 px rule that does not land on one whole device pixel produces.
  let f = channels(fg)
  let b = channels(bg)
  if f[0] < 0 or b[0] < 0: return [-1, -1, -1]
  for i in 0 .. 2:
    result[i] = (3 * f[i] + b[i]) div 4

proc kidAt(row: JsonNode; i: int): JsonNode =
  ## A row's `i`-th child, nil when there is none.
  ##
  ## **A RED CONTROL THAT REMOVES A ROW REACHES THIS LINE HOLDING NOTHING**,
  ## and `row.kids[i]` on a shorter seq raises `IndexDefect` — which scores
  ## MIS-ATTRIBUTED, not KILLED, and is how two earlier drafts of this file
  ## died instead of failing. `check` does not abort a case, so the next line
  ## always runs; every reader here has to answer for an absent node.
  let ks = row.kids
  if i < 0 or i >= ks.len: return nil
  ks[i]

proc bodyRowAt(pane: JsonNode; i: int): JsonNode =
  ## The pane's `i`-th body row, nil when it has none.
  ##
  ## **`pane.bodyRows[0]` RAISED `IndexDefect` UNDER ARM A, MEASURED AT
  ## ITERATION 8, AND THAT WENT UNNOTICED FOR A REASON WORTH WRITING DOWN.**
  ## With the dispatch reverted the pane has no body rows; `check` does not
  ## abort, so the line after `ck drawn.len > 1` indexed an empty seq. The
  ## case still printed a `[FAILED]` line — `std/unittest` catches the defect
  ## — so in the log an ABORTED case and a FAILED case look identical, and
  ## only one of them ran its remaining assertions. **A crashed arm scores
  ## MIS-ATTRIBUTED, not KILLED**, and the two earlier drafts of this file
  ## that died in `has` and on `n{"children"}.len` are the same defect: this
  ## file's rule is that EVERY reader tolerates an absent node, and a bare
  ## `[0]` is not one.
  let rows = pane.bodyRows
  if i < 0 or i >= rows.len: return nil
  rows[i]

proc cellAt(row: JsonNode; i: int): JsonNode =
  ## This row's `i`-th CELL (the rule is not one), nil when there is none —
  ## `bodyRowAt`'s rule one level down. The three call sites below are each
  ## preceded by `ck cs.len == 2`, which does not abort, so an arm that made a
  ## row one cell would have aborted here rather than failing.
  let cs = row.cells
  if i < 0 or i >= cs.len: return nil
  cs[i]

proc separator(row: JsonNode): JsonNode =
  ## This row's column rule, nil when it has none.
  if row.isNil: return nil
  for c in row{"children"}.getElems:
    if c.has(StateSeparatorAttribute): return c
  nil

proc valueColumnXOf(row: JsonNode): int =
  ## **WHERE THIS ROW'S VALUE TEXT BEGINS, recomputed from the DRAWN
  ## geometry** — the name cell's width, THE RULE'S WIDTH and the value
  ## cell's own inset — and never read out of `StateAlignAttribute`. An
  ## attribute agreeing with itself is §7's assertion that cannot fail; this
  ## is the sum a layout engine would add up, and it adds up the rule because
  ## the layout engine does.
  ##
  ## -1 when any part is missing, so an absent width cannot read as zero.
  let name = row.cell(StateNameColumn)
  if name.isNil: return -1
  let w = name.pxStyle("w")
  if w < 0: return -1
  var x = w
  let rule = row.separator
  if rule.isNil: return -1
  let ruleW = rule.pxStyle("w")
  if ruleW < 0: return -1
  x += ruleW
  let value = row.cell(StateValueColumn)
  if value.isNil: return -1
  let pad = value.pxStyle("padding_left")
  if pad < 0: return -1
  x + pad

# ---------------------------------------------------------------------------
# A StateVM with constructed variables, for suite 2
# ---------------------------------------------------------------------------

proc nestedStateVM(): StateVM =
  ## A StateVM over a MockBackendService whose locals are a KNOWN shape: two
  ## top-level names, the second with two children, and only the second
  ## expanded. Constructed rather than recorded, because the question is what
  ## the flattening rule does with an expansion state no scenario reaches.
  let mock = newMockBackendService(autoRespond = false)
  let store = createReplayDataStore(mock.toBackendService())
  store.locals.locals.val = @[
    Variable(name: "alpha", value: "1"),
    Variable(name: "beta", value: "2", hasChildren: true, children: @[
      Variable(name: "gamma", value: "3"),
      Variable(name: "delta", value: "4", hasChildren: true, children: @[
        Variable(name: "epsilon", value: "5")])])]
  result = createStateVM(store)
  result.expandedPaths.val = toHashSet(["beta"])
  result.selectedPath.val = "beta.gamma"

# ---------------------------------------------------------------------------

suite "PLAT-40 / PLAT35-F4: the rule that decides the name column":

  # `leaves.stateNameColumnPx` is what makes the alignment claim true: ONE
  # width for the whole pane. Pinned against literals here so a drawing that
  # merely agrees with a changed rule cannot pass the pane cases below.

  test "the header alone sets the floor, not `Name`'s own four characters":
    # 4 * StateCharPx = 32, under the floor.
    ck stateNameColumnPx([]) == StateNameMinPx
    ck StateNameMinPx == 72
    ck StateHeaderNameLabel.len * StateCharPx == 32

  test "the WIDEST drawn name decides the column, not the first row":
    let rows = @[
      StateRow(name: "x", depth: 0),
      StateRow(name: "__builtins__", depth: 0),   # 12 * 8 = 96
      StateRow(name: "add", depth: 0)]
    ck stateNameColumnPx(rows) == 96
    # …and the answer does not depend on the order they are given in.
    ck stateNameColumnPx(@[rows[1], rows[0], rows[2]]) == 96
    # The widest name ALONE answers the same, which is what "one column for
    # the pane" means.
    ck stateNameColumnPx(@[rows[1]]) == 96

  test "a short pane still gets a readable column (the floor)":
    ck stateNameColumnPx(@[StateRow(name: "x", depth: 0)]) == StateNameMinPx
    ck stateNameColumnPx(@[StateRow(name: "ab", depth: 0)]) == StateNameMinPx

  test "DEPTH counts toward the name column, because the indent is inside it":
    # 2 * 14 + 10 * 8 = 108 — wider than the same name at depth 0 (80). A rule
    # that ignored depth would let a nested name overflow the column it is
    # supposed to end in.
    ck stateNameColumnPx(@[StateRow(name: "abcdefghij", depth: 2)]) == 108
    ck stateNameColumnPx(@[StateRow(name: "abcdefghij", depth: 0)]) == 80
    ck StateIndentPx == 14
    # One level of nesting costs exactly one indent.
    ck stateNameColumnPx(@[StateRow(name: "abcdefghij", depth: 1)]) ==
       80 + StateIndentPx

  test "one long dunder cannot push the value column off the pane (the ceiling)":
    let long = StateRow(name: repeat("z", 40), depth: 0)   # 320 px
    ck stateNameColumnPx(@[long]) == StateNameMaxPx
    ck StateNameMaxPx == 260
    # And the ceiling binds whatever else is in the set.
    ck stateNameColumnPx(@[long, StateRow(name: "x", depth: 0)]) ==
       StateNameMaxPx

  test "the value column's x is the name column, the RULE and the value cell's inset":
    # THREE terms, and the middle one is the drawn rule. **THIS CASE'S
    # LITERAL MOVED FROM 102 TO 103 IN THIS PASS**, because the rule the two
    # previous passes had deleted on a false reading is drawn again: the
    # 1 px `div` sits between the two cells, so a value x that skipped it
    # would be a published number the drawing disagrees with.
    ck stateValueColumnPx(96) == 96 + StateSeparatorPx + StateValuePadPx
    ck stateValueColumnPx(96) == 103
    ck StateValuePadPx == 6
    ck StateSeparatorPx == 1
    # It is strictly to the right of the name column on any pane, and by more
    # than the inset alone — a rule of zero width would be an invisible rule.
    ck stateValueColumnPx(StateNameMinPx) > StateNameMinPx
    ck stateValueColumnPx(StateNameMinPx) > StateNameMinPx + StateValuePadPx

suite "PLAT-40 / PLAT35-F4: the rows are the ViewModel's, not this renderer's":

  # `leaves.stateRows` re-derives the path spelling and the expansion rule
  # that `pane_views.variableRow` owns. §30: two derivations of one rule is
  # the defect, so the agreement is a case rather than a comment.

  test "the flattened paths are `statePaneView`'s own visible Tree row ids":
    let vm = nestedStateVM()
    let rows = stateRows(vm, GpuiPanelBudget)
    let pv = statePaneView(vm, GpuiPanelBudget)
    var tree: ViewNode
    for child in pv.root.children:
      if child.id == StateTreeViewId: tree = child
    ck not tree.isNil
    # `visibleRows` puts the tree's own root first; the rows follow.
    let vocabulary = visibleRows(tree)
    ck vocabulary.len > 1
    ck vocabulary[0].id == StateTreeViewId
    var vocabularyPaths: seq[string] = @[]
    for n in vocabulary[1 .. ^1]: vocabularyPaths.add n.id
    var nativePaths: seq[string] = @[]
    for row in rows: nativePaths.add row.path
    checkpoint("native " & $nativePaths)
    checkpoint("vocabulary " & $vocabularyPaths)
    ck nativePaths == vocabularyPaths
    # And the shape is the one the fixture built: `beta` expanded, `delta` not.
    ck nativePaths == @["alpha", "beta", "beta.gamma", "beta.delta"]
    vm.dispose()

  test "a collapsed parent hides its children; expanding shows them":
    let vm = nestedStateVM()
    vm.expandedPaths.val = initHashSet[string]()
    var paths: seq[string] = @[]
    for row in stateRows(vm, GpuiPanelBudget): paths.add row.path
    ck paths == @["alpha", "beta"]
    vm.expandedPaths.val = toHashSet(["beta", "beta.delta"])
    paths = @[]
    for row in stateRows(vm, GpuiPanelBudget): paths.add row.path
    ck paths == @["alpha", "beta", "beta.gamma", "beta.delta",
                  "beta.delta.epsilon"]
    vm.dispose()

  test "a row carries its depth, its value and the selection, and the type it does NOT draw":
    let vm = nestedStateVM()
    let rows = stateRows(vm, GpuiPanelBudget)
    ck rows.len == 4
    ck rows[0].depth == 0
    ck rows[2].depth == 1            # `beta.gamma`
    ck rows[0].value == "1"
    ck rows[2].value == "3"
    # `selectedPath` is the ViewModel's, and exactly one row answers to it.
    var selected = 0
    for row in rows:
      if row.selected: inc selected
    ck selected == 1
    ck rows[2].selected
    # `typeName` is CARRIED, which is what this line gates — the field is in
    # reach of `renderState` and readable here. **IT DOES NOT GATE "NOT
    # DRAWN", and saying so is the point**: this fixture sets no `typeName`,
    # so a renderer that drew a third column would still satisfy it. The
    # not-drawn half is gated in suite 3, by `header.cells.len == 2`,
    # `cs.len == 2` and `row.textNodeCount == 2` — a third column reddens
    # those at both viewports. Recorded at adversarial review, 2026-10-04,
    # because an assertion whose case NAME claims more than the assertion
    # checks is §7 in miniature.
    ck rows[0].typeName == ""
    vm.dispose()

  test "an empty ViewModel yields no rows, so the pane keeps its own report":
    let mock = newMockBackendService(autoRespond = false)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createStateVM(store)
    ck stateRows(vm, GpuiPanelBudget).len == 0
    ck stateNameColumnPx(stateRows(vm, GpuiPanelBudget)) == StateNameMinPx
    vm.dispose()
    ck stateRows(nil, GpuiPanelBudget).len == 0

suite "PLAT-40 / PLAT35-F4: the pane draws the spec's two columns":

  for (w, h) in Viewports:
    let vp = $w & "x" & $h

    test "at " & vp & " the pane publishes a Name/Value HEADER":
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        ck pane.attr(StateAttr) == "live"
        let header = pane.headerRow
        ck not header.isNil
        # Exactly one, and it is not also a body row.
        ck pane.nodesWith(StateHeaderAttribute).len == 1
        ck not header.has(StateRowAttribute)
        let hn = header.cell(StateNameColumn)
        let hv = header.cell(StateValueColumn)
        ck not hn.isNil
        ck not hv.isNil
        checkpoint(vp & " ops='" & ops & "' header " & hn.textOf & " | " &
                   hv.textOf)
        # The spec's two headings, verbatim.
        ck hn.textOf == "Name"
        ck hv.textOf == "Value"
        ck hn.textOf == StateHeaderNameLabel
        ck hv.textOf == StateHeaderValueLabel
        # …and no third heading: the spec publishes TWO columns.
        ck header.cells.len == 2

    test "at " & vp & " every row is two cells, name then value, each with data-column":
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        let rows = pane.bodyRows
        # Not "a row exists": one row would make every alignment claim below
        # vacuous.
        ck rows.len > 1
        let census = pane.nodesWith(StateColumnAttribute).len
        checkpoint(vp & " ops='" & ops & "' rows=" & $rows.len &
                   " data-column=" & $census)
        # The census is pinned to the rows it is supposed to describe: two
        # cells per body row plus the header's two. A census alone is §7.
        ck census == 2 * (rows.len + 1)
        for i, row in rows:
          ck row.attr(StateRowAttribute) == $i      # in draw order
          let cs = row.cells
          ck cs.len == 2
          ck row.cellAt(0).attr(StateColumnAttribute) == StateNameColumn
          ck row.cellAt(1).attr(StateColumnAttribute) == StateValueColumn
          # THE FLAT `name: value` RUN IS GONE: the name is its own text node
          # in its own cell, and it does not carry the separator the old label
          # was built with (`pane_views.VariableLabelSeparator`).
          ck VariableLabelSeparator notin row.cellAt(0).textOf
          ck row.cellAt(0).textOf.len > 0
          # The row holds the two cells' text and nothing else — exactly two
          # text nodes, so a stray third run cannot hide here, and the column
          # RULE between them (a third CHILD, counted in the case that owns
          # it) contributes no text of its own.
          ck row.textNodeCount == 2
          ck not row.textOf.startsWith(row.cellAt(0).textOf &
                                      VariableLabelSeparator)

    test "at " & vp & " EVERY VALUE CELL STARTS AT THE SAME X, and it is not zero":
      # The finding's own sentence — *"nothing aligns vertically"*,
      # *"its starting x-position varies per row"* — and the §7b trap: two
      # cells that both start at x = 0 satisfy a `data-column` census.
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        let rows = pane.bodyRows
        ck rows.len > 1
        var widths = initHashSet[int]()
        var xs = initHashSet[int]()
        var lengths = initHashSet[int]()
        for row in rows:
          let name = row.cell(StateNameColumn)
          ck not name.isNil
          widths.incl name.pxStyle("w")
          xs.incl row.valueColumnXOf
          lengths.incl name.textOf.len
        checkpoint(vp & " ops='" & ops & "' name widths " & $widths &
                   " value x " & $xs & " name lengths " & $lengths)
        # ONE width and ONE x across every row.
        ck widths.len == 1
        ck xs.len == 1
        for x in xs:
          ck x > 0                 # the "all at x = 0" trap
        for width in widths:
          ck width > 0
        # **AND THE ROWS MUST DIFFER IN NAME LENGTH**, or equal widths would
        # prove nothing at all. `calc`'s module scope has `__builtins__` and
        # `add` in the same pane.
        ck lengths.len > 1
        # The header is in the same column as the rows it names.
        let header = pane.headerRow
        ck not header.isNil
        ck header.cell(StateNameColumn).pxStyle("w") in widths
        ck header.valueColumnXOf in xs
        # The table's published x is the one the geometry adds up to — one
        # number, two readers (§30).
        let table = pane.tableOf
        ck not table.isNil
        for x in xs:
          ck table.attr(StateAlignAttribute) == $x

    test "at " & vp & " the drawn width is the one the rule answers for these names":
      # The correspondence, not the presence: a width that is not the rule's
      # answer passes the alignment case above and fails here. The expectation
      # comes from `leaves.stateNameColumnPx` — the product's own rule, pinned
      # against literals in suite 1 — applied to the names THE PLAN DREW.
      #
      # **AND IT TAKES MORE THAN ONE STOP TO MEAN THAT.** With only
      # `stepIn=5` and `stepIn=5,next=3` in `PopulatedOps` this case was
      # satisfied by a HARDCODED `96px`, because both of those stops answer
      # 96. `stepIn=21,stepOut=1` answers 88, so the constant now fails here
      # and nowhere else — see `PopulatedOps` and the §7 note above.
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        var drawn: seq[StateRow] = @[]
        for row in pane.bodyRows:
          var depth = 0
          try: depth = parseInt(row.attr(StateDepthAttribute))
          except ValueError: depth = -1
          ck depth >= 0
          drawn.add StateRow(name: row.cell(StateNameColumn).textOf,
                             depth: depth)
        ck drawn.len > 1
        let expected = stateNameColumnPx(drawn)
        let actual = pane.bodyRowAt(0).cell(StateNameColumn).pxStyle("w")
        checkpoint(vp & " ops='" & ops & "' expected " & $expected &
                   " drawn " & $actual)
        ck actual == expected
        # It is a real content-dependent answer and not the floor by accident.
        ck expected > StateNameMinPx

    test "at " & vp & " the Name/Value column RULE is drawn, and declares what makes it paint":
      # **THIS CASE IS THE RE-POINTING ITS OWN PREDECESSOR ASKED FOR.** It
      # was *"at <vp> NO column boundary is drawn, and none is faked"*, and
      # its comment said a later pass that drew a VISIBLE rule should
      # re-point it at the rule's geometry and its measured colour rather
      # than read it as a blocker. This is that pass. The spec census that
      # refuted the absence is in this file's header; what is asserted here
      # is the DRAWING.
      #
      # **A CENSUS OF `data-state-separator` IS WORTH NOTHING ON ITS OWN, AND
      # THAT IS MEASURED RATHER THAN FEARED** (§7a): a 1 px `div` with a
      # background and no height of its own occupies its width in the layout
      # and paints NOTHING. That element — present, laid out, invisible — is
      # exactly what a previous pass built, and the absence case that replaced
      # it existed to stop it being reinstated and called "drawn". So the two
      # declarations that make it paint are asserted here beside its
      # presence, and the drag it must NOT advertise is asserted with them.
      let plan = windowPlan(w, h, PopulatedOps[0])
      let pane = plan.paneOf("state")
      ck not pane.isNil
      let rows = pane.bodyRows
      ck rows.len > 1
      let header = pane.headerRow
      ck not header.isNil
      # ONE RULE PER ROW, THE HEADER'S INCLUDED, and the census is pinned to
      # the rows it is supposed to describe — a bare count is §7.
      checkpoint(vp & " rows=" & $rows.len & " rules=" &
                 $pane.nodesWith(StateSeparatorAttribute).len)
      ck pane.nodesWith(StateSeparatorAttribute).len == rows.len + 1
      for row in rows & @[header]:
        # **THE RULE IS THE MIDDLE CHILD, AND ITS POSITION IS AN ASSERTION**:
        # a rule appended after the value cell would paint at the pane's right
        # edge instead of between the columns, and every width assertion in
        # this suite would still pass.
        ck row.kids.len == 3
        ck row.kidAt(0).attr(StateColumnAttribute) == StateNameColumn
        ck row.kidAt(1).has(StateSeparatorAttribute)
        ck row.kidAt(2).attr(StateColumnAttribute) == StateValueColumn
        let rule = row.separator
        ck not rule.isNil
        # ITS GEOMETRY: one pixel wide, and the second term of
        # `stateValueColumnPx`.
        ck rule.pxStyle("w") == StateSeparatorPx
        ck rule.pxStyle("w") == 1
        # **AND ITS OWN HEIGHT, WHICH IS NECESSARY AND SUFFICIENT FOR IT TO
        # PAINT AT ALL.** A childless flex child inherits none from a row that
        # declares `height: 26px`. Four arms were measured: this pair →
        # 276 of 276 scanned rows; height alone → 194 of 276; `flex-shrink: 0`
        # with no height → nothing; a bare div with a background → nothing.
        ck rule.pxStyle("h") == StateRowPx
        ck rule.pxStyle("h") == 26
        ck rule.style("flex_shrink") == "0"
        # Its colour is the design TOKEN and not a hex somebody typed.
        ck rule.style("bg") == StateSeparatorColour
        ck StateSeparatorColour == "#565656"
        # It is a rule and not a cell: no column, no text, no affordance.
        ck not rule.has(StateColumnAttribute)
        ck rule.textNodeCount == 0
        ck rule{"has_click_handler"}.getBool == false
        ck rule.style("cursor") == ""
      # **THE DRAG IS STILL NOT DRAWN AND IS STILL NAMED RESIDUE.** It is
      # spec-ranked `Low`, it needs a persisted width and a pointer-capture
      # model, and the governing clause is `PLAT35-F7`'s — *"A rendered
      # affordance must do the thing it advertises, or not be rendered"*. A
      # static rule is not an affordance; a `col-resize` cursor over no drag
      # would be, which is why the rule's own `cursor` is asserted empty
      # above and the cells' are asserted empty here.
      ck pane.nodesWith("data-ct-drag").len == 0
      for row in rows & @[header]:
        for c in row.cells:
          ck c{"has_click_handler"}.getBool == false
          ck c.style("cursor") == ""

    test "at " & vp & " the rule's RENDERED colour is not the colour it declares":
      # **THE FALSE NEGATIVE THAT DELETED THIS RULE TWICE, PINNED SO IT
      # CANNOT BE REPEATED.** A frame probe searched for pixels of exactly
      # `#565656`, found zero, and the rule was removed as "painting
      # nothing". An exact-token search returns zero in a WORKING build: the
      # rule paints at `(71, 73, 76)` = `#47494C`, which is that token over
      # the pane's own `#1b222c` ground at coverage ≈ 0.75 (0.746 / 0.750 /
      # 0.762 on R / G / B — the blend is the rasteriser's, a 1 px logical box
      # failing to land on one whole device pixel; the shim parses a 6-digit
      # hex at FULL alpha).
      #
      # **WHAT THIS CASE CAN AND CANNOT DO, STATED.** Nothing in this file
      # opens a window, so the 71/73/76 is a frame measurement CARRIED (the
      # capture lane's, with its own positive control, recorded in
      # `PLAT35-F4.confirmedBy`). What IS asserted here is the arithmetic
      # that connects the two numbers, over the token and the ground READ OFF
      # THE PLAN: if either moves, the composite moves with it and this case
      # reddens — which is the right alarm, because the frame probe's
      # constant would then be stale. That is `Verification-Harness-Traps`
      # §67's requirement met at this instrument's level: a probe is gated on
      # knowing what the right answer looks like.
      let plan = windowPlan(w, h, PopulatedOps[0])
      let pane = plan.paneOf("state")
      ck not pane.isNil
      ck pane.bodyRows.len > 1
      let rule = pane.bodyRowAt(0).separator
      ck not rule.isNil
      # Both ends of the blend come out of the plan.
      ck rule.style("bg") == "#565656"
      ck pane.style("bg") == StateGroundHex
      ck StateGroundHex == "#282828"
      let mixed = mixAtThreeQuarters(rule.style("bg"), pane.style("bg"))
      let rendered = channels(SeparatorRenderedHex)
      checkpoint(vp & " declared " & rule.style("bg") & " over " &
                 pane.style("bg") & " at 3/4 = " & $mixed &
                 ", frame holds " & $rendered & " (" & SeparatorRenderedHex &
                 ")")
      # Within one unit per channel, because the measured coverage is not
      # exactly 3/4 (≈ 0.76 over the `#282828` ground) and the rasteriser
      # rounds: truncated 3/4 gives 74 per channel and the frame holds 75.
      # A token or a ground that MOVED would miss by tens — which is exactly
      # what this case did at the PLAT-50 merge, by 3 and 2 on two channels,
      # when the ground went from `#1b222c` to `#282828` and these two
      # constants still held the old composite. It was re-measured, not
      # widened: the tolerance is still one unit.
      for i in 0 .. 2:
        ck abs(rendered[i] - mixed[i]) <= 1
      # **AND IT IS NOT THE DECLARED TOKEN**, which is the whole point: a
      # probe that looks for `#565656` in the framebuffer is looking for bytes
      # no build contains.
      ck SeparatorRenderedHex != rule.style("bg")
      ck rendered != channels(rule.style("bg"))
      ck rendered != channels(pane.style("bg"))
      # It is strictly between the ground and the token on every channel —
      # the shape of a composite, which is what makes `#47494C` a plausible
      # reading of a `#565656` rule rather than a coincidence.
      for i in 0 .. 2:
        ck rendered[i] > channels(pane.style("bg"))[i]
        ck rendered[i] < channels(rule.style("bg"))[i]

    test "at " & vp & " the pane's TAB STRIP is still the vocabulary's":
      # `renderState` takes over `state.root` only. A pass that drew the three
      # roots natively would lose `Locals` from `--report-plan`, which
      # `test_gpui_editing_surface` asserts, and would give the tab strip a
      # second owner.
      let plan = windowPlan(w, h, PopulatedOps[0])
      let pane = plan.paneOf("state")
      ck not pane.isNil
      var tabs: JsonNode
      for n in pane.nodesWith(ViewIdAttr):
        if n.attr(ViewIdAttr) == "state.tabs": tabs = n
      ck not tabs.isNil
      ck tabs.attr(ViewKindAttr) == "Tabs"
      var labels: seq[string] = @[]
      for o in tabs{"children"}.getElems: labels.add o.textOf
      ck labels == @["Locals", "Globals", "Watches"]
      # Exactly one highlighted option, and it is the active tab's.
      var highlighted = 0
      for n in pane.nodesWith(HighlightedAttr):
        if n.attr(HighlightedAttr) == "true": inc highlighted
      ck highlighted == 1
      # **THE STATE TREE HAS EXACTLY ONE OWNER AND IT IS THIS TABLE.**
      #
      # RE-AIMED AT THE PLAT-50 MERGE, 2026-10-05. This block asserted that
      # NOTHING in the pane carried `state.root`, because `renderState` had
      # removed the vocabulary's `Tree` outright. PLAT-50 then made that
      # absence a REGRESSION rather than a virtue: `window_clicks` decides a
      # press is a variable press by walking for `data-view-kind == "Tree"`
      # UNDER an ancestor whose `data-view-id` is `state.root`, so with the id
      # absent every variable press in this pane stopped being recognised and
      # PLAT-50's own case *"a value expands; a variable's menu"* went red
      # (measured: 95 assertions against upstream's own 104 at the same
      # merge). The table therefore CLAIMS the id — it IS the state tree now.
      #
      # So the invariant worth holding was never "the id is absent"; it is
      # that the id is not DUPLICATED, because two owners of one node is §30.
      # That is what is asserted, and it is a FIXED number of assertions
      # rather than one per `data-view-id` node, which is what made the old
      # loop's contribution move with the rows it happened to find.
      var treeOwners = 0
      var tableOwnsTree = false
      for n in pane.nodesWith(ViewIdAttr):
        if n.attr(ViewIdAttr) == StateTreeViewId:
          inc treeOwners
          if n.attr(StateTableAttribute).len > 0: tableOwnsTree = true
      ck treeOwners == 1
      ck tableOwnsTree
      # And every body row names the variable it draws, as a vocabulary
      # `Tree` row, in the spelling `stateVM.toggleExpand` and
      # `variablesContextMenu` take — the two attributes PLAT-50 dispatches
      # on, published here so this renderer's agreement with that click model
      # is GATED and not merely intended.
      for row in pane.bodyRows:
        ck row.attr(ViewKindAttr) == "Tree"
        ck row.attr(ViewIdAttr).len > 0

    test "at " & vp & " the pane draws its ACTIVE TAB's word exactly ONCE":
      # **PLAT35-F9's residue, GATED.** The finding, rewritten to its residue
      # on 2026-10-03: *"The state pane's variable tree labels its root
      # `locals` directly under the active tab `Locals`, so the same word is
      # drawn twice in the same pane."*
      #
      # It is CLOSED, and not by anything done for it. `renderState` strips
      # the vocabulary's `state.root` `Tree` out of `pv.root.children` before
      # binding (`leaves.nim`'s `kept` loop) and redraws the variables from
      # `vm.currentVariables.val` at depth 0, so the node that CARRIED that
      # label — `pane_views.statePaneView`'s `viewTreeNode("state.root", …)`,
      # whose text is `"locals"` / `"globals"` / `"watches"` by active tab —
      # is not in the window plan at all. The id survives, on the TABLE, which
      # is the PLAT-50 click contract and not a drawn label.
      #
      # **SO THIS CASE EXISTS BECAUSE THE FIX IS SOMEBODY ELSE'S.** PLAT35-F2
      # is the precedent: a finding closed upstream, with no assertion left
      # behind, is a finding that regresses silently.
      #
      # **AND IT IS NOT SUBSUMED BY THE CASE ABOVE IT, WHICH WAS MEASURED
      # RATHER THAN ASSUMED — TWO RED-CONTROL ARMS, BOTH KILLED.** Arm R1
      # drops the `kept` filter so the vocabulary `Tree` is drawn again: that
      # reds BOTH this case (`repeats was 2`, `sole was locals`) and *"the
      # pane's TAB STRIP is still the vocabulary's"* (`treeOwners == 2`),
      # because the node carrying the label is also the node carrying the id.
      # So R1 alone does not show this case is needed. **Arm R2 does.** It
      # keeps the filter and substitutes `viewText("state.caption",
      # child.label)` for the dropped child — the regression PLAT-49 named in
      # `statePaneView` (*"a label here drew a second 'State' as the pane's
      # first row"*): the word is drawn twice, `state.root` still has exactly
      # ONE owner, and the table, the columns, the rule, the widths and the
      # tab strip are all still exactly right. Under R2, at both viewports and
      # all three stops, **this is the only case in the file this arm reds**:
      # 28 OK / 3 FAILED, where the two new reds are this case at the two
      # viewports and the third is the §7 count case that is red at the
      # unmodified bytes too. Counted 1683 under the arm and 1683 without it,
      # so no case aborted (§69). Measured at `bc915c73d` plus that one arm,
      # with `leaves.nim` restored by copy afterwards and its digest
      # `10411cb1f3ee…` asserted both ways.
      #
      # ## §7b: what would satisfy this case if it stood alone
      #
      # `repeats == 1` alone is satisfied by a pane with NO ROWS — the three
      # tab labels would be the only text and the active one would appear
      # once. That is why `bodyRows.len > 0` is asserted beside it and why the
      # needle is READ OFF the plan rather than written here: a hardcoded
      # `"Locals"` would keep passing on a pane whose tabs had been renamed,
      # and the finding is about a pane repeating ITS OWN tab, whatever that
      # tab says.
      #
      # **THE EMPTY PANE IS OUT OF SCOPE HERE, DELIBERATELY, AND IT IS WHERE
      # THE RESIDUE SURVIVES.** `renderState` returns false when there are no
      # rows, so at an UNSTEPPED stop the vocabulary draws the root again and
      # the pane really does read `Locals` over `locals — no variables at this
      # position`. That path is the next case's subject (*"an UNSTEPPED
      # session draws the report, not an empty table"*), it is recorded in the
      # ledger as `PLAT35-F9.residue`, and asserting its absence here would
      # red this case against behaviour nobody has decided to change.
      #
      # ALL THREE STOPS AND BOTH VIEWPORTS: the plans are already cached by
      # the cases above, so the coverage is free and a stop-dependent answer
      # cannot hide.
      for ops in PopulatedOps:
        checkpoint(vp & " " & ops)
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        var tabs: JsonNode
        for n in pane.nodesWith(ViewIdAttr):
          if n.attr(ViewIdAttr) == "state.tabs": tabs = n
        ck not tabs.isNil
        # The needle: the pane's OWN active tab, read off the plan.
        var active = ""
        var activeCount = 0
        for o in tabs.kids:
          if o.attr(HighlightedAttr) == "true":
            inc activeCount
            if active.len == 0: active = o.textOf
        ck activeCount == 1
        ck active == "Locals"
        # The population control. Without it the scan below is a count over
        # three tab labels and would pass on an empty pane.
        ck pane.bodyRows.len > 0
        # THE GATE. A PREFIX match and not equality, because the label the
        # finding named is `locals — no variables at this position`, not
        # `locals`; and case-folded, because the two spellings that collided
        # are `Locals` and `locals`. `repeats` is -1 rather than a count when
        # the needle is empty, so an empty needle — which `startsWith` says
        # every string begins with — fails loudly instead of matching
        # everything or being quietly skipped (§4).
        var repeats = -1
        var sole = ""
        if active.len > 0:
          repeats = 0
          let needle = active.toLowerAscii
          for t in pane.textNodes:
            if t.strip().toLowerAscii().startsWith(needle):
              inc repeats
              sole = t
        ck repeats == 1
        # And the one occurrence is the TAB, not a row that swallowed it: an
        # equality here separates `Locals` from `Locals — …` in the case where
        # the tab itself went missing and a row took its place.
        ck sole == active

    test "at " & vp & " `data-column` ELSEWHERE in the window is the Table's fact":
      # §4: the instrument must measure the subject. The mirror of the mistake
      # that sent `test_plat40_calltrace_current_frame`'s first draft red at 3
      # would be counting `data-column` over the whole plan — and here that is
      # not hypothetical. **`data-column` IS ALREADY TAKEN**: the vocabulary
      # binding publishes a `Table`'s own `column` field as a fact under
      # exactly that name (`view_vocabulary/gpui_binding.nim`, the `pkTable`
      # arm; `fact_reader.factAttributeName("column")`), and the EVENT LOG is
      # a `Table`. Measured on this plan: 25 occurrences in the window, 24 in
      # the state pane, ONE on the event log's `Table` node carrying `"0"`.
      #
      # So a window-wide census is not a reading of this pane, and the name is
      # kept — it is what `PLAT35-F4`'s remedy asks for and what a reader
      # looks for — with the collision GATED rather than glossed: everything
      # outside the pane must be a `Table` fact, and everything inside must be
      # one of the spec's two column names.
      let plan = windowPlan(w, h, PopulatedOps[0])
      let pane = plan.paneOf("state")
      ck not pane.isNil
      let inside = pane.nodesWith(StateColumnAttribute)
      ck inside.len > 0
      var seen = initHashSet[string]()
      for c in inside: seen.incl c.attr(StateColumnAttribute)
      ck seen == toHashSet([StateNameColumn, StateValueColumn])
      # What the rest are.
      let outside = plan.nodesWithOutside(StateColumnAttribute, "state")
      for n in outside:
        checkpoint(vp & " outside the pane: " & $n{"attributes"})
        # A vocabulary fact on a Table node, whose value is an index.
        ck n.attr(ViewKindAttr) == "Table"
        ck n.attr(StateColumnAttribute).len > 0
        ck n.attr(StateColumnAttribute).allCharsInSet(Digits)
      checkpoint(vp & " data-column: " & $plan.nodesWith(
        StateColumnAttribute).len & " in the window, " & $inside.len &
        " in the pane, " & $outside.len & " elsewhere")
      ck outside.len == 1
      ck plan.nodesWith(StateColumnAttribute).len == inside.len + outside.len
      # And none of the other panes has a state-pane cell in it.
      #
      # **THE PANE MUST BE THERE BEFORE ITS EMPTINESS MEANS ANYTHING.** This
      # loop used to open `if p.isNil: continue`, which made it a SILENT SKIP:
      # a plan that stopped publishing `data-ct-pane`, or a renaming of any of
      # these four roles, would have scored four passes without reading a
      # single node — §7's assertion that cannot fail, in the middle of the
      # case that exists to enforce §4. The presence is now asserted. All
      # four ARE in this window's plan, measured on this host at both
      # viewports and all three stops: `editor`, `calltrace`, `eventLog`,
      # `fileTree`, plus `state`. Gated at adversarial review, 2026-10-04.
      for other in ["editor", "calltrace", "eventLog", "fileTree"]:
        let p = plan.paneOf(other)
        checkpoint(vp & " other pane: " & other)
        ck not p.isNil
        ck p.nodesWith(StateRowAttribute).len == 0
        ck p.nodesWith(StateHeaderAttribute).len == 0

    test "at " & vp & " an UNSTEPPED session draws the report, not an empty table":
      # The population control, and the false-return path: at entry the pane
      # has no variables, so `renderState` must decline and the vocabulary's
      # own report must still be what the pane says.
      let plan = windowPlan(w, h, UnsteppedOps)
      let pane = plan.paneOf("state")
      ck not pane.isNil
      ck pane.attr(StateAttr) == "pane-report"
      ck pane.nodesWith(StateColumnAttribute).len == 0
      ck pane.nodesWith(StateRowAttribute).len == 0
      ck pane.nodesWith(StateHeaderAttribute).len == 0
      ck pane.tableOf.isNil
      ck "no variables at this position" in pane.textOf
      # And the tab strip is still there even with nothing to tabulate.
      ck "Locals" in pane.textOf

suite "PLAT-40 / PLAT35-F4: every case in this file ran":

  test "the assertion count is the one this file declares":
    checkpoint("counted " & $CHECKS & ", expected " & $ExpectedAssertions)
    doAssert CHECKS == ExpectedAssertions,
      "this suite's assertion count moved: counted " & $CHECKS &
      ", declared " & $ExpectedAssertions &
      ". A case that stopped running is not a case that passed."
