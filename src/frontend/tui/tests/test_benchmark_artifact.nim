## test_benchmark_artifact.nim — CTUI-14.
##
## ## Why this file exists: THE ARTIFACT IS A DELIVERABLE AND NO TEST READ IT
##
## `bench-results/benchmark_results.json` is committed, is what
## `benchmark-action/github-action-benchmark` consumes, and is the only part of
## this milestone that LEAVES the repository as data rather than as code. Until
## this file existed, every defect ever found in it was found by a human
## reading it:
##
##   * `samples=200` — the suite's loop budget — was appended to all twelve
##     entries, including four that are a single observation of a single
##     spawned process. Seven entries claimed a provenance they did not have.
##   * The two rows whose published CONDITION is not satisfied emitted a bare
##     `verdict=met`. The gap was written into `extra`'s prose, where a human
##     finds it and a consumer parsing `verdict=` does not.
##   * `verdict=reported (not gated)` contained a SPACE, so the ordinary
##     whitespace-splitting parse of `extra` read that row's verdict as
##     `reported` and dropped the rest.
##
## Every one of those was downstream of a green suite and none of them could
## redden one: the tests asserted things about the CODE and were silent about
## the thing the code produces. That is the relationship
## `codetracer-specs/Testing/Verification-Harness-Traps.md` describes between a
## test and its harness, one level further out, and
## `metacraft-dev-guidelines/policies/continuous-benchmarking.md` now requires
## a lane test that reads the committed artifact.
##
## ## IT READS THE COMMITTED FILE, ADVERSARIALLY, AND IT DOES NOT SKIP
##
## A missing or unparseable artifact FAILS by name with the recipe that
## regenerates it. There is no `skip()` and no early `return`: a suite that
## detected a missing deliverable and returned early would be counted PASSED,
## which is the defect class
## `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md` catalogues —
## and it would be silent about precisely the file this suite exists to guard.
##
## ## THE EXPECTATIONS COME FROM THE SUITE'S SOURCE, NOT FROM A LIST HERE
##
## The entry names, the number of entries, each entry's `conditionGap` and each
## entry's comparison direction are parsed OUT OF
## `src/frontend/tui/benchmarks/tui_benchmarks.nim`'s own `bench.record(...)`
## call sites and compared with the committed artifact. A hand-kept list in
## this file would go stale the first time a metric is added, and would do so
## silently — the same failure the workflow's split key was written to avoid
## one level up. What this buys is the check nothing else makes: that the
## COMMITTED artifact was produced by the source in the tree beside it.
##
## Because that makes every set comparison depend on a parse succeeding, the
## parse has its own NON-VACUITY FLOOR: a source scan that found nothing would
## otherwise make every comparison below trivially true, which is trap 4 of
## Verification-Harness-Traps arriving in the checker rather than in the thing
## checked.

import std/[json, os, strutils, tables, unittest]

# Declared on ONE line because `ci/lib/run-nim-test-lane.sh` reads exactly that
# spelling; inside a `const` block it is invisible to the lane.
#
# IT MOVES WHEN THE ARTIFACT GROWS, and that is the intended coupling rather
# than a maintenance cost: almost every case below is a sweep over the entries,
# so the total is `26 * len(entries)` plus the fixed cases. Twelve entries were
# 334; the three `tui/ui-flag-*` rows took it to 412. A contributor who adds a
# metric and does not move this number gets a red lane naming both figures,
# which is the only signal that the artifact and the file that reads it have
# been changed together.
const ExpectedAssertions = 412

var countedAssertions = 0

template ck(condition: untyped) =
  ## `check`, counted.
  inc countedAssertions
  check condition

proc repoRoot(): string =
  ## The checkout this test's source lives in.
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

const
  ArtifactRel = "bench-results/benchmark_results.json"
  SuiteRel = "src/frontend/tui/benchmarks/tui_benchmarks.nim"
  BenchRecipe = "just bench"

  ## The CLOSED set of values the `verdict=` field may take. `verdictToken` in
  ## the suite has exactly these five arms; a sixth spelling reaching the
  ## artifact means the two have drifted.
  VerdictTokens = [
    "met",
    "NOT-MET",
    "reported-not-gated",
    "met-CONDITION-NOT-external",
    "met-CONDITION-NOT-internal",
  ]

  ## A source scan finding fewer than this many `bench.record(` calls has not
  ## understood the file, and every set comparison below would pass vacuously.
  ## Eight is §8's own row count, which is the floor the milestone promises
  ## independently of the four extra entries.
  MinRecordCalls = 8

type
  SourceEntry = object
    ## What one `bench.record(...)` call site says about itself.
    name: string
    conditionGap: string     ## `cgNone` | `cgExternal` | `cgInternal`
    smallerIsBetter: bool
    gated: bool
    samplesExpr: string      ## the literal source text after `samples = `

proc between(s, open, close: string; start = 0): string =
  ## The text between the first `open` at or after `start` and the next
  ## `close`. Empty when either is absent.
  let a = s.find(open, start)
  if a < 0:
    return ""
  let b = s.find(close, a + open.len)
  if b < 0:
    return ""
  s[a + open.len ..< b]

proc valueAfter(line, key: string): string =
  ## The comma-terminated token following `key` on one source line, stripped.
  let a = line.find(key)
  if a < 0:
    return ""
  var rest = line[a + key.len .. ^1]
  let comma = rest.find(',')
  if comma >= 0:
    rest = rest[0 ..< comma]
  rest.strip()

proc parseRecordCalls(source: string): seq[SourceEntry] =
  ## Every `bench.record(...)` call site, read out of the suite's own source.
  ##
  ## A call's parameter block runs from its first line to whichever comes
  ## first: the NEXT call, or the next blank line. Both bounds are needed —
  ## three of these calls are followed by another call before their own block
  ## ends, and the last one is followed by unrelated code.
  let lines = source.splitLines()
  var starts: seq[int] = @[]
  for i, line in lines:
    if line.contains("bench.record(\""):
      starts.add i
  for k, s in starts:
    var stop = lines.len
    if k + 1 < starts.len:
      stop = starts[k + 1]
    for j in s + 1 ..< stop:
      if lines[j].strip().len == 0:
        stop = j
        break
    var e = SourceEntry(
      name: between(lines[s], "bench.record(\"", "\""),
      conditionGap: "",
      smallerIsBetter: true,
      gated: true,
      samplesExpr: "")
    for j in s ..< stop:
      let line = lines[j]
      if e.conditionGap.len == 0 and line.contains("conditionGap = "):
        e.conditionGap = valueAfter(line, "conditionGap = ")
      if e.samplesExpr.len == 0 and line.contains("samples = "):
        e.samplesExpr = valueAfter(line, "samples = ")
      if line.contains("smallerIsBetter = false"):
        e.smallerIsBetter = false
      if line.contains("gated = false"):
        e.gated = false
    result.add e

suite "CTUI-14: the committed benchmark artifact":

  let root = repoRoot()
  let artifactPath = root / ArtifactRel
  let suitePath = root / SuiteRel

  test "the artifact and the suite that writes it are both present":
    # Named with the recipe, because "file not found" a hundred lines into a
    # lane is the diagnosis this line exists to skip.
    checkpoint("artifact: " & artifactPath & " (regenerate with `" &
               BenchRecipe & "`)")
    ck fileExists(artifactPath)
    ck fileExists(suitePath)

  test "the source scan is not vacuous":
    # THE FLOOR. Every comparison in the cases below is against a set derived
    # from this parse; a parse that found nothing would make all of them pass.
    let entries = parseRecordCalls(readFile(suitePath))
    checkpoint("record() call sites found: " & $entries.len)
    ck entries.len >= MinRecordCalls
    var named = 0
    var withGap = 0
    for e in entries:
      if e.name.startsWith("tui/"):
        inc named
      if e.conditionGap.len > 0:
        inc withGap
    # Every call site must have yielded a name AND a conditionGap, or the
    # parse understood the shape of some calls and not others.
    ck named == entries.len
    ck withGap == entries.len

  test "the artifact parses as a non-empty array of named entries":
    let doc = parseJson(readFile(artifactPath))
    ck doc.kind == JArray
    ck doc.len > 0
    var names: seq[string] = @[]
    for entry in doc:
      ck entry.kind == JObject
      ck entry.hasKey("name")
      ck entry.hasKey("value")
      ck entry.hasKey("extra")
      ck entry["extra"].kind == JString
      names.add entry["name"].getStr()
    # Duplicate names would silently collapse two series into one chart.
    var seen = initTable[string, int]()
    for n in names:
      seen[n] = seen.getOrDefault(n) + 1
    var duplicated: seq[string] = @[]
    for n, c in seen:
      if c > 1:
        duplicated.add n
    checkpoint("duplicate names: " & duplicated.join(", "))
    ck duplicated.len == 0

  test "the artifact's entries are exactly the suite's record() calls":
    let doc = parseJson(readFile(artifactPath))
    let entries = parseRecordCalls(readFile(suitePath))
    # THE COUNT MATCHES. A metric added to the suite and an artifact never
    # regenerated is the state this asserts against.
    checkpoint("artifact entries: " & $doc.len &
               ", record() call sites: " & $entries.len)
    ck doc.len == entries.len
    var sourceNames: seq[string] = @[]
    for e in entries:
      sourceNames.add e.name
    for entry in doc:
      let n = entry["name"].getStr()
      checkpoint("artifact entry not recorded by the suite: " & n)
      ck n in sourceNames
    var artifactNames: seq[string] = @[]
    for entry in doc:
      artifactNames.add entry["name"].getStr()
    for n in sourceNames:
      checkpoint("suite records an entry the artifact does not carry: " & n)
      ck n in artifactNames

  test "every entry carries a real samples= it could have measured":
    let doc = parseJson(readFile(artifactPath))
    let entries = parseRecordCalls(readFile(suitePath))
    var bySource = initTable[string, SourceEntry]()
    for e in entries:
      bySource[e.name] = e
    var samples: seq[int] = @[]
    for entry in doc:
      let name = entry["name"].getStr()
      let extra = entry["extra"].getStr()
      ck extra.count("samples=") == 1
      let tok = between(extra & " ", "samples=", " ")
      checkpoint(name & " samples=" & tok)
      var n = -1
      try:
        n = parseInt(tok)
      except ValueError:
        n = -1
      ck n >= 1
      samples.add n
      # A call site whose source says `samples = 1` measured ONE thing, and an
      # artifact claiming otherwise for it is the original defect exactly.
      if bySource.hasKey(name) and bySource[name].samplesExpr == "1":
        ck n == 1
    # THE FINGERPRINT OF THE DEFECT THIS FIELD WAS FIXED FOR: one number
    # stamped on every entry. Four of these are one observation of one spawned
    # process and the rest loop on their own constants, so a uniform column
    # means the loop budget is being reported again.
    var distinct1 = 0
    for i, s in samples:
      var first = true
      for j in 0 ..< i:
        if samples[j] == s:
          first = false
      if first:
        inc distinct1
    checkpoint("distinct sample counts across the artifact: " & $distinct1)
    ck distinct1 > 1

  test "every entry says what one sample IS":
    let doc = parseJson(readFile(artifactPath))
    for entry in doc:
      let name = entry["name"].getStr()
      let extra = entry["extra"].getStr()
      ck extra.count("shape=\"") == 1
      let shape = between(extra, "shape=\"", "\"")
      checkpoint(name & " shape=" & shape)
      ck shape.len > 0
      # `shape` answers "what one sample IS" — a spawn, an iteration, a step,
      # a frame. A single word cannot, and "1" least of all.
      ck shape.contains(' ')

  test "verdict= is one whitespace-free token from the closed set":
    let doc = parseJson(readFile(artifactPath))
    for entry in doc:
      let name = entry["name"].getStr()
      let extra = entry["extra"].getStr()
      ck extra.count("verdict=") == 1
      let idx = extra.find("verdict=")
      ck idx >= 0
      # `verdict=` is written LAST, so everything after it is the token. This
      # is the assertion `verdict=reported (not gated)` would have failed: the
      # ordinary whitespace-splitting parse of `extra` read that as `reported`.
      let token = extra[idx + "verdict=".len .. ^1]
      checkpoint(name & " verdict=[" & token & "]")
      ck token.len > 0
      ck not token.contains(' ')
      ck not token.contains('\t')
      ck token in VerdictTokens

  test "a condition gap in the source reaches the machine-readable field":
    let doc = parseJson(readFile(artifactPath))
    let entries = parseRecordCalls(readFile(suitePath))
    var bySource = initTable[string, SourceEntry]()
    for e in entries:
      bySource[e.name] = e
    var gapped = 0
    for entry in doc:
      let name = entry["name"].getStr()
      let extra = entry["extra"].getStr()
      let token = extra[extra.find("verdict=") + "verdict=".len .. ^1]
      ck bySource.hasKey(name)
      let gap = bySource[name].conditionGap
      checkpoint(name & ": source " & gap & ", artifact " & token)
      if gap == "cgNone":
        # THE POSITIVE CLAIM. `cgNone` says the number WAS taken under the
        # condition its target is published for, so no gap may appear.
        ck not token.contains("CONDITION-NOT")
      else:
        inc gapped
        let kind = if gap == "cgExternal": "external" else: "internal"
        ck gap in ["cgExternal", "cgInternal"]
        # A gapped row that met its number must SAY the gap. `met` alone here
        # is the defect: a consumer parsing `verdict=` read a row whose
        # published condition was not satisfied as an unqualified pass.
        ck token in ["NOT-MET", "reported-not-gated",
                     "met-CONDITION-NOT-" & kind]
    # Non-vacuity again: if no call site declares a gap, the branch above
    # asserted nothing at all and this file would be silent about the very
    # defect it was written for.
    checkpoint("entries whose source declares a condition gap: " & $gapped)
    ck gapped >= 1

  test "the split key is unambiguous on every entry":
    # The withdrawn workflow divides this artifact by the `target<=` /
    # `target>=` token before handing each half to a differently-signed
    # comparison. An entry carrying both, or neither, is dropped from or
    # double-counted across the two charts — silently, because the action
    # accepts whatever it is given.
    let doc = parseJson(readFile(artifactPath))
    let entries = parseRecordCalls(readFile(suitePath))
    var bySource = initTable[string, SourceEntry]()
    for e in entries:
      bySource[e.name] = e
    var smaller = 0
    var bigger = 0
    for entry in doc:
      let name = entry["name"].getStr()
      let extra = entry["extra"].getStr()
      let le = extra.contains("target<=")
      let ge = extra.contains("target>=")
      checkpoint(name & ": target<= " & $le & ", target>= " & $ge)
      ck le != ge          # exactly one — never both, never neither
      if le:
        inc smaller
      if ge:
        inc bigger
      # And the direction is the one the call site asked for.
      ck bySource.hasKey(name)
      ck le == bySource[name].smallerIsBetter
    checkpoint("split: " & $smaller & " smaller-is-better, " &
               $bigger & " bigger-is-better, " & $doc.len & " total")
    # The halves partition the whole. This is the workflow's own assertion,
    # asserted here so it fails in a lane rather than in a pipeline nothing
    # currently runs.
    ck smaller + bigger == doc.len
    # BOTH HALVES NON-EMPTY, and the expected size of each comes from the
    # source rather than from a number typed here.
    var sourceBigger = 0
    for e in entries:
      if not e.smallerIsBetter:
        inc sourceBigger
    ck sourceBigger >= 1
    ck bigger == sourceBigger
    ck smaller == doc.len - sourceBigger
    ck smaller >= 1

  test "every entry carries the host it was measured on":
    # The load average is the reason any figure here is readable at all: the
    # same binary on this host measured time-to-debugger at 259.7 ms and at
    # 82.5 ms four minutes apart.
    let doc = parseJson(readFile(artifactPath))
    for entry in doc:
      let extra = entry["extra"].getStr()
      ck extra.count("load1=") == 1
      ck extra.count("cpus=") == 1
      ck extra.count("alert-threshold=") == 1

  test "assertion count":
    # Printed as well as asserted: `ci/lib/run-nim-test-lane.sh` reads a
    # `CHECKS: <n>` line as a RUNTIME assertion count, which is better
    # evidence than the `[OK]` markers it otherwise tallies — unittest prints
    # one of those per test block, including a block that asserted nothing.
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
