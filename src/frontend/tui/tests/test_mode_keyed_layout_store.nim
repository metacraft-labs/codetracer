## test_mode_keyed_layout_store.nim — Mode-Transitions.md §4b, Tier 1. **The
## terminal remembers each product mode's arrangement in a document of its
## own, so an Edit arrangement survives a restart and never replaces the Debug
## one.**
##
## §4b's three tiers are the register (this session), the store (a previous
## session, on this device) and the mode's default. The register was keyed by
## the mode from the start (`views/shell.ModeRegister`); the store was one
## document holding the Debug arrangement, so an Edit arrangement was a default
## again in the next session and `ct edit` neither read nor wrote it. The cases
## below assert the store tier at the FILES, through the shipped
## `host/layout_store` procedures, in a scratch state root:
##
##   1. a replay session's Edit arrangement — made after `Ctrl+F5` — is written
##      to `tui-layout-edit.json`, the Debug document keeps the Debug
##      arrangement, and the next replay session's first switch into Edit mode
##      enters the remembered Edit arrangement, not the default;
##   2. `ct edit` restores that same Edit document, writes its changes through
##      to it and nowhere else, and a reset removes only it;
##   3. `ct edit` with only a Debug document on disk opens Edit mode's default
##      and leaves the Debug document byte for byte;
##   4. an unreadable Edit document is announced on the switch, Edit mode's
##      default is entered, and no gesture or exit writes over the file.
##
## ## No mocks
##
## The runtime, binding, register, layout model and layout store are the
## product's own, the files are real files under a private
## `CODETRACER_TUI_LAYOUT_DIR`, clicks are SGR-1006 reports through
## `handleToken`, and `Ctrl+F5` is `CSI 15 ; 5 ~`. `wireAsShipped` sets the
## runtime's two persistence hooks to exactly what `main.interactive` and
## `main.editInteractive` set them to (the store's own procedures); it is the
## one stand-in, and it is not a mock: it calls the shipped functions, and only
## the terminal loop around them is absent.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc`
## cannot see `testStatusIMPL`. Helpers here return values.

import std/[json, os, strutils, tempfiles, unittest]

import codetracer_embed
import headless_app/layout_model

import ../app/runtime
import ../app/theme/capabilities
import ../host/layout_store

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 56

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  CtrlF5 = "\x1b[15;5~"
    ## `CSI <code> ; <modifier> ~`, F5 is 15 and Ctrl is modifier 5.

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc wireAsShipped(rt: TuiRuntime) =
  ## The two hooks `main.nim`'s loops install, calling the store's own
  ## procedures.
  rt.layoutCommitted = proc(rt: TuiRuntime) =
    discard persistLayoutForSession(rt)
  rt.modeDocumentWanted = proc(rt: TuiRuntime; mode: ProductMode): string =
    let staged = stageLayoutForMode(rt, mode)
    if staged.status == lrsUnreadable: staged.message else: ""

proc replayRuntime(): TuiRuntime =
  ## `main.interactive`'s shape: Debug mode, a binding, the hooks.
  result = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
  discard result.enableLayoutBinding()
  result.wireAsShipped()

proc editRuntime(): TuiRuntime =
  ## `main.editInteractive`'s shape: Edit mode set before the runtime, a
  ## binding, no session, the hooks.
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  result = newTuiRuntime(app, caps(), Cols, Rows)
  discard result.enableLayoutBinding()
  result.wireAsShipped()

proc sgr(row, col: int; pressed: bool): string =
  "\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & (if pressed: "M" else: "m")

proc drawn(rt: TuiRuntime): seq[PaneKind] =
  let m = rt.app.shellModel(rt.width, rt.height)
  for r in projectLayout(m.layout, bodyArea(rt.width, rt.height)).regions:
    result.add r.pane

proc clickTab(rt: TuiRuntime; tab: string): bool =
  ## Click the tab titled `tab` where the frame draws it.
  let m = rt.app.shellModel(rt.width, rt.height)
  for r in projectLayout(m.layout, bodyArea(rt.width, rt.height)).regions:
    let at = r.tabs.find(tab)
    if r.tabs.len >= 2 and at >= 0:
      let col = r.area.col + tabSpans(r.tabs, r.activeTab)[at].startCol + 1
      discard rt.handleToken(sgr(r.area.row, col, true), 0'i64)
      discard rt.handleToken(sgr(r.area.row, col, false), 0'i64)
      return true
  false

proc toggle(rt: TuiRuntime) =
  discard rt.handleToken(CtrlF5, 0'i64)

proc arrangement(rt: TuiRuntime): JsonNode =
  saveLayout(rt.app.layoutBinding.layout)

proc editDefault(): JsonNode =
  ## Edit mode's default as a bound replay enters it with nothing remembered.
  let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
  discard rt.enableLayoutBinding()
  rt.toggle()
  rt.arrangement()

suite "Mode-Transitions §4b: the terminal's store is keyed by the mode":

  let root = createTempDir("mode-keyed-layout-", "")
  putEnv(LayoutDirEnvVar, root)
  let debugPath = root / "tui-layout.json"
  let editPath = root / "tui-layout-edit.json"
  var editArrangement: JsonNode = nil
  var debugText = ""

  test "a replay's Edit arrangement goes to the Edit document and comes back next session":
    ck layoutDocumentPath(pmDebug) == debugPath
    ck layoutDocumentPath(pmEdit) == editPath
    let rt = replayRuntime()
    ck restoreLayoutForSession(rt).status == lrsNoDocument
    ck rt.layoutDocument == debugPath
    # A Debug gesture: written through to the Debug document only.
    ck rt.clickTab("Terminal Output")
    ck fileExists(debugPath)
    ck not fileExists(editPath)
    debugText = readFile(debugPath)
    let debugArrangement = rt.arrangement()
    # Into Edit mode: the Edit document is bound on the way in, nothing is
    # written by the switch itself.
    rt.toggle()
    ck rt.app.modes.product == pmEdit
    ck rt.layoutDocuments[pmEdit] == editPath
    ck not fileExists(editPath)
    # An Edit gesture: written through to the Edit document, Debug's untouched.
    ck rt.clickTab("VCS")
    ck paneVcs in rt.drawn()
    ck fileExists(editPath)
    ck readFile(debugPath) == debugText
    editArrangement = rt.arrangement()
    ck parseJson(readFile(editPath)) == editArrangement
    # The exit save, from Edit mode, writes each document from its own mode.
    ck persistLayoutForSession(rt).outcome == lpoWritten
    ck parseJson(readFile(debugPath)) == debugArrangement
    ck parseJson(readFile(editPath)) == editArrangement

    # THE NEXT SESSION: Debug restored, and the first switch into Edit mode
    # enters the remembered Edit arrangement rather than the default.
    let next = replayRuntime()
    ck restoreLayoutForSession(next).status == lrsRestored
    ck next.arrangement() == debugArrangement
    ck editArrangement != editDefault()
    next.toggle()
    ck next.app.modes.product == pmEdit
    ck next.arrangement() == editArrangement
    ck paneVcs in next.drawn()
    # …and back: the Debug arrangement the session started with.
    next.toggle()
    ck next.arrangement() == debugArrangement

  test "ct edit restores the Edit document, writes only it, and a reset removes only it":
    let rt = editRuntime()
    let restored = restoreLayoutForSession(rt)
    ck restored.status == lrsRestored
    ck rt.layoutDocument == editPath
    ck rt.layoutHome == pmEdit
    ck rt.arrangement() == editArrangement
    ck paneVcs in rt.drawn()
    # A gesture: the Edit document follows it, the Debug document does not.
    ck rt.clickTab("Files")
    ck paneFileTree in rt.drawn()
    ck parseJson(readFile(editPath)) == rt.arrangement()
    ck readFile(debugPath) == debugText
    ck persistLayoutForSession(rt).outcome == lpoWritten
    ck readFile(debugPath) == debugText
    # Back to Edit mode's default: the exit removes the stale Edit document
    # and leaves Debug's.
    discard rt.app.layoutBinding.resetToProfile()
    ck persistLayoutForSession(rt).outcome == lpoRemoved
    ck not fileExists(editPath)
    ck readFile(debugPath) == debugText

  test "ct edit with only a Debug document opens Edit's default and never touches it":
    ck not fileExists(editPath)
    ck fileExists(debugPath)
    let rt = editRuntime()
    ck restoreLayoutForSession(rt).status == lrsNoDocument
    ck rt.arrangement() == editDefault()
    ck rt.layoutPersistPlanOf(pmDebug).intent == lpiQuarantine
    ck persistLayoutForSession(rt).outcome == lpoRemoved
    ck readFile(debugPath) == debugText
    ck not fileExists(editPath)

  test "an unreadable Edit document is announced, Edit's default entered, the file left alone":
    let garbage = "{ not json"
    writeFile(editPath, garbage)
    let rt = replayRuntime()
    discard restoreLayoutForSession(rt)
    rt.toggle()
    ck rt.app.modes.product == pmEdit
    checkpoint(rt.app.notification)
    ck rt.app.notification.startsWith("saved layout ignored (NotJson)")
    ck rt.arrangement() == editDefault()
    ck rt.layoutQuarantined[pmEdit]
    # A gesture and an exit: the file is still what it was.
    ck rt.clickTab("VCS")
    ck readFile(editPath) == garbage
    ck rt.layoutPersistPlanOf(pmEdit).intent == lpiQuarantine
    discard persistLayoutForSession(rt)
    ck readFile(editPath) == garbage
    ck readFile(debugPath) == debugText

  delEnv(LayoutDirEnvVar)
  removeDir(root)

  test "assertion count":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
