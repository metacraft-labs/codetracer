## text_store_bench.nim — PLAT-24's measurement: what an editable source
## document should be stored in, decided by numbers taken before anything is
## built on top of the answer.
##
## NOT-A-TEST-LANE-FILE: a benchmark, not a suite. It asserts nothing and runs
## from `just bench-text-store`; the assertions PLAT-24 owns live in
## `viewmodel/tests/unit/test_editor_text_store.nim`, which the `vm-unit` lane
## discovers.
##
## WHAT IS MEASURED, AND WHY EXACTLY THIS
## ======================================
##
## The gate was fixed before the measurement and it names the keystroke,
## because the wrong keystroke makes it pass:
##
##   the cost of one LINE-SPLITTING keystroke (`Enter`) at line 1 of a
##   200,000-line document, divided by the cost of the same keystroke at the
##   LAST line, must be under 4x.
##
## Only the line-splitting branch of `textarea.nim`'s `applyInsert` moves the
## `seq`: `:761-767` does one `t.lines.insert(...)` per inserted line, which at
## line 1 of 200,000 memmoves ~200,000 string headers and at the last line
## moves none. A rope is O(log n) at both ends. 4x sits in the wide gap
## between a linear shift and a logarithmic one, so it is a statement about
## structure and not about a constant.
##
## **The ordinary character insert is measured and printed beside it, as the
## arm that does not discriminate.** `textarea.nim:755` is
## `t.lines[pos.line] = prefix & s & suffix` — an assignment to an EXISTING
## `seq` element, whose cost is the length of the line and is the same on line
## 1 and on line 200,000. Its ratio is ~1 on `seq[string]` AND on a rope, so a
## gate measured on that keystroke alone is satisfied by the incumbent and
## would decide the milestone the wrong way while looking green. It is printed
## so the discriminating arm cannot be quietly swapped for it.
##
## The line index is printed as a third figure for both stores, because it is
## the other thing a position costs and folding it into a keystroke would hide
## a real difference inside a number about something else.
##
## THE INSTRUMENT IS PROVED ABLE TO FAIL
## =====================================
## Both stores run in the SAME process, at the SAME load, interleaved round by
## round, and both ratios are printed against the same gate. A gate whose
## losing arm is never executed is a gate nobody has seen fail.
##
## THIS HOST IS HOSTILE TO TIMING, AND THE GATE IS A RATIO FOR THAT REASON
## ======================================================================
## Absolute nanoseconds on a shared runner are not comparable with anything.
## A ratio between two operations measured back-to-back on the same box is
## far more robust than either number, which is why the gate is a ratio — so
## the harness preserves that property rather than spending it:
##
##   * the two positions of an arm are measured in the SAME round, adjacent in
##     time, so a scheduler excursion lands on both;
##   * every figure is the MEDIAN of `Rounds` rounds, and the MINIMUM is
##     printed beside it — under contention, noise is one-sided upward, so the
##     minimum is the better estimator of the true cost and the two agreeing
##     is evidence the median was not eaten;
##   * the ratio is reported from the median AND from the minimum, and the
##     per-round ratio's own min/median/max are printed, which is what "the
##     ratio is stable" has to mean if it is to mean anything;
##   * the run's load average is read at the start and at the end and both are
##     printed (§28b: a timing quotes what it was taken under), together with
##     the build — memory manager, optimisation level and backend — because a
##     number taken under a different `--mm` is a number about a different
##     program.
##
## EVERY FIGURE IS TAKEN TWICE (two takes), at stated loads, because an
## inequality between two independently noisy measurements asserted against an
## exact constant is a coin flip.
##
## THE CORPUS IS REAL SOURCE OFF THE DISK
## ======================================
## No synthetic document of repeated lines: line-length distribution is one of
## the inputs. The 1K corpus is one named product source file; the 40K and
## 200K corpora are path-sorted concatenations of this repository's own `.nim`
## sources, whole files at a time, and the full file list of each is written to
## `test-logs/plat24/` so a figure can be retaken against the same bytes. Each
## corpus prints its byte length and an FNV-1a fingerprint.
##
## Usage:
##   nim c -d:release -o:/tmp/plat24-bench \
##       src/frontend/viewmodel/benchmarks/text_store_bench.nim
##   /tmp/plat24-bench [--sizes=1000,40000,200000] [--takes=2] [--rounds=25]

import std/[algorithm, cpuinfo, math, monotimes, os, strformat, strutils,
            times, unicode]

import ../editor/text_store
import ../editor/seq_line_store
import isonim_tui/text/width as widthMod

const
  GateRatio = 4.0
    ## Fixed before the measurement. See the header.
  EnterOpsPerRound = 64
    ## `Enter` grows the document by one line per op. 64 out of 200,000 is
    ## 0.03%, so `n` is effectively constant across a round, and the store is
    ## rebuilt between rounds so it cannot drift across them either.
  CharOpsPerRound = 64
    ## An ordinary insert grows the LINE it lands on by one byte per op. 64
    ## bytes onto a ~40-byte source line roughly triples it by the end of a
    ## round; the store is rebuilt between rounds, and the same growth happens
    ## identically at both positions, so the ratio the gate reads is unmoved.
  IndexOpsPerRound = 1024
    ## The line index mutates nothing, so nothing drifts and the count is set
    ## purely for clock resolution.

type
  Corpus = object
    name: string
    text: string
    lines: int
    firstLineLen: int
    lastLineLen: int
    fingerprint: uint64
    manifestPath: string
    fileCount: int

  Sample = object
    ## One arm at one position: the per-round ns-per-op figures.
    perOp: seq[float]

  ArmKind = enum
    akEnter          ## the line-splitting keystroke — the gate's arm
    akChar           ## the ordinary character insert — the non-discriminating arm
    akLineIndex      ## resolving a position — printed as context

  Position = enum
    posFirst
    posLast

# ---------------------------------------------------------------------------
# Host and build, quoted beside every number
# ---------------------------------------------------------------------------

proc loadAverage(): string =
  try:
    let raw = strutils.splitWhitespace(readFile("/proc/loadavg"))
    if raw.len >= 3: raw[0] & " " & raw[1] & " " & raw[2]
    else: "unreadable"
  except CatchableError:
    "unavailable (no /proc/loadavg)"

proc buildDescription(): string =
  ## Verification-Harness-Traps.md §28b: a timing quotes its build. `let x =
  ## someSeq` is a deep copy under ORC and a refcount bump under refc, so a
  ## nanosecond figure without the memory manager beside it is a number about
  ## an unnamed program. `compileOption` takes literals only, hence the
  ## unrolled `when` chain.
  const mm =
    when compileOption("mm", "orc"): "orc"
    elif compileOption("mm", "arc"): "arc"
    elif compileOption("mm", "refc"): "refc"
    elif compileOption("mm", "markAndSweep"): "markAndSweep"
    elif compileOption("mm", "boehm"): "boehm"
    else: "other"
  const opt =
    when compileOption("opt", "speed"): "speed"
    elif compileOption("opt", "size"): "size"
    else: "none"
  const flavour =
    when defined(danger): "danger"
    elif defined(release): "release"
    else: "debug"
  const backend = when defined(js): "js" else: "c"
  const assertionsOn = not defined(danger)
  &"Nim {NimVersion}, backend={backend}, --mm:{mm}, opt={opt}, {flavour}, " &
    &"assertions={assertionsOn}"

# ---------------------------------------------------------------------------
# The corpus
# ---------------------------------------------------------------------------

func fnv1a(s: string): uint64 =
  result = 0xcbf29ce484222325'u64
  for ch in s:
    result = result xor uint64(uint8(ch))
    result = result * 0x100000001b3'u64

proc sourceFiles(root: string): seq[string] =
  ## Every `.nim` under `root/src`, path-sorted, excluding build output and
  ## vendored trees. Sorted so the corpus is the same bytes on every host.
  result = @[]
  for path in walkDirRec(root / "src", relative = true):
    if not path.endsWith(".nim"): continue
    if path.contains("build-") or path.contains("nimcache") or
       path.contains("node_modules"):
      continue
    result.add "src" / path
  result.sort()

proc writeManifest(path: string; entries: seq[(string, int)]) =
  createDir(path.parentDir)
  var f = open(path, fmWrite)
  defer: f.close()
  f.writeLine("# PLAT-24 corpus manifest — file, lines contributed")
  for (name, n) in entries:
    f.writeLine(name & "\t" & $n)

proc buildCorpus(root: string; targetLines: int; outDir: string): Corpus =
  ## Whole real source files, concatenated in path order until `targetLines`
  ## is reached; the last file is truncated to land on the target exactly.
  var text = newStringOfCap(targetLines * 40)
  var entries: seq[(string, int)] = @[]
  var have = 0
  for rel in sourceFiles(root):
    if have >= targetLines: break
    var body: string
    try:
      body = readFile(root / rel)
    except CatchableError:
      continue
    if body.len == 0: continue
    if not body.endsWith("\n"): body.add '\n'
    var lines = body.count('\n')
    if have + lines > targetLines:
      # Truncate this file on a line boundary so the corpus is exactly the
      # requested height and still ends in real source.
      let want = targetLines - have
      var cut = 0
      var seen = 0
      for i in 0 ..< body.len:
        if body[i] == '\n':
          inc seen
          if seen == want:
            cut = i + 1
            break
      body = body[0 ..< cut]
      lines = want
    text.add body
    entries.add (rel, lines)
    have += lines
  if have < targetLines:
    raise newException(IOError,
      &"only {have} lines of real source available, needed {targetLines}")
  # `split('\n')` on a text ending in '\n' yields a final empty line, which is
  # what both stores model, so the document is `targetLines + 1` lines.
  let manifest = outDir / &"corpus-{targetLines}.manifest"
  writeManifest(manifest, entries)
  var firstEnd = text.find('\n')
  if firstEnd < 0: firstEnd = text.len
  var lastStart = 0
  if text.len >= 2:
    let prev = text.rfind('\n', last = text.len - 2)
    lastStart = prev + 1
  Corpus(
    name: &"{targetLines} lines",
    text: text,
    lines: targetLines + 1,
    firstLineLen: firstEnd,
    lastLineLen: (text.len - 1) - lastStart,
    fingerprint: fnv1a(text),
    manifestPath: manifest,
    fileCount: entries.len)

# ---------------------------------------------------------------------------
# The arms — written ONCE, generic over the store, so the two arms of the
# comparison cannot drift apart (§30: one predicate, one function).
# ---------------------------------------------------------------------------

template applyOp(s: untyped; kind: ArmKind; pos: Position; sink: var int) =
  let line = (if pos == posFirst: 0 else: s.lineCount - 1)
  case kind
  of akEnter:
    s.replaceRange(textPos(line, 0), textPos(line, 0), "\n")
  of akChar:
    s.replaceRange(textPos(line, 0), textPos(line, 0), "x")
  of akLineIndex:
    sink = sink + s.offsetOf(textPos(line, 0))

proc opsPerRound(kind: ArmKind): int =
  case kind
  of akEnter: EnterOpsPerRound
  of akChar: CharOpsPerRound
  of akLineIndex: IndexOpsPerRound

proc measurePair[S](make: proc(): S; kind: ArmKind; rounds: int):
    (Sample, Sample) =
  ## The two positions of one arm, INTERLEAVED round by round: a scheduler
  ## excursion lands on both sides of the ratio rather than on one.
  var first = Sample()
  var last = Sample()
  let n = opsPerRound(kind)
  var sink = 0
  for r in 0 ..< rounds:
    for pos in [posFirst, posLast]:
      var store = make()
      let t0 = getMonoTime()
      for _ in 0 ..< n:
        applyOp(store, kind, pos, sink)
      let ns = float((getMonoTime() - t0).inNanoseconds) / float(n)
      if pos == posFirst: first.perOp.add ns else: last.perOp.add ns
      # Keep `store` and `sink` observable so no optimiser can delete the work.
      if store.lineCount < 0: quit("unreachable: " & $sink)
  (first, last)

func median(xs: seq[float]): float =
  var v = xs
  v.sort()
  if v.len == 0: 0.0
  elif v.len mod 2 == 1: v[v.len div 2]
  else: (v[v.len div 2 - 1] + v[v.len div 2]) / 2.0

func minimum(xs: seq[float]): float =
  result = xs[0]
  for x in xs: result = min(result, x)

func maximum(xs: seq[float]): float =
  result = xs[0]
  for x in xs: result = max(result, x)

func perRoundRatios(a, b: Sample): seq[float] =
  result = @[]
  for i in 0 ..< min(a.perOp.len, b.perOp.len):
    if b.perOp[i] > 0.0: result.add a.perOp[i] / b.perOp[i]

proc reportArm(storeName, armName: string; first, last: Sample;
               gated: bool): float =
  let fm = median(first.perOp)
  let lm = median(last.perOp)
  let fn0 = minimum(first.perOp)
  let ln0 = minimum(last.perOp)
  let ratioMedian = if lm > 0: fm / lm else: Inf
  let ratioMin = if ln0 > 0: fn0 / ln0 else: Inf
  let rr = perRoundRatios(first, last)
  echo &"  {storeName:<12} {armName:<22} " &
       &"line1 median {fm:>12.1f} ns  min {fn0:>12.1f} ns"
  echo &"  {\"\":<12} {\"\":<22} " &
       &"last  median {lm:>12.1f} ns  min {ln0:>12.1f} ns"
  let stability =
    if rr.len == 0: "no paired rounds"
    else: &"per-round ratio min {minimum(rr):.2f} median {median(rr):.2f} " &
          &"max {maximum(rr):.2f} over {rr.len} rounds"
  if gated:
    let verdict = if ratioMedian < GateRatio: "UNDER 4x (passes the gate)"
                  else: "OVER 4x (FAILS the gate)"
    echo &"  {\"\":<12} {\"\":<22} " &
         &"RATIO {ratioMedian:.2f}x (median)  {ratioMin:.2f}x (min)  -> {verdict}"
  else:
    echo &"  {\"\":<12} {\"\":<22} " &
         &"ratio {ratioMedian:.2f}x (median)  {ratioMin:.2f}x (min)"
  echo &"  {\"\":<12} {\"\":<22} {stability}"
  ratioMedian

# ---------------------------------------------------------------------------
# Deliverable 4 — the two properties of TODAY's storage, re-measured
# ---------------------------------------------------------------------------

proc measureLineLengthEffect(corpus: Corpus; rounds: int) =
  ## `applyInsert` copies the whole line per keystroke (`prefix & s & suffix`).
  ## Measured as: the same character insert on the SHORTEST and on the LONGEST
  ## real line of the corpus. If the cost were independent of the line, the two
  ## would agree.
  var shortest = 0
  var longest = 0
  block:
    var probe = toSeqLineStore(corpus.text)
    var sLen = high(int)
    var lLen = -1
    for i in 0 ..< probe.lineCount:
      let n = probe.lineLen(i)
      # The shortest NON-EMPTY line: an empty line makes `prefix & s & suffix`
      # a copy of nothing, which is a measurement of the allocator rather than
      # of the property "applyInsert copies the whole line".
      if n > 0 and n < sLen: sLen = n; shortest = i
      if n > lLen: lLen = n; longest = i
    echo &"  shortest non-empty line: #{shortest} ({sLen} bytes)   " &
         &"longest: #{longest} ({lLen} bytes)"
  for (label, line) in [("shortest line", shortest), ("longest line", longest)]:
    var seqTimes: seq[float] = @[]
    var ropeTimes: seq[float] = @[]
    for r in 0 ..< rounds:
      block:
        var s = toSeqLineStore(corpus.text)
        let t0 = getMonoTime()
        for _ in 0 ..< CharOpsPerRound:
          s.replaceRange(textPos(line, 0), textPos(line, 0), "x")
        seqTimes.add float((getMonoTime() - t0).inNanoseconds) /
                    float(CharOpsPerRound)
        if s.lineCount < 0: quit("unreachable")
      block:
        var s = toTextStore(corpus.text)
        let t0 = getMonoTime()
        for _ in 0 ..< CharOpsPerRound:
          s.replaceRange(textPos(line, 0), textPos(line, 0), "x")
        ropeTimes.add float((getMonoTime() - t0).inNanoseconds) /
                     float(CharOpsPerRound)
        if s.lineCount < 0: quit("unreachable")
    echo &"  char insert on the {label:<14} " &
         &"seq[string] {median(seqTimes):>10.1f} ns   " &
         &"rope {median(ropeTimes):>10.1f} ns"

proc measureMultiLineInsert(corpus: Corpus; rounds: int) =
  ## A multi-line insert does one `seq.insert` per line (`textarea.nim:763`),
  ## so its cost should be proportional to the number of lines inserted. One
  ## `seq.insert` is what a 1-line split costs; a 10-line block should cost
  ## about ten of them, at line 1, and the same as one at the end.
  const Block10 = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj"
  for (label, payload) in [("1-line split", "\n"), ("10-line block", Block10)]:
    var seqTimes: seq[float] = @[]
    var ropeTimes: seq[float] = @[]
    for r in 0 ..< rounds:
      block:
        var s = toSeqLineStore(corpus.text)
        let t0 = getMonoTime()
        for _ in 0 ..< EnterOpsPerRound:
          s.replaceRange(textPos(0, 0), textPos(0, 0), payload)
        seqTimes.add float((getMonoTime() - t0).inNanoseconds) /
                    float(EnterOpsPerRound)
        if s.lineCount < 0: quit("unreachable")
      block:
        var s = toTextStore(corpus.text)
        let t0 = getMonoTime()
        for _ in 0 ..< EnterOpsPerRound:
          s.replaceRange(textPos(0, 0), textPos(0, 0), payload)
        ropeTimes.add float((getMonoTime() - t0).inNanoseconds) /
                     float(EnterOpsPerRound)
        if s.lineCount < 0: quit("unreachable")
    echo &"  {label:<16} at line 1   " &
         &"seq[string] {median(seqTimes):>12.1f} ns   " &
         &"rope {median(ropeTimes):>10.1f} ns"

# ---------------------------------------------------------------------------
# Deliverable 5 — grapheme segmentation's allocation profile
# ---------------------------------------------------------------------------

proc countCallSites(path: string; needle: string): int =
  ## Call sites of `needle(` in `path`, excluding its own definition lines.
  ## Returns -1 when the file is absent, which the caller prints LOUDLY: a
  ## figure that silently becomes "0 call sites" because a path moved is a
  ## scan that found nothing satisfying every check written over it.
  if not fileExists(path): return -1
  var n = 0
  for line in lines(path):
    let t = line.strip()
    if t.startsWith("proc " & needle) or t.startsWith("func " & needle) or
       t.startsWith("iterator " & needle) or t.startsWith("template " & needle):
      continue
    var idx = 0
    while true:
      let at = line.find(needle & "(", idx)
      if at < 0: break
      inc n
      idx = at + needle.len
  n

proc measureGraphemeProfile(corpus: Corpus; root: string; rounds: int) =
  ## `graphemeClusters` decodes every rune of a line into two `seq`s before it
  ## yields, so it allocates per call. Measured against a rune walk over the
  ## same lines, which does the same decoding and allocates nothing — the
  ## difference is what the buffers cost.
  var store = toSeqLineStore(corpus.text)
  var sample: seq[string] = @[]
  var bytes = 0
  var runeTotal = 0
  let step = max(1, store.lineCount div 2000)
  var i = 0
  while i < store.lineCount and sample.len < 2000:
    let t = store.lineText(i)
    if t.len > 0:
      sample.add t
      bytes += t.len
      runeTotal += t.runeLen
    i += step
  if sample.len == 0:
    echo "  NOT MEASURED: the corpus yielded no non-empty lines"
    return

  # Three variants over the SAME lines, so the profile separates what the
  # segmentation costs from what its allocations cost:
  #   (a) `graphemeClusters(string)` — what textarea.nim calls: three `seq`s
  #       built before the first yield, plus a fresh substring PER CLUSTER;
  #   (b) decode once into a `seq[int32]`, then the openArray overload — the
  #       same UAX #29 work and the same buffer, no per-cluster substring;
  #   (c) a plain `runes` walk — the same UTF-8 decoding, no buffer, no
  #       substring, no break logic.
  # (a) - (b) is the per-cluster substring; (b) - (c) is the buffer plus the
  # break logic.
  var segTimes: seq[float] = @[]
  var noStrTimes: seq[float] = @[]
  var runeTimes: seq[float] = @[]
  var clusters = 0
  var runesSeen = 0
  for r in 0 ..< rounds:
    block:
      var c = 0
      let t0 = getMonoTime()
      for line in sample:
        for _ in graphemeClusters(line):
          inc c
      segTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
      clusters = c
    block:
      var c = 0
      let t0 = getMonoTime()
      for line in sample:
        var buf: seq[int32] = @[]
        for rn in runes(line): buf.add int32(rn)
        for _ in graphemeClusters(buf):
          inc c
      noStrTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
    block:
      var c = 0
      let t0 = getMonoTime()
      for line in sample:
        for _ in runes(line):
          inc c
      runeTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
      runesSeen = c
  let segMed = median(segTimes)
  let noStrMed = median(noStrTimes)
  let runeMed = median(runeTimes)
  # The three `seq`s `graphemeClusters` builds before yielding: one
  # `seq[int32]` of runes and two `seq[int]` of byte offsets, each sized by
  # the rune count.
  let allocBytesPerLine = float(runeTotal) * float(4 + 8 + 8) / float(sample.len)
  echo &"  {sample.len} real lines sampled, {bytes} bytes, " &
       &"{runesSeen} runes, {clusters} clusters"
  echo &"  (a) graphemeClusters(string)   {segMed:>10.1f} ns/line" &
       &"   {(if runeMed > 0: segMed / runeMed else: Inf):>7.2f}x a plain rune walk"
  echo &"  (b) same, no cluster substring {noStrMed:>10.1f} ns/line" &
       &"   per-cluster substring costs {segMed - noStrMed:>9.1f} ns/line"
  echo &"  (c) plain rune walk            {runeMed:>10.1f} ns/line" &
       &"   buffers + break logic cost  {noStrMed - runeMed:>9.1f} ns/line"
  echo &"  buffers built before the first yield: " &
       &"~{int(allocBytesPerLine)} bytes/line " &
       &"(seq[int32] runes + two seq[int] byte-offset arrays)"
  let ta = root / ".." / "isonim-tui" / "src" / "isonim_tui" / "widgets" /
           "textarea.nim"
  for helper in ["clusterBoundaries", "clusterCount", "clusterTextAt"]:
    let n = countCallSites(ta, helper)
    if n < 0:
      echo &"  NOT MEASURED: {helper} call sites — {ta} is absent"
    else:
      echo &"  {helper:<20} {n:>3} call sites in textarea.nim " &
           "(each re-walks the line)"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc runTake(corpus: Corpus; takeNo, rounds: int): (float, float) =
  echo ""
  echo &"-- take {takeNo} --  load {loadAverage()}"
  var seqGateRatio = 0.0
  var ropeGateRatio = 0.0
  for kind in [akEnter, akChar, akLineIndex]:
    let armName =
      case kind
      of akEnter: "Enter (line-splitting)"
      of akChar: "ordinary char insert"
      of akLineIndex: "line index (offsetOf)"
    let gated = kind == akEnter
    block:
      let make = proc(): SeqLineStore = toSeqLineStore(corpus.text)
      let (f, l) = measurePair(make, kind, rounds)
      let r = reportArm("seq[string]", armName, f, l, gated)
      if gated: seqGateRatio = r
    block:
      let make = proc(): TextStore = toTextStore(corpus.text)
      let (f, l) = measurePair(make, kind, rounds)
      let r = reportArm("rope", armName, f, l, gated)
      if gated: ropeGateRatio = r
    echo ""
  (seqGateRatio, ropeGateRatio)

proc main() =
  var sizes = @[1000, 40000, 200000]
  var takes = 2
  var rounds = 25
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--sizes="):
      sizes = @[]
      for part in a[8 .. ^1].split(','):
        sizes.add parseInt(part.strip())
    elif a.startsWith("--takes="):
      takes = parseInt(a[8 .. ^1])
    elif a.startsWith("--rounds="):
      rounds = parseInt(a[9 .. ^1])
    else:
      quit("unknown argument: " & a)

  let root = getCurrentDir()
  if not dirExists(root / "src" / "frontend" / "viewmodel"):
    quit("run from the codetracer repository root; " & root & " is not it")
  let outDir = root / "test-logs" / "plat24"

  echo "PLAT-24 — the text store decision, by measurement"
  echo "================================================="
  echo &"build   : {buildDescription()}"
  echo &"host    : {countProcessors()} processors, load {loadAverage()} at start"
  echo &"gate    : Enter at line 1 / Enter at the last line must be under " &
       &"{int(GateRatio)}x"
  echo &"takes   : {takes}, rounds per take: {rounds}, " &
       &"ops per round: Enter {EnterOpsPerRound}, char {CharOpsPerRound}, " &
       &"index {IndexOpsPerRound}"
  echo &"run at  : {now().format(\"yyyy-MM-dd HH:mm:ss\")}"

  var gateSeq: seq[float] = @[]
  var gateRope: seq[float] = @[]
  var gateSize = 0

  for size in sizes:
    let corpus = buildCorpus(root, size, outDir)
    echo ""
    echo "================================================================"
    echo &"CORPUS {corpus.name}: {corpus.text.len} bytes, " &
         &"{corpus.lines} lines (incl. the trailing empty one), " &
         &"{corpus.fileCount} real files"
    echo &"       fnv1a=0x{corpus.fingerprint:016x}  " &
         &"manifest={corpus.manifestPath.relativePath(root)}"
    echo &"       first line {corpus.firstLineLen} bytes, " &
         &"last non-empty line {corpus.lastLineLen} bytes"
    echo "================================================================"

    for t in 1 .. takes:
      let (sr, rr) = runTake(corpus, t, rounds)
      if size == 200000:
        gateSeq.add sr
        gateRope.add rr
        gateSize = size
      # Deliverables 4 and 5 are inside the take, not after it: PLAT-24 asks
      # for TWO takes of EVERY figure, and a figure taken once beside two
      # takes of its neighbours is the one nobody can check.
      echo "  -- deliverable 4: applyInsert copies the whole line, re-measured --"
      measureLineLengthEffect(corpus, rounds)
      echo "  -- deliverable 4: one seq.insert per inserted line, re-measured --"
      measureMultiLineInsert(corpus, rounds)
      echo "  -- deliverable 5: grapheme segmentation's allocation profile --"
      measureGraphemeProfile(corpus, root, rounds)

  echo ""
  echo "================================================================"
  echo "VERDICT"
  echo "================================================================"
  echo &"load at end: {loadAverage()}"
  if gateSeq.len == 0:
    echo "NO VERDICT: the 200,000-line corpus was not among the sizes run, " &
         "and the gate is stated on that size. Re-run without --sizes."
    quit(2)
  for i in 0 ..< gateSeq.len:
    echo &"take {i + 1}: seq[string] {gateSeq[i]:.2f}x   rope {gateRope[i]:.2f}x"
  let seqWorst = minimum(gateSeq)     # the incumbent's BEST case for itself
  let ropeWorst = maximum(gateRope)   # the candidate's WORST case for itself
  echo ""
  echo &"incumbent seq[string]: best ratio across takes {seqWorst:.2f}x — " &
       (if seqWorst >= GateRatio: "FAILS the gate, in every take"
        else: "PASSES the gate — the gate did not discriminate, READ THE NOTE BELOW")
  echo &"candidate rope       : worst ratio across takes {ropeWorst:.2f}x — " &
       (if ropeWorst < GateRatio: "PASSES the gate, in every take"
        else: "FAILS the gate")
  echo ""
  if seqWorst >= GateRatio and ropeWorst < GateRatio:
    echo "DECISION: the rope. The gate is two-sided and both sides were run " &
         "in this process."
  elif seqWorst < GateRatio:
    echo "DECISION: NOT the rope on this evidence. The incumbent passed the " &
         "gate it was built to fail, which means either the measurement is " &
         "wrong or seq[string] is adequate at this size. Do not adopt a rope " &
         "on a gate that did not discriminate."
  else:
    echo "DECISION: NEITHER. The candidate failed the same gate the " &
         "incumbent did; a candidate that merely fails differently does not " &
         "pass."

main()
