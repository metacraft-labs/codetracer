## Constraints panel (`Content.Constraints`) — the legacy-side bridge.
##
## There is no legacy Karax half to bridge FROM: this pane is new, and it was
## built the way the migrated ones ended up rather than the way they started.
## What this module is, then, is the GoldenLayout mount and the VM's owner —
## the same two jobs `ui/trace_log.nim` does after its Karax `method render`
## was dropped, minus the translation layer neither of us needs.
##
## The component exists at all because `Content` members are constructed
## through `utils.makeComponent`, registered in `data.ui.componentMapping`, and
## found by `ui/layout.nim`'s `genericUiComponent` registration by id. A pane
## that skipped that would not be a CodeTracer pane; it would be a div in a
## GoldenLayout container, which is what the web build had before NS9 and
## exactly what §3 says not to build.

import
  ui_imports,
  session_viewmodels,
  ../[ types, communication ]

# `markStale` WAS in this list and was never applied — an import that read,
# for the whole life of the pane, exactly like the caller it was standing in
# for. `noteSourceEdited` replaces it because that is the proc this module
# actually calls; `markStale` is reached through it, inside the viewmodel,
# where the rule about which edits count can be driven by a headless lane.
from ../viewmodel/viewmodels/constraints_vm import
  ConstraintsVM, createConstraintsVM, setReport, setAbsence, noteSourceEdited,
  NoirSourceFile, ConstraintReport
from ../viewmodel/viewmodels/constraints_answer import ConstraintsOnlyAsk,
  attachListing, placeOpcodes
from ../viewmodel/viewmodels/build_diagnostics import resolvedPath
import std/json
from isonim/web/dom_api import nil
from ./pane_host_lookup import tabOfPaneHost
import isonim/core/signals
import isonim/web/web_renderer
import ./panel_host
import ../viewmodel/input/[dom_pointer, dom_pane_presses, pane_presses]
from std/jsffi import JsObject
from ../viewmodel/session_vm import SessionViewModel
import ../viewmodel/views/isonim_constraints_view

var constraintsVMInstance*: ConstraintsVM
  ## The SHOWN tab's Constraints ViewModel. Each tab has its own
  ## (`session_viewmodels.constraintsVMOf`, as `ui/test_results.nim`'s); this
  ## names the one the window's hosts write into now, moved by
  ## `bindConstraintsVM` on every tab switch. Each tab's pane renders its own
  ## tab's (`constraintsVMForHost`).

var recordingTabsAsked: seq[int]
  ## `ReplaySession.id` of each tab holding a recording that has asked for the
  ## circuit (`askToMeasure`): its pane has been on screen, so it follows the
  ## project from then on. A tab with no recording asks at start-up instead
  ## (`ui_js.onNoTrace`).

proc setMeasuredReport*(vm: ConstraintsVM; totals: ConstraintReport;
                        listing, artefact: string) =
  ## The desktop host's answer joined by the procs the native hosts use, placed
  ## against the sources that came with it.
  vm.setReport(placeOpcodes(attachListing(totals, listing), artefact,
                            vm.sources.val))

proc sendMeasureAsk(session: ReplaySession) =
  # A tab holding a recording has the window's start options, so its folder is
  # the project the window opened: every tab of a window shares its project, as
  # a native window's do.
  data.ipc.send "CODETRACER::ns9-panes",
    js{ folder: session.startOptions.folder,
        tab: int(session.id), only: cstring(ConstraintsOnlyAsk) }

proc askToMeasure*(session: ReplaySession) =
  ## `session`'s pane is on screen: measure its project the first time, as a
  ## native window does (`native_constraints_host`). Never for a tab that does
  ## not show the pane, because `nargo` compiles the project.
  if session.isNil or session.trace.isNil or
     int(session.id) in recordingTabsAsked:
    return
  recordingTabsAsked.add int(session.id)
  sendMeasureAsk(session)

proc remeasureRecordingTabs*() =
  ## A source was saved: the recordings' tabs that show the pane measure again.
  ## The tab on screen has already asked, when its start options say Edit
  ## (`ui_js`, on a save).
  for session in data.sessions:
    if not session.isNil and int(session.id) in recordingTabsAsked and
       not (session == data.activeSession and data.startOptions.edit):
      sendMeasureAsk(session)

proc sourcesFromJson*(text: string): seq[NoirSourceFile] =
  ## The `[{path, content}]` the main process sends beside a report
  ## (`index/ns9_panes.sourcesJson`). An unreadable answer is no sources —
  ## the rows then say they were not placed, rather than the pane failing.
  try:
    let node = parseJson(text)
    if node.kind != JArray:
      return @[]
    for entry in node:
      if entry.kind == JObject and entry.hasKey("path") and
         entry.hasKey("content"):
        result.add NoirSourceFile(path: entry["path"].getStr(),
                                  content: entry["content"].getStr())
  except:
    # Bare: on the JS backend a malformed document raises a foreign
    # `SyntaxError` (see `noir_constraints.parseNargoInfoJson`).
    result = @[]

proc openConstraintSource(path: string; line, column: int) =
  ## PLAT-62: a row's Go to Source — the project-relative file opened at the
  ## line in the editor, as the Problems pane opens a diagnostic.
  let folder = if data.isNil or data.startOptions.folder.isNil: ""
               else: $data.startOptions.folder
  discard data.openLocation(cstring(resolvedPath(path, folder)), line,
                            max(column, 1))

proc installConstraintsCallbacks*(vm: ConstraintsVM) =
  ## The host's half of a row's activation: opening its source.
  if not vm.isNil and vm.onOpenSource.isNil:
    vm.onOpenSource = openConstraintSource

proc bindConstraintsVM*(vm: ConstraintsVM) =
  ## Make `vm` — the shown tab's — the one the window's hosts write into.
  if not vm.isNil:
    installConstraintsCallbacks(vm)
    constraintsVMInstance = vm

proc initConstraintsVM*() =
  ## Bind the shown tab's ViewModel, created on first use.
  ##
  ## The VM needs no store: a constraint report comes from `nargo info`, or
  ## from the counts the bundle carries, and from nowhere else. That is why
  ## there is no `initConstraintsVMWithStore` twin — a `ReplayDataStore`
  ## parameter would be a promise this pane does not keep.
  ##
  ## A page with no tab yet keeps one window-wide instance.
  if data.sessions.len == 0:
    if constraintsVMInstance.isNil:
      constraintsVMInstance = createConstraintsVM()
      installConstraintsCallbacks(constraintsVMInstance)
      clog "ConstraintsVM: instance created"
    return
  bindConstraintsVM(constraintsVMOf(data.activeSession))

proc constraintsVMForHost(host: dom_api.Element): ConstraintsVM =
  ## The ViewModel of the tab whose container holds `host`; a host outside
  ## every tab shows the shown tab's.
  let tab = tabOfPaneHost(host)
  if tab >= 0 and tab < data.sessions.len:
    result = constraintsVMOf(data.sessions[tab])
    askToMeasure(data.sessions[tab])
  else:
    # Also a host GoldenLayout has not attached to its tab's container yet,
    # which is every pane a View item opens: the tab on screen is its tab.
    initConstraintsVM()
    result = constraintsVMInstance
    if data.sessions.len > 0:
      askToMeasure(data.activeSession)
  installConstraintsCallbacks(result)

# The panel host mounts the pane into the container GoldenLayout creates.
setPanelRenderer(Content.Constraints,
  proc(r: WebRenderer; host: dom_api.Element;
       session: SessionViewModel): dom_api.Element =
    renderConstraintsPanel[WebRenderer, dom_api.Element](r,
      constraintsVMForHost(host)))

proc noteEditorSourceChanged*(path: cstring) =
  ## A visitor edited `path`, so the counts on screen may no longer describe
  ## the program on screen.
  ##
  ## Installed into `ui/editor.editorSourceChangedHook` by `ui_js`, which is
  ## where every other cross-module editor hook is installed. Kept as a named
  ## proc here rather than written as a closure at the install site so that the
  ## call from the editor to this pane is a thing a reader (and the
  ## reachability guard) can SEE — an anonymous `proc` in a 400-line install
  ## block is how the previous version of this wiring managed to not exist for
  ## as long as it did.
  ##
  ## Silent when there is no VM. The pane is created lazily by
  ## `initConstraintsVM`, and it is not this hook's business to force it into
  ## existence: a project with no constraint report has no count to invalidate.
  if not constraintsVMInstance.isNil:
    constraintsVMInstance.noteSourceEdited($path)
  # The recordings' tabs that show the pane describe the same project.
  for session in data.sessions:
    if not session.isNil and int(session.id) in recordingTabsAsked:
      constraintsVMOf(session).noteSourceEdited($path)

method register*(self: ConstraintsComponent, api: MediatorWithSubscribers) =
  self.api = api
  initConstraintsVM()

# A press on a row selects it and opens its source (K67): the pointer row
# `constraints.go-to-source`, performed on the row the key router's hit test
# found (`input/dom_pointer`), on the ViewModel of the tab holding it.
registerElementOperation("constraints.go-to-source", proc(p: ElementPress): bool =
  pressConstraints(constraintsVMForHost(cast[dom_api.Element](p.element)),
                   "constraints.go-to-source", readerOf(p.element)))
