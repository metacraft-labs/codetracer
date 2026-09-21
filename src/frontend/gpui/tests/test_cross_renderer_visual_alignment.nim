## test_cross_renderer_visual_alignment.nim — PLAT-35. **The gate: one
## scenario definition, two front-ends, eight questions, compared as values.**
##
## `Testing/Cross-Renderer-Visual-Alignment.md` §3 is the oracle. This suite
## parses it out of the sibling checkout at run time, asserts the parsed row
## count, and compares it against **the `LayoutQuestion` enum** in both
## directions with the cardinality asserted on both sides —
## `Editor-Model-Conformance-Suite.md` §7.1. The last line is the one usually
## omitted, and without it the two set differences are both satisfied by two
## empty sets.
##
## **THAT COMPARISON IS THE TABLE AGAINST THE ENUM. IT IS NOT THE TWO
## FRONT-ENDS' ANSWER SETS**, and this header said it was until 2026-09-21.
## The front-ends' own cardinality is asserted separately and is a separate
## claim — see `the two front-ends each emit all eight questions, per
## scenario` below, which calls `emittedQuestions` and `unknownQuestionKeys`.
## Before that case existed, no front-end's answer count was asserted anywhere
## and a question id renamed on the Electron side was silently `continue`d away
## by the JSON reader.
##
## ## THE CORPUS IS PINNED, AND THAT IS WHAT MAKES THIS A GATE
##
## **ALL EIGHT questions carry a filed gap**, so ALL FORTY-EIGHT tier-3 cells
## take the `residualHolds` branch: what those forty-eight assert is that eight
## NAMED divergences have not grown past their filed shapes, which is a real
## claim and is not the same claim as "the two front-ends agree". Said plainly
## because it is the suite's largest limitation. **The `gaps.len == 0` branch —
## the alignment claim itself — is NOT REACHABLE by any cell.**
##
## THIS NUMBER MOVED TWICE IN ONE DAY AND BOTH MOVES ARE INSTRUCTIVE.
## On 2026-09-21 `PLAT35-VG7` was retired, because the run measured that morning
## showed BOTH arms answering an empty `inline-value-runs-by-line` set, and a
## filed gap whose divergence cannot be demonstrated must go. Seven gaps, six
## live-but-vacuous alignment cells — which is what this header, the pin file's
## `_comment`, the `requireFile` message below, the milestone and the spec were
## corrected to say. **That retirement was WRONG**: re-running the same binary
## on the same tree six times, FIVE runs report the GPUI values and one does
## not, so the gap was retired against the minority run. It is re-filed as
## `PLAT35-VG9`, the intermittency is `PLAT35-PD3`, and the count is back to
## eight. What let a one-in-six run masquerade as a repair was that
## `the GPUI arm's three pane producers all ran` asserted only that nothing
## RAISED — never that anything ARRIVED; `the GPUI arm's locals producer LOADED
## something, not just ran` is the assertion that was missing, and a run with no
## locals now reddens by name instead of silently retiring a gap.
##
## So the mutation harness's `M2` arm is NOT aimed at the `gaps.len == 0`
## branch; there is nothing to aim at. It is aimed at the `lqInlineValueRuns`
## residual, and its `because` line is derived from a real run, not typed.
##
## The consequence measured on 2026-09-21: re-running the gate against a corpus
## in which FOUR OF SIX scenarios had reached a different program state left it
## green at 90/309, because a residual that compares only mark KINDS cannot see
## where either front-end stopped. `PLAT-35: THE CORPUS IS PINNED` is the
## repair — the stopped line and the pane census, per scenario, per arm, read
## back out of the answers and compared with `src/tests/visual/corpus-pins.json`.
## A corpus that shifts now reddens by name.
##
## ## THE TWO ARMS, AND WHICH PART OF EACH IS LIVE
##
## Said plainly, because a suite claiming two live captures when it has one and
## a half is the weakest thing on this page.
##
##   GPUI      LIVE, IN THIS PROCESS. A real `.ct` recording, a real
##             `replay-server` child, the real ViewModels, the real
##             `editorSurfaceFor`, the real `renderLeaves`, and the answers read
##             back out of the Rust shadow tree across the FFI boundary. The
##             path is `gpui/main.nim`'s `runOpen` minus `createWindow`, which
##             is the only line of it that needs a GPU.
##   ELECTRON  A RECORDED CAPTURE. `src/tests/gui/tests/visual/
##             visual-alignment-capture.spec.ts` drives the real `ct` binary
##             under Playwright and writes `src/tests/visual/answers/
##             <scenario>.electron.json`. That file is read here. It carries its
##             own provenance — when it was captured and against which `ui.js` —
##             and this suite prints it, because a recorded capture with no date
##             is a capture nobody can age.
##
## **The Electron arm is a CAPTURE and not a source reading**, and the
## distinction is measured rather than assumed: `just build-once` completes on
## this host (measured 2026-09-20, rc 0 in 1m16s) and the Electron front-end
## launches, loads a trace folder and renders under Xvfb. The prerequisite
## `Cross-Renderer-Visual-Alignment.md` recorded on 2026-09-17 — *"this host has
## no `node` and no `npx` at all"* — was true **outside the dev shell** and is
## false inside it; the real blocker was different and is recorded in the
## milestone's status.
##
## ## No mocks
##
## There is no mock, no stub renderer and no stand-in. The workspace policy
## requires a use of one to be justified here; there is none to justify.
##
## ## Trap 13
##
## Every helper that calls `check` is a `template`. The ones that are `proc`s
## return values and call `check` nowhere.

import std/[algorithm, json, options, os, sequtils, sets, strutils, tables,
            times, unittest]

# `Memo.val`, for reading the state pane's variable list back out of the
# ViewModel the producers write into — see `GpuiRun.localsLoaded`.
import isonim/core/computation
import isonim_gpui/renderer
import isonim_gpui/bindings

import headless_session
import headless_app/layout_model
import headless_app/window_set

import ../app/shell as gpui_shell
import ../app/leaves
import ../app/dock_projection
import ../host/gpui_host
import ../../view_vocabulary/editor_surface
import ../../view_vocabulary/pane_views
import ../../view_vocabulary/gpui_layout_answers
import ../../../common/view_vocabulary

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 480

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# The inputs, all of them read and none of them transcribed
# ---------------------------------------------------------------------------

const
  SpecRel = "../codetracer-specs/Testing/Cross-Renderer-Visual-Alignment.md"
  ScenarioRel = "src/tests/visual/scenarios.json"
  PinRel = "src/tests/visual/corpus-pins.json"
  ThresholdRel = "src/tests/visual/thresholds.json"
  AnswerDir = "src/tests/visual/answers"
  BriefRel = "tools/visual-review-brief.md"
  Tier4Rel = "src/tests/visual/tier4-review.json"
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"

proc requireFile(path, why: string): string =
  ## **A MISSING PREREQUISITE FAILS BY NAME. It does not skip.** The
  ## Silent-Self-Pass audit is the reason: a check that detects a missing
  ## prerequisite, returns early and is counted PASSED is the defect.
  if not fileExists(path) and not dirExists(path):
    raise newException(IOError, path & " is not here. " & why)
  path

proc specText(): string =
  readFile(requireFile(SpecRel,
    "The layout-assertion vocabulary is published in codetracer-specs and read " &
    "at run time, never transcribed — a copy here would be written from the " &
    "same reading that produced the implementation, and the two would agree " &
    "about a misreading."))

# ---------------------------------------------------------------------------
# §3's oracle table
# ---------------------------------------------------------------------------

proc publishedQuestionKeys(): seq[string] =
  ## Parse §3's table. The grammar is published in that document's §3.1a and
  ## implemented ONCE, in `layout_questions.canonicalQuestionKey`, which this
  ## calls — so the parser and the enum's display strings cannot drift apart
  ## through two spellings of one rule (§30).
  result = @[]
  var inside = false
  var seenHeader = false
  for raw in specText().splitLines():
    let line = raw.strip()
    if line.startsWith("## 3. "):
      inside = true
      continue
    if inside and line.startsWith("## ") and not line.startsWith("## 3."):
      break
    if inside and line.startsWith("### "):
      # §3.1 and beyond are prose about the table, not the table.
      break
    if not inside: continue
    if not line.startsWith("|"): continue
    let cells = line.split('|')
    if cells.len < 4: continue
    let first = cells[1].strip()
    if first.len == 0: continue
    if first.startsWith("---") or first.startsWith(":--"): continue
    if not seenHeader:
      # The header row is `| Question | Electron answers from | GPUI … |`.
      seenHeader = true
      continue
    result.add canonicalQuestionKey(first)

let publishedKeys = publishedQuestionKeys()

# ---------------------------------------------------------------------------
# The scenario definition — read, never restated
# ---------------------------------------------------------------------------

type
  ScenarioOp = object
    kind: string
    times: int
    line: int

  Scenario = object
    id, view, recording, viewport: string
    ops: seq[ScenarioOp]
    canary: bool

let scenarioDoc = parseJson(readFile(requireFile(ScenarioRel,
  "The scenario definition names no renderer and is read by BOTH capture " &
  "paths; a Nim transcription of it would be the second copy §30 is about.")))

proc readScenarios(): seq[Scenario] =
  result = @[]
  for s in scenarioDoc["scenarios"]:
    var ops: seq[ScenarioOp] = @[]
    for o in s["operations"]:
      ops.add ScenarioOp(kind: o["kind"].getStr,
                         times: o{"times"}.getInt(1),
                         line: o{"line"}.getInt(0))
    result.add Scenario(id: s["id"].getStr, view: s["view"].getStr,
                        recording: s["recording"].getStr,
                        viewport: s["viewport"].getStr, ops: ops,
                        canary: s{"tier1Canary"}.getBool(false))

let scenarios = readScenarios()
let expectedScenarios = scenarioDoc["expectedScenarios"].getInt
let expectedViewports = scenarioDoc["expectedViewports"].getInt
let expectedCanaries = scenarioDoc["expectedCanaries"].getInt
let operationKinds = scenarioDoc["operationKinds"].mapIt(it.getStr)

proc viewportOf(name: string): DockViewport =
  let v = scenarioDoc["viewports"][name]
  DockViewport(width: v["width"].getInt, height: v["height"].getInt,
               dockExtent: DefaultGpuiViewport.dockExtent)

# ---------------------------------------------------------------------------
# The GPUI arm — LIVE, through the shipped binary's own derivation
# ---------------------------------------------------------------------------

type GpuiRun = object
  answers: LayoutAnswerSet
  rows: int
  serialised: string
  producerFailures: seq[string]
    ## Which of the three pane producers raised, and with what message.
    ## **A value rather than a `discard`** — see `runGpuiScenario`.
  localsLoaded: int
    ## **HOW MANY VARIABLES THE STATE PANE ACTUALLY HOLDS after the producers
    ## ran.** `producerFailures` says none of them RAISED, which is not the
    ## same claim and was being read as if it were: on 2026-09-21 a gate run
    ## recorded no producer failure and an EMPTY inline-value answer on all six
    ## scenarios, while five other runs of the same binary on the same tree
    ## reported values on three of them. A producer that runs and loads nothing
    ## empties the panes exactly as one that raised, every question about them
    ## then compares two empty answers and agrees, and that is what retired
    ## `PLAT35-VG7` against a divergence that had not gone anywhere.
    ##
    ## This is `the capture asserts EFFECT, not ACTION` applied one level over.

proc serialise(s: LayoutAnswerSet): string =
  ## The whole answer set as one string, for the tier-1 canary. Deterministic
  ## by construction: the questions are emitted in enum order and every
  ## formatter sorts what it can.
  var parts: seq[string] = @[]
  for a in s.answers:
    parts.add $a.question & "\x1f" & a.value & "\x1f" & $a.tier
  parts.join("\x1e")

proc driveGpui(session: HeadlessDebugSession; ops: seq[ScenarioOp]): int =
  ## Apply one scenario's operation sequence to a real debugger. Answers how
  ## many operations were performed, so the caller can assert the count EXACTLY
  ## rather than "at least one" (§4b).
  result = 0
  for op in ops:
    for _ in 0 ..< max(op.times, 1):
      case op.kind
      of "stepIn": session.stepIn()
      of "next": session.stepForward()
      of "stepOut": session.stepOut()
      of "continueForward": session.continueForward()
      of "setBreakpoint": discard   # applied to the surface below, see `pointsFor`
      else:
        raise newException(ValueError, "unknown operation kind: " & op.kind)
      discard session.drainEvents()
      inc result

proc breakpointOffset(ops: seq[ScenarioOp]): int =
  ## `-1` when the scenario declares no breakpoint.
  result = -1
  for op in ops:
    if op.kind == "setBreakpoint": result = op.line

proc runGpuiScenario(sc: Scenario): GpuiRun =
  ## **`gpui/main.nim`'s `runOpen`, minus `createWindow`.** Every call below is
  ## one the shipped binary makes, in the order it makes them; nothing here is
  ## a test affordance.
  let trace = requireFile(CalcFixture,
    "the `calc` recording is produced on demand by the tui lane's fixture " &
    "provider through the product's own `ct record`; run `just test-tui` once. " &
    "It is NOT skipped, because a green run over no recording is worth less " &
    "than a red one.")
  let session = openGpuiTrace(trace)
  defer: session.close()

  let performed = driveGpui(session, sc.ops)
  var declared = 0
  for op in sc.ops: declared += max(op.times, 1)
  doAssert performed == declared,
    "the GPUI arm performed " & $performed & " of " & $declared &
    " declared operations for scenario " & sc.id

  # The panes' own producers, exactly as `runOpen` and `tui_session.refresh`
  # call them. Without these the state, call-trace and event-log panes render
  # their "nothing at this position" report and every question about them
  # becomes a universal quantification over an empty set (§4a).
  #
  # **THEIR FAILURES ARE RECORDED, NOT SWALLOWED.** They used to be three bare
  # `except CatchableError: discard`, directly under a comment saying that
  # without these calls every question about those panes becomes a universal
  # quantification over an empty set — which is to say, the comment named the
  # §4a defect and the code then arranged for it to happen silently. A
  # producer that stopped working would empty the panes, every question about
  # them would compare two empty answers, and the suite would go green.
  #
  # `ct/load-locals` changed shape upstream on 2026-09-21 (LRS-1: the language
  # travels by name rather than by ordinal), which is exactly the kind of
  # change that lands here. Whether it did is now a line in the log rather
  # than a guess.
  for (name, thunk) in {
      "requestAndLoadLocals": proc () = session.requestAndLoadLocals(),
      "requestAndLoadCalltrace": proc () = session.requestAndLoadCalltrace(),
      "requestAndLoadEventLog": proc () =
        discard session.requestAndLoadEventLog(0, 50)}:
    try:
      thunk()
    except CatchableError as e:
      result.producerFailures.add name & ": " & e.msg

  # THE EFFECT, read off the ViewModel the producers write into. Recorded here
  # and asserted by `the GPUI arm's locals producer LOADED something`, which is
  # a different case from `…all ran` on purpose: one is about raising and the
  # other is about arriving.
  result.localsLoaded =
    if session.session.stateVM.isNil: -1
    else: session.session.stateVM.currentVariables.val.len

  let viewport = viewportOf(sc.viewport)
  var shell = newGpuiShell(viewport)
  let slot = shell.app.openSession(session.backend.toBackendService(),
                                   title = trace, adopt = session.sdk)
  let windowId = WindowId(0)
  let opened = shell.openWindowForSession(windowId, slot.id)
  doAssert opened.kind == wsApplied,
    "the GPUI shell refused a window for scenario " & sc.id
  discard slot.activatePane(paneDebugControls)

  let sourceService = newGpuiSourceService(session, trace,
                                           editorRowsForViewport(viewport.height))
  defer: sourceService.close()
  sourceService.serveWindow()

  var points: seq[EditorPoint] = @[]
  let offset = breakpointOffset(sc.ops)
  if offset >= 0:
    # RESOLVED AGAINST THE RECORDING'S OWN SOURCE, never against a literal: the
    # first line the editor actually drew, plus the declared offset. A hardcoded
    # line number would make the scenario about this file rather than about the
    # program.
    let probe = editorSurfaceFor(
      source = sourceService.vm, editor = session.session.editorVM,
      state = session.session.stateVM, flow = session.session.flowVM,
      availability = sourceService.availability(),
      budget = gpuiRowBudget(), medium = GpuiMedium)
    if probe.rows.len > 0:
      let at = probe.rows[min(offset, probe.rows.high)].line
      points.add EditorPoint(path: session.getCurrentFile(), line: at,
                             kind: epkBreakpoint, enabled: true)

  let surface = editorSurfaceFor(
    source = sourceService.vm, editor = session.session.editorVM,
    state = session.session.stateVM, flow = session.session.flowVM,
    availability = sourceService.availability(),
    budget = gpuiRowBudget(), medium = GpuiMedium, points = points)

  gpui_reset_tree()
  resetCallbacks()
  var r: GpuiRenderer
  let leafSet = shell.leavesFor(windowId)
  let drawn = renderLeaves(r, leafSet, surface)
  doAssert leafPlanIsValid(r, drawn),
    "the GPUI render plan did not verify for scenario " & sc.id

  let projection = shell.projectionFor(windowId)
  result.answers = gpuiLayoutAnswers(sc.id, drawn.root, projection, viewport)
  result.rows = surface.rows.len
  result.serialised = serialise(result.answers)

# ---------------------------------------------------------------------------
# The Electron arm — a RECORDED capture, with its provenance
# ---------------------------------------------------------------------------

type ElectronRun = object
  answers: LayoutAnswerSet
  provenance: string
  tier1: string
  present: bool
  unknownKeys: seq[string]
    ## Question ids in the recorded file that this Nim side does not know.
    ## **Reported rather than dropped** — `answerSetFromJson` skips them, which
    ## is right for a parser and would be silent without this.
  stoppedLine: int
    ## The capture lane's own figure, from `window.data.services.debugger.
    ## location.line` — a DIFFERENT reading of the same fact than the one
    ## `executionLineIn` takes out of the gutter-marks answer's DOM. Two
    ## independent readings that must agree.
  capturePixels: string
  viewportCss: string
  moved: int
  uiBundleMtime: string
    ## Which `ui.js` the capture was taken against — what a tier-4 review has
    ## to match to be a review of this product rather than of a previous one.

proc readElectron(sc: Scenario): ElectronRun =
  let path = AnswerDir / (sc.id & ".electron.json")
  if not fileExists(path):
    raise newException(IOError,
      path & " is not here. The Electron arm is a RECORDED capture produced by " &
      "`just plat35-capture-electron` (which is `just test-gui-prebuilt " &
      "tests/visual/visual-alignment-capture.spec.ts` under Xvfb). It is NOT " &
      "skipped: a comparison with one arm missing is not a comparison, and a " &
      "suite that quietly became one would pass for ever.")
  let doc = parseJson(readFile(path))
  result.answers = answerSetFromJson(doc)
  result.unknownKeys = unknownQuestionKeys(doc)
  result.present = true
  let prov = doc{"provenance"}
  result.uiBundleMtime =
    if prov.isNil: "<no provenance recorded>"
    else: prov{"uiBundleMtime"}.getStr("<no uiBundleMtime>")
  result.provenance =
    if prov.isNil: "<no provenance recorded>"
    else: prov{"capturedAt"}.getStr("?") & " against ui.js of " &
          result.uiBundleMtime
  let capturePath = AnswerDir / (sc.id & ".electron.capture.json")
  result.stoppedLine = -1
  result.capturePixels = "<no capture manifest>"
  result.viewportCss = "<no capture manifest>"
  result.moved = -1
  if fileExists(capturePath):
    let man = parseJson(readFile(capturePath))
    result.tier1 = man{"tier1"}.getStr("<none>")
    result.stoppedLine = man{"stoppedLine"}.getInt(-1)
    result.capturePixels = man{"capturePixels"}.getStr("<not recorded>")
    result.viewportCss = man{"viewportCss"}.getStr("<not recorded>")
    result.moved = man{"operationsMoved"}.getInt(-1)
  else:
    result.tier1 = "<no capture manifest>"

# ---------------------------------------------------------------------------
# Everything is computed ONCE, before the suites
# ---------------------------------------------------------------------------

var gpuiRuns = initTable[string, GpuiRun]()
var electronRuns = initTable[string, ElectronRun]()

for sc in scenarios:
  electronRuns[sc.id] = readElectron(sc)
  gpuiRuns[sc.id] = runGpuiScenario(sc)

# ---------------------------------------------------------------------------

suite "PLAT-35: §3's layout-assertion vocabulary is an oracle table":

  test "the published table parses to the declared cardinality":
    ck publishedKeys.len == LayoutQuestionCount
    # A DUPLICATE CHECK IS PART OF THE PARSER (§7.3). Without it, "every
    # question appears and is answered" is satisfiable with one fewer distinct
    # name than the count claims.
    ck publishedKeys.toHashSet.len == publishedKeys.len
    for key in publishedKeys:
      ck key.len > 0

  test "every published question has an implementation id":
    var implemented = initHashSet[string]()
    for q in LayoutQuestion: implemented.incl $q
    let onlySpec = publishedKeys.toHashSet - implemented
    if onlySpec.len > 0:
      checkpoint("published in §3 and not implemented: " & $onlySpec)
    ck onlySpec.len == 0

  test "every implementation id is published":
    var implemented = initHashSet[string]()
    for q in LayoutQuestion: implemented.incl $q
    let onlyImpl = implemented - publishedKeys.toHashSet
    if onlyImpl.len > 0:
      checkpoint("implemented and not published in §3: " & $onlyImpl)
    ck onlyImpl.len == 0

  test "the two front-ends each emit all eight questions, per scenario":
    # **A FRONT-END'S OWN CARDINALITY, WHICH THE THREE CASES ABOVE DO NOT
    # ASSERT.** They compare the published table with the Nim enum; a
    # front-end could emit a perfectly-spelled subset of six and none of them
    # would look at it. `answeredQuestions` and `emittedQuestions` were
    # written for this and were called by nothing until 2026-09-21.
    for sc in scenarios:
      let g = gpuiRuns[sc.id].answers
      let e = electronRuns[sc.id].answers
      ck g.emittedQuestions.toHashSet.len == LayoutQuestionCount
      ck e.emittedQuestions.toHashSet.len == LayoutQuestionCount
      # EMITTED, not answered, is the cardinality claim: `Unanswered` is a
      # value and a front-end that cannot answer one still emits its row. How
      # many it ANSWERS is a measurement rather than a floor, so it is printed
      # and not asserted — a number asserted equal to today's value would fail
      # the day a front-end learned to answer one more.
      checkpoint(sc.id & ": gpui answers " & $gpuiRuns[sc.id].answers.answeredQuestions.len &
                 "/8, electron answers " & $e.answeredQuestions.len & "/8")
      # AND NOTHING WAS DROPPED ON THE WAY IN. `answerSetFromJson` skips a
      # question id it does not recognise; without this, a key renamed on the
      # Electron side would simply stop arriving and every check over "the
      # questions both sides have" would still pass (§4).
      if electronRuns[sc.id].unknownKeys.len > 0:
        checkpoint("the recorded Electron capture for " & sc.id &
                   " carries question ids this vocabulary does not know: " &
                   electronRuns[sc.id].unknownKeys.join(", "))
      ck electronRuns[sc.id].unknownKeys.len == 0

  test "both sets are exactly the declared cardinality of DISTINCT ids":
    # **THE LINE THAT IS USUALLY OMITTED.** Without it the two set differences
    # above are both satisfied by two empty sets.
    var implemented = initHashSet[string]()
    for q in LayoutQuestion: implemented.incl $q
    ck publishedKeys.toHashSet.len == LayoutQuestionCount
    ck implemented.len == LayoutQuestionCount
    ck implemented == publishedKeys.toHashSet

suite "PLAT-35: the scenario corpus is pinned":

  test "the scenario set is pinned at its declared cardinality":
    ck scenarios.len == expectedScenarios
    ck scenarios.len == 6
    var ids = initHashSet[string]()
    for sc in scenarios: ids.incl sc.id
    ck ids.len == scenarios.len

  test "every view name is distinct, one per scenario":
    var views = initHashSet[string]()
    for sc in scenarios: views.incl sc.view
    ck views.len == scenarioDoc["expectedViews"].getInt
    ck views.len == scenarios.len

  test "every operation is in the closed vocabulary":
    ck operationKinds.len == scenarioDoc["expectedOperationKinds"].getInt
    var used = initHashSet[string]()
    for sc in scenarios:
      for op in sc.ops:
        ck op.kind in operationKinds
        used.incl op.kind
    # EVERY MEMBER IS REACHABLE. A closed set with a member no scenario can
    # produce is an open set wearing a type.
    for kind in operationKinds:
      ck kind in used

  test "the viewport matrix and the canary set have their declared sizes":
    ck scenarioDoc["viewports"].len == expectedViewports
    var canaries = 0
    var viewportsUsed = initHashSet[string]()
    for sc in scenarios:
      if sc.canary: inc canaries
      viewportsUsed.incl sc.viewport
    ck canaries == expectedCanaries
    # BOTH VIEWPORTS ARE EXERCISED. A matrix with an unused row is a row that
    # has never been wrong.
    ck viewportsUsed.len == expectedViewports

  test "THE POPULATION: the six scenarios are pairwise distinct on screen":
    # **Verification-Harness-Traps §34.** A scenario set whose members are
    # structurally identical makes the whole comparison vacuous: eight questions
    # times six copies of one screen is eight cases wearing a multiplier. This
    # is the arm that can see it.
    var distinctGpui = initHashSet[string]()
    for sc in scenarios:
      distinctGpui.incl gpuiRuns[sc.id].serialised
    if distinctGpui.len != scenarios.len:
      checkpoint("only " & $distinctGpui.len & " of " & $scenarios.len &
                 " scenarios produce a distinct answer set on the GPUI arm")
      # NAME THE COLLIDING PAIR. "Five of six" sends the next reader to read
      # six answer sets by hand; the pair is what they need and the reducer
      # already has it.
      for i in 0 ..< scenarios.len:
        for j in i + 1 ..< scenarios.len:
          if gpuiRuns[scenarios[i].id].serialised ==
             gpuiRuns[scenarios[j].id].serialised:
            checkpoint("  collides: " & scenarios[i].id & " and " &
                       scenarios[j].id)
    ck distinctGpui.len == scenarios.len
    # And the same on the other arm, separately: a population that is only
    # distinct on one side is a population one front-end cannot tell apart.
    var distinctElectron = initHashSet[string]()
    for sc in scenarios:
      distinctElectron.incl serialise(electronRuns[sc.id].answers)
    if distinctElectron.len != scenarios.len:
      checkpoint("only " & $distinctElectron.len & " of " & $scenarios.len &
                 " scenarios produce a distinct answer set on the Electron arm")
    ck distinctElectron.len == scenarios.len

# ---------------------------------------------------------------------------
# THE CORPUS PINS — what makes a shifted corpus redden
# ---------------------------------------------------------------------------

let pinDoc = parseJson(readFile(requireFile(PinRel,
  "the pinned corpus is what makes a shifted corpus fail. ALL EIGHT " &
  "questions carry a gap, so ALL FORTY-EIGHT tier-3 cells take the residual " &
  "branch, and those residuals compare shapes rather than positions: " &
  "measured 2026-09-21, a corpus in which four of six scenarios reached a " &
  "DIFFERENT program state left this suite green at 90/309. No cell takes " &
  "the `gaps.len == 0` alignment branch — `inline-value-runs-by-line` did " &
  "for one day, while `PLAT35-VG7` stood retired, and that retirement was a " &
  "mistake now re-filed as `PLAT35-VG9`. These pins are the arm that can " &
  "see a moved corpus.")))
let pinnedScenarios = pinDoc["scenarios"]

proc admissibleRows(pin: JsonNode; key: string): seq[string] =
  ## The set of `editor-row-count` answers this arm is pinned to, as a `seq`.
  ##
  ## ALWAYS AN ARRAY IN THE FILE, even for the four scenarios whose answer is a
  ## single value. A schema where one entry is a string and another is a list is
  ## a schema in which the reader decides, and the reader would then be the
  ## second place the rule lives. Trap 13: a `proc`, returning a value, calling
  ## `check` nowhere.
  result = @[]
  if not pin.hasKey(key): return
  for v in pin[key]: result.add v.getStr

proc executionLineOf(s: LayoutAnswerSet): int =
  ## ONE reading, both arms — `executionLineIn` over the front-end's own
  ## `gutter-marks-by-line` answer. Two different extractors for the two arms
  ## would be two facts with one name (§30a's shape, one level down).
  executionLineIn(s.answerFor(lqGutterMarks)[1].value)

suite "PLAT-35: THE CORPUS IS PINNED — a shifted corpus reddens":

  test "the GPUI arm's three pane producers all ran":
    # **THE PANES HAVE TO BE FILLED BEFORE ANY QUESTION ABOUT THEM MEANS
    # ANYTHING** (§4a). A producer that raised would leave the state,
    # call-trace or event-log pane holding its "nothing at this position"
    # report, and every question about it would then compare two empty
    # answers and agree. This is that failure made into a check.
    var failures: seq[string] = @[]
    for sc in scenarios:
      for f in gpuiRuns[sc.id].producerFailures:
        failures.add sc.id & " / " & f
    if failures.len > 0:
      for f in failures: checkpoint(f)
    ck failures.len == 0

  test "the GPUI arm's locals producer LOADED something, not just ran":
    # **`…all ran` IS A CLAIM ABOUT RAISING. THIS IS THE CLAIM ABOUT
    # ARRIVING**, and the difference is not academic: measured 2026-09-21, a
    # gate run recorded NO producer failure and an EMPTY inline-value answer on
    # all six scenarios, while five other runs of the same binary on the same
    # tree reported values on three. A producer that runs and loads nothing
    # empties the panes exactly as one that raised; every question about them
    # then compares two empty answers and agrees; and that is what retired
    # `PLAT35-VG7` against a divergence that had not gone anywhere.
    #
    # `entry-shell` is EXCLUDED and that is the population control, not a
    # loophole: it is the unstepped scenario, a Python program at line 1
    # genuinely has no locals, and requiring some there would be requiring the
    # product to invent them. The five stepped scenarios are inside a function
    # and must have them.
    var empty: seq[string] = @[]
    for sc in scenarios:
      checkpoint(sc.id & ": stateVM holds " & $gpuiRuns[sc.id].localsLoaded &
                 " variable(s)")
      if sc.ops.len == 0: continue
      if gpuiRuns[sc.id].localsLoaded <= 0:
        empty.add sc.id & " loaded " & $gpuiRuns[sc.id].localsLoaded &
                  " variables with no producer failure — the panes are empty" &
                  " and every question about them will agree about nothing"
    if empty.len > 0:
      for e in empty: checkpoint(e)
    ck empty.len == 0

  test "a row-count pin with more than one member names a filed defect":
    # **THE COST OF A SET.** A pinned SET is weaker than a pinned value: it
    # tolerates a front-end that rests in more than one place. That tolerance
    # has to be paid for, or the next person who finds a flaky pin will widen
    # it and the pin will have become a wildcard one member at a time.
    #
    # So: every entry is an ARRAY, every array is non-empty, and an array with
    # MORE THAN ONE member must name a defect in `productDefectRegister()`
    # through `<arm>EditorRowsDefect`. Filing is the price of the tolerance,
    # and a filed defect carries a measurement, an owner and a date.
    #
    # The other direction is asserted too: a SINGLE-member array must NOT name
    # a defect, so an entry that has been repaired down to one value fails
    # until its now-false attribution is deleted.
    var filedIds = initHashSet[string]()
    for id, _ in productDefectRegister(): filedIds.incl $id
    var defended = true
    for sc in scenarios:
      let p = pinnedScenarios[sc.id]
      for arm in ["gpuiEditorRows", "electronEditorRows"]:
        let admissible = admissibleRows(p, arm)
        let defectKey = arm & "Defect"
        let defect = p{defectKey}.getStr("")
        if admissible.len == 0:
          checkpoint(sc.id & "/" & arm & " pins no answer at all")
          defended = false
        elif admissible.len > 1:
          checkpoint(sc.id & "/" & arm & " admits " & $admissible.len &
                     " answers: " & admissible.join(" | ") & " — filed as `" &
                     defect & "`")
          if defect notin filedIds:
            checkpoint(sc.id & "/" & arm & " admits more than one answer and " &
                       "`" & defectKey & "` is `" & defect & "`, which is in " &
                       "no register. A tolerance nobody filed is a wildcard.")
            defended = false
        elif defect.len > 0:
          checkpoint(sc.id & "/" & arm & " pins ONE answer and still names `" &
                     defect & "`. If the defect is repaired, delete the " &
                     "attribution; if it is not, the set is wrong.")
          defended = false
    ck defended

  test "the pin set covers exactly the pinned scenario set":
    # §4b: the membership is knowable, so the COUNT is asserted. A pin file
    # that lost five entries would otherwise make five scenarios unpinned and
    # nothing would say so.
    ck pinnedScenarios.len == pinDoc["expectedPinnedScenarios"].getInt
    ck pinnedScenarios.len == scenarios.len
    for sc in scenarios:
      ck pinnedScenarios.hasKey(sc.id)

  for sc in scenarios:
    test "the corpus for '" & sc.id & "' is where it was pinned":
      let p = pinnedScenarios[sc.id]
      let gpuiLine = executionLineOf(gpuiRuns[sc.id].answers)
      let elecLine = executionLineOf(electronRuns[sc.id].answers)
      let gpuiPanes = gpuiRuns[sc.id].answers.answerFor(lqPanesPresent)[1].value
      let elecPanes = electronRuns[sc.id].answers.answerFor(lqPanesPresent)[1].value
      # **PRINTED, NOT CHECKPOINTED.** A `checkpoint` is shown only when a
      # check in the same block fails, so the pinned measurements were visible
      # exactly when somebody already knew something was wrong. These four
      # numbers are the evidence every finding in this milestone rests on;
      # `PLAT35-VG6`'s whole content is two of them. Putting them in the log on
      # every run is what makes a re-derivation a matter of reading rather than
      # of re-instrumenting — and it is how the VG6 and VG7 measurements were
      # found to have gone stale.
      echo "CORPUS ", sc.id, ":"
      echo "  gpui     line=", gpuiLine, "  panes=", gpuiPanes
      echo "  electron line=", elecLine, "  panes=", elecPanes
      echo "  gpui     marks=",
        gpuiRuns[sc.id].answers.answerFor(lqGutterMarks)[1].value,
        "  inline=", gpuiRuns[sc.id].answers.answerFor(lqInlineValueRuns)[1].value
      echo "  electron marks=",
        electronRuns[sc.id].answers.answerFor(lqGutterMarks)[1].value,
        "  inline=",
        electronRuns[sc.id].answers.answerFor(lqInlineValueRuns)[1].value

      # **THE STOPPED LINE, PER ARM.** This is the number `PLAT35-VG6` is
      # entirely a claim about, and the number a re-run of the capture moves
      # when an operation lands somewhere else.
      ck gpuiLine == p["gpuiStoppedLine"].getInt
      ck elecLine == p["electronStoppedLine"].getInt

      # **AND THE SAME FACT READ A SECOND WAY.** The capture lane records the
      # line from `window.data.services.debugger.location`; the figure above
      # comes from the gutter the DOM drew. Two independent readings of one
      # fact, so a renderer that drew its execution mark on the wrong row
      # fails here rather than agreeing with itself.
      ck electronRuns[sc.id].stoppedLine == elecLine

      # **THE PANE CENSUS, PER ARM.** `PLAT35-VG5`'s four-against-eight is a
      # claim about exactly these two strings, and the residual for this
      # question only asks that three named panes are on both sides — which a
      # front-end that lost four of its other panes would still satisfy.
      ck gpuiPanes == p["gpuiPanes"].getStr
      ck elecPanes == p["electronPanes"].getStr

      # **AND THE EDITOR ROW COUNT, PER ARM, BECAUSE THIS FILE WAS BLIND TO IT
      # AND THAT IS HOW THE DRIFT SURVIVED THE MECHANISM BUILT TO CATCH IT.**
      #
      # Measured 2026-09-21: `returned-calltrace`'s Electron answer flipped
      # between `rows=36;first=82;last=117` and `rows=35;first=83;last=117`
      # across runs of the identical specification — four and three of seven
      # captures. NOTHING SAW IT. `editor-row-count` has `PLAT35-VG2` filed
      # against it, so its cell takes the residual branch, and that residual
      # asks only that both sides drew rows numbered ascending from a real
      # line; and the pins above are the stopped line and the pane census,
      # neither of which a scrolled editor moves. The capture is repaired (see
      # `waitForEditorFrameSettled` in the capture spec), and the repair is
      # not what makes the next one visible — this is.
      #
      # THE WHOLE ANSWER STRING, not the row count alone: `first` and `last`
      # are what say WHICH window the editor holds, and a scroll that moved
      # the window while keeping the count is exactly the drift a bare count
      # would absorb.
      #
      # **THE PIN IS A SET, AND A SET LARGER THAN ONE COSTS A FILED DEFECT.**
      # Two of the six scenarios rest at more than one scroll position for a
      # measured product reason (`PLAT35-PD4`), and the three positions are not
      # a list somebody observed — each is `contentHeight - layoutHeight` for
      # one of the three values the editor's content height takes as it grows.
      # Pinning a single value there would make this gate flake; pinning
      # nothing is what let the drift survive in the first place. So the set is
      # pinned, membership is asserted, and `pinnedRowsAreDefended` below makes
      # a multi-member set impossible to introduce without filing why.
      let gpuiRows = gpuiRuns[sc.id].answers.answerFor(lqEditorRowCount)[1].value
      let elecRows =
        electronRuns[sc.id].answers.answerFor(lqEditorRowCount)[1].value
      echo "  gpui     rows=", gpuiRows
      echo "  electron rows=", elecRows
      ck gpuiRows in admissibleRows(p, "gpuiEditorRows")
      ck elecRows in admissibleRows(p, "electronEditorRows")

      # THE CAPTURE'S OWN VIEWPORT, against the scenario's declaration. The
      # capture lane asserts this too; asserting it again here is not
      # redundancy but a different subject — the lane checks the run it is in,
      # this checks the artefact the gate is reading, which may have been
      # produced weeks earlier by a lane that did not have the check.
      let declared = scenarioDoc["viewports"][sc.viewport]
      let want = $declared["width"].getInt & "x" & $declared["height"].getInt
      ck electronRuns[sc.id].viewportCss == want
      ck electronRuns[sc.id].capturePixels == want

      # AND THE OPERATIONS MOVED THE PROGRAM. The lane counts EFFECTS now, not
      # clicks; a manifest from a lane that still counted clicks has no such
      # key and reports -1 here, which fails rather than being read as zero.
      var declaredOps = 0
      for op in sc.ops: declaredOps += max(op.times, 1)
      ck electronRuns[sc.id].moved == declaredOps

suite "PLAT-35: the review brief carries a per-scenario expected-elements block":

  let briefText = readFile(requireFile(BriefRel,
    "the design brief's per-scenario expected-elements blocks are half of the " &
    "mutation arm; without them the reviewer cannot tell 'the design is bad' " &
    "from 'I see nothing on screen'."))

  for sc in scenarios:
    test "the brief has a block for the '" & sc.view & "' view":
      let heading = "### View: `" & sc.view & "`"
      ck heading in briefText
      ck sc.id in briefText
      # THE BLOCK NAMES CONCRETE, COUNTABLE THINGS. A block that says "the
      # panes look right" passes every review and fails the mutation arm,
      # which is the methodology's checklist item 7 stated as a check.
      let at = briefText.find(heading)
      var blockEnd = briefText.find("### ", at + heading.len)
      if blockEnd < 0: blockEnd = briefText.find("## ", at + heading.len)
      if blockEnd < 0: blockEnd = briefText.len
      let body = briefText[at ..< blockEnd]
      var bullets = 0
      for line in body.splitLines():
        if line.strip().startsWith("- "): inc bullets
      ck bullets >= 3

      # **THE BLOCK NAMES THE SCENARIO'S OWN VIEWPORT, READ FROM THE
      # DEFINITION.** Not decoration: two of these blocks say *"at the
      # narrower viewport, nothing is clipped"*, and that is a check the
      # reviewer can only perform if the viewport the block names is the one
      # the capture was taken at.
      #
      # FOUND BY WRITING IT, 2026-09-21: the `calltrace` block said
      # `viewport wide` and its scenario has always been `laptop`. A reviewer
      # following that block would have been looking for clipping at the wrong
      # width, or not looking for it at all. The brief was transcribed from the
      # definition once and then the two were never compared — §30 through a
      # prose file.
      let vp = scenarioDoc["viewports"][sc.viewport]
      let dims = $vp["width"].getInt & "x" & $vp["height"].getInt
      ck ("viewport " & sc.viewport) in body
      ck dims in body

# ---------------------------------------------------------------------------
# TIER 3 — the gate. Eight questions x six scenarios.
# ---------------------------------------------------------------------------

proc gapsForQuestion(q: LayoutQuestion): seq[VisualGap] =
  let register = gapRegister()
  if register.hasKey(q): register[q] else: @[]

suite "PLAT-35: TIER 3 — one scenario, two front-ends, eight questions":

  for sc in scenarios:
    let gpui = gpuiRuns[sc.id]
    let electron = electronRuns[sc.id]

    for q in LayoutQuestion:
      test sc.id & " / " & $q:
        # BOTH FRONT-ENDS EMIT EVERY QUESTION. A missing row is never a skip:
        # §3 — *"a front-end that cannot answer one says so rather than
        # omitting it"*.
        let (gpuiHas, gpuiAnswer) = gpui.answers.answerFor(q)
        let (elecHas, elecAnswer) = electron.answers.answerFor(q)
        ck gpuiHas
        ck elecHas

        let verdict = compareAnswer(q, gpuiAnswer.value, elecAnswer.value)
        checkpoint("TIER  gpui=" & $gpuiAnswer.tier &
                   "  electron=" & $elecAnswer.tier &
                   "  (recorded " & electron.provenance & ")")
        checkpoint("GPUI      " & gpuiAnswer.value)
        checkpoint("ELECTRON  " & elecAnswer.value)
        checkpoint("VERDICT   " & $verdict.verdict & " " & verdict.detail)

        # **EITHER EQUAL OR A FILED, NAMED GAP — AND THE ASSERTION IS
        # TWO-SIDED**, which is the part that keeps it from being a license.
        #
        # A one-sided rule ("differing is fine if a gap exists") makes every
        # gapped question unfalsifiable: any answer at all satisfies it, so a
        # mutation aimed at one of those producers could never be killed, and
        # the gap register would grow into a list of questions nobody checks.
        # So the register is read as a PREDICTION:
        #
        #   no gap filed  -> the two front-ends MUST agree. This is the
        #                    alignment claim, and it is where the mutation arms
        #                    are aimed.
        #   a gap filed   -> they MUST still differ. A gap whose divergence has
        #                    been repaired is a gap that has to be retired, and
        #                    this is what makes somebody retire it.
        let gaps = gapsForQuestion(q)
        let agreed = verdict.verdict in {cvEqual, cvWithinTolerance}
        if gaps.len == 0:
          if not agreed:
            checkpoint("the two front-ends disagree about " & $q &
                       " and no gap is filed for it; file one with its " &
                       "measurement and its remedy, or repair the front-end")
          ck agreed
        else:
          # **A GAP IS NOT A LICENCE, IT IS A NARROWER CLAIM.** "They differ"
          # is satisfied by any two strings, so a cell that only tolerated
          # divergence would be a cell no mutation could redden — and the
          # first graded run of this vocabulary diverged on all eight
          # questions, so that would have been forty-eight decorative cases.
          # The gap's own measurement says what the divergence is LIMITED to;
          # `residualHolds` is that limit as a predicate, and a divergence
          # that grows past it fails here.
          var ids: seq[string] = @[]
          for g in gaps: ids.add $g.id
          let (holds, why) = residualHolds(q, gpuiAnswer.value,
                                           elecAnswer.value)
          checkpoint("RESIDUAL  " & ids.join(", ") & ": " & why)
          ck holds

suite "PLAT-35: a filed gap is retired when its divergence is repaired":

  for q in LayoutQuestion:
    if gapsForQuestion(q).len == 0: continue
    test "at least one scenario still diverges on " & $q:
      # **THE RETIREMENT CHECK.** The per-cell rule above asserts the gap's
      # RESIDUAL, which holds whether or not a particular scenario happens to
      # agree — so nothing there notices a gap whose divergence has been
      # repaired everywhere. This does: a gap that no scenario can still
      # demonstrate is a gap somebody has to delete, and this is what makes
      # them.
      var ids: seq[string] = @[]
      for g in gapsForQuestion(q): ids.add $g.id
      var diverging = 0
      for sc in scenarios:
        let g = gpuiRuns[sc.id].answers.answerFor(q)[1].value
        let e = electronRuns[sc.id].answers.answerFor(q)[1].value
        if compareAnswer(q, g, e).verdict notin {cvEqual, cvWithinTolerance}:
          inc diverging
      # **AND IT MUST NOT FIRE ON A RUN IN WHICH THE PANES NEVER FILLED.**
      # That is not a hypothetical: `PLAT35-VG7` was retired on 2026-09-21 by
      # this case, against a run in which the GPUI arm's locals had not
      # arrived. Every question about an empty pane compares two empty answers
      # and agrees, so `diverging == 0` said "repaired" about a divergence that
      # had not moved — and the gap was deleted. It is filed again as
      # `PLAT35-VG9`.
      #
      # So the precondition is stated rather than assumed: in a run where the
      # stepped scenarios loaded no locals, NO question's agreement is evidence
      # that anything was repaired. That run has its own red — `the GPUI arm's
      # locals producer LOADED something, not just ran` — and this case must
      # not add a second one telling somebody to delete a gap.
      var localsMissing = false
      for sc in scenarios:
        if sc.ops.len > 0 and gpuiRuns[sc.id].localsLoaded <= 0:
          localsMissing = true
      if diverging == 0 and localsMissing:
        checkpoint("no scenario diverges on " & $q & " in this run AND the " &
                   "GPUI arm loaded no locals on at least one stepped " &
                   "scenario. That is PLAT35-PD3, not a repair: two empty " &
                   "panes compare equal. " & ids.join(", ") & " stays filed.")
      elif diverging == 0:
        checkpoint("the two front-ends now agree about " & $q &
                   " on every one of the " & $scenarios.len &
                   " pinned scenarios, with the panes filled; retire " &
                   ids.join(", "))
      ck diverging > 0 or localsMissing

# ---------------------------------------------------------------------------
# TIER 4 — the human review, and whether it happened
# ---------------------------------------------------------------------------
#
# **TIER 4 IS THE GATE, AND IT HAD NO DELIVERABLE AT ALL UNTIL 2026-09-21.**
#
# §2's tier table calls tier 4 *"human review, on paired captures"* and
# `tools/visual-review-brief.md` opens with *"This is the gate. The tiers below
# it exist to keep this gate from being re-litigated on every commit, not to
# replace it."* A `7/10` and a `3/10`, a clipping finding and a tooltip finding
# were spoken of in this campaign. **None of them is in any artefact in this
# repository**, there was no file for one to be in, and nothing here could tell
# a review that happened from one that did not — which is §4 again, at the top
# of the tier stack rather than the bottom.
#
# So the review is a FILE with a schema, and this suite refuses it in four
# ways. The most important is the third:
#
#   * it must cover every pinned scenario;
#   * it must name the VIEWPORT it was taken at, and that must be the
#     scenario's declared one. Every finding in this milestone that cited
#     1440x900 was made against an artefact captured at 1923x1082, because the
#     viewport matrix was inert — so a review that cannot say which width it
#     saw is a review nobody can re-take;
#   * **a score below 4 BLOCKS.** The brief's own grammar makes below-4 a
#     MISSING OR DISTORTED ELEMENT rather than an aesthetic opinion — *"if any
#     expected element is missing, distorted, or replaced by a placeholder,
#     report that as the first finding and rate below 4 regardless of
#     polish"* — and content clipped mid-glyph is content loss. A milestone
#     does not land over a view whose expected elements are not on the screen,
#     so this is an assertion and not a note;
#   * it must be taken against the SAME BUILD as the answers it accompanies. A
#     review of last week's `ui.js` is a review of a different product.
#
# **WHAT IS NOT CLAIMED.** `reviewerKind` is a closed set of `human` and
# `agent`, it is counted, and the count is printed. Today it is six agent
# readings and ZERO human reviews. An agent reading the brief against the
# captures is a real check and is not the thing §2's table calls tier 4; the
# label is what keeps the difference visible, and it is the same rule
# PLAT-23 wrote for `ctSourceReading` one tier down.

let tier4Doc = parseJson(readFile(requireFile(Tier4Rel,
  "TIER 4 IS THE GATE and its verdicts have to live somewhere a reader can " &
  "find them. A campaign that speaks of a 7/10 and a 3/10 and has no artefact " &
  "holding either has not performed the review — it has described one.")))
let tier4Reviews = tier4Doc["reviews"]

# **THE QUARANTINE.** Read once, here, so the per-scenario cases below and the
# both-directions suite at the end are reading ONE value (§30). A tree with no
# `knownRed` block at all is a tree with an empty quarantine, which the cases
# grade exactly as they grade a present one — an absent block must not become
# an absent check.
proc knownRedOrEmpty(doc: JsonNode): JsonNode =
  ## AN ABSENT BLOCK IS AN EMPTY QUARANTINE, not an absent check. The cases
  ## below then assert that NOTHING scores below 4, which is the right thing to
  ## assert about a tree with nothing quarantined — and the far date makes "it
  ## has not expired" trivially true, because a permission nobody is using
  ## cannot expire. A `KeyError` here instead would be a crash that reads as a
  ## harness fault rather than as a verdict.
  ##
  ## Trap 13: this is a `proc` and it calls `check` nowhere.
  if doc.hasKey("knownRed"): return doc["knownRed"]
  result = newJObject()
  result["declaredKnownRed"] = newJInt(0)
  result["expiresOn"] = newJString("9999-12-31")
  result["scenarios"] = newJObject()

let knownRedDoc = knownRedOrEmpty(tier4Doc)
let quarantinedScenarios = knownRedDoc["scenarios"]

suite "PLAT-35: TIER 4 — the review is recorded, or its absence is":

  test "the review covers exactly the pinned scenario set":
    ck tier4Reviews.len == tier4Doc["expectedReviewedScenarios"].getInt
    ck tier4Reviews.len == scenarios.len
    for sc in scenarios:
      ck tier4Reviews.hasKey(sc.id)

  test "the reviewer kinds are a closed set and the human count is stated":
    var human = 0
    var agent = 0
    var kindsClosed = true
    for id, r in tier4Reviews:
      let kind = r{"reviewerKind"}.getStr("")
      if kind notin ["human", "agent"]:
        checkpoint(id & " has reviewerKind `" & kind & "`")
        kindsClosed = false
      if kind == "human": inc human else: inc agent
    ck kindsClosed
    checkpoint("TIER 4: " & $human & " human review(s), " & $agent &
               " agent reading(s), of " & $tier4Reviews.len & " scenarios")
    # THE DECLARED COUNT, ASSERTED (§4b). It is a number in the file rather
    # than a number here so that performing a human review is an edit to the
    # review, not an edit to the suite that grades it.
    ck human == tier4Doc["declaredHumanReviews"].getInt
    ck agent == tier4Doc["declaredAgentReadings"].getInt

  for sc in scenarios:
    test "the '" & sc.view & "' review was taken at its declared viewport":
      let r = tier4Reviews[sc.id]
      let vp = scenarioDoc["viewports"][sc.viewport]
      let want = $vp["width"].getInt & "x" & $vp["height"].getInt
      checkpoint("reviewed at " & r{"viewportPixels"}.getStr("<none>") &
                 ", declared " & want)
      ck r{"viewportPixels"}.getStr("") == want
      # AND AGAINST THE ARTEFACT THE GATE IS READING. The capture manifest
      # records the pixels that reached the disk; a review of a differently
      # sized image is a review of a different picture.
      ck r{"viewportPixels"}.getStr("") == electronRuns[sc.id].capturePixels

    test "the '" & sc.view & "' review is against the current build":
      let r = tier4Reviews[sc.id]
      # The answers carry `provenance.uiBundleMtime`; the review carries the
      # one it was taken against. Unequal means the product moved under the
      # review, which is the one thing a recorded human verdict cannot survive.
      ck r{"againstUiBundleMtime"}.getStr("<review>") ==
         electronRuns[sc.id].uiBundleMtime

    test "the '" & sc.view & "' review scores at or above the blocking floor":
      let r = tier4Reviews[sc.id]
      let score = r{"score"}.getInt(0)
      let findings = r{"findings"}
      ck (not findings.isNil) and findings.kind == JArray
      # EVERY REVIEW CARRIES ITS LEDGER. The brief's own words: *"a numeric
      # rating is a summary of the findings ledger, not a substitute for it"*.
      ck findings.len >= 1
      # **A FIXED NUMBER OF `ck`s PER SCENARIO, WHATEVER THE LEDGER HOLDS.**
      # `ExpectedAssertions` is a pinned constant read by
      # `ci/lib/run-nim-test-lane.sh`; a `ck` inside the findings loop would
      # make that constant a function of how many findings somebody wrote
      # down, so adding a finding to a review would redden the assertion
      # count. Reduce first, assert once.
      var kindsKnown = true
      var textsSubstantial = true
      for f in findings:
        if f{"kind"}.getStr("") notin
           ["missing-element", "alignment", "design", "state-not-reached"]:
          checkpoint("unknown finding kind: " & f{"kind"}.getStr(""))
          kindsKnown = false
        if f{"text"}.getStr("").len <= 20:
          checkpoint("a finding with no substance: " & f{"text"}.getStr(""))
          textsSubstantial = false
      ck kindsKnown
      ck textsSubstantial
      # **BELOW 4 BLOCKS — UNLESS IT IS QUARANTINED, AND A QUARANTINE IS
      # GRADED IN BOTH DIRECTIONS.** See `knownRed` in `tier4-review.json` and
      # the suite below, which asserts that the quarantined set is EXACTLY the
      # set scoring below 4. Here the two branches carry the same number of
      # `ck`s, because `ExpectedAssertions` is a pinned constant and a count
      # that moved with a review's score would be a count nobody could pin.
      if score < 4:
        var named: seq[string] = @[]
        for f in findings:
          if f{"kind"}.getStr("") == "missing-element":
            named.add f{"text"}.getStr("")
        checkpoint("BLOCKING: '" & sc.view & "' scored " & $score &
                   "/10. Below 4 is the brief's grammar for a MISSING OR " &
                   "DISTORTED element, not for an aesthetic opinion: " &
                   named.join(" | "))
      if quarantinedScenarios.hasKey(sc.id):
        let q = quarantinedScenarios[sc.id]
        checkpoint("QUARANTINED: '" & sc.view & "' is " &
                   q{"defect"}.getStr("<no id>") & ", owner " &
                   q{"owner"}.getStr("<none>") & ", expiring " &
                   knownRedDoc["expiresOn"].getStr)
        # **THE QUARANTINE MUST STILL BE NEEDED.** A scenario listed here that
        # has recovered is what the other direction is for: it fails, and the
        # remedy is to delete its entry rather than to leave a line describing
        # a defect that is gone.
        ck score < 4
      else:
        ck score >= 4
      ck score <= 10

# ---------------------------------------------------------------------------
# THE QUARANTINE — graded in both directions, and dated
# ---------------------------------------------------------------------------
#
# `PLAT-35` is a member of `just editor-model-case-floors`, a lane shared with
# eleven other milestones that hard-fails on any `[FAILED]` case. Two tier-4
# readings score 3, and `score < 4` blocks. Landing that red would put a
# permanently-red case into a shared lane, where "PLAT-35 is red" decays into
# noise that masks the next real regression; refusing to land the tool because
# of the defects it found is the other wrong answer. So the two are
# QUARANTINED — with the shape this repo already uses for its `known-dark`
# ledgers, whose rule is that the file FAILS IN BOTH DIRECTIONS.

suite "PLAT-35: THE QUARANTINE is exact, attributed and dated":

  test "the quarantined set is exactly the set below the blocking floor":
    # **BOTH DIRECTIONS, IN ONE COMPARISON.** A third scenario dropping below
    # 4 is not absorbed by the two already listed, and a listed scenario that
    # has recovered demands its entry be deleted. A subset check in either
    # direction alone is satisfied by the wrong set.
    var belowFloor = initHashSet[string]()
    for id, r in tier4Reviews:
      if r{"score"}.getInt(0) < 4: belowFloor.incl id
    var quarantined = initHashSet[string]()
    for id, _ in quarantinedScenarios: quarantined.incl id
    if belowFloor != quarantined:
      checkpoint("below the floor : " & toSeq(belowFloor).sorted.join(", "))
      checkpoint("quarantined     : " & toSeq(quarantined).sorted.join(", "))
      checkpoint("a scenario below 4 with no entry is an unowned permanent " &
                 "red; an entry whose scenario recovered is a line " &
                 "describing a defect that is gone. Both are failures here.")
    ck belowFloor == quarantined
    # §4b: the membership is knowable, so the COUNT is asserted too — a
    # declaration that drifted from the block below it is how a quarantine
    # silently grows.
    ck quarantined.len == knownRedDoc["declaredKnownRed"].getInt

  test "every quarantined case names a defect, an owner and a remedy":
    # A quarantine with no attribution is an exemption list. Each field is
    # asserted for SUBSTANCE rather than presence, because `"owner": "TBD"` is
    # a present field and is not an owner.
    var attributed = true
    for id, q in quarantinedScenarios:
      # THE PROSE FIELDS, by length. A sentence is what these are for, and 12
      # characters is not one. (`defect` and `subject` are NOT here: they are
      # short by design — `PLAT35-PD1` is ten characters and `front-end` is
      # nine — and a length rule over them is a rule about the wrong thing.
      # Measured: it rejected two correctly-filled entries on its first run.)
      for field in ["owner", "measurement", "remedy"]:
        let v = q{field}.getStr("")
        if v.len <= 40 or v.strip().toLowerAscii in
           ["tbd", "unknown", "investigate", "none"]:
          checkpoint(id & ": `" & field & "` is `" & v & "`")
          attributed = false
      # THE ID IS CAMPAIGN-NAMESPACED, the way every other register in this
      # campaign spells one, so it is greppable from either repo.
      if not q{"defect"}.getStr("").startsWith("PLAT35-"):
        checkpoint(id & ": `" & q{"defect"}.getStr("") &
                   "` is not a PLAT-35 defect id")
        attributed = false
      # AND THE SUBJECT IS FROM THE CLOSED SET `VisualGap` publishes, so
      # "which layer owes the repair" is answerable rather than free text.
      if q{"subject"}.getStr("") notin ["renderer", "front-end", "harness"]:
        checkpoint(id & ": `subject` is `" & q{"subject"}.getStr("") & "`")
        attributed = false
    ck attributed

  test "every filed product defect names an owner, a date and a remedy":
    # **THE REGISTER IS WHERE THIS CAMPAIGN FILES A DEFECT IT IS NOT FIXING**,
    # and `PLAT35-PD3` is why it exists: `PLAT35-VG7`'s retirement left an
    # unexplained PRODUCT regression recorded in an enum's doc comment, where
    # nobody returns to it. Every field is asserted for SUBSTANCE — a `subject`
    # names a layer and is not an owner, and an `owner` with no `reviewBy` is
    # not one either.
    var filed = true
    for id, d in productDefectRegister():
      checkpoint($id & ": subject=" & d.subject & ", reviewBy=" & d.reviewBy)
      if d.owner.len <= 20 or d.reviewBy.len != 10:
        checkpoint($id & " has owner `" & d.owner & "` and reviewBy `" &
                   d.reviewBy & "`")
        filed = false
      if d.subject notin ["renderer", "front-end", "harness"]:
        checkpoint($id & " has subject `" & d.subject & "`")
        filed = false
      # NEVER "differs", NEVER "investigate" — `VisualGap`'s own rule, applied
      # to the register that reuses its shape.
      if d.measurement.len <= 40 or d.remedy.len <= 40:
        checkpoint($id & " has a measurement or a remedy with no substance")
        filed = false
    ck filed

  test "every quarantined case points at a defect that is actually filed":
    # THE TWO REGISTERS ARE JOINED, IN THIS DIRECTION ON PURPOSE. A quarantine
    # naming an id nobody filed is a quarantine with no measurement and no
    # remedy behind it — the exemption list this is not allowed to become.
    var filedIds = initHashSet[string]()
    for id, _ in productDefectRegister(): filedIds.incl $id
    var allJoined = true
    for scenarioId, q in quarantinedScenarios:
      let defect = q{"defect"}.getStr("")
      if defect notin filedIds:
        checkpoint(scenarioId & " is quarantined against `" & defect &
                   "`, which is in no register. Filed: " &
                   toSeq(filedIds).sorted.join(", "))
        allJoined = false
    ck allJoined

  test "the quarantine has not expired":
    # **THE `nimsuggest-check.sh` RULE, AS A DATE.** That quarantine retires
    # itself by re-probing, because an upstream crash can be fixed under it.
    # These two defects cannot fix themselves, so the thing that has to expire
    # is the PERMISSION. On `expiresOn` this goes red, and the remedy is to
    # fix the defect or to re-file the quarantine with a new owner and a new
    # date — a deliberate edit somebody defends, which is the point.
    let expires = knownRedDoc["expiresOn"].getStr
    let today = now().format("yyyy-MM-dd")
    checkpoint("quarantine expires " & expires & "; today is " & today)
    if today > expires:
      checkpoint("the quarantine has expired. Fix the defects it names, or " &
                 "re-file it with a new owner and a new date. Extending it " &
                 "silently is the thing a date exists to prevent.")
    ck today <= expires

# ---------------------------------------------------------------------------
# TIER 1 — the determinism canary, WITHIN each renderer, never across
# ---------------------------------------------------------------------------

suite "PLAT-35: TIER 1 — the determinism canary, one per renderer":

  for sc in scenarios:
    if not sc.canary: continue

    test "GPUI capture of '" & sc.view & "' is deterministic":
      # Its question is *"is the capture harness still deterministic"*, which is
      # well-posed per renderer and meaningless between two rasterisers.
      #
      # **THE GPUI CAPTURE IS THE SHADOW TREE, NOT A PIXEL**, and that is
      # `PLAT35-VG1` rather than a silence: the shim in this workspace is built
      # without `--features gpui-backend`, so `createWindow` opens nothing.
      # A canary over the artefact this front-end CAN produce is worth more
      # than no canary at all, and is labelled.
      let again = runGpuiScenario(sc)
      if again.serialised != gpuiRuns[sc.id].serialised:
        checkpoint("first : " & gpuiRuns[sc.id].serialised)
        checkpoint("second: " & again.serialised)
      ck again.serialised == gpuiRuns[sc.id].serialised
      ck again.rows == gpuiRuns[sc.id].rows

    test "Electron capture of '" & sc.view & "' is deterministic":
      # Read from the capture manifest the Playwright lane wrote: a THIRD
      # screenshot, taken after the settle loop had already seen two identical
      # ones, must equal them.
      #
      # **ITS FAILURE INVALIDATES TIER 2 ON THIS SIDE**, which is why this suite
      # runs it before the thresholds below and why the verdict is a value in a
      # file rather than a line in a log.
      checkpoint("tier-1 verdict recorded by the capture lane: " &
                 electronRuns[sc.id].tier1)
      ck electronRuns[sc.id].tier1 == "identical"

# ---------------------------------------------------------------------------
# TIER 2 — the perceptual thresholds, per view
# ---------------------------------------------------------------------------

suite "PLAT-35: TIER 2 — a perceptual threshold per named view":

  let thresholds = parseJson(readFile(requireFile(ThresholdRel,
    "tier 2's thresholds are per view and are declared with their history, " &
    "because a threshold raised twice is a defect in the capture.")))

  for sc in scenarios:
    test "the '" & sc.view & "' view has a threshold with a history":
      ck thresholds["views"].hasKey(sc.view)
      let entry = thresholds["views"][sc.view]
      ck entry{"maxDifferingPixelRatioPerMille"}.getInt(0) > 0
      ck entry{"why"}.getStr("").len > 20
      let history = entry{"history"}
      ck (not history.isNil) and history.kind == JArray and history.len >= 1
      # **A THRESHOLD RAISED TWICE IS A DEFECT IN THE CAPTURE, NOT IN THE
      # THRESHOLD.** Enforced rather than quoted: a rule with no reader is a
      # sentence.
      var raises = 0
      var previous = -1
      for h in history:
        let value = h{"value"}.getInt(0)
        if previous >= 0 and value > previous: inc raises
        previous = value
      if raises >= 2:
        checkpoint("the '" & sc.view & "' threshold has been raised " &
                   $raises & " times; investigate what is non-deterministic " &
                   "in the capture instead of raising it again")
      ck raises < 2
      # The cross-renderer arm is blocked and SAYS SO. A threshold quietly not
      # applied is the same shape as a scanner that finds nothing.
      ck thresholds{"crossRendererArmBlockedBy"}.getStr("").len > 0

# ---------------------------------------------------------------------------
# The comparator and the gap register — the arming of everything above
# ---------------------------------------------------------------------------

suite "PLAT-35: the comparison can fail, and every gap is filed":

  test "the comparator reports a DIFFERENCE over two real answers":
    # **§4a's positive twin.** Without it, a comparator that returned `cvEqual`
    # for everything would make all forty-eight cases above true for free.
    # The two values are two REAL answers from two different scenarios on the
    # same arm, never two literals.
    let a = gpuiRuns["entry-shell"].answers.answerFor(lqGutterMarks)[1].value
    let b = gpuiRuns["stepped-editor"].answers.answerFor(lqGutterMarks)[1].value
    ck a != b
    ck compareAnswer(lqGutterMarks, a, b).verdict == cvDiffers
    ck compareAnswer(lqGutterMarks, a, a).verdict == cvEqual

  test "the comparator reports ONE-SIDE-SILENT rather than equal":
    let a = gpuiRuns["stepped-editor"].answers.answerFor(lqEditorRowCount)[1].value
    ck a != Unanswered
    ck compareAnswer(lqEditorRowCount, a, Unanswered).verdict == cvOneSideSilent
    ck compareAnswer(lqEditorRowCount, Unanswered, a).verdict == cvOneSideSilent
    ck compareAnswer(lqEditorRowCount, Unanswered, Unanswered).verdict ==
       cvBothSilent

  test "the pane-rectangle tolerance is applied and is not a free pass":
    # The ONE question compared with a tolerance. Two rectangles one point
    # apart are within it; two rectangles far apart are not, and a tolerance
    # that swallowed the second would make question one unable to fail.
    let near = "editor=0,0,50,100;state=50,0,50,100"
    let alsoNear = "editor=0,0,51,100;state=51,0,49,100"
    # `far` differs in ONE FIELD ONLY — the editor's width. That is deliberate
    # rather than incidental: a pair differing in three fields is caught by
    # whichever check runs first, so a mutation that disables one of the four
    # comparisons survives. One field, one comparison, one arm that can kill it.
    let far = "editor=0,0,20,100;state=50,0,50,100"
    ck compareAnswer(lqPaneRectangles, near, alsoNear).verdict ==
       cvWithinTolerance
    ck compareAnswer(lqPaneRectangles, near, far).verdict == cvDiffers

  test "every filed gap carries a measurement and a remedy":
    let gaps = allGaps()
    ck gaps.len == ord(high(VisualGapId)) + 1
    var ids = initHashSet[string]()
    for g in gaps:
      ids.incl $g.id
      ck g.subject.len > 0
      # NEVER "differs" AND NEVER "investigate". A gap whose measurement is a
      # verb is a gap nobody can close.
      ck g.measurement.len > 60
      ck g.remedy.len > 20
      ck "investigate" notin g.remedy.toLowerAscii()
      # The question it is filed against must be one of the published eight.
      ck ($g.question) in publishedKeys
    ck ids.len == gaps.len

suite "PLAT-35: the assertion count":
  test "every case ran":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
