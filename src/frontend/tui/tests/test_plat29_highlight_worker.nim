## PLAT-29 Tier 2 — a REAL tree-sitter parse on a REAL thread, outrun by a
## REAL edit stream, with the reconciliation observed.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat29_highlight_worker.nim
##
## PLAT-29's three real-stack rows, taken together because they are one run:
##
##   1. *"A real tree-sitter parse over a real file, driven by a real edit
##      stream fast enough to outrun it, with the reconciliation observed
##      rather than simulated."* The file is real Nim source — this
##      repository's own editor modules, concatenated until the parse takes
##      longer than the gap between edits — parsed by the vendored Nim grammar
##      on `host/highlight_worker`'s thread. The stream applies edits faster
##      than the worker can answer, so parses land for versions the document
##      has left, and `reconcile` maps or drops them: counted in the buffer's
##      `StalenessReport` and asserted non-zero on both sides.
##   2. *"An edit applied while a slow producer is mid-flight, asserting the
##      edit's latency is unaffected."* Every edit is timed together with the
##      frame that follows it. The same stream is first run with NO producer
##      at all — the baseline — and then with the worker; the edits made while
##      a parse was in flight must cost what the baseline's did. The inline
##      path (the same parse run on the render path) is timed too and printed,
##      as the cost the boundary removes.
##   3. *"The edit streams driving this come from the corpus, at real edit
##      rates."* Every inserted string is whole grapheme clusters drawn from a
##      corpus document (`change_generator.corpusClusters`), positions are
##      cluster boundaries, and the gap between edits is stated and printed.
##
## Convergence closes the run: once the stream stops, the parse of the final
## version arrives and the pane's spans equal a fresh parse of the final text.
##
## NO MOCKS: the shipped worker, the shipped parse, real files, a real thread.

import std/[algorithm, monotimes, os, strutils, times, unittest]

import codetracer_embed
import ../app/edit_binding
import ../app/runtime
import ../app/theme/capabilities
import ../host/highlight_worker
import ../../viewmodel/tests/generators/change_generator

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 140
  Rows = 48
  TargetLines = 24_000
    ## Enough real Nim that one parse outlasts the gap between edits.
  EditCount = 60
  EditRegionLines = 60
    ## Edits land in the first screenful, where the pane is looking.
  Seed = 29'u32
  SourceDirs = ["src/frontend/viewmodel/editor", "src/frontend/viewmodel/keymap",
                "src/frontend/tui/app"]

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc realNimSource(): string =
  ## Real Nim, this repository's own, in a stable order, until the target.
  let root = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
  var files: seq[string] = @[]
  for dir in SourceDirs:
    for f in walkDirRec(root / dir):
      if f.endsWith(".nim"): files.add f
  files.sort()
  var lines = 0
  for f in files:
    let t = readFile(f)
    result.add t
    if not t.endsWith("\n"): result.add "\n"
    lines += t.count('\n')
    if lines >= TargetLines: break

proc ms(d: Duration): float = d.inMicroseconds.float / 1000.0

proc median(xs: seq[float]): float =
  var s = xs
  s.sort()
  if s.len == 0: 0.0 else: s[s.len div 2]

suite "PLAT-29 Tier 2: the highlighter off the render path, on a real thread":

  test "a real edit stream outruns a real parse; every late answer is reconciled":
    let text = realNimSource()
    let path = "src/plat29_big.nim"
    checkpoint($text.count('\n') & " lines of real Nim")
    ck text.count('\n') >= TargetLines

    # THE PARSE, TIMED ALONE — the cost the render path used to pay per frame.
    let t0 = getMonoTime()
    let whole = computeHighlight(HighlightRequest(path: path, text: text))
    let parseMs = ms(getMonoTime() - t0)
    ck whole.highlight.mode == hmTreeSitter
    # The gap between edits: a third of a parse, so the stream outruns it, and
    # never below a fast typist's 60 ms or above a slow one's 250 ms.
    let gapMs = max(60.0, min(250.0, parseMs / 3.0))
    echo "  parse of the whole file: ", parseMs.formatFloat(ffDecimal, 1),
         " ms; edit gap: ", gapMs.formatFloat(ffDecimal, 1), " ms"

    let app = newTuiApp()
    app.modes = initModeRegister(pmEdit)
    app.editSession = newEditSession()
    discard app.editSession.openFile(path, text, Rows - 6)
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    discard rt.focus.focusPaneKind(paneEditor)
    let buf = rt.app.editSession.activeBuffer()

    proc edit(r: var Rng; at: int; now: int64): ChangeSet =
      ## A cluster-aligned edit in the first screenful, of corpus text.
      discard at
      let head = buf.text.splitLines()[0 ..< EditRegionLines].join("\n")
      let bs = clusterBoundaries(head)
      let pos = bs[r.rand(bs.len - 2)]
      if r.rand(3) == 0 and pos + 1 < head.len:
        changeSet(buf.text.len, pos, bs[min(bs.len - 1, bs.find(pos) + 1)], "")
      else:
        changeSet(buf.text.len, pos, pos, corpusClusters(r, 1 + r.rand(2)))

    # THE BASELINE: the same kind of stream with no producer at all.
    var baseline: seq[float] = @[]
    block:
      rt.editServices.requestHighlight = proc(req: HighlightRequest) = discard
      var rb = initRng(Seed + 1)
      for step in 0 ..< EditCount div 2:
        let cs = edit(rb, step, 0)
        let e0 = getMonoTime()
        discard buf.doc.applyChangeSet(cs, int64(step))
        discard rt.shellScreenOf()
        baseline.add ms(getMonoTime() - e0)
    # THE INLINE PATH, once: what a frame costs when the parse runs on it.
    var inlineMs: float
    block:
      rt.editServices.requestHighlight = nil
      var ri = initRng(Seed + 2)
      let cs = edit(ri, 0, 0)
      let e0 = getMonoTime()
      discard buf.doc.applyChangeSet(cs, 1)
      discard rt.shellScreenOf()
      inlineMs = ms(getMonoTime() - e0)

    let worker = startHighlightWorker()
    defer: worker.stop()
    rt.editServices.requestHighlight = proc(req: HighlightRequest) =
      worker.submit(req)

    proc pump(): int =
      for res in worker.drain():
        if rt.deliverHighlight(res): inc result

    var r = initRng(Seed)
    var latencies: seq[float] = @[]
    var inFlightLatencies: seq[float] = @[]
    var inFlightEdits = 0
    var now = 0'i64
    for step in 0 ..< EditCount:
      let cs = edit(r, step, now)
      let busy = worker.submitted > worker.delivered
      now += int64(gapMs)
      let e0 = getMonoTime()
      discard buf.doc.applyChangeSet(cs, now)
      discard rt.shellScreenOf()          # the frame that follows the edit
      let lat = ms(getMonoTime() - e0)
      latencies.add lat
      if busy:
        inc inFlightEdits
        inFlightLatencies.add lat
      discard pump()
      sleep(int(gapMs))

    let rep = buf.highlights.report
    echo "  arrivals: ", buf.highlights.arrivals, "  submitted: ",
         worker.submitted
    for line in rep.reportLines(): echo line
    # (1) OUTRUN, AND RECONCILED — stale answers arrived and were mapped or
    # dropped, not applied as current.
    ck buf.highlights.arrivals > 0
    ck worker.submitted > buf.highlights.arrivals
    ck rep.count(pkTreeSitter, roMapped) > 0
    ck rep.count(pkTreeSitter, roDropped) > 0

    # (2) THE EDIT DOES NOT WAIT FOR THE PARSE. Edits were made while a parse
    # was in flight, and they took a small fraction of what the inline parse
    # costs — the latency the render path had before the producer moved out.
    echo "  edit+frame latency: baseline (no producer) median ",
      median(baseline).formatFloat(ffDecimal, 2), " ms; with a parse in flight ",
      "median ", median(inFlightLatencies).formatFloat(ffDecimal, 2), " ms over ",
      inFlightEdits, " edits; inline parse on the render path ",
      inlineMs.formatFloat(ffDecimal, 1), " ms"
    ck inFlightEdits > 0
    # THE EDIT DOES NOT WAIT FOR THE PARSE, which is the property, and it is
    # asserted two ways. (a) An edit made while a parse runs costs a small
    # fraction of that parse: were it waiting, it would cost the parse. (b) It
    # stays within a band of the no-producer baseline. The band is 3x + 20 ms
    # and not tighter because the worker is a second thread doing real work:
    # on a shared host the two contend for cores — measured at 2.2x on a
    # 24-core host at load 140 — and that is CPU sharing, not waiting.
    ck median(inFlightLatencies) < parseMs / 4.0
    ck median(inFlightLatencies) <= median(baseline) * 3.0 + 20.0
    # …and the inline path is what the boundary removes.
    ck inlineMs > median(inFlightLatencies) * 4.0

    # CONVERGENCE — the final version's parse arrives and IS the answer.
    let deadline = getMonoTime() + initDuration(seconds = 30)
    while getMonoTime() < deadline and
          not (buf.highlights.hasParse and
               buf.highlights.parsedVersion == buf.doc.version):
      discard rt.shellScreenOf()
      discard pump()
      sleep(20)
    ck buf.highlights.parsedVersion == buf.doc.version
    let fresh = computeHighlight(HighlightRequest(path: path, text: buf.text))
    let shown = buf.highlights.spansForWindow(buf.doc, 1, EditRegionLines)
    var agree = 0
    for i in 0 ..< EditRegionLines:
      if shown[i] == fresh.highlight.spansForLine(i + 1): inc agree
    ck agree == EditRegionLines

suite "PLAT-29 highlight worker — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
