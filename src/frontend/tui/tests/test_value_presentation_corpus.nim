## test_value_presentation_corpus.nim — PLAT-2's real-stack half.
##
## ## WHAT THIS ADDS THAT A CONSTRUCTED VALUE CANNOT
##
## `src/common/value_presentation_test.nim` and
## `src/common/value_presentation_bridge_test.nim` assert the presenter's rules
## over values this file writes out. That is necessary — they reach kinds no
## recorder in this workspace produces — and it is not sufficient, because
## every one of those values was written by the same person who wrote the
## expectation. A recording was not.
##
## So this suite opens the DECLARED FIXTURE CORPUS through a REAL
## `replay-server`, over containers real recorders produced, and asserts the
## properties PLAT-2's "real-stack integration tests" name, on values nobody
## here chose:
##
##   1. **The same value renders consistently across every surface, differing
##      only by the budget each declares.** Asserted per variable, per fixture:
##      the renderings are compared to each other and their differences are
##      required to be budget differences (a prefix relationship under a cells
##      bound, an elision under a member cap) rather than arbitrary.
##   2. **Presentation is pure — byte-identical across runs.** Two SEPARATE
##      sessions are opened against the same trace, stepped to the same place,
##      and every variable's rendering is compared between them. Two processes'
##      worth of allocation, hashing and iteration order, one answer.
##   3. **A user can ask which presenter rendered a value and get an answer.**
##      `describeAttribution` is required to name a presenter and a budget for
##      every recorded value in the corpus.
##   4. **The renderings are the RIGHT ones**, not merely stable ones. See the
##      section immediately below: this arm was missing, and its absence made
##      every count above meaningless as evidence of correctness.
##
## ## WHAT ARMS 1-3 DO NOT ESTABLISH, AND HOW THAT WAS MEASURED
##
## Arms 1, 2 and 3 are SELF-COMPARISONS. Every one of them has the presenter on
## both sides of the `==`: `present(a, b) == present(a', b)`,
## `unbounded.startsWith(bounded)`, `class == class`. A self-comparison is
## satisfied by any implementation that is merely CONSISTENT — including a
## broken one, including an empty one — which is exactly the trap
## `codetracer-specs/Testing/Verification-Harness-Traps.md` records under
## "a check that cannot fail".
##
## That was not a theoretical worry. Two mutations were applied to the
## presenter and this suite stayed FULLY GREEN at 16 650 checks over 978 real
## values for both of them:
##
##   * M1 — `presenter.inlineText` returning `""` for every value. Every
##     surface renders nothing; the corpus reports success.
##   * M3 — the sequence delimiter changed from `@[` to `<<`. Every sequence in
##     the product renders wrongly; the corpus reports success.
##
## Neither is subtle and neither was caught, because nothing here wrote down
## what a value SHOULD render as. Two arms were added and both mutations now
## redden this file:
##
##   * A NON-EMPTY FLOOR over every value at every budget (`ck
##     text.len > 0`), which is the arm `value_presentation_bridge_test.nim`
##     already carried and this file did not. It kills M1.
##   * AN INDEPENDENT ORACLE — `suite "PLAT-2: the renderings, written down"`
##     below — a table of values whose expected rendering is a LITERAL STRING
##     in this file, derived from the milestone and from the recorders' own
##     conventions rather than from the presenter. It kills M3, and it kills
##     M1 a second time from a different direction.
##   * A SCALAR IDENTITY assertion on the REAL corpus values, which is the one
##     correctness statement that can be made about a value nobody wrote down:
##     an integer, float or boolean renders as the payload the ADAPTER decoded
##     (`a.text`, which the presenter did not produce), and a string renders as
##     that payload in quotes. It kills both mutations on recorded data rather
##     than on constructed data.
##
## The determinism arms are KEPT. Purity across two processes is a real
## property and nothing else asserts it. What changed is that this file no
## longer reports determinism as if it were correctness — and neither does
## PLAT-2, whose deliverable still reads "renders consistently".
##
## ## NO MOCKS
##
## Metacraft policy and PLAT-2's own "Real-stack integration tests (no mocks)":
## real containers from real recorders, driven by a real `replay-server` over
## DAP. No mock appears in this file and none is justified.
##
## ## THE THREE OUTCOMES, AND WHY AN ALL-SKIPPED RUN FAILS
##
## Per `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md`, a test
## that detects a missing prerequisite, returns early and is counted as PASSED
## is a lie. This suite reports the same three outcomes
## `test_fixture_corpus.nim` does — verified, a counted `MISSING-PREREQ SKIP:`,
## or failed — and its last case asserts that at least one fixture was verified
## and that the run's assertion tally equals a number derived from the run's own
## shape (Verification-Harness-Traps §4c).
##
## `replay-server` is NOT part of that skip machinery: a run without it has not
## tested a corpus, it has tested nothing.

import std/[os, strutils, unittest]

import headless_session
import store/types

import fixtures/fixture_provider

import ../../../common/value_presentation

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  MaxStepsForLocals = 40
    ## How far into a recording this suite will step looking for locals.
    ##
    ## ONE STEP IS NOT ENOUGH FOR EVERY RECORDER, measured rather than assumed:
    ## `noir_space_ship` reports ZERO locals one step in, and a suite that
    ## asserted over that empty list would have been asserting nothing — the
    ## empty-set pass Verification-Harness-Traps §4 describes, arriving through
    ## a recorder's entry-point convention rather than through a regex. The
    ## bound is here so a recording that genuinely never yields a local FAILS
    ## by name instead of hanging.

  ChecksPerVerifiedFixture = 6
    ## The fixed assertions a verified fixture makes, before the per-variable
    ## loop. Written here so the final case's expectation is DERIVED.
  ChecksPerSkippedFixture = 2
  ChecksSummaryCase = 5

  BudgetCount = SurfaceBudgets.len
    ## Seven today. Named so the per-variable arithmetic below is readable and
    ## so an eighth surface moves the expectation rather than the tally alone.

  ChecksPerVariable = 3 * BudgetCount + 5
    ## What ONE recorded value costs this suite, in assertions:
    ##
    ##   1              the two sessions agree on the variable's name
    ##   BudgetCount    purity across runs, one per surface budget
    ##   1              purity within a run
    ##   1              the bounded surfaces show a prefix of the unbounded one
    ##                  (one budget declares a cells bound today: `flow`, at 30)
    ##   BudgetCount    the class is the same at every budget
    ##   BudgetCount    THE NON-EMPTY FLOOR — see the header. This is the arm
    ##                  whose absence let a presenter returning "" for every
    ##                  value pass this suite at 16 650 checks.
    ##   2              the attribution names a presenter and the budget
    ##
    ## DERIVED FROM THE RUN'S SHAPE, which is what Verification-Harness-Traps
    ## §4c asks for: `variablesSeen` is whatever the corpus produced, and the
    ## expectation is that number times this one. A branch inside the loop that
    ## stopped asserting moves the tally and not the expectation.
    ##
    ## §4c IS NOT THE WHOLE CONTROL, and this file learned that the hard way:
    ## a derivation from the run's own shape moves BOTH sides together when a
    ## fixture drops out, which is why the summary case now carries a FIXED
    ## fixture floor beside it.

  ChecksPerScalarValue = 1
    ## The scalar-identity assertion, counted per SCALAR value rather than per
    ## value, because it applies only where the adapter's decoded payload is
    ## itself the expected rendering. `scalarValuesSeen` below is its
    ## multiplier.

  ChecksOracleSuite = 47
    ## The written-down oracle's assertions. A FIXED number, not a derived one:
    ## the oracle's whole purpose is to be independent of what the run happens
    ## to contain, so a table row that stopped being asserted must move the
    ## tally away from a constant rather than move an expectation along with it.

var verifiedFixtures = 0
var skippedFixtures = 0
var examinedFixtures = 0
var scalarValuesSeen = 0
  ## Recorded values whose kind makes the adapter's decoded payload the
  ## expected rendering. See `ChecksPerScalarValue`.
var variablesSeen = 0
  ## How many recorded values the corpus produced. The final case's expectation
  ## is a function of THIS, so a recorder change that yields more variables
  ## moves the tally and the expectation together, and a branch that stopped
  ## asserting moves only one of them.

proc brief(s: string): string =
  ## A rendering bounded for a CHECKPOINT LINE.
  ##
  ## The corpus holds values that render to tens of kilobytes — `wide_state`'s
  ## 600-entry mapping is one — and a mismatch checkpoint that printed one in
  ## full buried the whole run: a deliberately-broken presenter produced 45 KB
  ## of Python `builtins` in a single diagnostic and the `[FAILED]` line was
  ## the only readable thing in it. A diagnostic nobody can read is a
  ## diagnostic that will be skipped.
  if s.len <= 120: s else: s[0 ..< 117] & "..."

proc announceSkip(res: FixtureResolution): string =
  result = missingPrereqMessage(res.spec, res.detail)
  echo "  ", result

proc openAt(tracePath: string): HeadlessDebugSession =
  ## A session parked one step in, so locals exist.
  ##
  ## ONE STEP AND NOT ZERO: at the entry point a recording may have no locals
  ## at all, and a suite that asserted over an empty variable list would be
  ## asserting nothing — the empty-set pass Verification-Harness-Traps §4
  ## describes. The `variablesSeen` floor in the final case is the control that
  ## says so out loud.
  result = newHeadlessDebugSession(tracePath, findReplayServer())
  for _ in 0 ..< MaxStepsForLocals:
    result.stepForward()
    result.requestAndLoadLocals()
    if result.getLocals().len > 0:
      return

iterator recordedValues(session: HeadlessDebugSession): (string, PValue) =
  ## Every recorded value the session can see, INCLUDING members, by name.
  ##
  ## Members matter: a corpus's top-level locals are mostly scalars, and the
  ## kinds that exercise the budget — sequences, records, tuples — are inside
  ## them. `wide_state`'s 600-entry mapping is one local and 600 values.
  var queue: seq[(string, Variable)] = @[]
  for v in session.getLocals():
    queue.add ((v.name, v))
  var guard = 0
  while queue.len > 0 and guard < 5000:
    inc guard
    let (path, v) = queue[0]
    queue = queue[1 .. ^1]
    if not v.presented.isNil:
      yield (path, v.presented)
    for child in v.children:
      queue.add ((path & "." & child.name, child))

suite "PLAT-2: one presentation, on real recordings":

  for spec in DeclaredFixtures:
    test "fixture " & spec.name & " renders through the one pipeline":
      inc examinedFixtures
      let resolution = resolveFixture(spec)

      if resolution.outcome == foMissingPrereq:
        inc skippedFixtures
        let message = announceSkip(resolution)
        ck resolution.detail.len > 0
        ck message.startsWith(MissingPrereqSkipPrefix) and spec.name in message
        skip()
      else:
        inc verifiedFixtures
        checkpoint("trace: " & resolution.tracePath)
        ck resolution.tracePath.len > 0
        ck dirExists(resolution.tracePath)

        # TWO SESSIONS, opened separately against the same container. This is
        # the byte-identity claim's real test: two processes' worth of
        # allocation and iteration order, one answer.
        let first = openAt(resolution.tracePath)
        defer: first.close()
        let second = openAt(resolution.tracePath)
        defer: second.close()

        ck first.getDebuggerStatus() == dsIdle
        ck second.getDebuggerStatus() == dsIdle

        var firstValues: seq[(string, PValue)] = @[]
        for entry in first.recordedValues():
          firstValues.add entry
        var secondValues: seq[(string, PValue)] = @[]
        for entry in second.recordedValues():
          secondValues.add entry

        checkpoint("values seen: " & $firstValues.len & " / " &
                   $secondValues.len)
        # The two sessions saw the same variables. If they did not, every
        # comparison below would be between different values and would prove
        # nothing about purity.
        ck firstValues.len == secondValues.len
        ck firstValues.len > 0

        for i in 0 ..< min(firstValues.len, secondValues.len):
          let (name, a) = firstValues[i]
          let (otherName, b) = secondValues[i]
          inc variablesSeen

          # 2. PURITY, ACROSS RUNS. Same value, two sessions, byte-identical.
          ck name == otherName
          for budget in SurfaceBudgets:
            let pa = present(a, budget)
            let pb = present(b, budget)
            if pa.root.text != pb.root.text:
              checkpoint(name & " @ " & budget.name & ": '" & brief(pa.root.text) &
                         "' vs '" & brief(pb.root.text) & "'")
            ck pa.root.text == pb.root.text

          # 2b. PURITY, WITHIN A RUN. The same call, twice.
          ck present(a, StatePanelBudget).root.text ==
             present(a, StatePanelBudget).root.text

          # 1. THE SIX SURFACES DIFFER ONLY BY BUDGET.
          #
          # Stated as: a surface with a cells bound shows a PREFIX of what an
          # unbounded surface shows, up to the ellipsis. That is what "the same
          # rendering, at a different budget" MEANS, and it is falsifiable — a
          # surface that reached a different formatter would produce a string
          # that is not a prefix of the unbounded one.
          let unbounded = present(a, TracepointBudget).root.text
          for budget in SurfaceBudgets:
            if budget.cells <= 0:
              continue
            let bounded = present(a, budget).root.text
            let body =
              if bounded.endsWith(Ellipsis):
                bounded[0 ..< bounded.len - Ellipsis.len]
              else:
                bounded
            if not unbounded.startsWith(body):
              checkpoint(name & " @ " & budget.name & ": '" & brief(bounded) &
                         "' is not a bounded form of '" & brief(unbounded) & "'")
            ck unbounded.startsWith(body)

          # …and the CLASS is the same on every surface. A budget bounds what
          # is shown; it never changes what the value IS.
          for budget in SurfaceBudgets:
            ck present(a, budget).root.class == present(a, TracepointBudget).root.class

          # 1b. THE NON-EMPTY FLOOR.
          #
          # EVERY ASSERTION ABOVE IS A SELF-COMPARISON — the presenter is on
          # both sides of every `==`, and `startsWith` is satisfied by the
          # empty string. A presenter returning "" for every value satisfies
          # all of them, and did: `inlineText` was mutated to `return ""` and
          # this suite stayed green at 16 650 checks over 978 recorded values.
          #
          # `value_presentation_bridge_test.nim` already carried this floor
          # over constructed values; the real-recording suite did not. There is
          # no recorded value whose correct rendering is the empty string —
          # `presenter.inlineText`'s `builtin.scalar` arm goes out of its way
          # to emit `<T: no value>` rather than "" precisely because a blank is
          # indistinguishable from "the debugger has no value here", and
          # `app/source_binding.annotationsFrom` DROPS a variable that renders
          # empty.
          for budget in SurfaceBudgets:
            let rendered = present(a, budget)
            if rendered.root.text.len == 0:
              checkpoint(name & " @ " & budget.name &
                         ": rendered as the EMPTY STRING")
            ck rendered.root.text.len > 0

          # 1c. SCALAR IDENTITY — the one CORRECTNESS statement that can be
          # made about a value nobody wrote down.
          #
          # For a scalar, the expected rendering is a function of the payload
          # the ADAPTER decoded off the wire, and the adapter is not the
          # presenter. `a.text` is `json_adapter.toPValue`'s verbatim
          # transcription of the response's `i` / `f` / `b` / `text` field, so
          # this compares the presenter's answer against a source of truth it
          # did not produce — which is what arms 1 to 3 could not do.
          #
          # `TracepointBudget` because it declares no cell bound (`cells: 0`)
          # and is not `annotated`, so no clipping and no hex companion can
          # legitimately alter the payload. Both mutations that survived this
          # suite die here: `""` is not `a.text`, and a changed sequence
          # delimiter reddens the corresponding oracle rows below.
          if a.text.len > 0:
            let scalarExpectation =
              case a.kind
              of pvkInt, pvkFloat, pvkBool: a.text
              of pvkString, pvkCString: "\"" & a.text & "\""
              of pvkChar: "'" & a.text & "'"
              else: ""
            if scalarExpectation.len > 0:
              inc scalarValuesSeen
              let got = present(a, TracepointBudget).root.text
              if got != scalarExpectation:
                checkpoint(name & " (" & $a.kind & "): rendered '" &
                           brief(got) & "', the adapter decoded '" &
                           brief(scalarExpectation) & "'")
              ck got == scalarExpectation

          # 3. WHICH PRESENTER RENDERED IT, answerable for every value.
          let described = describeAttribution(present(a, StatePanelBudget))
          if not described.startsWith("builtin."):
            checkpoint(name & ": attribution '" & described & "'")
          ck described.startsWith("builtin.")
          ck described.contains("budget=state-panel")

# ---------------------------------------------------------------------------
# THE INDEPENDENT ORACLE.
#
# Values built here, with their expected rendering written out as a LITERAL
# STRING. Nothing in this section asks the presenter what it thinks; every
# right-hand side is a constant, derived from PLAT-2's own description of what
# each surface should show and from the spellings the recorders and the
# language communities already use (`@[…]` is Nim's, `vec![…]` and
# `T { f: … }` are Rust's, `{k: v}` is a mapping's).
#
# THIS IS THE ARM THE SUITE WAS MISSING. Every other assertion in this file has
# the presenter on both sides of the comparison, and two presenter mutations
# (an `inlineText` that returns "" for everything; a sequence delimiter changed
# from `@[` to `<<`) left the whole file green at 16 650 checks. Both die here,
# and they die on the FIRST row.
#
# WHY IT LIVES IN THIS FILE AND NOT ONLY IN `value_presentation_test.nim`:
# because this is the file whose count is quoted as the milestone's evidence.
# A suite that reports 16 650 checks and cannot tell `@[1, 2]` from `<<1, 2]`
# is a number, not a measurement, wherever the correctness arm happens to live.
#
# It runs whether or not any fixture resolves, which is deliberate: a
# recorder-less machine still gets the correctness answer, and only loses the
# real-recording half.
# ---------------------------------------------------------------------------

proc oInt(text: string; typeName = "int"): PValue =
  PValue(kind: pvkInt, text: text, typeName: typeName, sourceKind: "Int")

proc oStr(text: string): PValue =
  PValue(kind: pvkString, text: text, typeName: "str", sourceKind: "String")

proc oBool(text: string): PValue =
  PValue(kind: pvkBool, text: text, typeName: "bool", sourceKind: "Bool")

proc oSeq(sourceKind: string; members: varargs[PValue]): PValue =
  var acc: seq[PMember] = @[]
  for m in members:
    acc.add member("", m)
  PValue(kind: pvkSequence, typeName: "list", sourceKind: sourceKind,
         members: acc)

proc oPoint(): PValue =
  PValue(kind: pvkRecord, typeName: "Point", sourceKind: "Instance",
         members: @[member("x", oInt("10")), member("y", oInt("20"))])

proc oMap(): PValue =
  PValue(kind: pvkMap, typeName: "dict", sourceKind: "TableKind",
         entries: @[PEntry(key: oStr("a"), val: oInt("1")),
                    PEntry(key: oStr("b"), val: oInt("2"))])

suite "PLAT-2: the renderings, written down":

  test "a scalar renders as its payload, and a string is quoted":
    ck present(oInt("42"), TracepointBudget).root.text == "42"
    ck present(oInt("0"), TracepointBudget).root.text == "0"
    ck present(oBool("true"), TracepointBudget).root.text == "true"
    ck present(oStr("hi"), TracepointBudget).root.text == "\"hi\""
    # THE EMPTY STRING IS A VALUE AND RENDERS AS TWO QUOTES, not as nothing.
    # This row alone falsifies a presenter that returns "" for every value.
    ck present(oStr(""), TracepointBudget).root.text == "\"\""
    ck present(PValue(kind: pvkChar, text: "x", typeName: "char",
                      sourceKind: "Char"), TracepointBudget).root.text == "'x'"
    ck present(nil, TracepointBudget).root.text == "nil"

  test "a sequence renders with its language's delimiters":
    # THE DELIMITER IS THE POINT. Changing `@[` to `<<` in the presenter left
    # every other assertion in this file green; it reddens these.
    #
    # THE MEMBERS ARE ABOVE 255 ON PURPOSE. `builtin.byte-buffer` claims any
    # sequence whose every member is an integer in `0 … 255`, and renders it as
    # a hex dump — so `@[1, 2]` is `01 02 (2 bytes)` and asserts nothing about
    # sequence delimiters. The first draft of this table used `1` and `2` and
    # this suite told us so, which is the oracle earning its place on its first
    # run. The byte-buffer spelling gets its own row below.
    let s2 = oSeq("Seq", oInt("1000"), oInt("2000"))
    ck present(s2, TracepointBudget, plUnknown).root.text == "@[1000, 2000]"
    ck present(s2, TracepointBudget, plOther).root.text == "@[1000, 2000]"
    ck present(s2, TracepointBudget, plRust).root.text == "vec![1000, 2000]"
    ck present(oSeq("Seq"), TracepointBudget).root.text == "@[]"
    ck present(oSeq("Array", oInt("700")), TracepointBudget).root.text == "[700]"
    ck present(oSeq("Set", oInt("700")), TracepointBudget).root.text == "{700}"
    ck present(oSeq("Seq", oStr("a"), oStr("b")),
               TracepointBudget).root.text == "@[\"a\", \"b\"]"

  test "a sequence of bytes renders as a hex dump with its length":
    # `builtin.byte-buffer`: every member an integer in `0 … 255`, at least one.
    ck present(oSeq("Seq", oInt("1"), oInt("2"), oInt("255")),
               TracepointBudget).root.text == "01 02 ff (3 bytes)"
    # THE CLASS IS `pcSequence`, NOT `pcByteBuffer`, and that is written down
    # here because it is surprising and because this oracle found it.
    # `value_model.classOf` is kind-directed and total over `PValue.kind`, and
    # "is this a byte buffer" is a property of the MEMBERS, not of the kind —
    # so `pcByteBuffer` is reachable from no value today, even though
    # `type_formatters.valueStyle` and `presented_value.presentationClassName`
    # both map it. The distinction survives in the ATTRIBUTION, which is where
    # a reader can still ask; asserted on the next line so the two halves of
    # the answer are visible together.
    ck present(oSeq("Seq", oInt("1"), oInt("2"), oInt("255")),
               TracepointBudget).root.class == pcSequence
    ck present(oSeq("Seq", oInt("1"), oInt("2"), oInt("255")),
               TracepointBudget).attribution.presenter == "builtin.byte-buffer"
    # ONE MEMBER OUT OF RANGE AND IT IS AN ORDINARY SEQUENCE AGAIN. This is the
    # boundary the rule turns on, and it is what makes the row above a
    # statement about `0 … 255` rather than about "small numbers".
    ck present(oSeq("Seq", oInt("1"), oInt("300")),
               TracepointBudget).root.text == "@[1, 300]"

  test "a record renders as its type and its named fields":
    ck present(oPoint(), TracepointBudget, plUnknown).root.text ==
       "Point(x:10, y:20)"
    ck present(oPoint(), TracepointBudget, plRust).root.text ==
       "Point{x:10, y:20}"

  test "a mapping renders its KEYS as values, not as strings":
    ck present(oMap(), TracepointBudget).root.text == "{\"a\": 1, \"b\": 2}"

  test "nesting renders to the depth the budget allows, and cuts with #":
    let nested = oSeq("Seq", oSeq("Seq", oInt("1000")))
    ck present(nested, TracepointBudget).root.text == "@[@[1000]]"
    var shallow = TracepointBudget
    shallow.depth = 1
    ck present(nested, shallow).root.text == "@[@[#]]"

  test "a member cap elides with the ellipsis, at the cap":
    var capped = TracepointBudget
    capped.members = 2
    let p = present(oSeq("Seq", oInt("1000"), oInt("2000"), oInt("3000")),
                    capped)
    ck p.root.text == "@[1000, 2000, " & Ellipsis & "]"
    ck p.truncated
    ck p.root.totalMembers == 3
    # `elided` IS THE CHILD COUNT THE SURFACE DID NOT GET, not the count the
    # inline text dropped. `TracepointBudget` is `lines: 1`, and a one-line
    # surface is given no children at all, so all three are elided even though
    # the text shows two. Written down because the two numbers differ and a
    # reader will otherwise assume they cannot.
    ck p.root.elided == 3

  test "a cells budget clips to the cells, ellipsis included":
    var narrow = TracepointBudget
    narrow.cells = 8
    let p = present(oSeq("Seq", oInt("100000"), oInt("200000")), narrow)
    ck p.root.text == "@[10000" & Ellipsis
    ck defaultMeasure(p.root.text) == 8
    ck p.truncated

  test "an error renders inside its own marker and nothing else":
    let e = PValue(kind: pvkError, text: "boom", typeName: "E",
                   sourceKind: "Error")
    ck present(e, TracepointBudget).root.text == "<error: boom>"
    ck present(e, TracepointBudget).root.class == pcError

  test "the classes are the ones the front-ends colour by":
    ck present(oInt("1"), TracepointBudget).root.class == pcInteger
    ck present(oStr("a"), TracepointBudget).root.class == pcString
    ck present(oBool("true"), TracepointBudget).root.class == pcBoolean
    ck present(oSeq("Seq", oInt("1")), TracepointBudget).root.class ==
       pcSequence
    ck present(oPoint(), TracepointBudget).root.class == pcRecord
    ck present(oMap(), TracepointBudget).root.class == pcMap
    ck present(nil, TracepointBudget).root.class == pcNone

  test "the seven surface budgets render this value the seven declared ways":
    # THE MILESTONE'S CENTRAL CLAIM, with the answers written out instead of
    # compared to each other. `flow` is the only budget that declares a cells
    # bound (30), so it is the only one whose answer differs — which is what
    # "differing only by the budget each declares" MEANS, said as a constant.
    let v = oSeq("Seq", oStr("aaaaaaaaaa"), oStr("bbbbbbbbbb"),
                 oStr("cccccccccc"))
    const Unbounded = "@[\"aaaaaaaaaa\", \"bbbbbbbbbb\", \"cccccccccc\"]"
    var byName: seq[string] = @[]
    for budget in SurfaceBudgets:
      byName.add budget.name
      if budget.cells > 0:
        ck defaultMeasure(present(v, budget).root.text) <= budget.cells
      else:
        ck present(v, budget).root.text == Unbounded
    # The SET of names, so a renamed or dropped budget is a failure here and
    # not a smaller loop.
    ck byName == @["state-panel", "tracepoint", "flow", "scratchpad",
                   "event-log", "tui-tree", "calltrace-arg"]

suite "PLAT-2: the corpus run measured itself":

  test "every declared fixture was examined, and the tally is the run's own":
    checkpoint("examined " & $examinedFixtures & " of " &
               $DeclaredFixtures.len & "; verified " & $verifiedFixtures &
               ", skipped " & $skippedFixtures)
    # THE COUNT, not "at least one" — Verification-Harness-Traps §4b.
    ck examinedFixtures == DeclaredFixtures.len
    ck verifiedFixtures + skippedFixtures == examinedFixtures

    # A FIXED FLOOR, DERIVED FROM THE DECLARATION AND NOT FROM THE RUN.
    #
    # `ck verifiedFixtures >= 1` used to stand here, and it was satisfiable by
    # any ONE of the four declared fixtures. That mattered because the tally
    # below is derived from `variablesSeen`: a fixture that stopped resolving
    # moved the COUNTED assertions and the EXPECTED assertions by the same
    # amount, so the derivation could not notice it either, and the only
    # remaining signal was one `>= 1` that three fixtures could go missing
    # without disturbing.
    #
    # So the floor is now a property of `DeclaredFixtures` itself: every
    # fixture whose `blockedOn` is empty is OBTAINABLE and must verify.
    # `blockedOn` is the provider's own word for "declared but unobtainable —
    # the replay layer cannot express what this fixture is for", which is a
    # different fact from "the recorder is not installed here" and is the only
    # skip this corpus accepts.
    #
    # This is deliberately STRICTER than a skip-tolerant floor: a machine
    # without the Noir or Python recorders now FAILS this suite instead of
    # quietly measuring a third of it. That is the intended reading — a corpus
    # result is evidence about the corpus, and a partial corpus reporting
    # success is the defect this control exists for. The remedy is named in
    # each skip line the provider prints.
    var obtainableFixtures = 0
    var blockedFixtures = 0
    for spec in DeclaredFixtures:
      if spec.blockedOn.len == 0: inc obtainableFixtures
      else: inc blockedFixtures
    checkpoint("obtainable " & $obtainableFixtures & ", declared-blocked " &
               $blockedFixtures)
    ck verifiedFixtures == obtainableFixtures
    ck skippedFixtures == blockedFixtures

    # …and it saw values. A verified fixture whose locals were empty would
    # satisfy every assertion in the loop above by vacuity.
    checkpoint("values compared: " & $variablesSeen)
    ck variablesSeen >= 1

    let expected =
      verifiedFixtures * ChecksPerVerifiedFixture +
      skippedFixtures * ChecksPerSkippedFixture +
      variablesSeen * ChecksPerVariable +
      scalarValuesSeen * ChecksPerScalarValue +
      ChecksOracleSuite + ChecksSummaryCase
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted " & $countedAssertions & ", derived " & $expected &
               " (values " & $variablesSeen & " x " & $ChecksPerVariable &
               ", scalars " & $scalarValuesSeen & ", oracle " &
               $ChecksOracleSuite & ")")
    check countedAssertions == expected
