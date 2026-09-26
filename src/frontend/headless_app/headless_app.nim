## SDK-CONSUMER: the headless application entrypoint. It is the counterpart
## of `viewmodel/app/isonim_app.nim`'s `mountIsoNimApp` for a host with no
## DOM, and it exists partly to prove the Embed SDK facade is sufficient: it
## composes a whole multi-session debugger shell out of `codetracer_embed`
## and nothing else, so any reach past the facade is a build failure rather
## than a review note.
##
## headless_app/headless_app.nim — boot a debugger shell with no renderer.
##
## ## What this is
##
## `viewmodel/app/isonim_app.nim` is the app entrypoint for a host that has a
## DOM: it looks up `#isonim-app`, builds a `WebRenderer`, and mounts eleven
## panels. It opens with `when not defined(js): {.error.}`, so on the C
## backend there is no application entrypoint at all — only ViewModels and
## the tests that drive them.
##
## This module is the entrypoint for a host that has no DOM: Electron-free,
## display-free, browser-free. It owns
##
##   * **the session set** — several `DebuggerSession`s in one process, which
##     is CodeTracer-Embed-SDK.md §3.1's "multi-session in one page";
##   * **which one is active**, and
##   * **each session's layout**, as a `layout_model.Layout` — the tree AND
##     its docked panes (a bare `LayoutNode` until PLAT-4's closing pass,
##     2026-09-26; see the slot's field).
##
## The last of those is the point. The desktop keeps the same state in
## `ReplaySession.savedLayoutConfig`, whose type is
## `GoldenLayoutResolvedConfig`, and switches between sessions by destroying
## and recreating a GoldenLayout tree (`src/frontend/ui/session_switch.nim`).
## That is the coupling BlockTracer.milestones.org M2a names as the last
## renderer-bound part of the replay core, and here activating a session is a
## field assignment.
##
## ## What it is not
##
## It is not a *process*. `HeadlessApp` takes its `BackendService` by
## injection, exactly as `DebuggerSession` does, and never constructs one:
## spawning `replay-server` is `viewmodel/headless_session.nim`'s job (native
## only, and deliberately outside the facade), and a browser host supplies a
## worker transport instead. A host that wants a child process wraps this
## module; this module cannot reach a `std/osproc` from where it sits, and
## `ci/test/sdk-facade-boundary.sh` is what keeps that true.

import std/[json, options, tables]

import codetracer_embed

import ./layout_model
export layout_model

type
  HeadlessSessionId* = distinct int
    ## Identity of a slot within one `HeadlessApp`. Distinct so a slot id and
    ## a `DebuggerSession.id` — which is process-global and keeps counting
    ## across apps — cannot be confused for one another.

  HeadlessSessionSlot* = ref object
    ## One session, plus the shell state that belongs to it rather than to
    ## the session itself.
    id*: HeadlessSessionId
    title*: string
      ## What a host would put on the session tab.
    session*: DebuggerSession
      ## The SDK session. Owns the ViewModel graph and the lifecycle phase.
    layout*: Layout
      ## This session's arrangement. Owned per slot — never shared, so
      ## activating a tab in one session cannot move it in another. `clone`
      ## in `layout_model` is what makes that true for a caller who passes
      ## the same tree twice.
      ##
      ## A WHOLE `Layout` — tree, docked panes, version — and not the bare
      ## `LayoutNode` it was until PLAT-4's closing pass (2026-09-26). While
      ## it was a node, a front-end that docked a pane could not hand that
      ## arrangement to the session: the GPUI shell synchronised only
      ## `layout.tree` back onto the slot, so `saveLayouts` wrote a document
      ## with the docked pane in NEITHER place, and a terminal binding had to
      ## hold its own `Layout` beside the session's node — two authorities
      ## for one screen (Layout-ViewModel §5.1). Holding the `Layout` here is
      ## what makes the session's arrangement and a binding's ONE value.

  HeadlessApp* = ref object
    ## The application. Not reactive, on purpose: every *pane's* state is
    ## already a signal, and the shell's own state (which session, which tab)
    ## is read once per host redraw. Adding signals here would put an
    ## `Owner` scope around application startup and buy nothing a host
    ## cannot get by reading `activeSlot` — see the note on
    ## `AppViewModel` for the same reasoning one layer down.
    slots: seq[HeadlessSessionSlot]
    activeId: HeadlessSessionId
    nextId: int
    disposed: bool

  HeadlessAppError* = object of CatchableError
    ## Raised for a caller mistake — an unknown slot, a duplicate open, a
    ## call after `dispose`. A *session* failure is not this: that is
    ## `DebuggerSession.failure`, a signal, so a host can render a broken
    ## session instead of catching around every call.

const NoHeadlessSession* = HeadlessSessionId(-1)
  ## The active id of an app with no sessions.

proc `==`*(a, b: HeadlessSessionId): bool {.borrow.}
proc `$`*(id: HeadlessSessionId): string {.borrow.}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc newHeadlessApp*(): HeadlessApp =
  ## An application with no sessions. Constructing it sends nothing anywhere:
  ## like `newDebuggerSession`, creation is passive.
  HeadlessApp(slots: @[], activeId: NoHeadlessSession, nextId: 0,
              disposed: false)

proc raiseApp(msg: string) {.noreturn.} =
  raise newException(HeadlessAppError, msg)

proc requireLive(app: HeadlessApp) =
  if app.isNil:
    raiseApp("HeadlessApp is nil")
  if app.disposed:
    raiseApp("HeadlessApp has been disposed")

proc slotCount*(app: HeadlessApp): int =
  ## How many sessions are open.
  if app.isNil: 0 else: app.slots.len

proc slotIds*(app: HeadlessApp): seq[HeadlessSessionId] =
  result = @[]
  if app.isNil:
    return
  for s in app.slots:
    result.add(s.id)

proc slot*(app: HeadlessApp; id: HeadlessSessionId): HeadlessSessionSlot =
  ## The slot with `id`, or nil.
  if app.isNil:
    return nil
  for s in app.slots:
    if s.id == id:
      return s
  nil

proc activeSlot*(app: HeadlessApp): HeadlessSessionSlot =
  ## The active slot, or nil when there are no sessions.
  app.slot(app.activeId)

proc activeSessionId*(app: HeadlessApp): HeadlessSessionId =
  if app.isNil: NoHeadlessSession else: app.activeId

proc openSessionWith(app: HeadlessApp; backend: BackendService;
                     title: string; source: Layout; clock: ClockBase;
                     adopt: DebuggerSession): HeadlessSessionSlot

proc openSession*(app: HeadlessApp; backend: BackendService;
                  title: string = "";
                  layout: LayoutNode = nil;
                  clock: ClockBase = nil;
                  adopt: DebuggerSession = nil): HeadlessSessionSlot =
  ## Add a session over `backend` and make it active.
  ##
  ## `layout` is **deep-copied**: a caller who passes `defaultReplayLayout()`
  ## once and opens two sessions from it must not get two sessions sharing a
  ## tree. Passing nil means `defaultReplayLayout()`.
  ##
  ## Nothing is sent to `backend` here — the session is created in
  ## `dspCreated` and the panel ViewModels stay inert until `launch` or
  ## `attach`.
  ##
  ## ## `adopt`, AND THE DEFECT IT CLOSES (PLAT-22, 2026-09-16)
  ##
  ## A native host that spawns `replay-server` itself — `viewmodel/
  ## headless_session.nim` — performs the DAP handshake on the raw channel
  ## (it needs the blocking `waitForEvent` that `BackendService.onEvent` does
  ## not provide), builds a `DebuggerSession` over the same transport, and
  ## `attach`es it. That session is `dspReady`, its panel ViewModels are
  ## constructed, and its store is the one the host pushes every
  ## `ct/complete-move` into.
  ##
  ## A front-end that then called `openSession(backend)` got a **SECOND**
  ## session over the same transport: `dspCreated`, panel VMs nil, an empty
  ## store nothing writes to. `paneViewModel` answers nil for every pane of it
  ## and `paneIsLive` answers false — so the host held a live debugger and the
  ## shell drew *"waiting for the session to launch"* on every pane, for ever.
  ## Measured on the shipped `codetracer-gpui` against a real `calc` recording:
  ## five leaves, five `— waiting for the session to launch`, rc 0.
  ##
  ## Nothing went red because nothing read it: PLAT-20's leaves drew a pane's
  ## TITLE, and PLAT-21's suites drove `pane_views` with ViewModels taken
  ## straight from a real session rather than through a slot. **The one path
  ## that joins them is the one no test took.**
  ##
  ## `adopt` is how the host hands over the session it already has. It is
  ## ADDITIVE — a defaulted parameter, no field changes shape, no existing call
  ## site moves — which is the form PLAT-20's verification gate admits, and the
  ## alternative (a second `openAdoptedSession`) would be two doors onto one
  ## concept with the second one's callers free to drift.
  ##
  ## `backend` is still REQUIRED beside it, deliberately, and not derived from
  ## `adopt.backend`: the argument is what says which transport this slot
  ## belongs to, and a shell that read it off the session would have no way to
  ## refuse a session belonging to another one.
  let tree = if layout.isNil: defaultReplayLayout() else: layout.clone()
  openSessionWith(app, backend, title, initLayout(tree), clock, adopt)

proc openSession*(app: HeadlessApp; backend: BackendService;
                  title: string = "";
                  layout: Layout;
                  clock: ClockBase = nil;
                  adopt: DebuggerSession = nil): HeadlessSessionSlot =
  ## `openSession` over a whole `Layout` — docked panes included — for a
  ## host that restored or built one. Deep-copied, for the tree overload's
  ## reason, and validated as a whole: a layout whose docked pane is also
  ## placed is refused here exactly as a malformed tree is.
  openSessionWith(app, backend, title, layout.clone(), clock, adopt)

proc openSessionWith(app: HeadlessApp; backend: BackendService;
                     title: string; source: Layout; clock: ClockBase;
                     adopt: DebuggerSession): HeadlessSessionSlot =
  app.requireLive()
  if backend.isNil:
    raiseApp("openSession requires a BackendService; the shell never builds one")
  # `{}`: the shell declares no owned-pane set of its own — a session may
  # open over any arrangement the host chose — and says so here rather than
  # inheriting it (`validate(Layout)`'s `owned` has no default).
  let problems = source.validate({})
  if problems.len > 0:
    raiseApp("openSession was given an invalid layout: " & $problems[0].kind &
             " at '" & problems[0].path & "'")
  if not adopt.isNil and not clock.isNil:
    # REFUSED RATHER THAN SILENTLY IGNORED. The clock belongs to the session
    # and an adopted one already has its own, so honouring both is not
    # possible and discarding one quietly is how a test's virtual clock ends
    # up not being the clock the session reads.
    raiseApp("openSession: `adopt` brings its own clock; passing `clock` too " &
             "asks for two")
  let session =
    if not adopt.isNil: adopt
    elif clock.isNil: newDebuggerSession(backend)
    else: newDebuggerSession(backend, clock = clock)
  let slot = HeadlessSessionSlot(
    id: HeadlessSessionId(app.nextId),
    title: (if title.len > 0: title else: "session " & $app.nextId),
    session: session,
    layout: source)
  inc app.nextId
  app.slots.add(slot)
  app.activeId = slot.id
  slot

proc activate*(app: HeadlessApp; id: HeadlessSessionId): bool =
  ## Switch to a session. False, changing nothing, when `id` is unknown.
  ##
  ## No layout is saved and none is restored, because none was ever handed to
  ## a renderer: each slot has held its own tree the whole time. That is the
  ## entire difference from `session_switch.nim`, which must copy
  ## `data.ui.resolvedConfig` into `session.savedLayoutConfig` on the way out
  ## and call `callInitLayoutSafe` on the way back in.
  app.requireLive()
  if app.slot(id).isNil:
    return false
  app.activeId = id
  true

proc closeSession*(app: HeadlessApp; id: HeadlessSessionId;
                   disconnectBackend: bool = true): bool =
  ## Dispose and remove a session. False when `id` is unknown.
  ##
  ## `disconnectBackend = false` is for a host whose transport outlives the
  ## session — the `HeadlessDebugSession` case, where the DAP pipe to
  ## `replay-server` is owned by the harness and closing it here would take
  ## the process down early.
  app.requireLive()
  let s = app.slot(id)
  if s.isNil:
    return false
  s.session.dispose(disconnectBackend = disconnectBackend)
  var kept: seq[HeadlessSessionSlot] = @[]
  for other in app.slots:
    if other.id != id:
      kept.add(other)
  app.slots = kept
  if app.activeId == id:
    app.activeId =
      if app.slots.len > 0: app.slots[^1].id else: NoHeadlessSession
  true

proc dispose*(app: HeadlessApp; disconnectBackend: bool = true) =
  ## Dispose every session. Idempotent, like `DebuggerSession.dispose`.
  if app.isNil or app.disposed:
    return
  for s in app.slots:
    s.session.dispose(disconnectBackend = disconnectBackend)
  app.slots = @[]
  app.activeId = NoHeadlessSession
  app.disposed = true

proc isDisposed*(app: HeadlessApp): bool =
  not app.isNil and app.disposed

# ---------------------------------------------------------------------------
# Panes — where the layout model meets the ViewModels
# ---------------------------------------------------------------------------

proc paneViewModel*(slot: HeadlessSessionSlot; kind: PaneKind): ViewModel =
  ## The ViewModel behind a pane, or nil when the session has not been
  ## launched yet (the panel VMs are constructed by `initializePanelViewModels`
  ## and stay nil in `dspCreated`).
  ##
  ## The `case` is exhaustive and that is the load-bearing part: a value added
  ## to `PaneKind` without a ViewModel behind it does not compile, so the enum
  ## cannot drift into a list of names nothing renders. It is the same device
  ## `test_five_panes_drive_headlessly.nim` uses on `PaneDegradation`.
  if slot.isNil or slot.session.isNil:
    return nil
  let s = slot.session.session
  if s.isNil:
    return nil
  case kind
  of paneEditor: ViewModel(s.editorVM)
  of paneCalltrace: ViewModel(s.calltraceVM)
  of paneState: ViewModel(s.stateVM)
  of paneEventLog: ViewModel(s.eventLogVM)
  of paneDebugControls: ViewModel(s.debugControlsVM)
  of paneFlow: ViewModel(s.flowVM)
  of paneTimeline: ViewModel(s.timelineVM)
  of paneSearch: ViewModel(s.searchVM)
  of panePointList: ViewModel(s.pointListVM)
  of paneScratchpad: ViewModel(s.scratchpadVM)
  of paneShell: ViewModel(s.shellVM)
  of paneFileTree:
    # PLAT-41. THE RECORDING'S SOURCE TREE — the argument below, refuted.
    #
    # This arm returned `nil` for both panes, arguing that a replay session
    # has "no replay concept" of a file tree and that wiring `FilesystemVM`
    # would claim the WORKING tree. The reference front-end says otherwise: in
    # replay, the desktop's Files pane is the recording's OWN source folders
    # (`index/traces.sourceFoldersFromTracePaths` over the trace's
    # `paths.json`, listed from its `files/` store) — a tree the replay
    # session does own, and not the working tree. So a replay slot answers the
    # session's `fileTreeVM`, which holds exactly that, and the working tree
    # stays an edit-mode session's.
    ViewModel(s.fileTreeVM)
  of paneBuildOutput:
    # PLAT-16. NIL, AND THE EXHAUSTIVE `case` IS WORKING RATHER THAN BEING
    # WORKED AROUND.
    #
    # The guard above says "a value added to `PaneKind` without a ViewModel
    # behind it does not compile", and the point of that is that a pane must
    # not be a name nothing renders. This one is rendered — by the build pane
    # — but not from a `ReplaySession`: a build belongs to EDIT mode, whose
    # subject is the working tree rather than a recording
    # (CodeTracer-TUI-Edit-Mode.md §2), and the desktop draws no build output
    # in replay either. Answering `nil` says exactly what is true — *this
    # replay session has no ViewModel for that pane* — and `paneIsLive`
    # reports false.
    nil

proc paneIsLive*(slot: HeadlessSessionSlot; kind: PaneKind): bool =
  ## Whether the pane has a ViewModel to render. False for every pane of a
  ## session that has not launched — which is what makes "the shell starts
  ## sending nothing" observable rather than merely documented.
  not slot.paneViewModel(kind).isNil

proc visiblePanes*(slot: HeadlessSessionSlot): seq[PaneKind] =
  ## The panes this session currently shows.
  if slot.isNil: @[] else: slot.layout.visiblePanes()

proc activatePane*(slot: HeadlessSessionSlot; kind: PaneKind): bool =
  ## Bring a pane to the front of whatever stack holds it. False for a pane
  ## that is not placed — a DOCKED pane included, since it has no region to
  ## come to the front of.
  if slot.isNil: false else: slot.layout.tree.activate(kind)

proc livePanes*(slot: HeadlessSessionSlot): seq[PaneKind] =
  ## Every pane placed in the layout that also has a ViewModel behind it.
  ## The intersection is what a host iterates to render.
  result = @[]
  if slot.isNil:
    return
  for p in slot.layout.tree.allPanes():
    if slot.paneIsLive(p):
      result.add(p)

# ---------------------------------------------------------------------------
# Persistence — the replacement for saving `GoldenLayoutResolvedConfig`
# ---------------------------------------------------------------------------

proc saveLayouts*(app: HeadlessApp): JsonNode =
  ## Every session's layout, plus which one was active, as one versioned
  ## document. Titles are included because they are shell state too; a
  ## `TraceSource` is not, because re-opening a trace is the host's decision.
  ##
  ## Each session entry carries its tree under `layout` and its docked panes
  ## under `docked` — the two halves of a §6 layout document, beside the
  ## entry's `id` and `title`. `docked` is always present, even empty.
  result = newJObject()
  result["version"] = %LayoutSchemaVersion
  var arr = newJArray()
  if not app.isNil:
    for s in app.slots:
      var entry = newJObject()
      entry["id"] = %int(s.id)
      entry["title"] = %s.title
      entry["layout"] = s.layout.tree.toJson()
      # ALWAYS written, even empty, by §6's rule for `docked`: a session
      # gaining a docked pane later must not change the document's shape.
      var docked = newJArray()
      for d in s.layout.docked:
        docked.add(d.toJson())
      entry["docked"] = docked
      arr.add(entry)
  result["sessions"] = arr
  result["active"] = %int(app.activeSessionId)

proc restoreLayouts*(app: HeadlessApp; doc: JsonNode): int =
  ## Apply a document from `saveLayouts` to the sessions that are open,
  ## matching on slot id. Returns how many layouts were applied.
  ##
  ## Sessions in the document that are not open are skipped, and open
  ## sessions the document does not mention keep the layout they have: a
  ## restore is not a session manager. A document this build cannot read
  ## raises `LayoutDecodeError`, whose `kind` is a host's cue to fall back to
  ## `defaultReplayLayout()`.
  app.requireLive()
  if doc.isNil or doc.kind != JObject:
    raise (ref LayoutDecodeError)(
      kind: ldeNotAnObject,
      msg: "restoreLayouts: document is not an object")
  if not doc.hasKey("version") or doc["version"].kind != JInt:
    raise (ref LayoutDecodeError)(
      kind: ldeMissingField, detail: "version",
      msg: "restoreLayouts: missing or non-integer 'version'")
  # A range rather than an equality since PLAT-4 gave `layout_model` a forward
  # migration chain. Each per-session payload is a tree plus (since PLAT-4's
  # closing pass) a `docked` list, and is decoded through that chain below,
  # so a v1 document is readable here for the same reason
  # `restoreLayoutDocument` can migrate one. A version ABOVE this build's is
  # still refused, loudly: an older build meeting a newer layout has nothing
  # to fall forward to.
  if doc["version"].getInt > LayoutSchemaVersion or
     doc["version"].getInt < FirstLayoutSchemaVersion:
    raise (ref LayoutDecodeError)(
      kind: ldeUnknownVersion, detail: $doc["version"].getInt,
      msg: "restoreLayouts: schema version " & $doc["version"].getInt &
           " is outside " & $FirstLayoutSchemaVersion & ".." &
           $LayoutSchemaVersion)
  if not doc.hasKey("sessions") or doc["sessions"].kind != JArray:
    raise (ref LayoutDecodeError)(
      kind: ldeMissingField, detail: "sessions",
      msg: "restoreLayouts: missing or non-array 'sessions'")
  # Decode every entry before applying any of them. A document whose fifth
  # session is undecodable must not leave the first four rearranged and the
  # rest as they were — a half-restored shell is harder to reason about than
  # one that did not restore.
  var pending = initTable[int, Layout]()
  var titles = initTable[int, string]()
  for entry in doc["sessions"]:
    if entry.kind != JObject:
      raise (ref LayoutDecodeError)(
        kind: ldeNotAnObject, msg: "restoreLayouts: session entry is not an object")
    if not entry.hasKey("id") or entry["id"].kind != JInt:
      raise (ref LayoutDecodeError)(
        kind: ldeMissingField, detail: "id",
        msg: "restoreLayouts: session entry has no integer 'id'")
    if not entry.hasKey("layout"):
      raise (ref LayoutDecodeError)(
        kind: ldeMissingField, detail: "layout",
        msg: "restoreLayouts: session entry has no 'layout'")
    # Each entry is decoded as a §6 layout document at THIS document's
    # version, so the docked list gets `restoreLayoutDocument`'s whole
    # decoder — migration chain, typed refusals, `revealed` forced false —
    # rather than a second copy of it. An entry with no `docked` is one
    # written before the slot held a `Layout` (every earlier build wrote the
    # bare tree), and it means exactly what it meant then: nothing docked.
    var perSession = newJObject()
    perSession["version"] = doc["version"]
    perSession["layout"] = entry["layout"]
    perSession["docked"] =
      if entry.hasKey("docked"): entry["docked"] else: newJArray()
    pending[entry["id"].getInt] = restoreLayoutDocument(perSession)
    if entry.hasKey("title") and entry["title"].kind == JString:
      titles[entry["id"].getInt] = entry["title"].getStr
  result = 0
  for s in app.slots:
    let key = int(s.id)
    if pending.hasKey(key):
      s.layout = pending[key]
      if titles.hasKey(key):
        s.title = titles[key]
      inc result
  if doc.hasKey("active") and doc["active"].kind == JInt:
    discard app.activate(HeadlessSessionId(doc["active"].getInt))
