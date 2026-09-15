## plat18_marshalling_probe.nim — PLAT-18 deliverable 1, the marshalling
## instrument, run against the variables pane with the 600-member fixture.
##
## ## WHAT THIS MEASURES, AND IN WHICH UNITS
##
## `codetracer-specs/Architecture/Uniform-WASM-Core.md` §3 names the hazard:
## not call overhead, which is cheap, but **marshalling** — "how many bytes,
## and how often". §6 step 1 says to put the instrument on the **current**
## build first, because the baseline is what the whole comparison rests on.
##
## This probe drives THE REAL `StateVM`, THE REAL `state_view` projection and
## THE REAL `views/isonim_state_view` panel — the same three the desktop runs
## — over a 600-member compound value, and reports, per phase:
##
##   * `crossings`   renderer operations issued              (count)
##   * `bytes`       what those operations occupy on a flat wire   (bytes)
##   * `encode_ns`   time to WRITE those bytes into a buffer       (ns)
##   * `decode_ns`   time to READ them back into runtime strings   (ns)
##   * `wall_ns`     the phase's own wall time WITH THE METER OFF  (ns)
##
## **These are four different quantities and must never be quoted as one.**
## `wall_ns` is taken in a separate pass with `meterEnabled = false`, because
## a wall time measured while an instrument is running is a measurement of the
## instrument. `bytes` is structural and is the same integer on all three
## backends; `encode_ns` and `decode_ns` are properties of the runtime taking
## them.
##
## ## WHAT `encode_ns` AND `decode_ns` MEAN ON THE CURRENT BUILD
##
## Nothing. That is the finding, and it is the point. On `nim js` the core and
## the DOM are one heap, so no string is encoded and no string is decoded —
## the figures below are **the cost the current build does not pay**, measured
## in the same runtime over exactly the bytes the `bytes` column counts. They
## are the thing a WASM core would add. Reported that way and no other way.
##
## ## THE PHASES, AND WHY THESE FOUR
##
##   MOUNT     the panel's first render, wide node COLLAPSED — what a user
##             sees on arrival at a frame
##   EXPAND    `toggleExpand` on the wide node. 600 rows appear in ONE
##             reactive update through the mounted panel. This is §4 metric 3
##             — "latency with a large state tree" — and it is the worst case
##             the product has
##   STEP      a locals response that changes ONE value, into the same
##             mounted panel with the 600 rows still open. This is §4
##             metric 2 at the rate a user actually generates
##   COLLAPSE  `toggleExpand` back: what the boundary pays to REMOVE 600 rows
##
## ## NO MOCKS BEYOND THE TWO THE ARCHITECTURE MANDATES
##
## `MockBackendService` stands in for the DAP transport and `MockRenderer` is
## IsoNim's renderer-agnostic DOM — the same pair
## `codetracer-specs/Testing/ViewModel-Testing-Architecture.md` mandates and
## the same pair every suite in `vm-unit` uses. The VM, the projection, the
## view, the presenter and the reactive layer are all real.
##
## **Why `MockRenderer` and not `WebRenderer` for the byte counts.** The row
## markup is `renderVariableRowImpl`, a TEMPLATE expanded once per concrete
## renderer, so the Mock and Web panels emit the same operations for the rows
## — and the rows are the 600. `WebRenderer` needs a browser and cannot be
## compiled on the C or WASM backends at all, so a probe built on it could not
## produce the three-backend comparison this milestone is about. The Electron
## arm measures `WebRenderer` directly; see `ci/test/plat18-electron-slice.sh`.
##
## ## THE FIXTURE
##
## The `wide_state` recording's own 600-entry mapping, on the wire as a `Seq`
## of `Tuple`s, which is how a Python dict actually arrives. Each row's
## `value` is **the presenter's answer at `StatePanelBudget`** — the product's
## own rendering, obtained by the same call the product makes — rather than a
## string typed here, so a change to the presenter moves these numbers.
##
## ## USAGE
##
##   nim c   -r ... plat18_marshalling_probe.nim            # current: native
##   nim js  -d:nodejs ... && node …                        # current: Electron's backend
##   nim c --cpu:wasm32 … && node …                         # PLAT-17's core
##
## Every line it prints is `PLAT18-MARSHAL …`, and the last is
## `PLAT18-MARSHAL-VERDICT ok|FAIL …`.

import std/[strutils, times, monotimes, algorithm, tables]

import isonim/core/signals
import isonim/core/owner
import isonim/core/async_compat
import isonim/core/boundary_meter
import isonim/testing/mock_dom

import ../../store/types as store_types
import ../../store/replay_data_store
import ../../backend/mock_backend
import ../../viewmodels/state_vm
import ../../views/state_view
import ../../views/isonim_state_view

import ../../../../common/value_presentation

const
  WideMemberCount = 600
    ## The `wide_state` fixture's own member count. The same constant
    ## `src/frontend/tui/tests/apps/app_variables.nim` declares, for the same
    ## reason: the pagination and the text volume the pane meets on a real
    ## trace are what the boundary has to carry.
  WideName = "mapping"
  Samples = 12
    ## How many independent repetitions each phase is measured over. A single
    ## timing under load is a coin flip (Verification-Harness-Traps.md §12a),
    ## so every published figure here is a MEDIAN of this many, and the min
    ## and max are printed beside it so a reader can see the spread rather
    ## than being handed a point.

# ---------------------------------------------------------------------------
# The fixture
# ---------------------------------------------------------------------------

proc wideEntry(index: int): PValue =
  ## `mapping["key_%03d" % index] = index * 2`, decoded as a tuple — the rule
  ## the recorded program itself declares (see
  ## `src/frontend/tui/tests/test_variables_tree_expansion.nim`'s
  ## `expectedMemberValue`, which reads the constant off disk).
  let key = "key_" & align($index, 3, '0')
  PValue(kind: pvkTuple, typeName: "Tuple", sourceKind: "Tuple",
         members: @[
           member("", PValue(kind: pvkString, text: key, typeName: "String",
                             sourceKind: "String")),
           member("", PValue(kind: pvkInt, text: $(index * 2), typeName: "Int",
                             sourceKind: "Int"))])

proc renderedAtStatePanelBudget(v: PValue): string =
  ## The product's own rendering of `v` for THIS pane. Derived rather than
  ## typed: a hand-written copy would keep these byte counts stable through a
  ## change to the presenter, which is the one regression the instrument
  ## exists to see.
  present(v, StatePanelBudget).root.text

proc wideVariable(): store_types.Variable =
  ## One 600-member compound `Variable`, children included.
  var children: seq[store_types.Variable] = @[]
  var memberPValues: seq[PMember] = @[]
  for i in 0 ..< WideMemberCount:
    let pv = wideEntry(i)
    memberPValues.add member("", pv)
    children.add store_types.Variable(
      name: $i,
      value: renderedAtStatePanelBudget(pv),
      presented: pv,
      typeName: "Tuple",
      hasChildren: false,
      children: @[])
  let whole = PValue(kind: pvkSequence, typeName: "Dict", sourceKind: "Seq",
                     members: memberPValues)
  store_types.Variable(
    name: WideName,
    value: renderedAtStatePanelBudget(whole),
    presented: whole,
    typeName: "Dict",
    hasChildren: true,
    children: children)

proc narrowVariable(tick: int): store_types.Variable =
  ## The one scalar a step changes. `tick` is what moves.
  ##
  ## FIXED WIDTH, and that is not cosmetic. The STEP phase's byte count is a
  ## structural figure the probe asserts is identical across its twelve
  ## samples, and a bare `$tick` makes it grow by one byte at every power of
  ## ten — so the run would report "structural figures not stable" for a
  ## reason about the counter rather than about the boundary. Measured: the
  ## first draft reported `16/424 vs 16/425` between sample 9 and sample 10.
  let pv = PValue(kind: pvkInt, text: align($tick, 6, '0'), typeName: "Int",
                  sourceKind: "Int")
  store_types.Variable(name: "counter", value: renderedAtStatePanelBudget(pv),
                       presented: pv, typeName: "int",
                       hasChildren: false, children: @[])

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

type
  PhaseSample = object
    crossings: int
    bytes: int64
    payload: int64
    handleBytes: int64
    lengthBytes: int64
    opcodeBytes: int64
    stringArgs: int64
    encodeNs: int64
    decodeNs: int64
    decodedBytes: int64
    mismatch: int
    rows: int
    opsByKind: array[BoundaryOp, int]

var problems: seq[string] = @[]

proc nowNs(): int64 = (getMonoTime() - MonoTime()).inNanoseconds

proc snapshot(rows: int): PhaseSample =
  PhaseSample(crossings: meter.totalCrossings(), bytes: meter.totalBytes(),
              payload: meter.payloadBytes, handleBytes: meter.handleBytes,
              lengthBytes: meter.lengthBytes, opcodeBytes: meter.opcodeBytes,
              stringArgs: meter.stringArgs,
              encodeNs: meter.encodeNs, decodeNs: meter.decodeNs,
              decodedBytes: meter.decodedBytes, mismatch: meter.sizeMismatch,
              rows: rows, opsByKind: meter.ops)

proc median(xs: seq[int64]): int64 =
  if xs.len == 0: return 0
  var s = xs
  s.sort()
  s[s.len div 2]

proc reportPhase(phase: string; samples: seq[PhaseSample]; wall: seq[int64]) =
  ## One line per phase. Every figure carries its sample count.
  if samples.len == 0:
    problems.add(phase & ": no samples")
    return
  let head = samples[0]

  # THE STRUCTURAL FIGURES MUST NOT MOVE BETWEEN SAMPLES. They are a property
  # of the view and the fixture, not of the host, so a spread here means the
  # probe is measuring two different renderings and no timing over them means
  # anything. Checked rather than assumed.
  for s in samples:
    if s.crossings != head.crossings or s.bytes != head.bytes:
      problems.add(phase & ": structural figures not stable across samples (" &
                   $head.crossings & "/" & $head.bytes & " vs " &
                   $s.crossings & "/" & $s.bytes & ")")
      break
  for s in samples:
    if s.mismatch != 0:
      problems.add(phase & ": frame size disagreed with frameBytesFor " &
                   $s.mismatch & " time(s)")
      break
    if s.decodedBytes != s.payload:
      problems.add(phase & ": decode returned " & $s.decodedBytes &
                   " byte(s) of " & $s.payload)
      break

  var encs, decs: seq[int64] = @[]
  for s in samples:
    encs.add s.encodeNs
    decs.add s.decodeNs
  let wallSorted = wall

  # THE PER-OPERATION BREAKDOWN IS NOT DECORATION. Three of these operations
  # — `firstChild`, `nextSibling`, `parentNode` — are READS of the node tree
  # that IsoNim's reconciler issues while it decides what to update. A WASM
  # core cannot hold a DOM node (§3), so each of those either crosses the
  # boundary and comes BACK, or is answered out of a shadow tree the core has
  # to keep in linear memory. Which of the two it is decides both a per-update
  # cost and a memory cost, so the count has to be visible rather than folded
  # into a total.
  var opBreakdown = ""
  for op in BoundaryOp:
    if head.opsByKind[op] > 0:
      opBreakdown.add " op_" & ($op)[2 .. ^1] & "=" & $head.opsByKind[op]

  echo "PLAT18-MARSHAL phase=", phase,
       " samples=", samples.len,
       " rows=", head.rows,
       " crossings=", head.crossings,
       " bytes=", head.bytes,
       " payload_bytes=", head.payload,
       " handle_bytes=", head.handleBytes,
       " length_bytes=", head.lengthBytes,
       " opcode_bytes=", head.opcodeBytes,
       " string_args=", head.stringArgs,
       " encode_ns_median=", median(encs),
       " encode_ns_min=", min(encs),
       " encode_ns_max=", max(encs),
       " decode_ns_median=", median(decs),
       " decode_ns_min=", min(decs),
       " decode_ns_max=", max(decs),
       " wall_ns_median=", median(wallSorted),
       " wall_ns_min=", min(wallSorted),
       " wall_ns_max=", max(wallSorted),
       opBreakdown

# ---------------------------------------------------------------------------
# The world
# ---------------------------------------------------------------------------

proc drain() =
  drainPlatformCallbacks()

type World = object
  store: ReplayDataStore
  vm: StateVM
  panel: MockNode
  r: MockRenderer

proc countRows(node: MockNode): int =
  ## How many variable rows the panel actually holds. Named `data-variable-name`
  ## because that is the attribute the product's own tests locate rows by.
  if node.kind == mnkElement and node.attributes.hasKey("data-variable-name") and
     node.attributes.getOrDefault("class", "").contains("value-expanded-name"):
    result = 1
  for c in node.children:
    result += countRows(c)

# ---------------------------------------------------------------------------
# The measurement
# ---------------------------------------------------------------------------

proc run() =
  let wide = wideVariable()

  var
    mountS, expandS, stepS, collapseS: seq[PhaseSample] = @[]
    mountW, expandW, stepW, collapseW: seq[int64] = @[]
    mountRows, expandRows, stepRows, collapseRows = 0
    expandRowsSeen = 0

  ## Two passes over the same script. `metered = true` fills the byte and
  ## codec columns; `metered = false` fills the wall column. They are separate
  ## because a wall time taken while the codec runs is a timing of the codec.
  for metered in [true, false]:
    for sample in 0 ..< Samples:
      createRoot proc(dispose: proc()) =
        let backend = newMockBackendService().toBackendService()
        let store = createReplayDataStore(backend)
        let vm = createStateVM(store)
        let r = MockRenderer()
        store.locals.locals.val = @[narrowVariable(0), wide]
        drain()

        meterEnabled = metered
        meterCodec = metered

        # ---- MOUNT ----
        resetMeter()
        var t0 = nowNs()
        let panel = renderStatePanel(r, vm)
        var t1 = nowNs()
        if metered: mountS.add snapshot(countRows(panel))
        else: mountW.add(t1 - t0)
        mountRows = countRows(panel)

        # ---- EXPAND ----
        resetMeter()
        t0 = nowNs()
        vm.toggleExpand(WideName)
        drain()
        t1 = nowNs()
        expandRowsSeen = countRows(panel)
        if metered: expandS.add snapshot(expandRowsSeen)
        else: expandW.add(t1 - t0)
        expandRows = expandRowsSeen

        # ---- STEP ----
        resetMeter()
        t0 = nowNs()
        store.locals.locals.val = @[narrowVariable(sample + 1), wide]
        drain()
        t1 = nowNs()
        if metered: stepS.add snapshot(countRows(panel))
        else: stepW.add(t1 - t0)
        stepRows = countRows(panel)

        # ---- COLLAPSE ----
        resetMeter()
        t0 = nowNs()
        vm.toggleExpand(WideName)
        drain()
        t1 = nowNs()
        if metered: collapseS.add snapshot(countRows(panel))
        else: collapseW.add(t1 - t0)
        collapseRows = countRows(panel)

        meterEnabled = false
        meterCodec = false
        dispose()

  # ---- the non-vacuity floor -------------------------------------------
  #
  # Every figure above is over a screen. A screen that did not have 600 rows
  # on it is a different measurement wearing this one's name, so the row
  # counts are asserted rather than reported.
  if mountRows != 2:
    problems.add("MOUNT drew " & $mountRows & " row(s), expected 2")
  if expandRows != 2 + WideMemberCount:
    problems.add("EXPAND drew " & $expandRows & " row(s), expected " &
                 $(2 + WideMemberCount))
  if stepRows != 2 + WideMemberCount:
    problems.add("STEP drew " & $stepRows & " row(s), expected " &
                 $(2 + WideMemberCount))
  if collapseRows != 2:
    problems.add("COLLAPSE drew " & $collapseRows & " row(s), expected 2")

  reportPhase("MOUNT", mountS, mountW)
  reportPhase("EXPAND", expandS, expandW)
  reportPhase("STEP", stepS, stepW)
  reportPhase("COLLAPSE", collapseS, collapseW)

  # ---- the state-snapshot alternative ----------------------------------
  #
  # §3's closing sentence: "A ViewModel that hands over a rendered string per
  # cell will be slow at any call cost; one that hands over a compact diff
  # will not." The op stream above IS the fine-grained design. This is the
  # other one — hand the whole `StateViewState` across on every update — so a
  # reader can see what the two cost without having to build the second.
  createRoot proc(dispose: proc()) =
    let backend = newMockBackendService().toBackendService()
    let store = createReplayDataStore(backend)
    let vm = createStateVM(store)
    store.locals.locals.val = @[narrowVariable(0), wide]
    drain()
    vm.toggleExpand(WideName)
    drain()
    let vs = getStateViewState(vm)
    var snapBytes = 0
    for v in vs.variables:
      # Every string field a renderer needs, plus the four scalars, framed the
      # same way `boundary_meter` frames a renderer operation.
      snapBytes += frameBytesFor(0,
        utf8ByteLen(v.name) + utf8ByteLen(v.path) + utf8ByteLen(v.value) +
        utf8ByteLen(v.typeName), 4) + 4
    echo "PLAT18-MARSHAL phase=SNAPSHOT-ALTERNATIVE samples=1 rows=",
         vs.variables.len, " bytes=", snapBytes,
         " note=whole-StateViewState-per-update-not-the-shipped-design"
    dispose()

when defined(ctPlat18Slice):
  import ./plat18_frame_renderer

  proc crossCheckWireAgainstMeter() =
    ## TWO IMPLEMENTATIONS OF ONE WIRE FORMAT, WITH A MECHANICAL EQUALITY
    ## BETWEEN THEM (Verification-Harness-Traps.md §14).
    ##
    ## `boundary_meter` COUNTS what an operation would cost; `plat18_frame_
    ## renderer` WRITES the bytes a host applies. There genuinely have to be
    ## two — one is an instrument on the current build, the other is the
    ## slice's actual boundary — and §14's remedy for the case where there
    ## have to be two is to make each have evidence the other cannot satisfy
    ## and to assert they agree.
    ##
    ## So: render the SAME panel over the SAME VM state through BOTH
    ## renderers, and require the same total. They receive the same operation
    ## stream by construction (one view, one `renderStatePanelImpl`), so any
    ## difference is a difference between the two encodings — a field one of
    ## them charges for and the other does not.
    for phase in ["MOUNT", "EXPAND"]:
      var meterBytes: int64 = 0
      var wireBytesTotal = 0
      let wide = wideVariable()

      createRoot proc(dispose: proc()) =
        let store = createReplayDataStore(newMockBackendService().toBackendService())
        let vm = createStateVM(store)
        let r = MockRenderer()
        store.locals.locals.val = @[narrowVariable(0), wide]
        drain()
        meterEnabled = true
        meterCodec = false
        resetMeter()
        let panel = renderStatePanel(r, vm)
        if phase == "EXPAND":
          resetMeter()
          vm.toggleExpand(WideName)
          drain()
        discard panel
        meterBytes = meter.totalBytes()
        meterEnabled = false
        dispose()

      createRoot proc(dispose: proc()) =
        let store = createReplayDataStore(newMockBackendService().toBackendService())
        let vm = createStateVM(store)
        let fr = FrameRenderer()
        store.locals.locals.val = @[narrowVariable(0), wide]
        drain()
        resetFrameRenderer()
        let panel = renderStatePanel(fr, vm)
        if phase == "EXPAND":
          wireReset()
          vm.toggleExpand(WideName)
          drain()
        discard panel
        wireBytesTotal = wireBytes()
        dispose()

      if meterBytes != int64(wireBytesTotal):
        problems.add("wire/meter disagree on " & phase & ": meter " & $meterBytes &
                     " byte(s), wire " & $wireBytesTotal)
      else:
        echo "PLAT18-MARSHAL cross-check phase=", phase,
             " meter_bytes=", meterBytes, " wire_bytes=", wireBytesTotal, " AGREE"

when isMainModule:
  echo "PLAT18-MARSHAL build=", (when defined(js): "nim-js"
                                elif defined(emscripten): "wasm32-emscripten"
                                else: "native-c"),
       " mm=", (when defined(gcOrc): "orc"
                elif defined(gcArc): "arc"
                elif defined(gcRefc): "refc"
                elif defined(js): "js-gc"
                else: "unknown"),
       " release=", (when defined(release): "yes" else: "no"),
       " danger=", (when defined(danger): "yes" else: "no"),
       " fixture=wide_state-600"
  run()
  when defined(ctPlat18Slice):
    crossCheckWireAgainstMeter()
  if problems.len == 0:
    echo "PLAT18-MARSHAL-VERDICT ok"
  else:
    for p in problems:
      echo "PLAT18-MARSHAL-PROBLEM ", p
    echo "PLAT18-MARSHAL-VERDICT FAIL ", problems.len, " problem(s)"
    quit(1)
