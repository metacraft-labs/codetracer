## test_noir_build_diagnostics.nim
##
## Edit-Mode-Toolbar.md §11 / EMT-A35, EMT-A36, EMT-A37 — a `nargo` build
## failure becomes navigable Problems rows.
##
## ## THIS SUITE IS RED ON `dev`, AND IT IS SUPPOSED TO BE.
##
## It states the CORRECT expectation for behaviour that is **not built**. It
## does not assert today's behaviour, because today's behaviour is wrong and a
## suite that pins it would teach the next maintainer that it is right. It goes
## green on its own when a Noir problem matcher lands — no edit to this file.
## Registered in `codetracer-specs/Testing/Known-Test-Failures.md`.
##
## ## What was observed, and why it changes the spec
##
## §2.3 and §13.1 of the spec carry this as the feature's **highest-risk**
## unknown, marked ⟨unverified⟩:
##
##   "`nargo` emits `ariadne`-style diagnostics whose location line is
##    `--> path:line:col`, which `parseRustLocation` should match — ⟨unverified⟩
##    … If `parseRustLocation` does not match `nargo` output, J5-J8 fail and a
##    Noir problem matcher is in scope for this feature."
##
## **It was settled by running the build. The reading was wrong.** `nargo` does
## not emit `-->`. It emits a box-drawing rule, `U+250C U+2500` (`┌─`):
##
##     error: Expected type bool, found type Field
##       ┌─ src/main.nr:3:19
##
## The bytes, from `hexdump -C` of the recorded transcript's line 2, are
## `20 20 e2 94 8c e2 94 80 20 73 72 63 2f …` — two spaces, `┌`, `─`, space,
## then the path. `parseRustLocation` requires `stripped.startsWith("-->")`
## (`frontend/ui/build_location_parser.nim:116`) and therefore **never matches**.
##
## **And the failure is worse than a non-match**, which is why this suite exists
## rather than a one-line spec correction. The line falls through to
## `parseColonLocation` (`:202`), whose path heuristic accepts anything
## containing a `.` or a `/`. So it matches, and produces a corrupted row:
##
## | field | produced today | correct |
## | --- | --- | --- |
## | `path` | `"  ┌─ src/main.nr"` | `"src/main.nr"` |
## | `col` | `-1` — the real column is consumed as the message | `19` |
## | `message` | `"19"` — the digits of the column | the compiler's sentence |
## | `severity` | `SevError` for **every** row, including warnings | per keyword |
##
## A non-matching line would be *visible*. This is a silently corrupted row, and
## it satisfies EMT-A35 exactly as the spec words it — non-empty `path`,
## `line > 0`, `severity == blsError` — over output in which two of the three
## severities are wrong and no row can ever navigate. **That is a spec defect,
## reported rather than inherited:** the assertions below are strengthened to
## the properties EMT-A35 was *for*, and each names the weaker form it replaces.
##
## ## The fixture is recorded, not synthesised
##
## EMT-A35 requires it: "**The transcript is a recorded fixture, not a
## synthesised string.**" `recorded-nargo-compile.stderr` is the verbatim stderr
## of
##
##     cd test-programs/noir_build_error && nargo compile
##
## run on 2026-09-01 with `nargo 1.0.0-beta.26`
## (`noirc 1.0.0-beta.26+906af2f42d6b874cf0f5dde193accb1e39e1bcd3`), exit code
## **1**. `test-programs/noir_build_error/src/main.nr` is the repository's own
## committed fixture, not one written for this suite — which is what makes the
## three diagnostics it produces (two `warning:`, one `error:`) an independent
## sample rather than a shape chosen to prove a point.
##
## Two further observations from the same run, both load-bearing elsewhere:
##
## * **Diagnostics go to stderr, and stdout is empty** (0 bytes). §11.1 says
##   `pump` "drains child output line by line"; a producer that reads only
##   stdout sees nothing at all. Asserted below.
## * **The exit code is 1 on error and 0 on warnings-only** — measured on a
##   second package. So for `nargo compile` the exit code happens to be
##   truthful, which is *not* a reason to trust it (§9.2/EMT-D16); the verdict
##   still comes from the artefact.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_noir_build_diagnostics.nim
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/[strutils, unittest]

import ../../store/types
import ../../../ui/build_location_parser

const RecordedNargoStderr =
  staticRead("../../../../../test-programs/noir_build_error/recorded-nargo-compile.stderr")

const RecordedNargoStdout = ""
  ## Measured: `nargo compile` wrote 0 bytes to stdout for this package.

# ---------------------------------------------------------------------------
# A counted `check` — Verification-Harness-Traps.md §4c.
# ---------------------------------------------------------------------------

var asserted = 0

template ck(condition: untyped) =
  ## `check`, counted. Every assertion in this file goes through it.
  inc asserted
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template startCount() =
  asserted = 0

# ---------------------------------------------------------------------------
# Is the Noir matcher built yet?
#
# `parseNoirLocation` is the proc §11 needs and does not have. `declared` is
# backend-portable and needs no import, because the matcher belongs in
# `frontend/ui/build_location_parser.nim`, which this suite already imports —
# so this suite flips to green the moment that proc lands, with no edit here.
# ---------------------------------------------------------------------------

const NoirMatcherBuilt = declared(parseNoirLocation)

template pending(what: string) =
  ## One counted assertion that fails, naming the unbuilt thing. Counting it
  ## keeps `expectCount` stable across the transition to green, so the count
  ## written below does not have to be rewritten when the feature lands.
  inc asserted
  checkpoint("UNIMPLEMENTED — " & what)
  check false

proc severityOf(raw: string): BuildLineSeverity =
  ## The store-layer severity for a build line, which is what a Problems row
  ## carries (`store/types.nim:305-313`). Mirrors the mapping the producer in
  ## §11.1 has to perform; `BuildSeverity` and `BuildLineSeverity` are
  ## deliberately independent enums.
  let parsed = parseBuildLocation(raw)
  if not parsed.found: return blsNone
  case parsed.severity
  of SevError: blsError
  of SevWarning: blsWarning
  of SevInfo: blsInfo

proc diagnosticLines(transcript: string): seq[string] =
  for raw in transcript.splitLines:
    if parseBuildLocation(raw).found:
      result.add raw

suite "EMT §11 a nargo failure becomes navigable Problems rows":

  test "the recorded transcript is the one this suite claims to be about":
    ## A fixture that moved or was truncated must redden here rather than make
    ## every assertion below vacuous (Verification-Harness-Traps.md §4).
    startCount()
    ck RecordedNargoStderr.len > 0
    ck "Expected type bool, found type Field" in RecordedNargoStderr
    ck RecordedNargoStderr.count("warning:") == 2
    ck RecordedNargoStderr.count("error:") == 1
    ck "src/main.nr" in RecordedNargoStderr
    # The box-drawing rule, not an arrow. This is the observation that settles
    # §13.1's highest-risk unknown, asserted so it cannot quietly change.
    ck "┌─ src/main.nr:3:19" in RecordedNargoStderr
    ck not RecordedNargoStderr.contains("--> src/main.nr")
    # Diagnostics are on stderr; a producer reading stdout sees nothing.
    ck RecordedNargoStdout.len == 0
    expectCount(8)

  test "EMT-A35 every diagnostic yields a row whose fields are the compiler's":
    ## STRENGTHENED against the spec's wording. EMT-A35 asks for
    ##   "≥ 1 BuildProblemLine with non-empty `path`, `line > 0`,
    ##    severity == blsError"
    ## and that is satisfied TODAY by a row whose path is `"  ┌─ src/main.nr"`,
    ## whose column was thrown away and whose message is the digits `"19"`.
    ## An assertion a broken parser passes is not an assertion, so each field
    ## below is pinned to what the compiler actually said.
    startCount()

    let lines = diagnosticLines(RecordedNargoStderr)
    # A count, not `>= 1` — §4b: "if your loop's membership is knowable,
    # assert the COUNT". Three diagnostics are in the fixture.
    ck lines.len == 3

    when NoirMatcherBuilt:
      for raw in lines:
        let parsed = parseBuildLocation(raw)
        ck parsed.found
        # The path is the compiler's path, with no box-drawing prefix. This is
        # the field EMT-D20 turns on: a path that does not resolve yields a row
        # that is shown and NOT navigable, so a polluted path silently costs
        # every row its navigation.
        ck parsed.path == "src/main.nr"
        ck parsed.line > 0
        # The column is present. `nargo` always emits one; today it is parsed
        # as the message and the column is -1.
        ck parsed.col > 0
        # The message is the compiler's sentence, never the column's digits.
        ck not parsed.message.allCharsInSet({'0' .. '9'})
    else:
      pending("`parseNoirLocation` — nargo's `┌─ path:line:col` form " &
              "has no matcher; `parseColonLocation` claims the line and " &
              "corrupts path, col and message")
      # Fifteen assertions the built matcher will make (3 rows x 5 fields),
      # accounted for here so the count below does not move when it lands.
      for _ in 0 ..< 14:
        pending("`parseNoirLocation`")

    expectCount(16)

  test "EMT-A35 severity is the compiler's word, not the parser's default":
    ## The sharpest consequence of the missing matcher, and the one no
    ## "at least one error row" assertion can see. `inferSeverity` falls back
    ## to `SevError` when it recognises no keyword
    ## (`build_location_parser.nim:37-44`), and `nargo` puts the keyword on the
    ## line ABOVE the location. So every Noir diagnostic — including the two
    ## warnings in this fixture — is reported as an error today.
    startCount()

    let lines = diagnosticLines(RecordedNargoStderr)
    ck lines.len == 3

    when NoirMatcherBuilt:
      var errors, warnings = 0
      for raw in lines:
        case severityOf(raw)
        of blsError: inc errors
        of blsWarning: inc warnings
        else: discard
      # The fixture is two warnings and one error. Both halves asserted, so a
      # matcher that classified everything as a warning fails too.
      ck errors == 1
      ck warnings == 2
    else:
      pending("severity: all three rows are blsError today; the fixture is " &
              "two warnings and one error")
      pending("severity: the warning count is 0 today, and must be 2")

    expectCount(3)

  test "EMT-A37 a diagnostic that cannot be located is shown, not dropped":
    ## EMT-D20: "A diagnostic whose path does not resolve to a file in the
    ## workspace becomes a Problems row that is **shown and not navigable**,
    ## carrying the raw path. It is not dropped."
    ##
    ## The negative twin matters here (§16.2): a producer that dropped every
    ## unresolvable row would satisfy "no row has a bad path" trivially.
    startCount()
    const Unresolvable = "  ┌─ ../outside-the-workspace/gen.nr:7:3"
    when NoirMatcherBuilt:
      let parsed = parseBuildLocation(Unresolvable)
      ck parsed.found                       # produced, not dropped
      ck parsed.path == "../outside-the-workspace/gen.nr"
      ck parsed.line == 7
      ck parsed.col == 3
    else:
      pending("`parseNoirLocation` — an unresolvable Noir path")
      for _ in 0 ..< 3:
        pending("`parseNoirLocation` — an unresolvable Noir path")
    expectCount(4)

  test "the four families that DO parse still parse — no regression twin":
    ## §16.2: every negative needs a positive through the same path. Without
    ## this, the assertions above are green over a `parseBuildLocation` that
    ## simply stopped matching anything.
    startCount()

    let rustLoc = parseBuildLocation(" --> src/main.rs:42:5")
    ck rustLoc.found
    ck rustLoc.path == "src/main.rs"
    ck rustLoc.line == 42
    ck rustLoc.col == 5

    let nimLoc = parseBuildLocation("src/x.nim(12, 4) Error: bad")
    ck nimLoc.found
    ck nimLoc.line == 12

    let gccLoc = parseBuildLocation("file.c:9:2: error: expected ';'")
    ck gccLoc.found
    ck gccLoc.path == "file.c"
    ck gccLoc.line == 9
    ck gccLoc.col == 2

    let pyLoc = parseBuildLocation("  File \"script.py\", line 42, in <module>")
    ck pyLoc.found
    ck pyLoc.line == 42

    # Severity, for the families that DO carry the keyword on the location
    # line. Mutation arm M18 broke `inferSeverity`'s "warning" branch and this
    # check SURVIVED, because every assertion above is about position and none
    # was about severity — so the twin was not in fact controlling the property
    # the Noir severity claim depends on. These two close that.
    ck severityOf("file.c:9:2: warning: unused variable 'x'") == blsWarning
    ck severityOf("file.c:9:2: error: expected ';'") == blsError

    # And the control on the control: a line with no location must not match,
    # or "it parses everything" would satisfy all of the above.
    ck not parseBuildLocation("Aborting due to 1 previous error").found
    ck not parseBuildLocation("").found

    expectCount(16)
