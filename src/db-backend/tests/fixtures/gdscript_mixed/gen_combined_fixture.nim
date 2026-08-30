## Mixed-Trace implicit-language-switch fixture generator.
##
## Writes `combined_trace.ct`, the `.ct` container the db-backend's
## `mixed_altitude_test.rs` reads to exercise the SPAN-DRIVEN half of the
## implicit-language-switch design
## (`codetracer-specs/Planned-Features/Mixed-Trace-Implicit-Switch.md`, P1/P3).
##
## Like the RS-M2 span-stream generator next door
## (`tests/fixtures/span_stream/gen_span_fixtures.nim`), this uses the CANONICAL
## Nim writer — `codetracer_trace_writer/multi_stream_writer` driving
## `codetracer_trace_writer/span_stream` — so the committed bytes are real
## production output, not something the Rust side round-tripped through itself.
## The container is COMMITTED so `cargo test` needs neither a Nim toolchain nor a
## sibling `codetracer-trace-format-nim` checkout; run `./regenerate.sh` to
## rebuild it.
##
## ## What this fixture is (and is NOT)
##
## It models the GDScript (VM) altitude of a combined native+GDScript recording:
## a MATERIALIZED GDScript program (steps / calls / returns / bundled `.gd`
## source) plus the CROSSING SPANS that bound each VM frame's steps
## (`Mixed-Trace-Debugging.md` §3).  The span stream is what the altitude
## resolver reads.
##
## It deliberately carries NO native `tNNN` streams and NO real MCR replay: a
## genuine combined native+GDScript trace needs the MT14 substrate (patched
## Godot under `ct-mcr` on Linux).  The db-backend altitude slice is green-able
## now against exactly this synthetic VM-plus-spans container, and the
## native-altitude REPLAY expectations stay gated (`#[ignore]`) until MT14.
##
## ## Step / span layout (documented so the Rust assertions can be reviewed)
##
## The program is `_ready()` calling `compute()`, which calls `scale()` — three
## nested GDScript frames.  Steps are 0-based StepIds in emission order:
##
##   step 0  outer `_ready`   line 4    (`var total = 0`)
##   step 1  outer `_ready`   line 5    (`total += 1`)
##   step 2  outer `_ready`   line 6    (call site: `compute(total)`)
##   --- registerCall(compute), entryStep = 3 ---
##   step 3  inner `compute`  line 11   (`var r = n * 2`)
##   --- registerCall(scale), entryStep = 4 ---
##   step 4  inner-inner `scale` line 16 (`var f = 30`)
##   step 5  inner-inner `scale` line 17 (`return x * f`)
##   --- registerReturn (scale) ---
##   step 6  inner `compute`  line 13   (`return r`)
##   --- registerReturn (compute) ---
##   step 7  outer `_ready`   line 7    (`print(total)`)
##   step 8  outer `_ready`   line 8    (`queue_free()`)
##
## Two crossing spans (both `span_type: "gdscript-frame"`, i.e. VM crossings):
##
##   span 1  compute frame    start_step = 3, end_step = 6   (covers steps 3..6)
##   span 2  scale   frame    start_step = 4, end_step = 5   (covers steps 4..5)
##
## So, for the resolver:
##   * step 1 is OUTSIDE every crossing span     -> native by P1
##   * step 5 is inside BOTH spans               -> vm by P1; innermost = span 2
##   * step 6 is inside span 1 only              -> vm by P1; innermost = span 1
##   * step 8 is outside every crossing span     -> native by P1
##
## Usage: `gen_combined_fixture <out-dir>`.

import std/[os]
import results
import codetracer_trace_writer/multi_stream_writer
import codetracer_trace_writer/span_stream

proc fail(msg: string) {.raises: [].} =
  try:
    stderr.writeLine("gen_combined_fixture: " & msg)
  except IOError, ValueError:
    discard
  quit(1)

proc toBytesSeq(s: string): seq[byte] {.raises: [].} =
  ## The `.gd` source text, byte for byte, for `registerSourceView`.
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

## The bundled GDScript source.  Line numbers here are the ones the steps above
## reference; keep the two in sync when editing.
const GdSource = """extends Node

# A tiny mixed-trace demo: _ready -> compute -> scale, three nested GD frames.
func _ready():
	var total = 0
	total += 1
	total = compute(total)
	print(total)
	queue_free()

func compute(n):
	var r = n * 2
	r = scale(r)
	return r

func scale(x):
	var f = 30
	return x * f
"""

proc frameSpan(spanId, parentSpanId, startStep, endStep: uint64,
    label: string): SpanRecord {.raises: [].} =
  ## One VM crossing span bounding a GDScript frame's materialized steps.  The
  ## `span_type` marks it a GDScript (VM) crossing — the resolver's
  ## `is_vm_crossing_span` predicate keys on the `"gdscript"` prefix.
  SpanRecord(
    spanId: spanId,
    parentSpanId: parentSpanId,
    isOpen: false,
    isExternal: false,
    status: spanStatusOk,
    startWallNs: 1_764_000_000_000_000_000'u64 + spanId * 1_000_000'u64,
    endWallNs: 1_764_000_000_000_000_000'u64 + spanId * 1_000_000'u64 + 500_000'u64,
    processOrd: 0,
    threadId: 1,
    startStep: startStep,
    endStep: endStep,
    spanType: "gdscript-frame",
    label: label,
    contiguousOnOneThread: true,
    sharesTimeline: true,
    concurrentWithSiblings: false,
    metadata: @[
      ("vm.language", "gdscript"),
      ("vm.frame", label),
    ])

proc writeContainer(outPath: string) {.raises: [].} =
  var wRes = initMultiStreamWriter(outPath, "res://mixed_demo.gd",
    recordingId = "01949fcc-7d92-7e9c-b001-000000000001")
  if wRes.isErr: fail("init writer: " & wRes.error)
  var w = wRes.get()

  let pRes = w.registerPath("res://mixed_demo.gd")
  if pRes.isErr: fail("registerPath: " & pRes.error)
  let pathId = pRes.get()

  # Bundle the `.gd` source so the container is a realistic self-contained VM
  # recording (view_kind 1, as `source_views.rs` documents).
  let svRes = w.registerSourceView(pathId, 1'u8, "mixed_demo.gd",
    toBytesSeq(GdSource), @[])
  if svRes.isErr: fail("registerSourceView: " & svRes.error)

  # Function names for the call/return chokepoints.
  let readyFn = w.registerFunction("_ready")
  if readyFn.isErr: fail("registerFunction _ready: " & readyFn.error)
  let computeFn = w.registerFunction("compute")
  if computeFn.isErr: fail("registerFunction compute: " & computeFn.error)
  let scaleFn = w.registerFunction("scale")
  if scaleFn.isErr: fail("registerFunction scale: " & scaleFn.error)

  template step(line: uint64) =
    let r = w.registerStep(pathId, line, [])
    if r.isErr: fail("registerStep: " & r.error)
  template call(fnId: uint64) =
    let r = w.registerCall(fnId, [])
    if r.isErr: fail("registerCall: " & r.error)
  template ret() =
    let r = w.registerReturn()
    if r.isErr: fail("registerReturn: " & r.error)

  # --- the materialized GDScript program (see the header for the layout) ---
  step(4'u64)                      # step 0  outer
  step(5'u64)                      # step 1  outer
  step(6'u64)                      # step 2  outer (calls compute)
  call(computeFn.get())           #          entryStep = 3
  step(11'u64)                     # step 3  inner  (calls scale)
  call(scaleFn.get())             #          entryStep = 4
  step(16'u64)                     # step 4  inner-inner
  step(17'u64)                     # step 5  inner-inner
  ret()                            #          scale returns
  step(13'u64)                     # step 6  inner
  ret()                            #          compute returns
  step(7'u64)                      # step 7  outer
  step(8'u64)                      # step 8  outer

  # --- one crossing span per VM frame; span 2 nested inside span 1 ---
  let s1 = w.registerSpan(frameSpan(1, 0, 3, 6, "compute()"))
  if s1.isErr: fail("registerSpan compute: " & s1.error)
  let s2 = w.registerSpan(frameSpan(2, 1, 4, 5, "scale()"))
  if s2.isErr: fail("registerSpan scale: " & s2.error)

  let closeRes = w.close()
  if closeRes.isErr: fail("close: " & closeRes.error)
  let bytes = w.toBytes()
  w.closeCtfs()
  try:
    writeFile(outPath, bytes)
  except IOError:
    fail("failed to write " & outPath)

proc main() {.raises: [].} =
  let args = commandLineParams()
  if args.len < 1:
    fail("usage: gen_combined_fixture <out-dir>")
  let outDir = args[0]
  try:
    createDir(outDir)
  except OSError, IOError:
    fail("cannot create " & outDir)
  writeContainer(outDir / "combined_trace.ct")
  echo "wrote combined mixed-trace fixture to " & outDir

main()
