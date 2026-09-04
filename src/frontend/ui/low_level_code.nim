## Low Level Code panel — assembly / IR view for the currently-debugged function.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_low_level_code_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``LowLevelCodeComponent`` retains its data-plumbing methods so the
## frontend's existing wiring keeps feeding the asm listing:
##
##   - ``CtLoadAsmFunction`` is emitted via ``loadAsm`` / ``getAsmCode``
##     to request the asm for a given function location.
##   - ``CtLoadAsmFunctionResponse`` arrives via the mediator and lands
##     in ``onLoadAsmFunctionResponse``, which formats each instruction,
##     installs the Monaco view-zones cross-referencing the high-level
##     source line each instruction was generated from, and sets the
##     active highlight line.
##   - ``onCompleteMove`` re-fetches the asm whenever the live debugger
##     position advances to a different function.
##
## Each handler now also feeds the parallel ``LowLevelCodeVM`` so the
## IsoNim view stays in sync.  In production the actual asm-listing
## buffer is rendered by Monaco inside the editor sub-tree (the
## EditorViewComponent owns that DOM); the IsoNim view here exposes
## the parity-faithful container shell + a fallback row list so
## headless tests can exercise the same data flow without Monaco.
## ---------------------------------------------------------------------------

import
  ui_imports,
  ../[ types, renderer, communication, utils],
  ../../common/ct_event

import std/[json, strutils]
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  LowLevelInstruction, LowLevelInstructionList
from ../viewmodel/viewmodels/low_level_code_vm import
  LowLevelCodeVM, createLowLevelCodeVM, NO_ACTIVE_OFFSET,
  setInstructions, setActiveOffset, setAddress, setErrorMessage,
  setNoirProject, clearInstructions, loadAsmFor, jumpToInstruction,
  setAnchors, clearAnchors, syncFromSourceLine, rowsFor

from ../viewmodel/viewmodels/generated_code_anchors import
  MappingAnchor, ArtefactSupport, SyncDecision, SyncOutcome, soAligned
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_low_level_code_view import
    mountIsoNimLowLevelCode

const NO_LINE = -1

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by terminal_output, search_results, no_source,
# step_list, calltrace_editor and repl.
var lowLevelCodeVMInstance*: LowLevelCodeVM
var lowLevelCodeVMStore: ReplayDataStore
var lowLevelCodeComponentRef: LowLevelCodeComponent
# Track which LowLevelCodeComponent ids have already mounted their
# IsoNim view.  The GL container is keyed by ``lowLevelCodeComponent-{id}``
# so each panel instance gets its own mount.
var isoNimLowLevelCodeMountedIds {.used.}: JsAssoc[int, bool] = JsAssoc[int, bool]{}

proc tryMountIsoNimLowLevelCodePanel*()

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by step_list / build / errors / search_results — E2E
  ## paths can land a null cstring in the legacy record, and naive
  ## ``$`` would throw inside ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc instructionToVm(instr: Instruction): LowLevelInstruction =
  ## Map the legacy ``Instruction`` (langstring fields) to the
  ## platform-neutral ``LowLevelInstruction`` value type the
  ## ViewModel layer consumes.
  LowLevelInstruction(
    name: safeStr(cast[cstring](instr.name)),
    args: safeStr(cast[cstring](instr.args)),
    other: safeStr(cast[cstring](instr.other)),
    offset: instr.offset,
    highLevelPath: safeStr(cast[cstring](instr.highLevelPath)),
    highLevelLine: instr.highLevelLine)

proc instructionsToVm(legacy: Instructions): LowLevelInstructionList =
  result.address = legacy.address
  result.error = safeStr(cast[cstring](legacy.error))
  result.instructions = newSeqOfCap[LowLevelInstruction](legacy.instructions.len)
  for i in 0 ..< legacy.instructions.len:
    result.instructions.add(instructionToVm(legacy.instructions[i]))

proc isNoirProject(): bool =
  ## Mirrors the legacy ``isNoirProject`` helper — Noir traces use
  ## a different offset display (``StepId(<offset>)``) for asm rows.
  data.services.debugger.location.path.split(".")[^1] == "nr"

proc activeOffsetForLocation(loc: types.Location): int =
  ## Return the active offset to highlight given the live debugger
  ## location.  Mirrors the legacy ``onLoadAsmFunctionResponse`` logic
  ## that picked ``self.location.line`` for Nim (where the asm rows
  ## carry C-source line numbers in ``highLevelLine``) and
  ## ``location.highLevelLine`` for everything else.  Returns
  ## ``NO_ACTIVE_OFFSET`` when no useful line is available so the
  ## view does not flag a phantom row.
  if loc.line < 0:
    NO_ACTIVE_OFFSET
  else:
    loc.line

# ---------------------------------------------------------------------------
# Legacy editor / Monaco view-zone plumbing — preserved verbatim so the
# Karax + Monaco fallback path still works for paths the IsoNim view
# does not yet render.  This is the same Monaco-driven asm rendering
# the legacy Karax ``method render`` set up; see the Section 5.4
# follow-up note in ``/tmp/isonim-migration.txt`` (originally raised
# from 1.40 no_source).
# ---------------------------------------------------------------------------

proc formatLine(instruction: Instruction): cstring =
  var name =
    if $instruction.name == "":
      "<no instructions>"
    elif $instruction.offset == "-1":
      "<no step id>"
    else:
      $instruction.name
  let offset =
    if isNoirProject():
      fmt"StepId({instruction.offset})"
    else:
      $instruction.offset

  cstring(
    align(offset, 4, ' ') & " " & alignLeft($name, 10, ' ') & alignLeft($instruction.args, 10, ' ') & alignLeft($instruction.other, 0, ' ')
  )

proc createViewZone(self: LowLevelCodeComponent, position: int, lineHeight: int, highLevelLine: int): Node =
  let instruction = self.editor.tabInfo.instructions.instructions[position]
  var zoneDom = document.createElement("div")

  zoneDom.id = fmt"high-level-view-zone-{position}"
  zoneDom.class = "high-level-view-zone high-level-content-widget"
  zoneDom.style.display = "flex"

  let textDom = document.createElement("span")
  textDom.class = "high-level-line"

  if not data.ui.editors[instruction.highLevelPath].tabInfo.isNil:
    let sourceCode = data.ui.editors[instruction.highLevelPath].tabInfo.sourceLines[highLevelLine-1]
    # `textContent`, not `innerHTML`.  `sourceCode` is A LINE OF THE RECORDED
    # PROGRAM'S OWN SOURCE — the most directly attacker-controlled string in
    # this front end, and one that is markup by construction for any HTML,
    # JSX, Vue, PHP or template file, and for any language whose string
    # literals happen to contain a tag.  Written as markup it executed in an
    # Electron renderer that runs with `nodeIntegration: true` the moment the
    # low-level view drew this overlay.
    textDom.textContent = cstring(fmt"{highLevelLine}| {sourceCode}")
    zoneDom.appendChild(textDom)

  let viewZone = js{
    afterLineNumber: position,
    heightInPx: lineHeight + 3,
    domNode: zoneDom
  }

  var zoneID: int

  if not self.editor.monacoEditor.isNil:
    self.editor.monacoEditor.changeViewZones do (view: js):
      var zoneId = cast[int](view.addZone(viewZone))
      zoneID = zoneId
      self.viewZones[position] = zoneId

  self.multiLineZones[position] = MultilineZone(dom: zoneDom, zoneId: zoneID, variables: JsAssoc[cstring, bool]{})

  return zoneDom

proc mapInstructions(self: LowLevelCodeComponent, tabInfo: TabInfo) =
  var prevLine = NO_LINE
  var prevPath = cstring""

  for i, instruction in tabInfo.instructions.instructions:
    if prevLine != instruction.highLevelLine or prevPath != instruction.highLevelPath:
      self.instructionsMapping[i] = instruction.highLevelLine

    prevLine = instruction.highLevelLine
    prevPath = instruction.highLevelPath

proc setViewZones(self: LowLevelCodeComponent) =
  for line, hLine in self.instructionsMapping:
    if not self.editor.monacoEditor.isNil and not self.multiLineZones.hasKey(line):
      let lineHeight = self.editor.monacoEditor.config.lineHeight
      let newZoneDom = createViewZone(self, line, lineHeight, hLine)

      self.viewDom[line] = newZoneDom

proc findHighlight(self: LowLevelCodeComponent, selectedLine: int): int =
  for key, val in self.instructionsMapping:
    if val == selectedLine:
      return key + 1

  return -1

proc loadAsm*(self: LowLevelCodeComponent, location: types.Location) =
  var functionLocation = FunctionLocation(
    path: location.path,
    name: location.functionName,
    key: location.key,
    forceReload: location.path.split(".")[^1] == "nr"  # Force reload on move for noir files
  )
  self.api.emit(CtLoadAsmFunction, functionLocation)


proc getAsmCode(self: LowLevelCodeComponent, location: types.Location) =
  let tabInfo = TabInfo(
    name: self.editor.name,
    location: location,
    loading: false,
    noInfo: false,
    lang: LangAsm,
  )

  self.partialTabInfo = tabInfo
  self.location = location
  self.loadAsm(location)

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyLowLevelCodeIntoVM*(self: LowLevelCodeComponent) =
  ## Bulk-replay the legacy ``self.editor.tabInfo.instructions`` cache
  ## into the VM.  Used by the layout when the panel container becomes
  ## visible (or is rebuilt) so the panel reflects every row already
  ## accumulated by the previous asm-load stream.  Per-row updates go
  ## through ``onLoadAsmFunctionResponse`` directly; this proc covers
  ## the bulk-replace scenario (e.g. opening the panel after some
  ## debugger navigation already happened).
  if lowLevelCodeVMInstance.isNil or self.isNil:
    return
  let tabInfo = self.editor.tabInfo
  if tabInfo.isNil:
    lowLevelCodeVMInstance.clearInstructions()
    return
  let vmList = instructionsToVm(tabInfo.instructions)
  lowLevelCodeVMInstance.setInstructions(vmList.instructions)
  lowLevelCodeVMInstance.setAddress(vmList.address)
  lowLevelCodeVMInstance.setErrorMessage(vmList.error)
  lowLevelCodeVMInstance.setNoirProject(isNoirProject())
  lowLevelCodeVMInstance.setActiveOffset(activeOffsetForLocation(self.location))

# ---------------------------------------------------------------------------
# Legacy event-bus handlers — kept so the existing IPC + mediator wiring
# keeps flowing.  Each handler also feeds the IsoNim VM so the panel
# stays in sync.
# ---------------------------------------------------------------------------

proc onLoadAsmFunctionResponse(self: LowLevelCodeComponent, instructions: Instructions) =
  ## Called when the backend streams the asm-load response.  Updates
  ## the legacy cache (still consulted by the Monaco view-zone setup)
  ## and mirrors the same data into the IsoNim VM so the live panel
  ## re-renders.
  var tabInfo = self.partialTabInfo
  tabInfo.instructions = instructions
  tabInfo.sourceLines = tabInfo.instructions.instructions.mapIt(formatLine(it))
  tabInfo.source = tabInfo.sourceLines.join(jsNl) & jsNl
  self.editor.tabInfo = tabInfo
  self.mapInstructions(tabInfo)

  discard setTimeout(proc() =
    self.setViewZones()
    self.data.redraw(),
    50
  )

  # For Nim, the instructions' highLevelLine values point to C lines (from
  # gdb.find_pc_line), and self.location is cLocation whose .line is the C line.
  # For other languages, highLevelLine == the source line == location.highLevelLine.
  let highlightSourceLine =
    if data.trace.lang == LangNim:
      self.location.line
    else:
      self.location.highLevelLine
  self.editor.tabInfo.highlightLine = self.findHighlight(highlightSourceLine)
  self.data.redraw()

  # Mirror into the parallel VM.  ``setInstructions`` replaces the row
  # list wholesale; the active-offset signal is refreshed against the
  # debugger's current source line.
  if not lowLevelCodeVMInstance.isNil:
    let vmList = instructionsToVm(instructions)
    lowLevelCodeVMInstance.setInstructions(vmList.instructions)
    lowLevelCodeVMInstance.setAddress(vmList.address)
    lowLevelCodeVMInstance.setErrorMessage(vmList.error)
    lowLevelCodeVMInstance.setNoirProject(isNoirProject())
    lowLevelCodeVMInstance.setActiveOffset(highlightSourceLine)

proc clear(self: LowLevelCodeComponent, location: types.Location) =
  self.editor.tabInfo = nil

  if location.path != self.path:
    self.editor = EditorViewComponent(
      id: data.generateId(Content.EditorView),
      path: location.path,
      data: data,
      lang: LangAsm,
      name: location.path,
      editorView: ViewLowLevelCode,
      tokens: JsAssoc[int, JsAssoc[cstring, int]]{},
      decorations: @[],
      whitespace: Whitespace(character: WhitespaceSpaces, width: 2),
      encoding: cstring"UTF-8",
      lastMouseMoveLine: -1,
      traces: JsAssoc[int, TraceComponent]{},
      expanded: JsAssoc[int, EditorViewComponent]{},
      service: data.services.editor,
      viewZones: JsAssoc[int, int]{},
    )

  self.viewZones = JsAssoc[int, int]{}
  self.instructionsMapping = JsAssoc[int, int]{}
  self.multilineZones =  JsAssoc[int, MultilineZone]{}
  self.path = location.path

  for _, dom in self.viewDom:
    discard jsDelete(dom)

  self.viewDom = JsAssoc[int, kdom.Node]{}

  if not lowLevelCodeVMInstance.isNil:
    lowLevelCodeVMInstance.clearInstructions()

proc reloadLowLevel*(self: LowLevelCodeComponent) =
  self.clear()
  # For Nim, use the C-level location to load the correct assembly function.
  if data.trace.lang == LangNim and data.services.debugger.cLocation.path != "":
    self.getAsmCode(data.services.debugger.cLocation)
  else:
    self.getAsmCode(data.services.debugger.location)

method onCompleteMove*(self: LowLevelCodeComponent, response: MoveState) {.async.} =
  # For Nim, the assembly corresponds to the generated C code, so use cLocation
  # which has the C-level path and function name needed to load the right function.
  let asmLocation =
    if data.trace.lang == LangNim and response.cLocation.path != "":
      response.cLocation
    else:
      response.location
  if asmLocation.path != "":
    self.clear(asmLocation)
    self.getAsmCode(asmLocation)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc showGeneratedListing*(rows: seq[LowLevelInstruction];
                           anchors: seq[MappingAnchor];
                           support: ArtefactSupport;
                           sourcePath: string; sourceLine: int;
                           notice: string): bool {.discardable.} =
  ## Paint a generated-code listing into THIS pane, anchored to a cursor.
  ##
  ## `Generated-Code-Listing.md` §7 asks for an editor TAB and this is a PANE,
  ## which is a divergence and is recorded as one rather than glossed: the pane
  ## is the surface that exists and already renders every row's fidelity badge
  ## (GCL-A7), the three not-aligned states (GCL-A8) and the sync toggle's
  ## visible state, all asserted in `test_low_level_code_view_anchors.nim`.
  ## Opening a tab that renders NOTHING, in order to match the spec's noun,
  ## would have been the worse divergence — a surface a user opens and finds
  ## empty is the failure this whole thread is closing, and `openTab(name,
  ## ViewInstructions)` would have produced exactly that, since the
  ## instructions view is fed by `CtLoadAsmFunction` and knows nothing about a
  ## compile artefact.
  ##
  ## Returns whether the ANCHORS were installed. False is a real answer and not
  ## an error: `setAnchors` refuses a set that `validate` rejects, and it
  ## refuses it wholesale, because a pane showing the valid half of a mapping
  ## it knows to be broken makes the same confident-wrong-answer error over
  ## fewer rows. The rows are painted either way — a listing whose mapping was
  ## refused is still the compiler's own output, and §5's rule is that it says
  ## so rather than disappearing.
  if lowLevelCodeVMInstance.isNil:
    return false
  lowLevelCodeVMInstance.setInstructions(rows)
  lowLevelCodeVMInstance.setErrorMessage(notice)
  lowLevelCodeVMInstance.setNoirProject(true)
  lowLevelCodeVMInstance.setActiveOffset(NO_ACTIVE_OFFSET)
  lowLevelCodeVMInstance.clearAnchors()
  if anchors.len == 0:
    return false
  if not lowLevelCodeVMInstance.setAnchors(anchors, support):
    return false
  # THE CURSOR IS WHAT THE PANE IS NOW SHOWING. Without this the pane holds a
  # correct mapping and points at nothing — the listing would open at row zero
  # regardless of where the developer asked from, which is GCL-D10's
  # whole-project reading reintroduced one layer down.
  let decision = lowLevelCodeVMInstance.syncFromSourceLine(sourcePath, sourceLine)
  if decision.outcome == soAligned:
    # `rowsFor` rather than reaching into the signal: the VM owns its anchors,
    # and it already has the accessor the view uses.
    let (first, _) = lowLevelCodeVMInstance.rowsFor(decision)
    if first >= 0 and first < rows.len:
      lowLevelCodeVMInstance.setActiveOffset(rows[first].offset)
  true

proc initLowLevelCodeVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``LowLevelCodeVM`` using an
  ## externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initLowLevelCodeVM`` before the real backend
  ## was available) it is replaced so the panel uses the real backend.
  if lowLevelCodeVMInstance != nil:
    clog "LowLevelCodeVM: replacing existing instance with shared-store version"
    isoNimLowLevelCodeMountedIds = JsAssoc[int, bool]{}
  lowLevelCodeVMStore = store
  lowLevelCodeVMInstance = createLowLevelCodeVM(store)
  clog "LowLevelCodeVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimLowLevelCodePanel()

proc initLowLevelCodeVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initStepListVM`` / ``initSearchResultsVM`` —
  ## a stub backend so the panel can still render before
  ## ``configureMiddleware`` runs.
  if lowLevelCodeVMInstance != nil:
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

  lowLevelCodeVMStore = createReplayDataStore(stubBackend)
  lowLevelCodeVMInstance = createLowLevelCodeVM(lowLevelCodeVMStore)
  clog "LowLevelCodeVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimLowLevelCodePanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimLowLevelCodePanel*() =
    ## Mount the IsoNim low-level-code view into the GoldenLayout-
    ## managed container.  The container's id is
    ## ``lowLevelCodeComponent-{id}``; each open Low Level Code panel
    ## instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes.
    if lowLevelCodeVMInstance.isNil:
      return
    if lowLevelCodeComponentRef.isNil:
      return
    let componentId = lowLevelCodeComponentRef.id
    if isoNimLowLevelCodeMountedIds.hasKey(componentId):
      return

    let key = cstring("lowLevelCodeComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimLowLevelCodeMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimLowLevelCodePanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimLowLevelCodeMountedIds[componentId] = true
      try:
        mountIsoNimLowLevelCode(container, lowLevelCodeVMInstance)
      except:
        cerror "tryMountIsoNimLowLevelCodePanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any rows the legacy component already carries so the
      # freshly-mounted view reflects the latest list.
      if not lowLevelCodeComponentRef.isNil:
        syncLegacyLowLevelCodeIntoVM(lowLevelCodeComponentRef)

    doMount()
else:
  proc tryMountIsoNimLowLevelCodePanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initLowLevelCodeVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

method unregister*(self: LowLevelCodeComponent) =
  ## Release the module-global slot and the mounted marker before the base
  ## implementation drops the event-bus subscriptions.
  ##
  ## WITHOUT THIS THE PANE COMES BACK BLANK, PERMANENTLY, AND SILENTLY. Both
  ## globals are write-once: `register` assigns `lowLevelCodeComponentRef` only
  ## `if isNil`, and the mount returns early at its
  ## `isoNimLowLevelCodeMountedIds.hasKey` guard. Neither was ever cleared. After a
  ## teardown `lowLevelCodeComponentRef` still points at a component whose DOM
  ## container is gone, and the marker for its id survives into the next
  ## component handed the same id — GoldenLayout reuses them, and ids restart
  ## from 0 after a layout reset — whose mount then returns at the guard and
  ## draws nothing.
  ##
  ## It is an ordinary transition, not an exotic one:
  ## `ui/session_switch.nim:337` unregisters EVERY component of a closing
  ## session and `ui/layout.nim` unregisters a closed panel. And the failure is
  ## silent, which is what made it survive — a pane that returns early at a
  ## guard is indistinguishable from a pane with nothing to show.
  ##
  ## The VM is deliberately NOT reset: it is a singleton by design and holds
  ## state about the trace rather than about this panel, so dropping it would
  ## make closing and reopening the pane lose data that is still true.
  ##
  ## Modelled on `ui/constraints.nim`, which is the worked example, and
  ## `ui/scratchpad.nim`, which is the original.
  if lowLevelCodeComponentRef == self:
    lowLevelCodeComponentRef = nil
  discard jsDelete(isoNimLowLevelCodeMountedIds[self.id])
  procCall unregister(Component(self))

method register*(self: LowLevelCodeComponent, api: MediatorWithSubscribers) =
  ## Register the LowLevelCodeComponent with the mediator.  Bring up
  ## the IsoNim LowLevelCodeVM lazily so the mount procedure can find
  ## it; the shared-store version is installed by
  ## ``configureMiddleware`` if the ViewModel layer is enabled.
  self.api = api
  self.api.subscribe(CtLoadAsmFunctionResponse, proc(kind: CtEventKind, instructions: Instructions, sub: Subscriber) =
    self.onLoadAsmFunctionResponse(instructions))
  initLowLevelCodeVM()
  if lowLevelCodeComponentRef.isNil:
    lowLevelCodeComponentRef = self
    tryMountIsoNimLowLevelCodePanel()
