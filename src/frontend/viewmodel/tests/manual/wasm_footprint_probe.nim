## NOT-A-TEST-LANE-FILE: a measurement probe, not a suite. It asserts nothing
## and has no pass/fail; it prints numbers, and the thing that grades them is
## `ci/test/wasm-footprint.sh`, which runs this on two backends and compares.
## Putting an absolute byte bound in here would be
## Verification-Harness-Traps.md §12a — an absolute bound on a single
## measurement, which is a coin flip with one side hidden.
##
## wasm_footprint_probe.nim — PLAT-17 deliverable 2: `--mm:orc` under a linear
## memory target, with the STEADY-STATE FOOTPRINT MEASURED BEFORE ANY UI IS
## ATTACHED.
##
## ## What is measured, and why these three numbers
##
## A WASM module's memory is not one number. `Uniform-WASM-Core.md` §4 row 4
## says "linear memory plus the host heap, against today's single heap", and a
## probe that reports only the total cannot tell a core that needs 4 MiB from
## one that TOUCHED 4 MiB once and settled at 400 KiB. So:
##
##   baseline    live bytes after module init and one warm-up session, before
##               this program constructs the graph it measures. This is the
##               floor: Nim's own module initialisers, the lazily-built
##               tables, the string literals. Nothing a ViewModel does can go
##               below it.
##   peak        live bytes at the point where `sessions` sessions are all
##               alive at once. The transient cost of building the core.
##   steady      live bytes after every session has been disposed and ORC has
##               been given the chance to collect. THIS is the number the
##               milestone asks for: what the core costs to HOLD, not what it
##               cost to build.
##
## `system.getOccupiedMem()` is the instrument, and the two obvious
## alternatives were both tried and both measure the wrong thing:
##
##   * `wasmMemory.buffer.byteLength` / `emscripten_get_heap_size()` only ever
##     GROWS -- that is what `-sALLOW_MEMORY_GROWTH=1` means -- so it is a
##     high-water mark and would report the PEAK under the name of the steady
##     state. It is printed anyway, as its own row, because the gap between it
##     and the occupancy is exactly "how much linear memory this module will
##     never give back", which is a real cost in a tab.
##   * `sbrk(0)` looks portable and is not. Measured on this host: under
##     glibc the break does not move at all across eight sessions, because
##     malloc serves them from an arena it took with `mmap`, so every delta
##     was 0 and the probe's own verdict fired. It is the right instrument on
##     emscripten and a constant on native, which makes it useless for the
##     COMPARISON, and the comparison is the point.
##
## `getOccupiedMem()` is Nim's own allocator's idea of live bytes. It is the
## same number on both targets and it comes back DOWN, so "steady below peak"
## is a statement about reclamation rather than about an allocator's
## bookkeeping.
##
## ## What "before any UI is attached" means here
##
## Exactly what it says: the graph built below is the Embed SDK's own
## `DebuggerSession` plus the seven panel ViewModels, through
## `codetracer_embed` and `MockBackendService`. No renderer, no DOM, no
## terminal, no isonim node tree. Adding a UI is PLAT-18's vertical slice and
## its numbers belong there.
##
## ## The build a number quotes
##
## Every figure this prints is meaningless without its build, so it prints the
## build: memory manager, target, and whether it is release. That is
## Verification-Harness-Traps.md §12b applied to a footprint rather than to a
## timing — `--mm:orc` and `--mm:refc` do not merely differ in speed here,
## they differ in whether a cycle in the owner tree is ever reclaimed at all.
##
## Run:
##   nim c -r --mm:orc --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/manual/wasm_footprint_probe.nim
##   (and the wasm32/emcc form, which ci/test/wasm-footprint.sh spells out)

import std/[os, strutils]

import codetracer_embed

when defined(js):
  {.error: "wasm_footprint_probe measures a linear-memory heap; the JS " &
           "backend has neither a Nim allocator nor linear memory, so " &
           "`getOccupiedMem` is not the same quantity there. Its footprint " &
           "question is a different one and is not this file's.".}

# ---------------------------------------------------------------------------
# The instrument
# ---------------------------------------------------------------------------
#
# `getOccupiedMem()` is Nim's allocator's live-byte count: bytes handed out
# and not yet returned. It is what ORC's reclamation moves, and it is
# identical in meaning on both targets -- see the header for the two
# instruments that are not.
proc heapOccupied(): int =
  getOccupiedMem()

proc heapTotal(): int =
  ## Bytes the allocator has taken from the OS (or from linear memory). The
  ## gap against `heapOccupied` is fragmentation plus free-list slack, and it
  ## is printed because on a linear-memory target it is the part that is never
  ## handed back to the page.
  getTotalMem()

# Linear memory's total size, for the gap against the break. Emscripten
# exposes it as `emscripten_get_heap_size`; on native there is no such thing
# and the field is reported as `n/a` rather than as a zero, because a zero in
# a byte column is a value and `n/a` is an absence.
when defined(emscripten) or defined(wasm32):
  proc emscripten_get_heap_size(): csize_t {.importc,
    header: "<emscripten/heap.h>".}

  proc linearMemoryBytes(): int = int(emscripten_get_heap_size())
  const hasLinearMemory = true
else:
  proc linearMemoryBytes(): int = 0
  const hasLinearMemory = false

proc kib(bytes: int): string =
  formatFloat(bytes.float / 1024.0, ffDecimal, 1) & " KiB"

# ---------------------------------------------------------------------------
# The graph — the ViewModel core, and nothing else
# ---------------------------------------------------------------------------

proc buildOneSession(): DebuggerSession =
  ## One `DebuggerSession`, launched, with its seven panel ViewModels
  ## constructed and its store driven once so the reactive graph is not
  ## merely allocated but has actually PROPAGATED. A signal that never fires
  ## has not allocated its subscriber lists.
  let mock = newMockBackendService(strict = false, autoRespond = true)
  result = newDebuggerSession(mock.toBackendService())
  result.launch(localFolderTrace("/tmp/footprint-probe-trace"))
  let vms = result.session
  doAssert not vms.calltraceVM.isNil
  doAssert not vms.eventLogVM.isNil
  doAssert not vms.stateVM.isNil
  doAssert not vms.flowVM.isNil
  doAssert not vms.editorVM.isNil
  doAssert not vms.debugControlsVM.isNil
  doAssert not createRequestPanelVM(result.store).isNil
  # One real write, so every derived signal in the graph computes at least
  # once. Without it the measurement is of an allocated graph rather than of
  # a live one, and the two differ by every memo's cached value.
  result.store.updateDebuggerPosition(42'u64, "main.nim", 7, none(uint64))
  doAssert result.position.line == 7

when isMainModule:
  let sessionCount =
    if paramCount() >= 1: parseInt(paramStr(1)) else: 8

  # Warm the allocator before taking the baseline. The FIRST session pulls in
  # every lazily-initialised table and string the ViewModel layer has, and
  # charging that to "the cost of a session" would overstate the marginal
  # cost by the whole of the module's one-time setup. Built and dropped.
  block warmup:
    let warm = buildOneSession()
    warm.dispose()
  GC_fullCollect()

  let baseline = heapOccupied()
  let baselineTotal = heapTotal()
  let baselineLinear = linearMemoryBytes()

  var live: seq[DebuggerSession] = @[]
  for _ in 0 ..< sessionCount:
    live.add buildOneSession()
  let peak = heapOccupied()
  let peakTotal = heapTotal()
  let peakLinear = linearMemoryBytes()

  # TEARDOWN, AND WHAT IT DOES AND DOES NOT ESTABLISH.
  #
  # Both lines are here and only the SECOND is what the verdict rests on.
  # `dispose()` releases the reactive owner tree; `setLen(0)` drops the last
  # reference each session has. A falsification arm on 2026-09-15 removed the
  # `dispose()` call and the probe stayed GREEN — because ORC reclaims the
  # cyclic graph on the strength of the dropped reference alone, whatever the
  # owner tree was told.
  #
  # That arm SURVIVING is the useful outcome: the verdict below used to say
  # "the owner tree is reclaimed", and the measurement could not tell that
  # from "the allocator gave the bytes back". The claim now matches what is
  # actually measured — that ORC's CYCLE COLLECTOR reclaims this graph under
  # a linear-memory target once the last reference is gone, which is the half
  # of "`--mm:orc` under a linear memory target" that a successful build does
  # not establish. The arm that CAN falsify it is the one that keeps `live`
  # populated, and it is the one recorded against this probe.
  for s in live:
    s.dispose()
  live.setLen(0)
  # Explicitly, because a collection that merely HAPPENED to run is not a
  # steady state: without this the number below would depend on where ORC's
  # heuristics landed rather than on what the graph costs to hold.
  GC_fullCollect()
  let steady = heapOccupied()
  let steadyTotal = heapTotal()
  let steadyLinear = linearMemoryBytes()

  # The build, first, because every number below is a claim about it.
  var mm = "unknown"
  when defined(gcOrc): mm = "orc"
  elif defined(gcArc): mm = "arc"
  elif defined(gcRefc): mm = "refc"
  var target = "native"
  when defined(emscripten) or defined(wasm32): target = "wasm32-emscripten"

  echo "FOOTPRINT-BUILD\ttarget=", target,
       "\tmm=", mm,
       "\trelease=", (when defined(release): "true" else: "false"),
       "\tdanger=", (when defined(danger): "true" else: "false"),
       "\tsessions=", sessionCount
  echo "FOOTPRINT-BASELINE-OCCUPIED\t", baseline, "\t", kib(baseline)
  echo "FOOTPRINT-BASELINE-TOTAL\t", baselineTotal, "\t", kib(baselineTotal)
  echo "FOOTPRINT-PEAK-DELTA\t", peak - baseline, "\t", kib(peak - baseline)
  echo "FOOTPRINT-STEADY-DELTA\t", steady - baseline, "\t", kib(steady - baseline)
  echo "FOOTPRINT-PER-SESSION-PEAK\t", (peak - baseline) div sessionCount,
       "\t", kib((peak - baseline) div sessionCount)
  echo "FOOTPRINT-PEAK-TOTAL-DELTA\t", peakTotal - baselineTotal, "\t",
       kib(peakTotal - baselineTotal)
  echo "FOOTPRINT-STEADY-TOTAL-DELTA\t", steadyTotal - baselineTotal, "\t",
       kib(steadyTotal - baselineTotal)
  if hasLinearMemory:
    echo "FOOTPRINT-LINEAR-BASELINE\t", baselineLinear, "\t", kib(baselineLinear)
    echo "FOOTPRINT-LINEAR-PEAK\t", peakLinear, "\t", kib(peakLinear)
    echo "FOOTPRINT-LINEAR-STEADY\t", steadyLinear, "\t", kib(steadyLinear)
  else:
    echo "FOOTPRINT-LINEAR-BASELINE\tn/a\tno linear memory on this target"
    echo "FOOTPRINT-LINEAR-PEAK\tn/a\tno linear memory on this target"
    echo "FOOTPRINT-LINEAR-STEADY\tn/a\tno linear memory on this target"

  # THE ONE PROPERTY THIS PROBE ASSERTS, AND THE MEASUREMENT THAT NARROWED IT.
  #
  # It is a property of the memory manager rather than a number: once the last
  # reference to every session is gone and a full collection has run, the
  # graph must be RECLAIMED rather than merely reduced. On a graph that is
  # cyclic by construction -- an owner holding children holding their owner --
  # that is the statement that ORC's cycle collector runs under a
  # linear-memory target, which is the half of "`--mm:orc` under a linear
  # memory target" that a successful build does not establish.
  #
  # THE FIRST DRAFT ASSERTED `steady < peak` AND THAT ASSERTION COULD NOT
  # FAIL. Measured on 2026-09-15 by an arm that kept every session referenced
  # (`live.setLen(0)` deleted), native, --mm:orc, debug:
  #
  #     retained: peak 810,864  steady 775,408   (95.6% of peak)
  #     released: peak 810,864  steady      80   ( 0.01% of peak)
  #
  # The retained run STILL satisfied `steady < peak`, by 4%, because
  # `GC_fullCollect` frees the transient garbage the eight constructions left
  # behind whether or not the sessions themselves go. An inequality that both
  # mechanisms satisfy is an assertion with one live branch --
  # Verification-Harness-Traps.md §10 wearing a comparison operator.
  #
  # So the assertion is a FRACTION, and the threshold separates the two
  # mechanisms rather than tuning a bound: 0.01% on one side, 95.6% on the
  # other, and 25% is two orders of magnitude above the first and four times
  # below the second. That is the same form as the fake-timer probe's ratio
  # and for the same reason (§12a: an absolute bound on a single measurement
  # is a coin flip with one side hidden).
  const MaxSteadyFractionOfPeakPercent = 25

  let peakDelta = peak - baseline
  let steadyDelta = steady - baseline
  let steadyPercent =
    if peakDelta <= 0: 100
    else: int((steadyDelta * 100) div peakDelta)
  echo "FOOTPRINT-STEADY-PERCENT-OF-PEAK\t", steadyPercent, "\t", steadyPercent, " %"

  if peakDelta <= 0:
    # A peak of zero is a probe that built nothing, not a core that costs
    # nothing, and the fraction above would be meaningless. Two events, two
    # messages (§5a).
    echo "FOOTPRINT-VERDICT\tFAILED\tpeak delta is ", peakDelta,
         ": nothing was allocated, so there is no reclamation to measure"
    quit(1)

  if steadyPercent > MaxSteadyFractionOfPeakPercent:
    echo "FOOTPRINT-VERDICT\tFAILED\tsteady is ", steadyPercent,
         "% of peak (limit ", MaxSteadyFractionOfPeakPercent,
         "%): releasing every session reclaimed almost nothing"
    quit(1)
  echo "FOOTPRINT-VERDICT\tOK\tsteady is ", steadyPercent,
       "% of peak: ORC reclaims this cyclic graph on a released reference"
