## Command Palette Panel — Ctrl+P-style file/command/symbol search overlay.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_command_palette_view.nim``) that
## mounts directly into the GoldenLayout container.  The legacy
## ``CommandPaletteComponent`` retains its module-level helpers
## (``clear``/``close``/``resetCommandPalette``/``commandIsParent``/
## ``changePlaceholder``/``eventuallyClearPlaceholder``/``showResults``/
## ``onInput``/``runQuery``/``onTab``/``onProgramSearchResults``) so the
## existing wiring (keyboard shortcuts, ``CommandInterpreter``, agent
## passthrough) keeps feeding the panel; every state mutation now
## mirrors into the parallel ``CommandPaletteVM`` via
## ``syncLegacyCommandPaletteIntoVM`` so the IsoNim view is the single
## source of truth for the panel's DOM.
##
## Lifecycle:
## 1. ``utils.nim::makeCommandPaletteComponent`` constructs the legacy
##    ``CommandPaletteComponent`` and registers it under
##    ``Content.CommandPalette`` (one instance per panel id).
## 2. ``layout.nim`` registers the GL container, then detects
##    ``Content.CommandPalette`` is in ``isIsoNimComponent`` and calls
##    ``tryMountIsoNimCommandPalettePanel`` instead of invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``commandPaletteComponent-{id}`` container and the reactive
##    effects keep the DOM in sync with the VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initCommandPaletteVMWithStore`` so
##    the panel uses the production ``ReplayDataStore``.
##
## NOTE: rich per-kind row rendering (program-search HTML fragment,
## symbol-kind suffix, file-path tail truncation, agent-mode
## passthrough) remains a follow-up.  The IsoNim view renders one row
## per result with the entry's display ``value`` verbatim plus stable
## per-kind / per-level / selected / zebra modifiers.
## ---------------------------------------------------------------------------

import ui_imports, kdom, ../renderer, command_interpreter, shell, ./agent_activity

import ../communication
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  CommandPaletteResultEntry, CommandPaletteResultKind,
  CommandPaletteNotificationLevel, CommandPaletteMode,
  cprkCommand, cprkFile, cprkProgram, cprkTextSearch, cprkSymbol, cprkAgent,
  cpnlInfo, cpnlWarning, cpnlError, cpnlSuccess,
  cpmNormal, cpmAgent
from ../viewmodel/viewmodels/command_palette_vm import
  CommandPaletteVM, createCommandPaletteVM,
  open, close, clear, setQuery, setResults, setSelected, setMode,
  setInputPlaceholder, setActiveCommandName
when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil
  from ../viewmodel/views/isonim_command_palette_view import
    mountIsoNimCommandPalettePanel

proc requestCommandPalettePanelRefresh*(self: CommandPaletteComponent)

proc clear(self: CommandPaletteComponent) =
  self.selected = 0
  self.inputValue = ""
  self.inputPlaceholder = ""
  self.query = nil
  self.results = @[]
  self.mode = CommandPaletteNormal

proc close(self: CommandPaletteComponent) =
  self.active = false
  self.requestCommandPalettePanelRefresh()
  self.clear()

proc resetCommandPalette*(self: CommandPaletteComponent) =
  self.inputField.toJs.value = "".cstring
  self.close()
  data.redraw()

proc commandIsParent(self: CommandPaletteComponent, commandName: cstring): bool =
  if self.interpreter.commands.hasKey(commandName):
    self.interpreter.commands[commandName].kind == ParentCommand
  else:
    return false

proc changePlaceholder*(self: CommandPaletteComponent) =
  if self.results.len == 0:
    self.inputPlaceholder = cstring("")
  else:
    case self.query.kind:
    of CommandQuery:
      if self.query.expectArgs:
        self.inputPlaceholder = cstring(&"{commandPrefix}{self.query.value}: ")
        if self.query.args.len > 0:
          for result in self.results:
            if ($(result.value.toLowerCase())).startsWith($(self.query.args[0].toLowerCase())):
              self.inputPlaceholder = cstring(&"{commandPrefix}{self.query.value}: {result.value}")
              break
      else:
        for result in self.results:
          if ($(result.value.toLowerCase())).startsWith($(self.query.value.toLowerCase())):
            # Since we are matching in case insensitive way, the found completion
            # may have different casing than the query. Since we are rendering the
            # completion behind the entered query, such difference would produce
            # an ugly rendering mismatches. We fix this by prefixing the found
            # completion with the precisely entered query:
            let completion = self.query.value & result.value.slice(self.query.value.len)
            if self.commandIsParent(result.value):
              self.inputPlaceholder = cstring(&"{commandPrefix}{completion}: ")
            else:
              self.inputPlaceholder = cstring(&"{commandPrefix}{completion}")
            break

    of FileQuery:
      for result in self.results:
        if ($(result.value.toLowerCase())).startsWith($(self.query.value.toLowerCase())):
          self.inputPlaceholder = result.value
          break

    of ProgramQuery:
      discard

    of TextSearchQuery:
      discard

    of SymbolQuery:
      discard # TODO

    of AgentQuery:
      discard

proc eventuallyClearPlaceholder(self: CommandPaletteComponent, value: cstring) =
  if self.inputPlaceholder != cstring("") and not ($(self.inputPlaceholder)).startsWith($value):
    self.inputPlaceholder = cstring("")
    self.requestCommandPalettePanelRefresh()

proc showResults(self: CommandPaletteComponent) =
  let value = self.inputField.toJs.value.to(cstring)
  self.inputValue = value
  self.query = self.interpreter.parseQuery(value)
  if self.query.kind != ProgramQuery:
    self.results = self.interpreter.autocompleteQuery(self.query)
    self.changePlaceholder()
    self.active = true
    self.requestCommandPalettePanelRefresh()
  else:
    discard

proc onInput(self: CommandPaletteComponent, value: cstring) =
  self.eventuallyClearPlaceholder(value)
  self.showResults()
  if self.inputValue == cstring"/ai ":
    self.inAgentMode = true
    self.inputValue = ""
    self.requestCommandPalettePanelRefresh()

proc runQuery(self: CommandPaletteComponent) =
  clog "runQuery "

  let value = self.inputField.toJs.value.to(cstring)
  self.inputValue = value
  self.query = self.interpreter.parseQuery(value)

  case self.query.kind:
  of CommandQuery:
    if self.results.len == 0:
      return

    let selectedResult = self.results[self.selected]
    let command = self.interpreter.commands[selectedResult.value]

    case command.kind:
    of ParentCommand:
      let inputValue = cstring(&"{commandPrefix}{selectedResult.value}: ")
      self.inputField.toJs.value = inputValue
      self.onInput(inputValue)
    of ActionCommand:
      self.interpreter.runCommandPanelResult(selectedResult)
      self.close()
    self.resetCommandPalette()

  of FileQuery:
    if self.results.len == 0:
      return

    self.interpreter.openFileQuery(self.results[self.selected])
    self.close()
    self.resetCommandPalette()

  of ProgramQuery:
    clog "search program"

    if self.results.len != 0 and self.prevCommandValue == self.inputValue:
      let selectedResult = self.results[self.selected]
      self.interpreter.runCommandPanelResult(selectedResult)
      self.close()
      self.resetCommandPalette()
    else:
      self.interpreter.searchProgram(self.query.value)

  of TextSearchQuery:
    # should be unreachable. This type is accessible through ProgramQuery
    discard

  of SymbolQuery:
    let selectedResult = self.results[self.selected]
    self.interpreter.runCommandPanelResult(selectedResult)
    self.close()
    self.resetCommandPalette()

  of AgentQuery:
    data.lastAgentPrompt = self.inputValue
    let content = Content.AgentActivity
    data.openLayoutTab(content)
    self.resetCommandPalette()
    self.requestCommandPalettePanelRefresh()

  self.prevCommandValue = self.inputValue

proc onTab(self: CommandPaletteComponent) =
  if self.inputPlaceholder != "" and self.inputPlaceholder != self.inputValue:
    self.inputField.toJs.value = self.inputPlaceholder
    self.onInput(self.inputPlaceholder)

method onProgramSearchResults*(self: CommandPaletteComponent, results: seq[CommandPanelResult]) {.async.} =
  clog "onProgramSearchResults commands"
  self.results = results
  self.data.redraw()

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and any
# legacy bridge handlers can find each other across calls.  Mirrors
# the pattern used by trace_log / scratchpad / filesystem.
# ---------------------------------------------------------------------------

var commandPaletteVMInstance*: CommandPaletteVM
var commandPaletteVMStore: ReplayDataStore
var commandPaletteComponentRef: CommandPaletteComponent
# Track which CommandPaletteComponent ids have already mounted their
# IsoNim view.  The GL container is keyed by
# ``commandPaletteComponent-{id}`` so each open palette panel
# instance gets its own mount.
var isoNimCommandPaletteMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimCommandPalettePanel*()

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  The legacy
  ## record carries cstring everywhere; an unconditional ``$`` would
  ## throw inside ``cstrToNimstr`` for null cstrings.
  if s.isNil:
    ""
  else:
    $s

proc legacyKindToVm(kind: QueryKind): CommandPaletteResultKind =
  ## Map the legacy ``QueryKind`` enum to its VM-side counterpart.
  ## The mapping is one-to-one — both enums carry the same six
  ## variants in the same order.
  case kind
  of CommandQuery: cprkCommand
  of FileQuery: cprkFile
  of ProgramQuery: cprkProgram
  of TextSearchQuery: cprkTextSearch
  of SymbolQuery: cprkSymbol
  of AgentQuery: cprkAgent

proc legacyLevelToVm(level: NotificationKind): CommandPaletteNotificationLevel =
  ## Map the legacy ``NotificationKind`` enum to the VM-side
  ## ``CommandPaletteNotificationLevel``.  Only the four values
  ## the legacy ``commandResultView`` branched on are mapped; any
  ## others fall through to ``cpnlInfo`` so the row renders the
  ## standard branch.
  case level
  of NotificationInfo: cpnlInfo
  of NotificationWarning: cpnlWarning
  of NotificationError: cpnlError
  of NotificationSuccess: cpnlSuccess

proc legacyResultToVm(qr: CommandPanelResult): CommandPaletteResultEntry =
  ## Translate one legacy ``CommandPanelResult`` ref into a flat
  ## ``CommandPaletteResultEntry`` value.  Per-kind context fields
  ## (file/line/symbolKind/snippetSource) are populated from the
  ## ref's case-branch fields; non-applicable fields stay empty / 0.
  if qr.isNil:
    return CommandPaletteResultEntry()
  result = CommandPaletteResultEntry(
    value: safeStr(qr.value),
    valueHighlighted: safeStr(qr.valueHighlighted),
    kind: legacyKindToVm(qr.kind),
    level: legacyLevelToVm(qr.level),
    file: "",
    line: 0,
    symbolKind: "",
    snippetSource: "",
  )
  case qr.kind
  of ProgramQuery:
    result.line = qr.codeSnippet.line
    result.snippetSource = safeStr(qr.codeSnippet.source)
  of TextSearchQuery, SymbolQuery:
    result.file = safeStr(qr.file)
    result.line = qr.line
    result.symbolKind = safeStr(qr.symbolKind)
  else:
    discard

proc legacyResultsToVm(results: seq[CommandPanelResult]):
    seq[CommandPaletteResultEntry] =
  ## Bulk translation helper — invoked from
  ## ``syncLegacyCommandPaletteIntoVM`` so the VM signal is updated
  ## in one go.
  result = @[]
  for qr in results:
    result.add(legacyResultToVm(qr))

proc legacyModeToVm(self: CommandPaletteComponent): vmtypes.CommandPaletteMode =
  ## Pick the VM-side mode based on the legacy ``inAgentMode`` flag.
  ## The legacy ``CommandPaletteMode`` enum carried only
  ## ``CommandPaletteNormal`` because the agent path was tracked via
  ## ``inAgentMode``; the IsoNim VM keeps both branches as a single
  ## source of truth.
  if self.inAgentMode:
    cpmAgent
  else:
    cpmNormal

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyCommandPaletteIntoVM*(self: CommandPaletteComponent) =
  ## Bulk-replay the legacy command-palette state into the VM.
  ## Called from layout / event-bus boilerplate so the panel reflects
  ## whatever the legacy ``CommandInterpreter`` already accumulated.
  ## Defensive nil-checks so a partially-initialised palette can call
  ## through this without exploding.
  if commandPaletteVMInstance.isNil or self.isNil:
    return
  commandPaletteVMInstance.setResults(legacyResultsToVm(self.results))
  commandPaletteVMInstance.setSelected(self.selected)
  commandPaletteVMInstance.setQuery(safeStr(self.inputValue))
  commandPaletteVMInstance.setInputPlaceholder(safeStr(self.inputPlaceholder))
  commandPaletteVMInstance.setActiveCommandName(safeStr(self.activeCommandName))
  commandPaletteVMInstance.setMode(legacyModeToVm(self))
  if self.active:
    commandPaletteVMInstance.open()
  else:
    commandPaletteVMInstance.close()

proc requestCommandPalettePanelRefresh*(self: CommandPaletteComponent) =
  ## Refresh the Command Palette's IsoNim surface after local legacy-state
  ## mutations. The legacy component remains the command interpreter/event-bus
  ## carrier, while the VM and direct mount own the visible DOM.
  self.syncLegacyCommandPaletteIntoVM()
  tryMountIsoNimCommandPalettePanel()

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initCommandPaletteVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``CommandPaletteVM`` using
  ## an externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance
  ## already exists (created by ``initCommandPaletteVM`` before the
  ## real backend was available) it is replaced so the panel uses
  ## the real backend.
  if commandPaletteVMInstance != nil:
    clog "CommandPaletteVM: replacing existing instance with shared-store version"
    isoNimCommandPaletteMountedIds = JsAssoc[int, bool]{}
  commandPaletteVMStore = store
  commandPaletteVMInstance = createCommandPaletteVM(store)
  clog "CommandPaletteVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimCommandPalettePanel()

proc initCommandPaletteVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initFilesystemVM`` / ``initScratchpadVM`` — a
  ## stub backend so the panel can still render before
  ## ``configureMiddleware`` runs.
  if commandPaletteVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  commandPaletteVMStore = createReplayDataStore(stubBackend)
  commandPaletteVMInstance = createCommandPaletteVM(commandPaletteVMStore)
  clog "CommandPaletteVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimCommandPalettePanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimCommandPalettePanel*() =
    ## Mount the IsoNim Command Palette panel view into the
    ## GoldenLayout-managed container.  The container's id is
    ## ``commandPaletteComponent-{id}`` — each open palette panel
    ## instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container
    ## appears (capped at 200 attempts, ~2 s) since GoldenLayout
    ## creates the host slightly after the layout state changes
    ## (mirrors ``tryMountIsoNimFilesystemPanel`` /
    ## ``tryMountIsoNimScratchpadPanel`` /
    ## ``tryMountIsoNimTraceLogPanel``).
    if commandPaletteVMInstance.isNil:
      return
    if commandPaletteComponentRef.isNil:
      return
    let componentId = commandPaletteComponentRef.id
    let key = cstring("commandPaletteComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      retryCount += 1
      let container = isonim_dom_api.getElementById(
        isonim_dom_api.document, key)
      if isonim_dom_api.isNodeNil(isonim_dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimCommandPalettePanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return
      if isoNimCommandPaletteMountedIds.hasKey(componentId):
        let containerNode = isonim_dom_api.Node(container)
        if not isonim_dom_api.isNodeNil(containerNode.firstChild):
          return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = isonim_dom_api.Node(container)
      while not isonim_dom_api.isNodeNil(containerNode.firstChild):
        discard isonim_dom_api.removeChild(
          containerNode, containerNode.firstChild)

      isoNimCommandPaletteMountedIds[componentId] = true
      try:
        mountIsoNimCommandPalettePanel(container, commandPaletteVMInstance)
      except:
        cerror "tryMountIsoNimCommandPalettePanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any state the legacy component already carries so
      # the freshly-mounted view reflects the latest state.
      if not commandPaletteComponentRef.isNil:
        syncLegacyCommandPaletteIntoVM(commandPaletteComponentRef)

    doMount()
else:
  proc tryMountIsoNimCommandPalettePanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initCommandPaletteVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

method register*(self: CommandPaletteComponent, api: MediatorWithSubscribers) =
  ## Register the CommandPaletteComponent with the mediator.  Bring
  ## up the IsoNim CommandPaletteVM lazily so the mount procedure
  ## can find it; the shared-store version is installed by
  ## ``configureMiddleware`` if the ViewModel layer is enabled.
  self.api = api
  initCommandPaletteVM()
  commandPaletteComponentRef = self
  tryMountIsoNimCommandPalettePanel()
