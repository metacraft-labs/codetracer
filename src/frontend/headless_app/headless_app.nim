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
##   * **each session's layout**, as a `layout_model.LayoutNode`.
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
    layout*: LayoutNode
      ## This session's arrangement. Owned per slot — never shared, so
      ## activating a tab in one session cannot move it in another. `clone`
      ## in `layout_model` is what makes that true for a caller who passes
      ## the same tree twice.

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

proc openSession*(app: HeadlessApp; backend: BackendService;
                  title: string = "";
                  layout: LayoutNode = nil;
                  clock: ClockBase = nil): HeadlessSessionSlot =
  ## Add a session over `backend` and make it active.
  ##
  ## `layout` is **deep-copied**: a caller who passes `defaultReplayLayout()`
  ## once and opens two sessions from it must not get two sessions sharing a
  ## tree. Passing nil means `defaultReplayLayout()`.
  ##
  ## Nothing is sent to `backend` here — the session is created in
  ## `dspCreated` and the panel ViewModels stay inert until `launch` or
  ## `attach`.
  app.requireLive()
  if backend.isNil:
    raiseApp("openSession requires a BackendService; the shell never builds one")
  let source = if layout.isNil: defaultReplayLayout() else: layout.clone()
  let problems = source.validate()
  if problems.len > 0:
    raiseApp("openSession was given an invalid layout: " & $problems[0].kind &
             " at '" & problems[0].path & "'")
  let session =
    if clock.isNil: newDebuggerSession(backend)
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

proc paneIsLive*(slot: HeadlessSessionSlot; kind: PaneKind): bool =
  ## Whether the pane has a ViewModel to render. False for every pane of a
  ## session that has not launched — which is what makes "the shell starts
  ## sending nothing" observable rather than merely documented.
  not slot.paneViewModel(kind).isNil

proc visiblePanes*(slot: HeadlessSessionSlot): seq[PaneKind] =
  ## The panes this session currently shows.
  if slot.isNil: @[] else: slot.layout.visiblePanes()

proc activatePane*(slot: HeadlessSessionSlot; kind: PaneKind): bool =
  ## Bring a pane to the front of whatever stack holds it.
  if slot.isNil: false else: slot.layout.activate(kind)

proc livePanes*(slot: HeadlessSessionSlot): seq[PaneKind] =
  ## Every pane placed in the layout that also has a ViewModel behind it.
  ## The intersection is what a host iterates to render.
  result = @[]
  if slot.isNil:
    return
  for p in slot.layout.allPanes():
    if slot.paneIsLive(p):
      result.add(p)

# ---------------------------------------------------------------------------
# Persistence — the replacement for saving `GoldenLayoutResolvedConfig`
# ---------------------------------------------------------------------------

proc saveLayouts*(app: HeadlessApp): JsonNode =
  ## Every session's layout, plus which one was active, as one versioned
  ## document. Titles are included because they are shell state too; a
  ## `TraceSource` is not, because re-opening a trace is the host's decision.
  result = newJObject()
  result["version"] = %LayoutSchemaVersion
  var arr = newJArray()
  if not app.isNil:
    for s in app.slots:
      var entry = newJObject()
      entry["id"] = %int(s.id)
      entry["title"] = %s.title
      entry["layout"] = s.layout.toJson()
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
  if doc["version"].getInt != LayoutSchemaVersion:
    raise (ref LayoutDecodeError)(
      kind: ldeUnknownVersion, detail: $doc["version"].getInt,
      msg: "restoreLayouts: schema version " & $doc["version"].getInt &
           " is not " & $LayoutSchemaVersion)
  if not doc.hasKey("sessions") or doc["sessions"].kind != JArray:
    raise (ref LayoutDecodeError)(
      kind: ldeMissingField, detail: "sessions",
      msg: "restoreLayouts: missing or non-array 'sessions'")
  # Decode every entry before applying any of them. A document whose fifth
  # session is undecodable must not leave the first four rearranged and the
  # rest as they were — a half-restored shell is harder to reason about than
  # one that did not restore.
  var pending = initTable[int, LayoutNode]()
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
    pending[entry["id"].getInt] = fromJson(entry["layout"])
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
