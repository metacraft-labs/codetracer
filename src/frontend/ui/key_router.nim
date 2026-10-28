## key_router.nim — PLAT-68: THE DESKTOP'S KEYS THROUGH THE ONE ROUTER.
##
## Base-Keymaps-And-Layer-Stack.md §6: the keymaps and the user's
## `keybindings.json` are shared by every front-end; how a key reaches them is
## the front-end's. On the desktop that is ONE capture-phase `keydown`
## listener on the window — before Monaco, before any panel — which:
##
##   1. names the key (`common/key_event_names.canonicalKeyOfDom`, the
##      desktop's one decoder);
##   2. reads the SCOPE PATH off the DOM's own focus chain: the focused
##      element and its ancestors, each scope element carrying
##      `data-scope-kind` / `data-scope-id` (the document, every GoldenLayout
##      pane, the Monaco editor, the palette and its field — stamped where
##      those are created) — and a focused native text field no view
##      stamped as an input element of its own (`withNativeTextField`), so
##      a field's keys are never a list pane's. Inside the editor element
##      only the editor's own text area stays the editor's: Monaco's find
##      widget and a tracepoint editor are fields like any other;
##   3. resolves it with the shared `KeymapRouter` — the active base, the
##      user's rows, the pushed layers (the palette while it is open);
##   4. runs the operation, ONCE: a `ClientAction` the desktop already
##      implements (`client_actions`), an editing operation through the
##      Monaco command that performs it (`MonacoOperations`), or one of the
##      few operations the desktop performs directly — and then stops the
##      event, so Monaco's and the page's own bindings never answer the same
##      key a second time. A key the router does not resolve, a character,
##      and the operations a DOM element performs natively (a field's
##      editing keys, the palette's and Monaco's find widget's own) are left
##      alone.
##
## The menus, the toolbar's tooltips and the shortcuts dialog show the chord
## that RUNS an action here (`chordForAction`, the router's `chordFor`), so a
## rebinding is shown the moment it loads.
##
## This replaced the Mousetrap binding table, the hard-bound chords beside it
## and the Monaco `commands` table — three registries that disagreed (one key
## running two actions by focus, `F2` swallowed, F-keys dispatched twice).

import ui_imports

import std/[tables, options]
import isonim/core/signals

import ../viewmodel/keymap/[keymap_router, user_keymap, client_actions,
                            operation_catalogue, scope_path, context_keys,
                            editing_keymap, keymap_importers]
import ../../common/[key_event_names, ct_event]
import ../dap
import ./shortcut_preference
import ./chord_display
import ./monaco_operations
import ./native_key_operations
import ./editor_scope
import ./video_player   # `videoPlayerHasFocus`, `currentVideoPlayerVM`
import ./menu_keys
import ../viewmodel/keymap/alt_tap
from ../viewmodel/viewmodels/omnibar_vm import paletteFieldOf
import ../../common/key_names
import ../viewmodel/viewmodels/video_player_vm
from ../viewmodel/views/list_scrubber_dom import viewOperation
from ../viewmodel/views/context_menu_bridge import contextMenuIsOpen,
                                                  contextMenuOperation
# PLAT-70 Part B (Horizontal-Overflow.md §5): the table panes' detail, copy
# and column widths.
import ../viewmodel/views/table_overflow_dom

type
  NativeKind = enum
    nkLeaveToElement   ## the DOM element performs it itself
    nkHandled          ## performed here: the event is stopped

const
  KeybindingsMessage = cstring"CODETRACER::keybindings"



proc browserPlatform(): PlatformKind =
  ## The visitor's platform, read from the browser: the renderer is one
  ## bundle served to every platform, so a compile-time answer would be the
  ## BUILDER's (`shortcuts.isMacPlatform`'s reason).
  var mac, win = false
  {.emit: [mac, """ = /Mac|iPhone|iPad|iPod/.test(
    (typeof navigator !== 'undefined' &&
     (navigator.platform || navigator.userAgent)) || '');""", "\n",
           win, """ = /Win/.test(
    (typeof navigator !== 'undefined' &&
     (navigator.platform || navigator.userAgent)) || '');"""].}
  if mac: pkMac elif win: pkWindows else: pkLinux

type
  ChordMemo = object
    ## The chords `chordForAction` answered, valid while everything the
    ## answer depends on is unchanged: the router's rows (by generation), its
    ## base and pushed layers, the ViewModels' facts and the scope path. The
    ## program menu is rebuilt on every redraw — every move, every tab switch
    ## — and asks for each item's chord; resolving them afresh each time blocked
    ## the window for seconds per move on a Noir trace (#784).
    valid: bool
    generation: int
    base: BaseKeymap
    imported: bool
    stack: LayerStack
    facts: SessionFacts
    path: ScopePath
    lookup: ChordLookup
    chords: Table[string, string]

var
  deskRouter: KeymapRouter = initKeymapRouter(bkCua, KeyDelivery(
    # The web studio is its own front-end (`frontEnd == web` rows: its Run
    # and Export, CUA-Keymap.md §3.7); Electron is the desktop.
    frontEnd: (when defined(ctWeb): feWeb else: feDesktop),
    platform: browserPlatform(), keyProtocol: kpNative))
  installed = false
  hostOperations = initTable[string, proc()]()
    ## Operations a build performs itself (`registerHostOperation`): the web
    ## studio's Run and Export.
  keymapGeneration = 0
    ## Bumped whenever `deskRouter`'s rows change (`applyKeybindingsText`), so
    ## `chordForAction`'s memo knows its answers are stale.
  chordMemo: ChordMemo
    ## `chordForAction`'s answers for the state they were computed in.
  keybindingsNotes*: seq[string] = @[]
    ## What the last `keybindings.json` load said (errors, shadows, the
    ## import's summary) — shown by the shortcuts dialog.
  onKeymapChanged*: proc() = nil
    ## Set by the host (`ui_js`): the menus and tooltips re-read their
    ## chords.
  toggleSidePanelsHook*: proc(data: Data) = nil
    ## `ui/layout.toggleSidePanels`, installed by `ui_js` (the layout reaches
    ## the editor, which reaches this module, so it cannot be imported here).
  toggleMacroExpansionHook*: proc(editor: EditorViewComponent) = nil
    ## `ui/editor.toggleMacroExpansion`, installed by `ui_js` likewise.
  editorJumpHook*: proc(editor: EditorViewComponent; operation: string): bool = nil
  resizeEventLogColumnHook*: proc(arg: string) = nil
    ## PLAT-70 Part B: `ui/event_log.resizeEventLogColumn`
    ## (`table.resize-column`), installed by `ui_js` likewise.
    ## `ui/editor.runEditorJump` (the caret's smart jump, run to cursor and
    ## call jump), installed by `ui_js` likewise.

proc activeElementJs(): JsObject {.importjs: "(document.activeElement)@".}

proc focusedEditorView(): EditorViewComponent =
  ## The editor view that holds the focus — its `.code-editor` element (the
  ## scope path's editor element) or the Monaco instance inside it — or nil.
  if data.isNil or data.ui.isNil or data.ui.editors.isNil:
    return nil
  let active = activeElementJs()
  for _, editor in data.ui.editors:
    if editor.isNil or editor.monacoEditor.isNil:
      continue
    if editor.monacoEditor.hasTextFocus():
      return editor
    let view = editorScopeElement(editor.monacoEditor)
    if not view.isNil and not view.isUndefined and not active.isNil and
       view.contains(active).to(bool):
      return editor
  nil

proc focusedMonaco(): MonacoEditor =
  ## The Monaco instance the caret is in, or nil.
  let editor = focusedEditorView()
  if editor.isNil: nil else: editor.monacoEditor

proc scopeChainOf(start: JsObject): seq[ScopeElement] =
  ## The scope elements from the document down to `start`.
  var node = start
  var reversed: seq[ScopeElement] = @[]
  while not node.isNil and not node.isUndefined:
    let getAttr = node[cstring"getAttribute"]
    if not getAttr.isNil and not getAttr.isUndefined:
      let kind = node.getAttribute(cstring"data-scope-kind")
      if not kind.isNil and not kind.isUndefined:
        let id = node.getAttribute(cstring"data-scope-id")
        reversed.add elementOfAttributes($kind.to(cstring),
          (if id.isNil or id.isUndefined: "" else: $id.to(cstring)))
    node = node[cstring"parentNode"]
  for i in countdown(reversed.high, 0):
    result.add reversed[i]

proc focusInWritableMonaco(): bool {.importjs: """
  (function(){
    const a = document.activeElement;
    const m = globalThis.monaco;
    if (!a || !m || !m.editor || typeof m.editor.getEditors !== 'function')
      return false;
    const ro = m.editor.EditorOption ? m.editor.EditorOption.readOnly
                                     : undefined;
    return m.editor.getEditors().some(e => {
      const node = e.getDomNode();
      return !!node && node.contains(a) &&
             !(ro !== undefined && e.getOption(ro));
    });
  })()""".}
  ## Whether the focus is inside a WRITABLE Monaco instance — the editor in
  ## Edit mode, or one nested in the read-only editor (a tracepoint editor).
  ## Asked of the instances' DOM nodes, not of `hasTextFocus()`, so that it
  ## holds for every element inside a writable instance and not only for
  ## its text input: wherever inside the field the focus is, the field's
  ## keys stay its own. `monaco.editor.getEditors` lists every instance
  ## (https://microsoft.github.io/monaco-editor/typedoc/functions/editor.getEditors.html).

proc focusedFieldFactsOf(active: JsObject): FocusedFieldFacts =
  ## What `withNativeTextField` needs to know about the focused DOM element.
  ## `type` is read as the PROPERTY, which the DOM normalises (lower case,
  ## `text` for a missing or unknown attribute; `textarea` on a textarea), so
  ## `<input>` with no type and `<input type="TEXT">` read alike.
  if active.isNil or active.isUndefined:
    return FocusedFieldFacts()
  proc str(v: JsObject): string =
    if v.isNil or v.isUndefined: "" else: $v.to(cstring)
  proc flag(v: JsObject): bool =
    not v.isNil and not v.isUndefined and v.to(bool)
  let editable = active[cstring"isContentEditable"]
  let getAttr = active[cstring"hasAttribute"]
  let monaco = focusedMonaco()
  FocusedFieldFacts(
    tagName: str(active[cstring"tagName"]),
    inputType: str(active[cstring"type"]),
    contentEditable: not editable.isNil and not editable.isUndefined and
                     editable.to(bool),
    id: str(active[cstring"id"]),
    carriesScope: not getAttr.isNil and not getAttr.isUndefined and
                  active.hasAttribute(cstring(ScopeKindAttribute)).to(bool),
    readOnly: flag(active[cstring"readOnly"]),
    disabled: flag(active[cstring"disabled"]),
    monacoText: focusInWritableMonaco(),
    editorText: not monaco.isNil and monaco.hasTextFocus())

proc desktopScopePath*(): ScopePath =
  ## **THE DESKTOP'S SCOPE PATH** (§6.2), read off the DOM focus chain. The
  ## document is the window element; a focus on `<body>` (nothing focused
  ## yet) is the window alone. The open palette replaces the chain below the
  ## window, as the native producers' overlays do.
  let window = element(ekWindow, "window")
  if not data.isNil and not data.ui.isNil and
     not data.ui.commandPalette.isNil and data.ui.commandPalette.active:
    let line = data.ui.commandPalette.inputValue
    return @[window, element(ekOverlay, "palette"),
             paletteFieldOf(if line.isNil: "" else: $line)]
  let active = activeElementJs()
  let chain = scopeChainOf(active)
  result = @[window]
  for e in chain:
    if e.kind != ekWindow: result.add e
  # A text field no view stamped (the Agent Activity prompt before it was,
  # a filter box, xterm's helper textarea) is still an input element
  # (§4.2's `textInputFocus`), so its keys reach it: without this the pane
  # was the focus, and a list pane's `Enter` / arrows / letters were run here
  # and the key stopped (`scope_path.withNativeTextField`).
  result = withNativeTextField(result, focusedFieldFactsOf(active))

proc desktopFacts(): SessionFacts =
  ## The ViewModels' facts, from this renderer's state.
  let editMode = not data.isNil and not data.ui.isNil and
                 data.ui.mode == EditMode
  let readOnly = data.isNil or data.ui.isNil or data.ui.readOnly
  var editor = if readOnly: sourceViewFacts()
               else: EditorFacts(readOnly: false, mode: emInsert)
  let monaco = focusedMonaco()
  if not monaco.isNil:
    let sel = monaco.toJs.getSelection()
    if not sel.isNil:
      editor.hasSelection = not sel.isEmpty().to(bool)
  SessionFacts(product: (if editMode: pmEdit else: pmDebug),
               replayLoaded: not data.isNil and not data.trace.isNil,
               editor: editor,
               paletteVisible: not data.isNil and not data.ui.isNil and
                               not data.ui.commandPalette.isNil and
                               data.ui.commandPalette.active)

proc syncPaletteLayer() =
  ## The palette's table is pushed exactly while the palette is open.
  let open = desktopFacts().paletteVisible
  let at = deskRouter.stack.indexOfLayer(PaletteTable, "window")
  if open and at < 0:
    discard deskRouter.pushLayer(PaletteTable, "window", "PALETTE")
  elif not open and at >= 0:
    discard deskRouter.popLayer(deskRouter.stack.layers[at].token)

proc syncContextMenuLayer() =
  ## The right-click menu's table is pushed exactly while the menu shows, as
  ## the terminal and GPUI push theirs (CUA-Keymap.md §3.8: once open, the
  ## menu takes the arrows, `Enter` and `Escape`). Without it `Escape` over a
  ## list pane resolved to the pane's `list.clear-selection`, which ran and
  ## stopped the event, so the menu stayed open, and the arrows moved the
  ## list under the menu.
  let open = contextMenuIsOpen()
  let at = deskRouter.stack.indexOfLayer(ContextMenuTable, "window")
  if open and at < 0:
    discard deskRouter.pushLayer(ContextMenuTable, "window", "MENU")
  elif not open and at >= 0:
    discard deskRouter.popLayer(deskRouter.stack.layers[at].token)

proc runAction(action: string): bool =
  ## A `ClientAction` by name, through the table every desktop surface
  ## (menu, toolbar) calls. Answers whether there was one to run.
  try:
    let a = parseEnum[ClientAction](action)
    let handler = data.actions[a]
    if handler.isNil:
      return false
    handler(nil)
    true
  except ValueError:
    false

proc runMonaco(operation: string): bool =
  ## The editing operation as the focused editor's Monaco command. The caret
  ## goes into Monaco first when the focus is on the editor view around it
  ## (where a press on the read-only text leaves it).
  let monaco = focusedMonaco()
  if monaco.isNil or not MonacoOperations.hasKey(operation):
    return false
  if not monaco.hasTextFocus():
    monaco.toJs.focus()
  monaco.toJs.trigger(cstring"keyboard", cstring(MonacoOperations[operation]),
                      js{})
  true

proc dispatchShowValueOrigin*() =
  ## `editor.jump-to-value-origin` on the desktop — `Ctrl+Shift+O`, and `o`
  ## in the read-only editor: the focused editor's selection (or the word at
  ## the caret) sent as a `ct/originChain` request, as the right-click "Show
  ## value origin" entry does (`ui/value.nim`).
  if data.isNil or data.activeSessionIndex < 0:
    return
  var expression: cstring = cstring""
  let activeEditorName = data.services.editor.active
  if not activeEditorName.isNil and data.ui.editors.hasKey(activeEditorName):
    let editor = data.ui.editors[activeEditorName]
    if not editor.isNil and not editor.monacoEditor.isNil:
      let monacoEditor = editor.monacoEditor
      let model = monacoEditor.toJs.getModel()
      let selection = monacoEditor.toJs.getSelection()
      if not selection.isNil:
        let selected = cast[cstring](model.getValueInRange(selection))
        if ($selected).strip().len > 0:
          expression = selected
      if expression.len == 0:
        let position = monacoEditor.toJs.getPosition()
        if not position.isNil:
          let wordInfo = model.getWordAtPosition(position)
          if not wordInfo.isNil:
            expression = cast[cstring](wordInfo.word)
  if expression.len == 0:
    cwarn "shortcuts: Show Value Origin — no editor selection or word under " &
          "the cursor; ignoring"
    return
  let args = js{
    variableName: expression,
    variablePath: [],
    frameId: -1,
    stepId: -1,
    threadId: 0,
    maxHops: 16,
    lazy: false,
    sessionId: "",
    classifySource: true,
  }
  data.dapApi.sendCtRequest(CtOriginChain, args)

# The Video Player pane's OWN keys while it has the focus (Visual-Replay.md
# §Keyboard Shortcuts) — a pane's keys, like the terminal's Terminal Output
# pane's, asked before the router; a key it does not take goes on to it.
const VideoPlayerKeys = {
  "Space": ClientAction.videoPlayerTogglePlay,
  "k": ClientAction.videoPlayerTogglePlay,
  "j": ClientAction.videoPlayerRewind,
  "l": ClientAction.videoPlayerFastForward,
  "Left": ClientAction.videoPlayerStepFrameBack,
  "Right": ClientAction.videoPlayerStepFrameForward,
  "Shift+Left": ClientAction.videoPlayerStepDrawBack,
  "Shift+Right": ClientAction.videoPlayerStepDrawForward,
  "Home": ClientAction.videoPlayerJumpStart,
  "End": ClientAction.videoPlayerJumpEnd,
  "p": ClientAction.videoPlayerTogglePicker}.toTable

proc videoPlayerKey(name: string): bool =
  ## Whether the focused Video Player took `name`. `Esc` is its only while
  ## the pixel picker is active.
  if not videoPlayerHasFocus():
    return false
  if name == "Esc":
    let vm = currentVideoPlayerVM()
    if vm.isNil or vm.pickerState.val != PickerActive:
      return false
    data.actions[ClientAction.videoPlayerCancelPicker](nil)
    return true
  if not VideoPlayerKeys.hasKey(name):
    return false
  let handler = data.actions[VideoPlayerKeys[name]]
  if not handler.isNil:
    handler(nil)
  true

proc traceOperation(op: string) =
  ## Every operation the router resolved, in order, on
  ## `window.__ctKeyTrace` — the desktop's counterpart of the terminal's
  ## status line and GPUI's gesture trace, which is what the Electron specs
  ## read to say a key ran ONE operation.
  let entry = cstring(op)
  {.emit: ["(window.__ctKeyTrace = window.__ctKeyTrace || []).push(",
           entry, ");"].}

proc focusedOutputScroller(): JsObject {.importjs: """
  (function(){
    const a = document.activeElement;
    const pane = a && a.closest ? a.closest('[data-scope-kind="pane"]') : null;
    if (!pane) return null;
    const id = pane.getAttribute('data-scope-id');
    let el = null;
    if (id === 'terminalOutput')
      el = pane.querySelector('.isonim-terminal-output > pre');
    else if (id === 'buildOutput')
      el = pane.querySelector('.build-output-container');
    else if (id === 'eventLog' || id === 'calltrace' || id === 'state') {
      const fit = pane.querySelector('[data-ct-fit="scroll"]');
      if (fit)
        el = fit.querySelector(':scope > .eventLog-scroll-body') || fit;
    }
    return el && el.clientHeight > 1 ? el : null;
  })()""".}
  ## PLAT-70: the scroll container of the focused output pane — the
  ## Terminal Output's LINE view (its screen view has no bar and keeps its
  ## step-by-write arrows) or Build Output's lines — or, PLAT-70 Part I, a
  ## focused table pane's while its columns SCROLL (the Event Log's body,
  ## the Call Trace's and the State pane's scroll boxes) — or nil.

proc tableScrollerOf(paneKind: cstring): JsObject {.importjs: """
  (function(id){
    const pane = document.querySelector(
      '[data-scope-kind="pane"][data-scope-id="' + id + '"]');
    if (!pane) return null;
    const fit = pane.querySelector('[data-ct-fit="scroll"]');
    if (!fit) return null;
    const el = fit.querySelector(':scope > .eventLog-scroll-body') || fit;
    return el && el.clientHeight > 1 ? el : null;
  })(#)""".}
  ## PLAT-70 Part I: a table pane's sideways scroll container while its
  ## columns SCROLL (`data-ct-fit="scroll"`), or nil.

proc registerHostOperation*(operation: string; run: proc()) =
  ## How THIS build performs `operation` — a catalogued operation whose rows
  ## hold only where a build supplies it (the web studio's
  ## `build.run-program` and `project.export`, `frontEnd == web`).
  hostOperations[operation] = run

func selectedRowSelectorOf(pane: string): cstring =
  ## The selector of a table pane's selected row ("" for the Variables pane,
  ## which marks none: its row is the one last pressed). PLAT-70 Part I: the
  ## Call Trace is a table pane on the desktop too (its rows are cut at the
  ## pane, Horizontal-Overflow.md §5.5.5).
  if pane == EventLogDetailPane: cstring"tr.event-selected"
  elif pane == CallTraceTablePane: cstring".calltrace-call-line.event-selected"
  else: cstring""

proc focusedTablePane(): tuple[pane: string; selected: cstring] =
  ## The table pane the focus is in — its name in a `DetailToggle` and the
  ## selector of its selected row — else the one last pressed (the palette
  ## holds the focus while one of its entries runs), else ("", "").
  for e in desktopScopePath():
    let pane = case e.paneKind
               of "state": StateDetailPane
               of "eventLog": EventLogDetailPane
               of "calltrace": CallTraceTablePane
               else: ""
    if pane.len > 0:
      return (pane, selectedRowSelectorOf(pane))
  if lastPressedTablePane.len > 0:
    return (lastPressedTablePane, selectedRowSelectorOf(lastPressedTablePane))
  ("", cstring"")

proc runTableOperation(res: EditingResolution): bool =
  ## PLAT-70 Part B: `list.show-detail` and `list.copy` on the focused table
  ## pane's row (its WHOLE text), `table.resize-column` on the Event Log.
  let (pane, selected) = focusedTablePane()
  case res.operation
  of "list.show-detail":
    if pane.len == 0 or not showDetailOf(pane, selected):
      cwarn "keys: Show Detail works in the Variables, Event Log and Call " &
            "Trace panes, on a row"
    true
  of "list.copy":
    pane.len > 0 and copyRowOf(pane, selected)
  of "table.resize-column":
    if not resizeEventLogColumnHook.isNil:
      resizeEventLogColumnHook(res.argument)
    true
  of "view.scroll-left", "view.scroll-right":
    # PLAT-70 Part I (Horizontal-Overflow.md §5.5): from the palette — which
    # holds the focus while its entry runs — the table pane last focused or
    # pressed, while its columns scroll; else the focused output pane.
    let id = if pane == EventLogDetailPane: "eventLog"
             elif pane == CallTraceTablePane: "calltrace"
             elif pane == StateDetailPane: "state"
             else: ""
    var scroller = if id.len > 0: tableScrollerOf(cstring(id)) else: nil
    if scroller.isNil:
      scroller = focusedOutputScroller()
    if scroller.isNil:
      cwarn "keys: `" & res.operation & "` scrolls an output pane, or a " &
            "table pane whose columns do not fit"
    else:
      discard viewOperation(scroller, res.operation)
    true
  else: false

proc runDesktopOperation(res: EditingResolution): NativeKind

proc runPaletteOperation*(operation, argument: string) =
  ## A palette entry's catalogued operation (PLAT-70 Part B: **Show Detail**,
  ## **Widen Column**, **Narrow Column**), run as a key's would be.
  traceOperation(if argument.len > 0: operation & "(" & argument & ")"
                 else: operation)
  discard runTableOperation(EditingResolution(kind: erOperation,
                                              operation: operation,
                                              argument: argument))

proc runDesktopOperation(res: EditingResolution): NativeKind =
  ## **THE DESKTOP'S DISPATCH** of a resolved operation.
  let op = if res.argument.len > 0: res.operation & "(" & res.argument & ")"
           else: res.operation
  traceOperation(op)
  if hostOperations.hasKey(res.operation):
    hostOperations[res.operation]()
    return nkHandled
  # The right-click menu's operations are performed here rather than left
  # to the menu: it is a plain `<div>` that never takes the focus, so no
  # element under the focus would move its highlight, choose or close it.
  if contextMenuIsOpen() and contextMenuOperation(res.operation):
    return nkHandled
  # The DOM element's own operations stay its own.
  if res.isNativeBaseOperation:
    return nkLeaveToElement
  if res.operation in HostIntents:
    if not data.functions.update.isNil: data.functions.update(data, false)
    return nkHandled
  if runTableOperation(res):
    return nkHandled
  if runMonaco(res.operation):
    return nkHandled
  if '.' notin res.operation:
    cwarn "keys: `" & op & "` is not available in this editor"
    return nkLeaveToElement
  case res.operation
  of "editor.toggle-tracepoint":
    # The desktop's `Enter` on a line of the read-only editor
    # (`EditorViewComponent.onEnter`): the tracepoint editor on that line.
    let editor = focusedEditorView()
    if not editor.isNil:
      if not editor.monacoEditor.hasTextFocus():
        editor.monacoEditor.toJs.focus()
      discard editor.onEnter()
    return nkHandled
  of "editor.toggle-macro-expansion":
    # No default chord (CUA-Keymap §5 gave `Alt+E` to the event log); a
    # user's row reaches the active editor's toggle.
    let active = data.services.editor.active
    if data.ui.editors.hasKey(active) and not toggleMacroExpansionHook.isNil:
      toggleMacroExpansionHook(data.ui.editors[active])
    return nkHandled
  of "layout.toggle-side-panels":
    if not toggleSidePanelsHook.isNil: toggleSidePanelsHook(data)
    return nkHandled
  of "debugger.smart-jump", "debugger.run-to-cursor",
     "debugger.source-call-jump":
    let editor = focusedEditorView()
    if not editor.isNil and not editorJumpHook.isNil and
       editorJumpHook(editor, res.operation):
      return nkHandled
  of "editor.jump-to-value-origin":
    dispatchShowValueOrigin()
    return nkHandled
  of "debugger.step-over-statement":
    if not data.services.debugger.isNil: data.services.debugger.stepOverStatement()
    return nkHandled
  of "debugger.reverse-step-over-statement":
    if not data.services.debugger.isNil: data.services.debugger.stepBackStatement()
    return nkHandled
  of "layout.focus-pane":
    # The three panes the desktop focuses directly (the old `Alt+E` /
    # `Alt+C` / `Alt+V`); the others through their View-menu action.
    case res.argument
    of "event-log":
      if not data.functions.focusEventLog.isNil: data.functions.focusEventLog(data)
      return nkHandled
    of "call-trace":
      if not data.functions.focusCalltrace.isNil: data.functions.focusCalltrace(data)
      return nkHandled
    of "editor":
      if not data.functions.focusEditorView.isNil: data.functions.focusEditorView(data)
      return nkHandled
    else: discard
  of "layout.focus-pane-by-index":
    try:
      discard data.ui.activeFocus.onCtrlNumber(parseInt(res.argument))
    except ValueError:
      discard
    return nkHandled
  of "session.re-record":
    data.reRecordCurrent(projectOnly = false)
    return nkHandled
  of "menu.open", "menu.toggle", "menu.open-folder":
    if not menuAccess.operation.isNil:
      menuAccess.operation(res.operation, res.argument)
      return nkHandled
  of "session.toggle-product-mode":
    if not data.functions.toggleMode.isNil: data.functions.toggleMode(data)
    return nkHandled
  of "view.scroll-left", "view.scroll-right", "view.scroll-left-half",
     "view.scroll-right-half", "view.scroll-to-line-start":
    # PLAT-70 (Horizontal-Overflow.md §4.4): the output panes' view, through
    # the shared model (`list_scrubber_dom.viewOperation`). Outside a line
    # view the key is the element's own (the screen view's write steps).
    let scroller = focusedOutputScroller()
    if scroller.isNil:
      return nkLeaveToElement
    discard viewOperation(scroller, res.operation)
    return nkHandled
  else: discard
  let action = clientActionOf(op)
  if action.len > 0 and runAction(action):
    return nkHandled
  cwarn "keys: `" & op & "` (" & operationLabelOf(res.operation) &
        ") is not available on the desktop"
  nkLeaveToElement

var deskAltTap: AltTap
  ## Whether the press of `Alt` in progress is still a tap (`alt_tap`).

const ModifierKeys = ["Alt", "Shift", "Control", "Meta"]
  ## `KeyboardEvent.key` of a modifier pressed or released on its own.

proc heldModifiers(ev: JsObject): KeyModifiers =
  ## The modifiers held AFTER this event (on `keyup` of `Alt`, `altKey` is
  ## already false).
  if ev.ctrlKey.to(bool): result.incl kmodCtrl
  if ev.shiftKey.to(bool): result.incl kmodShift
  if ev.altKey.to(bool): result.incl kmodAlt
  if ev.metaKey.to(bool): result.incl kmodMeta

proc stop(ev: JsObject) =
  discard ev.preventDefault()
  discard ev.stopImmediatePropagation()

proc routeKey(name: string; ev: JsObject) =
  ## One canonical key through the router, run once, the event stopped when
  ## it was run.
  syncPaletteLayer()
  syncContextMenuLayer()
  let path = desktopScopePath()
  let facts = desktopFacts()
  # An open program menu owns its keys, as on the terminal and GPUI; the
  # keymap's menu keys keep their meaning there (CUA-Keymap.md §3.8).
  if menuIsOpen():
    var probe = deskRouter
    let res = probe.route(facts, path, nmNormal, name, int64(now()))
    if res.kind == erOperation and res.operation in MenuOperations:
      traceOperation(if res.argument.len > 0:
                       res.operation & "(" & res.argument & ")"
                     else: res.operation)
      menuAccess.operation(res.operation, res.argument)
      stop(ev)
      return
    if menuAccess.key(name):
      stop(ev)
      return
  let res = deskRouter.route(facts, path, nmNormal, name, int64(now()))
  var handled = false
  case res.kind
  of erPending:
    handled = true
  of erOperation:
    handled = runDesktopOperation(res) == nkHandled
  of erCharacter, erNothing:
    discard
  if handled:
    stop(ev)

proc onKeyDown(ev: JsObject) =
  ## The ONE key listener (capture phase, on the window).
  if ev[cstring"isComposing"].to(bool):
    return
  let key = $ev.key.to(cstring)
  if key in ModifierKeys:
    discard deskAltTap.modifiersChanged(heldModifiers(ev))
    return
  # Any other key while Alt is held makes it a chord, not a tap.
  deskAltTap.interrupted()
  let name = canonicalKeyOfDom(key, $ev.code.to(cstring),
                               ev.ctrlKey.to(bool), ev.shiftKey.to(bool),
                               ev.altKey.to(bool), ev.metaKey.to(bool))
  if name.len == 0:
    return
  if videoPlayerKey(name):
    stop(ev)
    return
  routeKey(name, ev)

proc onKeyUp(ev: JsObject) =
  ## A modifier released: `Alt` pressed and released ALONE is the key `Alt`
  ## (VS Code's menu-bar gesture, CUA-Keymap.md §3.8).
  let key = $ev.key.to(cstring)
  if key notin ModifierKeys:
    return
  if deskAltTap.modifiersChanged(heldModifiers(ev)):
    routeKey("Alt", ev)

proc onPointerDown(ev: JsObject) =
  deskAltTap.interrupted()       # Alt+click is not Alt tapped

proc onWindowBlur(ev: JsObject) =
  deskAltTap.reset()             # a release may never be reported
  deskRouter.cancelPending()     # the next key, on return, starts afresh

proc applyKeybindingsText*(text: string; notes: seq[string] = @[]) =
  ## The user's `keybindings.json` (as the main process read it), laid over
  ## the base. What did not load is kept for the shortcuts dialog and said
  ## on the console.
  deskRouter.applyUserKeymap(parseUserKeymap(text))
  inc keymapGeneration
  keybindingsNotes = notes
  if deskRouter.errors.len > 0:
    keybindingsNotes.add deskRouter.loadSummary
  for note in keybindingsNotes:
    cwarn "keybindings: " & note
  if not onKeymapChanged.isNil:
    onKeymapChanged()

proc chordForAction*(action: ClientAction): cstring =
  ## THE CHORD TO SHOW for `action` — the one that runs it where the focus
  ## is now (KL-8). "" when no key reaches it.
  let op = operationOfClientAction($action)
  if op.len == 0:
    return cstring""
  let facts = desktopFacts()
  let path = desktopScopePath()
  if not (chordMemo.valid and chordMemo.generation == keymapGeneration and
          chordMemo.base == deskRouter.base and
          chordMemo.imported == deskRouter.hasImported and
          chordMemo.stack == deskRouter.stack and chordMemo.facts == facts and
          chordMemo.path == path):
    chordMemo = ChordMemo(
      valid: true, generation: keymapGeneration, base: deskRouter.base,
      imported: deskRouter.hasImported, stack: deskRouter.stack,
      facts: facts, path: path,
      lookup: initChordLookup(deskRouter, facts, path, nmNormal),
      chords: initTable[string, string]())
  if not chordMemo.chords.hasKey(op):
    let (name, arg) = splitOperation(op)
    chordMemo.chords[op] = chordMemo.lookup.chordFor(deskRouter, name, arg)
  cstring(chordMemo.chords[op])

chord_display.chordOfAction = chordForAction

proc testChordForAction(actionName: cstring): cstring =
  ## Read-only browser-test seam: ask the live router, including the user's
  ## rows and current scope, independently of any menu or tooltip's text.
  try:
    chordForAction(parseEnum[ClientAction]($actionName))
  except ValueError:
    cstring""

# PLAT-70 Part B: the copy hint under a table row names the chord that
# copies it where the focus is (KL-8).
copyChordOf = proc(): string =
  deskRouter.chordFor("list.copy", desktopFacts(), desktopScopePath(),
                      nmNormal, "")

proc importStoredPreset() =
  ## The ONE-TIME IMPORT of the old shortcuts dialog's stepping preset, which
  ## lives in this renderer's `localStorage`: handed to the main process,
  ## which merges it into `keybindings.json`.
  if presetImported():
    return
  let stored = storedPreset()
  if stored.isSome and not data.isNil and not data.ipc.isNil:
    data.ipc.send(cstring"CODETRACER::keybindings-import",
                  js{preset: cstring(stored.get)})
  markPresetImported()

proc installKeyRouter*() =
  ## Install the listener and wait for the user's keymap. Idempotent: the
  ## renderer's start-up paths may all call it.
  if installed:
    return
  installed = true
  {.emit: ["window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};",
           "window.__CODETRACER_TEST__.chordForAction = ", testChordForAction, ";"].}
  {.emit: ["window.addEventListener('keydown', ", onKeyDown, ", true);",
           "window.addEventListener('keyup', ", onKeyUp, ", true);",
           "window.addEventListener('mousedown', ", onPointerDown, ", true);",
           "window.addEventListener('blur', ", onWindowBlur, ");"].}
  if not data.isNil and not data.ipc.isNil:
    data.ipc.on(KeybindingsMessage, proc(event: JsObject; payload: JsObject) =
      var notes: seq[string] = @[]
      let raw = payload[cstring"notes"]
      if not raw.isNil and not raw.isUndefined:
        for n in raw:
          notes.add $n.to(cstring)
      applyKeybindingsText($payload[cstring"text"].to(cstring), notes))
    # Ask for the file now: the main process may have sent it before this
    # listener existed (it sends at the renderer's start-up handshake).
    data.ipc.send(cstring"CODETRACER::keybindings-request", js{})
    importStoredPreset()
