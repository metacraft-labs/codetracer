## Headless regression tests for the New Trace tab and caption chrome contract.
##
## The runtime code that creates a new trace tab lives in the JS/Electron
## frontend and is coupled to DOM and GoldenLayout objects, so this test keeps
## the guard headless by checking the production source contract that the
## Electron path must satisfy:
##
## - createNewSession creates an empty welcome-screen session, not a blank
##   non-trace session.
## - createNewSession inherits the current menu model so the welcome tab keeps
##   the CodeTracer icon/menu instead of rendering a chrome-less blank bar.
## - createNewSession initializes the shared caption chrome components for the
##   newly-active session.
## - switchSession routes empty welcome sessions through initLayout so the
##   welcome surface and shared chrome are mounted.
## - initLayout installs shared chrome renderers before taking the welcome
##   screen early return.
##
## The rendered DOM shape for the menu/debug/controls hosts is covered in
## ``views/isonim_views_test.nim``.  Together these tests catch the regressions
## where clicking "+" / "New Trace" produced a blank screen and the caption bar
## lost the CodeTracer menu, omnibox, or debug toolbar hosts.
##
## One contract here is *not* a source contract: the edit-mode layout
## sanitiser is JavaScript (``index/layout_config_repair.nim``), so it is
## executed for real in the ``nim js`` suite at the top of the file, and the
## native suite only asserts what a native run can — which panels edit mode
## declares hidden, and that the production call sites route through that
## module.  It used to grep the sanitiser's implementation text out of
## ``index/config.nim``, which broke the moment issue #608 moved that text
## without changing what it does.

import std/[strutils, unittest]

const
  SessionSwitchPath = "src/frontend/ui/session_switch.nim"
  LayoutPath = "src/frontend/ui/layout.nim"
  RendererPath = "src/frontend/renderer.nim"
  DebugPath = "src/frontend/ui/debug.nim"
  IndexPath = "src/frontend/index.nim"
  IndexTracesPath = "src/frontend/index/traces.nim"
  IndexConfigPath = "src/frontend/index/config.nim"
  UiJsPath = "src/frontend/ui_js.nim"

proc sectionBetween(source, startMarker, endMarker: string): string =
  let start = source.find(startMarker)
  check start >= 0
  if start < 0:
    return ""

  let bodyStart = start + startMarker.len
  if endMarker.len == 0:
    return source[bodyStart .. ^1]

  let stop = source.find(endMarker, bodyStart)
  check stop > bodyStart
  if stop <= bodyStart:
    return source[bodyStart .. ^1]

  source[bodyStart ..< stop]

proc indexOfRequired(source, needle: string): int =
  result = source.find(needle)
  check result >= 0

when defined(js):
  ## Nim's JavaScript backend does not provide the filesystem reads the source
  ## contracts below need, and the structural caption DOM checks run on this
  ## backend through ``views/isonim_views_test.nim``.  What *can* only run
  ## here is the edit-layout sanitiser itself: it is JavaScript
  ## (``index/layout_config_repair.nim`` is an ``importjs`` body over
  ## ``std/jsffi``), so this is the backend on which its behaviour is real.
  import std/jsffi
  import ../../../../frontend/index/layout_config_repair

  # ``Content`` ordinals, mirrored as literals so this test keeps the
  # dependency-free property of the module under test — the same convention
  # ``layout/layout_config_roundtrip_test.nim`` uses.  Source of truth:
  # ``src/common/common_types/codetracer_features/frontend.nim`` (``Content``).
  # The corresponding *names* are asserted against
  # ``index/config.nim``'s ``editModeHiddenContentIds()`` by the native suite
  # below, which is what keeps these numbers honest.
  const
    ContentTrace = 1
    ContentEditorView = 2
    ContentState = 4
    ContentCalltrace = 6
    ContentFilesystem = 9
    ContentTraceLog = 22
    ContentCalltraceEditor = 23
    ContentTerminalOutput = 24
    ContentNoInfo = 34
    ContentAgentActivity = 35

    EditModeHiddenContents = @[
      ContentTrace,
      ContentState,
      ContentCalltrace,
      ContentTraceLog,
      ContentCalltraceEditor,
      ContentTerminalOutput,
      ContentAgentActivity
    ]

  proc component(content: int; title: cstring; componentType: cstring): js =
    js{
      "type": cstring"component",
      "componentType": componentType,
      "componentState": js{"id": 0, "label": title, "content": content},
      "title": title
    }

  proc editorTab(title: cstring): js =
    component(ContentEditorView, title, cstring"editorComponent")

  proc genericTab(content: int; title: cstring): js =
    component(content, title, cstring"genericUiComponent")

  proc stackOf(activeItemIndex: int; children: seq[js]): js =
    js{
      "type": cstring"stack",
      "activeItemIndex": activeItemIndex,
      "content": children
    }

  proc debuggerLayout(): js =
    ## A layout saved by a replay session: an editor stack holding a source
    ## tab next to "CALLS" and "NO SOURCE", a side stack holding the
    ## Filesystem panel next to the debugger-only State panel, and a bottom
    ## stack carrying the remaining replay-only panels.  Every id in
    ## `EditModeHiddenContents` is present on purpose, so the assertions
    ## below cannot pass by asserting the absence of something that was never
    ## there.
    var replayOnly: seq[js] = @[]
    for hiddenContent in EditModeHiddenContents:
      if hiddenContent != ContentState and
          hiddenContent != ContentCalltraceEditor and
          hiddenContent != ContentTerminalOutput:
        replayOnly.add genericTab(hiddenContent, cstring"REPLAY PANEL")
    js{
      "root": js{
        "type": cstring"row",
        "content": @[
          stackOf(1, @[
            genericTab(ContentFilesystem, cstring"FILES"),
            genericTab(ContentState, cstring"STATE")]),
          stackOf(2, @[
            editorTab(cstring"main.rb"),
            genericTab(ContentCalltraceEditor, cstring"CALLS"),
            genericTab(ContentNoInfo, cstring"NO SOURCE"),
            genericTab(ContentTerminalOutput, cstring"OUTPUT")]),
          stackOf(0, replayOnly)
        ]
      }
    }

  suite "New Trace session chrome contract":

    test "edit layout sanitizer removes debugger-only panels":
      ## An edit session has no recording behind it, so the panels that only
      ## mean something during replay must not come back when the layout a
      ## replay session saved is reopened in edit mode.
      ##
      ## This used to be asserted by grepping the sanitiser's source text out
      ## of ``index/config.nim``; the implementation moved to
      ## ``index/layout_config_repair.nim`` (issue #608) and the grep failed
      ## while the behaviour was intact.  It is executed here instead, against
      ## the real production module.
      let before = debuggerLayout()
      for hiddenContent in EditModeHiddenContents:
        check layoutContainsContentId(before, hiddenContent)
      check layoutContainsContentId(before, ContentEditorView)

      let sanitized = sanitizeLayoutConfig(
        before, ContentEditorView, EditModeHiddenContents)

      for hiddenContent in EditModeHiddenContents:
        check not layoutContainsContentId(sanitized, hiddenContent)
      # The per-trace editor tabs go too: their `componentState.fullPath`
      # names a source file of whatever program was being debugged.
      check not layoutContainsContentId(sanitized, ContentEditorView)

      # Everything that is not debugger-only survives — the sanitiser must
      # not be "reset the layout" wearing a different name.
      check layoutContainsContentId(sanitized, ContentFilesystem)
      check layoutContainsContentId(sanitized, ContentNoInfo)

      # …and what survives is loadable: issue #608 is a stack whose
      # `activeItemIndex` still points past the tabs that were removed, which
      # GoldenLayout rejects in `Stack.init`.
      check stackActiveItemIndexInRange(sanitized)

    test "replay mode keeps the debugger-only panels the edit mode hides":
      ## The same call with an empty hidden set is the replay-mode save path
      ## (`sanitizeDefaultLayoutJson`).  Asserting both directions is what
      ## makes the test above a statement about the *edit-mode hidden set*
      ## rather than about the sanitiser dropping panels in general.
      let sanitized = sanitizeLayoutConfig(
        debuggerLayout(), ContentEditorView, @[])

      for hiddenContent in EditModeHiddenContents:
        check layoutContainsContentId(sanitized, hiddenContent)
      check not layoutContainsContentId(sanitized, ContentEditorView)
      check stackActiveItemIndexInRange(sanitized)
else:
  suite "New Trace session chrome contract":

    test "createNewSession creates a welcome-screen session":
      let source = readFile(SessionSwitchPath)
      let body = sectionBetween(source,
        "proc createNewSession*(data: Data) =",
        "proc closeSession*(data: Data, targetIndex: int) =")

      check body.contains("session.startOptions = StartOptions(")
      check body.contains("welcomeScreen: true")
      check body.contains("screen: true")
      check body.contains("trace.isNil") == false

    test "createNewSession initializes shared caption and welcome components":
      let source = readFile(SessionSwitchPath)
      let body = sectionBetween(source,
        "proc createNewSession*(data: Data) =",
        "proc closeSession*(data: Data, targetIndex: int) =")

      let activateIndex = indexOfRequired(body, "data.activeSessionIndex = sessionId")
      let debugIndex = indexOfRequired(body, "discard data.makeDebugComponent()")
      let menuIndex = indexOfRequired(body, "discard data.makeMenuComponent()")
      let commandPaletteIndex =
        indexOfRequired(body, "discard data.makeCommandPaletteComponent()")
      let welcomeIndex = indexOfRequired(body, "discard data.makeWelcomeScreenComponent()")
      let restoreIndex =
        indexOfRequired(body, "data.activeSessionIndex = previousActiveSessionIndex")

      check activateIndex < debugIndex
      check activateIndex < menuIndex
      check activateIndex < commandPaletteIndex
      check activateIndex < welcomeIndex
      check debugIndex < restoreIndex
      check menuIndex < restoreIndex
      check commandPaletteIndex < restoreIndex
      check welcomeIndex < restoreIndex

    test "createNewSession inherits menu state for welcome tab chrome":
      let source = readFile(SessionSwitchPath)
      let body = sectionBetween(source,
        "proc createNewSession*(data: Data) =",
        "proc closeSession*(data: Data, targetIndex: int) =")

      let componentsIndex = indexOfRequired(body, "session.ui = Components(")
      let menuNodeIndex = indexOfRequired(body, "session.ui.menuNode = data.ui.menuNode")
      let launchConfigsIndex =
        indexOfRequired(body, "session.ui.launchConfigs = data.ui.launchConfigs")
      let mappingIndex = indexOfRequired(body, "for content in Content:")

      check componentsIndex < menuNodeIndex
      check menuNodeIndex < mappingIndex
      check componentsIndex < launchConfigsIndex
      check launchConfigsIndex < mappingIndex

    test "switchSession mounts empty welcome sessions through initLayout":
      let source = readFile(SessionSwitchPath)
      let body = sectionBetween(source,
        "proc switchSession*(data: Data, targetIndex: int) =",
        "")

      let branchIndex =
        indexOfRequired(body, "elif session.ui.layout.isNil and session.startOptions.welcomeScreen:")
      let initIndex =
        indexOfRequired(body, "callInitLayoutSafe(session.savedLayoutConfig, targetContainer)")
      let redrawIndex =
        indexOfRequired(body, "data.activeSession.startOptions.welcomeScreen")

      check branchIndex < initIndex
      check initIndex < redrawIndex

    test "switchSession refreshes the global welcome host for welcome tabs":
      let source = readFile(SessionSwitchPath)
      let body = sectionBetween(source,
        "proc switchSession*(data: Data, targetIndex: int) =",
        "")

      let welcomeBranchIndex =
        indexOfRequired(body, "if data.activeSession.startOptions.welcomeScreen:")
      let showWelcomeIndex =
        indexOfRequired(body, "data.ui.welcomeScreen.showWelcomeView()")
      let renderWelcomeIndex =
        indexOfRequired(body, "data.ui.welcomeScreen.requestWelcomeScreenRender()")
      let clearIndex =
        indexOfRequired(body, "welcome_screen.clearIsoNimWelcomeScreen()")

      check welcomeBranchIndex < showWelcomeIndex
      check showWelcomeIndex < renderWelcomeIndex
      check welcomeBranchIndex < clearIndex

    test "trace and edit session entry clear the global welcome host":
      let source = readFile(UiJsPath)
      let helperBody = sectionBetween(source,
        "proc hideWelcomeScreenSurface() =",
        "# ---------------------------------------------------------------------------")
      check helperBody.contains("data.ui.welcomeScreen.resetView()")
      check helperBody.contains("welcome_screen.clearIsoNimWelcomeScreen()")

      let traceLoadedBody = sectionBetween(source,
        "proc onTraceLoaded(",
        "proc onStartShellUi*")
      let traceLoadedClearIndex =
        indexOfRequired(traceLoadedBody, "hideWelcomeScreenSurface()")
      let traceAssignmentIndex =
        indexOfRequired(traceLoadedBody, "data.trace = response.trace")
      check traceLoadedClearIndex < traceAssignmentIndex

      let noTraceBody = sectionBetween(source,
        "proc onNoTrace(",
        "proc invalidPath(")
      check noTraceBody.contains("hideWelcomeScreenSurface()")

    test "switchSession rebinds debug toolbar bridge for active session":
      let source = readFile(SessionSwitchPath)
      let body = sectionBetween(source,
        "proc switchSession*(data: Data, targetIndex: int) =",
        "")

      let tabBarIndex = indexOfRequired(body, "refreshSessionTabBar()")
      let rewireIndex =
        indexOfRequired(body, "debug.rewireDebugControlsBridgeForActiveSession(data)")
      let redrawIndex =
        indexOfRequired(body, "if not data.activeSession.ui.layout.isNil")

      check tabBarIndex < rewireIndex
      check rewireIndex < redrawIndex

    test "debug bridge rewire uses active session component mediator":
      let source = readFile(DebugPath)
      let body = sectionBetween(source,
        "proc rewireDebugControlsBridgeForActiveSession*(data: Data) =",
        "proc jumpBeforeList*(self: DebugComponent) =")

      check body.contains("data.ui.componentMapping[Content.Debug][0]")
      check body.contains("component.api")
      check body.contains("debugControlsVMInstance.onDapStep")

    test "folder edit mode opens an indexed project file":
      let source = readFile(UiJsPath)
      let body = sectionBetween(source,
        "proc onNoTrace(",
        "configureShortcuts()")

      let filenameFallbackIndex = indexOfRequired(body, "chooseInitialEditPath(")
      let openIndex = indexOfRequired(body, "data.openTab(initialEditPath, ViewSource)")

      check filenameFallbackIndex < openIndex
      check body.contains("let requestedEditPath =")
      check body.contains("$data.startOptions.name")

    test "folder edit mode publishes the selected folder to renderer state":
      let indexTracesSource = readFile(IndexTracesPath)
      let initEditBody = sectionBetween(indexTracesSource,
        "proc initEditModeForFolder(sender: js; folder: cstring) {.async.} =",
        "proc onInitEditMode*")

      check initEditBody.contains("data.startOptions.folder = folder")
      check initEditBody.contains("path: folder")

      let uiSource = readFile(UiJsPath)
      let noTraceBody = sectionBetween(uiSource,
        "proc onNoTrace(",
        "proc invalidPath(")
      let startOptionsIndex =
        indexOfRequired(noTraceBody, "data.startOptions = response.startOptions")
      let tabRenderIndex =
        indexOfRequired(noTraceBody, "requestSessionTabsRender(data)")
      check startOptionsIndex < tabRenderIndex

    test "edit mode declares every debugger-only panel hidden":
      ## The *names* half of the edit-mode sanitiser contract.  Which panels
      ## count as "debugger-only" is a product decision that can only be read
      ## off `editModeHiddenContentIds()`; the matching *behavioural* half —
      ## that the sanitiser really drops them, and keeps them in replay mode —
      ## runs on the JavaScript backend at the top of this file against the
      ## real `index/layout_config_repair` module.  The two halves are paired
      ## by these `Content` members and their ordinals.
      let source = readFile(IndexConfigPath)
      let hiddenBody = sectionBetween(source,
        "proc editModeHiddenContentIds(): seq[int] =",
        "proc stringifyJson")

      for contentName in [
        "Content.Trace",
        "Content.State",
        "Content.Calltrace",
        "Content.CalltraceEditor",
        "Content.TraceLog",
        "Content.AgentActivity",
        "Content.TerminalOutput"
      ]:
        check hiddenBody.contains(contentName)

    test "edit layout save and load route through the repair module":
      ## What replaced two greps for the sanitiser's *implementation text*
      ## (`Number(state.content) === editorContent`, `hidden.has(...)`).  That
      ## text moved out of `index/config.nim` when issue #608 extracted the
      ## logic into `index/layout_config_repair.nim`, and the test failed even
      ## though the behaviour it named was intact — a test keyed to how a
      ## thing is written cannot survive it being rewritten.
      ##
      ## The behaviour is now asserted by executing it (JS suite above).  What
      ## is left here is the one thing a native run can still establish: the
      ## production call sites are wired to the module that owns that
      ## behaviour, and every edit-mode entry point passes the hidden set —
      ## an edit session that forgets it restores the debugger panels it must
      ## not have.
      let source = readFile(IndexConfigPath)
      check source.contains("./layout_config_repair,")

      let sanitizeBody = sectionBetween(source,
        "proc sanitizeEditLayoutConfig*(config: js; editorContent: int;",
        "proc editModeHiddenContentIds(): seq[int] =")
      check sanitizeBody.contains("sanitizeLayoutConfig(config, editorContent, hiddenContents)")

      # Every edit-mode call site — the save path, both load paths and (since
      # RV-2) the reset path — hands the sanitiser the editor content id AND a
      # hidden set.
      #
      # RV-2 turned the hidden set into a *parameter* of
      # `loadEditLayoutConfig`, defaulting to `editModeHiddenContentIds()`, so
      # a review can share the loader with its own set (edit mode's, minus
      # DeepReview's Agent Activity pillar).  The three edit-mode paths inside
      # the loader therefore spell it `hiddenContents` and the save path still
      # names the set directly.  The count is asserted per spelling rather
      # than in total so neither can quietly become zero.
      check source.count(
        "ord(Content.EditorView), editModeHiddenContentIds())") == 1
      check source.count("ord(Content.EditorView), hiddenContents)") == 3

      # The parameter defaults to the edit-mode set, so every edit-mode caller
      # keeps the set it always had without naming it.
      check source.contains(
        "hiddenContents: seq[int] = editModeHiddenContentIds()")

    test "delegated ct edit opens a populated edit session":
      let indexSource = readFile(IndexPath)
      let secondInstanceBody = sectionBetween(indexSource,
        "electron_vars.app.on(\"second-instance\")",
        "electron_vars.app.on(\"window-all-closed\")")

      let editBranchIndex =
        indexOfRequired(secondInstanceBody, "argText == \"edit\"")
      let argvScanIndex =
        indexOfRequired(secondInstanceBody, "for i in 2 ..< argvLen:")
      let editEventIndex =
        indexOfRequired(secondInstanceBody,
          "\"CODETRACER::open-edit-folder-in-tab-ready\"")
      let traceEventIndex =
        indexOfRequired(secondInstanceBody,
          "\"CODETRACER::open-trace-in-tab-ready\"")

      check argvScanIndex < editBranchIndex
      check editBranchIndex < editEventIndex
      check editEventIndex < traceEventIndex

      let uiSource = readFile(UiJsPath)
      let handlerBody = sectionBetween(uiSource,
        "proc onOpenEditFolderInTabReady*(",
        "proc onTraceLoadError*")
      check handlerBody.contains("createNewSession(data)")
      check handlerBody.contains("CODETRACER::init-edit-mode")
      check handlerBody.contains("response.folderPath")

      let noTraceBody = sectionBetween(uiSource,
        "proc onNoTrace(",
        "proc invalidPath(")
      check noTraceBody.contains("hideWelcomeScreenSurface()")
      check noTraceBody.contains("filesystem.refreshIsoNimFilesystemPanel()")
      check noTraceBody.contains("vcs.resetAndRefreshVCS(")
      check noTraceBody.contains("vcs.tryMountIsoNimVCSPanel(")

      let ipcBody = sectionBetween(uiSource,
        "proc configureIPC(data: Data) =",
        "duration(\"configureIPCRun\")")
      check ipcBody.contains("\"open-edit-folder-in-tab-ready\"")

    test "window close snapshots current splitter and panel sizes":
      let source = readFile(RendererPath)
      let body = sectionBetween(source,
        "proc saveCurrentLayoutConfig*(data: Data) =",
        "proc redrawAll*")

      let guardIndex = indexOfRequired(body, "data.ui.layout.isNil")
      let saveLayoutIndex =
        indexOfRequired(body, "data.ui.resolvedConfig = data.ui.layout.saveLayout()")
      let saveConfigIndex =
        indexOfRequired(body, "data.saveConfig(data.ui.layoutConfig.fromResolved")
      let beforeUnloadIndex =
        indexOfRequired(body, "window.addEventListener(cstring\"beforeunload\"")

      check guardIndex < saveLayoutIndex
      check saveLayoutIndex < saveConfigIndex
      check saveConfigIndex < beforeUnloadIndex

    test "initLayout installs shared chrome before welcome early return":
      let source = readFile(LayoutPath)
      let body = sectionBetween(source,
        "proc initLayout*(initialLayout: GoldenLayoutResolvedConfig,",
        "let root = if not containerElement.isNil:")

      let sharedIndex = indexOfRequired(body, "ensureSharedRenderers()")
      let welcomeIndex =
        indexOfRequired(body, "if data.startOptions.welcomeScreen and data.trace.isNil:")
      let mountIndex =
        indexOfRequired(body, "welcome_screen.tryMountIsoNimWelcomeScreen()")

      check sharedIndex < welcomeIndex
      check welcomeIndex < mountIndex
