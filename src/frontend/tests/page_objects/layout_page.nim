import
  ../testing_framework/extended_web_driver,
  base_page,
  async,
  strutils,
  lib, strformat,
  sequtils,
  sets,
  macros,
  os,
  jsffi,
  jsconsole,
  tables,
  /layout_page_model


type TabObject* = ref object of RootObj
  root*: PageElement
  tabButtonText*: cstring

type ProgramStateVariable* = ref object of RootObj
  root*: PageElement

type ProgramStateTab* = ref object of TabObject
  internalProgramStateVariables: seq[ProgramStateVariable]

type
  EventElementType* = enum
    notSet, eventLog, tracePointEditor
  EventElement* = ref object of RootObj
    root*: PageElement
    elementType*: EventElementType

type EventLogTab* = ref object of TabObject
  internalEvents: seq[EventElement]

type TextRow* = ref object of RootObj
  root*: PageElement

type EditorTab* = ref object of TabObject
  filePath*: cstring
  fileName*: cstring
  idNumber*: int

type TracepointEditor* = ref object of RootObj
  parentEditorTab*: EditorTab
  lineNumber*: int
  idNumber*: int
  internalEventElements*: seq[EventElement]

type CallTraceTab* = ref object of TabObject

type LayoutPage* = ref object of BasePage
  internalEventLogTabs: seq[EventLogTab]
  internalEditorTabs: seq[EditorTab]
  internalEditorTabsTable: JsAssoc[cstring, EditorTab]
  internalProgramStateTabs: seq[ProgramStateTab]
  internalMenuItemChain: JsAssoc[cstring, cstring]
  internalCallTraceTabs: seq[CalltraceTab]

proc tabButton*(driver: ExtendedWebDriver, tabSelector: cstring, tabButtonText: cstring, retryCount: int = 0): Future[PageElement] {.async.}
proc tabButton*(tabRoot: PageElement, tabButtonText: cstring, retryCount: int = 0) : Future[PageElement] {.async.}

proc isVisible*(tab: TabObject): Future[bool] {.async.} =
  let tabContainer = tab.root.domParent()
  let tabContainerStyle = $(await tabContainer.getAttribute("style"))
  return not tabContainerStyle.contains("none")

# --- Call Graph Tab ---

#TODO: continue when ids have been changed to classses
# proc searchTextBox(tab: CallTraceTab): PageElement =

# --- Program State Tab ---

proc watchExpressionTextBox*(tab: ProgramStateTab): PageElement =
  return tab.root.findElement("#watch")

proc programStateVariables*(tab: ProgramStateTab, forceReload: bool = false): Future[seq[ProgramStateVariable]] {.async.} =
  if forceReload or tab.internalProgramStateVariables.len == 0:
    let containerElements = await tab.root.findElements(".value-expanded")
    tab.internalProgramStateVariables = @[]
    for element in containerElements:
      var newProgramStateVariable = ProgramStateVariable()
      newProgramStateVariable.root = element
      tab.internalProgramStateVariables.add(newProgramStateVariable)
  return tab.internalProgramStateVariables

proc name*(variable: ProgramStateVariable): Future[cstring] {.async.} =
  let textBox = variable.root.findElement(".value-name")
  let name = await textBox.text()
  return name

proc valueType*(variable: ProgramStateVariable): Future[cstring] {.async.} =
  let textBox = variable.root.findElement(".value-type")
  let valueType = await textBox.text()
  return valueType

proc value*(variable: ProgramStateVariable): Future[cstring] {.async.} =
  let textBox = variable.root.findElement(".value-expanded-text")
  let value = await textBox.getAttribute("textContent")
  return value

# ---  Event log tab ---

proc autoScrollButton*(tab: EventLogTab): PageElement =
  return tab.root.findElement(".checkmark")

proc footerContainer*(tab: EventLogTab): PageElement =
  return tab.root.findElement(".data-tables-footer")

proc rowsInfoContainer*(tab: EventLogTab): PageElement =
  return tab.footerContainer.findElement(".data-tables-footer-info")

proc rows*(tab: EventLogTab): Future[int] {.async.} =
  var input = await tab.footerContainer.getAttribute(cstring("class"))

  let pattern = regex("""(\d*)to""")
  var matches = input.matchAll(pattern)

  return (matches[0][0]).parseJsInt()

proc toRow*(tab: EventLogTab): Future[int] {.async.} =
  var input = await tab.rowsInfoContainer.text

  let pattern = regex("""(\d*)\sof""")
  var matches = input.matchAll(pattern)

  return (matches[0][0]).parseJsInt()

proc ofRows*(tab: EventLogTab): Future[int] {.async.} =
  var input = await tab.rowsInfoContainer.text

  let pattern = regex("""of\s(\d*)""")
  var matches = input.matchAll(pattern)

  return (matches[0][1]).parseJsInt()

# --- Event Log Events ---

proc eventElementRoots*(eventlogTab: EventLogTab): Future[seq[PageElement]] {.async.} =
  return await eventlogTab.root.findElements(cstring(".eventLog-dense-table tbody tr"))

proc tickCount*(event: EventElement): Future[int] {.async.} =
  return (await event.root.findElement(cstring(".rr-ticks-time")).text).parseJsInt()

proc index*(event: EventElement): Future[int] {.async.} =
  return (await event.root.findElement(cstring(".eventLog-index")).text).parseJsInt()

proc consoleOutput*(event: EventElement): Future[cstring] {.async.} =
  var locator = &"EventElementType {event.elementType} not implemented in proc consoleOutput*(event: EventElement)"
  if event.elementType == EventElementType.eventLog:
    locator = ".eventLog-text"
  if event.elementType == EventElementType.tracePointEditor:
    locator = "td.trace-values"
    # for some reason .text would not give a result for event elements in tracelog editors
    return await event.root.findElement(locator).getAttribute("innerHTML")
  echo "before locator------------------"
  echo locator
  
  let element = event.root.findElement(cstring(locator))
  echo "after element -=---------"
  echo element.selector
  echo element.selectorType
  echo element.parentElement.isNil
  echo element.parentElement.selector

  let text = await element.text()
  echo text
  
  return text

proc eventElements*(eventLogTab: EventLogTab, forceReload: bool = false): Future[seq[EventElement]] {.async.} =
  if forceReload or eventLogTab.internalEvents.len == 0:
    let containerElements = await eventElementRoots(eventLogTab)
    eventlogTab.internalEvents = @[]
    for element in containerElements:
      var newEvent = EventElement()
      newEvent.root = element
      newEvent.elementType = EventElementType.eventLog
      eventLogTab.internalEvents.add(newEvent)
  return eventLogTab.internalEvents

# --- Editor Component ---

proc editorLinesRoot*(editorTab: EditorTab): PageElement =
  return editorTab.root.findElement(".view-lines")

proc lineJumpTextBox*(editorTab: EditorTab): PageElement =
  return editorTab.root.findElement(".monaco-quick-open-wdget")

proc gutterRoot*(editorTab: EditorTab): PageElement =
  return editorTab.root.findElement(".margin-view-overlays")

proc highlightedLineNumber*(editorTab: EditorTab): Future[int] {.async.} =
  let isHighlightedRowOnScreen = (await editorTab.root.findElements(".on")).len > 0

  if isHighlightedRowOnScreen:
    let highlitedElement = editorTab.root.findElement(".on")

    let highlitedElementClasses = await highlitedElement.getAttribute("class")
    #example class: "cdr on on-41"
    let pattern = regex("""on-(\d*)""")
    var matches = highlitedElementClasses.matchAll(pattern)

    return parseInt($(matches[0][1]))
  return -1

proc visibleTextRows*(editorTab: EditorTab): Future[seq[TextRow]] {.async.} =
  var linesOfCode: seq[TextRow] = @[]

  let lineElements = await findElements(editorTab.root, ".view-line")

  for lineElement in lineElements:
    var newLineOfCode = TextRow()

    #echo await lineElement.text

    newLineOfCode.root = lineElement;

    linesOfCode.add(newLineOfCode)

  return linesOfCode

# ---  Layout Page  ---

proc runToEntryButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#run-to-entry-debug")

proc continueButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#continue-debug")

proc reverseContinueButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#reverse-continue-debug")

proc stepOutButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#step-out-debug")

proc reverseStepOutButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#reverse-step-out-debug")

proc stepInButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#step-in-debug")

proc reverseStepInButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#reverse-step-in-debug")

proc nextButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#next-debug")

proc reverseNextButton*(page: LayoutPage): PageElement =
  return page.driver.findElement("#reverse-next-debug")

proc tabGroupContainers*(page: LayoutPage): Future[seq[PageElement]] {.async.} =
  return findElements(page.driver, ".lm_stack")

#------ Menu -----

proc menuRootButton*(page: LayoutPage): PageElement =
  return findElement(page.driver, "#menu-root-name")

proc menuSearchTextBox*(page: LayoutPage): PageElement =
  return findElement(page.driver, "#menu-search-text")

#The layoutPage parameter is not used. It is meant to
proc menuItemChain*(layoutPage: LayoutPage, forceReload: bool = false): JsAssoc[cstring, cstring] =
  if forceReload or layoutPage.internalMenuItemChain.len == 0:

    layoutPage.internalMenuItemChain = JsAssoc[cstring, cstring]{}

    let mainMenu = [
      "File",
      "Edit",
      "View",
      "Navigate",
      "Build",
      "Debug",
      "Help"
    ]
    for key in mainMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "".cstring

    let fileMenu = [
      "New File",
      "Preferences",
      "Open File",
      "Open Folder",
      "Open Recent",
      "Save",
      "Save As ...",
      "Save All",
      "Close Tab",
      "Reopen Tab",
      "Next Tab",
      "Prev Tab",
      "Switch Tab",
      "Close All Documents",
      "Exit"
    ]
    for key in fileMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "File".cstring

    #--- Edit ---

    let editMenu = [
      "Undo",
      "Redo",
      "Cut",
      "Copy",
      "Paste",
      "Replace",
      "Find in Files",
      "Replace in Files",
      "Expand All",
      "Collapse All",
      "Advanced",
      "Delete"
    ]
    for key in editMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Edit".cstring

    # #--- Edit -> Advanced

    let editAdvancedMenu = [
      "Toggle Comment",
      "Increase Indentation",
      "Decrease Indentation",
      "Make Uppercase",
      "Make Lowercase"
    ]
    for key in editAdvancedMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Advanced".cstring

    #--- View

    let viewMenu = [
      "Panes",
      "Layouts",
      "New Horizontal Tab Group",
      "New Vertical Tab Group",
      "Notifications",
      "Start Window",
      "Full Screen Toggle",
      "Choose App Theme",
      "Choose Monaco Theme",
      "Multi-line Preview Mode",
      "No Preview",
      "View C Code (here it depends on Lang for project)",
      "View Assembly Code (similar: can be llvm ir)",
      "Zoom In",
      "Zoom Out",
      "Show Minimap"
    ]
    for key in viewMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "View".cstring

    #--- View -> Panes

    let viewPanesMenu = [
      "New",
      "Program Call Trace",
      "Program State Explorer",
      "Event Log",
      "Shell",
      "Find Results",
      "Build Log",
      "File Explorer"
    ]
    for key in viewPanesMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Panes".cstring

    #--- View -> Layouts

    let viewLayoutsMenu = [
      "Save Layout",
      "Load Layout",
      "Debug (Normal Screen)",
      "Debug (Wide Screen)",
      "Edit (Normal Screen)",
      "Edit (Wide Screen)"
    ]
    for key in viewLayoutsMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Layouts".cstring

    #--- View -> Choose app theme

    let viewChooseAppThemeMenu = [
      "Mac Classic Theme",
      "Default White Theme",
      "Default Black Theme",
      "Default Dark Theme"
    ]
    for key in viewChooseAppThemeMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Choose App Theme".cstring

    #--- View -> Choose Monaco Theme

    let viewChooseMonacoThemeMenu = [
      "vs-light"
    ]
    for key in viewChooseMonacoThemeMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Choose Monaco Theme".cstring

    #--- Navigate

    let navigateMenu = [
      "Go to File",
      "Go to Symbol",
      "Go to Definition",
      "Find References",
      "Go to Line",
      "Go to Previous Cursor Location",
      "Go to Next Cursor Location",
      "Go to Previous Edit Location",
      "Go to Next Edit Location",
      "Go to Previous Point in Time",
      "Go to Next Point in Time",
      "Go to Next Error",
      "Go to Previous Error",
      "Go to Next Search Result",
      "Go to Previous Search Result",
      "Trace Existing Program..."
    ]

    for key in navigateMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Navigate".cstring

    #--- Build

    let buildMenu = [
      "Build Project",
      "Compile Current File (Nim Check)",
      "Run Static Analysis (drnim)"
    ]
    for key in buildMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Build".cstring

    #--- Debug

    let debugMenu = [
      "Trace Existing Program...",
      "Load Existing Trace...",
      "Options",
      "Start Debugging",
      "Continue",
      "Step Over",
      "Step In",
      "Step Out",
      "Reverse Continue",
      "Reverse Step Over",
      "Reverse Step In",
      "Reverse Step Out",
      "Stop Debugging",
      "Add a Breakpoint",
      "Delete Breakpoint",
      "Delete All Breakpoints",
      "Enable Breakpoint",
      "Enable All Breakpoints",
      "Disable Breakpoint",
      "Disable All Breakpoints",
      "Add a Tracepoint",
      "Delete Tracepoint",
      "Enable Tracepoint",
      "Enable All Tracepoints",
      "Disable Tracepoint",
      "Disable All Tracepoints",
      "Collect Tracepoint Results"
    ]
    for key in debugMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Debug".cstring

    let helpMenu = [
      "User Manual (TODO)",
      "Report a Problem (TODO)",
      "Suggest a Feature",
      "About (TODO)"
    ]
    for key in helpMenu:
      layoutPage.internalMenuItemChain[key.cstring] = "Help".cstring

  return layoutPage.internalMenuItemChain

proc visibleMenuItems(page: LayoutPage): Future[JsAssoc[cstring, PageElement]] {.async.} =

  var menuNodes = await page.driver.findElements(".menu-node-name")
  var menuNodeDictionary = JsAssoc[cstring, PageElement]{}

  for menuNode in menuNodes:
    menuNodeDictionary[await menuNode.text()] = menuNode
    #keep this comment for debugging purposes
    #echo &"visibleMenuItems menuNode: {await menuNode.text()}"

  return menuNodeDictionary


proc menuItem*(page: LayoutPage,menuItemName: cstring): Future[PageElement] {.async.} =
  if not page.menuItemChain.hasKey(menuItemName):
    raise ElementNotFoundException.newException(&"No menu element with name: {menuItemName} is defined in the menuItemChain")

  if not (await visibleMenuItems(page)).hasKey(menuItemName):
    let previousInChainName = menuItemChain(page)[menuItemName]
    var previousElement = PageElement()
    if previousInChainName == "":
      previousElement = page.menuRootButton
    else:
      previousElement = await menuItem(page, previousInChainName)

    await previousElement.click()

    for i in 0 .. (defaultWaitForElement div defaultWaitInterval):
      #keep comment for debugging purposes
      #echo &"waiting for {menuItemName}"
      if (await visibleMenuItems(page)).hasKey(menuItemName):
        break
      await wait(defaultWaitInterval)

  if not (await visibleMenuItems(page)).hasKey(menuItemName):
     raise ElementNotFoundException.newException(&"{menuItemName} is defined in the menuItemChain but was not found, uncomment echo in proc visibleMenuItems")
  return (await visibleMenuItems(page))[menuItemName]

#------ Tabs -----

#TODO: simplify by using xpath to get parent element instead of iterating trough all possible tabs
proc tabButton*(driver: ExtendedWebDriver, tabSelector: cstring, tabButtonText: cstring, retryCount: int = 0): Future[PageElement] {.async.} =

  let allTabGroups = await findElements(driver, ".lm_stack")
  for tabGroup in allTabGroups:
    let elementsInCurrentTabGroup = await tabGroup.findElements(tabSelector)
    if elementsInCurrentTabGroup.len > 0:
      let allTabButtonsInGroup = await tabGroup.findElements(".lm_title")
      for currentTabButton in allTabButtonsInGroup:
        let currentTabButtonText = await currentTabButton.text
        if currentTabButtonText == tabButtonText:
          return currentTabButton
      raise ElementNotFoundException.newException(&"A tab with selector: {tabSelector} has been found but no button with text: {tabButtonText}")
  if retryCount * defaultWaitInterval <= defaultWaitForElement:
    await wait(defaultWaitInterval)
    return await tabButton(driver, tabSelector, tabButtonText, retryCount + 1)
  raise ElementNotFoundException.newException(&"No tab with selector: {tabSelector} has been found")

proc tabButton*(tabRoot: PageElement, tabButtonText: cstring, retryCount: int = 0) : Future[PageElement] {.async.} =
  return tabButton(tabRoot.driver, tabRoot.selector, tabButtonText, retryCount)

proc tabButton*(tab: TabObject): Future[PageElement] {.async.} =
  return tabButton(tab.root, tab.tabButtonText)

proc isTabActive*(tab: TabObject): Future[bool] {.async.} =
  let tabButton = await tab.tabButton()
  let tabButtonContainer = tabButton.findElement("""//parent::li""", SelectorType.xpath)
  let class = $(await tabButtonContainer.getAttribute("class"))
  #echo &"tab button classes: {class}"
  if class.contains("lm_active"):
    return true
  else:
    return false

proc eventLogTabs*(layoutPage: LayoutPage, forceReload: bool = false): Future[seq[EventLogTab]] {.async.} =
  if forceReload or layoutPage.internalEventLogTabs.len == 0:
    layoutPage.internalEventLogTabs = @[]
    let tabRoots = await layoutPage.driver.findElements("div[id^='eventLogComponent-']")

    for tabRoot in tabRoots:
      var tab = EventLogTab()
      #convert list elements to individual pageElements
      let tabId = await tabRoot.getAttribute("id")
      tab.root = layoutPage.driver.findElement(&"#{tabId}")

      tab.tabButtonText = "EVENT LOG"

      layoutPage.internalEventLogTabs.add(tab)

  return layoutPage.internalEventLogTabs

proc programStateTabs*(layoutPage: LayoutPage, forceReload: bool = false): Future[seq[ProgramStateTab]] {.async.} =
  if forceReload or layoutPage.internalEventLogTabs.len == 0:
    layoutPage.internalProgramStateTabs = @[]
    let tabRoots = await layoutPage.driver.findElements("div[id^='stateComponent-']")

    for tabRoot in tabRoots:
      var tab = ProgramStateTab()
      #convert list elements to individual pageElements
      let tabId = await tabRoot.getAttribute("id")
      tab.root = layoutPage.driver.findElement(&"#{tabId}")

      tab.tabButtonText = "STATE"

      layoutPage.internalProgramStateTabs.add(tab)

  return layoutPage.internalProgramStateTabs

proc editorTabs*(layoutPage: LayoutPage, forceReload: bool = false): Future[seq[EditorTab]] {.async.} =
  if forceReload or layoutPage.internalEditorTabs.len == 0:
    layoutPage.internalEditorTabs = @[]
    let tabRoots = await layoutPage.driver.findElements("div[id^='editorComponent-']")

    for tabRoot in tabRoots:
      var tab = EditorTab()

      # convert list elements to individual pageElements
      let idAttributeText = await tabRoot.getAttribute("id")
      tab.root = layoutPage.driver.findElement(&"#{idAttributeText}")

      let extractNumberRegexPattern = regex("""(\d)""")
      let extractedId = idAttributeText.matchAll(extractNumberRegexPattern)

      tab.idNumber = (extractedId[0][0]).parseJsInt()

      tab.filePath = await tab.root.getAttribute("data-label")
      var regexInput = tab.filePath

      let fileNamePattern = regex("""(?!\/)(?:.(?!\/))+$""")
      var fileNameMatches = regexInput.matchAll(fileNamePattern)

      let tabButtonTextPattern = regex("""[^\/]*\/(?!\/)(?:.(?!\/))+$""")
      var tabButtonTextMatches = regexInput.matchAll(tabButtonTextPattern)

      tab.fileName = fileNameMatches[0][0]
      tab.tabButtonText = tabButtonTextMatches[0][0]
      layoutPage.internalEditorTabs.add(tab)

  return layoutPage.internalEditorTabs

proc editorTabsTable*(layoutPage: LayoutPage, forceReload: bool = false): Future[JsAssoc[cstring, EditorTab]] {.async.} =
  if forceReload or layoutPage.internalEditorTabsTable.len == 0:
    layoutPage.internalEditorTabsTable = JsAssoc[cstring, EditorTab]{}

    let tabs = await layoutPage.editorTabs()

    for tab in tabs:
      layoutPage.internalEditorTabsTable[tab.filePath] = tab

  return layoutPage.internalEditorTabsTable

proc editorTabFromFileName*(page: LayoutPage, fileName: cstring): Future[seq[EditorTab]] {.async.} =
  let editors = await editorTabs(page)

  echo "editors"
  echo editors.len()
  echo "for debug-----------------"
  echo filename
  
  for editor in editors:
    echo editor.fileName

  let filteredEditors = editors.filterIt(($it.fileName) == ($fileName))
  echo filteredEditors.len()
  return filteredEditors

proc editorTabFromContainsPath*(page: LayoutPage, fileName: cstring): Future[seq[EditorTab]] {.async.} =
  let editors = await editorTabs(page)
  return editors.filterIt(($fileName).contains(($it.fileName)))

proc callTraceTabs*(page: LayoutPage, forceReload = false): Future[seq[CallTraceTab]] {.async.} =
  if forceReload or page.internalCallTraceTabs.len == 0:
    page.internalCallTraceTabs = @[]
    let tabRoots = await page.driver.findElements("div[id^='calltraceComponent-']")

    for tabRoot in tabRoots:
      var tab = CallTraceTab()
      #convert list elements to individual pageElements
      let tabId = await tabRoot.getAttribute("id")
      tab.root = page.driver.findElement(&"#{tabId}")

      tab.tabButtonText = "CALLTRACE"

      page.internalCallTraceTabs.add(tab)

  return page.internalCallTraceTabs

#---

proc jumpToEvent*(event: EventElement): Future[void] {.async.} =
  #TODO: add scroll to
  await event.root.click()

proc jumpToEvent*(layoutPage: LayoutPage, index: int): Future[void] {.async.} =
  let eventLogTabs = await layoutPage.eventLogTabs
  let eventLogTabButton = await eventLogTabs[0].tabButton
  await eventLogTabButton.click()

  for i in 0 .. defaultWaitForElement div defaultWaitInterval:
    let events = await eventLogTabs[0].eventElements()
    if events.len <= index:
      await wait(defaultWaitInterval)
    else:
      await jumpToEvent(events[index])
      break

proc gotoLine*(editorTab: EditorTab, line: int): Future[void] {.async.} =
  let script = """
  var callback = arguments[arguments.length - 1];
  var tabRoot = arguments[0][0];
  var lineNumber = arguments[0][1];

  tabRoot.focus();

  gotoLine(lineNumber);

  callback(null);
  """.cstring

  discard await executeAsyncScript(editorTab.root.driver, script,await editorTab.root.wrappedElement ,line.toJs)

  return

proc tracePointEditor*(editorTab: EditorTab, lineNumber: int): TracePointEditor =
  var tracePointEditor = TracePointEditor()
  tracePointEditor.lineNumber = lineNumber
  tracePointEditor.parentEditorTab = editorTab

  return tracePointEditor

proc tracePointEditors*(editorTab: EditorTab): Future[seq[TracePointEditor]] {.async.} =
  var tracePointEdiors: seq[TracePointEditor] = @[]

  var rootElements = await editorTab.root.findElements(".trace")

  for root in rootElements:
    let editElement = root.findElement(".edit")
    let editElementIdText = await editElement.getAttribute("id")

    let lineNumberRegexPattern = regex("""edit-trace-\d*-(\d*)""")
    let lineNumber = (editElementIdText.matchAll(lineNumberRegexPattern)[0][1]).parseJsInt()

    tracePointEdiors.add(tracePointEditor(editorTab, lineNumber))

  return tracePointEdiors

proc openTracePointEditor*(editorTab: EditorTab, lineNumber: int): Future[TracePointEditor] {.async.} =
  let script = """
  var callback = arguments[arguments.length - 1];
  var lineNumber = arguments[0][0];
  var path = arguments[0][1];

  toggleTracepoint(path, lineNumber);

  callback(null);
  """.cstring

  await editorTab.gotoLine(lineNumber)
  discard await executeAsyncScript(editorTab.root.driver, script, lineNumber.toJs, editorTab.filePath.toJs)

  return tracePointEditor(editorTab, lineNumber)

# proc focusTracePointEdiorCodeTextBox*(tracePoint: TracePointEditor): Future[void] {.async.} =
#   await tracePoint.parentEditorTab.root.findElement(&"#edit-trace-{tracePoint.parentEditorTab.idNumber}-{tracePoint.lineNumber} textArea").jsFocusElement()

proc root*(tracePoint: TracePointEditor): PageElement =
  return tracePoint.parentEditorTab.root.findElement(&"//*[@id='edit-trace-{tracePoint.parentEditorTab.idNumber}-{tracePoint.lineNumber}']/ancestor::*[@class='trace']", SelectorType.xpath)

proc editTextBox*(tracePoint: TracePointEditor): PageElement =

  return tracePoint.root.findElement(&"textarea")

proc runTracePoints*(page: LayoutPage): Future[void] {.async.} =
  let script = """
  var callback = arguments[arguments.length - 1];

  runTracepoints();

  callback(null);
  """.cstring

  discard await executeAsyncScript(page.driver, script)
  return

proc openTracePointEditor*(page: LayoutPage, model: TracePointEditorModel): Future[TracePointEditor] {.async.} =

  let editors = (await editorTabFromFileName(page, model.filename))

  let editor = editors[0]

  await (await editor.tabButton).click()

  let traceEditor = await openTracePointEditor(editor, model.lineNumber)

  # TODO: add dynamic wait below
  await wait(2000)

  await traceEditor.editTextBox.sendKeys($model.code)

proc eventElements*(tracePointEditor: TracePointEditor, forceReload: bool = false): Future[seq[EventElement]] {.async.} =
  if forceReload or tracePointEditor.internalEventElements.len == 0:
    tracePointEditor.internalEventElements = @[]
    for element in await tracePointEditor.root.findElements(".trace-view tbody tr"):
      var newEvent = EventElement()
      newEvent.root = element
      newEvent.elementType = EventElementType.tracePointEditor
      tracePointEditor.internalEventElements.add(newEvent)
  return tracePointEditor.internalEventElements

proc waitForEventLogTabLoad*(page: LayoutPage): Future[void] {.async.} =
  var eventLogTab = EventLogTab()
  for i in 0 .. defaultWaitForElement div defaultWaitInterval:
    let eventLogTabs = await eventLogTabs(page, true)
    if eventLogTabs.len > 0:
      eventLogTab = eventLogTabs[0]
      break
    await wait(defaultWaitInterval)
  return

# Continue from here
# add code from trace points to snapshots
# proc code(tracePointEditor: TracePointEditor): Future[cstring] {.async.} =
