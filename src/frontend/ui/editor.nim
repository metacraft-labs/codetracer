import
  std/[ cstrutils, jsre, options ],
  ui_imports, trace, debug, menu, flow, value, no_source, shortcuts, kdom,
  trace_macro, trace_static,
  column_click_resolver,
  editor_decoration_layers, trace_redraw_policy,
  flow_line_styles, review_flow_adapter, review_flow_selection,
  ../[ renderer, communication, event_helpers, lsp_router ],
  ../../common/[ ct_event, review_source_paths ]

from welcome_screen import resetView
from event_log import findTRNode
from dom import createElement

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The EditorVM receives the same data but does not affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/viewmodels/editor_vm import
  EditorVM, createEditorVM
when defined(js):
  import isonim/web/web_renderer
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_editor_view import renderEditorPanel
# The IsoNim editor view owns direct editor containers for top-level and
# expansion editors; Monaco still manages the container's internal DOM.

# Module-level EditorVM instance. Created once and fed data whenever
# the legacy event-bus handlers fire. Rendering still reads from legacy
# data so behaviour is unchanged.
var editorVMInstance: EditorVM
var editorVMStore: ReplayDataStore

# Track which editor instances have been IsoNim-mounted by their id.
# Once an editor's container is created by IsoNim, its legacy renderer entry is removed.
var isoNimEditorMountedIds = JsAssoc[int, bool]{}

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# ---------------------------------------------------------------------------

proc initEditorVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel EditorVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel).
  ##
  ## If a stub-backed instance already exists (created by initEditorVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  if editorVMInstance != nil:
    clog "EditorVM: replacing existing instance with shared-store version"
  editorVMStore = store
  editorVMInstance = createEditorVM(store)
  clog "EditorVM: parallel ViewModel instance created (shared store)"

proc initEditorVM() =
  ## Lazily create the parallel EditorVM backed by a stub
  ## BackendService.  Fallback when no shared store has been provided
  ## via `initEditorVMWithStore`.
  if editorVMInstance != nil:
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

  editorVMStore = createReplayDataStore(stubBackend)
  editorVMInstance = createEditorVM(editorVMStore)
  clog "EditorVM: parallel ViewModel instance created (stub backend)"

proc syncEditorDebuggerPosition(rrTicks: int, path: cstring, line: int;
                                sourceGeneration: int = 0;
                                sourceDigest: cstring = cstring"") =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the EditorVM's activeFileName memo sees the updated location.
  if editorVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  editorVMStore.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  clog fmt"EditorVM: synced debugger rrTicks={ticks}"

include system/timers

type langstring = cstring

# for now applied to user config, but not to commands:
# the commands shortcuts are hardcoded in this file
# so review them if needed!
const MONACO_SHORTCUTS_WHITELIST: seq[cstring] =
  @[
      "F2",
      "F8",
      "F10",
      "F11",
      "F12",
      "SHIFT+F2",
      "SHIFT+F8",
      "SHIFT+F10",
      "SHIFT+F11",
      "SHIFT+F12",
      "CTRL+KeyS",
      # BUILD — `CTRL+B`, spelled as `default_config.yaml` spells it.
      #
      # `initShortcutMap` copies the YAML string into `Shortcut.editor`
      # VERBATIM (`common/config.nim`: `editor: normalShortcut`, and
      # `normalize` is the identity), so the entry that matches `build`'s
      # binding is `CTRL+B` and not `CTRL+KeyB`. `ui/shortcuts.nim:18` is what
      # makes the two spellings equivalent to Monaco — a one-character final
      # token becomes `Key<X>` there — so `CTRL+KeyS` above and `CTRL+B` here
      # both resolve, and matching the YAML is what makes the lookup on line
      # 295 hit at all.
      #
      # WHY IT IS NEEDED, measured on the deployed site rather than reasoned
      # from the comment below. `noirstudio.dev`, caret placed in
      # `src/main.nr` by clicking a `.view-line`, then `Ctrl+B`: ZERO
      # `nargo compile` worker starts, zero `.wasm` fetches, and no
      # `shortcuts: global handle ctrl+b build` line. The same page with focus
      # on `<body>`: the build ran, `nbpCompile-exit verdict=npvSucceeded`.
      # Two in-editor trials, one after typing into the buffer — the user's
      # actual gesture — both dead. This is the bug report.
      #
      # WHERE THE EVENT DIES, and it is NOT `stopCallback`. A keydown listener
      # installed before any page script saw `ctrl+b` arrive at `document` in
      # the CAPTURE phase, `defaultPrevented == false`, target
      # `div.native-edit-context` — and then never reach `document` in the
      # BUBBLE phase, which is where Mousetrap listens. Something between the
      # two stops propagation while the caret is in Monaco. So a global bind
      # cannot fire from inside the editor no matter what `stopCallback`
      # answers, because `stopCallback` is only consulted for events that
      # arrive.
      #
      # NOT A DOUBLE-DELIVERY, and this is the question the ALT+F8 note below
      # says to ask. Monaco binds nothing to `ctrl+b`: the standalone editor's
      # own keybinding resolver, queried on the live page, returns an EMPTY
      # list for Ctrl+B/Cmd+B — unlike ALT+F8, which is Monaco's marker
      # navigation and which is why that chord fired twice. The two paths stay
      # exclusive for the reason `ui/shortcuts.nim` records: with the caret in
      # Monaco the event never reaches Mousetrap (measured above), and with
      # the caret outside, the delegated Monaco command does not run.
      "CTRL+B",
  ]
  # BUILD-ERROR NAVIGATION IS DELIBERATELY *NOT* IN THE LIST ABOVE, and the
  # reason is worth recording because the obvious change is the wrong one.
  #
  # Mousetrap's DEFAULT `stopCallback` ignores a chord raised inside a
  # textarea, and Monaco's input surface is one — so a global binding would
  # normally never fire while the user was editing, which is the only place
  # anybody presses "go to next error" from. That is what this whitelist is
  # for, and `ALT+F8` was added to it on exactly that reasoning.
  #
  # But `ui/shortcuts.nim:318` overrides `stopCallback` to `return false` for
  # the whole application. The global binding therefore ALREADY fires with the
  # caret in the editor, and adding the chord here made it fire TWICE — once
  # through Mousetrap and once through the delegated Monaco command. Measured
  # in a browser tab: one press of ALT+F8 on a one-error build advanced to the
  # error and then wrapped, reporting "wrapped to first error" for a list the
  # user had not finished walking once.
  #
  # THE SENTENCE ABOVE IS TRUE OF ALT+F8 AND FALSE IN GENERAL — see the
  # `CTRL+B` entry in the list. "The global binding ALREADY fires with the
  # caret in the editor" holds only for chords whose keydown still REACHES
  # `document`'s bubble phase. ALT+F8 does; `ctrl+b` does not, so for it the
  # whitelist is the only path and there is nothing to double up with. The
  # distinguishing question is not `stopCallback`, it is whether Monaco
  # consumes the chord — which `default_config.yaml`'s own note records from
  # the other side: "with the chord removed from the whitelist it fired NOT AT
  # ALL, because Monaco consumed the key before it reached the document."
  #
  # The entries above predate that override and are left alone: F2/F8/F10-F12
  # are chords Monaco itself would otherwise consume, and changing them is a
  # separate question from this one.
const EDITOR_GUTTER_PADDING = 2 #px

proc getLineFunctionName(self: EditorViewComponent, line: int): cstring
proc removeClasses(index: int, class: cstring, name: string)
proc styleLines(
  self: EditorViewComponent,
  editor: MonacoEditor,
  baseLines: seq[MonacoLineStyle],
  flowLines: seq[MonacoLineStyle],
  flowDataAvailable: bool)
proc ensureExpanded*(self: EditorViewComponent, expanded: EditorViewComponent, line: int)
proc editorLineJump(self: EditorViewComponent, line: int, behaviour: JumpBehaviour)
proc sourceCallJump(self: EditorViewComponent, path: cstring, line: int, targetToken: cstring, behaviour: JumpBehaviour)
proc initMonacoForEditor(self: EditorViewComponent, selector: cstring)
proc editorAfterRedraw(self: EditorViewComponent)
proc scheduleInitialFlowLoad(self: EditorViewComponent)
proc tryMountIsoNimEditorPanel*(self: EditorViewComponent)
proc renderTopLevelEditorDirect*(self: EditorViewComponent; containerId: cstring)
proc renderExpandedEditorDirect(self: EditorViewComponent)

proc insideLocation(x: float, y: float, location: HTMLBoundingRect): bool =
  x >= location.left and x <= location.right and y >= location.top and y <= location.bottom

proc clearViewZones*(self: EditorViewComponent) =
  self.monacoEditor.changeViewZones do (view: js):
    for viewZone in self.viewZones:
      view.removeZone(viewZone)

proc toggleMacroExpansion*(self: EditorViewComponent) =
  if self.lastMouseMoveLine != -1:
    if self.expanded.hasKey(self.lastMouseMoveLine):
      self.expanded[self.lastMouseMoveLine].isExpanded = not self.expanded[self.lastMouseMoveLine].isExpanded
      self.data.redraw()
    else:
      expand(self.path, self.lastMouseMoveLine)

proc loadKeyPlugins*(self: Component) =
  cdebug "load key plugins"
  for keys, plugin in self.data.keyPlugins[Content.EditorView]:
    var shMonaco = shortcut($keys)
    if shMonaco == -1:
      cwarn "cant create shorctut for key plugin " & $keys
    else:
      self.toJs.monacoEditor.addCommand(shMonaco, proc =
        let position = self.toJs.monacoEditor.getPosition()
        let wordInfo = self.toJs.monacoEditor.getModel().getWordAtPosition(position)

        let path = if not self.toJs.path.isNil: cast[cstring](self.toJs.path) else: cast[cstring](self.toJs.lowLevelTab.path)
        let line = cast[int](position.lineNumber)
        let column = cast[int](position.column)
        let word = if not wordInfo.isNil: cast[cstring](wordInfo.word) else: cstring""
        let startColumn = if not wordInfo.isNil: cast[int](wordInfo.startColumn) else: -1
        let endColumn = if not wordInfo.isNil: cast[int](wordInfo.endColumn) else: -1
        let context = KeyPluginContext(
          path: path,
          line: line,
          column: column,
          startColumn: startColumn,
          endColumn: endColumn,
          word: if not word.isNil: word else: cstring"",
          data: self.data)
        discard plugin(context), cstring"")

func getLine(editor: MonacoEditor): int =
  editor.getPosition().lineNumber

func getLineAndColumn(editor: MonacoEditor): (int, int) =
  let position = editor.getPosition()

  (position.lineNumber, position.column)

func loadCallName(lineText: cstring, column: int): cstring =
  if column >= lineText.len:
    return NO_NAME

  var i = column

  while i >= 0 and (lineText[i].isAlphaNumeric or lineText[i] == '_'):
    i -= 1

  var start = i + 1
  i = column + 1

  while i < lineText.len and (lineText[i].isAlphaNumeric or lineText[i] == '_'):
    i += 1

  var finish = i - 1
  lineText.slice(start, finish + 1)

var commands = JsAssoc[cstring, (proc(editor: MonacoEditor, e: EditorViewComponent): void)]{ ## commands for each monaco editor instance # app-global
  # TODO improve or retire other modes
  # cstring"ALT+P":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.flow.switchFlowUI(FlowParallel),
  cstring"ALT+KeyI":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.flow.switchFlowUI(FlowInline),
  # cstring"ALT+M":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.flow.switchFlowUI(FlowMultiline),
  cstring"ALT+KeyE":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.toggleMacroExpansion(),

  cstring"ALT+KeyT":      proc(editor: MonacoEditor, e: EditorViewComponent) =
    runTracepoints(data),


  cstring"CTRL+Enter": proc(editor: MonacoEditor, e: EditorViewComponent) =
    runTracepoints(data),

  cstring"CTRL+KeyS":      proc(editor: MonacoEditor, e: EditorViewComponent) =
    if not data.functions.update.isNil:
      data.functions.update(data, false)
    else:
      data.saveFiles(data.services.editor.active),

  cstring"CTRL+F5":     proc(editor: MonacoEditor, e: EditorViewComponent) =
    if not data.functions.toggleMode.isNil:
      data.functions.toggleMode(data),

  cstring"CTRL+KeyE":   proc(editor: MonacoEditor, e: EditorViewComponent) =
    ## Mirror the Mousetrap shortcut so toggling works while Monaco has focus.
    if not data.functions.toggleReadOnly.isNil:
      data.functions.toggleReadOnly(data)
      return
    if not data.functions.toggleMode.isNil:
      data.functions.toggleMode(data),

  # TODO: support concurrent when add later on
  # cstring"CTRL+F10": proc(editor: MonacoEditor, e: EditorViewComponent) =
  #   let taskId = genTaskId(Step)
  #   data.step("co-next", CoNext, reverse=false, taskId=taskId),

  cstring"CTRL+F8": proc(editor: MonacoEditor, e: EditorViewComponent) =
    if editor.hasTextFocus():
      let line = editor.getLine()
      e.editorLineJump(line, SmartJump),

  cstring"CTRL+F11": proc(editor: MonacoEditor, e: EditorViewComponent) =
    if editor.hasTextFocus():
      let position = editor.getPosition()
      let targetToken = editor.toJs.getModel().getWordAtPosition(position)

      if not targetToken.isNil:
        e.sourceCallJump(e.name, position.lineNumber, if not targetToken.word.isNil: cast[cstring](targetToken.word) else: cstring"", SmartJump)
}

for i in 1 .. 9:
  capture [i]:
    commands[cstring("CTRL+Digit" & $i)] = proc(editor: MonacoEditor, e: EditorViewComponent) =
      discard data.ui.activeFocus.onCtrlNumber(i)

proc delegateShortcuts*(self: EditorViewComponent, editor: MonacoEditor) =
  cdebug "create context key"
  console.log("SETTING READONLY")
  self.readOnly = editor.toJs.createContextKey(cstring"readOnly", self.data.ui.readOnly)
  for sh, command in commands:
    cdebug "editor: delegate shortcut " & sh
    self.delegateShortcut(sh, command, editor)

  for action, shortcuts in data.config.shortcutMap.actionShortcuts:
    for shortcut in shortcuts:
      let editorShortcut = shortcut.editor
      if editorShortcut notin MONACO_SHORTCUTS_WHITELIST:
        cdebug "editor: ignoring, because not in monaco shortcuts whitelist: " & $editorShortcut
        continue
      cdebug "editor: delegate config monaco shortcut " & $editorShortcut
      capture action, editorShortcut:
        let command = proc(editor: MonacoEditor, e: EditorViewComponent) =
          cdebug "editor: shortcuts: monaco handle " & $editorShortcut & " " & $action
          data.actions[action](nil)
        self.delegateShortcut(editorShortcut, command, editor)

proc closeEditorTab*(data: Data, id: cstring) =
  cdebug "tabs: closeEditorTab " & $id
  if not data.ui.editors.hasKey(id):
    raise newException(Exception, "There is not any editor with the given id.")

  # get the editor
  let editor = data.ui.editors[id]
  unregisterLspEditor(editor)

  # remove editor from open editors registry
  if editor.service.open.hasKey(id):
    discard jsDelete(editor.service.open[id])

  # remove all instances of editor's path from tab history
  let newTabHistory = data.services.editor.tabHistory.filterIt(
    it.name != id
  )

  data.services.editor.tabHistory = newTabHistory
  data.services.editor.historyIndex = data.services.editor.tabHistory.len - 1

  cdebug "tabs: closeEditorTab: historyIndex -> " & $data.services.editor.historyIndex

  # remove editor component from editors registry
  let editorId = editor.id
  discard jsDelete(data.ui.editors[id])

  # remove editor renderer instance (may already be absent if IsoNim-mounted)
  renderer.removeLegacyRendererInstanceByKey(id)

  # Clean up the IsoNim mount tracking for this editor.
  if isoNimEditorMountedIds.hasKey(editorId):
    discard jsDelete(isoNimEditorMountedIds[editorId])

  # add editor to closed tabs registry
  let header = EditorViewTabArgs(name: id, editorView: editor.editorView)
  data.services.editor.closedTabs.add(header)

  # set editor view type panel to nil
  if editor.service.open.len == 0:
    data.ui.editorPanels[EditorView.ViewSource] = nil
    cdebug "editor: on close tab, no tabs left: active = nil"
    data.services.editor.active = nil

proc closeActiveTab*(data: Data) {.locks: 0.} =
  var panel = data.ui.activeEditorPanel
  var active = panel.getActiveContentItem()
  var oldActive = data.services.editor.active

  if data.services.editor.open.hasKey(oldActive) and data.services.editor.open[oldActive].changed:
    data.saveDialog(oldActive, proc = data.closeActiveTab())
  elif data.services.editor.open.hasKey(oldActive):
    active.toJs.remove()
    data.closeEditorTab(oldActive)
  else:
    cwarn "editor: closing tab, but  implemented close expanded.nim"

proc getBoundingClientRect(s: js): HTMLBoundingRect {.importcpp: "#.getBoundingClientRect()".}

proc removeClasses(index: int, class: cstring, name: string) =
  let elements = jqall(&"#{name}-{index} .{class}")

  for element in elements:
    cast[ClassList](element.classList).remove(class)

proc disableDebugShortcuts*(self: EditorViewComponent) =
  console.log("EDITOR VIEW COMPONENT")
  console.log(self)
  if not self.isNil and not self.readOnly.isNil:
    self.readOnly.set(false)

proc enableDebugShortcuts*(self: EditorViewComponent) =
  console.log("EDITOR VIEW COMPONENT")
  console.log(self)
  if not self.isNil and not self.readOnly.isNil:
    self.readOnly.set(true)

proc highlightTag(path: cstring, tag: Tag, name: cstring) =
  var line = -1
  var highlightEditor = data.ui.editors[path].monacoEditor
  if tag.kind == TagLine and tag.line != -1:
    line = tag.line
  else:
    let regex = if tag.kind == TagRegex: tag.regex else: name
    let location = cast[seq[js]](highlightEditor.getModel().findMatches(regex, false, true, false, false))
    if location.len > 0:
      line = cast[int](location[0][cstring"range"].startLineNumber)
  if line != -1:
    highlightLine(data.services.editor.active, line)
    gotoLine(line)

proc toDeltaDecorations(
    textModel: MonacoTextModel,
    lines: seq[MonacoLineStyle]): seq[DeltaDecoration] =
  ## Translate our line-style descriptions into Monaco decoration requests.
  ## Split out of ``styleLines`` so the base and the flow layer are built by
  ## the same code path and cannot drift apart.
  result = @[]
  for lineItem in lines:
    let line = lineItem
    let lineContent = textModel.getLineContent(line.line)
    let endIndex = lineContent.len() + 1
    let startIndex = textModel.getLineFirstNonWhitespaceColumn(line.line)
    if not line.afterContent.isNil:
      # An *injected text* decoration: Monaco renders `after.content` as a real
      # inline span at the range's end position, carrying `inlineClassName`.
      # The range is collapsed there because injected text is placed at the end
      # position and a non-empty range would additionally style the line's own
      # text with the chip's class.  `showIfCollapsed` keeps it alive on an
      # empty line, whose only column is 1.
      result.add(DeltaDecoration(
        `range`: newMonacoRange(line.line, endIndex, line.line, endIndex),
        options: js{
          showIfCollapsed: true,
          after: js{
            content: line.afterContent,
            inlineClassName: line.afterClass,
            inlineClassNameAffectsLetterSpacing: true}}))
      continue
    result.add(DeltaDecoration(
      `range`: newMonacoRange(line.line, startIndex, line.line, endIndex),
      options: js{
        isWholeLine: line.class.isNil or
                     ui_imports.jslib.startsWith(line.class, "on") or
                     line.class == "diff-added" or
                     ui_imports.jslib.startsWith(line.class, "line-diff-") or
                     line.class == "flow-taken" or
                     line.class == "flow-not-taken",
        className: line.class,
        inlineClassName: line.inlineClass}))

proc styleLines(
    self: EditorViewComponent,
    editor: MonacoEditor,
    baseLines: seq[MonacoLineStyle],
    flowLines: seq[MonacoLineStyle],
    flowDataAvailable: bool) =
  ## Apply the editor's Monaco line decorations as TWO independently tracked
  ## layers (see ``ui/editor_decoration_layers.nim`` for the rules and for the
  ## #594 post-mortem).
  ##
  ## ``baseLines`` (current-line highlight, diff / DeepReview stripes, origin
  ## chain hops) is recomputed from inputs that are always available, so it is
  ## replaced on every call. ``flowLines`` (``flow-taken`` / ``flow-not-taken``
  ## and the per-line hit / skip / unknown styles) is derived from omniscience
  ## flow data, which is *absent* for the whole window between ``loadFlow``
  ## installing a fresh ``FlowComponent`` and ``ct/updated-flow`` delivering
  ## its payload — a window that ``onCompleteMove`` opens on every single step.
  ## Pushing the resulting empty set into Monaco is what made the conditional
  ## branch colours disappear, so during that window the previous flow layer is
  ## retained instead.
  if editor.decorations.toJs.isNil:
    editor.decorations = @[]

  let textModel = self.monacoEditor.getModel()
  if textModel.isNil:
    return

  let baseDecorations = toDeltaDecorations(textModel, baseLines)
  let computedFlowDecorations = toDeltaDecorations(textModel, flowLines)
  let flowLayer = nextFlowDecorationLayer(
    previous = flowDecorationLayer(self.decorations),
    computed = computedFlowDecorations,
    flowDataAvailable = flowDataAvailable)

  self.decorations = mergeDecorationLayers(baseDecorations, flowLayer)

  editor.decorations = editor.deltaDecorations(
    editor.decorations,
    self.decorations.mapIt(it[0]))

  if not self.data.ui.welcomeScreen.isNil:
    self.data.ui.welcomeScreen.resetView()

proc applyColumnBreakpointDecorations*(self: EditorViewComponent) =
  ## M6 — Column-Aware Replay Navigation: render column-anchored
  ## breakpoint markers as Monaco inline decorations.
  ##
  ## For each registered breakpoint with ``column > 0`` (i.e. a
  ## breakpoint placed via ``DebuggerService.addColumnBreakpoint`` or
  ## the M6 Alt+click affordance below) we emit a Monaco decoration
  ## spanning ``(line, column..column+1)`` with the
  ## ``ct-column-breakpoint-marker`` inline class and a hover tooltip
  ## naming the bound column.  This satisfies two M6 deliverables:
  ##
  ##   * "Marker visibly anchors to the column, not the line start —
  ##      column position survives editor scroll / resize."  Monaco
  ##      anchors decorations to text positions, so they track scroll
  ##      / resize automatically.
  ##   * "Hovering an existing column breakpoint shows the bound
  ##      column in a tooltip" via the decoration's ``hoverMessage``.
  ##
  ## The decoration IDs are stored on ``self.columnBreakpointDecorations``
  ## so the next call diffs against them via ``deltaDecorations``,
  ## the standard Monaco update pattern.  Breakpoints without a
  ## bound column (legacy line-only) contribute no decoration —
  ## their visual representation remains the gutter dot rendered by
  ## ``editorLineNumber`` in ``ui/trace.nim``.
  if self.monacoEditor.isNil:
    return
  let debuggerService = self.data.services.debugger
  if debuggerService.isNil:
    self.columnBreakpointDecorations = self.monacoEditor.deltaDecorations(
      self.columnBreakpointDecorations, @[])
    return
  let path = self.path
  var newDecorations: seq[DeltaDecoration] = @[]
  if debuggerService.breakpointTable.hasKey(path):
    let textModel = self.monacoEditor.getModel()
    for line, b in debuggerService.breakpointTable[path]:
      if b.column <= 0 or not b.enabled:
        continue
      var column = b.column
      var endColumn = column + 1
      # Clamp to the actual line length so the marker never extends
      # past the line's terminator — Monaco rejects out-of-range
      # decoration ranges silently and we'd lose the marker.
      if not textModel.isNil:
        let maxColumn = textModel.getLineMaxColumn(line)
        if maxColumn >= 1:
          if column > maxColumn:
            column = maxColumn
          if endColumn > maxColumn:
            endColumn = maxColumn
          if endColumn <= column:
            endColumn = column + 1
      let hoverText = cstring("Column breakpoint at line " & $line &
                              ", column " & $b.column)
      newDecorations.add(DeltaDecoration(
        `range`: newMonacoRange(line, column, line, endColumn),
        options: js{
          inlineClassName: cstring"ct-column-breakpoint-marker",
          stickiness: 1,
          hoverMessage: js{value: hoverText}}))
  self.columnBreakpointDecorations = self.monacoEditor.deltaDecorations(
    self.columnBreakpointDecorations, newDecorations)


proc setColumnBreakpoint*(
    self: EditorViewComponent;
    tabInfo: TabInfo;
    line: int;
    column: int) =
  ## M6 — invoke the column-aware breakpoint path on the underlying
  ## ``DebuggerService`` and refresh the editor row so the gutter dot
  ## and the new column-anchored decoration both render.
  self.data.services.debugger.addColumnBreakpoint(tabInfo.name, line, column)
  self.applyColumnBreakpointDecorations()
  self.refreshEditorLine(line)


proc lineActionClickAt*(
    self: EditorViewComponent;
    tabInfo: TabInfo;
    line: int;
    monacoColumn: Option[int];
    onGutterElement: bool;
    lineMaxColumn: Option[int] = none(int)) =
  ## M6 — dispatch a gutter / editor click to either the legacy
  ## line-only ``toggleBreakpoint`` or the column-aware
  ## ``addColumnBreakpoint`` path, based on the resolver in
  ## ``column_click_resolver``.
  ##
  ## The pixel→column mapping is provided by Monaco
  ## (``e.target.position.column``) when available; this proc just
  ## consumes the resolver's verdict.  Pulling the dispatch out of
  ## the raw DOM event handler keeps the legacy
  ## ``lineActionClick(element)`` path untouched for the
  ## ``gutter-line`` / ``gutter-breakpoint`` HTML elements that the
  ## CodeTracer custom gutter emits.
  if line <= 0:
    return
  let resolution = resolveColumnClick(
    line = line,
    monacoColumn = monacoColumn,
    onGutterElement = onGutterElement,
    lineMaxColumn = lineMaxColumn)
  case resolution.kind
  of ColumnAwareClick:
    self.setColumnBreakpoint(tabInfo, resolution.line, resolution.column)
  of GutterClick:
    self.data.services.debugger.toggleBreakpoint(tabInfo.name, resolution.line)
    self.refreshEditorLine(resolution.line)


proc lineActionClick(self: EditorViewComponent, tabInfo: TabInfo, line: js) =
  var element = line
  var dataset = element.dataset

  if dataset.line.isNil:
    element = element.parentNode
    dataset = element.dataset

  if not dataset.line.isNil:
    let lineNumber = cast[cstring](dataset.line).parseJSInt()
    self.data.services.debugger.toggleBreakpoint(tabInfo.name, lineNumber)
    self.refreshEditorLine(lineNumber)

proc lineActionContextMenu(self: EditorViewComponent, tabInfo: TabInfo, line: js) =
  var element = line
  let dataset = element.dataset

  if dataset.line.isNil:
    element = element.parentNode
  if not dataset.line.isNil:
    let lineNumber = cast[cstring](dataset.line).parseJSInt()
    let path = tabInfo.name
    if self.data.services.debugger.isEnabled(path, lineNumber):
      self.data.services.debugger.disable(path, lineNumber)
    else:
      self.data.services.debugger.enable(path, lineNumber)
    self.refreshEditorLine(lineNumber)

method clear*(self: EditorViewComponent) =
  self.flow.clear()

func has(tab: TabInfo, instruction: Instruction, i: int, offset: int): bool =
  if i + 1 < tab.instructions.instructions.len:
    var limit = tab.instructions.instructions[i + 1].offset

    result = offset >= instruction.offset and offset < limit
  else:
    result = offset >= instruction.offset

method position*(self: EditorViewComponent): int =
  if self.data.services.debugger.frameInfo.hasSelected and
    self.data.services.debugger.frameInfo.offset != NO_OFFSET:

    for i, instruction in self.tabInfo.instructions.instructions:
      if self.tabInfo.has(instruction, i, self.data.services.debugger.frameInfo.offset):
        return i + 1

  return NO_OFFSET

proc colorLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  var tabInfo = self.tabInfo

  case self.editorView:
  of ViewSource, ViewTargetSource:
    var debuggerLine = NO_LINE
    var debuggerPath = cstring""
    if self.editorView == ViewSource:
      debuggerLine = self.data.services.debugger.location.line
      debuggerPath = self.data.services.debugger.location.path
    else:
      debuggerLine = self.data.services.debugger.cLocation.line
      debuggerPath = self.data.services.debugger.cLocation.path

    if debuggerLine != NO_LINE and debuggerPath == tabInfo.name:
      let line = if not self.data.services.debugger.location.isExpanded:
        debuggerLine
      else:
        self.data.services.debugger.location.line - self.data.services.debugger.location.expansionFirstLine + 1 # e.g. 2 - 1 + 1 -> 2. 2 - 2 + 1 -> 1
      lines.add(MonacoLineStyle(line: line, class: cstring(fmt"on on-{line}")))

  of ViewInstructions:
    cdebug "editor: asmName " & self.data.services.debugger.location.asmName
    cdebug "editor: instructions name " & self.name
    if self.data.trace.lang in {LangC, LangCpp, LangRust, LangGo} and self.data.services.debugger.location.asmName == self.name or
       self.data.trace.lang == LangNim and self.data.services.debugger.cLocation.asmName == self.name:
      var position = self.position()
      if position != NO_POSITION:
        lines.add(MonacoLineStyle(line: position, class: cstring(fmt"on on-{position}")))

  of ViewCalltrace:
      let currentLocation = self.data.services.debugger.location
      let currentLocationName = currentLocation.path & cstring":" & currentLocation.functionName & cstring"-" & currentLocation.key
      if currentLocationName == self.name:
        if currentLocation.line != NO_LINE and currentLocation.line in currentLocation.functionFirst .. currentLocation.functionLast:
          lines.add(MonacoLineStyle(line: currentLocation.line - currentLocation.functionFirst + 1, class: cstring"on"))

  else:
    discard

  if tabInfo.highlightLine != NO_LINE:
    lines.add(MonacoLineStyle(line: tabInfo.highlightLine, class: cstring"highlight"))
    self.monacoEditor.revealLineInCenterIfOutsideViewport(tabInfo.highlightLine)

  lines

proc isLineStyleSet(conditionFlowLines: seq[MonacoLineStyle], position: int): bool =
  MonacoLineStyle(line: position, inlineClass: cstring"line-flow-hit") notin conditionFlowLines

proc flowStyleLines(self: EditorViewComponent, conditionFlowLines: seq[MonacoLineStyle]): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  var flow = self.flow

  if not flow.isNil and not flow.flow.isNil and not self.flowUpdate.isNil:
    # The per-line decision lives in `ui/flow_line_styles.nim` so it can be
    # unit-tested headlessly, and so the guard it carries is shared with every
    # other reader of `branchesTaken`. Before RV-5 this loop indexed
    # `branchesTaken[0][0]` with no bounds check — a latent `IndexDefect` that
    # aborted the whole of `applyEventualStylesLines`.
    for styled in flowStyledLines(flow.flow, self.flowUpdate.finished):
      if isLineStyleSet(conditionFlowLines, styled.position):
        lines.add(MonacoLineStyle(
          line: styled.position,
          inlineClass: cstring(flowLineStyleClass(styled.kind))))

  lines

proc reviewFileForTab(self: EditorViewComponent): DeepReviewFileData =
  ## The review dataset's entry for the file THIS editor tab shows, or nil.
  ##
  ## The single place either full-file overlay decides "is this my file?", so
  ## §5.1's diff highlights and §5.3's flow overlay cannot disagree about it —
  ## and they did: both used to spell the question `file.path == self.path`,
  ## with the dataset's repo-relative `src/main.nr` on the left and the tab's
  ## path on the right.  When the two differed at all the answer was always
  ## "no", so Full Files mode drew zero decorations of either kind; measured
  ## over the book's own worked example it was 0 added, 0 modified, and the
  ## diff tab's 8 flow lines and 36 value chips unchanged by opening the file.
  ##
  ## The rule itself lives in `common/review_source_paths` because the index
  ## process asks the same question when it serves the tab's text, and a
  ## second implementation of it would be a second chance to get it wrong.
  result = nil
  if not self.data.deepReviewActive or self.data.deepReviewData.isNil:
    return
  var paths: seq[string] = @[]
  for file in self.data.deepReviewData.files:
    paths.add($file.path)
  let index = reviewFileIndexForPath(paths, $self.path)
  if index >= 0:
    result = self.data.deepReviewData.files[index]

proc reviewFlowStyleLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  ## The review's Omniscience overlay on a full-file editor tab
  ## (DeepReview-GUI.md §5.3: "The same Omniscience data from the associated
  ## traces is overlaid on the file in its normal form […] Use the standard
  ## Omniscience appearance").
  ##
  ## A review launched over an exported dataset loads no recording, so no
  ## `FlowComponent` is ever created for this tab and `flowStyleLines` above has
  ## nothing to work from. The overlay's input is the dataset (§7), so the
  ## dataset is adapted into a `FlowUpdate` here and handed to the *same*
  ## `flowStyledLines` — the classes, the guard and the hit/skip/unknown
  ## decision are one implementation, not two.
  ##
  ## Which invocation is displayed is the reviewer's choice, made with the
  ## in-editor selector the diff tab renders (`ui/unified_diff.nim`); this tab
  ## follows the same per-file, per-function ordinals so both surfaces of one
  ## review agree about which call they are showing.
  ##
  ## The **inline values** §4.4 names come with the classes: each captured
  ## variable becomes one name chip and one value box, injected after the line's
  ## own text with the debugger's own flow chip classes. Never a text comment —
  ## `afterContent` carries the value, and `afterClass` the standard classes.
  result = @[]
  if self.editorView != ViewSource:
    return
  let file = self.reviewFileForTab()
  if not file.isNil:
    let path = $file.path
    let functions = reviewFunctionInvocations(file)
    for fn in functions:
      let ordinal = reviewInvocationOrdinal(path, fn.functionKey)
      let invocation =
        reviewInvocationIndex(functions, fn.functionKey, ordinal)
      # A function the changeset only *calls* has a `callCount` and no flow
      # (RV-4 gap 8): it is skipped rather than annotated with somebody else's
      # execution.
      if invocation == NoInvocation:
        continue
      let plan = reviewFlowPlan(file, invocation)
      if not plan.found:
        continue
      var update = FlowUpdate()
      # The file-taking overload: it carries the structured values the
      # materialized collector writes (UD-3) into the `FlowUpdate`, so both of
      # a review's surfaces hold the recorder's own `Value`s rather than a
      # synthesis from a rendering.
      fillFlowUpdate(file, plan, update, ViewSource)
      let view = update.viewUpdates[ViewSource]
      # The loop iteration the reader picked with the diff tab's loop control,
      # for every loop this invocation entered — so a line inside a loop shows
      # the pass the reader asked for on both surfaces of the review.
      var iterations: seq[(int, int)] = @[]
      for loopIndex in 1 ..< plan.loops.len:
        iterations.add(
          (loopIndex, reviewLoopIteration(path, fn.functionKey, loopIndex)))
      for styled in flowStyledLines(view, update.finished):
        result.add(MonacoLineStyle(
          line: styled.position,
          inlineClass: cstring(flowLineStyleClass(styled.kind))))
      # §4.4's inline values. Walked over the function's own span rather than
      # over `flowStyledLines`, which starts at `functionFirst + 1` because the
      # declaration line cannot be *skipped* — it can still have captured a
      # parameter, and `format_output`'s `input` is exactly that case. The model
      # line IS the source line here (this tab shows the whole file), so no
      # mapping is needed, unlike the diff tab's synthetic document.
      for position in plan.functionFirst .. plan.functionLast:
        let stepIndex = plan.stepAtLine(position, iterations)
        if stepIndex < 0:
          continue
        for chip in reviewValueChips(plan.steps[stepIndex]):
          result.add(MonacoLineStyle(
            line: position,
            afterContent: cstring(" " & reviewValueChipName(chip)),
            afterClass: cstring(ReviewInlineValueNameClass)))
          result.add(MonacoLineStyle(
            line: position,
            afterContent: cstring(chip.text),
            afterClass: cstring(ReviewInlineValueBoxClass)))

proc conditionToLine(self: EditorViewComponent, loopId: int, loopIteration: int): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  var flow = self.flow

  if not flow.isNil and not flow.flow.isNil and
     loopId >= 0 and loopId < flow.flow.branchesTaken.len and
     loopIteration >= 0 and loopIteration < flow.flow.branchesTaken[loopId].len:
    let branchTable = flow.flow.branchesTaken[loopId][loopIteration].table
    if not branchTable.isNil:
      for position, typ in branchTable:
        if (position >= flow.flow.location.functionFirst and position <= flow.flow.location.functionLast) or
          (flow.flow.location.functionFirst == -1 and flow.flow.location.functionLast == -1):
          case typ:
          of Taken:
            lines.add(MonacoLineStyle(line: position, class: cstring"flow-taken"))
            if position in flow.flow.relevantStepCount:
              lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-hit"))
            else:
              lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-skip"))

          of NotTaken:
            lines.add(MonacoLineStyle(line: position, class: cstring"flow-not-taken"))
            if position notin flow.flow.relevantStepCount:
              lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-skip"))
            else:
              lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-hit"))

          of Unknown:
            lines.add(MonacoLineStyle(line: position, class: cstring"flow-not-taken"))
            lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-skip"))

  lines

proc conditionStyleLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  let currentPosition = self.data.services.debugger.location.highLevelLine
  let currentRRTicks = self.data.services.debugger.location.rrTicks
  let flow = self.flow
  var lines: seq[MonacoLineStyle] = @[]

  if not flow.isNil and not flow.flow.isNil and
     flow.flow.branchesTaken.len > 0 and
     flow.flow.branchesTaken[0].len > 0 and
     not flow.flow.branchesTaken[0][0].table.isNil:
    # conditions outside of loops:
    lines.add(self.conditionToLine(0, 0))
    var currentStepCount = self.flow.getCurrentStepCount(currentPosition)

    # conditions inside of loops:
    if currentStepCount != NO_STEP_COUNT:
      for flowLoop in flow.flowLoops:
        var currentLoopStep = flowLoop.loopStep
        if currentLoopStep.loop >= 0 and currentLoopStep.loop < flow.flow.loops.len:
          var loop = flow.flow.loops[currentLoopStep.loop]
          var closestStep = self.flow.getClosestIterationStepCount(loop, currentLoopStep.stepCount)
          if closestStep >= 0 and closestStep < flow.flow.steps.len:
            var step = flow.flow.steps[closestStep]
            lines.add(self.conditionToLine(step.loop, step.iteration))

  lines

proc diffStyleLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  for file in self.data.startOptions.diff.files:
    if file.currentPath == self.path:
      for chunk in file.chunks:
        for diffLine in chunk.lines:
          case diffLine.kind:
          of DiffLineKind.NonChanged:
            discard
          of DiffLineKind.Deleted:
            discard
          of DiffLineKind.Added:
            lines.add(MonacoLineStyle(line: diffLine.currentLineNumber, class: cstring"diff-added"))

  lines

proc deepReviewDiffStyleLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  ## Build diff decoration lines from DeepReview data for the current file.
  ## When DeepReview mode is active, this checks the review data for diff
  ## hunks matching the editor's file path and produces line styles:
  ##   - Added lines in pure-addition hunks: green border (``line-diff-added``)
  ##   - Added lines in mixed hunks (modification): yellow border (``line-diff-modified``)
  ## Removed lines are not decorated since they have no position in the new file.
  var lines: seq[MonacoLineStyle] = @[]
  let file = self.reviewFileForTab()
  if file.isNil or file.diff.isNil:
    return lines

  for hunk in file.diff.hunks:
    # Determine if hunk has both removals and additions (= modification).
    var hasRemoved = false
    var hasAdded = false
    for line in hunk.lines:
      let lt = $line.`type`
      if lt == "removed":
        hasRemoved = true
      elif lt == "added":
        hasAdded = true

    let isModification = hasRemoved and hasAdded

    for line in hunk.lines:
      let lt = $line.`type`
      if lt != "added":
        continue
      if line.newLine < 1:
        continue
      let className = if isModification:
        cstring"line-diff-modified"
      else:
        cstring"line-diff-added"
      lines.add(MonacoLineStyle(line: line.newLine, class: className))
  lines

proc originHopStyleLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  ## Value Origin Tracking (M4) — co-exist with omniscience-flow
  ## decorations via distinct CSS classes (`ct-origin-hop-gutter` /
  ## `ct-origin-hop-line`) per spec §8.1. The gutter is wide enough
  ## to render both a flow glyph and an origin glyph side-by-side, so
  ## the two layers do not overwrite each other.
  ##
  ## The chain's per-hop locations are read from the shared
  ## `OriginChainVM.activeChain` signal via the host bridge stored on
  ## the editor view component. Until the bridge is installed (e.g.
  ## in standalone unit tests of the editor view) the proc returns an
  ## empty seq so the existing flow / condition / diff layers remain
  ## untouched.
  result = @[]
  if self.activeOriginHopLines.len == 0:
    return
  let tabPath = self.tabInfo.location.path
  for hopLine in self.activeOriginHopLines:
    if hopLine.path == tabPath and hopLine.line > 0:
      result.add(MonacoLineStyle(line: hopLine.line,
                                 class: cstring"ct-origin-hop-gutter",
                                 inlineClass: cstring"ct-origin-hop-line"))

proc applyEventualStylesLines*(self: EditorViewComponent) =
  ## Recompute and re-apply every Monaco line decoration this editor owns.
  ##
  ## Exported (#594) because it is the ONLY producer of the ``flow-taken`` /
  ## ``flow-not-taken`` conditional-branch styles, and the two moments at which
  ## flow data actually becomes paintable — the ``ct/updated-flow`` event and
  ## tab (re)activation — live outside this proc's original call sites.
  if self.monacoEditor.isNil:
    return

  let colorLineList = self.colorLines()
  let conditionFlowLines = self.conditionStyleLines()
  # var diffLineList = self.diffStyleLines()
  let flowLineList = self.flowStyleLines(conditionFlowLines)
  let deepReviewDiffLines = self.deepReviewDiffStyleLines()
  let originHopLines = self.originHopStyleLines()

  # Layer split, see `styleLines` / `ui/editor_decoration_layers.nim`:
  # everything derived from `self.flow.flow` goes into the flow layer, which is
  # retained rather than wiped while a flow reload is in flight.
  # §5.3 — a review's flow comes from the dataset, so it is available whenever
  # the review is, with no `FlowComponent` and no recording behind it. It joins
  # the flow layer because it *is* flow: the layer-retention rule of #594 must
  # apply to it identically.
  let reviewFlowLines = self.reviewFlowStyleLines()
  let baseLines = concat(colorLineList, concat(deepReviewDiffLines, originHopLines))
  let flowLines = concat(concat(flowLineList, reviewFlowLines), conditionFlowLines)
  let flowDataAvailable =
    (not self.flow.isNil and not self.flow.flow.isNil) or
    reviewFlowLines.len > 0

  self.styleLines(self.monacoEditor, baseLines, flowLines, flowDataAvailable)

proc statusWidgetDom(self: FlowComponent, line: int): Node =
  var dom = cast[Node](document.createElement(cstring"div"))
  var target = cast[Node](document.createElement(cstring"div"))
  dom.appendChild(target)
  let id = cstring(&"flow-status-widget-{line}")
  target.id = id
  cast[Element](target).classList.add(cstring"flow-status-widget")
  self.statusDom = dom
  return dom

proc ensureStatusWidget(self: FlowComponent, line: int) =
  var add = false

  if self.statusWidget.isNil:
    add = true
  elif cast[int](self.statusWidget.getPosition().position.lineNumber) != line:
    self.editorUI.monacoEditor.removeContentWidget(self.statusWidget)
    self.statusWidget = nil
    add = true
  else:
    add = false

  if add:
    let dom = self.statusWidgetDom(line)
    self.statusWidget = self.addContentWidget(dom, line, self.maxFlowLineWidth, &"flow-status-widget-{line}", isStatusWidget = true)

const flowStatusTexts: array[FlowUpdateStateKind, string] = [
  "not loading",
  "waiting for start ..",
  "loading ...",
  "finished"
];

func flowStatusText(status: FlowUpdateState): string =
  result = flowStatusTexts[status.kind]
  if status.kind == FlowLoading:
    result = result & " " & $status.steps

proc redrawFlowInfo(self: FlowComponent, centerLine: int, loadingLine: int) =
  let line = if self.status.kind == FlowWaitingForStart: centerLine else: loadingLine
  self.ensureStatusWidget(line)

  let text = flowStatusText(self.status)
  self.statusWidget.domNode.childNodes[0].innerText = cstring(text)

proc redrawFlow(self: EditorViewComponent) =
  var tabInfo = self.tabInfo

  if self.flow.tab.isNil:
    self.flow.tab = tabInfo
    if self.flow.tab.isNil:
      cerror fmt"flow: tab in service is still nil {self.path}"
      return

  try:
    if self.flow.maxFlowLineWidth == 0:
      let minimapLeft = self.flow.editorUI.monacoEditor
        .getOption(LAYOUT_INFO).minimap.minimapLeft
      let editorContentLeft = self.flow.editorUI.monacoEditor
        .getOption(LAYOUT_INFO).contentLeft

      self.flow.maxFlowLineWidth = self.flow.calculateMaxFlowLineWidth()
      self.flow.flowViewWidth = minimapLeft - self.flow.maxFlowLineWidth
  except:
    cerror "flow: max flow line width " & getCurrentExceptionMsg()

  if self.flow.flow.isNil:
    return

proc applyOriginChainHopLines*(self: EditorViewComponent, chain: JsObject) =
  ## Value Origin Tracking (M4) — populate `self.activeOriginHopLines`
  ## from the decoded `ct/updated-origin-chain` event body so the
  ## existing `originHopStyleLines` proc emits Monaco decorations on
  ## the hop lines.  The wire body matches the typed
  ## `OriginChain` JSON shape (spec §4.1); we walk `hops[i].location`
  ## fields directly because the editor only needs `(path, line, stepId)`.
  ##
  ## Coexists with the omniscience-flow / condition / diff decoration
  ## layers — `applyEventualStylesLines` concatenates all four lists
  ## with distinct CSS classes per spec §8.1.
  self.activeOriginHopLines = @[]
  if chain.isNil:
    return
  let hops = chain[cstring"hops"]
  if hops.isNil or hops.isUndefined:
    return
  let length = cast[int](hops.length)
  for i in 0 ..< length:
    let hop = hops[i]
    if hop.isNil or hop.isUndefined:
      continue
    let loc = hop[cstring"location"]
    if loc.isNil or loc.isUndefined:
      continue
    let path = cast[cstring](loc[cstring"path"])
    let line = cast[int](loc[cstring"line"])
    let stepId =
      if hop[cstring"stepId"].isNil or hop[cstring"stepId"].isUndefined: 0'i64
      else: cast[int64](hop[cstring"stepId"])
    if path.isNil or path.len == 0 or line <= 0:
      continue
    self.activeOriginHopLines.add(
      OriginHopLineRef(path: path, line: line, stepId: stepId))
  # Re-apply the Monaco line styles so the new hop decorations land in
  # the editor — same trigger the flow / diff layers use after they
  # update their own state.
  if not self.monacoEditor.isNil:
    self.applyEventualStylesLines()

method register*(self: EditorViewComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtUpdatedFlow, proc(kind: CtEventKind, response: FlowUpdate, sub: Subscriber) =
    discard self.onUpdatedFlow(response)
  )
  # Value Origin Tracking (M4) — keep the editor's `activeOriginHopLines`
  # in sync with the active chain so `originHopStyleLines` returns
  # non-empty when a chain is live (spec §8.1 editor decorations).
  api.subscribe(CtUpdatedOriginChain, proc(kind: CtEventKind, response: JsObject, sub: Subscriber) =
    self.applyOriginChainHopLines(response)
  )
  api.emit(InternalLastCompleteMove, EmptyArg())
  self.scheduleInitialFlowLoad()

proc registerEditorViewComponent*(component: EditorViewComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

proc sourceLineJump(self: EditorViewComponent, path: cstring, line: int, behaviour: JumpBehaviour) =
  self.api.emit(
    CtSourceLineJump,
    SourceLineJumpTarget(
      path: path,
      line: line,
      behaviour: behaviour,
    )
  )
  self.api.emit(
    InternalNewOperation,
    NewOperation(
      name: fmt"Source line jump - {line}",
      stableBusy: true,
    )
  )

proc sourceCallJump(self: EditorViewComponent, path: cstring, line: int, targetToken: cstring, behaviour: JumpBehaviour) =
  self.api.emit(
    CtSourceCallJump,
    SourceCallJumpTarget(
      path: path,
      line: line,
      token: targetToken,
      behaviour: behaviour,
    )
  )
  self.api.emit(
    InternalNewOperation,
    NewOperation(
      name: fmt"Source call jump - {targetToken}",
      stableBusy: true,
    )
  )

proc editorLineJump(self: EditorViewComponent, line: int, behaviour: JumpBehaviour) =
  if self.editorView == ViewTargetSource and self.data.trace.lang == LangNim:
    # For ViewTargetSource (C code view), use the sourcemap to find the
    # corresponding Nim line and highlight it in the Nim source editor.
    let sm = self.data.sourcemap
    if not sm.isNil and sm.loaded and sm.cToNim.hasKey(self.name):
      let cLineMap = sm.cToNim[self.name]
      if cLineMap.hasKey(line):
        let nimMapping = cLineMap[line]
        let nimPathID = nimMapping[0]
        let nimLine = nimMapping[1]
        if sm.nimSources.hasKey(nimPathID):
          let nimPath = sm.nimSources[nimPathID]
          # Highlight the corresponding Nim line in the source view
          highlightLine(nimPath, nimLine)
          return
    # Fall through to normal line jump if no mapping found
    self.sourceLineJump(self.name, line, behaviour)
  elif self.tabInfo.lang != LangAsm:
    self.sourceLineJump(self.name, line, behaviour)
  elif 0 <= line - 1 and line - 1 <= self.tabInfo.instructions.instructions.len():
    self.sourceLineJump(self.name, self.tabInfo.instructions.instructions[line-1].highLevelLine, behaviour)

type
  AmbiguousFunctionCallException = object of ValueError

proc getTokenFromPosition(self: EditorViewComponent, position: js): cstring =
  try:
    let model = self.monacoEditor.toJs.getModel()
    let currentWord = model.getWordAtPosition(position)

    if currentWord.isNil:
      return cstring""

    result = if not currentWord.word.isNil: cast[cstring](currentWord.word) else: cstring""

    let lang = fromPath(self.data.services.debugger.location.path)

    if lang == LangRust:
      let xidRegex = newRegExp(r"^\w$")
      let lineNumber = cast[int](position.lineNumber)
      let lineContent = $cast[cstring](model.getLineContent(lineNumber))
      var startColumn = cast[int](currentWord.startColumn) - 1
      var endColumn = cast[int](currentWord.endColumn) - 2

      while startColumn > 0 and (lineContent[startColumn - 1] == ':' or cstring($lineContent[startColumn - 1]).contains(xidRegex)):
        startColumn -= 1

      while endColumn < lineContent.len - 1 and (lineContent[endColumn + 1] == ':' or cstring($lineContent[endColumn + 1]).contains(xidRegex)):
        endColumn += 1

      result = lineContent[startColumn..endColumn]
      if lineContent.count($result) != 1:
        raise newException(AmbiguousFunctionCallException, &"Multiple calls of '{result}' on line {lineNumber}.")
  except AmbiguousFunctionCallException:
    raise
  except:
    cerror getCurrentExceptionMsg()
    result = ""


proc runTest(self: EditorViewComponent, testName: cstring, path: cstring, line: int, column: int) =
  let options = RunTestOptions(
    testName: testName,
    path: path,
    line: line,
    column: column,
    newWindow: false,
  )
  self.data.runTests(options)

# Fill contextMenu with ContextMenuItem variables and return it to be used in the context menu
proc createContextMenuItems(self: EditorViewComponent, ev: js): seq[ContextMenuItem] =
  # Editor context menu items
  var callLine:                   ContextMenuItem
  var callLineForward:            ContextMenuItem
  var callLineBackward:           ContextMenuItem
  var toggleBreakpoint:           ContextMenuItem
  var toggleBreakpointState:      ContextMenuItem
  var deleteBreakpoints:          ContextMenuItem
  var deleteAllBreakpoints:       ContextMenuItem
  var toggleBreakpoints:          ContextMenuItem
  var addDeleteTracepoint:        ContextMenuItem
  var toggleTracepoint:           ContextMenuItem
  var targetToken:                cstring
  var listLine:                   seq[int]
  var contextMenu:                seq[ContextMenuItem]

  # Trace context menu items
  var addToScratchpad:     ContextMenuItem
  var expandTraceValue:    ContextMenuItem

  var tabInfo = self.tabInfo

  if ev.isNil or ev.target.isNil or ev.target.position.isNil:
    return contextMenu

  var line = cast[int](ev.target.position.lineNumber)
  let path = tabInfo.name

  var isDetailNil = ev.target.detail.isNil or ev.target.detail.isUndefined
  var isAfterLineNil = true
  if not isDetailNil:
    isAfterLineNil = ev.target.detail.afterLineNumber.isNil

  if isDetailNil or isAfterLineNil:
    # Source Line Jump Menu Item
    let sourceLine = ContextMenuItem(
      name: "Jump to line",
      hint: "&lt;Middle click on line&gt;, CTRL+&lt;click on line&gt;",
      handler: proc(e: Event) =
        self.editorLineJump(line, SmartJump)
    )
    let sourceLineForward = ContextMenuItem(
      name: "Jump forward to line",
      hint: "",
      handler: proc(e: Event) =
        self.editorLineJump(line, ForwardJump)
    )
    let sourceLineBackward = ContextMenuItem(
      name: "Jump backward to line",
      hint: "",
      handler: proc(e: Event) =
        self.editorLineJump(line, BackwardJump)
    )
    contextMenu &= sourceLine
    contextMenu &= sourceLineForward
    contextMenu &= sourceLineBackward

    try:
      targetToken = self.getTokenFromPosition(ev.target.position)
      # copied/adapted from getTokenFromPosition
      let model = self.monacoEditor.toJs.getModel()
      let lineContent = $cast[cstring](model.getLineContent(line))
      if lineContent.strip == "#[test]":
        # for now trying to guess where the function name for rust is
        # e.g.
        # ```
        # #[test]
        # fn test_1() {
        # ..
        # }
        let column = 1
        let path = self.name
        let testName = self.getLineFunctionName(line + 1)
        clog cstring"test name: " & testName
        let runTest = ContextMenuItem(
          name: "Re-record and replay this test",
          hint: "try to rebuild/re-record and replay this test",
          handler: proc(e: Event) =
            self.runTest(testName, path, line, column)
        )
        contextMenu &= runTest
      # Call Line Jump Menu Item
      if targetToken != "":
        callLine = ContextMenuItem(
          name: "Jump to call",
          hint: "CTRL+ALT+&lt;click function name&gt;",
          handler: proc(e: Event) =
            self.sourceCallJump(self.name, line, targetToken, SmartJump)
        )
        callLineForward = ContextMenuItem(
          name: "Jump forward to call",
          hint: "",
          handler: proc(e: Event) =
            self.sourceCallJump(self.name, line, targetToken, ForwardJump)
        )
        callLineBackward = ContextMenuItem(
          name: "Jump backward to call",
          hint: "",
          handler: proc(e: Event) =
            self.sourceCallJump(self.name, line, targetToken, BackwardJump)
        )
      else:
        let handler = proc(e: Event) = self.api.errorMessage("No word selected.")

        callLine = ContextMenuItem(
          name: "Jump to call",
          hint: "CTRL+ALT+&lt;click function name&gt;",
          handler: handler
        )
        callLineForward = ContextMenuItem(
          name: "Jump forward to call",
          hint: "", handler: handler)
        callLineBackward = ContextMenuItem(
          name: "Jump backward to call",
          hint: "",
          handler: handler
        )
    except AmbiguousFunctionCallException:
      let msg = getCurrentExceptionMsg()
      let handler = proc(e: Event) = self.api.errorMessage msg

      callLine = ContextMenuItem(
        name: "Jump to call",
        hint: "CTRL+ALT+&lt;click function name&gt;",
        handler: handler
      )
      callLineForward = ContextMenuItem(
        name: "Jump forward to call",
        hint: "",
        handler: handler
      )
      callLineBackward = ContextMenuItem(
        name: "Jump backward to call",
        hint: "",
        handler: handler
      )

    contextMenu &= callLine
    contextMenu &= callLineForward
    contextMenu &= callLineBackward

    # Delete/Add Breakpoint Menu Item
    if data.services.debugger.hasBreakpoint(path, line):
      toggleBreakpoint = ContextMenuItem(
        name: "Delete breakpoint",
        hint: "&lt;click on the red dot&gt;",
        handler: proc(e: Event) =
          self.data.services.debugger.deleteBreakpoint(path, line)
          self.refreshEditorLine(line)
      )
      # Enable/Disable Breakpoint
      if data.services.debugger.isEnabled(path, line):
        toggleBreakpointState = ContextMenuItem(
          name: "Disable breakpoint",
          hint: "",
          handler: proc(e: Event) =
            data.services.debugger.disable(path, line)
            self.refreshEditorLine(line)
        )
      else:
        toggleBreakpointState = ContextMenuItem(
          name: "Enable breakpoint",
          hint: "",
          handler: proc(e: Event) =
            data.services.debugger.enable(path, line)
            self.refreshEditorLine(line)
        )

      contextMenu &= toggleBreakpointState

    # Add/Delete Breakpoint Menu Item
    else:
      toggleBreakpoint = ContextMenuItem(
        name: "Add breakpoint",
        hint: "&lt;click line number gutter&gt;",
        handler: proc(e: Event) =
          data.services.debugger.addBreakpoint(path, line)
          self.refreshEditorLine(line)
      )

    contextMenu &= toggleBreakpoint

    # Delete Breakpoints in file
    if data.pointList.breakpoints.len > 0:
      deleteBreakpoints = ContextMenuItem(
        name: "Delete breakpoints in file",
        hint: "",
        handler: proc(e: Event) =
          let breakpointsCopy = data.pointList.breakpoints
          for i, b in breakpointsCopy:
            data.services.debugger.deleteBreakpoint(path, b.line)
            self.refreshEditorLine(b.line)
            data.pointList.breakpoints.delete(i, i)
      )

      contextMenu &= deleteBreakpoints

    # Delete ALL Breakpoints in project
    if data.pointList.breakpoints.len > 0:
      deleteAllBreakpoints = ContextMenuItem(
        name: "Delete ALL breakpoints",
        hint: "",
        handler: proc(e: Event) =
          data.services.debugger.deleteAllBreakpoints(self)
          data.pointList.breakpoints = @[]
      )

      contextMenu &= deleteAllBreakpoints

    # Delete/Add tracepoint field
    if not self.traces[line].isNil:
      addDeleteTracepoint = ContextMenuItem(
        name: "Delete tracepoint",
        hint: "",
        handler: proc (e: Event) =
          self.traces[line].closeTrace()
      )

      # Enable/Disable tracepoint
      if self.traces[line].isDisabled:
        toggleTracepoint = ContextMenuItem(
          name: "Enable tracepoint",
          hint: "",
          handler: proc(e: Event) =
            self.toggleTrace(path, line)
            self.traces[line].toggleTraceState()
        )
      else:
        toggleTracepoint = ContextMenuItem(
          name: "Disable tracepoint",
          hint: "",
          handler: proc(e: Event) =
            self.traces[line].toggleTraceState()
            self.toggleTrace(path, line)
        )

      contextMenu &= toggleTracepoint

    # Add/Delete tracepoint field
    else:
      addDeleteTracepoint = ContextMenuItem(
        name: "Add tracepoint",
        hint: "Enter&lt;on line&gt;",
        handler: proc(e: Event) =
          self.toggleTrace(self.name, line)
      )

    contextMenu &= addDeleteTracepoint

    # Add expression to Scratchpad
    let key = &"{self.path}:{self.lastMouseMoveLine}"

    if not data.services.debugger.expressionMap.isNil and data.services.debugger.expressionMap.hasKey(key):
      for item in data.services.debugger.expressionMap[key]:
        let startCol = cast[int](item.startCol)
        var endCol = cast[int](item.endCol)
        var expression: cstring
        case item.kind:
        of TkField:
          expression = item.base

        of TkIndex:
          expression = item.collection
          endCol -= 2

        else:
          expression = item.expression

        if startCol <= self.lastMouseClickCol and self.lastMouseClickCol <= endCol:
          for local in data.services.debugger.locals:
            if local.expression == expression:
              let baseValue = local.value
              addToScratchpad = ContextMenuItem(name: "Add value to scratchpad", hint: "", handler: proc(e: Event) =
                self.api.openValueInScratchpad(ValueWithExpression(expression: expression, value: baseValue))
                self.data.redraw())
              contextMenu &= addToScratchpad
          break
  else:
    let className = cast[cstring](ev.target.element.className)
    if not ($className).startsWith("flow"):
      var datatable: js

      try:
        datatable = self.traces[line].dataTable.context
      except:
        line -= 1
        datatable = self.traces[line].dataTable.context

      # Check how many values the trace datatable has
      # and generate the context menu based on that information
      try:
        let target = ev.target.element.findTRNode()
        let dataTableRow = datatable.row(target)
        let traceValue = cast[Stop](datatableRow.data())
        if traceValue.locals.len > 1:
          for localValue in traceValue.locals:
            # Add values to scratchpad
            let tempValue = localValue
            capture tempValue:
              addToScratchpad = ContextMenuItem(
                name: &"Add {tempValue[0]} to scratchpad",
                hint: "",
                handler: proc(e: Event) =
                  self.api.openValueInScratchpad(
                    ValueWithExpression(
                      expression: tempValue[0],
                      value: tempValue[1]))
                  self.data.redraw()
              )

              contextMenu &= addToScratchpad

              # Expand values
              expandTraceValue = ContextMenuItem(
                name: &"Expand {tempValue[0]} value",
                hint: "",
                handler: proc(e: Event) =
                  self.traces[line].showExpandValue(tempValue, line)
                  self.data.redraw()
              )

              contextMenu &= expandTraceValue

          # Add all values to scratchpad
          contextMenu &= ContextMenuItem(
            name: "Add all values to scratchpad",
            hint: "",
            handler: proc(e: Event) =
              for localValue in traceValue.locals:
                self.api.openValueInScratchpad(
                  ValueWithExpression(
                    expression: localValue[0],
                    value: localValue[1]))
                self.data.redraw()
          )

        else:
          # Add value to scratchpad
          addToScratchpad = ContextMenuItem(
            name: "Add value to scratchpad",
            hint: "CTRL+&lt;click on value&gt;",
            handler: proc(e: Event) =
              self.api.openValueInScratchpad(
                ValueWithExpression(
                  expression: traceValue.locals[0][0],
                  value: traceValue.locals[0][1]))
              self.data.redraw()
          )

          contextMenu &= addToScratchpad

          # Expand value
          expandTraceValue = ContextMenuItem(
            name: "Expand value",
            hint: "",
            handler: proc(e: Event) =
              self.traces[line].showExpandValue(traceValue.locals[0], line)
              self.data.redraw()
          )

          contextMenu &= expandTraceValue

      except:
        discard

  # "Trace Macro Execution" action for Nim files (M11).
  # Available when the current file is a Nim source file and the cursor
  # is on a line that could contain a macro call.  Sends the LSP request
  # and opens the resulting .ct trace in a new session tab.
  if tabInfo.lang == LangNim:
    let traceLine = line
    let traceCol = cast[int](ev.target.position.column)
    let tracePath = self.path
    let traceData = self.data
    let traceMacroItem = ContextMenuItem(
      name: "Trace Macro Execution",
      hint: "",
      handler: proc(e: Event) =
        # Monaco positions are 1-based; LSP uses 0-based coordinates.
        discard traceExpandMacro(traceData, tracePath,
                                 traceLine - 1, traceCol - 1)
    )
    contextMenu &= traceMacroItem

    # "Trace Static Block Execution" action (CTFS-M-StaticBlockTrace).
    # Heuristic offer: surface the action when the right-clicked line —
    # or any of the few lines above it inside the current Nim view —
    # contains a ``static:`` / ``const`` / ``{.compileTime.}`` token.
    # The langserver itself does the authoritative check via nimsuggest's
    # ``tracestatic`` query (which matches at evalConstExprAux entry
    # points), so a false positive here just yields a user-visible
    # "not a static block" warning.
    #
    # TODO: replace the textual heuristic with a real AST / sym check
    # once nimsuggest exposes a position-classification query that
    # mirrors what `tracestatic` accepts.
    let model = self.monacoEditor.toJs.getModel()
    var showStaticAction = false
    if not model.isNil:
      # Walk upward from the cursor for a bounded number of lines.  The
      # langserver's `tracestatic` query is authoritative — a false
      # positive here just yields a user-visible "not a static block"
      # warning, so we err on the side of being permissive within the
      # scan window.
      let scanFrom = max(1, traceLine - 20)
      var scanned = 0
      for ln in countdown(traceLine, scanFrom):
        try:
          let raw = $cast[cstring](model.getLineContent(ln))
          let trimmed = raw.strip()
          # `static:` block opener (allow trailing comment).
          if trimmed.startsWith("static:"):
            showStaticAction = true
            break
          # `const` section / single-line const declaration.
          if trimmed == "const" or trimmed.startsWith("const ") or
             trimmed.startsWith("const\t") or trimmed.startsWith("const:"):
            showStaticAction = true
            break
          # `{.compileTime.}` pragma — usually on a proc/func signature.
          if "{.compileTime" in trimmed or "{. compileTime" in trimmed:
            showStaticAction = true
            break
          # `static(expr)` — single-token form, anywhere on the line.
          if "static(" in trimmed:
            showStaticAction = true
            break
          # Bail out once the scan crosses a clearly unrelated top-level
          # construct: an `import`/`type`/`proc`/etc. above us means we
          # are no longer inside a static: / const section.  Skip the
          # very first iteration (the right-clicked line itself) so the
          # action still appears when the user right-clicks directly on
          # a `proc {.compileTime.}` signature line.
          if scanned > 0 and trimmed.len > 0 and
             (trimmed.startsWith("proc ") or trimmed.startsWith("func ") or
              trimmed.startsWith("template ") or trimmed.startsWith("macro ") or
              trimmed.startsWith("method ") or trimmed.startsWith("iterator ") or
              trimmed.startsWith("converter ") or trimmed.startsWith("type ") or
              trimmed.startsWith("import ") or trimmed.startsWith("from ") or
              trimmed.startsWith("include ")):
            break
          inc scanned
        except:
          break

    if showStaticAction:
      let staticLine = traceLine
      let staticCol = traceCol
      let staticPath = tracePath
      let staticData = traceData
      let traceStaticItem = ContextMenuItem(
        name: "Trace Static Block Execution",
        hint: "",
        handler: proc(e: Event) =
          # Monaco positions are 1-based; LSP uses 0-based coordinates.
          discard traceStaticBlock(staticData, staticPath,
                                   staticLine - 1, staticCol - 1)
      )
      contextMenu &= traceStaticItem

  return contextMenu

proc getSourceLineDomIndex(self:EditorViewComponent, position: int): int =
  var result: int
  let editorId = self.id
  let overlayNodes = jq(&"#editorComponent-{editorId} .monaco-editor .view-overlays").children
  let marginOverlayNodes = jq(&"#editorComponent-{editorId} .monaco-editor .margin-view-overlays").children

  for index, overlayNode in marginOverlayNodes:
    let gutter = findNodeInElement(cast[Node](overlayNode),".gutter")
    let dataLine = cast[cstring](gutter.getAttribute("data-line"))

    if cast[int](dataLine) == position:
      result = index
      break

  return result

proc legacyValueViewZoneDom(self: EditorViewComponent, value: ValueComponent): Node =
  ## DOM entrypoint for inline Monaco value view zones.
  ##
  ## The value module owns the remaining value-tree DOM materialization.  Editor
  ## only supplies the legacy root-left style required by Monaco view zones.
  value.renderValueDomWithLeft(&"{self.currentTooltip[0] * 9}px")

proc addLegacyValueViewZone(self: EditorViewComponent, value: ValueComponent, line: int) =
  let viewZone = js{
    afterLineNumber: line,
    heightInPx: 0,
    domNode: self.legacyValueViewZoneDom(value)
  }

  self.monacoEditor.changeViewZones do (view: js):
    var zoneId = cast[int](view.addZone(viewZone))
    self.viewZones[line] = zoneId

proc renderValueView(self: EditorViewComponent, value: ValueComponent, line: int) =
  self.addLegacyValueViewZone(value, line)

proc customRedraw(self: ValueComponent) =
  let editor = data.ui.editors[data.services.debugger.location.path]
  var line = editor.lastMouseClickLine

  editor.clearViewZones()
  editor.addLegacyValueViewZone(self, line)

proc renderValueTooltip(self: EditorViewComponent) {.async.} =
  let key = &"{self.path}:{self.lastMouseClickLine}"

  self.currentTooltip = (0, 0, 0)

  if not data.services.debugger.expressionMap.isNil and data.services.debugger.expressionMap.hasKey(key):
    self.clearViewZones()
    if self.data.services.debugger.showInlineValues:
      for item in data.services.debugger.expressionMap[key]:
        let startCol = cast[int](item.startCol)
        var endCol = cast[int](item.endCol)
        var expression: cstring
        case item.kind:
        of TkField:
          expression = item.expression

        of TkIndex:
          expression = item.collection
          endCol -= 2

        else:
          expression = item.expression

        if startCol <= self.lastMouseClickCol and self.lastMouseClickCol <= endCol:
          var baseValue: Value

          for local in self.data.services.debugger.locals:
            if local.expression == expression:
              baseValue = local.value
              break

          if baseValue.isNil:
            baseValue = await self.data.services.debugger.evaluateExpression(self.data.services.debugger.location.rrTicks, item.expression)

          if not baseValue.isNil:
            let value = ValueComponent(
              expanded: JsAssoc[cstring, bool]{expression: false},
              charts: JsAssoc[cstring, ChartComponent]{},
              showInLine: JsAssoc[cstring, bool]{},
              baseExpression: expression,
              baseValue: baseValue,
              stateID: -1,
              nameWidth: VALUE_COMPONENT_NAME_WIDTH,
              valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
              data: data,
              customRedraw: customRedraw
            )
            self.currentTooltip = (startCol, endCol, self.lastMouseClickLine)
            if not self.viewZones.isNil:
              self.clearViewZones()
            self.renderValueView(value, self.lastMouseClickLine)
            break

  elif not self.monacoEditor.isNil:
    self.clearViewZones()

const DELAY: int64 = 400 # milliseconds

proc sourceOrCallJump(self: EditorViewComponent, position: js) =
  let currentTime: int64 = now()

  if currentTime - self.lastScrollFireTime <= DELAY:
    let targetToken = self.getTokenFromPosition(position)

    if targetToken != "":
      self.sourceCallJump(
        self.name,
        self.lastMouseMoveLine,
        targetToken,
        SmartJump
      )
    else:
      self.editorLineJump(self.lastMouseMoveLine, SmartJump)

  else:
    self.editorLineJump(self.lastMouseClickLine, SmartJump)

  self.lastScrollFireTime = currentTime

proc loadFlow*(self: EditorViewComponent, flowMode: FlowMode, location: types.Location) =
  # # possible to test/debug diff flow TEMP HACK:
  # if flowMode != FlowMode.Diff:
  #  return

  # Retire the component we are about to replace.
  #
  # A `FlowComponent` schedules deferred work on itself — `scheduleFlowRedraw`
  # and the five `scheduleActiveLoopIterationValueRender` timers — and those
  # closures keep the component alive long after this assignment drops the last
  # reference the editor holds. Without this flag the retired component's timer
  # fires ~100 ms into the new load, runs a full `redrawFlow()`, and re-creates
  # the Monaco view zones (and the loop-iteration control inside them) from the
  # location it was built for: the PREVIOUS debugger position.
  #
  # Two visible failures came out of that (#593, #595). The zombie zones are
  # tracked only in the retired component's `loopViewZones`, so the live
  # component's `clear()` cannot remove them and the editor ends up with two
  # loop controls; and the zombie's control shows the previous iteration, so the
  # next arrow click read that stale number, recomputed the same target it had
  # already jumped to, and the counter stopped advancing.
  #
  # It is deliberately a "stop painting" flag rather than a teardown: until the
  # replacement has rendered, the retired component's DOM is what the user sees
  # and clicks, and its `loopStates` carry the optimistic iteration
  # `selectLoopIteration` just wrote, which is exactly what a rapid second
  # click must read.
  let prevFlow = self.flow
  if not self.flow.isNil:
    self.flow.superseded = true

  self.flow = FlowComponent(
    handoffFlow: prevFlow,
    api: self.api,
    id: self.id,
    flow: nil,
    tab: self.tabInfo,
    location: location,
    multilineZones: JsAssoc[int, MultilineZone]{},
    flowDom: JsAssoc[int, Node]{},
    shouldRecalcFlow: false,
    flowLoops: JsAssoc[int, FlowLoop]{},
    flowLines: JsAssoc[int, FlowLine]{},
    activeStep: FlowStep(rrTicks: -1),
    selectedLine: -1,
    selectedLineInGroup: -1,
    selectedStepCount: -1,
    multilineValuesDoms: JsAssoc[int, JsAssoc[cstring, Node]]{},
    loopLineSteps: JsAssoc[int, int]{},
    inlineDecorations: JsAssoc[int, InlineDecorations]{},
    editorUI: self,
    scratchpadUI: if self.data.ui.componentMapping[Content.Scratchpad].len > 0: self.data.scratchpadComponent(0) else: nil,
    editor: self.service,
    service: self.data.services.flow,
    data: self.data,
    lineGroups: JsAssoc[int, Group]{},
    status: FlowUpdateState(kind: FlowWaitingForStart),
    statusWidget: nil,
    # `sliderWidgets` used to be initialised here.  Nothing ever wrote to it
    # (the only writer was an `isSliderWidget = true` argument to
    # `addContentWidget` that had no call site), so every reader — linked-slider
    # sync, slider cleanup and the slider resize pass — was an unconditional
    # no-op, and the guard it fed made `makeSlider` destroy and recreate the
    # loop slider on every step.  Removed with the #562 fix; see the notes in
    # `ui/flow.nim` for why reviving it with `flowLines` would not be
    # behaviour-preserving.
    lineWidgets: JsAssoc[int, js]{},
    multilineWidgets: JsAssoc[int, JsAssoc[cstring, js]]{},
    stepNodes: JsAssoc[int, kdom.Node]{},
    loopStates: JsAssoc[int, LoopState]{},
    viewZones: JsAssoc[int, int]{},
    loopViewZones: JsAssoc[int, int]{},
    loopColumnMinWidth: 15,
    shrinkedLoopColumnMinWidth: 8,
    pixelsPerSymbol: 8,
    distanceBetweenValues: 10,
    distanceToSource: 50,
    inlineValueWidth: 80,
    bufferMaxOffsetInPx: 300,
    maxWidth: 0,
    modalValueComponent: JsAssoc[cstring, ValueComponent]{},
    pendingRenderTimerId: -1
  )
  self.flow.valueMode = BeforeValueMode

  let taskId = genTaskId(LoadFlow)
  self.api.emit(CtLoadFlow, CtLoadFlowArguments(flowMode: flowMode, location: location))
  cdebug "start load-flow", taskId

proc createMonacoEditor*(selector: cstring, options: MonacoEditorOptions): MonacoEditor =
  result = monaco.editor.create(jq(selector), options)

proc updateMonacoGutterWidth(editor: MonacoEditor, fontSize: int) =
  let options = cast[MonacoEditorOptions](editor.getOptions())
  let lineCount = editor.getModel().getLineCount()
  options.lineNumbersMinChars = monacoLineNumbersMinChars(lineCount)
  options.lineDecorationsWidth = monacoLineDecorationsWidth(fontSize)
  editor.updateOptions(options)

proc drawDiffViewZones(self: EditorViewComponent, source: cstring, id: int, lineNumber: int): Node =
  var zoneDom = document.createElement("div")
  zoneDom.id = fmt"diff-view-zone-{self.id}-{id}"
  zoneDom.class = "diff-view-zone"
  zoneDom.style.display = "flex"
  zoneDom.style.fontSize = cstring($self.data.ui.fontSize) & cstring"px"

  var editorDom = document.createElement("div")
  var selector = fmt"diffEditorComponent-{self.id}-{id}"
  editorDom.id = selector

  let editorContentLeft = self.monacoEditor
    .getOption(LAYOUT_INFO).contentLeft + EDITOR_GUTTER_PADDING
  zoneDom.style.left = fmt"-{editorContentLeft}px"
  editorDom.style.height = "100%"

  zoneDom.appendChild(editorDom)

  var lang = fromPath(self.data.services.debugger.location.path)
  let theme = monacoThemeName(self.data.config.theme)
  if not self.diffEditors.hasKey(lineNumber):
    discard setTimeout(proc () =
      self.diffEditors[lineNumber] = createMonacoEditor(
        "#" & editorDom.id.cstring,
        MonacoEditorOptions(
          value: source,
          language: lang.toCLang(),
          readOnly: true,
          theme: theme,
          automaticLayout: true,
          folding: true,
          fontSize: self.data.ui.fontSize,
          fontFamily: codeFontFamily(self.data.ui),
          fontLigatures: true,
          minimap: js{ enabled: false },
          renderIndentGuides: true,
          find: js{ addExtraSpaceOnTop: false },
          renderLineHighlight: if self.editorView == ViewLowLevelCode: "none".cstring else: "".cstring,
          lineNumbers: proc(line: int): cstring = self.editorLineNumber(self.path, line, true, lineNumber),
          lineNumbersMinChars: monacoLineNumbersMinChars(lineCountForGutter(source)),
          lineDecorationsWidth: monacoLineDecorationsWidth(self.data.ui.fontSize),
          showFoldingControls: cstring"always",
          contextmenu: false,
          mouseWheelScrollSensitivity: 0,
          fastScrollSensitivity: 0,
          scrollBeyondLastLine: false,
          smoothScrolling: false,
          scrollbar: js{
            "vertical": "hidden",
            "horizontal": "hidden",
            "useShadows": false
          }
        )
      ),
      0
    )

  return zoneDom

proc clearDiffViewZones(self: EditorViewComponent) =
 for line, zone in self.diffViewZones:
    self.monacoEditor.changeViewZones do (view: js):
      view.removeZone(self.diffViewZones[line].zoneId)

proc addDiffView(self: EditorViewComponent, source: cstring, removedLinesNumber: int, startLineNumber: int, firstDeletedLineNumber: int) =
  var offset = 1 # Offset for proper line placement and number
  var newZoneDom = self.drawDiffViewZones(source, startLineNumber, firstDeletedLineNumber)
  let viewZone = js{
    afterLineNumber: if startLineNumber == 1: 0 else: startLineNumber,
    heightInLines: removedLinesNumber + offset,
    domNode: newZoneDom
  }
  self.monacoEditor.changeViewZones do (view: js):
    var zoneId = cast[int](view.addZone(viewZone))
    self.diffViewZones[startLineNumber] =
      MultilineZone(
        dom: newZoneDom,
        zoneId: zoneId,
        variables: JsAssoc[cstring, bool]{}
      )

proc removeLastChar(cs: cstring): cstring =
  var str = $cs
  if str.len > 0:
    str.setLen(str.len - 1)
  result = str.cstring

proc makeDiffViewZones(self: EditorViewComponent) =
  for file in self.data.startOptions.diff.files:
    if file.currentPath == self.path:
      for chunk in file.chunks:
        var isInDeleteChunk = false
        var removedLinesNumber = NO_LINE # Number for lines to be included
        var firstDeletedLineNumber = NO_LINE
        var startLineNumber = chunk.currentFrom # initial start line for the viewZones
        var source = "".cstring # Source code
        for diffLine in chunk.lines:
          case diffLine.kind:
          of DiffLineKind.Deleted:
            removedLinesNumber.inc()
            source = source & diffLine.text.toCString() & "\n".cstring
            if firstDeletedLineNumber == NO_LINE:
              firstDeletedLineNumber = diffLine.previousLineNumber
            isInDeleteChunk = true
          else:
            if diffLine.kind == DiffLineKind.Added and diffLine.currentLineNumber notin self.diffAddedLines:
              self.diffAddedLines.add(diffLine.currentLineNumber)
            if removedLinesNumber != NO_LINE:
              self.addDiffView(source.removeLastChar(), removedLinesNumber, startLineNumber, firstDeletedLineNumber)
              source = ""
              removedLinesNumber = NO_LINE
              firstDeletedLineNumber = NO_LINE
            else:
              startLineNumber = diffLine.currentLineNumber
            isInDeleteChunk = false
        if isInDeleteChunk:
          self.addDiffView(source, removedLinesNumber, startLineNumber, firstDeletedLineNumber)

proc addContentWidget*(
  self: EditorViewComponent,
  dom: Node,
  line: int,
  column: int,
  id: cstring,
  isStatusWidget: bool = false,
  isSliderWidget: bool = false
): JsObject =
  dom.class = "flow-content-widget"
  var editor = self.monacoEditor

  let widget = js{
    domNode: cast[Node](nil),
    getId: proc: cstring = id,
    getDomNode: (proc: Node =
      if cast[Node](jsthis.domNode).isNil:
        jsthis.domNode = dom
      cast[Node](jsthis.domNode)),
    getPosition: (proc: js =
      js{position: js{lineNumber: parseJSInt(line), column: column}, preference: cast[seq[MonacoContent]](@[EXACT])})
  }

  self.testLines[line].contentWidget = cast[Node](widget)

  editor.addContentWidget(widget)

  return widget

proc makeTestContainer(self: EditorViewComponent, line: int): Node =
  let textModel = self.monacoEditor.getModel()
  let lineContent = textModel.getLineContent(line)
  let editorConfiguration = self.monacoEditor.config
  let lineHeight = editorConfiguration.lineHeight

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(&"editor-test-container-{self.id}-{line}"))
  result.setAttribute(cstring"class", cstring"flow-loop-step-container")
  result.setAttribute(cstring"style", cstring(
    fmt"left: calc({lineContent.len()}ch + 2ch); " &
      fmt"font-size: {data.ui.fontSize - 2}px; " &
      fmt"line-height: {lineHeight - 2}px; " &
      fmt"height: {lineHeight - 2}px; " &
      fmt"background-size: {data.ui.fontSize}px;"))

proc makeTestLineContainer(self: EditorViewComponent, line: int) =
  var dom = cast[Node](document.createElement(cstring"div"))
  let id = cstring(&"ct-test-{self.id}-{line}")

  self.testDom[line] = dom

  discard self.addContentWidget(dom, line, 0, id)

proc ensureTestLineContainer(self: EditorViewComponent, line: int) =
  if not self.testDom.hasKey(line) and self.testLines[line].contentWidget.isNil:
    self.makeTestLineContainer(line)

proc getLineFunctionName(self: EditorViewComponent, line: int): cstring =
  let model = self.monacoEditor.getModel()
  let lineContent = $cast[cstring](model.getLineContent(line))

  let tokens = lineContent.split("fn ")
  var name = "".cstring
  if tokens.len() > 1:
    name = tokens[^1].split("(")[0]

  return name

proc getPythonTestFunctionName(self: EditorViewComponent, line: int): cstring =
  ## Extract Python test function name from a line containing def test_* or async def test_*
  let model = self.monacoEditor.getModel()
  let lineContent = $cast[cstring](model.getLineContent(line))
  let stripped = lineContent.strip()

  # Handle both "def test_*" and "async def test_*"
  var funcPart = ""
  if stripped.startsWith("def test_"):
    funcPart = stripped[4..^1]  # Skip "def "
  elif stripped.startsWith("async def test_"):
    funcPart = stripped[10..^1]  # Skip "async def "
  else:
    return "".cstring

  # Extract function name up to the opening paren
  let parenIdx = funcPart.find('(')
  if parenIdx > 0:
    return funcPart[0..<parenIdx].cstring
  return "".cstring

proc isPythonTestLine(lineContent: string): bool =
  ## Check if a line starts a Python test function (def test_* or async def test_*)
  let stripped = lineContent.strip()
  return stripped.startsWith("def test_") or stripped.startsWith("async def test_")

# ---------------------------------------------------------------------------
# The editor's Run-test control, and the three hooks a host fills in
#
# THIS CONTROL HUNG, and the hang was worse than the missing capability behind
# it: a button that accepts a click and then does nothing teaches a user the
# product is broken, where an absent one teaches nothing. Three separate faults
# produced it and all three are closed here.
#
#   1. THE CLICK WENT NOWHERE ON THE WEB. `runTest` sends
#      `CODETRACER::run-test`, which the Electron index answers and a browser
#      tab does not — `newWebIpc.send` finds no responder, logs "no host for",
#      and drops it. `editorTestRunHook` lets a host take the run instead, and
#      `ui_js` points it at the Noir wasm runner, which is the same one the
#      Test Results pane's ▶ uses.
#   2. THE SPINNER NEVER STOPPED. `loadAnimation` re-armed a 300 ms
#      `setTimeout` unconditionally and `activeTestId` was written in one place
#      and cleared in none, so the animation outlived every outcome — including
#      outcomes that arrived. It now stops when the button is no longer the
#      active one, and `settleEditorTestRun` is what makes it no longer active.
#   3. IT COULD SPIN FOREVER EVEN IF SOMETHING SETTLED IT WRONG. A cap is here
#      as well as the settle, because a control whose only exit is a callback
#      has one way to hang and a control with a deadline has none. Reaching the
#      cap SAYS SO rather than quietly reverting: a run that was abandoned and
#      a run that finished are different facts.
#
# The hooks are `var`s rather than a compile-time branch for the reason
# `noir_build_producer.onProblem` is one: this module is the editor, the runner
# lives behind the platform facade, and `ui_js` is the one place that can see
# both.
# ---------------------------------------------------------------------------

# WHICH LINES DECLARE A TEST is `trace.gutterTestLinesProvider`, and it lives
# there rather than here because `trace.editorLineNumber` is the thing that has
# to ask on every repaint. `addTestActions` reads the same one through
# `trace.gutterTestLinesFor`, so the gutter and the fallback widget cannot
# disagree about which lines have tests.
#
# Nil falls back to the text scan in `addTestActions`, which is what the desktop
# still uses. The two are not equivalent and the catalog is the better one: the
# scan matches `lineStr.strip() == "#[test]"` exactly, so `#[test(should_fail)]`
# and `#[test(should_fail_with = "…")]` get no control at all — two of the
# bundled Noir template's five tests, and precisely the two whose behaviour is
# worth checking.

var editorTestSelectorHook*: proc(path: cstring; attrLine: int): cstring
  ## The RUNNER'S OWN NAME for the test declared at `attrLine` — the
  ## fully-qualified `tests::test_main`, which is the string `nargo test
  ## --exact` compares against. Empty when the catalog has no such test.
  ##
  ## Not the bare function name `getLineFunctionName` splits out of the source:
  ## two modules may each declare `test_main`, and a runner given the bare name
  ## would run both or neither.

var editorTestRunHook*: proc(path: cstring; selector: cstring;
                             line: int): cstring
  ## Take the run. Returns "" when it was taken, or a sentence saying why it
  ## could not be — which the caller shows instead of starting a spinner.
  ##
  ## Nil means no host installed one, and the desktop `CODETRACER::run-test`
  ## path applies unchanged.

const editorTestRunFrames = 400
  ## 400 × 300 ms = two minutes. Long enough for a cold 16 MB wasm compiler to
  ## be fetched, instantiated and run over a project; short enough that a
  ## control which lost its answer stops claiming to be working before a user
  ## has decided the product is broken.

var spinningTestEditors: seq[EditorViewComponent] = @[]
  ## Every editor with a Run-test button currently animating. A list rather
  ## than one component because a session can have several editors open and a
  ## settle has to reach all of them; `activeTestId` alone could only ever
  ## describe the last one.

proc restoreTestButton(self: EditorViewComponent; note: cstring) =
  ## Take this editor out of the running state, however the run ended.
  ##
  ## TWO SURFACES, because the control moved and the old one has not been torn
  ## out from under the desktop's Python/Rust flows: the GUTTER slot, whose
  ## running state lives in `trace.gutterRunningTest` and becomes visible
  ## through a repaint, and the legacy inline widget, whose state is a class on
  ## a node. Both are cleared here so a settle cannot leave either spinning.
  if trace.gutterRunningTest.hasKey(self.name):
    trace.gutterRunningTest.del(self.name)
    # A REPAINT IS HOW IT BECOMES VISIBLE. Monaco re-renders the gutter
    # wholesale, so the running class is not a DOM edit that survives — it is
    # read out of the map above on the next render.
    self.updateLineNumbersOnly()
  if self.activeTestId.len == 0:
    return
  let el = cast[Element](jq("#" & self.activeTestId))
  self.activeTestId = cstring""
  if el.isNil:
    return
  el.classList.remove(cstring"active-test-button")
  el.innerHTML = if note.len > 0: note else: cstring"Run test"

proc settleEditorTestRun*(note: cstring = cstring"") =
  ## Stop every spinning Run-test button, however the run ended.
  ##
  ## Called on SETTLE and not on success: a refused run, a red suite and a
  ## green one all end the animation, because all three are answers. The one
  ## state this must never leave behind is "still running" over a run that is
  ## not.
  let editors = spinningTestEditors
  spinningTestEditors = @[]
  for editor in editors:
    editor.restoreTestButton(note)

proc loadAnimation(self: EditorViewComponent, el: Element, testId: cstring,
                   i: int, frame: int) =
  if self.activeTestId != testId:
    # SETTLED, or another test was started from this editor. Either way this
    # button is no longer the active one and the chain ends here — the missing
    # condition that made the original loop unbounded.
    return
  if frame >= editorTestRunFrames:
    self.restoreTestButton(cstring"Run test (timed out)")
    let index = spinningTestEditors.find(self)
    if index >= 0:
      spinningTestEditors.delete(index)
    self.api.errorMessage(
      "The test run did not answer within two minutes. Nothing about the " &
      "test has been established.")
    return
  let frames = ["Running.  ", "Running.. ", "Running..."]
  el.innerHTML = frames[i]
  let nextIndex = (i + 1) mod frames.len
  discard setTimeout(proc() = loadAnimation(self, el, testId, nextIndex,
                                            frame + 1), 300)

proc redrawActiveTestButton(self: EditorViewComponent) =
  let el = cast[Element](jq("#" & self.activeTestId))
  if el.isNil:
    return
  el.classList.add(cstring"active-test-button")
  let testId = self.activeTestId
  discard setTimeout(proc() = loadAnimation(self, el, testId, 0, 0), 0)

proc runTestFromGutter(self: EditorViewComponent; attrLine: int) =
  ## The gutter slot was clicked. One place, so the gutter and the legacy inline
  ## widget cannot start a run two different ways.
  let selector =
    if editorTestSelectorHook.isNil: cstring""
    else: editorTestSelectorHook(self.name, attrLine)
  if selector.len == 0:
    self.api.errorMessage("Could not work out which test this is.")
    return
  if editorTestRunHook.isNil:
    self.api.errorMessage("No host in this build can run the tests.")
    return
  # REFUSE BEFORE SHOWING A RUNNING STATE. A slot that starts spinning over a
  # request nothing took is the defect this control is being repaired for.
  let refusal = editorTestRunHook(self.name, selector, attrLine)
  if refusal.len > 0:
    self.api.errorMessage($refusal)
    return
  trace.gutterRunningTest[self.name] = attrLine
  if spinningTestEditors.find(self) < 0:
    spinningTestEditors.add(self)
  self.updateLineNumbersOnly()
  # THE DEADLINE APPLIES HERE TOO. `loadAnimation` carries it for the inline
  # widget; this slot has no animation to hang a frame counter on, so the cap is
  # a timeout. Without it a host that never settled would leave the slot
  # spinning for the life of the tab — the exact state this control had.
  discard setTimeout(proc() =
    if trace.gutterRunningTest.hasKey(self.name) and
       trace.gutterRunningTest[self.name] == attrLine:
      self.restoreTestButton(cstring"")
      self.api.errorMessage(
        "The test run did not answer within two minutes. Nothing about the " &
        "test has been established."), editorTestRunFrames * 300)
  self.api.infoMessage(&"\"{selector}\" started")

proc makeTestAction(self: EditorViewComponent, line: int, isPythonTest: bool = false): Node =
  # For Python tests, the function name is on the same line (line)
  # For Rust tests, the function is on the next line (line + 1, after #[test])
  let scannedName = if isPythonTest:
    self.getPythonTestFunctionName(line)
  else:
    self.getLineFunctionName(line + 1)
  # THE CATALOG'S NAME WHEN THERE IS ONE. `selector` is what a runner is given;
  # `scannedName` is what the source text looks like. They differ by the module
  # path, and the difference decides whether `--exact` selects one test or none.
  let selector =
    if editorTestSelectorHook.isNil: scannedName
    else:
      let fromCatalog = editorTestSelectorHook(self.name, line)
      if fromCatalog.len > 0: fromCatalog else: scannedName
  let testId = &"ct-test-action-{self.id}-{line}"
  if self.activeTestId == testId:
    discard setTimeout(proc() = redrawActiveTestButton(self), 0)

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(testId))
  result.setAttribute(cstring"class", cstring"flow-parallel flow-parallel-value-single editor-test-action")
  result.setAttribute(cstring"title",
    cstring(if selector.len > 0: "Run " & $selector else: "Run this test"))
  result.appendChild(document.createTextNode(cstring"Run test"))
  result.addEventListener(cstring"click", proc(ev: Event) =
    if selector.len == 0:
      self.api.errorMessage("Could not work out which test this is.")
      return

    if not editorTestRunHook.isNil:
      # A HOST TOOK IT, or said why it could not. Either way the button never
      # starts animating over a message that went nowhere.
      let refusal = editorTestRunHook(self.name, selector, line)
      if refusal.len > 0:
        self.api.errorMessage($refusal)
        return
      capture testId:
        self.activeTestId = testId
        self.redrawActiveTestButton()
      if spinningTestEditors.find(self) < 0:
        spinningTestEditors.add(self)
      self.api.infoMessage(&"\"{selector}\" started")
      return

    capture testId:
      self.activeTestId = testId
      self.redrawActiveTestButton()
    if spinningTestEditors.find(self) < 0:
      spinningTestEditors.add(self)
    self.runTest(scannedName, self.name, line, 1)
    self.api.infoMessage(&"\"{scannedName}\" started"))

proc makeFlowLine(self: EditorViewComponent, position: int): FlowLine =
  cdebug fmt"makeFlowLine position {position}"
  FlowLine(
    startBuffer: FlowBuffer(
      kind: FlowLineBuffer,
      position: position,
      loopIds: @[]
    ),
    number: position,
    variablesPositions: JsAssoc[cstring, int]{},
    sortedVariables: JsAssoc[cstring, Value]{},
    decorationsIds: @[],
    decorationsDoms: JsAssoc[cstring, Node]{},
    stepLoopCells: JsAssoc[int, JsAssoc[int, Node]]{},
    loopContainers: JsAssoc[int, Node]{},
    iterationContainers: JsAssoc[int, Node]{},
    loopIds: @[],
    sliderPositions: @[],
    activeLoopIteration: (-1,-1),
    loopStepCounts: JsAssoc[int, seq[int]]{}
  )

proc addTestActions*(self: EditorViewComponent) =
  # Determine if this is a Python file
  let lang = fromPath(self.name)
  let isPythonFile = lang == LangPythonDb

  # THE CATALOG FIRST, when a host has one. See `trace.gutterTestLinesProvider`:
  # the text
  # scan below cannot see `#[test(should_fail)]`, so on the bundled Noir
  # template it puts a Run button on three of the five tests and none on the
  # two whose behaviour is the most interesting.
  let catalogLines = trace.gutterTestLinesFor(self.name)
  let haveCatalog = catalogLines.len > 0

  # THE GUTTER GETS THE LINES, and this is what moves the control off the end
  # of the source line and into the strip a reader already looks at for
  # per-line actions. `trace.editorLineNumber` reads this map; a repaint is
  # what makes the slots appear.
  if haveCatalog:
    # `gutterTestLinesFor` has already cached the answer the gutter renders
    # from; nothing to publish here.
    #
    # AND ANY INLINE WIDGET FROM AN EARLIER PASS GOES. This proc can run twice
    # for one file — once when it opened, and again when the catalog arrived
    # (`refreshEditorTestControls`) — and the first pass may well have taken
    # the fallback branch and painted inline widgets. Leaving them would put a
    # control in the gutter AND one at the end of the source line for the same
    # test, which is two affordances for one action and a reader having to
    # decide which is real.
    #
    # Not `clearTest`, which is declared below this proc; the same three lines,
    # here, rather than reordering a file this size.
    for testLine in self.testLines:
      if not testLine.contentWidget.isNil:
        self.monacoEditor.removeContentWidget(testLine.contentWidget.toJs)
        testLine.contentWidget = nil
    self.testDom = JsAssoc[int, Node]{}

    self.updateLineNumbersOnly()

  for i, line in self.tabInfo.sourceLines:
    let rLine = i + 1
    let lineStr = $line

    # Check for Rust tests (#[test] attribute)
    #
    # THE INLINE WIDGET IS THE FALLBACK NOW, not the control. When a host
    # supplied a catalog the gutter carries the run control, and painting a
    # second one at the end of the source line would be two affordances for one
    # action — the reader has to decide which is real. Without a catalog (the
    # desktop's Python and Rust flows, which have no `ct test` provider wired
    # into this renderer) the inline widget is still the only one there is.
    let isRustTest =
      if haveCatalog: false
      else: lineStr.strip() == "#[test]" and not isPythonFile
    # Check for Python tests (def test_* or async def test_*)
    let isPythonTest = isPythonFile and isPythonTestLine(lineStr)

    if (isRustTest or isPythonTest) and not self.testDom.hasKey(rLine):
      self.testLines[rLine] = self.makeFlowLine(rLine)

      self.ensureTestLineContainer(rLine)

      let widget = self.testDom[rLine]
      let testContainer = self.makeTestContainer(rLine)
      let parentContainer = self.testDom[rLine]
      let testNode = self.makeTestAction(rLine, isPythonTest)

      testContainer.appendChild(testNode)
      parentContainer.appendChild(testContainer)

proc refreshEditorTestControls*(data: Data) =
  ## Re-derive every open editor's run-test controls from the CATALOG.
  ##
  ## WHY THIS HAS TO EXIST, and it is an ordering fact rather than a nicety.
  ## `addTestActions` runs when a file is opened; the project's test catalog
  ## arrives separately, on `CODETRACER::ns9-panes-catalog`. Nothing sequences
  ## the two. An editor that opened first read an EMPTY catalog, took the
  ## fallback branch, and painted the legacy inline widget — so the gutter had
  ## no run controls at all, and nothing would ever have re-derived them
  ## because `addTestActions` is not called again for a file already open.
  ##
  ## `onNs9PanesCatalog` calls this after `setCatalog`, which is the moment the
  ## answer changes. Idempotent by construction: it rebuilds the line map from
  ## the catalog rather than adding to it.
  if data.isNil or data.ui.isNil or data.ui.editors.isNil:
    return
  for editorId, editor in data.ui.editors:
    if editor.isNil or editor.monacoEditor.isNil:
      continue
    try:
      # FORGET FIRST. The cache holds what the provider said last time, and
      # this proc is called precisely because that answer has changed.
      trace.invalidateGutterTestLines(editor.name)
      editor.addTestActions()
    except CatchableError:
      cerror "refreshEditorTestControls: " & getCurrentExceptionMsg()
    except:
      cerror "refreshEditorTestControls: a non-Nim value was raised"

proc clearTest(self: EditorViewComponent) =
  for testLine in self.testLines:
    if not testLine.contentWidget.isNil:
      self.monacoEditor.removeContentWidget(testLine.contentWidget.toJs)
      testLine.contentWidget = nil
  self.testDom = JsAssoc[int, Node]{}

proc loadPendingFlowIfReady(self: EditorViewComponent): bool =
  if self.api.isNil:
    return false
  if self.tabInfo.isNil or self.tabInfo.monacoEditor.isNil:
    return false
  if not self.shouldLoadFlow:
    return false

  # Prefer the cached complete-move location over tabInfo.location. The latter
  # is the open-tab request shape and can carry rrTicks=0/NO_LINE while Monaco
  # was still mounting.
  let flowLocation =
    if self.hasPendingFlowLocation:
      self.pendingFlowLocation
    else:
      self.tabInfo.location
  if flowLocation.line <= 0:
    return false
  self.loadFlow(FlowMode.Call, flowLocation)
  self.shouldLoadFlow = false
  self.hasPendingFlowLocation = false
  true

proc editorLineCanHostFlow(self: EditorViewComponent, line: int): bool =
  if line <= 0:
    return false
  if self.tabInfo.isNil or self.tabInfo.sourceLines.len == 0:
    return true
  line <= self.tabInfo.sourceLines.len

proc locationPathMatchesEditor(self: EditorViewComponent, location: types.Location): bool =
  if location.path.len > 0 and sameSourceRevisionPath(location.path, self.name):
    return true
  if location.highLevelPath.len > 0 and sameSourceRevisionPath(location.highLevelPath, self.name):
    return true
  if location.lowLevelPath.len > 0 and sameSourceRevisionPath(location.lowLevelPath, self.name):
    return true
  location.path.len == 0 and location.highLevelPath.len == 0 and location.lowLevelPath.len == 0

proc usableInitialFlowLocation(
  self: EditorViewComponent,
  input: types.Location
): tuple[found: bool, location: types.Location] =
  var location = input
  if not self.locationPathMatchesEditor(location):
    return

  if not self.editorLineCanHostFlow(location.line):
    if location.highLevelPath.len > 0 and
        sameSourceRevisionPath(location.highLevelPath, self.name) and
        self.editorLineCanHostFlow(location.highLevelLine):
      location.path = location.highLevelPath
      location.line = location.highLevelLine
    elif location.lowLevelPath.len > 0 and
        sameSourceRevisionPath(location.lowLevelPath, self.name) and
        self.editorLineCanHostFlow(location.lowLevelLine):
      location.path = location.lowLevelPath
      location.line = location.lowLevelLine
    else:
      return

  if location.path.len == 0 and location.highLevelPath.len == 0:
    location.path = self.name

  (true, location)

proc eventFlowLocation(event: ProgramEvent): types.Location =
  types.Location(
    path: event.highLevelPath,
    line: event.highLevelLine,
    event: event.rrEventId,
    highLevelPath: event.highLevelPath,
    highLevelLine: event.highLevelLine,
    rrTicks: event.directLocationRRTicks,
    sourceGeneration: event.sourceGeneration,
    sourceDigest: event.sourceDigest
  )

proc firstEditorFlowLine(self: EditorViewComponent): int =
  if self.tabInfo.isNil:
    return 0
  for i, line in self.tabInfo.sourceLines:
    if ($line).strip.len > 0:
      return i + 1
  if self.tabInfo.sourceLines.len > 0:
    return 1
  0

proc eventFlowLocationForEditor(
  self: EditorViewComponent,
  event: ProgramEvent
): tuple[found: bool, location: types.Location] =
  let directLocation = self.usableInitialFlowLocation(eventFlowLocation(event))
  if directLocation.found:
    return directLocation
  if event.directLocationRRTicks <= 0:
    return
  if event.highLevelPath.len > 0 and not sameSourceRevisionPath(event.highLevelPath, self.name):
    return

  let line = self.firstEditorFlowLine()
  if not self.editorLineCanHostFlow(line):
    return

  (true, types.Location(
    path: self.name,
    line: line,
    event: event.rrEventId,
    highLevelPath: self.name,
    highLevelLine: line,
    rrTicks: event.directLocationRRTicks,
    sourceGeneration: event.sourceGeneration,
    sourceDigest: event.sourceDigest
  ))

proc initialDebuggerFlowLocation(self: EditorViewComponent): tuple[found: bool, location: types.Location] =
  if self.data.isNil or self.data.services.isNil or self.data.services.debugger.isNil:
    return
  self.usableInitialFlowLocation(self.data.services.debugger.location)

proc initialCachedMoveFlowLocation(self: EditorViewComponent): tuple[found: bool, location: types.Location] =
  if self.service.isNil:
    return

  let candidates = @[
    self.path,
    self.name,
    canonicalSourceRevisionPath(self.path),
    canonicalSourceRevisionPath(self.name)
  ]
  for key in candidates:
    if key.len == 0 or not self.service.completeMoveResponses.hasKey(key):
      continue
    let location = self.usableInitialFlowLocation(self.service.completeMoveResponses[key].location)
    if location.found:
      return location

proc initialCalltraceFlowLocation(self: EditorViewComponent): tuple[found: bool, location: types.Location] =
  if self.data.isNil or self.data.ui.isNil:
    return
  if self.data.ui.componentMapping[Content.Calltrace].len == 0:
    return

  for _, component in self.data.ui.componentMapping[Content.Calltrace]:
    let calltrace = CalltraceComponent(component)
    if calltrace.isNil:
      continue
    for callLine in calltrace.callLines:
      if callLine.isNil or callLine.content.isNil:
        continue
      if callLine.content.kind != CallLineContentKind.Call or callLine.content.call.isNil:
        continue
      let location = callLine.content.call.location
      let usableLocation = self.usableInitialFlowLocation(location)
      if usableLocation.found:
        if usableLocation.location.rrTicks > 0:
          return usableLocation

proc initialEventLogFlowLocation(self: EditorViewComponent): tuple[found: bool, location: types.Location] =
  if self.data.isNil:
    return

  if not self.data.services.isNil and not self.data.services.eventLog.isNil:
    for event in self.data.services.eventLog.events:
      let location = self.eventFlowLocationForEditor(event)
      if location.found:
        return location

  if not self.data.ui.isNil:
    for _, component in self.data.ui.componentMapping[Content.EventLog]:
      let eventLog = EventLogComponent(component)
      if eventLog.isNil:
        continue
      for event in eventLog.programEvents:
        let location = self.eventFlowLocationForEditor(event)
        if location.found:
          return location

proc initialFlowLocation(self: EditorViewComponent): tuple[found: bool, location: types.Location] =
  let tabLocation = self.usableInitialFlowLocation(self.tabInfo.location)
  if tabLocation.found:
    return tabLocation

  let debuggerLocation = self.initialDebuggerFlowLocation()
  if debuggerLocation.found:
    return debuggerLocation

  let cachedMoveLocation = self.initialCachedMoveFlowLocation()
  if cachedMoveLocation.found:
    return cachedMoveLocation

  let eventLogLocation = self.initialEventLogFlowLocation()
  if eventLogLocation.found:
    return eventLogLocation

  let calltraceLocation = self.initialCalltraceFlowLocation()
  if calltraceLocation.found:
    return calltraceLocation

proc loadInitialFlowIfReady(self: EditorViewComponent): bool =
  if self.api.isNil:
    return false
  if self.tabInfo.isNil or self.tabInfo.monacoEditor.isNil:
    return false
  if not self.flow.isNil:
    return false
  if not self.data.config.flow.enabled or
     self.data.ui.mode != DebugMode:
    return false
  let initialLocation = self.initialFlowLocation()
  if not initialLocation.found:
    return false

  self.loadFlow(FlowMode.Call, initialLocation.location)
  true

proc scheduleInitialFlowLoad(self: EditorViewComponent) =
  var attempts = 0

  proc tryLoad() =
    if self.isNil:
      return
    if not self.api.isNil and self.flow.isNil:
      self.api.emit(InternalLastCompleteMove, EmptyArg())
    if not self.flow.isNil:
      return
    if self.loadPendingFlowIfReady() or self.loadInitialFlowIfReady():
      return
    attempts += 1
    if attempts <= 200:
      discard setTimeout(proc() = tryLoad(), 50)

  discard setTimeout(proc() = tryLoad(), 0)

# ---------------------------------------------------------------------------
# IsoNim primary rendering — Monaco init and after-redraw extracted procs
# ---------------------------------------------------------------------------

proc initMonacoForEditor(self: EditorViewComponent, selector: cstring) =
  ## Initialise Monaco Editor inside the container identified by `selector`.
  ## Shared by the top-level and expanded direct IsoNim editor mount paths.
  ## Runs only once — guarded by `tabInfo.monacoEditor.isNil`.
  var tabInfo = self.tabInfo
  if tabInfo.isNil or not tabInfo.monacoEditor.isNil:
    return

  let path = tabInfo.name
  # DeepReview-GUI.md §5.1: "Keep the review representation read-only by
  # default."  A review opened from a dataset serves every tab out of
  # `DeepReviewFileData.sourceContent` — the file as of the REVIEWED COMMIT —
  # and names the tab by the dataset's repo-relative path, because that is the
  # only name a portable dataset has.  An editable tab therefore has a save
  # target that resolves against the index process's working directory, i.e.
  # wherever `ct review` happened to be typed, and saving would overwrite an
  # unrelated file that merely sits at the same relative path.  There is also
  # nothing to save into: a review has no working tree, only a commit that has
  # already happened.
  let readOnly = self.data.ui.readOnly or self.data.isReviewDatasetSession()

  # The theme definitions used to be emitted here, which made every other
  # Monaco surface depend on a source editor having been created first — see
  # `renderer.ensureMonacoThemesDefined`, which now owns them and which
  # `monacoThemeName` calls for every caller.
  let theme = monacoThemeName(self.data.config.theme)

  var editorReady = false
  try:
    let documentTmp = domWindow.document
    let overflowHost = documentTmp.createElement(cstring("div"))
    overflowHost.className = cstring("monaco-editor")
    documentTmp.body.appendChild(overflowHost)

    cdebug "editor: creating monaco editor " & $self.name
    var lang = fromPath(path)
    if lang == LangNoir:
      lang = LangRust

    cdebug lang

    tabInfo.monacoEditor = createMonacoEditor(
      selector,
      MonacoEditorOptions(
        value: tabInfo.source,
        language: lang.toCLang(),
        readOnly: readOnly,
        theme: theme,
        automaticLayout: true,
        folding: true,
        fontSize: self.data.ui.fontSize,
        fontFamily: codeFontFamily(self.data.ui),
        fontLigatures: true,
        minimap: js{ enabled: false },
        renderIndentGuides: true,
        find: js{ addExtraSpaceOnTop: false },
        renderLineHighlight: if self.editorView == ViewLowLevelCode: "none".cstring else: "".cstring,
        lineNumbers: proc(line: int): cstring = self.editorLineNumber(path, line),
        lineNumbersMinChars: monacoLineNumbersMinChars(lineCountForGutter(tabInfo.source)),
        lineDecorationsWidth: monacoLineDecorationsWidth(self.data.ui.fontSize),
        showFoldingControls: cstring"always",
        scrollBeyondLastColumn: 0,
        contextmenu: false,
        overflowWidgetsDomNode: overflowHost,
        fixedOverflowWidgets: true
      )
    )

    tabInfo.monacoEditor.config = getConfiguration(tabInfo.monacoEditor)
    tabInfo.monacoEditor.onDidChangeModelContent(proc(event: JsObject) =
      updateMonacoGutterWidth(tabInfo.monacoEditor, self.data.ui.fontSize)
    )
    editorReady = true
  except:
    cerror "editor: " & getCurrentExceptionMsg()
    if tabInfo.monacoEditor.isNil:
      return
  finally:
    if not tabInfo.monacoEditor.isNil:
      self.monacoEditor = tabInfo.monacoEditor
      if self.monacoEditor notin self.data.ui.monacoEditors:
        self.data.ui.monacoEditors.add(self.monacoEditor)
      registerLspEditor(self)
      try:
        self.delegateShortcuts(self.monacoEditor)
      except:
        cerror "delegateShortcuts " & getCurrentExceptionMsg()
    if not editorReady:
      return

  self.monacoEditor = tabInfo.monacoEditor
  if self.monacoEditor notin self.data.ui.monacoEditors:
    self.data.ui.monacoEditors.add(self.monacoEditor)

  tabInfo.monacoEditor.onMouseWheel(proc(e: js) =
    if not self.flow.isNil and self.flow.shouldRecalcFlow:
      self.flow.resizeFlowSlider()
  )

  tabInfo.monacoEditor.onDidScrollChange(proc(e: js) =
    let leftPos = fmt"{e.scrollLeft}px".cstring
    for trace in self.traces:
      trace.viewZone.domNode.style.toJs.left = leftPos
    if not self.flow.isNil and not self.flow.flowLoops.isNil:
      for flowLoop in self.flow.flowLoops:
        if not flowLoop.flowZones.isNil:
          self.flow.leftPos = leftPos
          flowLoop.flowZones.dom.style.toJs.left = leftPos
  )

  tabInfo.monacoEditor.onMouseDown(proc(e: js) =
    cdebug "M6 onMouseDown fired ctrl=" & $cast[bool](e.event.ctrlKey) &
      " alt=" & $cast[bool](e.event.altKey) &
      " shift=" & $cast[bool](e.event.shiftKey)
    if cast[bool](e.event.ctrlKey) and cast[bool](e.event.altKey):
      try:
        let targetToken = self.getTokenFromPosition(e.target.position)
        if targetToken != "":
          self.sourceCallJump(
            self.name,
            self.lastMouseMoveLine,
            targetToken,
            SmartJump)
      except AmbiguousFunctionCallException:
        self.api.errorMessage getCurrentExceptionMsg()
    elif cast[bool](e.event.altKey) and
        not cast[bool](e.event.ctrlKey) and
        not cast[bool](e.event.shiftKey) and
        not cast[bool](e.event.middleButton):
      # M6 — Column-Aware Replay Navigation: Alt+click on the line
      # text places a column-anchored breakpoint at the exact column
      # Monaco resolves under the click.  The gutter HTML click
      # handler below still drives the legacy line-only path so
      # M1's back-compat invariant holds — Alt+click is opt-in.
      cdebug "M6 alt+click fired"
      let position = e.target.position
      if not position.isNil:
        let lineNumber = cast[int](position.lineNumber)
        let column = cast[int](e.target.toJs.position.column)
        cdebug "M6 alt+click line=" & $lineNumber & " column=" & $column
        var maxColumn = none(int)
        let textModel = self.monacoEditor.getModel()
        if not textModel.isNil:
          let lm = textModel.getLineMaxColumn(lineNumber)
          if lm >= 1:
            maxColumn = some(lm)
        # The target element class tells us whether Monaco hit the
        # gutter region (margin / overlay / decorations) — those
        # should fall through to the legacy line-only path even
        # under Alt+click.
        var onGutter = false
        let targetClass =
          cast[cstring](e.target.element.classList.value)
        cdebug "M6 alt+click targetClass=" & $targetClass
        if ($targetClass).contains("margin") or
           ($targetClass).contains("glyph") or
           ($targetClass).contains("line-numbers"):
          onGutter = true
        self.lineActionClickAt(
          tabInfo,
          lineNumber,
          monacoColumn = some(column),
          onGutterElement = onGutter,
          lineMaxColumn = maxColumn)
        e.event.preventDefault()
        e.event.stopPropagation()
      else:
        cdebug "M6 alt+click position nil"
    elif cast[bool](e.event.ctrlKey) or cast[bool](e.event.middleButton):
      self.lastMouseClickLine = self.lastMouseMoveLine
      self.lastMouseClickCol = cast[int](e.target.toJs.position.column)
      if cast[bool](e.event.middleButton) :
        self.sourceOrCallJump(e.target.position)
      else:
        self.editorLineJump(self.lastMouseMoveLine, SmartJump)
    else:
      let position = e.target.position
      let target = cast[cstring](e.target.element.classList.value).split(" ")[0]
      let line = cast[int](position.lineNumber)
      if target != "fa" and not ui_imports.jslib.startsWith(target, "value"):
        self.lastMouseClickLine = line
        self.lastMouseClickCol = cast[int](e.target.toJs.position.column)
        self.data.redraw()
    self.data.ui.activeFocus = self)

  tabInfo.monacoEditor.onContextMenu(proc(ev: js) =
    console.log(cstring"editor: onContextMenu fired")
    # TWO MENUS, and this is where the second one came from.  Reported
    # 2026-09-02 against ide.codetracer.com: "when I right click in the editor
    # area in the IDE, I see both the browser menu and the CodeTracer menu".
    #
    # `contextmenu: false` in the editor options (`:2508`, and `:1943` for the
    # expansion editor) only stops MONACO's own menu — and it is also what stops
    # Monaco's `ContextMenuController` from ever calling `preventDefault`, so the
    # native `contextmenu` event ran to completion and the browser drew its menu
    # over ours.
    #
    # AND THE GUTTER WAS NOT THE EXCEPTION IT LOOKED LIKE.  The listener below
    # (`:2674`) does call `preventDefault`, but only for a target whose class
    # list contains `gutter-line` or `gutter-breakpoint` — so on the rest of the
    # margin (Monaco's own `.line-numbers`, `.margin`) nothing suppressed
    # anything and the gutter showed two menus as well.  Measured against an
    # assembled bundle before this change: right-clicking `div.gutter` gave
    # `defaultPrevented == false`, exactly like the text surface.  This handler
    # fires for the margin too, so one `preventDefault` here covers both, and
    # `ci/test/menu-and-context-menu-in-browser.sh` asserts each separately.
    #
    # SHIFT IS THE ESCAPE HATCH AND IT IS DELIBERATELY NOT SUPPRESSED.  A page
    # can suppress the native menu but has no API to summon it, so "show the
    # browser menu" cannot be a command in ours.
    #
    # STANDING DOWN, rather than suppressing and trusting the browser to
    # override us, is what makes the gesture work on every engine instead of
    # two.  Measured (see `viewmodel/views/context_menu_hint.nim`): Firefox does
    # not deliver the event at all when Shift is held, but Chromium AND WebKit
    # both do — so on those two what happens next is the PAGE's decision, and a
    # `preventDefault` here would have swallowed the modifier in exactly the
    # browsers where the user would notice.  Returning early means we show
    # nothing and prevent nothing, and the browser's default action for an
    # unprevented `contextmenu` is its own menu.
    if cast[bool](ev.event.toJs.shiftKey):
      return
    ev.event.preventDefault()
    let contextMenu = createContextMenuItems(self, ev)
    console.log(cstring"editor: context menu items count = " & $contextMenu.len)
    if contextMenu.len > 0:
      showContextMenu(contextMenu, cast[int](ev.event.posx), cast[int](ev.event.posy)))

  tabInfo.monacoEditor.onMouseMove(proc(event: js) =
    let position = event.target.position
    let line = if not position.isNil:
        cast[int](position.lineNumber)
      else:
        (cast[int](event.target.element.parentElement.offsetTop) div 20) + tabInfo.location.expansionFirstLine
    self.lastMouseMoveLine = line)

  tabInfo.monacoEditor.toJs.getModel().onDidChangeContent(proc =
    if tabInfo.reloadChange:
      tabInfo.reloadChange = false
    else:
      tabInfo.changed = true)

  console.log("DELEGATING SHORTCUTS")

  try:
    self.delegateShortcuts(self.monacoEditor)
  except:
    cerror "delegateShorcuts " & getCurrentExceptionMsg()

  try:
    self.loadKeyPlugins()
  except:
    cerror "loadKeyPlugins " & getCurrentExceptionMsg()

  document.querySelector(selector).addEventListener(cstring"click", proc(ev: Event) =
    ev.stopPropagation()
    # THE RUN SLOT IS ROUTED FIRST, and the order is the whole of the guard.
    # `gutter-runtest` contains "gutter", so the sweep at the bottom of this
    # loop would toggle a breakpoint on it — one point answering two controls,
    # which is exactly what the marker lanes were given disjoint hit areas to
    # stop. Read from the attribute rather than from the class, because the line
    # is what the handler needs and the class does not carry it.
    let runAttr =
      cast[Element](ev.target).getAttribute(cstring"data-runtest-line")
    if not runAttr.isNil and runAttr.len > 0:
      try:
        self.runTestFromGutter(parseInt($runAttr))
      except CatchableError:
        self.api.errorMessage("This line's run control names no line.")
      return
    for element in cast[seq[cstring]](ev.toJs.target.classList):
      if element == cstring"gutter-line" or element == cstring"gutter-breakpoint":
        self.lineActionClick(tabInfo, ev.target.toJs)
        return
      if ($element).contains("gutter"):
        self.lineActionClick(tabInfo, ev.target.toJs)
  )

  document.querySelector(selector).addEventListener(cstring"contextmenu", proc(ev: Event) =
    for element in cast[seq[cstring]](ev.toJs.target.classList):
      if element == cstring"gutter-line" or element == cstring"gutter-breakpoint":
        ev.preventDefault()
        ev.stopPropagation()
        self.lineActionContextMenu(tabInfo, ev.target.toJs)
        return
  )

  discard self.loadInitialFlowIfReady()

  if not self.api.isNil:
    self.api.emit(InternalLastCompleteMove, EmptyArg())

proc editorAfterRedraw(self: EditorViewComponent) =
  ## Per-redraw work for the editor: flow rendering, line styles, test
  ## actions, inline values, trace/expansion redraws.
  let tabInfo = self.tabInfo
  if tabInfo.isNil:
    return

  try:
    if self.isExpansion:
      var zoneNode = cast[Node](self.viewZone.domNode)

    if not self.flow.isNil and self.data.config.flow.enabled and self.data.ui.mode == DebugMode:
      self.redrawFlow()
      if not self.flow.flow.isNil:
        self.flow.scheduleActiveLoopIterationValueRender()
    else:
      if not self.flow.isNil and not self.flow.flow.isNil:
        self.flow.clear()

    if not self.loadPendingFlowIfReady():
      discard self.loadInitialFlowIfReady()

    if not self.data.startOptions.diff.isNil and
      self.diffViewZones.len() == 0 and
      self.diffAddedLines.len() == 0:
        self.clearDiffViewZones()
        self.makeDiffViewZones()
        self.loadFlow(FlowMode.Diff, types.Location())

    self.addTestActions()
    self.applyEventualStylesLines()
    # M6 — refresh column-anchored breakpoint markers so they survive
    # editor scroll / resize and reflect any column breakpoints
    # registered via Alt+click or the M1 `addColumnBreakpoint` API.
    self.applyColumnBreakpointDecorations()

  except Exception as e:
    cerror "afterRedraw redrawFlow" & getCurrentExceptionMsg()

  if self.data.ui.activeFocus == self:
    discard self.renderValueTooltip()

  # Tracepoint results (#566): this used to unconditionally call
  # `refreshTraceViewZoneDom()` for every expanded tracepoint, on every
  # completed move — including the `CtTraceJump` the results grid's OWN row
  # click emits. That wipes `viewZone.domNode.innerHTML`, detaching the
  # `<table>` the live jQuery-DataTables instance is bound to while leaving
  # `dataTable.context` non-nil, so `renderTableResults` then refused to build
  # a replacement and the `.chart-table` container stayed `hidden`: the grid
  # disappeared after the first jump. Only rebuild when there is genuinely
  # nothing mounted; otherwise refresh the live subtree in place.
  # The decision lives in `ui/trace_redraw_policy.nim` so it is unit-testable
  # (this panel has no ViewModel).
  for line, trace in self.traces:
    case traceRedrawAction(
        expanded = trace.expanded,
        hasViewZone = not trace.viewZone.isNil,
        resultsDomMounted = trace.traceResultsDomMounted())
    of traSkip:
      discard
    of traRefreshInPlace:
      trace.refreshTrace()
      trace.refreshTraceTableLayout()
    of traRebuild:
      trace.refreshTraceViewZoneDom()

  for line, expandedInstance in self.expanded:
    self.ensureExpanded(expandedInstance, line)
    if expandedInstance.isExpanded:
      expandedInstance.renderExpandedEditorDirect()

proc reloadFlowAfterActivation(self: EditorViewComponent) =
  ## Flow-data half of ``refreshFlowAfterActivation``: get the flow either
  ## redrawn or (re)requested, whichever the component's state calls for.
  ## Split out so the decoration repaint below runs on EVERY one of these
  ## branches instead of being skipped by the first early ``return``.
  if not self.api.isNil and self.flow.isNil:
    self.api.emit(InternalLastCompleteMove, EmptyArg())
  if not self.flow.isNil:
    self.redrawFlow()
    self.flow.scheduleActiveLoopIterationValueRender()
    return
  if self.loadPendingFlowIfReady():
    return
  if self.loadInitialFlowIfReady():
    return
  if self.flow.isNil:
    return
  if self.data.config.flow.enabled and self.data.ui.mode == DebugMode and
     not self.flow.flow.isNil:
    self.flow.redrawFlow()
    self.flow.scheduleActiveLoopIterationValueRender()

proc refreshFlowAfterActivation*(self: EditorViewComponent) =
  if self.isNil:
    return
  if self.tabInfo.isNil or self.tabInfo.monacoEditor.isNil:
    return

  self.reloadFlowAfterActivation()

  # #594: activating a tab must repaint the line decorations too. Neither
  # `redrawFlow` overload touches them (the EditorViewComponent one only
  # recomputes `maxFlowLineWidth`), so without this the newly activated tab
  # showed the flow widgets but no `flow-taken` / `flow-not-taken` colours —
  # while the tab the user came from, which had been repainted by an
  # `onCompleteMove` at an already-loaded rrTicks, kept them. That asymmetry
  # is exactly what the reporter described.
  self.applyEventualStylesLines()
  self.applyColumnBreakpointDecorations()

proc tryMountIsoNimEditorPanel*(self: EditorViewComponent) =
  ## Mark the IsoNim editor view as the primary renderer once Monaco
  ## has initialized inside the direct editor host.
  ##
  ## Called after Monaco has been initialised by the direct IsoNim editor
  ## mount path.
  ##
  ## Safe to call multiple times per editor — mounts only once per id.
  let editorId = self.id
  if isoNimEditorMountedIds.hasKey(editorId):
    return

  # Ensure the EditorVM is available before taking ownership.
  initEditorVM()
  if editorVMInstance.isNil:
    return

  let tabInfo = self.tabInfo
  if tabInfo.isNil:
    return

  # Only mount after Monaco has been created — we need the container
  # to already be in the DOM with Monaco attached.
  if tabInfo.monacoEditor.isNil:
    return

  # Remove the legacy renderer instance so redrawAll() skips this component.
  # Editor tabs use the file path (self.name) as the renderer key.
  # This prevents legacy VDOM diffing from corrupting the IsoNim/Monaco
  # managed DOM on subsequent redraw cycles.
  if not self.name.isNil:
    renderer.removeLegacyRendererInstanceByKey(self.name)

  isoNimEditorMountedIds[editorId] = true

  clog "IsoNim editor: mounted as primary renderer for editorComponent-" & cstring($editorId)

proc editorSourceReady(self: EditorViewComponent): bool =
  not self.service.open.hasKey(self.name) or self.service.open[self.name].received

proc ensureEditorLspStarted(self: EditorViewComponent) =
  if not self.data.lspStarted:
    self.data.ipc.send("CODETRACER::start-lsp", js{})
    self.data.lspStarted = true

when defined(js):
  proc replaceWithIsoNimEditorPanel(self: EditorViewComponent;
                                    host: dom_api.Element): dom_api.Element =
    initEditorVM()
    if editorVMInstance.isNil:
      return nil

    let path =
      if not self.tabInfo.isNil:
        $self.tabInfo.name
      else:
        $self.name
    let depth =
      if not self.tabInfo.isNil:
        self.tabInfo.location.expansionDepth
      else:
        0
    let hostId = cstring(&"editorComponent-{self.id}")

    if dom_api.getAttribute(host, cstring"data-isonim-editor-host") == cstring"true":
      return host

    let r = WebRenderer()
    let panel = renderEditorPanel(
      r,
      editorVMInstance,
      self.id,
      path,
      false,
      depth,
      $hostId)
    let parent = host.parentNode
    if dom_api.isNodeNil(parent):
      return nil

    discard dom_api.replaceChild(parent, dom_api.Node(panel), dom_api.Node(host))
    dom_api.setAttribute(panel, cstring"data-isonim-editor-host", cstring"true")
    panel

  proc renderTopLevelEditorDirect*(self: EditorViewComponent; containerId: cstring) =
    ## Mount the top-level editor GoldenLayout surface directly through IsoNim.
    ##
    ## GoldenLayout creates a temporary ``component-container`` with the stable
    ## ``editorComponent-{id}`` id.  This proc replaces that placeholder with
    ## the IsoNim editor host using the same id, then initializes Monaco once
    ## source data is available.  Loading tabs keep the shell mounted and retry
    ## until the legacy editor service marks the source as received.
    self.ensureEditorLspStarted()

    let componentId = self.id
    var retryCount = 0
    var afterInitScheduled = false
    var layoutListenerInstalled = false
    var layoutListener: proc(ev: Event)

    if isoNimEditorMountedIds.hasKey(componentId):
      discard jsDelete(isoNimEditorMountedIds[componentId])

    proc doMount() =
      retryCount += 1

      # Query the container ID dynamically from layoutItem/contentItem metadata if available
      var targetContainerId = containerId
      if not self.layoutItem.isNil and not self.layoutItem.componentState.isNil:
        let stateId = self.layoutItem.componentState.id
        if stateId > 0:
          targetContainerId = cstring("editorComponent-" & $stateId)

      var host = dom_api.getElementById(dom_api.document, targetContainerId)
      if dom_api.isNodeNil(dom_api.Node(host)):
        if not layoutListenerInstalled:
          layoutListenerInstalled = true
          domwindow.addEventListener(cstring"ct:layoutUpdated", layoutListener)
        if retryCount <= 200:
          discard setTimeout(proc() = doMount(), 20)
        return

      if self.editorView == ViewNoSource and not self.noInfo.isNil:
        self.noInfo.renderNoSourceShellDirect(host)
        if not afterInitScheduled:
          afterInitScheduled = true
          discard self.afterInit()
        if layoutListenerInstalled:
          domwindow.removeEventListener(cstring"ct:layoutUpdated", layoutListener)
        return

      let panel = self.replaceWithIsoNimEditorPanel(host)
      if dom_api.isNodeNil(dom_api.Node(panel)):
        if not layoutListenerInstalled:
          layoutListenerInstalled = true
          domwindow.addEventListener(cstring"ct:layoutUpdated", layoutListener)
        if retryCount <= 200:
          discard setTimeout(proc() = doMount(), 20)
        return

      # Successfully replaced the host with the panel, we can remove the layout listener now.
      if layoutListenerInstalled:
        domwindow.removeEventListener(cstring"ct:layoutUpdated", layoutListener)

      if not afterInitScheduled:
        afterInitScheduled = true
        discard self.afterInit()

      let sourceReady = self.editorSourceReady()
      if self.tabInfo.isNil or not sourceReady:
        if retryCount <= 1200:
          discard setTimeout(proc() = doMount(), 25)
        return

      let selector = cstring("#editorComponent-" & $componentId)
      if self.tabInfo.monacoEditor.isNil:
        self.initMonacoForEditor(selector)

      if not self.tabInfo.monacoEditor.isNil:
        self.tryMountIsoNimEditorPanel()
        self.editorAfterRedraw()

    # Define the layout updated listener callback
    layoutListener = proc(ev: Event) =
      if not isoNimEditorMountedIds.hasKey(componentId):
        doMount()

    doMount()

proc renderExpandedEditorDirect(self: EditorViewComponent) =
  ## Refresh a Monaco macro-expansion editor without registering a Karax
  ## renderer. The view-zone host keeps the stable ``expanded-{line}`` id that
  ## Monaco attaches to, while the host structure comes from the shared IsoNim
  ## editor view.
  if not self.isExpansion or self.viewZone.isNil:
    return

  initEditorVM()
  if editorVMInstance.isNil or self.tabInfo.isNil:
    return

  let hostId = cstring(&"expanded-{self.parentLine}")
  var host = dom_api.getElementById(dom_api.document, hostId)
  if dom_api.isNodeNil(dom_api.Node(host)):
    return

  if dom_api.getAttribute(host, cstring"data-isonim-editor-host") != cstring"true":
    let r = WebRenderer()
    let panel = renderEditorPanel(
      r,
      editorVMInstance,
      self.id,
      $self.tabInfo.name,
      true,
      self.tabInfo.location.expansionDepth,
      $hostId)
    let parent = host.parentNode
    if dom_api.isNodeNil(parent):
      return
    discard dom_api.replaceChild(
      parent,
      dom_api.Node(panel),
      dom_api.Node(host))
    dom_api.setAttribute(panel, cstring"data-isonim-editor-host", cstring"true")
    host = panel

  if self.tabInfo.monacoEditor.isNil:
    self.initMonacoForEditor(hostId)

  self.editorAfterRedraw()

proc ensureExpanded*(self: EditorViewComponent, expanded: EditorViewComponent, line: int) =
  if expanded.viewZone.isNil:
    let id = cstring(&"expanded-{line}")
    var expandedViewZoneNode = createElement(dom.document, cstring"div")
    var editorNode = createElement(dom.document, cstring"div")

    editorNode.toJs.id = id
    editorNode.toJs.classList.add(cstring"expansion")
    expandedViewZoneNode.append(editorNode)

    expanded.viewZone = js{
      afterLineNumber: line,
      heightInLines: 7,
      domNode: expandedViewZoneNode
    }

    self.monacoEditor.changeViewZones do (view: js):
      expanded.zoneId = cast[int](view.addZone(expanded.viewZone))

    domwindow.toJs.parent = expanded.viewZone.domNode.parentNode
    expanded.isExpanded = true

    return
  else:
    if not expanded.isExpanded:
      if expanded.zoneId >= 0:
        self.monacoEditor.changeViewZones do (view: js):
          try:
            view.removeZone(expanded.zoneId)
            expanded.zoneId = -1
          except:
            cerror "editor: non expanded: " & getCurrentExceptionMsg()
    else:
      if expanded.zoneId == -1:
        self.monacoEditor.changeViewZones do (view: js):
          expanded.zoneId = cast[int](view.addZone(expanded.viewZone))

    discard

method afterInit*(self: EditorViewComponent) {.async.} =
  # ``[NSS-1.64]`` Diagnostic: the noir-space-ship loop-iteration GUI tests
  # ("loop iteration slider tracks remaining shield" and "simple loop
  # iteration jump") open shield.nr fresh via a calltrace-jump to
  # iterate_asteroids and then wait on ``.flow-multiline-value-container``.
  # That widget is rendered by ``flow.nim::makeLoopLine`` only after the
  # ``loadFlow`` -> ``CtUpdatedFlow`` -> ``onUpdatedFlow`` chain runs for
  # the freshly-opened editor.  The replay below is the moment the cached
  # CtCompleteMove (stored by editor_service keyed on
  # ``response.location.highLevelPath`` -- editor_service.nim:42) is
  # delivered to the new EditorViewComponent.  See
  # ``/tmp/isonim-migration.txt`` §5.8 / §1.54 / §1.64.
  let isShield = ($self.path).contains("shield.nr")
  if isShield:
    clog cstring("[NSS-1.64] afterInit: path=" & $self.path &
                 " hasCachedMove=" & $self.service.completeMoveResponses.hasKey(self.path))
  if self.service.completeMoveResponses.hasKey(self.path):
    if isShield:
      let cached = self.service.completeMoveResponses[self.path]
      clog cstring("[NSS-1.64] afterInit: replaying cachedMove rrTicks=" &
                   $cached.location.rrTicks & " line=" & $cached.location.line &
                   " resetFlow=" & $cached.resetFlow &
                   " highLevelPath=" & $cached.location.highLevelPath)
    let cached = self.service.completeMoveResponses[self.path]
    await self.onCompleteMove(cached)
    discard jsDelete(self.service.completeMoveResponses[self.path])
    if cached.location.path.len > 0:
      discard jsDelete(self.service.completeMoveResponses[cached.location.path])
    if cached.location.highLevelPath.len > 0:
      discard jsDelete(self.service.completeMoveResponses[cached.location.highLevelPath])
  elif isShield:
    # Diagnostic: the cached move may have been stored under
    # ``highLevelPath`` while we look it up by ``self.path``.  Walk the
    # responses map and report any entries whose key contains shield.nr
    # so we can spot a key/path mismatch under the IsoNim mount.
    for k, _ in self.service.completeMoveResponses:
      if ($k).contains("shield.nr"):
        clog cstring("[NSS-1.64] afterInit: cachedMove present under key " & $k &
                     " (self.path=" & $self.path & ") -- KEY MISMATCH")

func supportsFlow*(self: EditorViewComponent): bool =
  self.data.config.flow.enabled

method onFindOrFilter*(self: EditorViewComponent) {.async.} =
  self.monacoEditor.trigger("keyboard".cstring, "actions.find".cstring)

proc applySourceRevisionForLocation(self: EditorViewComponent;
                                    location: types.Location) {.async.} =
  if self.tabInfo.isNil:
    return
  let revisionPath = sourceRevisionPath(location)
  if revisionPath.len == 0:
    return
  if revisionPath != self.path and revisionPath != self.name and
      location.path != self.path and location.path != self.name and
      not sameSourceRevisionPath(revisionPath, self.path) and
      not sameSourceRevisionPath(revisionPath, self.name) and
      not sameSourceRevisionPath(location.path, self.path) and
      not sameSourceRevisionPath(location.path, self.name):
    return

  let editorService = self.data.services.editor
  let tabHasRevisionIdentity = sourceRevisionHasIdentity(self.tabInfo.location)
  if tabHasRevisionIdentity and
      sameSourceRevisionPath(sourceRevisionPath(self.tabInfo.location), revisionPath):
    editorService.cacheSourceRevision(self.tabInfo.location, self.tabInfo.source)

  var desiredSource = cstring""
  let pendingPath = canonicalSourceRevisionPath(revisionPath)
  if location.sourceGeneration != 0 and
      editorService.pendingDiskSourceByPath.hasKey(pendingPath):
    desiredSource = editorService.pendingDiskSourceByPath[pendingPath]
    editorService.cacheSourceRevision(location, desiredSource)
  elif location.sourceGeneration != 0 and
      editorService.pendingDiskSourceByPath.hasKey(revisionPath):
    desiredSource = editorService.pendingDiskSourceByPath[revisionPath]
    editorService.cacheSourceRevision(location, desiredSource)
  elif editorService.hasSourceRevision(location):
    desiredSource = editorService.sourceRevisionSource(location)
  elif location.sourceGeneration != 0:
    try:
      let diskSource = await readFileUtf8(revisionPath)
      if not diskSource.isNil and diskSource.len > 0:
        desiredSource = diskSource
        editorService.cacheSourceRevision(location, desiredSource)
    except:
      cwarn fmt"source revision: failed to read {revisionPath}: {getCurrentExceptionMsg()}"
  elif location.sourceGeneration == 0 and
      sourceRevisionHasIdentity(location) and
      not tabHasRevisionIdentity:
    desiredSource = self.tabInfo.source
    editorService.cacheSourceRevision(location, desiredSource)

  if desiredSource.len == 0:
    return

  self.tabInfo.location = location
  if self.tabInfo.source != desiredSource:
    self.tabInfo.source = desiredSource
    self.tabInfo.lastSyncedSource = desiredSource
    self.tabInfo.sourceLines = desiredSource.split(jsNl)
    self.tabInfo.changed = false
    self.tabInfo.reloadChange = false
    if not self.monacoEditor.isNil:
      self.monacoEditor.setValue(desiredSource)

method onCompleteMove*(self: EditorViewComponent, response: MoveState) {.async.} =
  # ``[NSS-1.64]`` Diagnostic for the noir-space-ship loop-iteration GUI
  # blocker (§5.8).  Both failing tests (lines 278, 393 in
  # ``noir-space-ship.spec.ts``) gate on
  # ``.flow-multiline-value-container`` rendered by
  # ``flow.nim::makeLoopLine``.  This log line lets us confirm whether
  # the per-component CtCompleteMove subscription (editor.nim:711) is
  # delivering the iterate_asteroids jump to the shield.nr editor.
  let isShield = ($self.path).contains("shield.nr") or
                 ($response.location.path).contains("shield.nr")
  if isShield:
    clog cstring("[NSS-1.64] EditorVC.onCompleteMove: self.path=" &
                 $self.path & " editorView=" & $self.editorView &
                 " response.path=" & $response.location.path &
                 " line=" & $response.location.line &
                 " rrTicks=" & $response.location.rrTicks &
                 " resetFlow=" & $response.resetFlow &
                 " flowIsNil=" & $self.flow.isNil &
                 " monacoNil=" & $self.tabInfo.isNil)

  # Feed the same position into the parallel ViewModel store.
  initEditorVM()
  syncEditorDebuggerPosition(
    response.location.rrTicks,
    response.location.path,
    response.location.line,
    response.location.sourceGeneration,
    response.location.sourceDigest)

  duration("complete move")
  self.location = response.location
  await self.applySourceRevisionForLocation(response.location)
  # cdebug fmt"reset Flow {response.resetFlow}"

  if self.editorView == ViewTargetSource and self.data.trace.lang == LangNim and
     response.cLocation.path == self.name:
    if not self.monacoEditor.isNil:
      self.monacoEditor.revealLineInCenterIfOutsideViewport(response.cLocation.line, Immediate)

  discard setTimeout(proc() = self.updateLineNumbersOnly(), 100)

  for view, isEnabled in self.data.ui.openViewOnCompleteMove:
    if isEnabled:
      case view:
      of ViewInstructions:
        if self.data.trace.lang in {LangC, LangCpp, LangRust, LangGo}:
          self.data.openInstructions(self.data.services.debugger.location.asmName)
        elif self.data.trace.lang == LangNim:
          self.data.openInstructions(self.data.services.debugger.cLocation.asmName)

      of ViewTargetSource:
        if self.data.trace.lang == LangNim:
          self.data.openTargetSource(self.data.services.debugger.cLocation.path)

      else:
        discard

  let sourceFilePath =
    if self.editorView != ViewInstructions:
      self.path
    else:
      self.path.split(cstring":")[0]

  let moveTargetsEditor =
    sameSourceRevisionPath(response.location.path, sourceFilePath) or
    (response.location.highLevelPath.len > 0 and
     sameSourceRevisionPath(response.location.highLevelPath, sourceFilePath))

  if moveTargetsEditor:
    self.data.services.debugger.stableBusy = false
    if not response.location.isExpanded:
      self.service.active = canonicalSourceRevisionPath(response.location.path)
    else:
      self.service.active = cstring(&"expanded-{response.location.expansionFirstLine}")
    self.service.changeLine = true
    self.service.currentLine = response.location.line

    if not self.flow.isNil:
      self.flow.activeStep = FlowStep(rrTicks: -1)

    # When the debugger position changes within an already-open editor,
    # a stale FlowComponent may still be present from the previous
    # position.  ``redrawFlow()`` only re-renders the existing flow data
    # without re-fetching from the backend, so the loop iteration
    # widgets (.flow-multiline-value-container) computed at the OLD
    # rrTicks would persist or be empty for the NEW rrTicks.  Force a
    # reload whenever the rrTicks differs from what the flow last
    # loaded — this is what the GUI loop-iteration tests
    # (``loop iteration slider tracks remaining shield`` and
    # ``simple loop iteration jump``) depend on after a calltrace jump
    # to ``iterate_asteroids``.  See /tmp/isonim-migration.txt §1.54.
    let needsFlowReload =
      self.supportsFlow() and (
        response.resetFlow or
        self.flow.isNil or
        self.flow.location.rrTicks != response.location.rrTicks
      )
    if needsFlowReload:
      # Do NOT call self.flow.clear() here. The old component's DOM stays
      # visible while the backend loads new flow data, preventing the blank-
      # panel flash. loadFlow() stores the old component in handoffFlow so
      # onUpdatedFlow can remove its zones after the new DOM is built.
      cdebug "flow: create flow again"
      if response.location.line <= 0:
        self.shouldLoadFlow = false
        self.hasPendingFlowLocation = false
      elif self.tabInfo.monacoEditor.isNil:
        self.shouldLoadFlow = true
        # NSS-1.68 FRONTEND fix: capture the move's true location so the deferred
        # loadFlow in ``editorAfterRedraw`` does not fall back to the stale
        # tabInfo.location (rrTicks=0, line=NO_LINE).
        self.pendingFlowLocation = response.location
        self.hasPendingFlowLocation = true
        if isShield:
          # ``[NSS-1.64]`` Diagnostic: monaco not ready yet, so loadFlow
          # is deferred to ``editorAfterRedraw``.  See §1.64.
          clog cstring("[NSS-1.64] EditorVC.onCompleteMove: shouldLoadFlow=true (monaco-not-ready)")
      else:
        if isShield:
          clog cstring("[NSS-1.64] EditorVC.onCompleteMove: calling loadFlow now (monaco-ready)")
        # If the new debugger position is within the same flow window (same
        # function body + same call invocation), reuse the existing FlowComponent
        # instead of creating a new one. FlowComponent.onCompleteMove (called
        # below) handles the in-place update — no CtLoadFlow needed. This keeps
        # the slider DOM alive during rapid slider drags (no focus loss) and
        # avoids accumulating handoffFlow chains that cause view-zone duplication.
        #
        # "Same function" detection:
        #   Primary: compare functionFirst+functionLast+path from the move
        #     response. The backend (dap_handler.rs) enriches every ct/complete-move
        #     Location with the enclosing function's first/last source lines.
        #     When they match the stored values from the last onCompleteMove call,
        #     we're still inside the same function body.
        #   Fallback (functionFirst==0, i.e. backend didn't enrich): use the
        #     rrTicks range of the current flow window's steps (rr traces) or
        #     the source-line range (DB traces with all rrTicks==0).
        let canReuseFlow = block:
          if self.flow.isNil or self.flow.flow.isNil:
            false
          else:
            let prevFunctionFirst = self.flow.location.functionFirst
            let newFunctionFirst = response.location.functionFirst
            if prevFunctionFirst > 0 and newFunctionFirst > 0:
              # Backend enriched both locations: direct function-bounds comparison.
              self.flow.location.path == response.location.path and
              prevFunctionFirst == newFunctionFirst and
              self.flow.location.functionLast == response.location.functionLast
            elif self.flow.flow.steps.len == 0:
              false
            else:
              # Fallback: infer from execution range
              let newTicks = response.location.rrTicks
              if newTicks != 0:
                # rr trace: same function call = rrTicks within step range
                var minTicks = self.flow.flow.steps[0].rrTicks
                var maxTicks = minTicks
                for step in self.flow.flow.steps:
                  if step.rrTicks < minTicks: minTicks = step.rrTicks
                  if step.rrTicks > maxTicks: maxTicks = step.rrTicks
                newTicks >= minTicks and newTicks <= maxTicks
              else:
                # DB trace (rrTicks=0): use source-line range
                var minPos = self.flow.flow.steps[0].position
                var maxPos = minPos
                for step in self.flow.flow.steps:
                  if step.position < minPos: minPos = step.position
                  if step.position > maxPos: maxPos = step.position
                response.location.line >= minPos and response.location.line <= maxPos
        if canReuseFlow:
          discard  # FlowComponent.onCompleteMove (below) handles in-place update
        else:
          self.loadFlow(FlowMode.Call, response.location)
        self.shouldLoadFlow = false
        self.hasPendingFlowLocation = false

    elif self.supportsFlow() and not self.flow.isNil:
      if isShield:
        clog cstring("[NSS-1.64] EditorVC.onCompleteMove: elif branch -- redrawFlow only (no fresh fetch)")
      self.flow.redrawFlow()
      self.adjustEditorWidth()

  if self.data.trace.lang != LangRubyDb:
    discard data.services.debugger.loadParsedExprs(self.service.currentLine, response.cLocation.path)

  if not self.flow.isNil:
    discard self.flow.onCompleteMove(response)

  # For IsoNim-mounted editors, run the after-redraw work directly
  # since the legacy renderer entry has been removed and redrawAll() will not
  # reach this component's afterRedraws callbacks.
  if isoNimEditorMountedIds.hasKey(self.id):
    self.editorAfterRedraw()

  self.data.redraw()

proc onSelectFlow*(data: Data) {.async.} =
  await data.ui.editors[data.services.editor.active].flow.select()

proc onSelectState*(data: Data) {.async.} =
  await data.ui.componentMapping[Content.State][0].select()

method onEnter*(self: EditorViewComponent) {.async.} =

  console.log("This gonn get nasty")
  var editor = self.monacoEditor

  if self.data.ui.readOnly and editor.hasTextFocus():
    let line = editor.getLine()
    var flow = self.flow

    if not flow.isNil and flow.selected and flow.selectedStepCount != -1:
      flow.openValue(flow.selectedStepCount, cstring"", before=true)
      discard
    else:
      if data.services.editor.activeTabInfo().changed:
        cwarn("TAB IS EDITED, DOING NOTHING")
      else:
        self.toggleTrace(self.name, line)


  elif self.data.ui.readOnly:
    let line = editor.getLine()
    let code = self.traces[line].monacoEditor.getValue()
    let lineCount = code.split("\n").len()
    let lineHeight = cast[int](self.traces[line].monacoEditor.getOption(LINE_HEIGHT))

    self.traces[line].lineCount = lineCount
    self.traces[line].expandWithEnter(lineCount * lineHeight)
    self.traces[line].monacoEditor.insertTextAtCurrentPosition("\n")

    discard setTimeout(proc() =
      self.traces[line].monacoEditor.toJs.getDomNode().querySelector("textarea").focus(),
      1
    )
    data.ui.activeFocus = self.traces[line]

method onUpdatedFlow*(self: EditorViewComponent, update: FlowUpdate) {.async.} =
  if not self.flow.isNil:
    await self.flow.onUpdatedFlow(update)
    self.adjustEditorWidth()
    # #594: this is the moment the conditional-branch data actually becomes
    # paintable. `onCompleteMove` ran `editorAfterRedraw` synchronously back
    # when `self.flow.flow` was still nil, so the flow decoration layer was
    # merely RETAINED there; nothing in `FlowComponent.onUpdatedFlow` applies
    # line styles. Without this call the colours only ever reappeared by
    # accident, on a later move that happened not to trigger a flow reload.
    self.applyEventualStylesLines()
