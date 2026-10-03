## test_plat35_ledger_integrity.nim — **TIER 3 OVER THE LEDGER ITSELF.**
##
## Run (no shim, no recording, no window — it reads two JSON files):
##   nim c -r --hints:off src/frontend/gpui/tests/test_plat35_ledger_integrity.nim
##
## ## Why this suite exists
##
## `src/tests/visual/tier4-gpui-readings.json` is PLAT-35's tier-4 ledger: two
## iterations of twelve agent readings, fifteen findings with owners, and a
## `gate` block that says whether the milestone's verification gate is met.
## **Nothing in the tree read it.** Measured 2026-10-02:
## `grep -rn tier4-gpui-readings.json` over the whole repository found the
## string in the ledger's own name and in prose, and in NO executable gate —
## while `tier4-review.json`, the ledger beside it, is read and graded in both
## directions by `test_cross_renderer_visual_alignment.nim`. So the GPUI arm
## had a ledger and no gate over it, which is the shape
## `Verification-Harness-Traps.md` §4 is about: a record nothing reads can say
## anything, and the first thing it will say wrong is its own summary.
##
## ## WHAT IS GATED, AND WHAT IS DELIBERATELY NOT
##
## **GATED: the ledger's INTEGRITY.** The `gate` block's two counts are
## RE-DERIVED from `findings` and compared; `met` is checked in BOTH
## directions against those counts; every finding must carry an owner, a
## severity from a closed set and substantial text; the readings must be as
## many as the declared corpus times the declared iterations, per iteration as
## well as in total; and the scenario/view/viewport of every reading is
## checked against `scenarios.json` — a SECOND FILE, so the ledger is measured
## against the corpus declaration rather than against itself (§30's
## two-copies rule: a record cross-checked only against its own fields cannot
## fail).
##
## **AND, SINCE 2026-10-03, THE `resolved` SET.** Until then it was checked
## for nothing but id-disjointness, which the ledger's own `gate.note` had
## already identified as the one edit that lowers both counts and reddens
## nothing: move an entry from `findings` to `resolved` and the gate improves
## for free. A closure now has to carry a closed-set severity, substantial
## text, a `remedy` and a `confirmedBy` — what was changed, and what was
## measured afterwards. See that case for what is deliberately NOT required.
##
## **NOT GATED: any READING'S SCORE, and nothing here quarantines a reading.**
## That is the distinction `tier4-review.json` got wrong in the opposite
## direction and the status note explains: ten of these twelve readings score
## below 4, so a `knownRed` block over them would be a gate holding ten of
## twelve exceptions, i.e. a gate switched off while wearing the shape of one.
## A score is a summary of the findings; the findings carry owners; and what a
## gate can honestly assert about this file is that it is INTERNALLY HONEST —
## that its summary is its contents and its population is the corpus. That is
## what is asserted here.
##
## ## Trap 13 / §29
##
## Every helper that calls `check` is a `template`. The `proc`s return values.

import std/[json, os, sets, strutils, tables, unittest]

const
  LedgerRel = "src/tests/visual/tier4-gpui-readings.json"
  ScenariosRel = "src/tests/visual/scenarios.json"

  Severities = ["P1", "P2", "capture-provenance"]
    ## **THE CLOSED SET, AND IT IS CLOSED ON PURPOSE.** A finding whose
    ## severity is a new spelling — `p1`, `P-1`, `major` — is a finding the
    ## `gate` block's counts cannot see, and it would be counted as neither
    ## unresolved nor resolved. That is the only way this ledger can lose an
    ## entry silently, so the spelling is pinned rather than inferred.

  MinFindingTextLen = 40
    ## Substantial text, and the number is the floor of what is there rather
    ## than a round one: the shortest `finding` in the ledger on 2026-10-02 is
    ## `PLAT35-F5`'s at 52 characters. A floor ABOVE the observed minimum
    ## would be a gate on prose length; a floor of 1 would pass `"x"`.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check(condition)

proc requireFile(rel, why: string): string =
  ## Absent, this suite FAILS BY NAME rather than skipping. A skipped ledger
  ## gate is a ledger with no gate, which is the state this suite exists to
  ## end.
  if not fileExists(rel):
    raise newException(IOError, rel & " is not here. " & why &
      " Run this suite from the repository root.")
  rel

proc expectedScenarioCount(scenarios: JsonNode): int =
  scenarios{"expectedScenarios"}.getInt(-1)

proc scenarioIds(scenarios: JsonNode): HashSet[string] =
  result = initHashSet[string]()
  for s in scenarios{"scenarios"}:
    result.incl s{"id"}.getStr

proc viewByScenario(scenarios: JsonNode): Table[string, string] =
  result = initTable[string, string]()
  for s in scenarios{"scenarios"}:
    result[s{"id"}.getStr] = s{"view"}.getStr

proc viewportByScenario(scenarios: JsonNode): Table[string, string] =
  ## `"<width>x<height>"`, resolved through `scenarios.json`'s OWN viewport
  ## table rather than re-typed here, so a viewport the corpus moves takes
  ## the ledger's rows with it.
  result = initTable[string, string]()
  let ports = scenarios{"viewports"}
  for s in scenarios{"scenarios"}:
    let p = ports{s{"viewport"}.getStr}
    result[s{"id"}.getStr] =
      $p{"width"}.getInt & "x" & $p{"height"}.getInt

proc severityCount(findings: JsonNode; severity: string): int =
  for f in findings:
    if f{"severity"}.getStr == severity:
      inc result

proc flatText(n: JsonNode): string =
  ## A field that is either a string or an array of lines, as one string.
  ## The ledger writes both spellings — `PLAT35-F15.remedy` is a string,
  ## `PLAT35-C1.remedy` is an array — and a check that only understood one of
  ## them would pass an entry by accident of formatting.
  if n.isNil: return ""
  case n.kind
  of JString: n.getStr.strip()
  of JArray:
    var parts: seq[string] = @[]
    for e in n: parts.add flatText(e)
    parts.join(" ").strip()
  else: ""

let ledger = parseJson(readFile(requireFile(LedgerRel,
  "It is PLAT-35's tier-4 ledger, written by the review iterations.")))
let scenarios = parseJson(readFile(requireFile(ScenariosRel,
  "It is the corpus declaration the ledger's population is checked against.")))

let findings = ledger{"findings"}
let iterations = ledger{"iterations"}
let gate = ledger{"gate"}

suite "PLAT-35 tier 3 — the tier-4 ledger's own integrity":

  test "the ledger and the corpus declaration are both readable and non-empty":
    # §4 FIRST, BECAUSE EVERY CASE BELOW IS WRITTEN OVER THESE POPULATIONS.
    # A ledger that parsed to `{}` would satisfy every count equality in this
    # suite by making both sides zero.
    ck findings.kind == JArray
    ck findings.len > 0
    ck iterations.kind == JArray
    ck iterations.len > 0
    ck gate.kind == JObject
    ck ledger{"schemaVersion"}.getInt(-1) == 1
    ck expectedScenarioCount(scenarios) > 0
    echo "  ledger: ", findings.len, " finding(s), ", iterations.len,
         " iteration(s); corpus declares ",
         expectedScenarioCount(scenarios), " scenario(s)"

  test "every finding carries an owner, a closed-set severity and real text":
    var ids = initHashSet[string]()
    for f in findings:
      let id = f{"id"}.getStr
      # An id, and a UNIQUE one: two findings sharing an id are one finding
      # as far as any reader or tracker is concerned, and the severity counts
      # would still add up.
      ck id.len > 0
      ck id notin ids
      ids.incl id
      # THE OWNER IS THE WHOLE POINT OF AN UNGATED LEDGER. The status note's
      # argument for not quarantining these readings is that *"the findings
      # carry owners instead"*; an ownerless finding is that argument's
      # premise withdrawn.
      ck f{"owner"}.getStr.strip().len >= 4
      ck f{"severity"}.getStr in Severities
      ck f{"finding"}.getStr.strip().len >= MinFindingTextLen
    ck ids.len == findings.len

  test "both graded severities are POPULATED, so the counts are not vacuous":
    # Without this, a ledger that spelled every severity `capture-provenance`
    # would report zero unresolved P1 and P2, would satisfy the equality in
    # the next case, and would flip `met` to true — a green gate over a file
    # full of defects. The two-sided version of §4.
    ck severityCount(findings, "P1") > 0
    ck severityCount(findings, "P2") > 0

  test "the gate's counts are the counts DERIVED from the findings":
    let p1 = severityCount(findings, "P1")
    let p2 = severityCount(findings, "P2")
    echo "  derived P1=", p1, " P2=", p2,
         "   declared P1=", gate{"unresolvedP1"}.getInt(-1),
         " P2=", gate{"unresolvedP2"}.getInt(-1)
    ck gate{"unresolvedP1"}.getInt(-1) == p1
    ck gate{"unresolvedP2"}.getInt(-1) == p2
    # A finding listed as resolved AND as unresolved would be counted twice
    # and described twice. The two id sets must be disjoint.
    var resolvedIds = initHashSet[string]()
    for r in ledger{"resolved"}:
      resolvedIds.incl r{"id"}.getStr
    for f in findings:
      ck f{"id"}.getStr notin resolvedIds

  test "every RESOLVED entry carries evidence, not just an id":
    # **THE GAP THIS SUITE WAS FOUND TO HAVE, 2026-10-03, CLOSED.** The ledger
    # said it of itself: *"it checks the shape of the UNRESOLVED set only.
    # `resolved` entries are checked for nothing but id-disjointness — no
    # owner, no closed-set severity, no text floor — so moving an entry from
    # `findings` to `resolved` is the one edit that lowers both counts and
    # reddens nothing."* That is the only way this gate could be satisfied by
    # a deletion dressed as a fix, and the PLAT35-F13 / PLAT35-F14 pass is the
    # first one to move an entry across, so it is the pass that closes it.
    #
    # WHAT IS REQUIRED, AND WHY EACH: a closed-set severity and a text floor,
    # so a closure cannot be a stub; a `remedy`, so the entry says what was
    # changed; and a `confirmedBy`, so it says what was MEASURED afterwards.
    # A closure with a remedy and no confirmation is the shape
    # `Verification-Harness-Traps` §39 is about — an expectation re-recorded
    # without a re-grade.
    #
    # NOT REQUIRED: an `owner`. An unresolved finding needs one because the
    # ungated-score argument rests on it; a closed one has no owner left to
    # name, and none of the five entries closed before today carries one.
    let resolved = ledger{"resolved"}
    # §4: the floor is over a population, so the population is asserted.
    ck resolved.len > 0
    var resolvedIds = initHashSet[string]()
    for r in resolved:
      let id = r{"id"}.getStr
      ck id.len > 0
      ck id notin resolvedIds
      resolvedIds.incl id
      ck r{"severity"}.getStr in Severities
      ck r{"finding"}.getStr.strip().len >= MinFindingTextLen
      ck flatText(r{"remedy"}).len >= MinFindingTextLen
      ck flatText(r{"confirmedBy"}).len >= MinFindingTextLen
    ck resolvedIds.len == resolved.len

  test "gate.met is false IFF those counts are non-zero — both directions":
    let p1 = severityCount(findings, "P1")
    let p2 = severityCount(findings, "P2")
    let shouldBeMet = p1 == 0 and p2 == 0
    # **AN EQUALITY AND NOT AN IMPLICATION.** `met == false` asserted alone is
    # satisfied by a ledger that hard-codes `false` and would stay green for
    # ever after the last finding is closed, which is the one moment this row
    # has to move. `met == shouldBeMet` is red in both directions.
    ck gate{"met"}.getBool(not shouldBeMet) == shouldBeMet
    ck gate{"rule"}.getStr.len > 0

  test "the readings are the declared corpus times the declared iterations":
    let expected = expectedScenarioCount(scenarios)
    var total = 0
    let ids = scenarioIds(scenarios)
    let views = viewByScenario(scenarios)
    let ports = viewportByScenario(scenarios)
    for it in iterations:
      let readings = it{"readings"}
      ck readings.kind == JArray
      # PER ITERATION AND NOT ONLY IN TOTAL: one iteration of 12 and one of 0
      # multiplies out to the same product, and is a review iteration that
      # graded the previous iteration's images.
      ck readings.len == expected
      var seen = initHashSet[string]()
      for r in readings:
        let sid = r{"scenario"}.getStr
        ck sid in ids
        # EACH SCENARIO ONCE PER ITERATION. Six readings of one frame also
        # multiply out correctly.
        ck sid notin seen
        seen.incl sid
        # AGAINST `scenarios.json`, NOT AGAINST THE LEDGER'S OTHER FIELDS:
        # the view and the viewport a reading claims must be the ones the
        # corpus declares for that scenario.
        ck r{"view"}.getStr == views[sid]
        ck r{"viewport"}.getStr == ports[sid]
        inc total
      ck seen.len == expected
    echo "  readings: ", total, " = ", expected, " x ", iterations.len
    ck total == expected * iterations.len

  test "every case ran":
    # **AN EXACT EQUALITY AGAINST A FORMULA, NOT AGAINST A CONSTANT.**
    # `test_gpui_window_frame.nim` carries an `ExpectedAssertions` literal and
    # pays for it: every file added under `src/frontend/gpui/` moves the
    # number and somebody has to prove the move is structural (which PLAT-35
    # did, 605 -> 615, for `host/pixel_capture.nim`). Here the whole count is
    # a function of the two POPULATIONS, so it is written as that function and
    # never needs bumping:
    #
    #   18                     the fixed assertions in the seven cases
    #   + 6 x findings         5 per finding in *"every finding carries…"*
    #                          plus 1 per finding in the resolved-disjoint loop
    #   + 6 x resolved         6 per entry in *"every RESOLVED entry carries
    #                          evidence"* (id, uniqueness, severity, finding,
    #                          remedy, confirmedBy)
    #   + iterations x (3 + 4 x scenarios)
    #                          2 + 1 fixed per iteration, 4 per reading
    #
    # A review iteration that adds a finding or an iteration therefore keeps
    # this green, and a CASE THAT STOPS RUNNING still reddens it — which is
    # the only thing the number is for. A floor would have lost the second
    # property; a literal would have lost the first.
    let expected = expectedScenarioCount(scenarios)
    let derived = 18 + 6 * findings.len + 6 * ledger{"resolved"}.len +
                  iterations.len * (3 + 4 * expected)
    # `ck` INCREMENTS AND THEN CHECKS, so the echo goes AFTER it or it prints
    # one less than the number being compared — which is exactly the kind of
    # off-by-one that makes a printed tally disagree with a green tick and
    # sends the next reader looking for a missing assertion.
    ck countedAssertions == derived
    echo "PLAT-35 ledger-integrity checks: ", countedAssertions,
         " (derived ", derived, " from ", findings.len, " finding(s), ",
         ledger{"resolved"}.len, " resolved, ",
         iterations.len, " iteration(s) x ", expected, " scenario(s))"
