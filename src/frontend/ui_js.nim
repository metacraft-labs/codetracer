import
  async, strformat, strutils, sequtils, jsffi, algorithm, jsconsole, macros,
  karax, karaxdsl, kdom, vstyles,
  ui/[agent_activity, layout, editor, trace, events, event_log,
      state, calltrace, loading, start, menu,
      debug, flow, filesystem, value, repl,
      build, welcome_screen, point_list, scratchpad,
      trace_log, calltrace_editor, terminal_output, shell,
      no_source, ui_imports, shortcuts, step_list, low_level_code],
  lib/[ jslib ],
  types, lang, utils, renderer, config, dap,
  ../common/ct_logging,
  property_test / test,
  event_helpers

when defined(ctInExtension):
  import vscode

import vdom except Event
from dom import Element, getAttribute, Node, preventDefault, document,
                getElementById, querySelectorAll, querySelector

proc configureIPC(data: Data)

# IPC HANDLERS

var vex* {.importc.}: js
var middlewareConfigured = false
var dapReplayHandlerRegistered = false
const TAB_LIMIT = 20
const MIN_FONTSIZE = 10
const MAX_FONTSIZE = 18
const EDITOR_GUTTER_PADDING = 2 #px

var disconnectedNotification: Notification

proc connectionDetailMessage(reason: ConnectionLossReason, detail: cstring): cstring =
  if detail.len > 0:
    return detail
  connectionLossMessage(reason)

proc showDisconnectedWarning(data: Data, reason: ConnectionLossReason, detail: cstring) =
  let message = $connectionDetailMessage(reason, detail)
  let reconnectAction = newNotificationButtonAction(cstring"Reconnect", proc = domwindow.location.reload())

  if disconnectedNotification.isNil:
    disconnectedNotification = newNotification(
      NotificationKind.NotificationWarning,
      message,
      actions = @[reconnectAction]
    )
    data.viewsApi.showNotification(disconnectedNotification)
  else:
    disconnectedNotification.text = message
    disconnectedNotification.active = true
    disconnectedNotification.seen = false
    if not data.ui.isNil and not data.ui.status.isNil:
      data.ui.status.redraw()

proc clearDisconnectedWarning(data: Data) =
  if disconnectedNotification.isNil:
    return
  disconnectedNotification.active = false
  disconnectedNotification.seen = false
  if not data.ui.isNil and not data.ui.status.isNil:
    data.ui.status.redraw()

proc updateConnectionState(data: Data, connected: bool, reason: ConnectionLossReason, detail: cstring = cstring"") =
  data.connection.connected = connected
  data.connection.reason = reason
  data.connection.detail = detail

  if connected:
    clearDisconnectedWarning(data)
    if not data.ui.isNil and not data.ui.status.isNil:
      data.ui.status.redraw()
  else:
    showDisconnectedWarning(data, reason, detail)

proc connectionReasonFromPayload(reason: cstring): ConnectionLossReason =
  case $reason
  of "idle-timeout":
    ConnectionLossIdleTimeout
  of "superseded":
    ConnectionLossSuperseded
  else:
    ConnectionLossUnknown

when defined(ctmacos):
  proc registerMenu*(menu: MenuNode) =
    ipc.send("CODETRACER::register-menu", js{menu: menu})
else:
  proc registerMenu*(menu: MenuNode) = discard

proc `or`*(a: MenuNodeOS, b: MenuNodeOS): MenuNodeOS =
  return MenuNodeOS(ord(a) or ord(b))

proc `and`*(a: MenuNodeOS, b: MenuNodeOS): MenuNodeOS =
  return MenuNodeOS(ord(a) and ord(b))

proc defineMenuImpl(node: NimNode): (NimNode, bool) =
  case node.kind:
  of nnkCommand:
    let kindOriginal = node[0]
    let nameNode = node[1]
    var currentParent: MenuNode

    if kindOriginal.repr == "folder"                  or
       kindOriginal.repr == "macexclude_folder"       or
       kindOriginal.repr == "macfolder"               or
       kindOriginal.repr == "hostexclude_folder"      or
       kindOriginal.repr == "hostfolder"              or
       kindOriginal.repr == "mac_and_host_exclude_folder":

      var folderType: MenuNodeOS = MenuNodeOSAny;

      if kindOriginal.repr == "macfolder":
        folderType = folderType or MenuNodeOSMacOs

      if kindOriginal.repr == "macexclude_folder":
        folderType = folderType or MenuNodeOSNonMacOS

      if kindOriginal.repr == "hostfolder":
        folderType = folderType or MenuNodeOSHost

      if kindOriginal.repr == "hostexclude_folder":
        folderType = folderType or MenuNodeOSNonHost

      if kindOriginal.repr == "mac_and_host_exclude_folder":
        folderType = folderType or MenuNodeOSNonHost or MenuNodeOSNonMacOS

      var elementsNode: NimNode = quote do: @[]
      if node.len > 2:
        # One more entry for text labels
        let index = if bool(ord(folderType and MenuNodeOSMacOs)): 3 else: 2
        if node.len > index:
          for element in node[index]:
            let (element, isSeparator) = defineMenuImpl(element)
            if not isSeparator:
              elementsNode[1].add(element)
            else:
              elementsNode[1][^1].add(nnkExprColonExpr.newTree(ident"isBeforeNextSubGroup", newLit(true)))

      let tmpcstr = quote do: cast[cstring]("")
      let roleExpr: NimNode =
        if bool(ord(folderType and MenuNodeOSMacOs)):
          node[2]
        else:
          tmpcstr

      var r = quote:
        MenuNode(
          kind: MenuFolder,
          name: `nameNode`,
          elements: `elementsNode`,
          enabled: true,
          menuOs: `folderType`,
          role: `roleExpr`
        )
      result = (r, false)
    elif  kindOriginal.repr == "element"              or
          kindOriginal.repr == "macexclude_element"   or
          kindOriginal.repr == "macelement"           or
          kindOriginal.repr == "macrole"              or
          kindOriginal.repr == "hostexclude_element"  or
          kindOriginal.repr == "hostelement"          or
          kindOriginal.repr == "mac_and_host_exclude_element":

      var elementType: MenuNodeOS = MenuNodeOSAny;

      if kindOriginal.repr == "macelement" or kindOriginal.repr == "macrole":
        elementType = elementType or MenuNodeOSMacOs

      if kindOriginal.repr == "macexclude_element":
        elementType = elementType or MenuNodeOSNonMacOS

      if kindOriginal.repr == "hostelement":
        elementType = elementType or MenuNodeOSHost

      if kindOriginal.repr == "hostexclude_element":
        elementType = elementType or MenuNodeOSNonHost

      if kindOriginal.repr == "mac_and_host_exclude_element":
        elementType = elementType or MenuNodeOSNonHost or MenuNodeOSNonMacOS

      let bMacRole: bool = kindOriginal.repr == "macrole"
      if node.len < 3 and not bMacRole:
        macros.error "no action " & node.repr & " "

      # If it's a role, insert a random action. It will not get used anyway
      let actionNode = if not bMacRole: node[2] else: newLit(ClientAction.forwardContinue)
      let last = if node.len == 3 or bMacRole: newLit(true) else: node[^1]

      var r = quote:
        MenuNode(
          kind: MenuElement,
          name: `nameNode`,
          action: `actionNode`,
          elements: @[],
          enabled: `last`,
          menuOs: `elementType`,
          role: if bool(`bMacRole`): `nameNode` else: cast[cstring]("")
        )
      result = (r, false)
  of nnkPrefix:
    if node.repr == "--sub":
      result = (nil, true)
      return
  else:
    echo "menu: expect command or prefix " & $node.kind

macro defineMenu(code: untyped): untyped =
  ## defineMenu:
  ##   folder "menu":
  ##     element name, action, [enabled=MEnabled] or false or name of check
  ## =>
  ## MenuNode(
  ##   kind: MenuFolder, name: "menu", elements: @[
  ##     MenuNode(kind: MenuElement, name: name, action: action, enabled: true)])
  let menuNode = defineMenuImpl(code[0])[0]
  result = quote do:
    var m = `menuNode`
    when defined(ctmacos):
      registerMenu(m)
    m

proc webTechMenu(data: Data, program: cstring): MenuNode =
  let config = data.config
  if not data.startOptions.shellUi:
    defineMenu:
      folder program:
        # Needed for compliance on macOS
        macfolder "CodeTracer", "":
          macrole "about"
          --sub
          macrole "services"
          --sub
          macrole "hide"
          macrole "hideOthers"
          macrole "unhide"
          --sub
          macrole "quit"
        folder "File":
          # element "New File", newTab, false
          # element "Preferences", preferences
          # --sub
          # element "Open File", openFile
          # element "Open Folder", openFolder, false
          # element "Open Recent", openRecent, false
          # --sub
          # element "Save", aSave
          # element "Save As ...", saveAs
          # element "Save All", saveAll
          # --sub
          element "Close Current File", closeTab
          element "Reopen File", reopenTab
          element "Next File", switchTabRight
          element "Previous File", switchTabLeft
          element "Switch File", switchTabHistory
          --sub
          # element "Close All Documents", closeAllDocuments
          mac_and_host_exclude_element "Exit CodeTracer", aExit
        folder "Edit":
          # element "Undo", aUndo, false
          # element "Redo", aRedo, false
          # --sub
          # element "Cut", aCut
          # element "Copy", aCopy
          # element "Paste", aPaste
          # --sub
          # element "Replace", aReplace, false
          # --sub
          element "Find in Files", findInFiles
          element "Find Symbol", findSymbol
          # element "Replace in Files", replaceInFiles, false
          --sub
          # folder "Code folding":
            # element "Collapse under cursor", aCollapseUnderCursor, false
            # element "Expand under cursor", aExpandUnderCursor, false
          element "Expand All", aExpandAll
          element "Collapse All", aCollapseAll
          # --sub
          # folder "Advanced":
          #   element "Toggle Comment", aToggleComment, false
          #   element "Increase Indentation", aIncreaseIndentation, false
          #   element "Decrease Indentation", aDecreaseIndentation, false
          #   element "Make Uppercase", aMakeUppercase, false
          #   element "Make Lowercase", aMakeLowercase, false
          #   #* (Other suitalbe Monaco commands)

            #* (Other suitable Monaco commands)
          # element "Delete", ClientAction.del
        folder "View":
          # folder "Panes":
            # folder "New"
          element "Filesystem", aFilesystem
          element "Calltrace", aFullCalltrace
          element "State", aState
          element "Event Log", aEventLog
          element "Terminal Output", aTerminal
          element "Scratchpad", aScratchpad
          # element "Step List", aStepList
            # element "Shell", aShell
            # element "Find Results", aFindResults, false
            # element "Build Log", aBuildLog, false
            # element "File Explorer", aFileExplorer, false
          # folder "Layouts":
            # element "Save Layout", aSaveLayout, false
            # element "Load Layout", aLoadLayout, false
            # element "Debug (Normal Screen)", switchDebug
            # element "Debug (Wide Screen)", switchDebugWide, false
            # element "Edit (Normal Screen)", switchEditNormal, false
            # element "Edit (Wide Screen)", switchEdit
            #element "can be also"
            #element "Normal screen"
            #element "Wide screen"
            #element "Debug"
            #element "Edit"
          # element "New Horizontal Tab Group", aNewHorizontalTabGroup, false
          # element "New Vertical Tab Group", aNewVerticalTabGroup, false
          # --sub
          # element "Notifications", aNotifications, false
          # element "Start Window", aStartWindow, false
          # element "Full Screen Toggle", aFullScreen, false
          # folder "Choose App Theme":
            # element "Mac Classic Theme", aTheme0
            # element "Default White Theme", aTheme1
            # element "Default Black Theme", aTheme2
            # element "Default Dark Theme", aTheme3
          # folder "Choose Monaco Theme":
            # element "vs-light", aMonacoTheme0, false
            # element "etc",
          # --sub
          # element "Multi-line Preview Mode", aMultiline, false
          # element "Single-line Preview Mode", aSingleLine, false
          # element "No Preview", aNoPreview, false
          # --sub
          # element "View C Code (here it depends on Lang for project)", aLowLevel0, false
          # element "View Assembly Code (similar: can be llvm ir)", aLowLevel1, false
          # --sub
          # element "Zoom In", zoomIn
          # element "Zoom Out", zoomOut
          # element "Show Minimap", aShowMinimap, false
        # folder "Navigate":
        #   element "Go to File", aGotoFile, false
        #   element "Go to Symbol", aGotoSymbol, false
        #   --sub
        #   element "Go to Definition", aGotoDefinition, false
        #   element "Find References", aFindReferences, false
        #   element "Go to Line", aGotoLine, false
        #   --sub
        #   element "Go to Previous Cursor Location", aGotoPreviousCursorLocation, false
        #   element "Go to Next Cursor Location", aGotoNextCursorLocation, false
        #   --sub
        #   element "Go to Previous Edit Location", aGotoPrevious, false
        #   element "Go to Next Edit Location", aGotoNextEditLocation, false
        #   --sub
        #   element "Go to Previous Point in Time", aGotoPreviousPointInTime, false
        #   element "Go to Next Point in Time", aGotoNextPointInTime, false
        #   --sub
        #   element "Go to Next Error", aGotoNextError, false
        #   element "Go to Previous Error", aGotoPreviousError, false
        #   --sub
        #   element "Go to Next Search Result", aGotoNextSearchResult, false
        #   element "Go to Previous Search Result", aGotoPreviousSearchResult, false

        folder "Build":
          element "Rebuild/Re-record file", aReRecord, true
          element "Rebuild/Re-record project", aReRecordProject, true
        #   element "Build Project", aBuild, false
        #   element "Compile Current File (Nim Check)", aCompile, false
        #   element "Run Static Analysis (drnim)", aRunStatic, false
        #   # element "Build tasks (nimble)", nil, false

        # TODO:
        # folder "Reset":
        #   element "Restart db-backend", aRestartDbBackend, true
        #   element "Restart backend-manager", aRestartBackendManager, true

        folder "Debug":
          # element "Trace Existing Program...", aTrace, false
          # element "Load Existing Trace...", aLoadTrace, false
          # folder "Panes":
          #   folder "New":
          #     element "Program state explorer", aNewState, false
          #     element "Event log", aNewEventLog, false
          #     element "Full call trace", aNewFullCalltrace, false
          #     element "Terminal output", aNewTerminal, false
          #   element "Breakpoints/Tracepoints", aPointList, false
          #   element "Mixed call/stack trace", aLocalCalltrace, false
          #   element "Full call trace", aFullCalltrace, false
          #   element "Program state explorer", aState, false
          #   element "Event log", aEventLog
          #   element "Terminal output", aTerminal, false
          # element "Options", aOptions, false
          # --sub
          # element "Start Debugging", aDebug, false
          element "Continue", forwardContinue
          element "Step Over", forwardNext
          element "Step In", forwardStep
          element "Step Out", forwardStepOut
          element "Reverse Continue", reverseContinue
          element "Reverse Step Over", reverseNext
          element "Reverse Step In", reverseStep
          element "Reverse Step Out", reverseStepOut
          # element "Stop Debugging", stop
          # TODO dynamic name
          # element "Pause (currently using stop shortcut?)", stop, false
          --sub
          element "Add a Breakpoint", aBreakpoint
          element "Delete Breakpoint", aDeleteBreakpoint
          element "Delete All Breakpoints", aDeleteAllBreakpoints
          element "Enable Breakpoint", aEnableBreakpoint
          element "Enable All Breakpoints", aEnableAllBreakpoint
          element "Disable Breakpoint", aDisableBreakpoint
          element "Disable All Breakpoints", aDisableAllBreakpoints
          --sub
          element "Add a Tracepoint", aTracepoint
          element "Delete Tracepoint", aDeleteTracepoint
          element "Enable Tracepoint", aEnableTracepoint
          element "Enable All Tracepoints", aEnableAllTracepoints
          element "Disable Tracepoint", aDisableTracepoint
          element "Disable All Tracepoints", aDisableAllTracepoints
          element "Run All Tracepoints", aCollectEnabledTracepointResults

        # The standard macOS Window menu
        macfolder "Window", "window"
        # TODO: Add this for other OS targets and add missing buttons. Added only on macOS for now, as there the menu is
        # generated automatically
        macfolder "Help", "help"
  else:
    defineMenu:
      folder program:
        macfolder "CodeTracer", "":
          macrole "about"
          --sub
          macrole "services"
          --sub
          macrole "hide"
          macrole "hideOthers"
          macrole "unhide"
          --sub
          macrole "quit"
        # element "New Terminal", aTheme0, false
        folder "Themes":
          element "Mac Classic Theme", aTheme0
          element "Default White Theme", aTheme1
          element "Default Black Theme", aTheme2
          element "Default Dark Theme", aTheme3

        # The standard macOS Window menu
        macfolder "Window", "window":
          macrole "minimize"
          macrole "zoom"
          --sub
          macrole "front"
          --sub
          macrole "window"
        # TODO: Add this for other OS targets and add missing buttons. Added only on macOS for now, as there the menu is
        # generated automatically
        macfolder "Help", "help"
        macexclude_element "Exit CodeTracer", aExit, true


proc update*(self: Data, build: bool = false) =
  if build:
    let buildComponent = data.buildComponent(0)
    buildComponent.builds.add(buildComponent.build)
    buildComponent.build = Build(output: @[], running: true)
    data.saveFiles()
  else:
    let activePath = self.services.editor.active
    if not activePath.isNil and activePath.len > 0:
      console.log(cstring(fmt"[ui] saving active editor path: {activePath}"))
      data.saveFiles(activePath)
    else:
      console.log(cstring"[ui] skip saveFiles — no active editor")
  if build:
    data.services.calltrace.restart()
    data.services.eventLog.restart()
    data.services.debugger.restart()
    data.services.flow.restart()
    data.services.history.restart()
    # maybe not? we want the files there data.services.editor
    for content, map in data.ui.componentMapping:
      for id, component in map:
        component.restart()

  # TODO : are undefined/null cstrings handled as cstring"" in the javascript backend?
  # there are a possible edge case, good to be handled as an empty cstring
  # is active focus ok in general?
  # document with active
  var currentPath = cstring""
  if not self.services.editor.active.isNil:
    currentPath = self.services.editor.active
  elif not self.ui.activeFocus.isNil:
    let focusPath = self.ui.activeFocus.toJs.path
    if not focusPath.isNil:
      currentPath = cast[cstring](focusPath)

  console.log(cstring(fmt"[ui] sending CODETRACER::update (build={build}) for path: {currentPath}"))
  ipc.send "CODETRACER::update", js{build: build, currentPath: currentPath}
  redrawAll()

# alt+1 => low level view source 1
# alt+2/alt+i => low level view source2 / instructions for now
# alt+a => low level ast view
# alt+c => low level cfg view
# they all share the same window, but they are displayed in the order in which they are toggled

proc setEditorsEditable*(data: Data, editable: bool) =
  ## Update Monaco editors to match requested editability.
  for label, editor in data.ui.editors:
    if editor.monacoEditor.isNil:
      continue
    let minimapEnabled =
      if editable: data.config.showMinimap
      else: false
    let options = MonacoEditorOptions(
      readOnly: not editable,
      minimap: js{ enabled: minimapEnabled }
    )
    editor.monacoEditor.updateOptions(options)
    editor.updateLineNumbersOnly()

const editModeAuxiliaryContents = [
  Content.State,
  Content.Scratchpad,
  Content.Repl,
  Content.EventLog,
  Content.TerminalOutput,
  Content.StepList,
  Content.Calltrace
]

proc closeAuxiliaryPanels(data: Data) =
  ## Close side panels that should disappear while edit mode is active.

  if data.ui.editModeHiddenPanels.len > 0:
    return
  if not data.ui.layout.isNil and data.ui.savedLayoutBeforeEdit.isNil:
    let snapshot = data.ui.layout.saveLayout()
    # Clone the resolved config so later layout mutations don't modify our snapshot.
    let snapshotCopy = cast[GoldenLayoutResolvedConfig](JSON.parse(JSON.stringify(snapshot)))
    data.ui.savedLayoutBeforeEdit = snapshotCopy
  for content in editModeAuxiliaryContents:
    var idsToClose: seq[int] = @[]
    for id, component in data.ui.componentMapping[content]:
      if component.isNil or component.layoutItem.isNil:
        continue
      idsToClose.add(id)
    for id in idsToClose:
      if not data.ui.componentMapping[content].hasKey(id):
        continue
      let component = data.ui.componentMapping[content][id]
      let layoutItem = component.layoutItem
      if component.isNil or layoutItem.isNil:
        continue
      let parent = layoutItem.parent
      if parent.isNil:
        continue
      var insertIdx = parent.contentItems.len
      for index, item in parent.contentItems:
        if item == layoutItem:
          insertIdx = index
          break
      let config = cast[GoldenLayoutResolvedConfig](JSON.parse(JSON.stringify(layoutItem.toConfig())))
      data.ui.editModeHiddenPanels.add(EditModeHiddenPanel(
        content: content,
        id: id,
        parent: parent,
        index: insertIdx,
        config: config
      ))
      try:
        layoutItem.remove()
      except:
        cwarn fmt"edit-mode: failed to close {$content} layout tab {id}: {getCurrentExceptionMsg()}"
      component.layoutItem = nil

proc reopenAuxiliaryPanels(data: Data) =
  ## Re-open panels closed while edit mode was active.

  if data.ui.editModeHiddenPanels.len == 0:
    data.ui.savedLayoutBeforeEdit = nil
    return

  if not data.ui.savedLayoutBeforeEdit.isNil and not data.ui.layout.isNil:
    for panel in data.ui.editModeHiddenPanels:
      if not data.ui.componentMapping[panel.content].hasKey(panel.id):
        console.log("Key missing!")
        discard data.makeComponent(panel.content, panel.id)
    try:
      data.ui.layout.loadLayout(data.ui.savedLayoutBeforeEdit)
      data.ui.resolvedConfig = data.ui.savedLayoutBeforeEdit
      data.ui.editModeHiddenPanels.setLen(0)
      data.ui.savedLayoutBeforeEdit = nil
      return
    except:
      cerror fmt"edit-mode: failed to reload saved layout: {getCurrentExceptionMsg()}"

  for panel in data.ui.editModeHiddenPanels:
    if not data.ui.componentMapping[panel.content].hasKey(panel.id):
      discard data.makeComponent(panel.content, panel.id)
    try:
      data.openLayoutTab(panel.content, id = panel.id)
    except:
      cwarn fmt"edit-mode: failed to reopen {$panel.content} layout tab with id {panel.id}: {getCurrentExceptionMsg()}"
  data.ui.editModeHiddenPanels.setLen(0)
  data.ui.savedLayoutBeforeEdit = nil

proc setEditorsReadOnlyState(data: Data, readOnly: bool) =
  ## Keep Monaco editor options and context keys aligned with the requested read-only flag.
  if data.ui.readOnly == readOnly:
    return
  data.ui.readOnly = readOnly
  if readOnly:
    data.reopenAuxiliaryPanels()
  else:
    data.closeAuxiliaryPanels()
  for _, editor in data.ui.editors:
    if editor.isNil:
      continue
    if readOnly:
      editor.enableDebugShortcuts()
    else:
      editor.disableDebugShortcuts()
  data.setEditorsEditable(not readOnly)

proc switchToEdit*(data: Data) =
  if data.ui.mode != EditMode:
    data.ui.mode = EditMode
    # TODO separate action for those?
    # data.ui.layout.root.contentItems[0].contentItems[1].config.width = 0
    # data.ui.layout.root.contentItems[0].contentItems[0].config.width = 100

    # data.ui.layout.root.contentItems[0].contentItems[0].contentItems[0].config.width = 20
    # data.ui.layout.root.contentItems[0].contentItems[0].contentItems[1].config.width = 80
    # data.ui.layout.updateSize()
    # data.ui.layout.root.contentItems[0].contentItems[1].element.hide()
    for content, map in data.ui.componentMapping:
      for id, component in map:
        try:
          component.clear()
        except:
          cerror "layout: component clear: " & getCurrentExceptionMsg()
  data.setEditorsReadOnlyState(false)
  redrawAll()

proc switchToDebug*(data: Data) =
  if data.ui.mode != DebugMode:
    data.ui.mode = DebugMode
    # TODO separate action?
    data.ui.layout.root.contentItems[0].contentItems[0].config.width = 50
    data.ui.layout.root.contentItems[0].contentItems[1].config.width = 50
    data.ui.layout.updateSize()
    data.ui.layout.root.contentItems[0].contentItems[1].element.show()
  data.setEditorsReadOnlyState(true)
  redrawAll()

proc toggleMode*(data: Data) =
  if data.ui.mode == DebugMode:
    data.switchToEdit()
  else:
    data.switchToDebug()

proc toggleReadOnly*(data: Data) =
  ## Toggle Monaco read-only state and accompanying panels without forcing a full layout toggle.
  let goingReadOnly = not data.ui.readOnly
  data.setEditorsReadOnlyState(goingReadOnly)
  if goingReadOnly:
    data.ui.mode = DebugMode
  else:
    data.ui.mode = EditMode
  redrawAll()

data.functions.toggleMode = toggleMode
data.functions.toggleReadOnly = toggleReadOnly
data.functions.update = update
data.functions.switchToEdit = switchToEdit
data.functions.switchToDebug = switchToDebug
data.functions.focusEventLog = focusEventLog
data.functions.focusCalltrace = focusCalltrace
data.functions.focusEditorView = focusEditorView


proc configure(data: Data) =
  Mousetrap.`bind`("ctrl+f5") do ():
    data.toggleMode()

  Mousetrap.`bind`("ctrl+e") do ():
    data.toggleReadOnly()

  Mousetrap.`bind`("ctrl+s") do ():
    data.update()

  Mousetrap.`bind`("alt+1") do ():
    data.openLowLevelCode()

  # Mousetrap.`bind`("alt+2") do ():
  #   data.openAlternativeView(2)

  domwindow.onresize = proc(e: js) =
    if not data.isNil and not data.ui.isNil and not data.ui.layout.isNil:
      data.ui.layout.updateSize()

proc loadShortcut*(action: ClientAction, config: Config): cstring =
  # load a shortcut for this node from config
  # if we update config it should effect it
  result = cstring""
  for index, shortcutValue in config.shortcutMap.actionShortcuts[action]:
    if index == 0:
      result = result & shortcutValue.renderer.toUpperCase()
    else:
      result = result & cstring" " & shortcutValue.renderer.toUpperCase()

proc getCommand(node: MenuNode, names: var JsAssoc[cstring, Command], parent: Command = nil) =
  # check if node has children and is enabled
  if node.elements.len == 0 and node.enabled:

    # add node as a subcommand to its parent if it  has one
    if not parent.isNil:
      if not names.hasKey(parent.name):
        names[parent.name] = parent
      names[parent.name].subcommands.add(node.name)

    # add node as a command in commands collection
    if not names.hasKey(node.name):
      names[node.name] = Command(
        name: node.name,
        kind: ActionCommand,
        action: node.action,
        shortcut: loadShortcut(node.action, data.config))

  else:
    # create a parent command from parent
    let parent = Command(
      name: node.name,
      kind: ParentCommand)

    # get commands of parent children
    for node in node.elements:
      node.getCommand(names, parent)

proc getCommands(node: MenuNode): JsAssoc[cstring, Command] =
  var names = JsAssoc[cstring, Command]{}
  node.getCommand(names)
  return names

proc followMouse(event: dom.Event) =
  # dont support ancient IE
  var ev = event
  if ev == nil:
    ev = dom.window.event
  # data.mouseCoords = (ev.pageX, ev.pageY)
  # dom.document.toJs.body.classList.remove(cstring"global-no-cursor")
  # if TELEMETRY_ENABLED:
  #   telemetryBackupIndex += 1
  #   if telemetryBackupIndex == 10:
  #   #  updateTelemetryLog()
  #    telemetryBackupIndex = 0

proc tryInitLayout*(data: Data) =
  if data.ui.pageLoaded and data.ui.initEventReceived:
    initLayout(data.ui.resolvedConfig)
    redrawAll()

# In both these `on` functions, we must communicate them to the ui

# We receive a DAP "Response" from the index process
proc onDapReceiveResponse*(sender: JsObject, raw: JsObject) =
  receiveResponse(data.dapApi, raw["command"].to(cstring), raw["body"])

# We receive a DAP "Event" from the index process
proc onDapReceiveEvent*(sender: JsObject, raw: JsObject) =
  receiveEvent(data.dapApi, raw["event"].to(cstring), raw["body"])

proc onReady(event: dom.Event) =
  if cast[cstring](cast[js](dom.document).readyState) == cstring"complete":
    data.ui.pageLoaded = true
    data.tryInitLayout()
    cast[js](dom.document).onmousemove = followMouse

    # jqueryFind("body").toJs.on(cstring"click", onGlobalClick)

    discard windowsetInterval(proc =
      if not data.services.editor.active.isNil:
        if data.services.editor.changeLine:
          gotoLine(data.services.editor.currentLine, change=true)

        if data.lowAsm() and scrollAssembly != -1:
          let index = scrollAssembly
          scrollAssembly = -1
          jq(".low-level").toJs.scrollTop = cast[int](jqall(".assembly-offset")[index].toJs.offsetTop) - 300, 500)

      # TODO different debug?

      # TODO next few lines are for live notifications/warnings in the app
      # let debugComponent = data.debugComponent
      # if debugComponent.message.message.len > 0 and
      #   delta(now(), debugComponent.message.time) > 5_000:
      #     debugComponent.message.message = ""
      #     redrawAll()

proc onInit*(
    sender: js,
    response: jsobject(
      time=BiggestInt,
      config=Config,
      layout=js,
      home=cstring,
      startOptions=StartOptions,
      bypass=bool,
      helpers=Helpers)) =
  data.startOptions = response.startOptions
  data.homedir = response.home
  data.config = response.config
  if response.bypass:
    renderer.resetLayoutState(data)
  data.ui.resolvedConfig = cast[GoldenLayoutResolvedConfig](response.layout)
  data.config.flow.realFlowUI = loadFlowUI(data.config.flow.ui)
  data.services.flow.enabledFlow = response.config.flow.enabled

  renderer.helpers = response.helpers

  # TELEMETRY_ENABLED = false

  # SILENT_LOG = not data.config.debug

  data.createUIComponents()

  loadTheme(data.config.theme)

  configureShortcuts()

  if not response.bypass:
    redrawAll()

when not defined(ctInExtension):
  import
    communication, middleware, dap,
    .. / common / ct_event

  const logging = true # TODO: maybe overridable dynamically

  # === LocalToViewTransport

  # for now sending through mediator.emit => for each subscriber, subscriber.emit directly
  # as there are many subscribers
  # IMPORTANT:
  # internalRawReceive for it is called by the LocalViewToMiddlewareTransport when
  # a local view emits

  # === end of LocalToViewsTransport

  proc configureMiddleware =
    setupMiddlewareApis(data.dapApi, data.viewsApi)

    data.dapApi.ipc = data.ipc

    data.dapApi.sendCtRequest(DapInitialize, toJs(DapInitializeRequestArgs(
      clientName: "codetracer"
    )))

    for content, components in data.ui.componentMapping:
      for i, component in components:
        if component.api.isNil:
          let componentToMiddlewareApi = setupLocalViewToMiddlewareApi(cstring(fmt"{content} #{component.id} api"), data.viewsApi)
          component.register(componentToMiddlewareApi)

    # discard windowSetTimeout(proc =
    #   data.dapApi.exampleDap.receiveOnMove(), 1_000)

  # once:
    # configureMiddleware()

cast[js](dom.document).onreadystatechange = onReady

proc onTraceLoaded(
  sender: js,
  response: jsobject(
    trace=Trace,
    tags=JsAssoc[cstring, seq[Tag]],
    functions=seq[Function],
    save=Save,
    diff=Diff,
    withDiff=bool,
    rawDiffIndex=cstring,
    # traceKind=cstring,
    dontAskAgain=bool)) {.async.} =

  clog "trace loaded"
  # console.log response.withDiff, response.diff, response.rawDiffIndex

  data.trace = response.trace
  data.setEditorsReadOnlyState(true)
  data.services.debugger.functions = response.functions
  data.services.editor.tags = response.tags
  data.save = response.save
  data.save.fileMap = JsAssoc[cstring, int]{}
  data.ui.menuNode = data.webTechMenu(baseName(response.trace.program))

  dom.document.title = cstring(fmt"CodeTracer | Trace {data.trace.id}: {data.trace.program}")

  for i, file in data.save.files:
    data.save.fileMap[file.path] = i

  # create Command objects from main menuNode
  data.ui.commandPalette.interpreter.commands = getCommands(data.ui.menuNode)

  # prepare command for fast search with fuzzysort
  for key, command in data.ui.commandPalette.interpreter.commands:
    data.ui.commandPalette.interpreter.commandsPrepared.add(fuzzysort.prepare(key))

  duration("traceLoaded")

  if data.trace.lang in {LangC, LangCpp, LangRust, LangGo}:
    data.startOptions.loading = false
  CURRENT_LANG = data.trace.lang

  if not data.services.eventLog.isNil:
    data.services.eventLog.restart()
  for id, component in data.ui.componentMapping[Content.EventLog]:
    if not component.isNil:
      component.restart()
  for id, component in data.ui.componentMapping[Content.TerminalOutput]:
    if not component.isNil:
      component.restart()

  data.ui.initEventReceived = true
  data.tryInitLayout()

  if data.startOptions.rawTestStrategy.len > 0:
    data.testRunner = cast[JsObject](runUiTest(data.startOptions.rawTestStrategy))

    if not dapReplayHandlerRegistered:
      data.ipc.on(cstring"CODETRACER::dap-replay-selected") do (sender: js, response: JsObject):
        let trace = response["trace"].to(Trace)
        infoPrint "ui: reinitializing dap for trace ", $trace.id
        data.dapApi.sendCtRequest(DapConfigurationDone, js{})
        data.dapApi.sendCtRequest(DapLaunch, js{
          traceFolder: trace.outputFolder,
          rawDiffIndex: data.startOptions.rawDiffIndex,
          ctRRWorkerExe: data.config.rrBackend.path,
        })
      dapReplayHandlerRegistered = true

  when not defined(ctInExtension):
    if not middlewareConfigured:
      configureMiddleware()
      middlewareConfigured = true

    if not dapReplayHandlerRegistered:
      data.ipc.on(cstring"CODETRACER::dap-replay-selected") do (sender: js, response: JsObject):
        let trace = response["trace"].to(Trace)
        infoPrint "ui: reinitializing dap for trace ", $trace.id
        data.dapApi.sendCtRequest(DapInitialize, toJs(DapInitializeRequestArgs(
          clientName: "codetracer"
        )))
        data.dapApi.sendCtRequest(DapConfigurationDone, js{})
        data.dapApi.sendCtRequest(DapLaunch, js{
          traceFolder: trace.outputFolder,
          rawDiffIndex: data.startOptions.rawDiffIndex,
          ctRRWorkerExe: data.config.rrBackend.path,
        })
      dapReplayHandlerRegistered = true

  data.switchToDebug()
  renderer.requestInitialPanelData(data)

  if not data.startOptions.isInstalled and not response.dontAskAgain and not data.config.skipInstall:
    data.viewsApi.installMessage()

proc onStartShellUi*(sender: js, response: jsobject(config=Config)) =
  # domwindow.kxi = JsAssoc[cstring, KaraxInstance]{}
  data.startOptions.loading = false
  data.startOptions.shellUi = true
  data.config = response.config
  data.ui.menuNode = data.webTechMenu(cstring"Shell")
  loadTheme(data.config.theme)
  var shellComponent = data.shellComponent(0)

  if shellComponent.isNil:
    shellComponent =
      cast[ShellComponent](data.makeComponent(
        Content.Shell, data.generateId(Content.Shell)))
  shellComponent.createShell()

  if not data.ui.welcomeScreen.isNil:
    data.ui.welcomeScreen.welcomeScreen = false
    data.ui.welcomeScreen.newRecordScreen = false

  if data.ui.menu.isNil:
    discard data.makeMenuComponent()

  data.ui.initEventReceived = true
  data.tryInitLayout()


proc onFilenamesLoaded(
    sender: js,
    response: jsobject(
      filenames=seq[string])) =

  data.services.debugger.paths = response.filenames

  # add file paths to command interpreter
  for path in data.services.debugger.paths:
    let fileName = baseName(path)
    data.ui.commandPalette.interpreter.files[path] = path

    # prepare file paths for fast srearch widh fuzzysort
    data.ui.commandPalette.interpreter.filesPrepared.add(fuzzysort.prepare(path))

  data.redraw()

proc onSymbolsLoaded(
    sender: js,
    response: jsobject(
      symbols=seq[Symbol])) =

  data.ui.commandPalette.interpreter.symbols = JsAssoc[cstring, seq[Symbol]]{}

  for symbol in response.symbols:
    if not data.ui.commandPalette.interpreter.symbols.hasKey(symbol.name):
      data.ui.commandPalette.interpreter.symbols[symbol.name] = @[]

      # prepare file paths for fast search widh fuzzysort
      data.ui.commandPalette.interpreter.symbolsPrepared.add(fuzzysort.prepare(cstring(symbol.name)))

    # It's possible to have the same symbol in different files
    var nameSymbols = data.ui.commandPalette.interpreter.symbols[symbol.name]
    nameSymbols.add(symbol)
    data.ui.commandPalette.interpreter.symbols[symbol.name] = nameSymbols

  data.redraw()

proc onMenuAction(sender: js, response: jsobject(action=ClientAction)) =
  let f = data.actions[response.action]
  if not f.isNil:
    f()


proc onFilesystemLoaded(
  sender: js,
  response: jsobject(
    folders=CodetracerFile)) =
  data.services.editor.filesystem = response.folders
  data.redraw()

proc onUpdatePathContent(
  sender: js,
  response: jsobject(
    content=CodetracerFile,
    nodeId=cstring,
    nodeIndex=int,
    nodeParentIndices=seq[int])) =
  let tree = jqFind(".filesystem").jstree(true)
  let parent = tree.get_node(response.nodeId)
  var children = parent.children.to(seq[cstring])

  # remove current jstree node children
  if children.len > 0:
    var deletedItems = 0
    for i in 0..<children.len:
      tree.delete_node(children[i - deletedItems])
      deletedItems += 1

  # create new jstree node children
  response.content.changeIcons()
  if response.content.children.len > 0:
    for child in response.content.children:
      tree.create_node(response.nodeId, child)

  # update component state
  var nodeParent = data.services.editor.filesystem

  for index in response.nodeParentIndices:
    nodeParent = nodeParent.children[index]

  var node = nodeParent.children[response.nodeIndex]
  node[] = response.content[]


proc onUpdateTrace(sender: js, response: jsobject(trace=Trace)) =
  data.trace = response.trace
  data.ui.readOnly = false
  let oldPaths = data.services.debugger.paths
  let oldTags = data.services.editor.tags
  let oldFilesystem = data.services.editor.filesystem
  let oldSave = data.save

  data.services.editor.tags = oldTags
  # TODO initDataTable = true
  data.services.debugger.paths = oldPaths
  data.services.editor.filesystem = oldFilesystem
  data.save = oldSave
  data.switchToDebug()
  redrawAll()


proc onNoTrace(
    sender: js,
    response: jsobject(
      path=cstring,
      lang=Lang,
      layout=js,
      home=cstring,
      startOptions=StartOptions,
      bypass=bool,
      helpers=Helpers,
      config=Config,
      filenames=seq[string],
      filesystem=CodetracerFile,
      functions=seq[Function],
      save=Save)) {.async.} =

  data.trace = nil
  data.ui.readOnly = false
  data.startOptions = response.startOptions
  data.homedir = response.home
  data.startOptions.app = response.home & cstring"/.local/share" & cstring"/codetracer"
  data.services.debugger.paths = response.filenames
  data.services.debugger.functions = response.functions
  data.ui.menuNode = data.webTechMenu(baseName(response.path))

  for path in data.services.debugger.paths:
    data.services.search.pathsPrepared.add(fuzzysort.prepare(path))

  for name, source in data.services.search.pluginCommands:
    data.services.search.commandsPrepared.add(
      fuzzysort.prepare(name))

  for function in data.services.debugger.functions:
    var prepared = fuzzysort.prepare(function.signature)
    prepared.obj = function
    data.services.search.functionsPrepared.add(prepared)
    if function.inSourcemap:
      data.services.search.functionsInSourcemapPrepared.add(prepared)

  data.services.editor.filesystem = response.filesystem
  data.ui.resolvedConfig = cast[GoldenLayoutResolvedConfig](response.layout)
  data.config = response.config
  data.config.layout = cstring"default_white"
  data.config.flow.realFlowUI = loadFlowUI(data.config.flow.ui)
  data.save = response.save
  data.save.fileMap = JsAssoc[cstring, int]{}
  for i, file in data.save.files:
    data.save.fileMap[file.path] = i
  loadTheme(cstring"default_white")
  # data.tabManager.tabs = JsAssoc[cstring, TabInfo]{}
  # data.tabManager.tabList = @[]
  if response.path.len > 0:
    data.openTab(response.path, ViewSource) # , response.lang)
  data.startOptions.screen = false
  data.startOptions.loading = false

  data.ui.initEventReceived = true
  data.tryInitLayout()

  data.switchToEdit()
  let ext = $toJsLang(response.lang)
  # for i, file in data.save.files:
    # if i < TAB_LIMIT:
      # if ($file.path).endsWith(ext):
        # data.openTab(file.path, cstring"", 0, response.lang)
      # else:
        # data.openTab(file.path, cstring"", 0, LangUnknown)
    # else:
      # remember those and be able to load them on ctrl+page etc
      # TODO
      # discard

  configureShortcuts()
  redrawAll()
  data.ui.layout.updateSize()
  discard windowSetTimeout(proc =
    redrawAll()
    data.ui.layout.updateSize(), 1_000)
  discard windowSetTimeout(proc = redrawAll(), 5_000)
  # sometimes stuff isn't rendered and it needs redraw

proc invalidPath(data: Data, fieldName: cstring, message: cstring) =
  let formValidator = data.ui.welcomeScreen.newRecord.formValidator
  let capitalizedField = capitalize(fieldName)
  formValidator.toJs[&"valid{capitalizedField}"] = false
  formValidator.toJs[&"invalid{capitalizedField}Message"] = message

proc recordPath(data: Data, path: cstring, fieldName: cstring) =
  if not data.ui.welcomeScreen.newRecord.isNil:
    data.ui.welcomeScreen.newRecord.toJs[$(fieldName)] = path
    let formValidator = data.ui.welcomeScreen.newRecord.formValidator
    let capitalizedField = capitalize(fieldName)
    formValidator.toJs[&"valid{capitalizedField}"]= true
    formValidator.toJs[&"invalid{capitalizedField}Message"] = cstring""
    redrawAll()

proc onRecordPath(
  sender: js,
  response: jsobject(
    execPath=cstring,
    fieldName=cstring)) =

    data.recordPath(response.execPath, response.fieldName)

proc onPathValidated(
  sender: js,
  response: jsobject(
    execPath=cstring,
    isValid=bool,
    fieldName=cstring,
    message=cstring)) =
  if not response.isValid:
    data.invalidPath(response.fieldName, response.message)
    redrawAll()
  else:
    data.recordPath(response.execPath, response.fieldName)

proc onSuccessfulRecord(
  sender: js,
  response: jsobject()) =
  if not data.ui.welcomeScreen.isNil and
      not data.ui.welcomeScreen.newRecord.isNil:
    data.ui.welcomeScreen.newRecord.status.kind = RecordSuccess
    redrawAll()
  else:
    data.viewsApi.successMessage(cstring"Recording finished. Reloading trace...")

proc onFailedRecord(
  sender: js,
  response: jsobject(errorMessage=cstring)) =
  if not data.ui.welcomeScreen.isNil and
      not data.ui.welcomeScreen.newRecord.isNil:
    data.ui.welcomeScreen.newRecord.status.kind = RecordError
    data.ui.welcomeScreen.newRecord.status.errorMessage = response.errorMessage
    redrawAll()
  else:
    data.viewsApi.errorMessage(response.errorMessage)

proc onLoadingTrace(
  sender: js,
  response: jsobject(trace=Trace)) =
  data.ui.welcomeScreen.loading = true
  data.ui.welcomeScreen.loadingTrace = response.trace
  redrawAll()

proc onFailedDownload(
  sender: js,
  response: jsobject(errorMessage=cstring)
) =
  data.ui.welcomeScreen.newDownload.status.kind = RecordError
  data.ui.welcomeScreen.newDownload.status.errorMessage = response.errorMessage
  redrawAll()

proc onSuccessfulDownload(
  sender: js,
  response: jsobject()
) =
  data.ui.welcomeScreen.newDownload.status.kind = RecordSuccess
  redrawAll()

proc onWelcomeScreen(
  sender: js,
  response: jsobject(
    home=cstring,
    layout=js,
    startOptions=StartOptions,
    config=Config,
    recentTraces=seq[Trace],
    recentTransactions=seq[StylusTransaction]
  )
) =
  clog "welcome_screen: on welcome screen"
  # TODO: remove unnecessary rows
  data.trace = nil
  data.ui.readOnly = false
  data.startOptions = response.startOptions
  data.homedir = response.home
  data.services.debugger.paths = @[]
  data.ui.resolvedConfig = cast[GoldenLayoutResolvedConfig](response.layout)
  data.config = response.config
  data.config.flow.realFlowUI = loadFlowUI(data.config.flow.ui)
  data.recentTraces = response.recentTraces
  data.stylusTransactions = response.recentTransactions
  loadTheme(data.config.theme)
  configureShortcuts()

  if data.ui.welcomeScreen.isNil:
    discard data.makeWelcomeScreenComponent()

  data.ui.initEventReceived = true
  data.tryInitLayout()

proc onNewNotification(sender: js, notification: Notification) =
  data.viewsApi.showNotification(notification)

# func renderVariables(self: TimelineComponent): VNode =
  # buildHtml(tdi)
method render(self: TimelineComponent): VNode =

  # var view = case self.active:
  # of TimelineVariables:
  #   self.renderVariables()
  # of TimelineRegisters:
  #   self.renderRegisters()
  buildHtml(tdiv()):
    tdiv(id="timeline") #:
      # for

proc onCtInstallStatus(sender: js, status: (cstring, cstring)) =
  if status[0] == cstring"ok":
    data.viewsApi.successMessage($(status[1]))
  else:
    data.viewsApi.errorMessage($(status[1]))

proc onSavedAs(sender: js, files: JsAssoc[cstring, cstring]) =
  # discard
  # TODO
  for untitledName, newPath in files:
    data.services.editor.open[newPath] = data.services.editor.open[untitledName]
    data.services.editor.open[newPath].untitled = false
    data.services.editor.open[newPath].changed = false
    data.services.editor.open[newPath].name = newPath
    # data.services.editor.open[newPath].fileInfo.path = newPath
    discard jsDelete(data.services.editor.open[untitledName])
    kxiMap[newPath] = kxiMap[untitledName]
    discard jsDelete(kxiMap[untitledName])
    data.ui.editors[newPath] = data.ui.editors[untitledName]
    discard jsDelete(data.ui.editors[untitledName])
    data.ui.editors[newPath].path = newPath

proc onSavedFile(sender: js, response: jsobject(name=cstring)) =
  if data.services.editor.open.hasKey(response.name):
    data.services.editor.open[response.name].changed = false
  if data.ui.editors.hasKey(response.name):
    let editor = data.ui.editors[response.name]
    if not editor.tabInfo.isNil:
      editor.tabInfo.changed = false
    editor.name = response.name
    if not data.services.search.paths.hasKey(response.name):
      data.services.search.pathsPrepared.add(fuzzysort.prepare(response.name))
      data.services.search.paths[response.name] = true
    var tokens = rsplit($response.name, {'/'}, maxsplit=1)
    var label = $response.name
    if tokens.len >= 2:
      label = tokens[1]
    editor.contentItem.setTitle(cstring(label))
    editor.contentItem.config.componentState.label = response.name
    editor.contentItem.config.componentState.fullPath = response.name
  data.redraw()

proc saveAllFiles*(data: Data): Future[void] =
  var promise = newPromise[void] do (resolve: proc: void):
    var input = ""

    var i = 0
    var changed: seq[TabInfo]
    for name, tab in data.services.editor.open:
      if tab.changed:
        input.add(&"<label for=tab-{i}>{name}</label><input type=checkbox name=tab-{i} />")
        i += 1
        changed.add(tab)

    if i > 0:
      vex.dialog.open(js{
        message: cstring"",
        input: cstring(&"close: files changed, save?\n{input}"),
        buttons: @[
          vex.dialog.buttons.YES, vex.dialog.buttons.NO
        ],
        callback: proc (checkbox: JsAssoc[cstring, cstring]) =
          if cast[bool](checkbox) == false:
            return
          for name, check in checkbox:
            let i = ($name)[4 .. ^1].parseInt
            if check == cstring"on":
              data.saveFiles(changed[i].name)
            changed[i].changed = false
          resolve()
      })
    else:
      resolve()
  return promise

proc closeAllTabsAfterSave*(data: Data) {.locks: 0.} =
  for id, editorComponent in (data.ui.componentMapping)[Content.EditorView]:
    try:
      # get editor component layout item
      let layoutItem = editorComponent.layoutItem
      let parentContentItem = layoutItem.parent

      # remove component layout item
      if parentContentItem.contentItems.len > 1:
        layoutItem.remove()
      else:
        parentContentItem.remove()

    except Exception as e:
      # maybe removed already
      data.viewsApi.warnMessage(&"warn: {e.msg}")

proc exit*(data: Data) {.async.} =
  await data.saveAllFiles()
  ipc.send "CODETRACER::close-app", js{}

proc closeAllFiles*(data: Data) {.async.} =
  await data.saveAllFiles()
  data.closeAllTabsAfterSave()

proc onClose*(data: Data) =
  discard data.exit()

macro uiIpcHandlers*(namespace: static[string], messages: untyped): untyped =
  let ipc = ident("ipc")
  let data = ident("data")
  result = nnkStmtList.newTree()
  for message in messages:
    var fullMessage: NimNode
    var handler: NimNode
    var messageCode: NimNode
    if message.kind == nnkStrLit:
      fullMessage = (namespace & $message).newLit
      handler = (("on-" & $message).toCamelCase).ident
      messageCode = quote:
        `ipc`["on"].call(`ipc`, `fullMessage`, `handler`)
    else:
      # a:t => b
      # echo message.treerepr
      fullMessage = (namespace & $(message[0])).newLit
      var elements: seq[NimNode]
      if message[1][0][2].kind == nnkIdent:
        elements.add(message[1][0][2])
      else:
        for element in message[1][0][2]:
          elements.add(element)
      let response = ident("response")
      var handlers = nnkStmtList.newTree()
      let temp = message[1][0][1]
      for element in elements:
        if element.repr != "ui":
          let service = element
          let name = (("on-" & $(message[0])).toCamelCase).ident
          handler = quote:
            discard functionAsJS(`data`.services.`service`.`name`).call(jsUndefined, `data`.services.`service`, `response`)
        else:
          let name = (("on-" & $(message[0])).toCamelCase).ident
          let nameLit = newLit($name)
          handler = quote:
            # var i = 0
            # while true:
            #   # echo i
            #   if i == `data`.ui.list.len or i > 50:
            #     break
            #   var component = `data`.ui.list[i]
            for content, map in `data`.ui.componentMapping:
              for id, component in map:
                discard component.`name`(cast[`temp`](`response`))
        handlers.add(handler)
      messageCode = quote:
        `ipc`["on"].call(`ipc`, `fullMessage`) do (sender: js, `response`: js):
          echo "-> received: ", `fullMessage`
          `handlers`
      # echo messageCode.repr
    result.add(messageCode)
  # echo result.repr

proc configureIPC(data: Data) =
  uiIpcHandlers("CODETRACER::"):
    # "new-record-window"
    "record-path"
    "path-validated"
    "successful-record"
    "failed-record"
    "loading-trace"

    "trace-loaded"
    "update-trace"
    "start-shell-ui"

    "no-trace"
    "welcome-screen"
    "saved-as"
    "saved-file"

    # notifications
    "new-notification"
    "ct-install-status"

    "init"
    "tab-load-received"
    "asm-load-received"
    "load-locals-received"
    "expand-value-received"
    "evaluate-expression-received"
    "expand-values-received"
    "search-calltrace-received"
    "load-parsed-exprs-received"
    "updated-events": seq[EventElement] => eventLog
    "updated-events-content": cstring => eventLog
    "updated-trace": TraceUpdate => [ui]
    "updated-history": HistoryUpdate => [ui]
    "updated-flow": FlowUpdate => [ui]
    # "loaded-terminal": seq[ProgramEvent] => [ui]
    # "updated-table": TableUpdate => [ui]
    # "updated-call-args": CallArgsUpdateResults => [ui]
    "updated-watches": JsAssoc[cstring, Value] => debugger
    "updated-shell": ShellUpdate => shell
    "loaded-flow-shape": FlowShape => [ui]
    "context-start-trace"
    "context-start-history"
    "complete-move": MoveState => [debugger, editor, eventLog, ui]
    "tracepoint-locals": TraceValues => [ui]
    "loaded-locals": JsAssoc[cstring, Value] => debugger
    "search-results-updated": seq[SearchResult] => search
    "load-callstack-received"
    "debug-output": DebugOutput => [debugger, ui]
    "log-output"
    # filesystem handlers
    "filesystem-loaded"
    "update-path-content"
    # load trace resources
    "filenames-loaded"
    "symbols-loaded"
    "build-stdout": BuildOutput => [ui]
    "build-stderr": BuildOutput => [ui]
    "build-code": BuildCode => [ui]
    "build-command": BuildCommand => [ui]
    "started"
    "change-file"
    "tab-reloaded"
    "opened-tab": OpenedTab => editor
    "close"
    "open-location"
    "add-breakpoint"
    "run-to"
    "collapse-expansion"
    "collapse-all-expansion"
    "add-break-response": BreakpointInfo => debugger
    "add-break-c-response": BreakpointInfo => debugger
    "debugger-started": int => [debugger, ui]
    "output-jump-from-shell-ui": int => ui
    "program-search-results": seq[CommandPanelResult] => ui
    "updated-load-step-lines": LoadStepLinesUpdate => ui

    "finished": JsObject => debugger
    "error": DebuggerError => [debugger, ui]
    "failed-download"
    "successful-download"

    "follow-history"

    "upload-trace-file-received"
    "upload-trace-progress": UploadProgress => ui
    "delete-online-trace-file-received"
    "menu-action"

    # Dap communication
    "dap-receive-response"
    "dap-receive-event"

    # Acp communication
    "acp-receive-response"

  duration("configureIPCRun")

proc zoomInEditors*(data: Data) =
  if data.ui.fontSize < MAX_FONTSIZE:
    data.ui.fontSize += 1
    for path, editor in data.ui.monacoEditors:
      let options = cast[MonacoEditorOptions](editor.getOptions())
      options.fontSize = data.ui.fontSize
      editor.updateOptions(options)
    for path, editor in data.ui.traceMonacoEditors:
      let options = cast[MonacoEditorOptions](editor.getOptions())
      options.fontSize = data.ui.fontSize
      editor.updateOptions(options)
    for path, editor in data.ui.editors:
      if not editor.flow.isNil and not editor.flow.flow.isNil:
        editor.flow.redrawFlow()
      for line, zone in editor.diffViewZones:
        zone.dom.style.fontSize = cstring($data.ui.fontSize) & cstring"px"
        let editorContentLeft = editor.monacoEditor
          .getOption(LAYOUT_INFO).contentLeft + EDITOR_GUTTER_PADDING
        zone.dom.style.left = fmt"-{editorContentLeft}px"
      for line, diffEditor in editor.diffEditors:
        let options = cast[MonacoEditorOptions](diffEditor.getOptions())
        options.fontSize = data.ui.fontSize
        diffEditor.updateOptions(options)
    redrawAll()
    clog "editor: zoom in!"

proc zoomOutEditors*(data: Data) =
  if data.ui.fontSize > MIN_FONTSIZE:
    data.ui.fontSize -= 1
    for path, editor in data.ui.monacoEditors:
      let options = cast[MonacoEditorOptions](editor.getOptions())
      options.fontSize = data.ui.fontSize
      editor.updateOptions(options)
    for path, editor in data.ui.traceMonacoEditors:
      let options = cast[MonacoEditorOptions](editor.getOptions())
      options.fontSize = data.ui.fontSize
      editor.updateOptions(options)
    for path, editor in data.ui.editors:
      if not editor.flow.isNil and not editor.flow.flow.isNil:
        editor.flow.redrawFlow()
      for line, zone in editor.diffViewZones:
        zone.dom.style.fontSize = cstring($(data.ui.fontSize)) & cstring"px"
        let editorContentLeft = editor.monacoEditor
          .getOption(LAYOUT_INFO).contentLeft + EDITOR_GUTTER_PADDING
        zone.dom.style.left = fmt"-{editorContentLeft}px"
      for line, diffEditor in editor.diffEditors:
        let options = cast[MonacoEditorOptions](diffEditor.getOptions())
        options.fontSize = data.ui.fontSize
        diffEditor.updateOptions(options)
    redrawAll()
    clog "editor: zoom out!"

proc zoomFlowLoopIn*(data: Data) =
  let flow = data.ui.editors[data.services.editor.active].flow
  for loopIndex, state in flow.loopStates:
    if state.viewState == LoopShrinked:
      resetShrinkedLoopIterations(flow)
      state.defaultIterationWidth = state.minWidth
      flow.resetColumnsWidth(1, loopIndex, true)
      state.viewState = LoopValues
    else:
      state.defaultIterationWidth += 1
      flow.resetColumnsWidth(1, loopIndex, false)
  discard calculateLoopSliderWidth(flow)

proc zoomFlowLoopOut*(data: Data) =
  let flow = data.ui.editors[data.services.editor.active].flow
  for loopIndex, state in flow.loopStates:
    if state.defaultIterationWidth > state.minWidth:
      state.defaultIterationWidth -= 1
      flow.resetColumnsWidth(-1, loopIndex, false)
    else:
      if state.viewState != LoopShrinked:
        flow.shrinkLoopIterations(loopIndex)

proc setFlowTypeToMultiline*(data: Data) =
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow
  flow.switchFlowType(FlowMultiline)

proc setFlowTypeToParallel*(data: Data) =
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow
  flow.switchFlowType(FlowParallel)

proc setFlowTypeToInline*(data: Data) =
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow
  flow.switchFlowType(FlowInline)

proc switchFocusedLoopLevelAtPosition*(data: Data) =
  console.time("switchFocusedLoopLevelAtPosition")
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow

  # get active editor current position
  let monaco = activeEditor.monacoEditor
  let currentEditorPosition = monaco.getPosition().toJs.lineNumber.to(int)

  if not toSeq(flow.flow.positionStepCounts.keys())
    .any(key => key == currentEditorPosition):
      cwarn "flow: no flow at this position"
      return

  # get loops at current position
  let loopsAtCurrentPosition = flow.flowLines[currentEditorPosition].loopIds

  # get currently focused loops
  let currentFocusedLoops = flow.getFocusedLoopsIds()

  if loopsAtCurrentPosition.len > 0 and
    loopsAtCurrentPosition.all(loopIndex => not flow.loopStates[loopIndex].focused):

    # first loop at current position
    let firstLoop = flow.flow.loops[loopsAtCurrentPosition[0]]
    let firstLoopFirstLine = firstLoop.first
    # flow line width at first line of first loop at current position
    let sliderPosition = flow.flowLines[firstLoopFirstLine].sliderPosition
    let sliderPositionLoop = sliderPosition.loopIndex
    let sliderPositionIteration = sliderPosition.iteration
    let step = flow.flow.steps.filterIt(
      it.position == firstLoopFirstLine and
      it.loop == sliderPositionLoop and
      it.iteration == sliderPositionIteration)[0]
    var stepNode = flow.stepNodes[step.stepCount]

    let stepNodeOffset = flow.getStepDomOffsetLeft(step)

    # remove focus on focused loops
    for loopIndex in currentFocusedLoops:
      flow.loopStates[loopIndex].focused = false

    # switch focused loops
    for loopIndex in loopsAtCurrentPosition:
      flow.loopStates[loopIndex].focused = true

    # recalculate loop iterationsWidth
    flow.calculateFlowLoopIterationsWidths()

    # recalculate flowLines width
    for line, flowLine in flow.flowLines:
      flowLine.totalLineWidth = flow.calclulateFlowLineTotalWidth(line)

    flow.redrawLinkedLoops()

    flow.move(sliderPositionLoop, sliderPositionIteration, firstLoopFirstLine, refocus = true)

    flow.updateFlowDom()
  console.timeEnd("switchFocusedLoopLevelAtPosition")

proc restartCodetracer*(data: Data) =
  data.ipc.send "CODETRACER::restart", js{}

proc switchFocusedLoopLevelUp*(data: Data) =
  let flow = data.ui.editors[data.services.editor.active].flow
  let currentFocusedLoops = flow.getFocusedLoopsIds()

  # switch focused loops
  var focusedLoops: seq[int] = @[]
  for loopIndex in currentFocusedLoops:
    let parentLoopIndex = flow.flow.loops[loopindex].base
    if parentLoopIndex != -1:
      flow.loopStates[loopIndex].focused = false
      flow.loopStates[parentLoopIndex].focused = true
      if not focusedLoops.any(index => index == parentLoopIndex):
        focusedLoops.add(parentLoopIndex)

  # recalculate loop iterationsWidth
  flow.calculateFlowLoopIterationsWidths()

  # recalculate flowLines width
  for line, flowLine in flow.flowLines:
    flowLine.totalLineWidth = flow.calclulateFlowLineTotalWidth(line)

  # redraw loops
  flow.redrawLinkedLoops()

proc switchFocusedLoopLevelDown*(data: Data) =
  discard

template pointsOperationsSetup(data: Data): untyped =
  let
    debuggerService {.inject.} = data.services.debugger
    activeEditorPath {.inject.} = data.services.editor.active
    editor {.inject.} = data.ui.editors[activeEditorPath]
    monacoEditor {.inject.} = editor.monacoEditor
    line {.inject.} = monacoEditor.getPosition().lineNumber

proc expandWholeSource*(data: Data) =
  data.pointsOperationsSetup()
  monacoEditor.trigger("unfold", "editor.unfoldAll")

proc collapseWholeSource*(data: Data) =
  data.pointsOperationsSetup()
  monacoEditor.trigger("fold", "editor.foldAll")

proc toggleMinimap*(data: Data) =
  discard

proc addBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.addBreakpoint(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc removeBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.deleteBreakpoint(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc removeAllBreakpoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, point in debuggerService.breakpointTable[activeEditorPath]:
    debuggerService.deleteBreakpoint(activeEditorPath, line)
    editor.refreshEditorLine(line)

proc enableBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.enable(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc enableAllBreakpoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, point in debuggerService.breakpointTable[activeEditorPath]:
    debuggerService.enable(activeEditorPath, line)
    editor.refreshEditorLine(line)

proc disableBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.disable(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc disableAllBreakpoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, point in debuggerService.breakpointTable[activeEditorPath]:
    debuggerService.disable(activeEditorPath, line)
    editor.refreshEditorLine(line)

proc addTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if not editor.traces.hasKey(line):
    editor.toggleTrace(editor.name, line)

proc removeTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if editor.traces.hasKey(line):
    let trace = editor.traces[line]
    trace.closeTrace()

proc enableTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if editor.traces.hasKey(line):
    let trace = editor.traces[line]
    if trace.isDisabled:
      trace.toggleTraceState()

proc enableAllTracepoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, trace in editor.traces:
    if trace.isDisabled:
      trace.toggleTraceState()

proc disableTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if editor.traces.hasKey(line):
    let trace = editor.traces[line]
    if not trace.isDisabled:
      trace.toggleTraceState()

proc disableAllTracepoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, trace in editor.traces:
    if not trace.isDisabled:
      trace.toggleTraceState()

const ClientActionCount = ClientAction.high.int - ClientAction.low.int + 1

# static:
  # echo ClientActionCount

proc isEditorFocused(data: Data): bool =
  for editor in data.ui.monacoEditors:
    if editor.hasTextFocus():
      return true

proc isInputElementFocused(data: Data): bool =
  var element: JsObject = cast[JsObject](dom.window.document.activeElement)
  return element.tagName.to(cstring) == cstring("INPUT")

proc toggleTracepoint*(path: cstring, line: int) {.exportc.} =
  data.ui.editors[path].toggleTrace(path, line)

var actions*: array[ClientAction, ClientActionHandler] = [
  proc = forwardContinue(fromShortcut=true),
  proc = reverseContinue(fromShortcut=true),
  proc = next(fromShortcut=true),
  proc = reverseNext(fromShortcut=true),
  proc = stepIn(fromShortcut=true),
  proc = reverseStepIn(fromShortcut=true),
  proc = stepOut(fromShortcut=true),
  proc = reverseStepOut(fromShortcut=true),
  proc = stopAction(),
  proc = data.update(build=true),
  proc = switchTab(change = -1),
  proc = switchTab(change = 1),
  proc = data.switchTabHistory(),
  proc = openFile(),
  proc = data.openNewTab(),
  proc = data.reopenLastTab(),
  proc = data.closeActiveTab(),
  proc = data.switchToEdit(),
  proc = data.switchToDebug(),
  proc = data.commandSearch(),
  proc = data.fileSearch(),
  proc = data.fixedSearch(),
  proc =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.delete(),
  proc = discard data.onSelectFlow(),
  proc = discard data.onSelectState(),
  proc =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onUp(),
  proc =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onDown(),
  proc =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onRight(),
  proc =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onLeft(),
  proc =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onPageUp(),
  proc =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onPageDown(),
  proc =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onGotoStart(),
  proc =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onGotoEnd(),
  proc = # aEnter
    # echo "global array map: enter"
    # affects only renderer, map manually editor differently
    if not data.ui.activeFocus.isNil and not data.isInputElementFocused():
      # echo "  => global array map: enter: activeFocus not nil, calling its method"
      discard data.ui.activeFocus.onEnter(),
  proc = # goUp
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onEscape(),
  proc = data.zoomInEditors(),
  proc = data.zoomOutEditors(),
  (proc = echo "example"),
  proc = discard data.exit(), # aExit
  proc = data.openNewTab(), # NewFile
  proc = data.openPreferences(), # TODO: fix bottom panels Preferences
  nil,# TODO proc = data.openNewTab(folder=true), # NewFold
  nil,# TODO OpenRecent
  # aSave
  proc = data.saveFiles(data.services.editor.active),
  proc = data.saveFiles(data.services.editor.active, saveAs=true),
  proc = data.saveFiles(),
  proc = discard data.closeAllFiles(), # close all,
  (proc = clipboardCopy(data.getMonacoSelectionText())), # aCut
  (proc = clipboardCopy(data.getMonacoSelectionText())), # aCopy
  (proc = data.clipboardPaste()), # aPaste
  proc =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onFindOrFilter(),
  nil,
  proc = data.findInFiles(),
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  proc = data.expandWholeSource(), # aExpandAll
  proc = data.collapseWholeSource(), # aCollapseAll
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  proc = loadThemeForIndex(0), # aTheme0
  proc = loadThemeForIndex(1), # aTheme1
  proc = loadThemeForIndex(2), # aTheme2
  proc = loadThemeForIndex(3), # aTheme3
  nil,
  nil,
  nil,
  nil,
  nil,
  proc = data.openLowLevelCode(), # aLowLevel1
  proc = data.toggleMinimap(), # aShowMinimap
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  proc = data.openLayoutTab(Content.PointList),
  nil,
  proc = data.openLayoutTab(Content.Calltrace),
  proc = data.openLayoutTab(Content.State),
  proc = data.openLayoutTab(Content.EventLog),
  proc = data.openLayoutTab(Content.TerminalOutput),
  proc = data.openLayoutTab(Content.StepList),
  proc = data.openLayoutTab(Content.Scratchpad),
  proc = data.openLayoutTab(Content.Filesystem),
  proc = data.openShellTab(),
  nil,
  nil,
  proc = data.addBreakpointAtPosition(),
  proc = data.removeBreakpointAtPosition(),
  proc = data.removeAllBreakpoints(),
  proc = data.enableBreakpointAtPosition(),
  proc = data.enableAllBreakpoints(),
  proc = data.disableBreakpointAtPosition(),
  proc = data.disableAllBreakpoints(),
  proc = data.addTracepointAtPosition(),
  proc = data.removeTracepointAtPosition(),
  proc = data.enableTracepointAtPosition(),
  proc = data.enableAllTracepoints(),
  proc = data.disableTracepointAtPosition(),
  proc = data.disableAllTracepoints(),
  proc = data.runTracepoints(),
  nil,
  nil,
  nil,
  nil,
  proc = data.ui.menu.toggle(),
  proc = data.zoomFlowLoopIn(),
  proc = data.zoomFlowLoopOut(),
  proc = data.switchFocusedLoopLevelUp(),
  proc = data.switchFocusedLoopLevelDown(),
  proc = data.switchFocusedLoopLevelAtPosition(),
  proc = data.setFlowTypeToMultiline(),
  proc = data.setFlowTypeToParallel(),
  proc = data.setFlowTypeToInline(),
  proc = data.restartCodetracer(),
  proc = data.findSymbol(),
  proc = data.reRecordCurrent(projectOnly=false),
  proc = data.reRecordCurrent(projectOnly=true),
  proc = data.restartSubsystem(name="db-backend"),
  proc = data.restartSubsystem(name="backend-manager"),
]

data.actions = actions

when not defined(ctInExtension):
  if not inElectron:
    var io {.importc.}: proc(address: cstring, options: JsObject): js
    var frontendSocketPort {.importc.}: int
    var frontendSocketParameters {.importc.}: cstring

    proc startIPC =
      let host = domwindow.location.hostname.to(cstring)
      let parameters = if frontendSocketParameters.len > 0:
          cstring"/" & frontendSocketParameters
        else:
          cstring""

      let port = if frontendSocketPort != -1:
          cstring($frontendSocketPort)
        else:
          domwindow.location.port.to(cstring)

      let protocol = domwindow.location.protocol.to(cstring)
      let wsProtocol = if protocol == cstring"https:":
          cstring"wss:"
        else: # assume http: , can it be different?
          cstring"ws:"
      let address = if port != cstring"":
          cstring(fmt"{wsProtocol}//{host}:{port}")
        else:
          cstring(fmt"{wsProtocol}//{host}")

      console.log protocol, wsProtocol, address
      var socket = io(
        address,
        js{withCredentials: false, query: cstring(fmt"socketParam={parameters}&pathname={domwindow.location.pathname.to(cstring)}")})
      socketdebug = socket
      socket.on(cstring"disconnect") do (reason: cstring):
        updateConnectionState(data, false, ConnectionLossUnknown, reason)
      socket.on(cstring"CODETRACER::connection-disconnected") do (payload: cstring):
        var parsedReason = ConnectionLossUnknown
        var detail = cstring""
        try:
          let parsed = JSON.parse(payload)
          if not parsed.isNil and not parsed[cstring"reason"].isUndefined:
            parsedReason = connectionReasonFromPayload(cast[cstring](parsed[cstring"reason"]))
          if not parsed.isNil and not parsed[cstring"message"].isUndefined:
            detail = cast[cstring](parsed[cstring"message"])
        except:
          discard
        updateConnectionState(data, false, parsedReason, detail)
      socket.on(cstring"connect") do ():
        updateConnectionState(data, true, ConnectionLossNone, cstring"")
        ipc = js{
          send: proc(id: cstring, response: js) =
            if not data.connection.connected:
              showDisconnectedWarning(data, data.connection.reason, data.connection.detail)
            console.log cstring"=> ", id, response
            socket.emit(id, response),
          on: proc(id: cstring, code: js) = socket.on(id, proc(response: cstring) =
            console.log cstring"<= ", id, response
            code.call(code, undefined, JSON.parse(response))
            )}
        data.ipc = ipc
        configureIPC(data)
        configure(data)

    startIPC()

when defined(ctInExtension):
  once:
    # configureIPC(data)
    configure(data)

if inElectron:
  once:
    configureIPC(data)
    configure(data)


# else:
  # configureIPC = functionAsJs(configureIPCRun)
