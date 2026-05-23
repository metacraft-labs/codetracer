import
  service_imports,
  ../[ types, utils ],
  ../lib/[ logging, jslib ]

proc switchHistory*(self: EditorService, path: cstring, editorView: EditorView) =
  clog "tabs: switchHistory: " & $path & " " & $editorView
  for index, tab in self.tabHistory:
    if tab.name == path:
      delete(self.tabHistory, index..index)
      break
  self.tabHistory.add(EditorViewTabArgs(name: path, editorView: editorView))
  self.historyIndex = self.tabHistory.len - 1
  clog "tabs: switchHistory: historyIndex -> " & $self.historyIndex


data.services.editor.onCompleteMove = proc(self: EditorService, response: MoveState) {.async.} =
  if response.location.path.len > 0 and not response.location.isExpanded: # TODO: exists path
    if not response.location.missingPath:
      let editorPath = canonicalSourceRevisionPath(response.location.path)
      # Pass the active line through to ``openTab`` so a freshly opened
      # editor (e.g. a calltrace-jump landing on a file that was not yet
      # open — the noir-space-ship "calculate damage" navigation jumps
      # to ``shield.nr:22`` from an open ``main.nr``) seeds the Monaco
      # cursor at the right line.  ``openTab`` only forwards the line
      # when creating the editor for the first time, so already-open
      # editors are unaffected — the per-component
      # ``onCompleteMove`` subscription handles their position update
      # via ``service.changeLine`` and the periodic ``gotoLine`` interval.
      self.data.openTab(editorPath, line = response.location.line)
    else:
      # eventually TODO(alexander: I wrote this: a more elegant way to pass
      # to the component)
      let noInfoMessage = cstring(
        fmt"We were not able to open the given location path: maybe a missing/internal file: {response.location.path}")
      echo "no source!"
      self.data.openTab("NO SOURCE", ViewNoSource, noInfoMessage = noInfoMessage)
  else:
    discard

  # Run-to-entry, calltrace jumps, and other moves can arrive before a newly
  # opened editor component has mounted and subscribed to CtCompleteMove.
  # `openTab` above uses `location.path`, while some source-mapped traces use
  # `highLevelPath` as the editor-facing key. Cache under both non-empty keys
  # so `EditorViewComponent.afterInit` can replay the move regardless of which
  # path variant named the tab.
  if response.location.highLevelPath.len > 0:
    self.completeMoveResponses[response.location.highLevelPath] = response
    self.completeMoveResponses[canonicalSourceRevisionPath(response.location.highLevelPath)] = response
  if response.location.path.len > 0 and response.location.path != response.location.highLevelPath:
    self.completeMoveResponses[response.location.path] = response
    self.completeMoveResponses[canonicalSourceRevisionPath(response.location.path)] = response

data.services.editor.onOpenedTab = proc(self: EditorService, response: OpenedTab) {.async.} =
  # kout2 response
  clog "editor service: onOpenedTab"
  self.data.openTab(response.path, ViewSource) # , response.lang)


proc openExpanded*(self: EditorService, location: types.Location) {.async.} =
  # isExpanded true
  let name = cstring(&"expanded-{location.expansionFirstLine}")

  let existing = self.expandedOpen.hasKey(name)
  if not self.expandedOpen.hasKey(name):
    self.expandedOpen[name] = TabInfo() # guard against next entering the function before loading all in the current call

  var parentName = cstring""
  let parentLocation = location.expansionParents[0]
  var parentEditor: EditorViewComponent
  if location.expansionParents.len > 1:
    let parentId = location.expansionParents[1][2] # (parent of parent)'s first line
    parentName = cstring(&"expanded-{parentId}")
    if self.expandedOpen.hasKey(parentName):
      # let expanded = self.expandedOpen[parentName]
      parentEditor = self.data.ui.editors[parentName]
    else:
      # TODO await self.openExpanded
      echo "TODO expand more than 1 levels: parent not open: ", parentLocation[0], " ", parentLocation[1]
      return
  else:
    parentName = parentLocation[0]
    parentEditor = self.data.ui.editors[parentName]

  # make sure it is expanded if it exists => after a new expand
  if existing:
    parentEditor.expanded[parentLocation[1]].isExpanded = true
    self.data.redraw()
    return

  var editorComponent = self.data.makeEditorViewComponent(
    self.data.generateId(Content.EditorView), location.highLevelPath, 1, name, ViewMacroExpansion, true, location, self.data.trace.lang)
  editorComponent.topLevelEditor = parentEditor.topLevelEditor
  var tabLoadLocation = location #TODO is this a new one-level clone?
  tabLoadLocation.functionName = name
  let tabInfo = await self.tabLoad(location, ViewMacroExpansion, self.data.trace.lang)
  self.expandedOpen[name] = tabInfo
  parentEditor.expanded[parentLocation[1]] = editorComponent
  editorComponent.tabInfo = tabInfo
  self.active = name
  self.data.redraw()

# TODO init

data.services.editor.onExpansionResponse = proc(self: EditorService, location: types.Location) {.async.} =
  ## Handle macro expansion DAP response (S6).
  ## When the location has expansion data, open the expanded code inline.
  ## Otherwise, navigate to the resolved high-level source location.
  if location.isExpanded:
    await self.openExpanded(location)
  elif location.highLevelPath.len > 0 and location.highLevelLine > 0:
    self.data.openTab(location.highLevelPath, ViewSource, line = location.highLevelLine)

proc tabInfoForPath*(self: EditorService, path: cstring): TabInfo =
  if not path.isNil and path.len > 0:
    if self.open.hasKey(path):
      return self.open[path]
    elif self.expandedOpen.hasKey(path):
      return self.expandedOpen[path]
    elif self.cachedFiles.hasKey(path):
      return self.cachedFiles[path]
  return nil

proc loadSourceLine*(self: EditorService, location: Location): cstring =
  let tabInfo = self.tabInfoForPath(location.path)
  if not tabInfo.isNil:
    if location.line < tabInfo.sourceLines.len:
      tabInfo.sourceLines[location.line]
    else:
      cstring"<not found>"
  else:
    cstring"<not found>"

proc activeTabInfo*(self: EditorService): TabInfo =
  self.tabInfoForPath(self.active)

func restart*(service: EditorService) =
  discard
