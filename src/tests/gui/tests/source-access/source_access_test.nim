## CTUI-4 — the source-access seam, through a real debugger on real traces.
##
## ## What this suite establishes
##
## `SourceVM` and `SourceProvider` are asserted in isolation by
## `src/frontend/viewmodel/tests/unit/test_source_vm_window.nim` and
## `…/test_source_provider_revisions.nim`, over files those suites write
## themselves. That is the right shape for the window arithmetic and for the
## revision refusal, and it establishes nothing at all about the two questions
## this file exists for:
##
##   1. **Does the provider return the file the DEBUGGER names?** Not a file
##      with the right name — the file at the path a real `replay-server`
##      reports for a real recorded stop.
##   2. **Is the line under the execution pointer the line the backend names?**
##      A pane can be one line out for the whole session and look perfectly
##      plausible.
##
## ## Both implementations, on both fixtures — because one tested
## ## implementation is one implementation
##
## The seam has two implementations and CTUI-4 says a seam with two
## implementations and one tested implementation is one implementation. So
## EVERY case below runs twice per fixture, once per provider:
##
##   `spkCtfsMaterialized`  reads the recording's own bundled sources out of the
##                          trace folder's `files/` payload. Constructed with
##                          `allowWorkingTree = false` HERE, deliberately: with
##                          the fallback on, a machine that happens to hold the
##                          recorded program would pass this suite without the
##                          payload being read at all.
##   `spkDapSource`         sends the DAP `source` request to the same
##                          `replay-server` process the session is driving.
##                          Constructed with `allowWorkingTree = false` too, and
##                          for exactly the same reason — see below.
##
## ## Provenance, not just text
##
## Both fixtures are recorded from programs that are still in this checkout, so
## the recording's copy and the working-tree copy of every file are byte
## identical today. Any assertion that only compares TEXT is therefore satisfied
## by a provider that never opened the recording at all. That is not
## hypothetical: it is how the engine shipped a working-tree read for every Noir
## recording through CTUI-4's first verification pass and was reported as an
## ordinary success.
##
## So every arm here asserts WHERE the bytes came from. Both providers are
## constructed refusing the working tree, both must answer `soTracePayload`, and
## the cross-check between them compares `status` and `origin` as well as text.
## A second, PERMISSIVE pair (`allowWorkingTree = true`) exists solely to prove
## the other half of the contract: that a working-tree read, when a consumer
## does allow it, comes back `sfsUnverified` / `soWorkingTree` on both arms and
## never `sfsAvailable`.
##
## ## The payload root is a boundary, and agreement alone cannot check it
##
## `checkEscapingPathIsRefusedByBothProviders` is the one arm here that exists
## because agreement is not enough. Both read sides resolved a recorded `..`
## through the OS — the engine in its exact mapping, the CTFS provider in its
## suffix walk, i.e. in OPPOSITE steps — and both therefore served a file from
## outside the trace, certified `soTracePayload`, to providers built with
## `allowWorkingTree = false`. They agreed the whole time. So that arm asserts a
## property of each answer rather than equality between two of them, and it
## establishes the escape is genuinely reachable before asserting it is refused.
##
## ## What the DAP arm cost, and why it is recorded here
##
## Before CTUI-4 the engine did not answer `source` at all: the request fell
## through `dap_server.rs`'s dispatch to `dap_command_to_step_action`, which
## replied `command source not supported here`. Measured against
## `src/build-debug/bin/replay-server` on the `calc` fixture before the change,
## and it is why `Handler::source` (`src/db-backend/src/dap_handler.rs`) and the
## `"source"` arm in `dap_server.rs` are part of this milestone: the second
## implementation of the seam had no server on the other end of it.
##
## ## Nothing here is hardcoded, and nothing here is mocked
##
## No line number, no tick, no file name is written into this file as an
## expectation. Every assertion is against a value the backend reported in the
## same run, or against agreement between two independent acquisition paths:
##
##   * the pointer line comes from `session.getCurrentLine()`;
##   * the path comes from `session.getCurrentFile()`;
##   * the expected TEXT at the entry stop comes from the recorded program file
##     itself, read at the path the backend reported — so a fixture re-recorded
##     on a new compiler moves both sides together;
##   * at every stepped stop the two providers must agree, which is a check
##     neither of them can satisfy alone.
##
## There is no `MockBackendService` in this file.
##
## ## The three outcomes, and why an all-skipped run FAILS
##
## Per `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md`, the
## fixtures resolve through `fixtures/fixture_provider.nim` and a missing
## RECORDER is a counted, greppable `MISSING-PREREQ SKIP`. A missing
## `replay-server` is not a skip — it is a diagnostic failure naming the build
## command, because a run without it has tested nothing. The last case asserts
## that every declared fixture was examined, that at least one was verified,
## and that the runtime assertion tally equals the number derived from the run's
## own shape (Verification-Harness-Traps §4b/§4c).
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/tests/gui/tests/source-access/source_access_test.nim

import std/[os, strutils, unittest]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import headless_session
import backend/backend_service
import backend/stdio_backend
import store/[replay_data_store, degraded_state]
import viewmodels/[editor_vm, source_vm]
import sdk/source_provider

import ../../../../frontend/tui/tests/fixtures/fixture_provider

# ---------------------------------------------------------------------------
# Counted assertions (Verification-Harness-Traps §4c)
# ---------------------------------------------------------------------------

var countedAssertions = 0

template ck(condition: untyped) =
  ## `check`, counted. The tally is compared at the end against a number
  ## derived from the run's own shape, so an arm that asserted nothing cannot
  ## leave this file green.
  inc countedAssertions
  check condition

const
  ExaminedFixtures = ["calc", "noir_space_ship"]
    ## The two CTUI-4 names. `wide_state` is a value-shape fixture and
    ## `threads` is declared-but-unobtainable (see `fixture_provider.nim`);
    ## neither says anything about source access, so neither is opened here.
  StepsPerFixture = 4
    ## Small on purpose. Each stop is a full window fill through both
    ## providers, and `HeadlessDebugSession` grows measurably per stop unless
    ## events are drained — which this suite does, after every step.

  # Each template's own `ck` count, named separately so the total below is a
  # sum a reader can check against the templates rather than one hand-totalled
  # number that drifts the moment an assertion is added.
  ChecksServesTheDebuggersFile = 16
  ChecksUnavailableGenerationDegrades = 5
  ChecksPerProviderArm = ChecksServesTheDebuggersFile +
                         ChecksUnavailableGenerationDegrades
  ChecksPerCrossCheckStop = 8
  ChecksForeignPathPerStrictProvider = 4
  ChecksForeignPathPerPermissiveProvider = 6
  ChecksAbsentPathPerProvider = 4
  ChecksForeignPath = 2 * ChecksForeignPathPerStrictProvider +
                      2 * ChecksForeignPathPerPermissiveProvider +
                      2 * ChecksAbsentPathPerProvider
  ChecksEscapeControls = 2
  ChecksEscapePerStrictProvider = 5
  ChecksEscapingPath = ChecksEscapeControls +
                       2 * ChecksEscapePerStrictProvider
  ChecksProviderInventory = 5
  ChecksPerVerifiedFixture = ChecksProviderInventory +
                             2 * ChecksPerProviderArm +
                             (StepsPerFixture + 1) * ChecksPerCrossCheckStop +
                             ChecksForeignPath +
                             ChecksEscapingPath
  ChecksPerSkippedFixture = 2
  ChecksSummaryCase = 4

const
  ForeignLines = ["alpha — belongs to no recording",
                  "beta — written by this test",
                  "gamma"]
    ## The content of the file below. Asserted back verbatim, so "the working
    ## tree really was read" is established by the BYTES and not merely by a
    ## status code.

let foreignSourcePath = getTempDir() /
  ("ctui4-foreign-source-" & $getCurrentProcessId() & ".src")
  ## A real file, on this machine, that is part of NO recording.
  ##
  ## This is the reviewer's third demonstration turned into a regression test.
  ## Asking a `noir_space_ship` session for `test-programs/calc/main.py` — a
  ## file in no way part of that recording — was answered `success: true` with
  ## 116 lines and nothing in the answer to say the engine had simply read the
  ## replay host's disk. A path the test writes itself is used rather than the
  ## other fixture's program, because it is foreign to BOTH fixtures and its
  ## exact content is known.

writeFile(foreignSourcePath, ForeignLines.join("\n") & "\n")

var verifiedFixtures = 0
var skippedFixtures = 0
var examinedFixtures = 0

# ---------------------------------------------------------------------------
# Opening a fixture
# ---------------------------------------------------------------------------

type SourceHarness = object
  session: HeadlessDebugSession
  vm: SourceVM
  traceDir: string
    ## The open trace folder. Carried so the containment arm can compute the
    ## payload root (`<traceDir>/files`) both providers treat as their
    ## boundary, rather than spelling a path this suite would then have to keep
    ## in sync with `sdk/source_provider.nim` and `Handler::source`.
  providers: seq[SourceProvider]
    ## Both implementations, each REFUSING the working tree. Index 0 is CTFS,
    ## index 1 is DAP; the order is asserted below rather than assumed.
  permissiveProviders: seq[SourceProvider]
    ## The same two, each ALLOWING it. Same order. Used by exactly one arm —
    ## the one that proves an allowed working-tree read is still reported
    ## unverified.

proc announceSkip(res: FixtureResolution): string =
  result = missingPrereqMessage(res.spec, res.detail)
  echo "  ", result

proc openHarness(tracePath: string): SourceHarness =
  ## A real session over `tracePath`, a `SourceVM` over its store, and both
  ## implementations of the seam pointed at the same open trace — twice, once
  ## per working-tree policy.
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  let vm = createSourceVM(session.session.store, session.session.editorVM)
  vm.setViewport(height = 12, overscan = 4)
  let backendService = session.backend.toBackendService()
  SourceHarness(
    session: session,
    vm: vm,
    traceDir: tracePath,
    providers: @[
      newCtfsSourceProvider(tracePath, allowWorkingTree = false),
      newDapSourceProvider(backendService, allowWorkingTree = false),
    ],
    permissiveProviders: @[
      newCtfsSourceProvider(tracePath, allowWorkingTree = true),
      newDapSourceProvider(backendService, allowWorkingTree = true),
    ])

proc closeHarness(h: SourceHarness) =
  h.vm.dispose()
  h.session.close()

proc serveOne(h: SourceHarness; provider: SourceProvider;
              request: SourceLineRequest): SourceFetch =
  ## One request through one provider, delivered.
  ##
  ## The `drainSourceCallbacks()` is load-bearing rather than defensive: on the
  ## native backend `asyncdispatch` defers a callback even on a future that is
  ## already complete, so the DAP provider's answer arrives on the next poll.
  ## Without the drain, `captured` keeps its zero value — `sfsAvailable`, no
  ## lines — which reads as "an empty file" and would let this whole suite pass
  ## while the DAP provider returned nothing at all. It was measured doing
  ## exactly that before the drain was added.
  ##
  ## `result` is seeded with a status that CANNOT be mistaken for success for
  ## the same reason: `SourceFetchStatus`'s zero value is `sfsAvailable`.
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc fillThrough(h: SourceHarness;
                 provider: SourceProvider): seq[SourceFetch] =
  ## Follow the execution pointer, then serve every range the VM asks for
  ## through `provider`. Returns one `SourceFetch` per request the VM made, so
  ## a caller can assert on the COUNT as well as on the answers.
  result = @[]
  h.vm.followExecutionPointer()
  for request in h.vm.requestMissing():
    let fetch = h.serveOne(provider, request)
    discard h.session.session.store.applySourceFetch(h.vm, fetch)
    result.add(fetch)

proc pointerFetch(h: SourceHarness;
                  provider: SourceProvider): tuple[text: string;
                                                   fetch: SourceFetch] =
  ## The line under the execution pointer AND the answer that produced it,
  ## acquired through `provider`.
  ##
  ## `discardHeldText` first, and it is load-bearing rather than tidy. Without
  ## it the second provider asked at a given stop finds the window already
  ## filled by the first, `requestMissing` yields nothing, `fillThrough`
  ## performs no acquisition at all, and `lineAt` returns the FIRST provider's
  ## text. The cross-check between the two implementations then compares one
  ## provider's answer with itself and passes unconditionally — measured: the
  ## DAP arm was never exercised at any stepped stop.
  ##
  ## `text` is "" only when the VM did not hold the pointer line; the callers
  ## assert against that separately, so an empty answer can never pass for a
  ## blank source line. The returned fetch is seeded with a status that cannot
  ## be mistaken for success when the fill did not produce EXACTLY one request,
  ## which is the shape a single contiguous window must have.
  h.vm.discardHeldText()
  let fetches = h.fillThrough(provider)
  let fetch =
    if fetches.len == 1: fetches[0]
    else: SourceFetch(status: sfsProviderUnavailable,
                      detail: "expected exactly one request to fill the " &
                        "window, got " & $fetches.len)
  let read = h.vm.lineAt(h.session.getCurrentLine())
  ((if read.kind == srkHeld: read.text else: ""), fetch)

proc recordedProgramLine(path: string; line: int): string =
  ## The `line`-th line of the file at `path`, read straight off disk.
  ##
  ## This is the INDEPENDENT ground truth for the entry stop: the recorded
  ## program is in this repository under `test-programs/`, the backend reports
  ## its absolute path, and the trace's bundled payload is a COPY of it. If the
  ## payload and the program disagree, the recording is not of the program.
  ## Returns "" when the path is unreadable or the line is out of range; every
  ## caller asserts non-emptiness, so a missing file is loud.
  if not fileExists(path):
    return ""
  let lines = splitSourceLines(readFile(path))
  if line >= 1 and line <= lines.len: lines[line - 1] else: ""

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
#
# A `proc` that fails a `check` sets `programResult = 1` while the enclosing
# test still prints `[OK]` — a live silent-self-pass mechanism found earlier in
# this campaign. `fillThrough`, `pointerFetch` and `recordedProgramLine` above
# assert nothing, which is why they are procs.
# ---------------------------------------------------------------------------

template checkProviderServesTheDebuggersFile(h: SourceHarness;
                                             provider: SourceProvider) =
  ## The heart of the milestone: at the entry stop the provider returns the
  ## file the DEBUGGER reports, and the line under the execution pointer is the
  ## line the BACKEND names.
  let backendFile = h.session.getCurrentFile()
  let backendLine = h.session.getCurrentLine()

  ck backendFile.len > 0
  ck backendLine >= 1
  ck provider.supports()

  # The VM's identity is the debugger's, not a copy the test made.
  ck h.vm.revision.val.path == backendFile
  ck h.vm.path.val == h.session.session.editorVM.activeFileName.val
  ck h.vm.sourceGeneration.val ==
    h.session.session.editorVM.activeSourceGeneration.val

  let fetches = h.fillThrough(provider)
  # EXACTLY ONE request: the held window was discarded before this arm, so the
  # VM needs one contiguous range and nothing else. An exact count rather than
  # a lower bound (Verification-Harness-Traps §4b) — a VM that asked twice for
  # overlapping ranges would satisfy "at least one" and would be re-fetching.
  ck fetches.len == 1
  let fetch = if fetches.len == 1: fetches[0]
              else: SourceFetch(status: sfsProviderUnavailable)
  ck fetch.status == sfsAvailable
  ck fetch.hasText
  # WHERE the bytes came from, not merely that bytes arrived. Both providers
  # were constructed refusing the working tree, so the only answer either can
  # legitimately give is the RECORDING's own copy. Without this the arm is
  # satisfied by a provider that read the program off this machine — which, on
  # both fixtures, holds identical bytes.
  ck fetch.origin == soTracePayload
  ck fetch.revision.path == backendFile
  ck fetch.revision.sourceGeneration == h.vm.sourceGeneration.val
  ck fetch.totalLineCount >= backendLine

  # The pointer line is HELD — not a request, not an empty string — and it is
  # the line the recorded program really has at that number.
  let read = h.vm.lineAt(backendLine)
  ck read.kind == srkHeld
  let groundTruth = recordedProgramLine(backendFile, backendLine)
  ck groundTruth.len > 0
  ck (if read.kind == srkHeld: read.text else: "\x00mismatch") == groundTruth

template checkUnavailableGenerationDegrades(h: SourceHarness;
                                            provider: SourceProvider) =
  ## A generation this recording does not hold must produce §14's existing
  ## "No verified source" row and NO text — never the recorded generation's
  ## text under the requested generation's identity.
  let backendFile = h.session.getCurrentFile()
  let store = h.session.session.store
  let captured = h.serveOne(
    provider,
    SourceLineRequest(path: backendFile,
                      sourceGeneration: h.vm.sourceGeneration.val + 7,
                      firstLine: 1, lastLine: 5))
  ck not captured.hasText
  ck captured.lines.len == 0
  # The EXACT status, not merely "not verified". `sfsGenerationUnavailable`
  # is the answer only a provider that KNOWS which revision it holds can give;
  # `sfsProviderUnavailable` would mean the request failed for some other
  # reason and would satisfy a weaker assertion while proving nothing about
  # revision identity. For the DAP arm this is what checks that the engine
  # NAMES the generation it served (`SourceResponseBody.sourceGeneration`)
  # rather than silently substituting the recorded one.
  ck captured.status == sfsGenerationUnavailable
  ck sourceAvailabilityFor(captured.status) == savUnverified
  discard store.applySourceFetch(h.vm, captured)
  ck h.session.session.editorVM.degradedState.val == pdNoVerifiedSource
  # Put the session back where the rest of the suite expects it.
  store.setSourceAvailability(savVerified)

template checkBothProvidersAgree(h: SourceHarness) =
  ## The cross-check that neither provider can satisfy alone: the recording's
  ## own bundled copy and the replay engine must produce the same ANSWER for
  ## the line the backend is stopped on — the same text, and the same account
  ## of where the text came from.
  ##
  ## Text alone is not enough and never was. Both fixtures are recorded from
  ## programs still present in this checkout, so the recording's copy and the
  ## working-tree copy are byte identical; a text-only comparison is satisfied
  ## by two providers that both read the working tree, by one that reads it and
  ## one that does not, and by an engine whose payload resolution is broken.
  ## Comparing `status` and `origin` too is what makes this an assertion about
  ## the SEAM's contract rather than about the fixture's contents.
  let backendLine = h.session.getCurrentLine()
  ck backendLine >= 1
  ck h.vm.executionLine.val == backendLine
  let viaCtfs = h.pointerFetch(h.providers[0])
  let viaDap = h.pointerFetch(h.providers[1])
  ck viaCtfs.text.len > 0
  ck viaDap.text.len > 0
  ck viaCtfs.text == viaDap.text
  ck viaCtfs.fetch.status == viaDap.fetch.status
  ck viaCtfs.fetch.origin == viaDap.fetch.origin
  # …and the provenance they agree on is the recording's. Two providers that
  # both fell back to the working tree would agree, and would be wrong.
  ck viaCtfs.fetch.origin == soTracePayload

template checkForeignPathIsNotServedAsTheRecordings(h: SourceHarness) =
  ## A path that belongs to NO recording, through both implementations, under
  ## both working-tree policies.
  ##
  ## This is the reviewer's third demonstration as a regression test, and it is
  ## also where the two arms' §14 rows are pinned to agree (CTUI-4's Part C).
  ## Before the provenance contract existed the DAP arm answered
  ## `sfsProviderUnavailable` → `savUnverified` where the CTFS arm answered
  ## `sfsPathUnavailable` → `savAbsent` for the same question, and nothing
  ## tested it: "there is no source for this path" and "this provider is not
  ## working" are different rows, and only the first is true here.
  let request = SourceLineRequest(path: foreignSourcePath,
                                  sourceGeneration: h.vm.sourceGeneration.val,
                                  firstLine: 1,
                                  lastLine: ForeignLines.len)

  # Refusing the working tree, the file is simply not part of this recording.
  for provider in h.providers:
    let refused = h.serveOne(provider, request)
    ck not refused.hasText
    ck refused.lines.len == 0
    ck refused.status == sfsPathUnavailable
    ck sourceAvailabilityFor(refused.status) == savAbsent

  # Allowing it, the bytes come back — the desktop has always worked that way —
  # but they come back UNVERIFIED, with the origin named. `sfsAvailable` here
  # would be the seam certifying a file that is in no way part of the open
  # recording.
  for provider in h.permissiveProviders:
    let served = h.serveOne(provider, request)
    ck served.hasText
    ck served.status == sfsUnverified
    ck served.origin == soWorkingTree
    ck sourceAvailabilityFor(served.status) == savUnverified
    # The exact bytes this test wrote, so "it read the working tree" is
    # established by content and not merely by a status code.
    ck served.lines == @ForeignLines
    ck served.totalLineCount == ForeignLines.len

  # And the literal form of the same question — a path with no source ANYWHERE,
  # asked of the PERMISSIVE pair so that even the last-resort read has nothing
  # to find. This is the exact disagreement CTUI-4 shipped with and nothing
  # tested: `savAbsent` ("there is no source of any kind here", and §14 has a
  # row for it) on the CTFS arm versus `savUnverified` ("this provider is not
  # working") on the DAP arm, for a question whose answer is the former.
  let absent = SourceLineRequest(path: foreignSourcePath & ".never-written",
                                 sourceGeneration: h.vm.sourceGeneration.val,
                                 firstLine: 1,
                                 lastLine: ForeignLines.len)
  for provider in h.permissiveProviders:
    let nothing = h.serveOne(provider, absent)
    ck not nothing.hasText
    ck nothing.lines.len == 0
    ck nothing.status == sfsPathUnavailable
    ck sourceAvailabilityFor(nothing.status) == savAbsent

template checkEscapingPathIsRefusedByBothProviders(h: SourceHarness) =
  ## A recorded path that CLIMBS OUT of the trace's payload root must be
  ## refused, on both implementations, and must never come back certified.
  ##
  ## ## The defect this arm exists for
  ##
  ## A recorded path is untrusted input: it is whatever string a recorder
  ## interned into a container that this process did not write. Both read sides
  ## resolved `..` through the OS — the engine in its exact mapping, the CTFS
  ## provider in its suffix walk, i.e. in OPPOSITE steps — so a path like
  ## `/../../<something outside>` was answered with a file that is in no way
  ## part of the recording, reported `soTracePayload` / `sourceOrigin: payload`,
  ## and reported that way to providers built with `allowWorkingTree = false`,
  ## the one policy that exists to refuse exactly this.
  ##
  ## Because BOTH sides had the hole, `checkBothProvidersAgree` could not catch
  ## it: they agreed, and they were both wrong.
  ##
  ## ## Why the path is computed and not written down
  ##
  ## The escape has to be genuinely reachable to prove anything — a refusal of a
  ## path that resolves to nothing is free. So the hops are computed with
  ## `relativePath` from the real payload root to the real file this suite wrote
  ## in `$TMPDIR`, and the FIRST assertion is that the OS really does reach the
  ## file through them. That control is what makes the two refusals below
  ## refusals of an escape rather than of an absence.
  let payloadRoot = h.traceDir / "files"
  let hops = relativePath(foreignSourcePath, payloadRoot)
  let escaping = "/" & hops
  # CONTROL 1: the hops really do leave the root (they start by climbing).
  ck hops.startsWith("..")
  # CONTROL 2: and the OS really does reach the file through them, from inside
  # the payload root. This is the escape, spelled out.
  ck fileExists(payloadRoot / hops)

  let request = SourceLineRequest(path: escaping,
                                  sourceGeneration: h.vm.sourceGeneration.val,
                                  firstLine: 1,
                                  lastLine: ForeignLines.len)
  for provider in h.providers:
    let refused = h.serveOne(provider, request)
    # A REFUSAL, not a differently-shaped success: no text, no lines, the exact
    # status, the §14 row that says "no source of any kind here", and — the one
    # that matters most — no claim that this was the recording's own copy.
    ck not refused.hasText
    ck refused.lines.len == 0
    ck refused.status == sfsPathUnavailable
    ck refused.origin == soNone
    ck sourceAvailabilityFor(refused.status) == savAbsent

# ---------------------------------------------------------------------------

suite "CTUI-4 — source access through a real HeadlessDebugSession":

  for fixtureName in ExaminedFixtures:
    test "the source at the stop, both providers — " & fixtureName:
      inc examinedFixtures
      let resolution = resolveFixture(fixtureName)
      if resolution.outcome == foMissingPrereq:
        inc skippedFixtures
        let message = announceSkip(resolution)
        ck message.startsWith(MissingPrereqSkipPrefix)
        ck resolution.tracePath.len == 0
        skip()
      else:
        inc verifiedFixtures
        let h = openHarness(resolution.tracePath)
        defer: h.closeHarness()

        ck h.providers.len == 2
        ck h.providers[0].kind == spkCtfsMaterialized
        ck h.providers[1].kind == spkDapSource
        ck h.permissiveProviders.len == 2
        ck h.permissiveProviders[0].kind == spkCtfsMaterialized

        # THE SAME BODY, ONCE PER IMPLEMENTATION.
        for provider in h.providers:
          h.vm.discardHeldText()
          checkProviderServesTheDebuggersFile(h, provider)
          checkUnavailableGenerationDegrades(h, provider)

        # A path in no recording is refused, not served off this machine's disk
        # under the recording's identity.
        checkForeignPathIsNotServedAsTheRecordings(h)

        # And the sharper form of the same question: a path that CLIMBS OUT of
        # the payload root. Both read sides resolved `..` through the OS, in
        # opposite steps, and certified the result as the recording's copy.
        checkEscapingPathIsRefusedByBothProviders(h)

        # And now step, asserting at every stop that the two independent
        # acquisition paths still name the same line of the same file, from the
        # same kind of source.
        checkBothProvidersAgree(h)
        for _ in 1 .. StepsPerFixture:
          h.session.stepForward()
          # The session grows measurably per stop unless its event buffer is
          # drained; draining is part of stepping here rather than an
          # optimisation left to the reader.
          discard h.session.drainEvents()
          checkBothProvidersAgree(h)

  test "every fixture was examined, and the assertion tally proves it":
    removeFile(foreignSourcePath)
    # Verification-Harness-Traps §4b: the membership is knowable, so the
    # control is the COUNT. §4c: the tally is derived from the run's own shape,
    # so an arm that returned early without asserting reddens this case.
    ck examinedFixtures == ExaminedFixtures.len
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    # An all-skipped run is a FAILURE, not a pass. A source-access suite in
    # which no source was accessed has established nothing.
    ck verifiedFixtures >= 1
    let expected =
      verifiedFixtures * ChecksPerVerifiedFixture +
      skippedFixtures * ChecksPerSkippedFixture +
      ChecksSummaryCase
    ck countedAssertions == expected
