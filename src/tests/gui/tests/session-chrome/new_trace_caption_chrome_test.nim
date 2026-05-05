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

import std/[strutils, unittest]

const
  SessionSwitchPath = "src/frontend/ui/session_switch.nim"
  LayoutPath = "src/frontend/ui/layout.nim"

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
  suite "New Trace session chrome contract":
    test "source contract checks run in native headless mode":
      ## Nim's JavaScript backend does not provide filesystem reads in Node for
      ## this test binary.  The structural caption DOM checks still run on the
      ## JS backend through ``views/isonim_views_test.nim``.
      check true
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
