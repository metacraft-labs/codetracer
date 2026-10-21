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
## 2. The panel host (``ui/panel_host.nim``) mounts the session's
##    ``CommandPaletteVM`` view into the container it is given — the debug
##    header's ``commandPaletteComponent-{id}`` (``debug_toolbar``) or a
##    GoldenLayout container — synchronously, and the reactive effects keep
##    the DOM in sync with the VM. This module's decorator connects the
##    view's input to the legacy interpreter.
## 3. ``configureMiddleware`` (in ``ui_js.nim``) hands the module the
##    session's VM (``initCommandPaletteVMFromSession``).
##
## NOTE: rich per-kind row rendering (program-search HTML fragment,
## symbol-kind suffix, file-path tail truncation, agent-mode
## passthrough) remains a follow-up.  The IsoNim view renders one row
## per result with the entry's display ``value`` verbatim plus stable
## per-kind / per-level / selected / zebra modifiers.
## ---------------------------------------------------------------------------

import ui_imports, kdom, ../renderer, command_interpreter, shell, ./agent_activity
import ./session_viewmodels
from ./event_log import runColumnWidthCommand
from ../viewmodel/viewmodels/omnibar_sources import ColumnWidthVerb

import ../communication
import std/json
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  CommandPaletteResultEntry, CommandPaletteResultKind,
  CommandPaletteNotificationLevel, CommandPaletteMode,
  cprkCommand, cprkFile, cprkProgram, cprkTextSearch, cprkSymbol, cprkAgent,
  cpnlInfo, cpnlWarning, cpnlError, cpnlSuccess,
  cpmNormal, cpmAgent
from ../viewmodel/viewmodels/command_palette_vm import
  CommandPaletteVM,
  open, close, clear, setQuery, setResults, setSelected, setMode,
  setInputPlaceholder, setActiveCommandName
when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil
  from ../viewmodel/views/isonim_command_palette_view import
    CommandPaletteInputId
  import ./panel_host
  from ../viewmodel/session_vm import SessionViewModel

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
    # PLAT-70 Part B (Horizontal-Overflow.md §5.2): `:column-width <column>
    # <cells>` sets an Event Log column's width.
    if ($value).substr(1).strip.startsWith(ColumnWidthVerb):
      let why = runColumnWidthCommand(($value).substr(1))
      if why.len > 0: cwarn "palette: " & why
      self.close()
      self.resetCommandPalette()
      return
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
    # `:grep <text>` (Find-And-Incremental-Search.md §5.1): the Find in Files
    # pane's search, and the palette closes — the results are the pane's, and
    # nothing is opened (the user's OQ-F2: "Only open the results panel").
    # `resetCommandPalette` empties the field and closes the palette.
    self.interpreter.searchProgram(self.query.value)
    self.resetCommandPalette()

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
  ## The mapping is total but no longer onto: ``QueryKind``'s six variants
  ## map one-to-one onto the first six of ``CommandPaletteResultKind``, and
  ## ``cprkProjectAction`` has no legacy counterpart by construction — a
  ## project-declared action (Noir-Studio.md §9.3) is not a member of the
  ## compiled-in ``ClientAction`` vocabulary the legacy palette searches.
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
  if self.isNil:
    return
  # The ViewModel of this component's own tab (`ownPaneVM`).
  let vm = ownPaneVM(self, commandPaletteVMInstance, commandPaletteVM)
  if vm.isNil:
    return
  vm.setResults(legacyResultsToVm(self.results))
  vm.setQuery(safeStr(self.inputValue))
  vm.setSelected(self.selected)
  vm.setInputPlaceholder(safeStr(self.inputPlaceholder))
  vm.setActiveCommandName(safeStr(self.activeCommandName))
  vm.setMode(legacyModeToVm(self))
  if self.active:
    vm.open()
  else:
    vm.close()

proc requestCommandPalettePanelRefresh*(self: CommandPaletteComponent) =
  ## Refresh the Command Palette's IsoNim surface after local legacy-state
  ## mutations. The legacy component remains the command interpreter/event-bus
  ## carrier, while the VM and direct mount own the visible DOM.
  self.syncLegacyCommandPaletteIntoVM()

proc wireCommandPaletteResultRunner(self: CommandPaletteComponent) =
  ## Run a chosen result through `self`'s interpreter — the palette of the
  ## tab whose ViewModel this is.
  if self.isNil:
    return
  let vm = ownPaneVM(self, commandPaletteVMInstance, commandPaletteVM)
  if vm.isNil:
    return
  vm.onResultRun = proc(index: int) =
    if index >= 0 and index < self.results.len:
      self.selected = index
      self.interpreter.runCommandPanelResult(self.results[index])
      self.close()
      self.resetCommandPalette()

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initCommandPaletteVMFromSession*(vm: CommandPaletteVM) =
  ## Hand the pane the session's `CommandPaletteVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  ## If a stub-backed instance already exists (created before the session
  ## was available), it is replaced so the panel uses the real backend.
  let store = vm.store
  commandPaletteVMStore = store
  commandPaletteVMInstance = vm
  # The shown tab's palette component — not the module's first one — runs
  # this ViewModel's results and is mirrored into it.
  let shownComponent = data.shownTabComponent(Content.CommandPalette)
  let component =
    if shownComponent.isNil: commandPaletteComponentRef
    else: CommandPaletteComponent(shownComponent)
  if not component.isNil:
    component.wireCommandPaletteResultRunner()
  clog "CommandPaletteVM: the session's instance installed"
  if not component.isNil:
    component.syncLegacyCommandPaletteIntoVM()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc focusElement(input: kdom.Element) {.importcpp: "#.focus()".}
  proc scrollResultsForNavigation(
      resultsEl: kdom.Element; goingDown: bool; currentIdx: int) =
    ## Pre-scroll synchronously BEFORE redrawAll — no timing race with
    ## Karax's requestAnimationFrame.
    ## Row positions are computed from the index and measured row height
    ## (offsetHeight is element-intrinsic and not affected by viewport
    ## coordinates, unlike getBoundingClientRect).
    let anyRow = cast[kdom.Element](
      resultsEl.toJs.querySelector(cstring ".ct-menu-item"))
    if isNil(anyRow): return
    let rowH      = cast[float](anyRow.toJs.offsetHeight)
    if rowH <= 0.0: return
    let clientH   = cast[float](resultsEl.toJs.clientHeight)
    let scrollTop = cast[float](resultsEl.toJs.scrollTop)
    if goingDown:
      # bottom of the row one step ahead
      let nextBottom = float(currentIdx + 2) * rowH
      if nextBottom > scrollTop + clientH:
        resultsEl.toJs.scrollTop = nextBottom - clientH
    else:
      if currentIdx > 0:
        # top of the row one step back
        let prevTop = float(currentIdx - 1) * rowH
        if prevTop < scrollTop:
          resultsEl.toJs.scrollTop = prevTop

  proc wireLegacyCommandPaletteInput(self: CommandPaletteComponent) =
    ## The IsoNim view owns the DOM, but the mature command/search/agent
    ## behavior still lives in CommandPaletteComponent. Keep the real input
    ## connected to those handlers until the interpreter itself is moved into
    ## the ViewModel layer.
    if self.isNil:
      return

    let input = kdom.document.getElementById(cstring CommandPaletteInputId)
    if input.isNil:
      return
    if cast[bool](input.toJs["__ctCommandPaletteWired"]):
      self.inputField = cast[dom.Node](input)
      return

    input.toJs["__ctCommandPaletteWired"] = true
    self.inputField = cast[dom.Node](input)

    input.addEventListener(cstring"mousedown", proc(ev: Event) =
      input.focusElement()
      self.data.search(SearchFileRealTime, "".cstring))

    input.addEventListener(cstring"input", proc(ev: Event) =
      let value = self.inputField.toJs.value.to(cstring)
      self.onInput(value))

    input.addEventListener(cstring"keydown", proc(ev: Event) =
      let keyCode = cast[int](ev.toJs.keyCode)
      if keyCode == DOWN_KEY_CODE:
        ev.preventDefault()
        let resultsElDown = kdom.document.querySelector(cstring ".command-results")
        if not resultsElDown.isNil:
          scrollResultsForNavigation(resultsElDown, true, self.selected)
        commandSelectNext()
        discard setTimeout(proc() =
          let fresh = kdom.document.getElementById(cstring CommandPaletteInputId)
          if not fresh.isNil: fresh.focusElement(), 16)
      elif keyCode == UP_KEY_CODE:
        ev.preventDefault()
        let resultsElUp = kdom.document.querySelector(cstring ".command-results")
        if not resultsElUp.isNil:
          scrollResultsForNavigation(resultsElUp, false, self.selected)
        commandSelectPrevious()
        discard setTimeout(proc() =
          let fresh = kdom.document.getElementById(cstring CommandPaletteInputId)
          if not fresh.isNil: fresh.focusElement(), 16)
      elif keyCode == ENTER_KEY_CODE:
        self.runQuery()
      elif keyCode == ESC_KEY_CODE:
        self.resetCommandPalette()
      elif keyCode == TAB_KEY_CODE:
        if self.inputPlaceholder != "" and self.inputPlaceholder != self.inputValue:
          ev.preventDefault()
          self.onTab())

  # The panel host mounts the palette's view into the host it is given — the
  # debug header's `commandPaletteComponent-<id>` (`debug_toolbar`) or a
  # GoldenLayout container — and this decoration connects that view's input
  # to the legacy interpreter, which still owns command, search and agent
  # behaviour, and brings the view up to the component's current state.
  setPanelDecorator(Content.CommandPalette,
    proc(host: isonim_dom_api.Element; session: SessionViewModel) =
      if not commandPaletteComponentRef.isNil:
        wireLegacyCommandPaletteInput(commandPaletteComponentRef)
        syncLegacyCommandPaletteIntoVM(commandPaletteComponentRef))

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

method register*(self: CommandPaletteComponent, api: MediatorWithSubscribers) =
  ## Register the CommandPaletteComponent with the mediator. It adopts the
  ## newest registration; the view is the panel host's.
  self.api = api
  commandPaletteComponentRef = self
  self.wireCommandPaletteResultRunner()
  self.syncLegacyCommandPaletteIntoVM()
