## benchmarks/tui_benchmarks.nim — CTUI-14. §8's eight performance targets,
## measured, plus the two gaps CTUI-14 was asked to close or record.
##
## ## What this produces
##
## `bench-results/benchmark_results.json` in **github-action-benchmark** format
## (`metacraft-dev-guidelines/policies/continuous-benchmarking.md` §2) and
## `bench-results/report.html` (§3). `just bench` runs it; `just bench --quick`
## runs it with the sample counts reduced, which is what the policy's CI leg
## uses.
##
## ## THE HOST LOAD IS PART OF EVERY FIGURE
##
## Every entry carries the one-minute load average and the CPU count in its
## `extra` field, and the report prints them at the top. That is not decoration.
## This campaign has crossed gates under load and been unable to tell a
## regression from a busy machine afterwards, and §8's own risk note — "benchmark
## numbers vary with runner load and produce false alerts" — is about exactly
## this. A figure without its load is not a measurement, it is an anecdote.
##
## ## AND SO IS THE SAMPLE COUNT — PER ENTRY, NOT PER RUN
##
## Every entry also carries `samples=` and `shape=`: how many measurements the
## published number is made of, and what one of them is. They are per entry
## because the twelve entries are not made the same way — four are ONE
## observation of ONE spawned process, three loop on their own constants, one is
## a difference between three blocks, and only two loop `Bench.samples` times.
## An earlier version of this file appended the suite's loop count to all
## twelve, which told a reader of the committed artifact that a cold start had
## been averaged over two hundred spawns. See `hostNote`.
##
## ## HOW THE TWO KINDS OF METRIC ARE MEASURED, and why there are two
##
## **Four are properties of a PROCESS** and are measured by spawning the shipped
## binary in a real pty: cold start to first paint, time to a usable debugger,
## steady-state RSS, and idle CPU. None of them exists in-process — a resident
## set is a property of an address space and an idle CPU share is a property of
## a scheduler.
##
## **Four are properties of the RENDER PATH** and are measured in-process
## against a real trace: input latency (p50 and p99), resize reflow latency,
## single-step ANSI emission, and the strip-cache hit rate. Measuring those
## through a pty would put a scheduler, a terminal parser and a harness between
## the keystroke and the number, and §8's budgets are about the front-end.
##
## Both halves open a REAL RECORDING through a REAL `replay-server`. There is no
## mock anywhere in this file.
##
## ## GAP 1: TIME TO A USABLE DEBUGGER, which nothing measured before
##
## CTUI-11's cold-start gate measures "process exec to first `ScreenBuffer`
## commit" and meets it comfortably — but frame 0 is the SHELL, painted before
## `replay-server` is spawned, and a user cannot debug anything on it. The
## number a user actually feels is the one CTUI-11 recorded and did not gate:
## time to the first DEBUGGER frame. It is a separate entry here
## (`tui/time-to-debugger`) rather than a replacement, because the two answer
## different questions and the first one is what the published §8 row is about.
##
## ## GAP 2: THE FUZZY-PALETTE GATE, measured in RELEASE
##
## CTUI-10's palette gate is 8 ms and the debug build measured 3.88 ms idle and
## **7.13 ms under 2x oversubscription, with 7 of 9 runs over**. That is a flake
## waiting for a busy runner. CTUI-14's answer is to measure it in a RELEASE
## build — the configuration a user runs — rather than to widen the gate against
## a debug number, and to publish the release figure here so the gate has
## something to be set from. See `paletteMetric` for the arithmetic.

when defined(js):
  {.error: "the TUI benchmarks spawn processes and open a real trace.".}

import std/[algorithm, json, monotimes, os, osproc, posix, streams,
            strformat, strtabs, strutils, times]

import isonim_tui
import nim_pty

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/degradation
import ../app/views/command_palette
import ../host/terminal_driver
import ../host/tui_session
import ../tests/fixtures/fixture_provider

const
  Cols = 120
  Rows = 40
    ## §3.1's STANDARD profile. Every budget below is stated for a screen a
    ## user actually runs, and a smaller one would make every byte count and
    ## every layout smaller for free.
  FullSamples = 200
  QuickSamples = 40
    ## `--quick` is the policy's CI shape: the same measurements over fewer
    ## samples. It changes the CONFIDENCE and never the metric, which is why
    ## every entry's `extra` publishes its OWN sample count.
    ##
    ## THIS CONSTANT IS NOT EVERY METRIC'S SAMPLE COUNT, and writing it as
    ## though it were is the defect `hostNote` now exists to prevent. Four
    ## entries are one observation of one process; three have their own
    ## constants (`40` steps, `60` frames, `PaletteSamples`); one is three
    ## blocks of this many. Only input latency and resize reflow loop exactly
    ## `Bench.samples` times.
  IdleSampleSeconds = 5
    ## §8: "Idle CPU Utilization … 5-second sampling".
  PaletteSamples = 400

type
  ConditionGap = enum
    ## Whether the row's PUBLISHED CONDITION held while the number was taken.
    ##
    ## THIS IS A DIFFERENT QUESTION FROM `met`, AND THE TWO CAN DISAGREE. `met`
    ## compares a value with a target; this says whether the value was measured
    ## under the circumstances §8 states. A row can be comfortably under budget
    ## and still not have measured the thing its target is about, and until this
    ## field existed the committed artifact said `verdict=met` for exactly that
    ## case — twice. The gap was written into the `extra` PROSE, where a human
    ## reading the table would find it and a consumer parsing `verdict=` would
    ## not, which is the whole defect: the artifact is a machine-readable file
    ## and its machine-readable field was the one that lied.
    cgNone
      ## The number was taken under the condition the target is stated for.
    cgExternal
      ## EXTERNAL gap: no fixture can express the condition yet, so the number
      ## is the closest approach available. Nothing about the product is known
      ## to be wrong; the corpus cannot ask the question.
    cgInternal
      ## INTERNAL gap: the product does not do the thing the row measures, so
      ## the number is a property of some component in isolation rather than of
      ## the shipped program. This is a product gap wearing a benchmark's green
      ## and is the more serious of the two.

  Metric = object
    name: string
    unit: string
    value: float
    target: float
    smallerIsBetter: bool
    gated: bool
      ## Whether `target` is a GATE or a reference point.
      ##
      ## One entry is not a gate: the untuned emission figure is the control
      ## arm for the tuned one — it is what every release before CTUI-14 sent —
      ## and printing `NOT MET` beside it would report the measurement this
      ## milestone exists to improve on as a failure of this milestone.
    extra: string
    met: bool
    conditionGap: ConditionGap
      ## Set explicitly by every `record` call — see `ConditionGap`, and see
      ## `record`'s note on why this parameter has NO DEFAULT.

  Bench = ref object
    quick: bool
    samples: int
    metrics: seq[Metric]
    loadAverage: float
    cpuCount: int
    startedAt: string

# ---------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------

proc oneMinuteLoad(): float =
  ## The host's one-minute load average, from `/proc/loadavg`.
  ##
  ## READ ONCE PER MEASUREMENT rather than once per run: a benchmark suite that
  ## takes two minutes can start on an idle machine and finish on a busy one,
  ## and a single figure at the top would attribute the whole run to the
  ## quieter half of it.
  try:
    let fields = readFile("/proc/loadavg").splitWhitespace()
    if fields.len > 0:
      return parseFloat(fields[0])
  except CatchableError:
    discard
  -1.0

proc hostNote(bench: Bench; samples: int; shape: string;
              extra = ""): string =
  ## The `extra` field every entry carries: what the machine was doing while
  ## the number was taken, and **how many measurements the number is made of**.
  ##
  ## ## `samples=` IS PER ENTRY, and it used to be a lie
  ##
  ## The first version of this file appended `samples={bench.samples}` — the
  ## suite's loop count — to EVERY entry, including the four that are a single
  ## observation of a single process (cold start, time-to-debugger, RSS, idle
  ## CPU) and the three whose loop count is their own constant rather than the
  ## suite's (emission 40 steps, strip cache 60 frames, palette 400 iterations).
  ## Seven of the twelve entries therefore claimed a provenance they did not
  ## have, and a reader of the committed artifact would have concluded that a
  ## cold start had been averaged over two hundred spawns.
  ##
  ## `samples` is now what the entry's own measurement actually counted, and
  ## `shape=` says what one sample IS — a spawn, an iteration, a step, a frame —
  ## because "1" alone does not distinguish "measured once" from "a ratio over
  ## one accumulated window".
  result = &"load1={oneMinuteLoad():.2f} cpus={bench.cpuCount} " &
           &"samples={samples} shape=\"{shape}\""
  if extra.len > 0:
    result.add " " & extra

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

proc record(bench: Bench; name, unit: string; value, target: float;
            samples: int; shape: string; conditionGap: ConditionGap;
            smallerIsBetter = true; gated = true; extra = "") =
  ## Record one entry. `samples`, `shape` and `conditionGap` are NOT DEFAULTED,
  ## so a metric added later cannot inherit somebody else's provenance by
  ## omission — which is exactly how `samples=200` came to be on a one-spawn
  ## measurement.
  ##
  ## `conditionGap` JOINS THAT GROUP RATHER THAN DEFAULTING TO `cgNone`, and the
  ## reason is the defect it fixes. `cgNone` is not a neutral value: it is the
  ## POSITIVE claim that the number was taken under the condition its target is
  ## published for. A default would hand that claim to every metric anyone adds
  ## without thinking about it, which is precisely how two rows here came to
  ## report `verdict=met` for a condition neither of them satisfied. The
  ## question has to be asked at the call site or it does not get asked.
  let met = if smallerIsBetter: value <= target else: value >= target
  bench.metrics.add Metric(
    name: name, unit: unit, value: value, target: target,
    smallerIsBetter: smallerIsBetter, gated: gated,
    extra: hostNote(bench, samples, shape, extra), met: met,
    conditionGap: conditionGap)
  let verdict =
    if not gated: "reported"
    elif not met: "**NOT MET**"
    elif conditionGap == cgNone: "MET"
    # The console arm says it too, because a run watched live is where somebody
    # would otherwise carry away "twelve green" as the summary.
    elif conditionGap == cgExternal: "MET (CONDITION NOT — external)"
    else: "MET (CONDITION NOT — internal)"
  let comparison = if smallerIsBetter: "<=" else: ">="
  stderr.writeLine(&"  {name:<44} {value:>10.3f} {unit:<8} " &
                   &"target {comparison} {target:<10.3f} {verdict}")
  stderr.writeLine(&"      {bench.metrics[^1].extra}")

# ---------------------------------------------------------------------------
# Percentiles
# ---------------------------------------------------------------------------

proc percentile(samples: seq[float]; p: float): float =
  ## The `p`-th percentile by sort-and-rank, which is what
  ## `isonim/bench/design_review_bench.nim` uses and therefore what the other
  ## benchmark in this workspace means by the word.
  if samples.len == 0:
    return 0.0
  var sorted = samples
  sorted.sort()
  let rank = int(p * float(sorted.len - 1) + 0.5)
  sorted[clamp(rank, 0, sorted.high)]

# ---------------------------------------------------------------------------
# The in-process half: a real session, no terminal
# ---------------------------------------------------------------------------

proc openBenchSession(fixture: string): (TuiSession, TuiRuntime) =
  ## A real recording, opened through a real `replay-server`, with no terminal
  ## anywhere.
  ##
  ## THE SAME CALL `main.nim` MAKES, minus the driver — so what is measured
  ## below is the front-end's own work rather than a benchmark's idea of it.
  let resolved = resolveFixture(fixture)
  if resolved.outcome != foRecorded:
    raise newException(IOError,
      "the `" & fixture & "` fixture is unavailable: " & resolved.detail &
      " — `just test-tui` records and caches it, or set $CT_BIN")
  let caps = TerminalCapabilities(
    colors: cdAnsi256, borders: bmUnicode, mouse: true,
    synchronizedOutput: false, theme: utDark)
  let app = newTuiApp()
  let session = openTuiSession(resolved.tracePath,
                               viewportHeight = max(1, Rows - 6))
  let rt = newTuiRuntime(app, caps, Cols, Rows)
  session.header(rt)
  session.setViewportHeight(rt.sourcePaneRows())
  session.learnExtent()
  session.refresh(rt)
  (session, rt)

proc renderOnce(rt: TuiRuntime; caps: TerminalCapabilities): ScreenBuffer =
  ## One frame, exactly as `host/terminal_driver.paint` builds it.
  let screen = rt.shellScreenOf()
  composite(degradeRows(screen.styledRows, caps), Cols, Rows)

proc inputLatencyMetrics(bench: Bench) =
  ## §8 rows 2 and 3: "keypress to screen buffer update committed".
  ##
  ## THE KEY IS A LOCAL ONE. `Tab`, `j` and `k` move focus and the inspection
  ## cursor; none of them sends a navigation command, so what is timed is the
  ## front-end's own path — resolve, dispatch, rebuild the pane models,
  ## composite — which is what a 60 Hz budget is a budget for. A step key would
  ## put a `replay-server` round trip inside the number and measure the engine.
  ##
  ## p50 is on `calc`; p99 is on `wide_state`, which is CTUI-1's WIDE fixture
  ## and therefore §8's "complex step with large variable tree expansion".
  for (fixture, label) in [("calc", "p50"), ("wide_state", "p99")]:
    let (session, rt) = openBenchSession(fixture)
    defer: session.close()
    let caps = TerminalCapabilities(
      colors: cdAnsi256, borders: bmUnicode, mouse: true,
      synchronizedOutput: false, theme: utDark)
    # EXPAND THE VARIABLE TREE for the p99 arm, which is what makes it the
    # complex case rather than the same case on a different recording.
    if label == "p99":
      for _ in 0 ..< 6:
        discard rt.handleToken("\t", 0)
      for _ in 0 ..< 12:
        discard rt.handleToken("j", 0)
        discard rt.handleToken("\r", 0)
    # WARM: the first frame builds every lazily-initialised table in the
    # renderer, and timing it would measure module initialisation.
    discard renderOnce(rt, caps)
    var samples: seq[float] = @[]
    let keys = ["j", "k", "\t"]
    for i in 0 ..< bench.samples:
      let key = keys[i mod keys.len]
      let started = getMonoTime()
      discard rt.handleToken(key, int64(i))
      discard renderOnce(rt, caps)
      samples.add float((getMonoTime() - started).inNanoseconds) / 1_000_000.0
    if label == "p50":
      bench.record("tui/input-latency-p50", "ms", percentile(samples, 0.50),
                   16.0, samples = samples.len,
                   conditionGap = cgNone,
                   shape = "one key dispatched and one frame composited, " &
                           "in-process; the value is the p50 of them",
                   extra = "fixture=" & fixture & " key=j/k/Tab")
    else:
      bench.record("tui/input-latency-p99", "ms", percentile(samples, 0.99),
                   33.0, samples = samples.len,
                   conditionGap = cgNone,
                   shape = "one key dispatched and one frame composited, " &
                           "in-process; the value is the p99 of them",
                   extra = "fixture=" & fixture & " variables-tree-expanded")

proc coalescingMetric(bench: Bench) =
  ## THE CONTRACT, MEASURED IN THE SAME RUN AS THE THING IT COULD HAVE COST.
  ##
  ## CTUI-14: *"coalescing must not increase p50 input latency; both are
  ## measured in the same run so a trade is visible rather than argued."*
  ##
  ## ## THE THRESHOLD IS MEASURED, NOT CHOSEN
  ##
  ## Three blocks run, not two: the uncoalesced arm runs TWICE and the
  ## coalesced arm once. `noise` is how much the SAME measurement moves between
  ## its own two runs on this host at this load, and it is the target the
  ## coalescing delta is gated against. A fixed `<= 0 ms` gate is what the first
  ## version of this file used, and it failed at +0.99 ms on a 10 ms p50 under
  ## load 50 — which said nothing about coalescing and everything about a
  ## 24-core machine with fifty runnable threads on it.
  ##
  ## The blocks are CONTIGUOUS rather than interleaved for the same reason:
  ## alternating two arms inside one loop gives the second one a different cache
  ## and a different branch history on every iteration.
  let (session, rt) = openBenchSession("calc")
  defer: session.close()
  let caps = TerminalCapabilities(
    colors: cdAnsi256, borders: bmUnicode, mouse: true,
    synchronizedOutput: false, theme: utDark)
  let emitter = newFrameEmitter(caps)
  let keys = ["j", "k", "\t"]
  discard emitter.emit(renderOnce(rt, caps))

  proc block1(coalesce: bool): seq[float] =
    var coalescer = initWriteCoalescer()
    result = @[]
    for i in 0 ..< bench.samples:
      let key = keys[i mod keys.len]
      let started = getMonoTime()
      discard rt.handleToken(key, int64(i))
      if coalesce:
        # THE LONE-KEYSTROKE CASE, which is the one the contract is about:
        # nothing is pending behind it, so `hold` must answer false and the
        # frame must go out on this turn.
        if not coalescer.hold(morePending = false):
          discard emitter.emit(renderOnce(rt, caps))
      else:
        discard emitter.emit(renderOnce(rt, caps))
      result.add float((getMonoTime() - started).inNanoseconds) / 1_000_000.0

  let firstPlain = percentile(block1(false), 0.50)
  let secondPlain = percentile(block1(false), 0.50)
  let coalesced = percentile(block1(true), 0.50)
  let noise = abs(secondPlain - firstPlain)
  let delta = coalesced - firstPlain
  bench.record("tui/coalescing-p50-delta", "ms", delta, max(noise, 0.001),
               samples = 3 * bench.samples,
               conditionGap = cgNone,
               shape = &"THREE contiguous blocks of {bench.samples} " &
                       "iterations — uncoalesced, uncoalesced again, " &
                       "coalesced; the value is a difference between two of " &
                       "the three p50s and the target is the spread of the " &
                       "other two",
               extra = &"uncoalesced-p50={firstPlain:.3f}ms " &
                       &"uncoalesced-p50-again={secondPlain:.3f}ms " &
                       &"coalesced-p50={coalesced:.3f}ms " &
                       &"run-to-run-noise={noise:.3f}ms — the target IS the " &
                       "noise: the same measurement's own spread between two " &
                       "consecutive blocks on this host at this load")

proc emissionMetrics(bench: Bench) =
  ## §8 row 5: "ANSI byte volume emitted across a single line step".
  ##
  ## MEASURED ON A REAL STEP, through the emitter the driver uses, and reported
  ## BOTH WAYS — with dirty-region diffing and without — because the untuned
  ## number is what makes the tuned one mean something. The untuned figure is
  ## the whole frame and is what every release before CTUI-14 sent.
  let (session, rt) = openBenchSession("calc")
  defer: session.close()
  let caps = TerminalCapabilities(
    colors: cdAnsi256, borders: bmUnicode, mouse: true,
    synchronizedOutput: false, theme: utDark)
  let tuned = newFrameEmitter(caps, diffing = true)
  let untuned = newFrameEmitter(caps, diffing = false)
  discard tuned.emit(renderOnce(rt, caps))
  discard untuned.emit(renderOnce(rt, caps))
  var tunedBytes: seq[float] = @[]
  var untunedBytes: seq[float] = @[]
  let steps = min(40, bench.samples)
  var unchanged = 0
  for _ in 0 ..< steps:
    let outcome = rt.handleToken("n", 0)
    if outcome.awaitsMove:
      session.pumpMove()
      session.refresh(rt)
    let buf = renderOnce(rt, caps)
    let tunedFrame = tuned.emit(buf).len
    let untunedFrame = untuned.emit(buf).len
    # STEPS THAT CHANGED NOTHING ARE NOT SINGLE-LINE STEPS, and counting them
    # would make the median a measurement of the cursor park. Measured, because
    # the first version of this file did exactly that and reported a median of
    # NINE BYTES: `calc` is short, the last steps of a forty-step sweep run off
    # the end of the recording, and `n` at the end of a trace repaints an
    # identical screen. They are counted and reported instead.
    if tunedFrame <= cursorTo(Rows - 1, Cols - 1).len:
      inc unchanged
      continue
    tunedBytes.add float(tunedFrame)
    untunedBytes.add float(untunedFrame)
  bench.record("tui/single-step-ansi-bytes", "bytes",
               percentile(tunedBytes, 0.50), 250.0,
               samples = tunedBytes.len,
               conditionGap = cgNone,
               shape = &"one `n` step through a real recording, its frame " &
                       &"emitted and counted; {steps} steps were taken and " &
                       "the ones that changed nothing on the screen are NOT " &
                       "samples of a single line step",
               extra = &"steps={steps} that-changed-the-screen=" &
                 &"{tunedBytes.len} unchanged={unchanged} " &
                 &"tuned-min={percentile(tunedBytes, 0.0):.0f} " &
                 &"tuned-p25={percentile(tunedBytes, 0.25):.0f} " &
                 &"tuned-p99={percentile(tunedBytes, 0.99):.0f} " &
                 &"untuned-median={percentile(untunedBytes, 0.50):.0f} — the " &
                 "sweep starts at the entry point, where most steps ENTER or " &
                 "LEAVE a function and scroll the source pane; the minimum " &
                 "is what a step within one function costs")
  bench.record("tui/single-step-ansi-bytes-untuned", "bytes",
               percentile(untunedBytes, 0.50), 250.0, gated = false,
               samples = untunedBytes.len,
               conditionGap = cgNone,
               shape = "the SAME steps as the tuned arm, emitted a second " &
                       "time through a non-diffing emitter that saw the same " &
                       "buffers",
               extra = "diffing=off — the pre-CTUI-14 emitter. THE CONTROL " &
                       "ARM, not a gate: it is what every release before " &
                       "CTUI-14 sent, and it is here so the tuned figure " &
                       "beside it is a difference rather than a claim")

proc reflowMetric(bench: Bench) =
  ## §8 row 7: "SIGWINCH received to complete reflow and paint".
  ##
  ## The SIGNAL itself is asserted at Tier 2 (`app/tests/test_resize_reflow.nim`
  ## explains why it cannot be); what is measured here is the work the signal
  ## causes, which is what the 20 ms budget is about: re-layout and repaint.
  let (session, rt) = openBenchSession("calc")
  defer: session.close()
  let caps = TerminalCapabilities(
    colors: cdAnsi256, borders: bmUnicode, mouse: true,
    synchronizedOutput: false, theme: utDark)
  discard renderOnce(rt, caps)
  var samples: seq[float] = @[]
  # BETWEEN TWO PROFILES, not two widths of one. 120x40 is `lpStandard` and
  # 100x30 is `lpCompact` (`app/layout/profile.selectProfile`), so every reflow
  # measured here rebuilds the pane tree rather than stretching it.
  let sizes = [(Cols, Rows), (100, 30)]
  for i in 0 ..< bench.samples:
    let (w, h) = sizes[i mod sizes.len]
    let started = getMonoTime()
    rt.resize(w, h)
    session.setViewportHeight(rt.sourcePaneRows())
    let screen = rt.shellScreenOf()
    discard composite(degradeRows(screen.styledRows, caps), w, h)
    samples.add float((getMonoTime() - started).inNanoseconds) / 1_000_000.0
  rt.resize(Cols, Rows)
  bench.record("tui/resize-reflow-p99", "ms", percentile(samples, 0.99), 20.0,
               samples = samples.len,
               conditionGap = cgNone,
               shape = "one resize, re-layout and composite; the value is " &
                       "the p99 of them",
               extra = "between lpStandard 120x40 and lpCompact 100x30")

proc stripCacheMetric(bench: Bench) =
  ## §8 row 8: "Strip Cache Hit Rate … steady-state stepping through unchanging
  ## source code".
  ##
  ## ## A FINDING, AND IT IS NOT A GOOD ONE
  ##
  ## The metric is a property of a compositor that SURVIVES BETWEEN FRAMES, and
  ## `host/ssh_tuning`/`terminal_driver.composite` builds a fresh
  ## `TerminalRenderer`, `HeadlessDriver` and `Compositor` for every frame —
  ## `testing/test_app_runtime.nim` records why (the driver's buffer is the
  ## diff base, and this front-end's frame barrier needs a whole frame). So
  ## **the shipped binary's strip cache hit rate is 0% by construction**, and a
  ## benchmark that measured the shipped path would publish a number that says
  ## nothing about the compositor.
  ##
  ## What is measured instead is the compositor's own behaviour over a
  ## persistent instance, which is what §8's row is about — and the finding
  ## above is recorded in the entry's `extra` rather than hidden, because
  ## re-using the compositor is a real optimisation this milestone did not
  ## take: CTUI-14 diffs at the BYTE level (`ssh_tuning.dirtyRuns`) and gets
  ## the same saving on the wire, and moving the diff base would have moved
  ## every Tier-2 frame barrier in the tree.
  let (session, rt) = openBenchSession("calc")
  defer: session.close()
  let caps = TerminalCapabilities(
    colors: cdAnsi256, borders: bmUnicode, mouse: true,
    synchronizedOutput: false, theme: utDark)
  let renderer = TerminalRenderer()
  let driver = newHeadlessDriver(Cols, Rows)
  let comp = newCompositor(Cols, Rows)
  let frames = min(60, bench.samples)
  for i in 0 ..< frames:
    # `resetNodeIds()` PER FRAME, which is what `terminal_driver.composite`
    # already does — and it is load-bearing here rather than tidiness. The
    # strip cache is keyed on `LayoutEntry.nodeId` (`compositor.stripForEntry`),
    # and a tree rebuilt with fresh ids every frame therefore misses on every
    # row however unchanged its content is. Measured: without this the hit rate
    # over forty frames is 0 out of 20,320.
    resetNodeIds()
    # STEPPING THROUGH UNCHANGING SOURCE, which is §8's stated condition: `j`
    # and `k` move the inspection cursor without moving the execution pointer,
    # so the source pane's rows are the ones that should be cached.
    discard rt.handleToken(if i mod 2 == 0: "j" else: "k", int64(i))
    let screen = rt.shellScreenOf()
    comp.paint(styledRowsTree(renderer,
                              degradeRows(screen.styledRows, caps)), driver)
  let stats = comp.stats()
  let total = stats.hits + stats.misses
  let rate = if total == 0: 0.0 else: 100.0 * float(stats.hits) / float(total)
  bench.record("tui/strip-cache-hit-rate", "%", rate, 92.0,
               samples = frames,
               conditionGap = cgInternal,
               shape = &"ONE ratio accumulated over {frames} frames on one " &
                       "persistent compositor — a single hits/(hits+misses) " &
                       "over every strip lookup those frames made, not a " &
                       "per-frame figure with a distribution",
               smallerIsBetter = false,
               extra = &"frames={frames} hits={stats.hits} " &
                 &"misses={stats.misses} — measured on a PERSISTENT " &
                 "compositor; the shipped driver builds a fresh one per " &
                 "frame and diffs on the wire instead (ssh_tuning.dirtyRuns). " &
                 "THE CONDITION IS NOT MET EVEN THOUGH THE NUMBER IS: §8 " &
                 "states the condition as steady-state stepping in the " &
                 "product, and terminal_driver.composite builds a fresh " &
                 "Compositor per frame, so THE SHIPPED BINARY'S RATE IS 0% " &
                 "BY CONSTRUCTION — this figure is a property of the " &
                 "compositor and not of the program that ships")

proc paletteMetric(bench: Bench) =
  ## GAP 2. CTUI-10's fuzzy command palette, against its published 8 ms gate.
  ##
  ## The gate was measured on a DEBUG build: 3.88 ms idle, 7.13 ms under 2x
  ## oversubscription, 7 of 9 individual runs over 8 ms. That is a flake, and
  ## the two ways out are to widen the gate against a debug number or to
  ## measure the configuration a user runs. **This measures release.**
  ##
  ## `just bench` builds this file with `-d:release`, so the figure below is
  ## the release one wherever `defined(release)` is true — and the entry says
  ## which build it came from, because an 8 ms gate met by a debug build and an
  ## 8 ms gate met by a release build are different claims.
  ## The index is the shape CTUI-10's gate uses: `GateSymbols` entries whose
  ## stems are real identifiers, cycled with an ordinal suffix, because the
  ## matcher's word-boundary bonus keys on structure a run of random strings
  ## does not have.
  const GateSymbols = 2000
  const Query = "shld"
  var index: seq[PaletteEntry] = @[]
  let stems = ["remaining_shield", "apply_damage", "shield_state", "main",
               "compute_hull", "space_ship", "fire_lasers", "tick_world"]
  var i = 0
  while index.len < GateSymbols:
    index.add PaletteEntry(kind: pekFunction, text: stems[i mod stems.len] &
                             "_" & $i,
                           help: "synthetic gate entry " & $i,
                           command: ":goto " & $i)
    inc i
  var model = initPaletteModel(index)
  discard model.open()
  var samples: seq[float] = @[]
  var hits = 0
  let iterations = if bench.quick: PaletteSamples div 4 else: PaletteSamples
  for _ in 0 ..< iterations:
    # EVERY RUN IS COLD. `rankWith` calls `newMatcher(query)`, which builds a
    # fresh `FuzzySearch` with an empty cache, so repeating one query measures
    # the search rather than a lookup — the same reasoning CTUI-10's gate
    # records, and the reason the query is not varied (that would compare
    # different amounts of work and call the cheapest one the answer).
    let started = getMonoTime()
    hits = model.setQuery(Query)
    samples.add float((getMonoTime() - started).inNanoseconds) / 1_000_000.0
    model.query = ""
  let build = if defined(release): "release" else: "debug"
  bench.record("tui/command-palette-p99", "ms", percentile(samples, 0.99), 8.0,
               samples = samples.len,
               conditionGap = cgNone,
               shape = "one cold fuzzy search over the whole index; the " &
                       "value is the p99 of them",
               extra = &"build={build} symbols={GateSymbols} query={Query} " &
                 &"hits={hits} iterations={iterations} " &
                 &"p50={percentile(samples, 0.50):.3f}ms " &
                 &"max={percentile(samples, 1.0):.3f}ms — CTUI-10 measured " &
                 "3.88ms idle and 7.13ms under 2x oversubscription on a " &
                 "DEBUG build, with 7 of 9 runs over 8ms; GAP 2's answer is " &
                 "to state the gate against this release figure")

# ---------------------------------------------------------------------------
# The process half: the shipped binary in a real pty
# ---------------------------------------------------------------------------

proc rssKilobytes(pid: int): int =
  ## `VmRSS` for a live process, in kB.
  try:
    for line in readFile("/proc/" & $pid & "/status").splitLines():
      if line.startsWith("VmRSS:"):
        let fields = line.splitWhitespace()
        if fields.len >= 2:
          return parseInt(fields[1])
  except CatchableError:
    discard
  -1

proc cpuJiffies(pid: int): int =
  ## `utime + stime` for a live process, in clock ticks.
  try:
    let stat = readFile("/proc/" & $pid & "/stat")
    # The comm field may contain spaces and parentheses; everything after the
    # LAST `)` is positionally stable, which is why the split starts there.
    let after = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace()
    # Fields 11 and 12 of the remainder are utime and stime (state is 0).
    if after.len > 12:
      return parseInt(after[11]) + parseInt(after[12])
  except CatchableError:
    discard
  -1

proc medianOf(samples: seq[float]): float =
  percentile(samples, 0.50)

proc spawnMillis(exe: string; args: seq[string];
                 env: seq[(string, string)]): float =
  ## Wall time from `startProcess` to `waitForExit`, in milliseconds.
  ##
  ## Both arms of the handoff measurement below use this ONE function, so the
  ## spawn overhead the harness itself contributes is the same constant in both
  ## and cancels in the difference.
  var table = newStringTable(modeCaseSensitive)
  for (k, v) in env:
    table[k] = v
  let started = getMonoTime()
  let p = startProcess(exe, args = args, env = table,
                       options = {poStdErrToStdOut})
  discard p.outputStream.readAll()
  discard p.waitForExit()
  p.close()
  float((getMonoTime() - started).inNanoseconds) / 1e6

proc uiHandoffMetric(bench: Bench) =
  ## PLAT-1's VERIFICATION GATE, as a benchmark entry rather than a review note.
  ##
  ## `codetracer-specs/CLI/ct/ui-selection.md` §3.1: "the added cost of reaching
  ## the TUI through `ct replay --ui=tui` rather than directly must stay under
  ## **10 ms**, measured and benchmarked alongside CTUI-14's
  ## `tui/cold-start-first-paint`". The milestone restates it: "measured with
  ## host load stated and benchmarked beside `tui/cold-start-first-paint`".
  ##
  ## ## WHAT "THE ADDED COST" IS, EXACTLY
  ##
  ## Reaching the TUI directly is `launcher -> codetracer-tui`. Reaching it
  ## through the flag is `launcher -> ct -> codetracer-tui`. The launcher's own
  ## exec is in BOTH, so it cancels; what `--ui` adds is one whole `ct` process
  ## — its dynamic loading, its Nim module initialisation, its prologue, and the
  ## second `execv`. That is what is measured here: the same front-end binary
  ## doing the same work in both arms, once reached directly and once reached
  ## through `ct`.
  ##
  ## ## WHY `--version` AND NOT A RECORDING
  ##
  ## Verification-Harness-Traps: an inequality between two independently noisy
  ## measurements, asserted against an exact constant, is a coin flip. A full
  ## session takes seconds and its variance is seconds; a difference of two such
  ## numbers cannot resolve 10 ms and would report whichever way the page cache
  ## fell. `--version` makes the SHARED part of both arms small and nearly
  ## constant, so the difference is dominated by the thing under measurement.
  ## The handoff work does not depend on what follows it — the same resolution,
  ## the same component lookup, the same `execv` — so this measures the whole of
  ## it and nothing else.
  ##
  ## `--version` reaches the front-end as a passed-through option: `ct replay
  ## --ui=tui --version` resolves the flag, hands the remaining arguments over,
  ## and `codetracer-tui --version` prints and exits. Asserted rather than
  ## assumed — the run is abandoned with a diagnosis if either arm's output is
  ## not the front-end's version line, because two arms that both failed
  ## quickly would produce a very good number.
  let root = repoRoot()
  let tuiBinary = root / "build" / "bin" / "codetracer-tui"
  let ctBinary = root / "src" / "build-debug" / "bin" / "ct"
  if not fileExists(tuiBinary):
    raise newException(IOError,
      "missing " & tuiBinary & " — run `just build-tui`")
  if not fileExists(ctBinary):
    raise newException(IOError,
      "missing " & ctBinary & " — run `just build-once`; PLAT-1's gate is " &
      "about the cost of going THROUGH this binary, so it cannot be measured " &
      "without it")

  var env: seq[(string, string)] = @[]
  for k, v in envPairs():
    if k == "CODETRACER_UI":
      continue
    env.add (k, v)
  # The handoff must resolve to the SAME binary the direct arm runs, or the
  # difference would include a component-directory scan against a different
  # answer.
  env.add ("CODETRACER_TUI_BIN", tuiBinary)

  # Both arms are checked ONCE for what they produce, before anything is timed.
  let expected = "codetracer-tui"
  block verify:
    var table = newStringTable(modeCaseSensitive)
    for (k, v) in env:
      table[k] = v
    for (exe, args) in [(tuiBinary, @["--version"]),
                        (ctBinary, @["replay", "--ui=tui", "--version"])]:
      let p = startProcess(exe, args = args, env = table,
                           options = {poStdErrToStdOut})
      let output = p.outputStream.readAll()
      let rc = p.waitForExit()
      p.close()
      if rc != 0 or not output.contains(expected):
        raise newException(IOError,
          "the `--ui` handoff benchmark cannot be measured: `" & exe & " " &
          args.join(" ") & "` exited " & $rc & " with output '" &
          output.strip() & "', which does not name " & expected)

  # A WARM-UP THAT IS DISCARDED, in both arms, so the first-touch page faults
  # of a 13 MB and a 15 MB binary are not attributed to the handoff.
  for _ in 0 ..< 5:
    discard spawnMillis(tuiBinary, @["--version"], env)
    discard spawnMillis(ctBinary, @["replay", "--ui=tui", "--version"], env)

  let samples = if bench.quick: 40 else: 200
  var direct: seq[float] = @[]
  var throughFlag: seq[float] = @[]
  # INTERLEAVED, not one block after the other: a machine that gets busier
  # halfway through a run would otherwise put all of the extra load into
  # whichever arm ran second, and the difference would be the load rather than
  # the handoff.
  for _ in 0 ..< samples:
    direct.add spawnMillis(tuiBinary, @["--version"], env)
    throughFlag.add spawnMillis(ctBinary,
                                @["replay", "--ui=tui", "--version"], env)

  let directMedian = medianOf(direct)
  let flagMedian = medianOf(throughFlag)
  let overhead = flagMedian - directMedian
  # THE LENGTH OF `PATH` IS PART OF THIS FIGURE, and it is published with it.
  #
  # Measured 2026-09-07: the overhead is 3.5 ms on a two-entry `PATH` and
  # 18.0 ms on the 193-entry `PATH` a nix dev shell provides — the SAME two
  # binaries, the same host, minutes apart. `strace -c` on `ct` shows 5,440
  # `newfstatat` calls of which 5,396 fail, and they come from
  # `src/common/paths.nim`, which resolves ~28 recorder and tool binaries with
  # `findTool` (i.e. `findExe`) in a module-level `let` block. That work is
  # done during Nim's module initialisation, BEFORE `main` and therefore before
  # the `--ui` prologue can decide anything, and every `ct` invocation pays it.
  #
  # So this number is not a property of `--ui`'s implementation: the prologue is
  # the first statement of `codetracer.nim` and reads no file on this path. It
  # is a property of what `ct` costs to start, which is what ui-selection.md
  # §3.1 warned about in the same paragraph as the gate ("loading a 25 MB binary
  # to reach it is not [acceptable]"). Making the gate hold on a long `PATH`
  # means making those lookups lazy, which is a change to `paths.nim` rather
  # than to the selector.
  let pathEntries = getEnv("PATH", "").split(PathSep).len
  bench.record("tui/ui-flag-handoff-overhead", "ms", overhead, 10.0,
               samples = samples,
               conditionGap = cgNone,
               shape = "the DIFFERENCE of two medians over " & $samples &
                       " interleaved spawn pairs — one sample is one" &
                       " `codetracer-tui --version` and one" &
                       " `ct replay --ui=tui --version`, run back to back",
               extra = "PLAT-1's gate (ui-selection.md §3.1). direct=" &
                       (&"{directMedian:.3f}") & "ms through-flag=" &
                       (&"{flagMedian:.3f}") & "ms path-entries=" &
                       $pathEntries &
                       "; the launcher's own exec is in neither arm because" &
                       " it is in BOTH of the invocations being compared and" &
                       " cancels. THE FIGURE SCALES WITH len(PATH): ~28" &
                       " module-level findExe lookups in src/common/paths.nim" &
                       " run before main on every ct start (3.5ms at 2 PATH" &
                       " entries, 18.0ms at 193, measured 2026-09-07)")
  # THE INPUTS ARE PUBLISHED AS WELL AS THE DIFFERENCE, and not gated: a
  # difference alone cannot be sanity-checked afterwards, and these two are what
  # a reader needs to tell "the handoff got cheaper" from "the front-end got
  # slower to start".
  bench.record("tui/ui-flag-direct-spawn", "ms", directMedian, 0.0,
               samples = samples, gated = false, conditionGap = cgNone,
               shape = "median of " & $samples &
                       " `codetracer-tui --version` spawns",
               extra = "the control arm of tui/ui-flag-handoff-overhead")
  bench.record("tui/ui-flag-handoff-spawn", "ms", flagMedian, 0.0,
               samples = samples, gated = false, conditionGap = cgNone,
               shape = "median of " & $samples &
                       " `ct replay --ui=tui --version` spawns",
               extra = "the measured arm of tui/ui-flag-handoff-overhead")

proc processMetrics(bench: Bench) =
  ## §8 rows 1, 4 and 6, plus GAP 1 — all four properties of a running process.
  ##
  ## ONE SPAWN FOR ALL OF THEM, because they are stages of one session: the
  ## first frame, the first debugger frame, the resident set once it has
  ## settled, and the CPU it uses when nothing is happening. Four spawns would
  ## have measured four cold caches.
  let root = repoRoot()
  let binary = root / "build" / "bin" / "codetracer-tui"
  if not fileExists(binary):
    raise newException(IOError,
      "missing " & binary & " — run `just build-tui`")
  let resolved = resolveFixture("calc")
  if resolved.outcome != foRecorded:
    raise newException(IOError,
      "the `calc` fixture is unavailable: " & resolved.detail)

  # A REAL PTY, through `nim-pty` — the same library `TermAssert` spawns with,
  # so what is measured is the process a Tier-2 case would have measured. The
  # HARNESS is deliberately not used: `TermAssert` parses every byte with
  # libvterm, and a benchmark that timed a terminal emulator as well as the
  # binary would be measuring the wrong program.
  var env: seq[(string, string)] = @[]
  for k, v in envPairs():
    if k in ["COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE"]:
      continue
    env.add (k, v)
  env.add ("TERM", "xterm-256color")
  env.add ("LANG", "en_US.UTF-8")

  let started = getMonoTime()
  var sess = spawnPty(binary, [resolved.tracePath], env,
                      SpawnOptions(cols: Cols, rows: Rows))
  let childPid = int(sess.pid)

  var seen = ""
  var firstFrameMs = -1.0
  var debuggerMs = -1.0

  # STAGE 1 and GAP 1, and the two markers are the ones the Tier-2 suites use
  # for the same reason: `main.nim` paints TWICE on startup and the pane titles
  # are on BOTH frames.
  #
  # Measured, because the first version of this file got it wrong and the
  # number said so: keying frame 1 on `VARIABLES`/`CALL STACK`/`TIMELINE`
  # reported time-to-debugger as 5.276 ms against a first paint of 5.274 ms —
  # the two markers were the same marker, and a gap CTUI-11 measured at ~125 ms
  # had apparently vanished. Frame 0 is the SHELL: it has every pane title and
  # no pane CONTENT.
  #
  # So frame 0 is `opening ` on the status row, and frame 1 is the status row
  # having been REPLACED by the engine's position — `<path>/main.py:<line>`.
  # `.py:` is specific to the `calc` fixture, which is a Python recording; it
  # is spelled here rather than derived because deriving it would mean opening
  # the trace, which is the thing being timed.
  let deadline = getMonoTime() + initDuration(seconds = 300)
  while getMonoTime() < deadline:
    let chunk = sess.readBytes(65536, initDuration(milliseconds = 50))
    for b in chunk:
      seen.add char(b)
    if firstFrameMs < 0 and seen.contains("opening "):
      firstFrameMs = float((getMonoTime() - started).inNanoseconds) / 1e6
    if debuggerMs < 0 and firstFrameMs >= 0 and seen.contains(".py:"):
      debuggerMs = float((getMonoTime() - started).inNanoseconds) / 1e6
      break
    if not sess.isAlive:
      break
  bench.record("tui/cold-start-first-paint", "ms", firstFrameMs, 50.0,
               samples = 1,
               conditionGap = cgNone,
               shape = "ONE spawn, observed once — a cold start is a " &
                       "property of a process's first moments and a second " &
                       "one would not be cold",
               extra = "process exec to the first ScreenBuffer commit " &
                       "(frame 0, the shell, before replay-server is spawned)")
  # GAP 1, and it is a REPORTED number rather than a §8 row: §8 publishes no
  # budget for it, so the target here is CTUI-11's own ~125 ms measurement
  # rounded up to 200 ms rather than a number this milestone invented and then
  # met.
  bench.record("tui/time-to-debugger", "ms", debuggerMs, 200.0,
               samples = 1,
               conditionGap = cgNone,
               shape = "ONE spawn, observed once — the SAME spawn the cold " &
                       "start above was taken from, so the two are stages of " &
                       "one session rather than two cold caches",
               extra = "GAP 1: process exec to the first frame a user can " &
                       "debug on — not a published §8 row; the target is " &
                       "CTUI-11's measured ~125ms with headroom")

  # STAGE 2: the resident set once the session has settled.
  for _ in 0 ..< 20:
    discard sess.readBytes(65536, initDuration(milliseconds = 50))
  let rss = rssKilobytes(childPid)
  bench.record("tui/steady-state-rss", "MB", float(rss) / 1024.0, 30.0,
               samples = 1,
               conditionGap = cgExternal,
               shape = "ONE read of /proc/<pid>/status VmRSS on the same " &
                       "spawn, after the session settled — a resident set is " &
                       "a state and not a distribution",
               extra = "fixture=calc — §8 states the condition as a " &
                       "50,000-tick trace; the fixture corpus CTUI-1 " &
                       "produces has no recording that long, so this is the " &
                       "largest available and the CONDITION IS NOT MET even " &
                       "though the number is")

  # STAGE 3: idle CPU over §8's own five-second window.
  let before = cpuJiffies(childPid)
  let idleStart = getMonoTime()
  var idleBytes = 0
  while (getMonoTime() - idleStart).inMilliseconds < IdleSampleSeconds * 1000:
    idleBytes += sess.readBytes(65536,
                                initDuration(milliseconds = 100)).len
  let after = cpuJiffies(childPid)
  let elapsedS = float((getMonoTime() - idleStart).inMilliseconds) / 1000.0
  let ticksPerSecond = float(sysconf(SC_CLK_TCK))
  let cpuPercent =
    if before < 0 or after < 0: -1.0
    else: 100.0 * (float(after - before) / ticksPerSecond) / elapsedS
  bench.record("tui/idle-cpu", "%", cpuPercent, 0.5,
               samples = 1,
               conditionGap = cgNone,
               shape = &"ONE utime+stime jiffy delta across ONE " &
                       &"{IdleSampleSeconds}-second window on the same " &
                       "spawn, which is §8's own stated sampling",
               extra = &"window={elapsedS:.1f}s bytes-received-while-idle=" &
                       &"{idleBytes} — a non-zero count there means the app " &
                       "was NOT idle and the figure is not an idle figure")

  # Give the terminal back the way a user would.
  sess.write(@[byte('q')])
  let quitDeadline = getMonoTime() + initDuration(seconds = 20)
  while sess.isAlive and getMonoTime() < quitDeadline:
    discard sess.readBytes(65536, initDuration(milliseconds = 50))
  if sess.isAlive:
    sess.terminate()

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

proc alertThreshold(bench: Bench; m: Metric): string =
  ## The CI alert threshold for one metric, as a percentage of the measured
  ## value, DERIVED FROM THIS RUN rather than chosen.
  ##
  ## `continuous-benchmarking.md` sets 120% as the org default.
  ##
  ## ## THIS IS NOT A MEASURED BASELINE DISTRIBUTION, and it must not be read
  ## ## as one
  ##
  ## CTUI-14's risk note asked for thresholds "set from a measured baseline
  ## distribution on the reference machine", with the alert on "a sustained
  ## regression rather than a single sample". **Neither is what this function
  ## does and neither exists in this repository.** There is no history to build
  ## a distribution from — the workflow that would accumulate one is withdrawn
  ## (`ci/test/shell-gate-coverage.sh` refuses `just bench` in a pipeline while
  ## `scripts/build-tui-grammars.sh` declares `NOT-A-CI-GATE:`), so there is no
  ## `gh-pages` baseline and no alerting of any kind.
  ##
  ## What this IS: a deterministic function of ONE run's headroom against its
  ## own published target. A metric sitting at half its budget can absorb a
  ## 120% regression and one sitting at 95% of it cannot, so the number below
  ## says how much room the entry has — useful to a reviewer, and not a
  ## statistic. The milestone's Risk mitigations section records the gap as
  ## UNMET rather than claiming it.
  ##
  ## The one gate in this file that IS measured against a distribution is
  ## `coalescingMetric`'s: it runs the uncoalesced arm TWICE and gates the
  ## coalescing delta against the spread between those two runs, so its
  ## threshold is calibrated per run on the host and load it ran on.
  if m.value <= 0.0 or m.target <= 0.0:
    return "120%"
  let headroom =
    if m.smallerIsBetter: m.target / m.value else: m.value / m.target
  # Never looser than the org default, never tighter than 105% — below that a
  # threshold is measuring the scheduler.
  let pct = clamp(100.0 * min(headroom, 1.20), 105.0, 120.0)
  $int(pct) & "%"

proc verdictToken(m: Metric): string =
  ## The `verdict=` value in the committed artifact — ONE WHITESPACE-FREE TOKEN
  ## per outcome, because this field is the machine-readable half of the file.
  ##
  ## ## WHY THE CONDITION GAPS GET THEIR OWN TOKENS
  ##
  ## `tui/steady-state-rss` and `tui/strip-cache-hit-rate` both emitted plain
  ## `met`. Both say, in their `extra` PROSE, that the condition §8 publishes
  ## the target for was NOT satisfied — the RSS row because the fixture corpus
  ## has no 50,000-tick recording, the strip-cache row because the shipped
  ## driver builds a fresh `Compositor` per frame and so has a hit rate of 0%
  ## by construction. A consumer parsing `verdict=` read "met" for both, and a
  ## consumer is the only reader this file has that is not a person.
  ##
  ## The tokens are deliberately NOT prefixes of one another in the useful
  ## direction: an equality test against `met` now fails for both gap rows,
  ## which is the test a consumer actually writes. The `external` / `internal`
  ## suffix carries which KIND of gap it is, per
  ## `metacraft-dev-guidelines/policies/continuous-benchmarking.md` — an
  ## external gap is a corpus limitation and an internal one is a product gap
  ## wearing a benchmark's green.
  ##
  ## The number's own verdict is still here and still first: these rows DID
  ## meet their numeric target, and a token that erased that would trade one
  ## inaccuracy for another.
  if not m.gated:
    return "reported-not-gated"
  if not m.met:
    return "NOT-MET"
  case m.conditionGap
  of cgNone: "met"
  of cgExternal: "met-CONDITION-NOT-external"
  of cgInternal: "met-CONDITION-NOT-internal"

proc writeJson(bench: Bench; path: string) =
  var arr = newJArray()
  for m in bench.metrics:
    arr.add %*{
      "name": m.name,
      "unit": m.unit,
      "value": m.value,
      "extra": m.extra & " target" &
               (if m.smallerIsBetter: "<=" else: ">=") & $m.target &
               " alert-threshold=" & alertThreshold(bench, m) &
               " verdict=" & verdictToken(m)
    }
  createDir(path.parentDir)
  writeFile(path, pretty(arr) & "\n")

proc writeReport(bench: Bench; path: string) =
  var rows = ""
  for m in bench.metrics:
    # THE ROW CLASS AND THE LABEL ARE NO LONGER THE SAME STRING. They were, and
    # that is why the two condition-gap rows rendered as plain green `met`: a
    # single value cannot carry both "how to colour this" and "what it says".
    let cls =
      if not m.gated: "reported"
      elif not m.met: "not-met"
      elif m.conditionGap == cgNone: "met"
      else: "condition-not"
    let label =
      if not m.gated: "reported"
      elif not m.met: "not-met"
      else:
        case m.conditionGap
        of cgNone: "met"
        of cgExternal: "met, CONDITION NOT (external)"
        of cgInternal: "met, CONDITION NOT (internal)"
    let comparison = if m.smallerIsBetter: "&le;" else: "&ge;"
    rows.add &"""
    <tr class="{cls}">
      <td class="name">{m.name}</td>
      <td class="num">{m.value:.3f}</td>
      <td class="unit">{m.unit}</td>
      <td class="num">{comparison} {m.target:.3f}</td>
      <td class="verdict">{label}</td>
      <td class="extra">{m.extra}</td>
    </tr>
"""
  let html = &"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>CodeTracer TUI benchmarks</title>
<style>
 body {{ font: 14px/1.5 ui-monospace, monospace; margin: 2rem; }}
 table {{ border-collapse: collapse; width: 100%; }}
 th, td {{ border-bottom: 1px solid #ddd; padding: .4rem .6rem;
           text-align: left; vertical-align: top; }}
 td.num {{ text-align: right; }}
 td.extra {{ font-size: 12px; color: #555; }}
 tr.not-met td.verdict {{ color: #b00; font-weight: bold; }}
 tr.met td.verdict {{ color: #070; }}
 tr.reported td.verdict {{ color: #666; }}
 /* AMBER, NOT GREEN: the number met its target and the published condition
    did not hold. Colouring these `met` green is the rendered form of the same
    defect the `verdict=` token had. */
 tr.condition-not td.verdict {{ color: #b56a00; font-weight: bold; }}
 .meta {{ color: #555; }}
</style></head><body>
<h1>CodeTracer TUI — §8 performance targets</h1>
<p class="meta">Run {bench.startedAt} &middot; {bench.cpuCount} CPUs &middot;
 one-minute load at start {bench.loadAverage:.2f} &middot;
 loop budget {bench.samples} iterations{(if bench.quick: " (--quick)" else: "")}</p>
<p class="meta"><strong>Every figure carries the host load it was taken
 under, and its own sample count and shape.</strong> A benchmark number
 without a load cannot be compared with another, and this campaign has
 crossed gates on a busy machine. The loop budget above is what the metrics
 that loop use; four entries are ONE observation of ONE process and three
 have sample counts of their own — read <code>samples=</code> and
 <code>shape=</code> in the conditions column, never this line.</p>
<table>
<tr><th>metric</th><th>value</th><th>unit</th><th>target</th>
    <th>verdict</th><th>conditions</th></tr>
{rows}</table>
</body></html>
"""
  createDir(path.parentDir)
  writeFile(path, html)

proc main() =
  var quick = false
  for arg in commandLineParams():
    if arg == "--quick":
      quick = true
    else:
      stderr.writeLine("tui_benchmarks: unknown argument '" & arg &
                       "'; the only one is --quick")
      quit(2)
  let bench = Bench(
    quick: quick,
    samples: (if quick: QuickSamples else: FullSamples),
    metrics: @[],
    loadAverage: oneMinuteLoad(),
    cpuCount: countProcessors(),
    startedAt: now().format("yyyy-MM-dd HH:mm:ss"))
  stderr.writeLine("CodeTracer TUI benchmarks — " & bench.startedAt)
  stderr.writeLine(&"  host: {bench.cpuCount} CPUs, one-minute load " &
                   &"{bench.loadAverage:.2f}, " &
                   &"{bench.samples} samples per metric" &
                   (if quick: " (--quick)" else: ""))
  if bench.loadAverage > float(bench.cpuCount) * 0.5:
    stderr.writeLine("  WARNING: this host is under load; every figure below" &
                     " carries its own load1 and should be read with it")

  processMetrics(bench)
  # PLAT-1's gate, next to the cold-start row its budget is stated against.
  uiHandoffMetric(bench)
  inputLatencyMetrics(bench)
  coalescingMetric(bench)
  emissionMetrics(bench)
  reflowMetric(bench)
  stripCacheMetric(bench)
  paletteMetric(bench)

  let root = repoRoot()
  writeJson(bench, root / "bench-results" / "benchmark_results.json")
  writeReport(bench, root / "bench-results" / "report.html")
  var notMet = 0
  var gated = 0
  var conditionGaps = 0
  for m in bench.metrics:
    if not m.gated:
      continue
    inc gated
    if not m.met:
      inc notMet
    # COUNTED SEPARATELY AND REPORTED, because the summary line is what a
    # reader carries away from a run, and "12 metric(s), 11 gated, 1 not met"
    # was the sentence that made two unsatisfied conditions invisible.
    elif m.conditionGap != cgNone:
      inc conditionGaps
  stderr.writeLine(&"  {bench.metrics.len} metric(s), {gated} gated, " &
                   &"{notMet} not met, " &
                   &"{conditionGaps} met with the CONDITION NOT satisfied")
  stderr.writeLine("  wrote bench-results/benchmark_results.json and " &
                   "bench-results/report.html")

when isMainModule:
  main()
