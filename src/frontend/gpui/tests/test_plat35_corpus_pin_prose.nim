## test_plat35_corpus_pin_prose.nim — **THE PIN'S PROSE AGAINST THE SCENARIO IT PINS.**
##
## Run (no shim, no recording, no window — it reads two JSON files):
##   nim c -r --hints:off src/frontend/gpui/tests/test_plat35_corpus_pin_prose.nim
##
## ## Why this suite exists
##
## `src/tests/visual/corpus-pins.json` pins the numbers each corpus scenario
## lands on (the stopped line, the pane census, the editor rows), and every
## pinned scenario carries a `_why` saying how it got there: "Six step-ins.",
## "Six step-ins and three nexts", "Twenty-one step-ins reach `evaluate`".
## Those counts are claims about `src/tests/visual/scenarios.json`, and
## **nothing compared them with it.**
##
## The defect that made this matter: on 2026-10-04 `scenarios.json` cut
## `stepped-editor`, `advanced-state` and `breakpoint-editor` from six
## `stepIn`s to five, because the engine began opening a recording at the
## program's entry call (tick 1, line 1) instead of on the `<toplevel>` root's
## synthetic entry at tick 0, so the step that used to leave the root was no
## longer taken. The numeric pins (44 / 56 / 44) were right before and after —
## five steps from tick 1 reach the same tick 6 that six steps from tick 0 did —
## and were re-measured on both front-ends on 2026-10-12. But the three `_why`
## strings kept saying **six**, so the pin file contradicted the scenario it
## pins, in the one artefact a reviewer reads to learn what a pin means. A
## review then declared the file "always right", because the numbers were;
## the prose was the part nobody's gate looked at.
##
## ## WHAT IS GATED, AND WHAT IS DELIBERATELY NOT
##
## **GATED:** every operation-count claim of the shape `<count> step-ins`,
## `<count> stepIns` or `<count> nexts` (singular forms too) in any `_why*`
## field of a pin entry. `<count>` is digits or an English number word,
## case-insensitive, compounds included (`Twenty-one`, `twenty one`). Each
## claim must equal the TOTAL `times` of that kind across the scenario's
## `operations` in `scenarios.json` — a SECOND FILE, so the prose is measured
## against the declaration rather than against itself.
##
## **AND THE PARSER ITSELF.** A claim extractor that matches nothing passes
## every comparison vacuously, so there is a unit case over literal strings,
## a positive control that `returned-calltrace`'s prose yields 21, and a floor
## on the number of claims found across the whole file.
##
## **NOT GATED:** prose that describes operation counts in any other shape
## ("five steps in", "step 17 enters", "stepped in six times"), and
## `scenarios.json`'s own `why`
## fields. The latter deliberately describe OTHER scenarios at times —
## `unstepped-breakpoint`'s says "five stepIns put the first drawn row at 31"
## about `breakpoint-editor` — so a per-scenario comparison over them would
## be wrong by construction. Nor is any dated historical ledger read here:
## those record what was measured then and must not be rewritten.
##
## **A consequence for whoever edits the prose:** a PAST count written in the
## gated shape ("measured with six step-ins") is read as a claim about the
## scenario as it is now, and reddens this. Write history in another shape —
## `stepped-editor`'s `_why` says the 2026-09-21 run was taken "when the
## scenario stepped in six times" — so that the gated shape always means the
## current declaration.
##
## ## Trap 13 / §29
##
## Every helper that calls `check` is a `template`. The `proc`s return values.

import std/[json, os, sets, strutils, unittest]

const
  PinsRel = "src/tests/visual/corpus-pins.json"
  ScenariosRel = "src/tests/visual/scenarios.json"

  MinClaimedPairs = 5
    ## The floor is what is there, not a round number, and it is counted in
    ## distinct (scenario, kind) PAIRS rather than in sentences, so restating
    ## a count in a second sentence neither raises nor satisfies it. On
    ## 2026-10-25 the pin file claims five: `stepIn` for `stepped-editor`,
    ## `advanced-state`, `returned-calltrace` and `breakpoint-editor`, and
    ## `next` for `advanced-state`. Rewording one into a shape the parser does not read
    ## lowers the count and reddens this; adding one keeps it green.

  Units = ["zero", "one", "two", "three", "four", "five", "six", "seven",
           "eight", "nine", "ten", "eleven", "twelve", "thirteen",
           "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
           "nineteen"]
  Tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
          "eighty", "ninety"]

type
  CountClaim* = object
    kind*: string    ## The `scenarios.json` operation kind: `stepIn` or `next`.
    count*: int
    phrase*: string  ## The words the count was read from, for messages.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check(condition)

proc requireFile(rel, why: string): string =
  ## Absent, this suite FAILS BY NAME rather than skipping. A skipped prose
  ## gate is prose with no gate, which is the state this suite exists to end.
  if not fileExists(rel):
    raise newException(IOError, rel & " is not here. " & why &
      " Run this suite from the repository root.")
  rel

proc unitValue(w: string): int =
  Units.find(w)

proc tensValue(w: string): int =
  let i = Tens.find(w)
  if i >= 2: i * 10 else: -1

proc parseCount*(word: string): int =
  ## A count written as digits or as an English number word below one
  ## hundred, including a hyphenated compound (`twenty-one`). Returns -1 for
  ## anything else, so a non-number before `step-ins` is not a claim.
  let w = word.toLowerAscii
  if w.len == 0: return -1
  if w.allCharsInSet(Digits):
    return parseInt(w)
  let u = unitValue(w)
  if u >= 0: return u
  let t = tensValue(w)
  if t >= 0: return t
  let parts = w.split('-')
  if parts.len == 2:
    let tp = tensValue(parts[0])
    let up = unitValue(parts[1])
    if tp >= 0 and up in 1..9:
      return tp + up
  -1

proc kindOf(word: string): string =
  ## The operation kind a counted noun names, or "" when it names none.
  case word.toLowerAscii
  of "step-in", "step-ins", "stepin", "stepins": "stepIn"
  of "next", "nexts": "next"
  else: ""

proc tokens(text: string): seq[string] =
  ## Runs of letters, digits and hyphens. Punctuation and backticks split,
  ## so "Six step-ins." yields `Six`, `step-ins`, and "`stepIn`s" yields
  ## `stepIn`, `s`. Edge hyphens (an em-dash spelt `--`) are stripped.
  var cur = ""
  for c in text:
    if c.isAlphaNumeric or c == '-':
      cur.add c
    else:
      if cur.strip(chars = {'-'}).len > 0:
        result.add cur.strip(chars = {'-'})
      cur = ""
  if cur.strip(chars = {'-'}).len > 0:
    result.add cur.strip(chars = {'-'})

proc extractClaims*(text: string): seq[CountClaim] =
  ## Every `<count> <kind>` pair in `text`. A two-word compound
  ## (`twenty one step-ins`) is read whole, so it cannot be mistaken for a
  ## claim of one.
  let toks = tokens(text)
  for i in 1 ..< toks.len:
    let kind = kindOf(toks[i])
    if kind.len == 0: continue
    var n = parseCount(toks[i - 1])
    if n < 0: continue
    var phrase = toks[i - 1] & " " & toks[i]
    if i >= 2 and n in 1..9:
      let t = tensValue(toks[i - 2].toLowerAscii)
      if t >= 0:
        n += t
        phrase = toks[i - 2] & " " & phrase
    result.add CountClaim(kind: kind, count: n, phrase: phrase)

proc flatText(n: JsonNode): string =
  ## A field that is either a string or an array of lines, as one string.
  if n.isNil: return ""
  case n.kind
  of JString: n.getStr
  of JArray:
    var parts: seq[string] = @[]
    for e in n: parts.add flatText(e)
    parts.join(" ")
  else: ""

proc proseClaims(pin: JsonNode): seq[(string, CountClaim)] =
  ## Claims from every `_why*` field of one pin entry, tagged with the field.
  for key, val in pin:
    if key.startsWith("_why"):
      for c in extractClaims(flatText(val)):
        result.add((key, c))

proc operationTotal(scenario: JsonNode; kind: string): int =
  ## The total `times` of `kind` across the scenario's operations. An
  ## operation that omits `times` is one operation.
  for op in scenario{"operations"}:
    if op{"kind"}.getStr == kind:
      result += op{"times"}.getInt(1)

let pins = parseJson(readFile(requireFile(PinsRel,
  "It is PLAT-35's pinned corpus, whose prose this suite checks.")))
let scenarios = parseJson(readFile(requireFile(ScenariosRel,
  "It is the corpus declaration the prose is checked against.")))

let pinned = pins{"scenarios"}

proc corpusEntries(): seq[JsonNode] =
  ## The scenarios AND the GPUI probes: a probe has no pin entry today, but
  ## one given an entry later is checked without editing this suite.
  for s in scenarios{"scenarios"}: result.add s
  if scenarios{"gpuiProbes"} != nil:
    for p in scenarios{"gpuiProbes"}: result.add p

var claimsFound = 0
var claimedPairs = initHashSet[string]()

suite "PLAT-35 — corpus-pins prose agrees with scenarios.json":

  test "the parser reads the claim shapes it is meant to, and no others":
    # Literal strings, so a regression in the parser is told apart from a
    # change in the files.
    ck parseCount("Six") == 6
    ck parseCount("twenty-one") == 21
    ck parseCount("Forty") == 40
    ck parseCount("17") == 17
    ck parseCount("the") == -1
    ck parseCount("twenty-ten") == -1

    let a = extractClaims("Six step-ins and three nexts: 44 -> 54.")
    ck a.len == 2
    ck a[0].kind == "stepIn"
    ck a[0].count == 6
    ck a[1].kind == "next"
    ck a[1].count == 3

    let b = extractClaims("Twenty-one step-ins reach it; twenty one stepIns too.")
    ck b.len == 2
    ck b[0].count == 21
    ck b[1].count == 21
    ck b[1].kind == "stepIn"

    let c = extractClaims("five `stepIn`s, 2 nexts, one step-in, ONE NEXT")
    ck c.len == 4
    ck c[0].count == 5
    ck c[1].count == 2
    ck c[2].count == 1
    ck c[3].kind == "next"

    # Not claims: no number before the noun, or a noun that is not a kind.
    ck extractClaims("so step-ins 1..16 never leave; step 17 enters `main`").len == 0
    ck extractClaims("the NEXT step, five steps in").len == 0

  test "both files are readable and every scenario has a pin entry":
    # §4 FIRST: an empty `scenarios` object would make every case below
    # vacuous.
    ck pinned.kind == JObject
    ck pinned.len == pins{"expectedPinnedScenarios"}.getInt(-1)
    ck scenarios{"scenarios"}.len > 0
    for s in scenarios{"scenarios"}:
      checkpoint "scenario " & s{"id"}.getStr & " has no corpus-pins entry"
      ck pinned.hasKey(s{"id"}.getStr)

  test "positive control: returned-calltrace's prose yields its 21 step-ins":
    # If the parser stopped reading compounds, every comparison below would
    # still be green over the claims it did read. This is the one claim in
    # the file a single-word parser cannot see.
    let claims = proseClaims(pinned{"returned-calltrace"})
    var found = -1
    for (_, c) in claims:
      if c.kind == "stepIn": found = c.count
    ck found == 21

  test "every count claim in a pin's prose equals the scenario's operations":
    for s in corpusEntries():
      let sid = s{"id"}.getStr
      if not pinned.hasKey(sid): continue
      for (field, c) in proseClaims(pinned{sid}):
        inc claimsFound
        claimedPairs.incl sid & "/" & c.kind
        let claimed = c.count
        let actual = operationTotal(s, c.kind)
        # Printed only on a mismatch: a `checkpoint` would accumulate over
        # the loop and print every PASSING claim beside the failing one.
        if claimed != actual:
          echo "    MISMATCH: corpus-pins.json scenarios.", sid, ".", field,
               " claims \"", c.phrase, "\" (", claimed, " ", c.kind,
               ") but scenarios.json `", sid, "` declares ", actual, " ",
               c.kind
        ck claimed == actual
    echo "  count claims found in corpus-pins prose: ", claimsFound,
         " over ", claimedPairs.len, " (scenario, kind) pair(s)"

  test "the parser found the claims the file carries":
    # Against the floor, so a parser — or a rewording — that reads nothing
    # cannot pass the case above vacuously.
    ck claimedPairs.len >= MinClaimedPairs

  test "every case ran":
    # 22 fixed in the parser case, 3 + scenarios in the readability case,
    # 1 in the control, 1 per claim, 1 in the floor case, and this one (`ck`
    # increments before it compares).
    let derived = 22 + 3 + scenarios{"scenarios"}.len + 1 + claimsFound + 1 + 1
    ck countedAssertions == derived
    echo "PLAT-35 corpus-pin prose checks: ", countedAssertions,
         " (derived ", derived, " from ", claimsFound, " claim(s))"
