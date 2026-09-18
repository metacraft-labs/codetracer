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
import ../tests/corpus/unicode_corpus
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
  # PART OF THE INSTRUMENT WAS IN THE TIMED REGION, and the fix is one word.
  #
  # `sample` above is a `var seq[string]`, and `for line in sample` over a
  # MUTABLE seq yields each element BY VALUE — one string copy per line, inside
  # every timed block. Rebinding to a `let` makes the iteration borrow.
  #
  # MEASURED, not assumed, 2026-09-18 in one process at load 31: variant (c)
  # moves from 144.6 to 117.0 ns/line and the published ratio from 20.1x to
  # 23.0x. So the copy is real and worth removing, and it is NOT the whole of
  # the 2x gap between this arm and `measureCorpusGraphemeProfile`'s arm over
  # the same bytes — the rest is heap layout, and that is recorded at the top
  # of that proc rather than left as a 2x nobody explained.
  let lines = sample

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
      for line in lines:
        for _ in graphemeClusters(line):
          inc c
      segTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
      clusters = c
    block:
      var c = 0
      let t0 = getMonoTime()
      for line in lines:
        var buf: seq[int32] = @[]
        for rn in runes(line): buf.add int32(rn)
        for _ in graphemeClusters(buf):
          inc c
      noStrTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
    block:
      var c = 0
      let t0 = getMonoTime()
      for line in lines:
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
# §4.5 RE-MEASURED ON CLUSTER-DENSE TEXT — PLAT-24 deliverable 6's consequence
# ---------------------------------------------------------------------------
#
# §4.5's first figures were taken on the SAME path-sorted `.nim` corpus as the
# storage arms: 88,000 bytes carrying 87,786 runes, i.e. **99.8% ASCII**, with
# one cluster per rune. That is a profile of segmenting ASCII-dominant source.
# It is not wrong and it is not useless — it is the CHEAPEST possible input, so
# the 18.1x it reports is a lower bound and the DIRECTION of the byte-offset
# `column` decision follows from it. What it cannot say is the MAGNITUDE on the
# text the model will actually meet, and the corpus (§5) exists to supply that.
#
# THE TWO ARMS ARE MEASURED IN THE SAME ROUND, ADJACENT IN TIME, for the same
# reason the storage gate's two positions are: on a shared runner an absolute
# nanosecond figure is a measurement of the scheduler, and a ratio between two
# things measured back to back is not. Every headline below is a ratio.
#
# AND THE TWO SAMPLES ARE BUILT BY ONE FUNCTION, WHICH IS LOAD-BEARING.
# `sampleLines` produces both, from a `string`, with the source document freed
# before anything is timed. That is not tidiness either. Running this arm
# beside the older `measureGraphemeProfile` in one process shows the two
# disagreeing about ASCII by ~2x — (a) agrees within noise (2,690 against
# 2,675 ns/line) and (c) does not (117.0 against 55.2) — and the reason is that
# the older arm holds an 8 MB `SeqLineStore` alive while it measures, so its
# 1,827 sample lines are scattered across a live heap and every line costs a
# cache miss. At 2,700 ns/line variant (a) cannot see one; at 55 ns/line
# variant (c) is made of them.
#
# THE CONSEQUENCE, STATED SO IT IS NOT REDISCOVERED: the (a)/(c) RATIO on ASCII
# is not pinned by this instrument to better than about 2x, because its
# denominator is the size of a cache miss. §4.5's published 18.1x is a LOWER
# BOUND. The quantity this re-measurement exists to produce is not that ratio —
# it is the ASCII-against-corpus comparison, and THAT one is sound, because
# both sides go through one function over two samples built the same way,
# adjacent in time, in two takes.
#
# THE UNIT IS PER RUNE, NOT PER LINE. A line of the ASCII corpus and a line of
# the ZWJ corpus are not the same quantity of work, so ns/line compares two
# different things and reports the difference as a speed. `graphemeClusters`
# decodes every rune and builds three `seq`s sized by the rune count, so the
# rune is the unit its cost is linear in — and the per-line figure is printed
# beside it, because §4.5's published number is per line and a re-measurement
# that changed the unit without saying so would be unreadable against it.

proc sampleLines(text: string; want: int): seq[string] =
  ## Non-empty lines, evenly spread through the document.
  result = @[]
  var all: seq[string] = @[]
  for line in text.split('\n'):
    if line.len > 0: all.add line
  if all.len == 0: return
  let step = max(1, all.len div want)
  var i = 0
  while i < all.len and result.len < want:
    result.add all[i]
    i += step

type SegProfile = object
  lines, bytes, runes, clusters: int
  segNs, noStrNs, runeNs: float      ## medians, ns per LINE

proc profileOf(sample: seq[string]; rounds: int): SegProfile =
  ## THE SAME THREE VARIANTS, IN THE SAME ORDER, AS `measureGraphemeProfile`,
  ## so the two arms differ in their INPUT and in nothing else.
  ##
  ## Variant (b) was first suspected of the gap between the two arms and
  ## measured: adding it here changed the ASCII ratio from 45x to 47x, i.e. not
  ## at all. It stays because matching the published body is the point, not
  ## because it explained anything — the hypothesis is recorded as tested and
  ## wrong rather than deleted, since the next reader will have it too.
  ##
  ##   (a) `graphemeClusters(string)` — what `textarea.nim` calls: three `seq`s
  ##       before the first yield, plus a fresh substring PER CLUSTER;
  ##   (b) the same UAX #29 work over a pre-decoded `seq[int32]` — same buffer,
  ##       no per-cluster substring;
  ##   (c) a plain `runes` walk — same decoding, no buffer, no break logic.
  var segTimes: seq[float] = @[]
  var noStrTimes: seq[float] = @[]
  var runeTimes: seq[float] = @[]
  for r in 0 ..< rounds:
    var c = 0
    block:
      let t0 = getMonoTime()
      for line in sample:
        for _ in graphemeClusters(line): inc c
      segTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
    result.clusters = c
    block:
      var k = 0
      let t0 = getMonoTime()
      for line in sample:
        var buf: seq[int32] = @[]
        for rn in runes(line): buf.add int32(rn)
        for _ in graphemeClusters(buf): inc k
      noStrTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
    var n = 0
    block:
      let t0 = getMonoTime()
      for line in sample:
        for _ in runes(line): inc n
      runeTimes.add float((getMonoTime() - t0).inNanoseconds) / float(sample.len)
    result.runes = n
  result.lines = sample.len
  result.bytes = 0
  for line in sample: result.bytes += line.len
  result.segNs = median(segTimes)
  result.noStrNs = median(noStrTimes)
  result.runeNs = median(runeTimes)

proc measureCorpusGraphemeProfile(corpus: Corpus; rounds: int) =
  ## The re-measurement. Prints the ASCII arm and the cluster-dense arm side by
  ## side, both taken in this process at this load, and the per-document
  ## distribution the deliverable asks for ("a distribution rather than one
  ## number from whichever file was open").
  const Want = 2000
  let asciiSample = sampleLines(corpus.text, Want)
  var corpusText = ""
  for d in CorpusDocs:
    corpusText.add d.text
    corpusText.add '\n'
  let denseSample = sampleLines(corpusText, Want)
  if asciiSample.len == 0 or denseSample.len == 0:
    echo "  NOT MEASURED: a sample came back empty"
    return

  # Interleaved: one round of ASCII, one round of cluster-dense, alternating,
  # so a scheduler excursion lands on both sides of the division.
  var asciiSeg: seq[float] = @[]
  var asciiNoStr: seq[float] = @[]
  var asciiRune: seq[float] = @[]
  var denseSeg: seq[float] = @[]
  var denseNoStr: seq[float] = @[]
  var denseRune: seq[float] = @[]
  var asciiRunes = 0
  var asciiClusters = 0
  var denseRunes = 0
  var denseClusters = 0
  for r in 0 ..< rounds:
    let a = profileOf(asciiSample, 1)
    let d = profileOf(denseSample, 1)
    asciiSeg.add a.segNs
    asciiNoStr.add a.noStrNs
    asciiRune.add a.runeNs
    denseSeg.add d.segNs
    denseNoStr.add d.noStrNs
    denseRune.add d.runeNs
    asciiRunes = a.runes
    asciiClusters = a.clusters
    denseRunes = d.runes
    denseClusters = d.clusters

  # DIAGNOSTIC, and it is here rather than in a scratch file because the
  # discrepancy it settles would otherwise go into the record as a 2x nobody
  # explained. The same `profileOf` over the same ASCII sample, run 25 rounds
  # BACK TO BACK instead of alternating with the corpus arm: if this matches
  # the interleaved figure the difference is the sample or the proc, and if it
  # matches `measureGraphemeProfile` the difference is the interleaving.
  let asciiSolo = profileOf(asciiSample, rounds)
  let denseSolo = profileOf(denseSample, rounds)

  let aSeg = median(asciiSeg)
  let aNoStr = median(asciiNoStr)
  let aRune = median(asciiRune)
  let dSeg = median(denseSeg)
  let dNoStr = median(denseNoStr)
  let dRune = median(denseRune)
  let aPerRune = aSeg * float(asciiSample.len) / float(asciiRunes)
  let dPerRune = dSeg * float(denseSample.len) / float(denseRunes)

  echo &"  ASCII arm  : {asciiSample.len} real `.nim` lines, " &
       &"{asciiRunes} runes, {asciiClusters} clusters " &
       &"({float(asciiRunes) / float(asciiClusters):.3f} runes/cluster)"
  echo &"  Corpus arm : {denseSample.len} corpus lines, " &
       &"{denseRunes} runes, {denseClusters} clusters " &
       &"({float(denseRunes) / float(denseClusters):.3f} runes/cluster)"
  echo &"  (a) graphemeClusters   ASCII {aSeg:>9.1f} ns/line  " &
       &"corpus {dSeg:>9.1f} ns/line"
  echo &"      per rune           ASCII {aPerRune:>9.2f} ns/rune  " &
       &"corpus {dPerRune:>9.2f} ns/rune"
  echo &"  (b) no cluster string  ASCII {aNoStr:>9.1f} ns/line  " &
       &"corpus {dNoStr:>9.1f} ns/line"
  echo &"  (c) plain rune walk    ASCII {aRune:>9.1f} ns/line  " &
       &"corpus {dRune:>9.1f} ns/line"
  echo &"  RATIO (a)/(c)          ASCII {aSeg / aRune:>9.2f}x        " &
       &"corpus {dSeg / dRune:>9.2f}x"
  echo &"  the magnitude the corpus was built to supply: segmentation costs " &
       &"{dPerRune / aPerRune:.2f}x as much PER RUNE on cluster-dense text " &
       &"as on 99.8%-ASCII source"
  echo &"  buffers before the first yield: ASCII " &
       &"~{asciiRunes * 20 div asciiSample.len} B/line, corpus " &
       &"~{denseRunes * 20 div denseSample.len} B/line " &
       &"(seq[int32] runes + two seq[int] byte-offset arrays)"

  echo &"  SOLO (25 rounds back to back, not interleaved):  " &
       &"ASCII (a) {asciiSolo.segNs:.1f} ns/line (c) {asciiSolo.runeNs:.1f} " &
       &"= {asciiSolo.segNs / asciiSolo.runeNs:.2f}x   " &
       &"corpus (a) {denseSolo.segNs:.1f} (c) {denseSolo.runeNs:.1f} " &
       &"= {denseSolo.segNs / denseSolo.runeNs:.2f}x"
  echo &"  SOLO per rune: ASCII " &
       &"{asciiSolo.segNs * float(asciiSolo.lines) / float(asciiSolo.runes):.2f}" &
       &" ns/rune, corpus " &
       &"{denseSolo.segNs * float(denseSolo.lines) / float(denseSolo.runes):.2f}" &
       &" ns/rune"

  # THE DISTRIBUTION, per document. One number from whichever file was open is
  # what this deliverable exists to replace.
  echo "  -- per document, (a)/(c), fewer rounds per document --"
  let perDocRounds = max(3, rounds div 5)
  var worst = 0.0
  var best = 1e18
  for d in CorpusDocs:
    let s = sampleLines(d.text, 400)
    if s.len == 0:
      echo &"  {d.id:<26} NOT MEASURED: no non-empty lines"
      continue
    let p = profileOf(s, perDocRounds)
    let ratio = p.segNs / p.runeNs
    let perRune = p.segNs * float(p.lines) / float(p.runes)
    if ratio > worst: worst = ratio
    if ratio < best: best = ratio
    echo &"  {d.id:<26} {p.lines:>4}L {p.runes:>6}r {p.clusters:>6}c  " &
         &"{p.segNs:>9.1f} ns/line  {perRune:>7.2f} ns/rune  {ratio:>7.2f}x"
  echo &"  across the eighteen: (a)/(c) from {best:.2f}x to {worst:.2f}x"

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
  var graphemeOnly = false
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a == "--grapheme-only":
      # §4.5 alone: the storage arms are unchanged and re-running them to reach
      # the segmentation figures would spend an hour to re-print numbers the
      # milestone already carries.
      graphemeOnly = true
    elif a.startsWith("--sizes="):
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
      if not graphemeOnly:
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
      echo ""
      echo &"-- take {t} --  load {loadAverage()}"
      echo "  -- deliverable 5: grapheme segmentation's allocation profile --"
      measureGraphemeProfile(corpus, root, rounds)
      echo "  -- deliverable 6's consequence: §4.5 RE-MEASURED on the corpus --"
      measureCorpusGraphemeProfile(corpus, rounds)

  echo ""
  echo "================================================================"
  echo "VERDICT"
  echo "================================================================"
  echo &"load at end: {loadAverage()}"
  if graphemeOnly:
    echo "NO STORAGE VERDICT: --grapheme-only was passed, so the gate's arms " &
         "were not run. The storage decision is unchanged and its numbers are " &
         "in Editor-ViewModel.md §4.3."
    quit(0)
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
