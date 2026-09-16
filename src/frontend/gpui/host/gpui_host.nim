## gpui/host/gpui_host.nim — PLAT-20. **The GPUI front-end's native host: the
## only part of it that opens a recording, and the reason this directory
## carries no `.sdk-consumer` marker.**
##
## ## The exemption is the ABSENCE of a marker, which is why it is stated
##
## `src/frontend/tui/host/`'s own header makes this argument and
## `ci/test/sdk-facade-boundary.sh` records it by name: `backend/stdio_backend`
## and `viewmodel/headless_session` are the two modules `codetracer_embed`
## deliberately withholds, and they are the only ones that spawn a local
## `replay-server` for a `.ct` folder on disk. A front-end living outside this
## repository could not open a local trace through the sanctioned surface at
## all; the capability is not smuggled in, it is isolated in one named
## directory on the far side of the line. The same sentence is true here, word
## for word, which is why the same shape is used.
##
## ## THIS MODULE DOES NOT RE-DERIVE `tui/host/native_host.nim`, AND THAT IS
## ## A DECISION WITH A COST
##
## `openLocalTrace`, `resolveTraceFolder`, `traceFolderProblem`,
## `findReplayServer` and `replayServerRemedy` are not TERMINAL concerns — they
## are "open a local recording" concerns, and every one of them would be
## byte-identical here. Verification-Harness-Traps §14a is the entry about what
## happens when a second author re-derives a solved problem in a second
## directory: *"the problem was solved, in this repository, in a file the second
## author had read. Re-derivation threw the solution away and then hid the loss
## behind a green run."* Its example is an import extractor whose second copy
## missed a spelling the first handled; `traceFolderProblem` has exactly that
## character (it knows that a recording is a *directory* holding `trace.bin`, or
## `rr/`, or a `.ct` container) and a second copy of it would be one more place
## to get that wrong.
##
## So this module imports the terminal front-end's host for those five, and the
## cost is named rather than hidden: **`src/frontend/gpui/host/` now depends on
## `src/frontend/tui/host/`, which is a front-end depending on a front-end.**
## The right home is a neutral `src/frontend/host/` that both import, and moving
## it is a rename across two front-ends' suites rather than PLAT-20's diff. It
## is recorded as a residue in PLAT-20's status block so the next person counts
## it rather than rediscovers it.
##
## What this module does NOT take from there is `stdoutIsTerminal` and the
## terminal-capability negotiation, because those really are terminal concerns
## and a GPUI binary that consulted `isatty` would be answering a question
## nobody asked it.

## ## PLAT-22 — THE SOURCE SERVICE, AND WHY IT IS THE HOST'S
##
## The GPUI editor reads a `SourceVM`, and the replay session does not own one:
## `HeadlessDebugSession` builds `editorVM`, `stateVM`, `flowVM` and the rest,
## and `SourceVM` is constructed by whoever has a `SourceProvider` — which means
## whoever may read files. Measured 2026-09-16, the repository had exactly one
## production `createSourceVM` call site and it was `tui/host/tui_session.nim`.
##
## So this module gains the same pair, for the same reason that one is in
## `tui/host/`: acquiring a file is a HOST capability. `SourceVM` itself
## performs no I/O and sends no request — its own header makes that a contract —
## so the split is the same one everywhere: the VM computes WHAT it needs, the
## host acquires it.
##
## `allowWorkingTree = false`, copied deliberately rather than reconsidered. A
## source pane that silently read the file off disk when the recording's payload
## was unopenable would show a user the code they have NOW for a recording made
## against the code they had THEN, and the provenance the editor draws
## (`EditorSurface.provenance`) exists to make that difference visible — it
## cannot if the provider papers over it.

when defined(js):
  {.error: "src/frontend/gpui/host is native-only: it spawns replay-server.".}

import std/strutils

import codetracer_embed

import ../../view_vocabulary/editor_surface

import tui/host/native_host
export native_host

# PLAT-22. The working-tree reader, for the same reason and at the same cost as
# `native_host` above: `editProjectProblem`, `listProjectFiles` and
# `readProjectFile` are "open a project" concerns rather than terminal ones, and
# every one of them would be byte-identical here. `readProjectFile`'s
# containment check is on the RESOLVED path rather than on the spelling — a
# `relative` of `../../etc/passwd` normalises outside the project and a check
# against the string before resolution would pass it — which is precisely the
# kind of thing §14a says a second copy gets wrong.
#
# It widens PLAT-20's residue 2 from one import to two and from one call site to
# four. The remedy is unchanged and still a rename: a neutral
# `src/frontend/host/` both front-ends import.
import tui/host/edit_host
export edit_host

# The one adapter this front-end needs from the withheld half: a
# `DapStdioBackend` presented as the SDK's `BackendService`.
#
# Re-exported from HERE rather than imported in `main.nim`, so the whole of
# this front-end's reach past `codetracer_embed` is in one file that the
# boundary gate can read — which is what the directory split is for.
import backend/stdio_backend
export stdio_backend

import ../../version_gpui

proc gpuiFrontEndVersion*(): string =
  ## The version this binary reports. One function, so `--version` and any
  ## future about-box cannot part.
  GpuiFrontEndVersion

proc openGpuiTrace*(traceFolder: string): HeadlessDebugSession =
  ## Spawn `replay-server` on `traceFolder` and complete the DAP handshake.
  ##
  ## A thin naming of `native_host.openLocalTrace` rather than a second
  ## implementation — see the module header. It exists so this front-end's
  ## call sites read in this front-end's vocabulary and so the dependency has
  ## exactly one site, which is what makes the residue above a one-line move
  ## rather than a sweep.
  ##
  ## No `DapReadBound` is threaded: CTUI-14's read bound exists because a
  ## stalled adapter can wedge a TERMINAL a user cannot get back, and a window
  ## that has not opened yet is not in that state. A GPUI equivalent is
  ## PLAT-21's, when there is a pane whose data can stall.
  if traceFolder.strip().len == 0:
    raise newException(TuiHostError,
      "codetracer-gpui: name a recording folder")
  openLocalTrace(traceFolder)

const GpuiSourceOverscan* = 6
  ## Lines held above and below the viewport. The terminal's number, and the
  ## same reasoning: the overscan is what makes a one-line step a read out of
  ## the held window rather than a round trip, and six is a step of six in
  ## either direction before the provider is asked again.

type
  GpuiSourceService* = ref object
    ## The `SourceVM` the editor reads, and the provider that fills it.
    ##
    ## A PAIR AND NOT TWO FIELDS ON THE SHELL, because the shell is renderer-
    ## free AND backend-free: `HeadlessApp.openSession` takes its backend by
    ## injection and never constructs one, and a shell that owned a provider
    ## would own a thing that opens files. This is the host's.
    vm*: SourceVM
    provider*: SourceProvider
    store*: ReplayDataStore

proc newGpuiSourceService*(session: HeadlessDebugSession;
                           traceFolder: string;
                           viewportHeight: int): GpuiSourceService =
  ## Build the source window for a live session.
  let store = session.session.store
  let vm = createSourceVM(store, session.session.editorVM)
  vm.setViewport(height = max(1, viewportHeight), overscan = GpuiSourceOverscan)
  GpuiSourceService(
    vm: vm,
    provider: newCtfsSourceProvider(traceFolder, allowWorkingTree = false),
    store: store)

proc serveWindow*(s: GpuiSourceService) =
  ## Follow the execution pointer and serve every line the window then lacks.
  ##
  ## The two halves of `followAndRequest` belong together and in this order:
  ## `followExecutionPointer` moves the window, `requestMissing` trims the held
  ## range to the NEW window and then asks for the gap. Reversed, the trim runs
  ## against the old window and the editor asks for lines it is about to scroll
  ## away from.
  if s.isNil or s.vm.isNil:
    return
  for request in s.vm.followAndRequest():
    var captured = SourceFetch(status: sfsProviderUnavailable,
                               detail: "the provider callback never ran")
    # SEEDED WITH A STATUS THAT CANNOT BE MISTAKEN FOR SUCCESS, and drained.
    # `SourceFetchStatus`'s zero value is `sfsAvailable`, and
    # `async_compat.onComplete` defers a callback even on an already-complete
    # native future — so a callback that never ran would read as an EMPTY FILE
    # rather than as a failure, and an empty file is a pane of blank lines over
    # a working debugger. This is the second call site of that trap in this
    # repository and it is repeated deliberately rather than because it is
    # likely: `tui/host/tui_session.serveSourceWindow` carries the same seed and
    # the same comment.
    s.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
    drainSourceCallbacks()
    discard s.store.applySourceFetch(s.vm, captured)

proc availability*(s: GpuiSourceService): SourceAvailability =
  ## Page-Descriptions.md §14's source axis for this session.
  ##
  ## READ HERE RATHER THAN IN `main.nim`, because `main.nim` is the wiring and
  ## a wiring module that reached three levels into a store to pull a signal out
  ## would be the place the next reader adds a fourth. `savAbsent` when there is
  ## no store, which is the honest answer for a session that has not opened —
  ## and is the answer that makes the editor say so rather than certify nothing.
  if s.isNil or s.store.isNil:
    return savAbsent
  s.store.degraded.sourceAvailability.val

proc close*(s: GpuiSourceService) =
  ## Drop the reactive root. VM-first ordering is the caller's, as in
  ## `tui_session.close`: each `dispose` releases a root that still reads the
  ## store, so the store must outlive them.
  if s.isNil or s.vm.isNil:
    return
  s.vm.dispose()
