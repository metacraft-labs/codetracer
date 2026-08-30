## Noir (`nargo test`) provider suite.
##
## LANE: `ct-providers` — `ci/test/ct-providers.sh`, the `ct-test-providers`
## job in `.github/workflows/codetracer.yml`, and the enumerated
## `ct-providers` list in `ci/lib/test-lane-files.sh`. It belongs there and
## not in `m16-release-gate` because it DRIVES A REAL EXTERNAL TOOLCHAIN:
## `nargo` comes from `ourPkgs.noir` in `nix/shells/ci-base.nix`, which the
## default dev shell composes, and the m16 gate is documented as the
## toolchain-light half of the split.
##
## The provider MODULE is additionally compiled by BOTH lanes, because
## `ct_test.nim`'s `newDefaultProviderRegistry` imports it and
## `release_gate_test.nim` imports `ct_test` — so a Noir module that stops
## parsing fails `ct-test-release-gate` too, not only this one.
##
## NOTHING HERE SKIPS. `nargo` missing is a FAILURE, matching the gate's
## stated policy that a missing toolchain must fail the job rather than turn
## the assertions into checks of nothing. `requireNargo` is where that is
## said.

import std/[algorithm, options, os, sequtils, strutils, tables, unittest]

import contracts
import ct_test
import discovery
import process_exec
import release_gate
import frameworks/noir_nargo

# ---------------------------------------------------------------------------
# Counted assertions.
#
# `counted` is a TEMPLATE, and that is load-bearing. `std/unittest`'s `check`
# only marks a case failed where `testStatusIMPL` is in scope, which is inside
# a `test` body; a template is inlined into that body, a proc is not, and
# every `check` inside a proc would print its message and let the case report
# [OK]. The same distinction is written up at length in
# `release_gate_test.nim`'s `checkCliLaneCovers`, where it was measured.
#
# The counter exists so the suite's assertion COUNT is a measured number that
# moves when a check is deleted or short-circuited, rather than a number
# claimed in a milestone file and never re-derived.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 175
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

proc noirRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/noir_nargo_project"

proc mainFile(): string =
  noirRoot() / "src/main.nr"

proc arithmeticFile(): string =
  noirRoot() / "src/arithmetic.nr"

const
  RootSelectors = ["passes_at_root", "fails_on_purpose", "fails_with_message"]
  ArithmeticSelectors = ["arithmetic::adds_two_fields",
    "arithmetic::adds_unconstrained", "arithmetic::genuinely_fails",
    "arithmetic::nested::nested_case"]

proc selectorsOf(catalog: TestCatalog): seq[string] =
  result = catalog.items.mapIt(it.selector)
  result.sort(system.cmp[string])

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc finishedSelectors(events: seq[TestEvent];
    status: TestResultStatus): seq[string] =
  for e in events:
    if e.kind == tekTestFinished and e.status.isSome and e.status.get == status:
      result.add e.testId
  result.sort(system.cmp[string])

proc kindsOf(events: seq[TestEvent]): seq[TestEventKind] =
  events.mapIt(it.kind)

proc firstOfKind(events: seq[TestEvent]; kind: TestEventKind): TestEvent =
  for e in events:
    if e.kind == kind:
      return e
  raise newException(ValueError, "no event of kind " & $kind)

template requireNargo() =
  ## A hard requirement, never a skip. If this fires, the gate has lost real
  ## coverage and must say so out loud.
  checkpoint("nargo must be on PATH: it ships in the dev shell via " &
    "ourPkgs.noir (nix/shells/ci-base.nix). A missing nargo is lost " &
    "coverage, not a reason to pass.")
  counted findExe("nargo").len > 0

proc runNargoRaw(args: seq[string]): CapturedRun =
  execCaptured(args, cwd = noirRoot())

proc scopeFor(kind: TestScopeKind; file, selector: string): TestScope =
  TestScope(kind: kind, projectRoot: noirRoot(), file: file,
      testId: selector, selector: selector)

# ---------------------------------------------------------------------------
# Transcripts.
#
# Real bytes, captured from `nargo test --format json --show-output` against
# this very fixture, with the compiler-warning block and the trailing bare
# `Error:` line that nargo writes to stderr — and that `execCapturedShell`
# merges into the same stream the JSON arrives on. They are checked in rather
# than regenerated so the three outcomes that are hardest to provoke on
# demand (a truncated capture, a stream with no test results, a failure) are
# assertable without depending on a toolchain producing them again.
# ---------------------------------------------------------------------------
const
  NoisyTranscript = """
warning: unused function not_a_test_at_all
   ┌─ src/main.nr:38:4
   │
38 │ fn not_a_test_at_all() -> Field {
   │    ----------------- unused function
   │

{"type":"suite","event":"started","name":"ct_test_noir_fixture","test_count":2}
{"type":"test","event":"started","name":"passes_at_root","suite":"ct_test_noir_fixture"}
{"type":"test","name":"passes_at_root","suite":"ct_test_noir_fixture","exec_time":0.25,"event":"ok"}
{"type":"test","name":"arithmetic::genuinely_fails","suite":"ct_test_noir_fixture","exec_time":0.5,"event":"failed","stdout":"Failed assertion\nAssertion failed: one plus one is not three\nat src/arithmetic.nr\n"}
{"type":"suite","event":"failed","passed":1,"failed":1,"ignored":0}
Error:
"""

  NoTestsTranscript = """
{"type":"suite","event":"started","name":"ct_test_noir_fixture","test_count":0}
{"type":"suite","event":"ok","passed":0,"failed":0,"ignored":0}
"""

suite "ct-test Noir nargo provider":

  test "noir_nargo_detects_nargo_projects_and_source_files":
    counted hasNargoToml(noirRoot())
    counted isNoirFile(mainFile())
    counted isNoirFile(arithmeticFile())
    counted isNoirSourceFile(noirRoot(), mainFile())
    # Control arm: the detector must say NO to the things that look close.
    counted(not hasNargoToml(getCurrentDir() /
        "src/ct_test/fixtures/rust_libtest_project"))
    counted(not isNoirFile(noirRoot() / "Nargo.toml"))
    counted(not isNoirSourceFile(noirRoot(), noirRoot() / "Nargo.toml"))

    let detected = newNoirNargoM1Provider().provider.detect(noirRoot())
    counted detected.value
    counted detected.diagnostics.len == 0
    let notDetected = newNoirNargoM1Provider().provider.detect(getCurrentDir())
    counted(not notDetected.value)

    # `noirFiles` enumerates through the shared workspace scope and finds both
    # crate sources and nothing else.
    let files = noirFiles(noirRoot()).mapIt(
        relativePath(it, noirRoot()).replace("\\", "/"))
    counted files.len == 2
    counted "src/main.nr" in files
    counted "src/arithmetic.nr" in files

  test "noir_nargo_discovers_module_qualified_selectors_and_ranges":
    let rootCatalog = noirFileCatalog(noirRoot(), mainFile()).value
    counted rootCatalog.provider.id == "noir-nargo"
    counted rootCatalog.provider.language == "noir"
    counted validateCatalog(rootCatalog).valid
    counted selectorsOf(rootCatalog) == sorted(@RootSelectors)

    # The crate root contributes NO module prefix — `src/main.nr` is the crate
    # root for a `bin`, so its tests are bare names, not `main::…`.
    counted fileModulePrefix(noirRoot(), mainFile()).len == 0
    counted fileModulePrefix(noirRoot(), arithmeticFile()) == @["arithmetic"]

    let passes = rootCatalog.itemBySelector("passes_at_root")
    counted passes.name == "passes_at_root"
    counted passes.kind == tikCase
    counted passes.file == "src/main.nr"
    # The range spans the attribute line through the `fn` line, so a gutter
    # control lands on `#[test]` rather than below it.
    counted passes.range.startLine == 7
    counted passes.range.endLine == 8
    counted passes.range.endColumn > passes.range.startColumn
    counted validateSourceRange(passes.range).valid
    counted passes.tags == @["noir", "nargo-test"]
    counted passes.location.source == lskParser
    counted passes.location.confidence == lcHigh

    let shouldFail = rootCatalog.itemBySelector("fails_on_purpose")
    counted "should-fail" in shouldFail.tags
    counted(not ("should-fail-with" in shouldFail.tags))

    let shouldFailWith = rootCatalog.itemBySelector("fails_with_message")
    counted "should-fail" in shouldFailWith.tags
    counted "should-fail-with" in shouldFailWith.tags

    let arithmetic = noirFileCatalog(noirRoot(), arithmeticFile()).value
    counted selectorsOf(arithmetic) == sorted(@ArithmeticSelectors)
    counted validateCatalog(arithmetic).valid
    counted "unconstrained" in
        arithmetic.itemBySelector("arithmetic::adds_unconstrained").tags
    counted(not ("unconstrained" in
        arithmetic.itemBySelector("arithmetic::adds_two_fields").tags))
    # An inline `mod` nests INSIDE the file's own module prefix.
    counted arithmetic.itemBySelector(
        "arithmetic::nested::nested_case").name == "nested_case"

    # The decoys. Each is a `#[test]` in the fixture's bytes that must NOT
    # become a catalog item, and each has a distinct masking rule behind it.
    let allSelectors = selectorsOf(rootCatalog) & selectorsOf(arithmetic)
    counted allSelectors.len == 7
    counted "commented_out_is_not_a_test" notin allSelectors
    counted "block_commented_is_not_a_test" notin allSelectors
    counted "string_literal_is_not_a_test" notin allSelectors
    counted "not_a_test_at_all" notin allSelectors
    counted "main" notin allSelectors

    let project = noirProjectCatalog(noirRoot()).value
    counted selectorsOf(project) == allSelectors.sorted
    counted validateCatalog(project).valid

  test "noir_nargo_selectors_equal_nargo_own_list_tests":
    requireNargo()
    let listed = runNargoRaw(@["nargo", "test", "--list-tests"])
    checkpoint(listed.output)
    counted listed.exitCode == 0
    counted(not listed.truncated)

    let fromNargo = parseNargoListTests(listed.output)
    let fromParser = selectorsOf(noirProjectCatalog(noirRoot()).value)

    # NON-TRIVIALITY BEFORE EQUALITY. Two empty lists compare equal and prove
    # nothing; the count is asserted first so the equality below can only pass
    # over real content.
    counted fromNargo.len == 7
    counted fromParser.len == 7
    counted fromNargo == fromParser
    for selector in ArithmeticSelectors:
      counted selector in fromNargo
    for selector in RootSelectors:
      counted selector in fromNargo
    # ... and the warning block nargo prints above the list does not become a
    # selector.
    counted(not fromNargo.anyIt(it.contains("unused")))

  test "noir_nargo_runs_one_test_and_reports_a_real_per_test_result":
    requireNargo()
    let scope = scopeFor(tskSingle, arithmeticFile(),
        "arithmetic::adds_two_fields")
    let outcome = newNoirNargoM1Provider().provider.run(scope)
    checkpoint($outcome.diagnostics.mapIt(it.message))
    counted outcome.diagnostics.len == 0

    let events = outcome.value
    counted events.len > 0
    counted events.allIt(validateEvent(it).valid)
    counted events.allIt(it.providerId == "noir-nargo")
    counted tekRunStarted in kindsOf(events)
    counted tekRunFinished in kindsOf(events)

    # EXACTLY ONE test finished, and it is the one that was asked for. An
    # `--exact` that silently widened to the whole crate would still exit 0
    # and still report "passed"; the count is what tells the two apart.
    let passedIds = finishedSelectors(events, tsPassed)
    counted passedIds == @["arithmetic::adds_two_fields"]
    counted finishedSelectors(events, tsFailed).len == 0
    counted firstOfKind(events, tekRunFinished).status == some(tsPassed)
    counted firstOfKind(events, tekTestStarted).testId ==
        "arithmetic::adds_two_fields"

    # The command that ran is recorded on the run-started event, and it
    # carries the two flags without which none of the above would be
    # observable.
    let command = firstOfKind(events, tekRunStarted).message
    counted "--format" in command
    counted "json" in command
    counted "--exact" in command
    counted "arithmetic::adds_two_fields" in command

  test "noir_nargo_reports_the_failing_test_as_failed_with_its_message":
    requireNargo()
    let scope = scopeFor(tskSingle, arithmeticFile(),
        "arithmetic::genuinely_fails")
    let outcome = newNoirNargoM1Provider().provider.run(scope)
    let events = outcome.value

    # CONTROL ARM: the passing selector above went green through this same
    # path, so a red here is the test's own status and not a broken driver.
    counted finishedSelectors(events, tsFailed) ==
        @["arithmetic::genuinely_fails"]
    counted finishedSelectors(events, tsPassed).len == 0
    counted firstOfKind(events, tekRunFinished).status == some(tsFailed)
    counted outcome.diagnostics.len == 1
    counted outcome.diagnostics[0].severity == dsError
    counted "1 of 1" in outcome.diagnostics[0].message

    # A per-test failure MESSAGE, not just a status — this is the whole
    # reason for `--format json` over an exit code.
    let failure = firstOfKind(events, tekFailure)
    counted failure.testId == "arithmetic::genuinely_fails"
    counted "one plus one is not three" in failure.output
    counted failure.output.len > 0
    counted tekOutput in kindsOf(events)
    counted "one plus one is not three" in
        firstOfKind(events, tekOutput).output

  test "noir_nargo_file_scope_runs_only_that_files_tests":
    requireNargo()
    let fileScope = scopeFor(tskFile, arithmeticFile(), "src/arithmetic.nr")
    let fileEvents = newNoirNargoM1Provider().provider.run(fileScope).value
    let fileFinished = (finishedSelectors(fileEvents, tsPassed) &
        finishedSelectors(fileEvents, tsFailed)).sorted

    # CONTROL ARM: the same provider, the same fixture, project scope. It runs
    # seven. If file scope also ran seven, "scoped to a file" would be a claim
    # with no content — and that is exactly what happens if the file's
    # selector list is replaced by its module PREFIX, because `src/main.nr`'s
    # prefix is the empty string.
    let projectScope = scopeFor(tskProject, "", "")
    let projectEvents = newNoirNargoM1Provider().provider.run(projectScope).value
    let projectFinished = (finishedSelectors(projectEvents, tsPassed) &
        finishedSelectors(projectEvents, tsFailed)).sorted

    counted projectFinished.len == 7
    counted fileFinished.len == 4
    counted fileFinished == sorted(@ArithmeticSelectors)
    for selector in RootSelectors:
      counted selector notin fileFinished
      counted selector in projectFinished

    # A file with no tests must NOT degrade into an unscoped run. `nargo test`
    # with no name argument runs the whole crate, so "no selectors" has to
    # stop the invocation rather than drop the argument.
    counted buildNargoCommand(@[], ncsFile).len == 0
    counted buildNargoCommand(@[], ncsSingle).len == 0
    counted buildNargoCommand(@[], ncsProject).len > 0
    counted "--exact" notin buildNargoCommand(@[], ncsProject)
    counted "--exact" in buildNargoCommand(@["a", "b"], ncsFile)
    counted buildNargoCommand(@["a", "b"], ncsFile)[^2 .. ^1] == @["a", "b"]

  test "noir_nargo_event_stream_survives_non_json_lines":
    var summary: NoirRunSummary
    let events = noirEventsFromOutput("noir-nargo", "run-1", NoisyTranscript,
        summary)

    counted summary.finished == 2
    counted summary.passed == 1
    counted summary.failed == 1
    counted summary.skipped == 0
    counted summary.started == 1
    counted summary.suiteLines == 2
    # The six-line compiler-warning block and the trailing bare `Error:` are
    # counted as unparsed rather than silently dropped: a parser that cannot
    # say how much it did not understand cannot be trusted about how much it
    # did.
    counted summary.unparsedLines == 7
    counted events.len > 0
    counted events.allIt(validateEvent(it).valid)
    counted finishedSelectors(events, tsPassed) == @["passes_at_root"]
    counted finishedSelectors(events, tsFailed) ==
        @["arithmetic::genuinely_fails"]
    counted firstOfKind(events, tekOutput).output.contains(
        "one plus one is not three")
    # `exec_time` is seconds; the events carry milliseconds.
    counted firstOfKind(events, tekFailure).durationMs == 500

  test "noir_nargo_a_run_with_no_test_results_is_an_error_not_a_pass":
    # THE TRAP THIS CHECK EXISTS FOR: `nargo test --exact <name that matches
    # nothing>` exits ZERO and prints a suite line and no test lines. Every
    # weaker signal — exit code, absence of a failure event, "the command ran"
    # — reports success over a run in which nothing executed.
    var summary: NoirRunSummary
    let outcome = noirRunResult(
      scopeFor(tskSingle, arithmeticFile(), "no_such_test"),
      "nargo test --format json --exact no_such_test",
      CapturedRun(output: NoTestsTranscript, exitCode: 0, durationMs: 12),
      summary)

    counted summary.finished == 0
    counted summary.suiteLines == 2
    counted outcome.diagnostics.len == 1
    counted outcome.diagnostics[0].severity == dsError
    counted "no per-test results" in outcome.diagnostics[0].message
    counted firstOfKind(outcome.value, tekRunFinished).status ==
        some(tsErrored)
    counted finishedSelectors(outcome.value, tsPassed).len == 0
    counted tekFailure in kindsOf(outcome.value)

    # CONTROL ARM: the same function, the same exit code, over a transcript
    # that DOES carry results. It must come back green — otherwise the check
    # above would pass for the trivial reason that this path never passes.
    var controlSummary: NoirRunSummary
    let control = noirRunResult(
      scopeFor(tskProject, "", ""),
      "nargo test --format json",
      CapturedRun(output: """
{"type":"suite","event":"started","name":"p","test_count":1}
{"type":"test","name":"passes_at_root","suite":"p","exec_time":0.1,"event":"ok"}
{"type":"suite","event":"ok","passed":1,"failed":0,"ignored":0}
""", exitCode: 0, durationMs: 12),
      controlSummary)
    counted controlSummary.finished == 1
    counted control.diagnostics.len == 0
    counted firstOfKind(control.value, tekRunFinished).status == some(tsPassed)

  test "noir_nargo_truncated_capture_is_an_error_not_a_short_answer":
    # A JSON Lines stream is the most list-shaped output ct_test consumes, and
    # `process_exec` says in as many words that a prefix of a list-shaped
    # output is indistinguishable from a complete short answer. So the
    # truncation flag is consulted BEFORE the stream is believed.
    var summary: NoirRunSummary
    let outcome = noirRunResult(
      scopeFor(tskProject, "", ""),
      "nargo test --format json",
      CapturedRun(output: NoisyTranscript, exitCode: 0, durationMs: 9,
          outputBytes: uint64(NoisyTranscript.len) + 4096, truncated: true),
      summary)

    counted outcome.diagnostics.len == 1
    counted outcome.diagnostics[0].severity == dsError
    counted "truncated" in outcome.diagnostics[0].message
    counted firstOfKind(outcome.value, tekRunFinished).status ==
        some(tsErrored)
    counted summary.finished == 0
    # And the two results it WOULD have reported are not in the stream — a
    # truncated capture yields no per-test verdicts at all rather than the
    # prefix that happened to survive.
    counted finishedSelectors(outcome.value, tsPassed).len == 0
    counted finishedSelectors(outcome.value, tsFailed).len == 0

    # CONTROL ARM: identical bytes, `truncated: false`. Two results.
    var controlSummary: NoirRunSummary
    let control = noirRunResult(
      scopeFor(tskProject, "", ""),
      "nargo test --format json",
      CapturedRun(output: NoisyTranscript, exitCode: 1, durationMs: 9),
      controlSummary)
    counted controlSummary.finished == 2
    counted finishedSelectors(control.value, tsPassed).len == 1
    counted finishedSelectors(control.value, tsFailed).len == 1

  test "noir_nargo_declares_only_the_capabilities_it_has":
    let capabilities = providerCapabilities()
    counted validateCapabilities(capabilities).valid
    counted capabilities.canDiscoverProject
    counted capabilities.canDiscoverFile
    counted capabilities.canLocateTests
    counted capabilities.canRunProject
    counted capabilities.canRunFile
    counted capabilities.canRunSingle
    counted capabilities.canCapturePerTestOutput
    counted capabilities.emitsStructuredEvents
    # Recording is NOT claimed, and the contract's own rule says trace
    # entry-point mapping cannot be claimed without it.
    counted(not capabilities.canRecordProject)
    counted(not capabilities.canRecordFile)
    counted(not capabilities.canRecordSingle)
    counted(not capabilities.canMapTraceEntryPoints)
    counted(not claimsRecord(capabilities))

    # And the unsupported paths say WHY, at the point of use, rather than
    # returning an empty success.
    let recorded = newNoirNargoM1Provider().provider.record(
        scopeFor(tskSingle, arithmeticFile(), "arithmetic::adds_two_fields"))
    counted recorded.value.len == 0
    counted recorded.diagnostics.len == 1
    counted recorded.diagnostics[0].severity == dsWarning
    counted "one event and zero steps" in recorded.diagnostics[0].message
    counted "tracer_wasm" in recorded.diagnostics[0].message

    let mapped = newNoirNargoM1Provider().provider.mapTraceEntryPoints(
        noirProjectCatalog(noirRoot()).value, @[])
    counted mapped.value.len == 0
    counted mapped.diagnostics.len == 1

    # `parseEvent` round-trips this provider's own normalized events.
    var sampleSummary: NoirRunSummary
    let sample = firstOfKind(noirEventsFromOutput("noir-nargo", "r",
        NoisyTranscript, sampleSummary), tekTestFinished)
    let reparsed = newNoirNargoM1Provider().provider.parseEvent(
        eventToJsonLine(sample))
    counted reparsed.diagnostics.len == 0
    counted reparsed.value.testId == sample.testId
    counted reparsed.value.status == sample.status

  test "noir_nargo_is_registered_and_release_gated":
    let registry = newDefaultProviderRegistry()
    let ids = registry.providers.mapIt(it.provider.info.id)
    counted "noir-nargo" in ids
    # Control arm: registering Noir did not displace anyone.
    counted "rust-libtest" in ids
    counted "smart-evm" in ids
    counted ids.len == ids.deduplicate.len

    let entries = gateEntryByProvider()
    counted entries.hasKey("noir-nargo")
    let entry = entries["noir-nargo"]
    counted dirExists(entry.fixturePath)
    counted fileExists(entry.researchDoc)
    counted fileExists(entry.providerTest)
    counted entry.providerTest == "src/ct_test/noir_providers_test.nim"
    counted(not entry.heavy)
    for source in entry.sourceFiles:
      counted fileExists(source)

    # The lane that runs this file, asserted rather than assumed — this repo's
    # signature defect is a gate whose surface has a hole exactly the shape of
    # the newest file.
    let laneScript = readFile("ci/test/ct-providers.sh")
    counted "src/ct_test/noir_providers_test.nim" in laneScript
    let laneFiles = readFile("ci/lib/test-lane-files.sh")
    counted "src/ct_test/noir_providers_test.nim" in laneFiles

  test "noir_nargo_assertion_count_is_measured":
    # The count is asserted so that deleting or short-circuiting a check above
    # cannot pass silently: it has to move this number in the same commit.
    # This case's own two checks are not counted, which is why the comparison
    # is against the value after every preceding case has run.
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
