## CTUI-4 — one path, two revisions, and the refusal in between.
##
## ## The defect this suite exists to prevent
##
## A source pane that shows the WRONG revision is worse than one that shows
## nothing. The text is plausible, the line numbers line up, the execution
## pointer sits on a statement — and the user is reading a build that never ran.
## Nothing about the screen says so.
##
## So the seam's contract is: a provider that cannot honour the requested
## `(path, sourceGeneration, sourceDigest)` triple returns a TYPED degradation
## and no text, and the degradation is Page-Descriptions.md §14's existing
## "No verified source" row rather than a new message. This file asserts both
## halves — that the right revision resolves to the right bytes, and that a
## revision the provider does not hold produces `pdNoVerifiedSource` while the
## ViewModel's held text is dropped rather than left on screen.
##
## ## What is real here
##
## No mocks. Two revisions of one path are two REAL files on disk with
## genuinely different contents, resolved through the production
## `spkCtfsMaterialized` provider: generation 0 from a trace folder's `files/`
## payload (where `ctfs_sources.safePayloadPath` puts it), generation 1 from a
## revision a host registered — which is how live HCR actually works, because
## the patched generation's text is not in the container at all; the container
## predates the patch. The desktop already carries the same mechanism as
## `EditorService.pendingDiskSourceByPath` (`src/frontend/ui/editor.nim`), keyed
## by the same triple.
##
## `MockBackendService` appears once, as the transport `createReplayDataStore`
## requires. No command is sent through it and nothing is asserted about it; the
## subject is the filesystem provider and the store's §14 axis.
##
## ## Test-quality rules
##
## Every helper that calls `check` is a `template`. There is no skip, no
## `when false`, no early return: this suite writes every file it reads.
##
## Native only, and rejected from `vm-unit-js` in `ci/lib/test-lane-files.sh`:
## its subject is the filesystem provider, and `std/os` file writes have no
## `nim js` equivalent. The DAP provider's half of the same contract — an
## engine that serves a different generation from the one requested — is
## asserted against a REAL `replay-server` in
## `src/tests/gui/tests/source-access/source_access_test.nim`, because a
## refusal asserted only against a stub is a refusal nobody has seen.
##
## Compile + run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_source_provider_revisions.nim

import std/[os, strutils, unittest]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../../backend/[backend_service, mock_backend]
import ../../store/[replay_data_store, degraded_state]
import ../../viewmodels/[editor_vm, source_vm]
import ../../sdk/source_provider

const
  RecordedPath = "/opt/ctui4/revisions/hot.src"
    ## Absolute, and deliberately not a path that exists on any host running
    ## this suite: the provider must resolve through the recording's payload
    ## and the registered revisions, never through a working-tree read that
    ## would happen to succeed on the author's machine.
  UnrecordedPath = "/opt/ctui4/revisions/never_recorded.src"

  Generation0Text = "def total(values):\n    return sum(values)\n"
    ## The recorded build.
  Generation1Text = "def total(values):\n    # patched in place by HCR\n" &
                    "    return sum(v for v in values if v > 0)\n"
    ## The patched build. Deliberately a DIFFERENT LENGTH as well as different
    ## text, so a test that accidentally read the wrong file would fail on the
    ## line count even if a string comparison were somehow satisfied.

  Generation0Digest = "sha256:gen0"
  Generation1Digest = "sha256:gen1"

type Harness = object
  root: string
  traceDir: string
  store: ReplayDataStore
  editor: EditorVM
  vm: SourceVM
  provider: SourceProvider

proc newHarness(): Harness =
  ## A trace folder holding generation 0 in its payload, plus generation 1
  ## registered from a separate real file.
  let root = getTempDir() / "ctui4-revisions-" & $getCurrentProcessId()
  removeDir(root)
  createDir(root)
  let traceDir = root / "trace"

  let payload = traceDir / "files" / RecordedPath[1 .. ^1]
  createDir(payload.parentDir)
  writeFile(payload, Generation0Text)

  let patched = root / "hcr" / "generation1" / "hot.src"
  createDir(patched.parentDir)
  writeFile(patched, Generation1Text)

  let store = createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())
  store.updateDebuggerPosition(rrTicks = 0, file = RecordedPath, line = 1)
  let editor = createEditorVM(store)
  let vm = createSourceVM(store, editor)
  vm.setViewport(height = 10, overscan = 2)

  let provider = newCtfsSourceProvider(traceDir, allowWorkingTree = false)
  provider.registerSourceRevision(RecordedPath, 1, patched, Generation1Digest)

  Harness(root: root, traceDir: traceDir, store: store, editor: editor,
          vm: vm, provider: provider)

proc teardown(h: Harness) =
  h.vm.dispose()
  h.editor.dispose()
  removeDir(h.root)

proc fetchOnce(h: Harness; path: string; generation: int;
               digest: string = ""; firstLine = 1;
               lastLine = 50): SourceFetch =
  ## One request through the real provider. Asserts nothing, so it is a proc.
  var captured: SourceFetch
  h.provider.fetch(
    SourceLineRequest(path: path, sourceGeneration: generation,
                      sourceDigest: digest,
                      firstLine: firstLine, lastLine: lastLine),
    proc(fetch: SourceFetch) = captured = fetch)
  captured

proc stopAt(h: Harness; path: string; generation: int; digest = "") =
  ## Move the debugger to a revision, so `SourceVM`'s identity follows.
  h.store.updateDebuggerPosition(
    rrTicks = uint64(generation), file = path, line = 1,
    sourceGeneration = generation, sourceDigest = digest)

# ---------------------------------------------------------------------------
# Assertion templates
# ---------------------------------------------------------------------------

template checkServedText(fetch: SourceFetch; expected: seq[string]) =
  check fetch.status == sfsAvailable
  check fetch.firstLine == 1
  check fetch.lines == expected
  check fetch.totalLineCount == expected.len

template checkDegradedWithNoText(fetch: SourceFetch;
                                 expectedStatus: SourceFetchStatus) =
  ## A degraded answer carries the status AND no text. Both halves matter: a
  ## status nobody reads is as bad as text nobody should have.
  check fetch.status == expectedStatus
  check not fetch.hasText
  check fetch.lines.len == 0
  check fetch.detail.len > 0

template checkPaneShowsNoVerifiedSource(h: Harness) =
  ## §14's row, read from the ViewModel a view actually binds to — and read
  ## from BOTH, because `SourceVM.degradedState` is `EditorVM`'s memo rather
  ## than a second one computing the same thing.
  check h.store.degraded.sourceAvailability.val == savUnverified
  check h.editor.degradedState.val == pdNoVerifiedSource
  check h.vm.degradedState.val == pdNoVerifiedSource
  check h.editor.instructionLevelStepping.val

# ---------------------------------------------------------------------------

suite "CTUI-4 — two generations of one path resolve to different content":

  test "generation 0 resolves to the recording's own copy":
    let h = newHarness()
    defer: h.teardown()
    let fetch = h.fetchOnce(RecordedPath, 0)
    checkServedText(fetch, @["def total(values):", "    return sum(values)"])
    check fetch.origin == soTracePayload
    check fetch.revision.sourceGeneration == 0

  test "generation 1 resolves to the registered patched revision":
    let h = newHarness()
    defer: h.teardown()
    let fetch = h.fetchOnce(RecordedPath, 1)
    checkServedText(fetch, @[
      "def total(values):",
      "    # patched in place by HCR",
      "    return sum(v for v in values if v > 0)"])
    check fetch.origin == soRegisteredRevision
    check fetch.revision.sourceGeneration == 1

  test "the two generations differ in content and in length":
    # Stated as its own case because it is the PREMISE of every refusal below:
    # if the two revisions were the same bytes, "served the wrong revision"
    # and "served the right one" would be indistinguishable and this whole
    # file would assert nothing.
    let h = newHarness()
    defer: h.teardown()
    let gen0 = h.fetchOnce(RecordedPath, 0)
    let gen1 = h.fetchOnce(RecordedPath, 1)
    check gen0.lines != gen1.lines
    check gen0.lines.len == 2
    check gen1.lines.len == 3
    check gen0.lines[1] != gen1.lines[1]

suite "CTUI-4 — the payload root is a containment boundary":
  ## A recorded path is UNTRUSTED INPUT — it is whatever string a recorder
  ## interned into a container this process did not write, and containers are
  ## downloaded, copied and shared. `traceDir / "files" / <recorded>` is a
  ## textual join, but `fileExists` and `readFile` are not: both resolve `..`
  ## through the OS. Before `isWithinPayloadRoot` existed, `resolvePayload`'s
  ## suffix walk did exactly that and this provider answered a file from
  ## outside the trace with `sfsAvailable` / `soTracePayload` — "the recording's
  ## own copy" — even when built with `allowWorkingTree = false`, the one
  ## setting whose whole purpose is to refuse anything less.
  ##
  ## The real-stack half of this is `source_access_test`'s
  ## `checkEscapingPathIsRefusedByBothProviders`, which asks a real
  ## `replay-server` the same question so the engine and this provider are
  ## pinned to the same answer. What is here is the mechanism-by-mechanism
  ## coverage that a real trace folder cannot conveniently carry: each case
  ## first asserts the escape is GENUINELY REACHABLE, because a refusal of a
  ## path that resolves to nothing is free.

  template checkRefusedAsAbsent(fetch: SourceFetch) =
    ## A refusal, and not a differently-shaped success: no text, no lines, the
    ## exact status, and no claim that this was the recording's copy.
    check fetch.status == sfsPathUnavailable
    check not fetch.hasText
    check fetch.lines.len == 0
    check fetch.origin == soNone

  test "a recorded `..` cannot climb out of the payload root":
    let h = newHarness()
    defer: h.teardown()
    let outside = h.root / "outside_the_trace.src"
    writeFile(outside, "OUTSIDE THE TRACE\n")
    # The escape, spelled out: from `<traceDir>/files`, these hops reach it.
    let hops = relativePath(outside, h.traceDir / "files")
    check hops.startsWith("..")
    check fileExists(h.traceDir / "files" / hops)
    checkRefusedAsAbsent(h.fetchOnce("/" & hops, 0))
    # …and the control: the recording's own file still resolves, so the
    # refusal above is a refusal of the escape and not of the provider.
    check h.fetchOnce(RecordedPath, 0).status == sfsAvailable

  test "a symlink that leaves the payload root is refused; one that stays is served":
    # `..` is not the only way out of a directory, and a payload is unpacked
    # from a container this process did not write. The stance is stated in
    # `isWithinPayloadRoot`: a symlink out of the payload is IN SCOPE and is
    # refused, and this case is what says so.
    let h = newHarness()
    defer: h.teardown()
    let outsideDir = h.root / "outside"
    createDir(outsideDir)
    writeFile(outsideDir / "secret.src", "OUTSIDE THE TRACE\n")
    createSymlink(outsideDir, h.traceDir / "files" / "escape")
    check fileExists(h.traceDir / "files" / "escape" / "secret.src")
    checkRefusedAsAbsent(h.fetchOnce("/escape/secret.src", 0))

    # The other half, without which the assertion above would also pass if
    # symlinks were refused outright: one that stays inside is still served.
    createSymlink(h.traceDir / "files" / "opt", h.traceDir / "files" / "inside")
    let served = h.fetchOnce("/inside/ctui4/revisions/hot.src", 0)
    check served.status == sfsAvailable
    check served.origin == soTracePayload

  test "a `.` component is filtered rather than refused, in both steps":
    # `a/./b` and `a/b` name the same payload entry, and the engine's
    # `expr_loader::bundle_path_components` drops `.` identically. A
    # containment check is exactly the kind of change that could turn a
    # harmless component into a refusal, so both steps are asserted: the
    # writer's exact mapping (the recorded path as the payload was written)
    # and the suffix walk (a longer recorded prefix the exact mapping misses).
    let h = newHarness()
    defer: h.teardown()
    let viaExact = "/opt/ctui4/./revisions/hot.src"
    let viaWalk = "/some/other/checkout/opt/ctui4/./revisions/hot.src"
    check not fileExists(h.traceDir / "files" / "some")
    for path in [viaExact, viaWalk]:
      let fetch = h.fetchOnce(path, 0)
      check fetch.status == sfsAvailable
      check fetch.origin == soTracePayload
      check fetch.lines == @["def total(values):", "    return sum(values)"]

suite "CTUI-4 — an unavailable revision degrades, and never substitutes":

  test "a generation the provider does not hold is a typed refusal":
    let h = newHarness()
    defer: h.teardown()
    let fetch = h.fetchOnce(RecordedPath, 2)
    checkDegradedWithNoText(fetch, sfsGenerationUnavailable)
    # The decisive assertion: it did NOT fall back to generation 0, whose text
    # the provider is holding one directory away.
    check fetch.lines.len == 0
    check fetch.revision.sourceGeneration == 2
    check sourceAvailabilityFor(fetch.status) == savUnverified

  test "a digest that contradicts the registered revision is a refusal":
    let h = newHarness()
    defer: h.teardown()
    let honest = h.fetchOnce(RecordedPath, 1, Generation1Digest)
    check honest.status == sfsAvailable
    let contradicted = h.fetchOnce(RecordedPath, 1, Generation0Digest)
    checkDegradedWithNoText(contradicted, sfsGenerationUnavailable)

  test "a path with no recorded source at all is ABSENT, not unverified":
    # §14 keeps `savAbsent` and `savUnverified` apart because the action
    # differs: there is nothing for a supply-sources affordance to attach to on
    # a stripped frame. Collapsing them would offer a button that cannot work.
    let h = newHarness()
    defer: h.teardown()
    let fetch = h.fetchOnce(UnrecordedPath, 0)
    checkDegradedWithNoText(fetch, sfsPathUnavailable)
    check sourceAvailabilityFor(fetch.status) == savAbsent

  test "every fetch status maps to a §14 source-availability value":
    # Walked exhaustively so a sixth status cannot be added without deciding
    # what a pane renders for it.
    var seen = 0
    for status in SourceFetchStatus:
      inc seen
      case status
      of sfsAvailable: check sourceAvailabilityFor(status) == savVerified
      of sfsUnverified: check sourceAvailabilityFor(status) == savUnverified
      of sfsGenerationUnavailable:
        check sourceAvailabilityFor(status) == savUnverified
      of sfsPathUnavailable: check sourceAvailabilityFor(status) == savAbsent
      of sfsProviderUnavailable:
        check sourceAvailabilityFor(status) == savUnverified
    check seen == 5

suite "CTUI-4 — the refusal reaches the pane as §14's existing row":

  test "a held revision is dropped when the next one cannot be served":
    let h = newHarness()
    defer: h.teardown()

    # Stopped in generation 0: the pane holds the recorded text.
    let served = h.fetchOnce(RecordedPath, 0)
    check h.store.applySourceFetch(h.vm, served)
    check h.vm.holdsCurrentRevision
    let firstRead = h.vm.lineAt(2)
    check firstRead.kind == srkHeld
    if firstRead.kind == srkHeld:
      check firstRead.text == "    return sum(values)"
    check h.editor.degradedState.val == pdNone

    # A live-HCR patch bumps the generation to one nobody registered.
    h.stopAt(RecordedPath, 2)
    let refused = h.fetchOnce(RecordedPath, 2)
    check not h.store.applySourceFetch(h.vm, refused)

    # The pane renders §14's row, and the previous revision's text is GONE —
    # not still on screen under the new revision's line numbers.
    checkPaneShowsNoVerifiedSource(h)
    check not h.vm.holdsCurrentRevision
    check h.vm.heldLines.val.len == 0
    let afterRead = h.vm.lineAt(2)
    check afterRead.kind == srkRequest
    if afterRead.kind == srkRequest:
      check afterRead.request.sourceGeneration == 2

  test "a served generation restores the pane to undegraded":
    let h = newHarness()
    defer: h.teardown()
    h.stopAt(RecordedPath, 2)
    check not h.store.applySourceFetch(h.vm, h.fetchOnce(RecordedPath, 2))
    checkPaneShowsNoVerifiedSource(h)

    h.stopAt(RecordedPath, 1, Generation1Digest)
    let served = h.fetchOnce(RecordedPath, 1, Generation1Digest)
    check h.store.applySourceFetch(h.vm, served)
    check h.store.degraded.sourceAvailability.val == savVerified
    check h.editor.degradedState.val == pdNone
    check h.vm.degradedState.val == pdNone
    let read = h.vm.lineAt(2)
    check read.kind == srkHeld
    if read.kind == srkHeld:
      check read.text == "    # patched in place by HCR"

  test "an answer for a revision the debugger has left is not adopted":
    # The late-arrival case. A fetch issued for generation 0 can land after the
    # debugger has already stepped into generation 1; adopting it would put the
    # old build's text under the new build's identity.
    let h = newHarness()
    defer: h.teardown()
    let stale = h.fetchOnce(RecordedPath, 0)
    check stale.status == sfsAvailable
    h.stopAt(RecordedPath, 1, Generation1Digest)
    check not h.store.applySourceFetch(h.vm, stale)
    check h.vm.heldLines.val.len == 0

  test "an unconfigured provider degrades instead of crashing":
    let h = newHarness()
    defer: h.teardown()
    var captured: SourceFetch
    SourceProvider(nil).fetch(
      SourceLineRequest(path: RecordedPath, firstLine: 1, lastLine: 1),
      proc(fetch: SourceFetch) = captured = fetch)
    checkDegradedWithNoText(captured, sfsProviderUnavailable)
    check not SourceProvider(nil).supports()

  test "selectSourceProvider picks the first provider that supports the trace":
    let h = newHarness()
    defer: h.teardown()
    let unusable = newCtfsSourceProvider(h.root / "no-such-trace")
    check not unusable.supports()
    check h.provider.supports()
    let chosen = selectSourceProvider([unusable, h.provider])
    check not chosen.isNil
    if not chosen.isNil:
      check chosen.kind == spkCtfsMaterialized
      check chosen.name == "ctfs:" & h.traceDir
    check selectSourceProvider([unusable]).isNil
