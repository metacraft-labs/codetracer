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
## ## SUPERSEDED 2026-10-17: THE PANE IS THE DESKTOP'S NOW
##
## The GPUI front-end was redesigned to replicate the Electron desktop pixel
## for pixel (`849d152bb`, `0835c7926`, `84f594bd5`, `e731c9aea`), and the
## desktop's state pane is NOT a two-column table: it draws `name:value` with
## nothing between them (`.value-name` then `.value-view`), the value's type,
## and history / origin buttons, under a segmented Locals / Globals / Watches
## control, a watch field and the stop's code line. So the two-column design
## documented below — the `Name` / `Value` header, the fixed name column, the
## 1 px rule and the shared value x — is history, kept for the record of how
## it was measured. Suite 3 now gates the NEW invariants: exactly one `name`
## and one `value` `data-column` cell per row in that order, `name:` with the
## value directly after it, the desktop's inks, the row facts the click model
## reads, the scroll box, the tab control, `data-column` scoped to the pane,
## and the empty state. The suite that pinned the name-column rule
## (`stateNameColumnPx` / `stateValueColumnPx`) was removed with that rule,
## which nothing drew by any more; references to "suite 1" below are history.
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
##   4. (REMOVED 2026-10-17 with the rule it gated.)
##      *the width is right* — satisfied by a constant. So suite 1 pinned
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

import replay_prerequisite
import std/[json, os, osproc, sets, streams, strtabs, strutils, tables,
            tempfiles, unittest]
import ./gpui_child_env

import codetracer_embed
import gpui/app/leaves
import gpui/chrome
import view_vocabulary/pane_views
import styles/generated/design_tokens

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 3231
    ## **3263 → 3231, 2026-10-30: THE TAB STRIP IS GONE** (`9ae2786b72a`, one
    ## list of variables and watches). Per viewport, the strip case's eight
    ## readings (the strip, its kind, three option indices, the labels, the
    ## active count) become four (no strip, no active tab, the watch field,
    ## the pane), and the active-word case's seven per stop become three (the
    ## pane, its rows, no retired tab word) — 32 fewer over two viewports.
    ## **3269 → 3263, 2026-10-20 (PLAT-70 Part B): NO HORIZONTAL THUMB** — the
    ## state pane does not scroll sideways (Horizontal-Overflow §5), so the
    ## thumb's three readings (`position`, `h`, `left`) are gone at each of the
    ## two viewports; `horizontal == 0` is asserted instead.
    ## **3291 → 3269, 2026-10-17: THE NAME-COLUMN RULE'S SUITE WAS REMOVED**
    ## with `leaves.stateNameColumnPx` / `stateValueColumnPx` themselves — six
    ## cases, 21 assertions, plus the one reading in the empty-ViewModel case
    ## that asked the rule for its floor. 25 cases now: four in the rows
    ## suite, TEN × two viewports in the pane suite, and the count case.
    ##
    ## **1747 → 3291, 2026-10-17, AND SUITE 3 WAS REWRITTEN** for the
    ## redesigned pane (see "SUPERSEDED" above): still 31 cases, TEN × two
    ## viewports in suite 3, but every one of them now reads the desktop's
    ## rows, and most of the total is the per-row loops — about twenty
    ## readings per row (two cells, the pair, the inks, the depth, the two
    ## controls) over 11, 12 and 19 rows at three stops and two viewports.
    ## MEASURED from the run, not derived. The history below is the
    ## two-column design's.
    ##
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
    ## `entry-shell`'s. The population control: at entry the pane has no
    ## variables and draws the tab's empty-state sentence (the vocabulary's
    ## report until the 2026-10-17 redesign).
  PaneAttr = "data-ct-pane"               # `leaves.PaneRoleAttribute`
  StateAttr = "data-ct-state"             # `leaves.StateAttribute`
  HighlightedAttr = "data-highlighted"    # the vocabulary binding's
  ViewKindAttr = "data-view-kind"
  ViewIdAttr = "data-view-id"
  TabActiveAttr = "data-ct-tab-active"    # `renderState`'s tab buttons
  ScrollAttr = "data-ct-state-scroll"     # the rows' scroll box
  ScrollbarAttr = "data-ct-state-scrollbar" # its thumbs
  EmptyAttr = "data-ct-state-empty"       # the pane's empty-state sentence
  ColumnIndexAttr = "data-column-index"   # the event log's column cells

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
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["DYLD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("DYLD_LIBRARY_PATH"): ":" & getEnv("DYLD_LIBRARY_PATH")
     else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  # Every other per-user location (trace index, config, caches) of the
  # spawned binary: its own, under this case's directory (common/ct_home).
  env["CODETRACER_HOME"] = state / "ct-home"
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
# one, and only one of them ran its remaining assertions. `cellAt`, `cellOf`
# and `pairOf` answer nil rather than indexing, for the same reason.
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

proc bodyRows(pane: JsonNode): seq[JsonNode] =
  if pane.isNil: return @[]
  pane.nodesWith(StateRowAttribute)

proc columnCells(row: JsonNode): seq[JsonNode] =
  ## Every node in this row carrying `data-column`, in plan order. **DEEP,
  ## not the row's children**: since 2026-10-17 the name and value sit inside
  ## a `name:value` pair (the desktop's `.value-name` then `.value-view`),
  ## not directly in the row.
  if row.isNil: return @[]
  row.nodesWith(StateColumnAttribute)

proc cellOf(row: JsonNode; column: string): JsonNode =
  ## This row's cell for `column`, nil when it has none.
  for c in row.columnCells:
    if c.attr(StateColumnAttribute) == column: return c
  nil

proc cellAt(row: JsonNode; i: int): JsonNode =
  ## This row's `i`-th cell, nil when there is none. Every reader here
  ## tolerates an absent node: `check` does not abort a case, so a bare `[i]`
  ## after a failed length check would turn a FAILED case into an aborted one.
  let cs = row.columnCells
  if i < 0 or i >= cs.len: return nil
  cs[i]

proc pairOf(row: JsonNode): JsonNode =
  ## The row's child that holds the name cell — the `name:value` pair. Nil
  ## when no child does.
  for c in row.kids:
    if c.has(StateColumnAttribute) or
       c.nodesWith(StateColumnAttribute).len > 0:
      return c
  nil

proc nameInk(name: JsonNode): JsonNode =
  ## The node that carries the name's TEXT inside its cell (after the caret
  ## of a compound value, when there is one): the cell's last child.
  let ks = name.kids
  if ks.len == 0: nil else: ks[^1]

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
    Variable(name: "alpha", value: "1", typeName: "int"),
    Variable(name: "beta", value: "2", hasChildren: true, children: @[
      Variable(name: "gamma", value: "3"),
      Variable(name: "delta", value: "4", hasChildren: true, children: @[
        Variable(name: "epsilon", value: "5")])])]
  result = createStateVM(store)
  result.expandedPaths.val = toHashSet(["beta"])
  result.selectedPath.val = "beta.gamma"

# ---------------------------------------------------------------------------

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

  test "a row carries its depth, its value, the selection and its type":
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
    # `typeName` is CARRIED from the Variable to the row — since the
    # 2026-10-17 redesign the pane draws it after the value, as the desktop
    # does — so the fixture sets one and the row must carry it verbatim.
    ck rows[0].typeName == "int"
    vm.dispose()

  test "an empty ViewModel yields no rows, so the pane keeps its own report":
    let mock = newMockBackendService(autoRespond = false)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createStateVM(store)
    ck stateRows(vm, GpuiPanelBudget).len == 0
    vm.dispose()
    ck stateRows(nil, GpuiPanelBudget).len == 0

suite "PLAT-40 / PLAT35-F4: the pane draws the desktop's name:value rows":

  # **SINCE 2026-10-17 THE STATE PANE IS DRAWN AS THE ELECTRON DESKTOP DRAWS
  # IT** (`isonim_state_view`, `components/state.styl`, measured): the
  # Locals / Globals / Watches control, the watch field, the stop's code line,
  # then one 24 px monospace row per value — `name:` in indigo and the value
  # directly after it, its type, and the history and origin controls. The
  # two-column table this suite used to gate (a `Name` / `Value` header, a
  # fixed-width name column, a 1 px rule, every value at one x) is SUPERSEDED:
  # the desktop is the reference (`tools/visual-review-brief.md`) and it draws
  # no table. What is still published — and what these cases protect — is the
  # STRUCTURE a reader needs to tell a name from a value: `data-column` on
  # exactly one name and one value per row, in that order, plus the row facts
  # the click model reads.

  for (w, h) in Viewports:
    let vp = $w & "x" & $h

    test "at " & vp & " no Name/Value HEADER, no column RULE and no shared value x":
      # The desktop draws no table; a header or a rule reappearing would be
      # the superseded design coming back beside the new one.
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        ck pane.attr(StateAttr) == "live"
        var desktop = 0
        for n in pane.nodesWith(StateAttr):
          if n.attr(StateAttr) == "desktop": inc desktop
        ck desktop == 1
        ck pane.bodyRows.len > 1          # population control: rows exist
        ck pane.nodesWith(StateHeaderAttribute).len == 0
        ck pane.nodesWith(StateSeparatorAttribute).len == 0
        let table = pane.tableOf
        ck not table.isNil
        ck table.attr(StateAlignAttribute) == ""
        var headings = 0
        for t in pane.textNodes:
          if t.strip() in [StateHeaderNameLabel, StateHeaderValueLabel]:
            inc headings
        ck headings == 0

    test "at " & vp & " every row is a name then a value, each with data-column":
      # The census is never asserted alone: exactly two cells per row, `name`
      # then `value` in that order, over more than one row.
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        let rows = pane.bodyRows
        ck rows.len > 1
        let census = pane.nodesWith(StateColumnAttribute).len
        checkpoint(vp & " ops='" & ops & "' rows=" & $rows.len &
                   " data-column=" & $census)
        ck census == 2 * rows.len
        for i, row in rows:
          ck row.attr(StateRowAttribute) == $i      # in draw order
          ck row.columnCells.len == 2
          ck row.cellAt(0).attr(StateColumnAttribute) == StateNameColumn
          ck row.cellAt(1).attr(StateColumnAttribute) == StateValueColumn
          # The name cell is the NAME: `name:` and nothing of the value.
          let name = row.cellAt(0).textOf
          ck name.len > 1
          ck name.endsWith(":")
          ck VariableLabelSeparator notin name

    test "at " & vp & " the value follows `name:` with NOTHING between them":
      # The desktop's `.value-name` then `.value-view`: `name:value`, no
      # gap, no column. Both cells are siblings in one pair, the pair sets no
      # gap, neither cell pads toward the other, and the value is
      # content-sized (no width that would put it at a column).
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        let rows = pane.bodyRows
        ck rows.len > 1
        var lengths = initHashSet[int]()
        for row in rows:
          let name = row.cellOf(StateNameColumn)
          let value = row.cellOf(StateValueColumn)
          ck not name.isNil
          ck not value.isNil
          let pair = row.pairOf
          ck not pair.isNil
          let pk = pair.kids
          ck pk.len == 2
          if pk.len == 2:
            ck pk[0].attr(StateColumnAttribute) == StateNameColumn
            ck pk[1].attr(StateColumnAttribute) == StateValueColumn
          ck pair.style("gap") == ""
          ck name.style("padding_right") == ""
          ck value.style("padding_left") == ""
          ck value.style("margin_left") == ""
          ck value.style("w") == ""
          ck name.style("w") == ""
          # Read as a reader would: the row's text BEGINS `name:value`.
          ck row.textOf.startsWith(name.textOf & value.textOf)
          # One line, as the desktop's `white-space: nowrap` collapses it.
          ck '\n' notin value.textOf
          ck "  " notin value.textOf
          lengths.incl name.textOf.len
        # Names of different lengths, without which "no column" proves
        # nothing about where the values start.
        ck lengths.len > 1

    test "at " & vp & " names, values and changed values are in the desktop's inks":
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        let rows = pane.bodyRows
        ck rows.len > 1
        var unchanged = 0
        for row in rows:
          let name = row.cellOf(StateNameColumn)
          let value = row.cellOf(StateValueColumn)
          ck name.nameInk.style("text_color") == StateNameColour
          ck value.style("font_family") == MonoFontFamily
          case row.attr(StateChangedAttribute)
          of "true":
            ck value.style("text_color") == StateChangedColour
          of "false":
            inc unchanged
            ck value.style("text_color") ==
               DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark]
          else:
            ck false                  # every row says whether it changed
        ck unchanged > 0

    test "at " & vp & " every row carries its depth, its history and origin controls":
      # The row facts the click model reads (PLAT-51 K40 / K41), named by
      # the row's own path, and the desktop's 24 px row and 16 px indent.
      for ops in PopulatedOps:
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        let rows = pane.bodyRows
        ck rows.len > 1
        for row in rows:
          let path = row.attr(ViewIdAttr)
          ck path.len > 0
          var depth = -1
          try: depth = parseInt(row.attr(StateDepthAttribute))
          except ValueError: depth = -1
          ck depth >= 0
          ck row.pxStyle("h") == StateValueRowPx
          ck row.style("padding_left") ==
             (if depth > 0: $(depth * StateRowIndentPx) & "px" else: "")
          var controls: seq[string] = @[]
          for c in row.nodesWith(StateControlAttribute):
            controls.add c.attr(StateControlAttribute)
            ck c.pxStyle("w") == 20
            ck c.pxStyle("h") == 20
          ck ("history:" & path) in controls
          ck ("origin:" & path) in controls

    test "at " & vp & " the rows scroll inside the table's scroll box":
      # The rows are children of ONE scroll box inside the state table,
      # at rest at its origin, and the scroll box lets each row take its
      # natural width (`items: start`) so a long value reaches past the pane.
      # `stepIn=5` holds `__builtins__`, whose value is thousands of columns
      # wide. Since PLAT-70 Part B (Horizontal-Overflow §5, Variable-State-Pane
      # Decision 3) a table pane does not scroll sideways: the value is cut
      # with `…` and revealed by its hover / detail, so NO horizontal thumb.
      let plan = windowPlan(w, h, PopulatedOps[0])
      let pane = plan.paneOf("state")
      ck not pane.isNil
      let table = pane.tableOf
      ck not table.isNil
      let boxes = table.nodesWith(ScrollAttr)
      ck boxes.len == 1
      let box = if boxes.len > 0: boxes[0] else: nil
      ck box.attr(ScrollAttr) == "0,0"
      var direct = false
      for k in table.kids:
        if k.has(ScrollAttr): direct = true
      ck direct
      ck box.style("items") == "start"
      ck box.style("margin_top") == "0px"
      ck box.style("margin_left") == "0px"
      var inBox = 0
      for k in box.kids:
        if k.has(StateRowAttribute): inc inBox
      ck inBox == pane.bodyRows.len
      ck inBox > 1
      var horizontal = 0
      for t in pane.nodesWith(ScrollbarAttr):
        ck t.style("position") == "absolute"
        case t.attr(ScrollbarAttr)
        of "horizontal":
          inc horizontal
          ck t.pxStyle("h") == 8
          ck t.pxStyle("left") == 0
        of "vertical":
          ck t.pxStyle("w") == 8
        else:
          ck false
      ck horizontal == 0

    test "at " & vp & " the pane is ONE list of variables and watches":
      # `9ae2786b72a` ("one list of variables and watches"): the Locals /
      # Globals / Watches tab strip is gone from every front-end, and the
      # watch input sits in the pane, as in Visual Studio. Until 2026-10-30
      # this case asserted the strip it replaced.
      let plan = windowPlan(w, h, PopulatedOps[0])
      let pane = plan.paneOf("state")
      ck not pane.isNil
      var tabs: JsonNode
      for n in pane.nodesWith(ViewIdAttr):
        if n.attr(ViewIdAttr) == "state.tabs": tabs = n
      ck tabs.isNil
      ck pane.nodesWith(TabActiveAttr).len == 0
      # THE WATCH FIELD IS IN THE PANE, once — the strip's Watches tab was
      # where it used to be reached.
      ck pane.nodesWith(StateAddWatchAttribute).len == 1
      # The vocabulary binding's highlight is gone with the vocabulary strip.
      ck pane.nodesWith(HighlightedAttr).len == 0
      var treeOwners = 0
      var tableOwnsTree = false
      for n in pane.nodesWith(ViewIdAttr):
        if n.attr(ViewIdAttr) == StateTreeViewId:
          inc treeOwners
          if n.attr(StateTableAttribute).len > 0: tableOwnsTree = true
      ck treeOwners == 1
      ck tableOwnsTree
      for row in pane.bodyRows:
        ck row.attr(ViewKindAttr) == "Tree"
        ck row.attr(ViewIdAttr).len > 0

    test "at " & vp & " the pane draws none of the retired tab words":
      # `PLAT35-F9` was the active tab's word drawn twice (the tab, and a
      # heading repeating it). With the strip gone the words go with it: no
      # text node in the pane is a lone `Locals`, `Globals` or `Watches` —
      # a heading reintroducing one would be the strip coming back in prose.
      for ops in PopulatedOps:
        checkpoint(vp & " " & ops)
        let plan = windowPlan(w, h, ops)
        let pane = plan.paneOf("state")
        ck not pane.isNil
        ck pane.bodyRows.len > 0
        var retired: seq[string] = @[]
        for t in pane.textNodes:
          if t.strip().toLowerAscii() in ["locals", "globals", "watches"]:
            retired.add t
        checkpoint("retired tab words drawn: " & $retired)
        ck retired.len == 0

    test "at " & vp & " `data-column` is the state pane's alone":
      # §4: scoped to the pane. The event log used to be a vocabulary
      # `Table` publishing `data-column: "0"`; it is drawn natively now and
      # names its columns `data-column-index`, so NO node outside this pane
      # carries `data-column` — and the event log really does draw column
      # cells (the positive control that the scan reaches other panes).
      let plan = windowPlan(w, h, PopulatedOps[0])
      let pane = plan.paneOf("state")
      ck not pane.isNil
      let inside = pane.nodesWith(StateColumnAttribute)
      ck inside.len > 0
      var seen = initHashSet[string]()
      for c in inside: seen.incl c.attr(StateColumnAttribute)
      ck seen == toHashSet([StateNameColumn, StateValueColumn])
      let outside = plan.nodesWithOutside(StateColumnAttribute, "state")
      for n in outside:
        checkpoint(vp & " outside the pane: " & $n{"attributes"})
      ck outside.len == 0
      ck plan.nodesWith(StateColumnAttribute).len == inside.len
      let events = plan.paneOf("eventLog")
      ck not events.isNil
      ck events.nodesWith(ColumnIndexAttr).len > 0
      for other in ["editor", "calltrace", "eventLog", "fileTree"]:
        let p = plan.paneOf(other)
        checkpoint(vp & " other pane: " & other)
        ck not p.isNil
        ck p.nodesWith(StateRowAttribute).len == 0
        ck p.nodesWith(StateColumnAttribute).len == 0

    test "at " & vp & " an UNSTEPPED session draws the desktop's empty state":
      # The population control: at entry there are no variables, and the
      # pane draws its empty-state sentence (`.empty-overlay`) — not a
      # table with no rows, and not a row with no data.
      let plan = windowPlan(w, h, UnsteppedOps)
      let pane = plan.paneOf("state")
      ck not pane.isNil
      ck pane.nodesWith(StateColumnAttribute).len == 0
      ck pane.nodesWith(StateRowAttribute).len == 0
      ck pane.nodesWith(StateHeaderAttribute).len == 0
      ck pane.nodesWith(ScrollAttr).len == 0
      let empty = pane.nodesWith(EmptyAttr)
      ck empty.len == 1
      if empty.len == 1:
        ck empty[0].attr(EmptyAttr) == "variables"
        ck empty[0].textOf == stateEmptyText()
      # One list of variables and watches: no Locals / Globals / Watches tabs
      # (Variable-State-Pane.md, "Decisions (2026-10-24)").
      ck "Globals" notin pane.textOf

suite "PLAT-40 / PLAT35-F4: every case in this file ran":

  test "the assertion count is the one this file declares":
    checkpoint("counted " & $CHECKS & ", expected " & $ExpectedAssertions)
    doAssert CHECKS == ExpectedAssertions,
      "this suite's assertion count moved: counted " & $CHECKS &
      ", declared " & $ExpectedAssertions &
      ". A case that stopped running is not a case that passed."
