## sdk/source_provider.nim
##
## `SourceProvider` — the acquisition seam behind `SourceVM`.
##
## ## What this is, and why it is a seam rather than a function
##
## `SourceVM` (viewmodels/source_vm.nim) owns *which* lines of *which revision*
## a source pane needs, and deliberately performs no I/O. This module is the
## only place that goes and gets them, and it does so behind ONE interface with
## two implementations:
##
##   `spkCtfsMaterialized`  the trace container's own bundled sources, unpacked
##                          into the trace folder's `files/` payload by
##                          `src/ct/trace/ctfs_sources.nim` — the code that
##                          already does this for the desktop, reused rather
##                          than reimplemented. Native only: it reads files.
##   `spkDapSource`         the DAP `source` request, answered by the replay
##                          engine over whatever `BackendService` is injected.
##                          Compiles and runs on both backends, and is the only
##                          route a consumer that never touches a filesystem
##                          (a browser session over a worker) can take.
##
## Which one an open trace uses is decided by `selectSourceProvider`, from the
## `TraceSource` it was opened with, not by the caller guessing.
##
## ## The failure that matters, and why it is typed
##
## Serving the wrong revision is worse than serving nothing: the pane looks
## right, the line numbers line up, and the user reads a build that never ran.
## So every answer is a `SourceFetch` carrying a `SourceFetchStatus`, and a
## provider that cannot honour the requested `(path, sourceGeneration,
## sourceDigest)` triple says so instead of falling back to a revision it does
## have. `sourceAvailabilityFor` maps the status onto the `SourceAvailability`
## axis the store already carries, so the condition surfaces through
## Page-Descriptions.md §14's existing "No verified source" row —
## `EditorVM.degradedState` and `SourceVM.degradedState` — and no new message is
## invented for it.
##
## ## Provenance is part of the answer, on BOTH implementations
##
## Neither implementation may report text as verified unless it knows the text
## is the recording's. Both can fall back to a read of a machine's working tree
## — the CTFS one reads this machine, the DAP one asks an engine that may read
## the replay host — and that answer is legitimate, but it is `sfsUnverified` /
## `soWorkingTree`, never `sfsAvailable`.
##
## The DAP arm could not honour that until the engine started saying where its
## bytes came from. It does now: `SourceResponseBody.sourceOrigin`
## (`src/db-backend/src/dap_types.rs`) is `payload`, `working-tree` or — on a
## refusal — `unavailable`, and `newDapSourceProvider` maps those onto the same
## three outcomes `newCtfsSourceProvider` produces for the same three
## situations. This is not decoration: without it a client cannot tell an
## engine that resolved the recording's copy from one that quietly read a
## same-named file off the replay host, and CTUI-4's own verification found the
## engine doing exactly the latter for every Noir recording while reporting it
## as an ordinary success.
##
## The one asymmetry left is deliberate and typed: an engine older than the
## provenance contract answers with no `sourceOrigin` at all, and that is
## `sfsUnverified` / `soBackend` — text this client cannot characterise is not
## text it may certify.
##
## ## Layering
##
## This module is inside the Embed SDK (`codetracer_embed` exports it), so a
## front-end's `app/` layer acquires source through the sanctioned surface and
## never opens a file itself. The native filesystem half is behind
## `when not defined(js)` and the DAP half is not, which is what lets the whole
## module compile on the JS backend where `codetracer_embed` also has to build.

import std/json

import isonim/core/[computation, async_compat]

import ../store/[replay_data_store, degraded_state]
import ../backend/backend_service
import ../viewmodels/source_vm
import trace_source

when not defined(js):
  import std/[os, strutils, tables]
  # The trace container's source payload is unpacked by `ct` itself; this is
  # the READ side of exactly that layout, and it calls the same writer rather
  # than re-deriving where the bytes went.
  import ../../../ct/trace/ctfs_sources

type
  SourceFetchStatus* = enum
    ## What a provider was able to say about one `SourceLineRequest`.
    ##
    ## Five values rather than a `bool` plus a message, because a source pane
    ## renders a different thing for each and §14 distinguishes three of them:
    ## "no source of any kind here" is `savAbsent`, "source, but not verifiably
    ## this build" is `savUnverified`, and those two must not collapse.
    sfsAvailable
      ## Text, from the recording's own copy of this revision. Verified.
    sfsUnverified
      ## Text, but from a source the provider cannot tie to the recorded
      ## revision — a working-tree read. Rendered, and rendered as unverified.
    sfsGenerationUnavailable
      ## The path is known; the REQUESTED revision is not. No text is returned,
      ## because the text this provider holds belongs to another build.
    sfsPathUnavailable
      ## Nothing at all for this path: a stripped library, a synthetic frame, a
      ## container that bundled no sources.
    sfsProviderUnavailable
      ## This provider cannot serve at all — the backend refused the request,
      ## the transport failed, or the trace has no payload for it to read.

  SourceOrigin* = enum
    ## Where the bytes in a `SourceFetch` came from. Reported so a consumer can
    ## tell "the recording carried this" from "we read the file that happens to
    ## be on this machine", which is the whole difference between verified and
    ## unverified source.
    soNone
    soTracePayload
      ## The RECORDING's own copy. On the CTFS arm that is the trace folder's
      ## `files/` payload; on the DAP arm it is whichever recorded copy the
      ## engine resolved — the container's bundled raw source views or that
      ## same `files/` payload — reported as `sourceOrigin: "payload"`.
    soRegisteredRevision  ## a revision a host supplied for this generation
    soWorkingTree
      ## The recorded path, read off a machine rather than out of the
      ## recording. On the CTFS arm that machine is this one; on the DAP arm it
      ## is the replay host, reported as `sourceOrigin: "working-tree"`.
    soBackend
      ## The replay engine answered DAP `source` but did NOT say where the
      ## bytes came from — an engine older than the provenance contract. The
      ## answer is text, but it is text this client cannot characterise, so it
      ## is reported `sfsUnverified` rather than trusted.

  SourceFetch* = object
    ## One provider's complete answer to one request.
    status*: SourceFetchStatus
    origin*: SourceOrigin
    request*: SourceLineRequest
      ## Echoed back so an asynchronous caller can match an answer to the
      ## question without keeping a correlation table.
    revision*: SourceRevision
      ## The revision the text belongs to. For a successful fetch this equals
      ## the request's triple; it is carried explicitly so `applySourceFetch`
      ## hands `SourceVM.fulfill` an identity it read from the ANSWER rather
      ## than from the store, which may have moved on.
    firstLine*: int
      ## 1-based line number of `lines[0]`.
    lines*: seq[string]
      ## Empty for every non-text status.
    totalLineCount*: int
      ## The file's length in lines, or 0 when unknown.
    detail*: string
      ## Human-readable diagnosis. Never the thing a pane renders — that is
      ## §14's row — but what a log or a `--verbose` surface shows.

  SourceProviderKind* = enum
    spkCtfsMaterialized = "ctfs-materialized"
    spkDapSource = "dap-source"

  SourceProvider* = ref object
    ## The seam. A plain object with proc fields, the same IsoNim
    ## service-injection shape `BackendService` uses, so a consumer can supply
    ## its own without this package growing a class hierarchy.
    kind*: SourceProviderKind
    name*: string
      ## Names the concrete source, so a diagnostic says which trace folder or
      ## which backend could not answer.
    state*: RootRef
      ## The implementation's own state, when it has any that a caller may
      ## legitimately reach — today only the CTFS provider's revision registry,
      ## which a host adds to through `registerSourceRevision`. A typed field
      ## rather than a closure's captured environment, because reaching into
      ## `supportsProc.rawEnv` would be a cast whose correctness nothing checks.
    supportsProc*: proc(): bool
      ## Whether this provider can serve the open trace AT ALL. Cheap and
      ## synchronous; a per-request refusal is `sfsProviderUnavailable`.
    fetchProc*: proc(request: SourceLineRequest;
                     onResult: proc(fetch: SourceFetch))
      ## Acquire one contiguous line range. The answer arrives through the
      ## callback rather than as a return value because one implementation is a
      ## round trip to another process.
      ##
      ## **THE CALLBACK MAY NOT HAVE RUN WHEN `fetch` RETURNS**, and that is
      ## true on the native backend as well as on JS — it is not a JS-only
      ## nicety. `spkCtfsMaterialized` answers inline, but `spkDapSource` goes
      ## through `BackendService`, and `async_compat.onComplete` registers an
      ## `addCallback` even on an already-completed `asyncdispatch` future, so
      ## the continuation runs on the next `poll`. A caller that read a `var`
      ## the callback assigns, immediately after `fetch` returns, would see the
      ## zero value — whose `status` is `sfsAvailable` and whose `lines` are
      ## empty, i.e. a silent empty file.
      ##
      ## So: call `drainSourceCallbacks()` after issuing a fetch, or do the work
      ## inside the callback. `drainSourceCallbacks` is exported from this
      ## module for exactly that reason.

# ---------------------------------------------------------------------------
# The typed degradation
# ---------------------------------------------------------------------------

func sourceAvailabilityFor*(status: SourceFetchStatus): SourceAvailability =
  ## Map a fetch status onto Page-Descriptions.md §14's source axis.
  ##
  ## `sfsGenerationUnavailable` is `savUnverified` rather than `savAbsent`
  ## deliberately: there IS source for this path, so §14's supply-sources
  ## action has something to attach to — the user can point the debugger at the
  ## build that was recorded. `savAbsent` is reserved for the case where there
  ## is nothing to supply sources FOR.
  case status
  of sfsAvailable: savVerified
  of sfsUnverified: savUnverified
  of sfsGenerationUnavailable: savUnverified
  of sfsPathUnavailable: savAbsent
  of sfsProviderUnavailable: savUnverified

func hasText*(fetch: SourceFetch): bool =
  ## Whether this answer carries source text. False for every degraded status,
  ## including the ones a careless caller might treat as "empty file".
  fetch.status in {sfsAvailable, sfsUnverified}

proc supports*(provider: SourceProvider): bool =
  ## Whether the provider can serve the open trace. A nil provider supports
  ## nothing, which is the answer `selectSourceProvider` needs when a consumer
  ## passes an unconfigured slot.
  if provider.isNil or provider.supportsProc.isNil: false
  else: provider.supportsProc()

proc drainSourceCallbacks*() =
  ## Run whatever a provider's transport has resolved but not yet delivered.
  ##
  ## A named door onto `async_compat.drainPlatformCallbacks`, so a consumer of
  ## this facade can satisfy `fetchProc`'s asynchrony contract without
  ## importing IsoNim's async plumbing and without knowing that
  ## `asyncdispatch` defers a callback on a future that is ALREADY complete.
  ## That last fact is the trap: it makes the DAP provider look synchronous in
  ## a debugger and behave asynchronously in a test, and the symptom is a
  ## zero-valued `SourceFetch` — `sfsAvailable`, no lines — which reads as an
  ## empty file rather than as an answer that has not arrived.
  drainPlatformCallbacks()

proc fetch*(provider: SourceProvider; request: SourceLineRequest;
            onResult: proc(fetch: SourceFetch)) =
  ## Acquire `request`. A nil provider answers `sfsProviderUnavailable` rather
  ## than crashing, so a front-end that has not selected one yet degrades
  ## instead of dying.
  if provider.isNil or provider.fetchProc.isNil:
    onResult(SourceFetch(
      status: sfsProviderUnavailable,
      origin: soNone,
      request: request,
      detail: "no source provider is configured for this session"))
    return
  provider.fetchProc(request, onResult)

# ---------------------------------------------------------------------------
# Wiring an answer into the ViewModel layer
# ---------------------------------------------------------------------------

proc applySourceFetch*(store: ReplayDataStore; vm: SourceVM;
                       fetch: SourceFetch): bool =
  ## Record the §14 axis this answer establishes, and hand the text (if any) to
  ## `SourceVM`.
  ##
  ## Returns whether the VM adopted the text. A degraded answer returns false
  ## AND drops whatever the VM was holding for this revision, because the one
  ## outcome that must not survive a failed fetch is the previous revision's
  ## text still on screen under the new revision's identity.
  store.setSourceAvailability(sourceAvailabilityFor(fetch.status))
  if not fetch.hasText:
    if fetch.revision.isEmpty or fetch.revision == vm.revision.val:
      vm.discardHeldText()
    return false
  vm.fulfill(fetch.revision, fetch.firstLine, fetch.lines, fetch.totalLineCount)

# ---------------------------------------------------------------------------
# Slicing a whole file down to the requested window
# ---------------------------------------------------------------------------

func sliceForRequest*(allLines: seq[string];
                      request: SourceLineRequest): tuple[firstLine: int;
                                                         lines: seq[string]] =
  ## The requested range of `allLines`, clamped to the file.
  ##
  ## A request that starts past the end of the file yields an EMPTY slice at
  ## the requested start, not a slice of the last line: the pane asked about
  ## lines that do not exist, and inventing text for them is the blank-line
  ## failure `SourceVM` refuses one layer up.
  let first = max(1, request.firstLine)
  let last = min(request.lastLine, allLines.len)
  if last < first:
    return (first, @[])
  (first, allLines[first - 1 .. last - 1])

func splitSourceLines*(text: string): seq[string] =
  ## Split source text into lines, without inventing a trailing empty line for
  ## a file that ends in a newline.
  ##
  ## `strutils.splitLines` reports "a\n" as `@["a", ""]`, which would make
  ## every well-formed source file one line longer than it is and put a blank
  ## line under the last statement in every pane that renders `totalLineCount`.
  result = @[]
  var current = ""
  for ch in text:
    if ch == '\n':
      if current.len > 0 and current[^1] == '\r':
        current.setLen(current.len - 1)
      result.add(current)
      current = ""
    else:
      current.add(ch)
  if current.len > 0:
    if current[^1] == '\r':
      current.setLen(current.len - 1)
    result.add(current)

# ---------------------------------------------------------------------------
# Implementation 1: the CTFS-materialized payload (native)
# ---------------------------------------------------------------------------

when not defined(js):
  type
    RegisteredRevision* = object
      ## A revision a host supplied out of band.
      ##
      ## Live HCR is the reason this exists: a patched generation's source is
      ## never inside the container, because the container was written before
      ## the patch. The desktop already carries the same idea as
      ## `EditorService.pendingDiskSourceByPath` (`src/frontend/ui/editor.nim`),
      ## keyed by the same `path / generation / digest` triple; this is that
      ## mechanism on the SDK side of the boundary.
      filePath*: string
      sourceDigest*: string

    CtfsSourceProviderState = ref object of RootObj
      traceDir: string
      recordedGeneration: int
      allowWorkingTree: bool
      materialized: bool
      revisions: Table[string, RegisteredRevision]
        ## Keyed by `path & "\n" & $generation`.

  proc revisionKey(path: string; generation: int): string =
    path & "\n" & $generation

  proc findCtContainer(dir: string): string =
    ## The `.ct` container in a trace folder, or "" when there is none.
    if not dirExists(dir):
      return ""
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".ct"):
        return path
    ""

  proc payloadPathFor(traceDir, recordedPath: string): string =
    ## Where `recordedPath`'s bytes live under `traceDir/files/`, ACCORDING TO
    ## THE WRITER.
    ##
    ## `safePayloadPath` is the writer's own function
    ## (`src/ct/trace/ctfs_sources.nim`), called rather than mirrored: a second
    ## spelling of the mapping would drift silently, and the symptom would be
    ## "this trace has no sources" for every path.
    traceDir / "files" / safePayloadPath(recordedPath)

  const GodotSchemes = ["res://", "user://"]
    ## Godot records GDScript source under its virtual-filesystem scheme, which
    ## is neither a real path nor portable (a `res:` component is invalid on
    ## Windows). The engine's `expr_loader::strip_godot_scheme` names the same
    ## two; the walk below must strip them for the same reason it splits on both
    ## separators — so the two read sides map one recorded path onto one
    ## candidate list.

  proc stripGodotScheme(path: string): string =
    ## `path` without a leading `res://` / `user://`, unchanged when it has
    ## none.
    for scheme in GodotSchemes:
      if path.startsWith(scheme):
        return path[scheme.len .. ^1]
    path

  proc pathComponents(path: string): seq[string] =
    ## The components of `path` as the suffix walk maps them under a bundle
    ## root: split on BOTH separators, with empty and `.` components dropped.
    ##
    ## Both separators, because a recording made on Windows and replayed on
    ## Linux still names its files with backslashes. `.` is dropped rather than
    ## pushed so `a/./b` and `a/b` name the same payload entry — which is also
    ## what `expr_loader::bundle_path_components` does, and these two lists have
    ## to match candidate for candidate.
    ##
    ## `..` is deliberately NOT dropped. Dropping it would silently rewrite
    ## `a/../b` into `a/b`, which may be an entirely different file; the caller
    ## skips any suffix containing one instead, which refuses rather than
    ## reinterprets.
    result = @[]
    var current = ""
    for ch in path:
      if ch == '/' or ch == '\\':
        if current.len > 0 and current != ".":
          result.add(current)
        current = ""
      else:
        current.add(ch)
    if current.len > 0 and current != ".":
      result.add(current)

  proc isWithinPayloadRoot(root, candidate: string): bool =
    ## Whether `candidate` — built by mapping a RECORDED path under `root` — is
    ## genuinely inside `root`.
    ##
    ## A recorded path is untrusted input: it is whatever string a recorder
    ## interned into a container this process did not write, and containers are
    ## downloaded, copied and shared. `root / "../../secret.txt"` is a *textual*
    ## join, but `fileExists` and `readFile` are not — both resolve `..` through
    ## the OS — so without this check the provider returned a file from outside
    ## the trace and reported it `sfsAvailable` / `soTracePayload`, i.e. "this is
    ## the recording's own copy", to a consumer that had set
    ## `allowWorkingTree = false` precisely because it would render nothing less.
    ##
    ## TWO CHECKS, because one is not enough:
    ##
    ##   1. lexical — `normalizedPath` collapses `..` textually, and the result
    ##      must still sit under the root;
    ##   2. physical — `..` is not the only way out of a directory. A symlink
    ##      inside an unpacked payload pointing anywhere on the host is the same
    ##      escape by another mechanism, so **a symlink that leaves the payload
    ##      root is in scope and is refused**: `expandFilename` resolves symlinks
    ##      on both sides and the candidate must still be under the root. Both
    ##      sides, because a trace folder is routinely reached THROUGH a symlink
    ##      (`/tmp` → `/private/tmp` on macOS) and resolving only the candidate
    ##      would refuse every legitimate answer there.
    ##
    ## When the platform cannot resolve a path — `expandFilename` raises for
    ## anything that does not exist — the lexical check stands alone. This
    ## mirrors `expr_loader::is_within_bundle_root` on the engine side.
    let normRoot = normalizedPath(absolutePath(root))
    let normCandidate = normalizedPath(absolutePath(candidate))
    if not normCandidate.isRelativeTo(normRoot):
      return false
    try:
      result = expandFilename(candidate).isRelativeTo(expandFilename(root))
    except OSError, IOError:
      result = true

  proc resolvePayload(traceDir, recordedPath: string): string =
    ## The payload file for `recordedPath`, or "" when the trace has none.
    ##
    ## TWO LAYOUTS EXIST IN THIS WORKSPACE, and both were measured rather than
    ## assumed, which is why this is a search rather than one `join`:
    ##
    ##   * a `ct`-imported CTFS container (the Python recorder's `calc`
    ##     fixture) writes `files/<absolute path with its root stripped>` —
    ##     `files/home/…/test-programs/calc/main.py` — which is exactly
    ##     `safePayloadPath`'s answer;
    ##   * the Noir recorder's container (`noir_space_ship`) writes
    ##     PROJECT-RELATIVE paths — `files/src/main.nr` — while the location the
    ##     engine reports for the same file is absolute.
    ##
    ## So the writer's mapping is tried first, exactly, and a failure then walks
    ## the recorded path's suffixes from LONGEST to shortest. Longest first is
    ## what makes the answer deterministic when a container bundles two files
    ## with the same basename at different depths: the deeper agreement wins,
    ## and a one-component match is only reached when nothing longer exists.
    ##
    ## ## `files/` IS A CONTAINMENT BOUNDARY AT EVERY STEP
    ##
    ## Both steps go through `isWithinPayloadRoot`, and the walk additionally
    ## skips any suffix that still contains `..`. Guarding only the exact step —
    ## which `safePayloadPath` already did — is what this function shipped with,
    ## and the unguarded walk answered a recorded `/../../outside/secret.txt`
    ## with the file outside the trace, `sfsAvailable` / `soTracePayload`, under
    ## `allowWorkingTree = false`.
    ##
    ## ## Exactly how this relates to the engine's `resolve_bundled_source`
    ##
    ## The WALK is the same algorithm on both sides, and that equality is
    ## load-bearing: `source_access_test` compares the two providers' answers at
    ## every stop. Same component split (both separators, `.` and empty
    ## dropped), same Godot-scheme strip, same longest-first order, same `..`
    ## skip, same containment check.
    ##
    ## The EXACT step is deliberately not identical, and cannot be: each side
    ## applies its OWN writer's mapping, and this workspace has two writers.
    ## Here it is `ctfs_sources.safePayloadPath` — strip a leading `/` or a
    ## `C:\` drive prefix, no scheme handling, because the `ct` importer that
    ## writes `files/` does not strip one either. There it is
    ## `expr_loader::bundled_source_path` — strip a leading `/`, strip the Godot
    ## scheme — because the engine's raw-source-view extractor writes THAT
    ## layout. Both exact steps are skipped outright for a recorded path
    ## carrying a `..` component, so both sides answer such a path identically:
    ## from the walk, or not at all.
    let filesRoot = traceDir / "files"
    let components = pathComponents(recordedPath.stripGodotScheme)

    var hasParentComponent = false
    for component in components:
      if component == "..":
        hasParentComponent = true
        break

    # 1. The writer's exact mapping. Skipped for a `..` path rather than
    #    sanitized: `safePayloadPath` answers such a path with the bare
    #    filename, and taking that answer here would put this side's exact step
    #    ahead of the engine's walk for the same input. The walk below reaches
    #    the same bare filename as its LAST candidate, so nothing that was
    #    written is lost — it is just found in the same order the engine finds
    #    it.
    if not hasParentComponent:
      let exact = payloadPathFor(traceDir, recordedPath)
      if fileExists(exact) and isWithinPayloadRoot(filesRoot, exact):
        return exact

    # 2. The suffix walk, longest first.
    for start in 0 ..< components.len:
      var escapes = false
      for i in start ..< components.len:
        if components[i] == "..":
          escapes = true
          break
      if escapes:
        continue
      var candidate = filesRoot
      for i in start ..< components.len:
        candidate = candidate / components[i]
      if fileExists(candidate) and isWithinPayloadRoot(filesRoot, candidate):
        return candidate
    ""

  proc ensureMaterialized(state: CtfsSourceProviderState) =
    ## Unpack the container's bundled sources once, if they are not on disk.
    ##
    ## `ct` normally does this at import time, so the common case is that
    ## `files/` already exists and this is a `dirExists` check. It is done here
    ## as well because a provider handed a bare `.ct` folder — a fixture
    ## directory, a downloaded container — must still be able to answer.
    if state.materialized:
      return
    state.materialized = true
    if dirExists(state.traceDir / "files"):
      return
    let container = findCtContainer(state.traceDir)
    if container.len == 0:
      return
    try:
      discard materializeCtfsSources(container, state.traceDir)
    except CatchableError:
      # A container that cannot be unpacked is reported per-request as
      # `sfsPathUnavailable`, with the path that was looked for. Raising here
      # would take a whole session down over one unreadable trace.
      discard

  proc registerSourceRevision*(provider: SourceProvider; path: string;
                               generation: int; filePath: string;
                               sourceDigest: string = "") =
    ## Tell a CTFS provider where generation `generation` of `path` lives.
    ##
    ## Called by a host that knows something the container cannot: an HCR
    ## coordinator that has just patched a function, an importer that kept the
    ## pre-patch snapshot. Without it, a request for any generation other than
    ## the recorded one is `sfsGenerationUnavailable` — which is the correct
    ## answer, and the one this call turns into text.
    doAssert provider.kind == spkCtfsMaterialized,
      "registerSourceRevision is only meaningful for a CTFS source provider"
    let state = CtfsSourceProviderState(provider.state)
    state.revisions[revisionKey(path, generation)] =
      RegisteredRevision(filePath: filePath, sourceDigest: sourceDigest)

  proc newCtfsSourceProvider*(traceDir: string; recordedGeneration: int = 0;
                              allowWorkingTree: bool = true): SourceProvider =
    ## A provider over one trace folder's materialized sources.
    ##
    ## `recordedGeneration` is the generation the container's payload IS. It is
    ## 0 for every recording this workspace produces today (`replay-server`
    ## reports `sourceGeneration: 0` for materialized traces — see
    ## `src/db-backend/src/db.rs`), and it is a parameter rather than a constant
    ## so an HCR-aware recording can say otherwise instead of being
    ## misinterpreted.
    ##
    ## `allowWorkingTree` permits a last-resort read of the recorded path off
    ## this machine when the container bundled no payload for it. That answer is
    ## reported as `sfsUnverified` / `soWorkingTree` and NEVER as verified,
    ## because the file on this disk may be any build at all.
    let state = CtfsSourceProviderState(
      traceDir: traceDir,
      recordedGeneration: recordedGeneration,
      allowWorkingTree: allowWorkingTree,
      materialized: false,
      revisions: initTable[string, RegisteredRevision]())

    proc supportsProc(): bool =
      ## A trace folder supports this provider when it either already carries a
      ## `files/` payload or carries a container one can be unpacked from.
      if not dirExists(state.traceDir):
        return false
      if dirExists(state.traceDir / "files"):
        return true
      findCtContainer(state.traceDir).len > 0

    proc fetchProc(request: SourceLineRequest;
                   onResult: proc(fetch: SourceFetch)) =
      var answer = SourceFetch(
        request: request,
        revision: SourceRevision(
          path: request.path,
          sourceGeneration: request.sourceGeneration,
          sourceDigest: request.sourceDigest))

      if request.path.len == 0:
        answer.status = sfsPathUnavailable
        answer.detail = "the request names no path"
        onResult(answer)
        return

      state.ensureMaterialized()

      # 1. A revision a host registered for exactly this generation wins: it is
      #    the only thing that can be right for a generation the container
      #    predates.
      let key = revisionKey(request.path, request.sourceGeneration)
      var resolved = ""
      var origin = soNone
      var registeredDigest = ""
      if state.revisions.hasKey(key):
        resolved = state.revisions[key].filePath
        registeredDigest = state.revisions[key].sourceDigest
        origin = soRegisteredRevision
      elif request.sourceGeneration == state.recordedGeneration:
        # 2. The recording's own copy of the recorded generation.
        let payload = resolvePayload(state.traceDir, request.path)
        if payload.len > 0:
          resolved = payload
          origin = soTracePayload
        elif state.allowWorkingTree and fileExists(request.path):
          resolved = request.path
          origin = soWorkingTree
      else:
        # 3. A generation this provider does not hold. NOT served from the
        #    payload: that text is another build's, and rendering it under this
        #    generation's identity is the failure this whole seam is shaped
        #    around.
        answer.status = sfsGenerationUnavailable
        answer.detail = "trace " & state.traceDir & " holds generation " &
          $state.recordedGeneration & " of " & request.path &
          ", and no revision is registered for generation " &
          $request.sourceGeneration
        onResult(answer)
        return

      if resolved.len == 0:
        answer.status = sfsPathUnavailable
        answer.detail = "no bundled source for " & request.path & " under " &
          (state.traceDir / "files") &
          (if state.allowWorkingTree: " and it is not readable on this machine"
           else: "")
        onResult(answer)
        return

      # A digest the request carries and the revision contradicts is a wrong
      # build, not a near miss. Only checked when BOTH sides have one: no
      # recorder in this workspace emits a source digest today, so requiring one
      # would refuse every real request.
      if request.sourceDigest.len > 0 and registeredDigest.len > 0 and
          request.sourceDigest != registeredDigest:
        answer.status = sfsGenerationUnavailable
        answer.detail = "digest mismatch for " & request.path &
          " generation " & $request.sourceGeneration & ": requested " &
          request.sourceDigest & ", registered revision carries " &
          registeredDigest
        onResult(answer)
        return

      var text = ""
      try:
        text = readFile(resolved)
      except CatchableError as e:
        answer.status = sfsPathUnavailable
        answer.detail = "could not read " & resolved & ": " & e.msg
        onResult(answer)
        return

      let allLines = splitSourceLines(text)
      let sliced = sliceForRequest(allLines, request)
      answer.status = if origin == soWorkingTree: sfsUnverified else: sfsAvailable
      answer.origin = origin
      answer.firstLine = sliced.firstLine
      answer.lines = sliced.lines
      answer.totalLineCount = allLines.len
      answer.detail = resolved
      onResult(answer)

    SourceProvider(
      kind: spkCtfsMaterialized,
      name: "ctfs:" & traceDir,
      state: state,
      supportsProc: supportsProc,
      fetchProc: fetchProc)

# ---------------------------------------------------------------------------
# Implementation 2: the DAP `source` request
# ---------------------------------------------------------------------------

const DapSourceCommand* = "source"
  ## The DAP request this provider issues
  ## (https://microsoft.github.io/debug-adapter-protocol/specification#Requests_Source).
  ## Named rather than spelled inline so `backend/dap_commands.nim` and this
  ## module cannot disagree about the string.

const
  DapSourceOriginField = "sourceOrigin"
    ## The engine's provenance field on a `source` response body — what the
    ## CodeTracer extension `dap_types::SourceOriginKind` serialises into.
  DapOriginPayload = "payload"
    ## The engine resolved the RECORDING's own copy.
  DapOriginWorkingTree = "working-tree"
    ## The engine read the replay host instead. Rendered, never verified.
  DapOriginUnavailable = "unavailable"
    ## Carried on a FAILED response: this engine has no source for this path.
    ## Distinct from a refusal for any other reason, which is why it exists —
    ## see `onSuccess` below.
  DapAllowWorkingTreeField = "allowWorkingTree"
    ## The request-side half of the same contract.
    ##
    ## These five strings are the wire contract with
    ## `src/db-backend/src/dap_types.rs`. They are named here, once, because
    ## the alternative is five string literals scattered through a callback,
    ## and a typo in any of them degrades silently into "the engine did not
    ## characterise its answer" — a legitimate state, so nothing would fail.
    ## They are deliberately NOT exported: they are this provider's transport
    ## detail, and a consumer that needs the distinction reads the typed
    ## `SourceFetch.origin` instead. What keeps the two sides honest is
    ## `src/tests/gui/tests/source-access/source_access_test.nim`, which drives
    ## a real `replay-server` and asserts the resulting `origin` on every arm.

proc newDapSourceProvider*(backend: BackendService;
                           allowWorkingTree: bool = true): SourceProvider =
  ## A provider that asks the replay engine for the file, over whatever
  ## transport `BackendService` is.
  ##
  ## This is the only route available to a consumer with no filesystem — a
  ## browser session driving the WASM engine through a worker — and it is the
  ## route that keeps working when the trace folder is not on the machine the
  ## front-end runs on.
  ##
  ## `sourceGeneration` and `sourceDigest` ride along inside the DAP `source`
  ## object. DAP's own `Source` has no field for either, and adding one is
  ## legitimate: the specification says a client may attach arbitrary data to a
  ## `Source`, and the engine's own `Source` deserialiser ignores members it
  ## does not know. An engine that ignores them answers with the recorded
  ## revision, which it then names in the response — see the identity check
  ## below, which is what turns "ignored my generation" into a typed
  ## degradation rather than into the wrong build's text.
  ##
  ## ## Provenance, and why this arm cannot do without it
  ##
  ## The engine's resolution order ends in a read of the REPLAY HOST's working
  ## tree, which may be any build at all and may not belong to this recording
  ## at all. `success: true` alone cannot tell that apart from the recording's
  ## own copy, so this provider would have to map every success to
  ## `sfsAvailable` — i.e. call an unverifiable answer verified, while the CTFS
  ## arm right above takes the same distinction seriously through
  ## `allowWorkingTree` / `soWorkingTree`. Two implementations of one seam
  ## disagreeing about verified-versus-unverified is the seam failing at the
  ## thing it exists for.
  ##
  ## So the engine names the origin of every answer and this provider maps it:
  ## `payload` is `sfsAvailable`, `working-tree` is `sfsUnverified`, and an
  ## engine that names NOTHING is also `sfsUnverified` — text this client
  ## cannot characterise is not text it may certify.
  ##
  ## `allowWorkingTree` mirrors `newCtfsSourceProvider`'s parameter of the same
  ## name and is sent to the engine, so a consumer that must not render
  ## unverifiable source gets a refusal (`sfsPathUnavailable`) rather than a
  ## labelled fallback. It defaults to `true` for the same reason the CTFS
  ## provider's does: the desktop has always read the recorded path when the
  ## container carried nothing.
  let b = backend
  let allowWorkingTreeRead = allowWorkingTree

  proc supportsProc(): bool =
    not b.isNil and not b.sendProc.isNil

  proc fetchProc(request: SourceLineRequest;
                 onResult: proc(fetch: SourceFetch)) =
    var base = SourceFetch(
      request: request,
      revision: SourceRevision(
        path: request.path,
        sourceGeneration: request.sourceGeneration,
        sourceDigest: request.sourceDigest))

    if request.path.len == 0:
      base.status = sfsPathUnavailable
      base.detail = "the request names no path"
      onResult(base)
      return
    if not supportsProc():
      base.status = sfsProviderUnavailable
      base.detail = "no backend is connected"
      onResult(base)
      return

    let args = %*{
      "source": {
        "path": request.path,
        "sourceGeneration": request.sourceGeneration,
        "sourceDigest": request.sourceDigest,
      },
      "sourceReference": 0,
      DapAllowWorkingTreeField: allowWorkingTreeRead,
    }

    proc onSuccess(response: JsonNode) =
      var answer = base
      if response.isNil or response.kind != JObject:
        answer.status = sfsProviderUnavailable
        answer.detail = "the backend returned no response body"
        onResult(answer)
        return
      # Read once: the provenance field is on the body of a REFUSAL as well as
      # on the body of an answer, and it is the discriminator in both.
      let body = response.getOrDefault("body")
      let servedOrigin =
        if body.isNil or body.kind != JObject: ""
        else: body.getOrDefault(DapSourceOriginField).getStr("")
      if not response.getOrDefault("success").getBool(false):
        if servedOrigin == DapOriginUnavailable:
          # The engine ANSWERED, and its answer is "there is no source for this
          # path here". That is `sfsPathUnavailable` — the same status the CTFS
          # arm gives for the same question — so the two implementations put
          # the same §14 row on screen (`savAbsent`, "no source of any kind").
          answer.status = sfsPathUnavailable
          answer.detail = "the backend has no source for " & request.path &
            ": " & response.getOrDefault("message").getStr("(no message)")
        else:
          # An engine that does not implement DAP `source` answers exactly here,
          # and it is reported as a PROVIDER failure rather than as "this file
          # has no source": the file may be perfectly available through the
          # other implementation of this seam.
          answer.status = sfsProviderUnavailable
          answer.detail = "backend refused `" & DapSourceCommand & "`: " &
            response.getOrDefault("message").getStr("(no message)")
        onResult(answer)
        return
      if body.isNil or body.kind != JObject or not body.hasKey("content"):
        answer.status = sfsPathUnavailable
        answer.detail = "the backend answered `" & DapSourceCommand &
          "` with no content for " & request.path
        onResult(answer)
        return

      # The engine names the revision it served. When it names a DIFFERENT one
      # the answer is refused: an engine that silently substituted the recorded
      # generation for the requested one would otherwise put the wrong build's
      # text under the right build's line numbers, which is precisely what the
      # identity triple exists to prevent.
      let servedGeneration =
        if body.hasKey("sourceGeneration"): body["sourceGeneration"].getInt(request.sourceGeneration)
        else: request.sourceGeneration
      let servedDigest =
        if body.hasKey("sourceDigest"): body["sourceDigest"].getStr("")
        else: request.sourceDigest
      if servedGeneration != request.sourceGeneration or
          (request.sourceDigest.len > 0 and servedDigest.len > 0 and
           servedDigest != request.sourceDigest):
        answer.status = sfsGenerationUnavailable
        answer.detail = "requested generation " & $request.sourceGeneration &
          " of " & request.path & ", backend served generation " &
          $servedGeneration
        onResult(answer)
        return

      # WHERE the engine got the bytes decides whether they are verified. An
      # engine that does not say is treated as unverified rather than trusted:
      # the alternative is certifying text whose provenance this client cannot
      # establish, which is exactly the failure this seam is shaped around.
      case servedOrigin
      of DapOriginPayload:
        answer.status = sfsAvailable
        answer.origin = soTracePayload
        answer.detail = "dap:" & DapSourceCommand & " (" & DapOriginPayload & ")"
      of DapOriginWorkingTree:
        answer.status = sfsUnverified
        answer.origin = soWorkingTree
        answer.detail = "dap:" & DapSourceCommand & " served " & request.path &
          " from the replay host's working tree, not from the recording"
      else:
        answer.status = sfsUnverified
        answer.origin = soBackend
        answer.detail = "dap:" & DapSourceCommand &
          " answered without naming an origin" &
          (if servedOrigin.len > 0: " this client knows (`" & servedOrigin & "`)"
           else: " (no `" & DapSourceOriginField & "` in the response body)") &
          "; the text cannot be tied to the recording"

      let allLines = splitSourceLines(body["content"].getStr(""))
      let sliced = sliceForRequest(allLines, request)
      answer.firstLine = sliced.firstLine
      answer.lines = sliced.lines
      answer.totalLineCount = allLines.len
      onResult(answer)

    proc onError(message: string) =
      var answer = base
      answer.status = sfsProviderUnavailable
      answer.detail = "`" & DapSourceCommand & "` failed: " & message
      onResult(answer)

    b.send(DapSourceCommand, args).onComplete(onSuccess, onError)

  SourceProvider(
    kind: spkDapSource,
    name: "dap:" & DapSourceCommand,
    supportsProc: supportsProc,
    fetchProc: fetchProc)

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

proc selectSourceProvider*(candidates: openArray[SourceProvider]): SourceProvider =
  ## The first candidate that supports the open trace, or `nil`.
  ##
  ## Order is the caller's, and it is the caller's decision because the two
  ## implementations are not interchangeable in cost: the CTFS payload is a
  ## local file read, the DAP request is a round trip through the replay
  ## engine.
  for candidate in candidates:
    if candidate.supports():
      return candidate
  nil

proc providerForTrace*(source: TraceSource;
                       backend: BackendService): SourceProvider =
  ## The provider an open trace supports, decided from the `TraceSource` it was
  ## opened with rather than from a caller's guess.
  ##
  ## A local folder gets the CTFS payload first and the backend second: the
  ## payload is on the same machine, needs no round trip, and is the recording's
  ## own copy. Every other kind — a container over HTTP, in OPFS, in memory, or
  ## behind a consumer's `BlockSource` — has no filesystem to read, so the
  ## engine is the only thing that can answer.
  when not defined(js):
    if source.kind == tskLocalFolder:
      return selectSourceProvider([
        newCtfsSourceProvider(source.folder),
        newDapSourceProvider(backend)])
  selectSourceProvider([newDapSourceProvider(backend)])
