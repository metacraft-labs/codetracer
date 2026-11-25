## test_recording_file_tree.nim — the replay FILES pane of the terminal and
## GPUI front-ends on a recording whose sources live in SEVERAL folders.
##
## `native_host.recordingFileTree` is the one producer both native front-ends
## hand their file tree (`loadRecordingPanes`). It derived the source folders
## from the trace folder's `paths.json` only — a sidecar written when a
## container is materialised or imported, and absent from a folder straight
## out of `ct record` — so a fresh recording opened with an EMPTY FILES pane
## ("▼ source folders" and nothing under it), while the desktop listed its
## sources. A recording whose runner and imported modules sit in different
## folders made it plain.
##
## The subject here is a REAL recording: `test-programs/multi_root`, whose
## runner is in `app/` and whose modules are in the sibling `shared/` (one of
## them a package in `shared/pkg/`), recorded by the terminal lanes' own
## fixture provider through a real `ct record`. It is read three ways: as
## `ct record` left it, with a `paths.json` sidecar beside it (the imported
## shape), and through a real session (a real `replay-server`): the frame the
## terminal paints and the view GPUI's FILES leaf draws. No mocks.
##
## M102 (codetracer#877), the replay arm: with the editor's tab Closed from
## its tab menu, a press on a FILES row of the same real session puts the
## editor back in the arrangement, focused, painting the clicked file
## (Filesystem-Pane.md § "Opening a file": *"its tab is the one on screen"*).
## The press goes through the product's runtime and the outcome through the
## host's own `applyOutcome`, the path `main.nim` drives.

import std/[algorithm, json, os, strutils, unicode, unittest]

import store/types as store_types
import ../../view_vocabulary/pane_views
import ../../headless_app/layout_model
import ../../../common/view_vocabulary
import ../../../common/value_presentation
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/shell
import ../app/layout/binding
import ../app/layout/cells
import ../../host/native_host
import ../host/tui_session
import ./fixtures/fixture_provider
import isonim/viewmodel as isonim_viewmodel   # `ViewModel`, the view's input

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 34

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

let resolved = resolveFixture(FixtureSpec(
  name: "multi_root",
  program: "test-programs/multi_root/app/main.py",
  recorder: "codetracer-python-recorder",
  probe: FixtureProbe(kind: pkPythonRecorder),
  buildHint: "Install codetracer_python_recorder into the interpreter `ct` " &
             "will use (the repo's .python-recorder-venv, or " &
             "$CODETRACER_PYTHON_INTERPRETER).",
  blockedOn: ""))

proc labelsOf(n: FilesystemEntryNode; acc: var seq[string]; depth = 0) =
  acc.add repeat("  ", depth) & n.text
  for c in n.children:
    labelsOf(c, acc, depth + 1)

proc filesUnder(n: FilesystemEntryNode; acc: var seq[string]) =
  if not n.isFolder:
    acc.add n.path
  for c in n.children:
    filesUnder(c, acc)

proc copyTrace(src, name: string): string =
  ## A private copy of the recorded trace folder, so a case can add or remove
  ## a sidecar without touching the fixture cache other suites read.
  result = getTempDir() / ("recording-file-tree-" & $getCurrentProcessId() &
                           "-" & name)
  removeDir(result)
  copyDir(src, result)

suite "the replay FILES pane lists every source folder of a recording":

  test "a fresh recording (no paths.json): both roots, every file, nested once":
    require resolved.outcome == foRecorded
    let trace = copyTrace(resolved.tracePath, "fresh")
    defer: removeDir(trace)
    # As `ct record` leaves it: the container and its `files/` store.
    removeFile(trace / "paths.json")
    ck not fileExists(trace / "paths.json")
    ck dirExists(trace / "files")
    let tree = recordingFileTree(trace)
    var labels: seq[string] = @[]
    labelsOf(tree, labels)
    checkpoint(labels.join("\n"))
    # Two roots — the runner's folder and the sibling it imports from — and
    # NOT a third for `shared/pkg`, which is listed inside `shared`.
    ck tree.children.len == 2
    var roots: seq[string] = @[]
    for c in tree.children: roots.add c.text
    ck roots == @["app", "shared"]
    var files: seq[string] = @[]
    filesUnder(tree, files)
    checkpoint(files.join("\n"))
    for tail in ["/app/main.py", "/shared/helpers.py",
                 "/shared/pkg/__init__.py", "/shared/pkg/extra.py"]:
      var hits = 0
      for f in files:
        if f.endsWith(tail): inc hits
      checkpoint(tail & ": " & $hits)
      ck hits == 1
    # Every listed path names a file the store holds.
    var stored = 0
    for f in files:
      if fileExists(trace / "files" / f[1 .. ^1]): inc stored
    ck stored == files.len

  test "with a paths.json sidecar (an imported recording): the same tree":
    require resolved.outcome == foRecorded
    let trace = copyTrace(resolved.tracePath, "sidecar")
    defer: removeDir(trace)
    # The sidecar as materialisation writes it: every recorded source,
    # relative to the store.
    # (In a stable order: the sidecar's order is the recording's, and the
    # tree keeps it, so an unordered listing would compare an order.)
    var paths: seq[string] = @[]
    for path in walkDirRec(trace / "files", relative = true):
      paths.add path
    paths.sort()
    var recorded = newJArray()
    for path in paths: recorded.add %path
    writeFile(trace / "paths.json", $recorded)
    let fresh = copyTrace(resolved.tracePath, "fresh2")
    defer: removeDir(fresh)
    removeFile(fresh / "paths.json")
    var a, b: seq[string] = @[]
    labelsOf(recordingFileTree(trace), a)
    labelsOf(recordingFileTree(fresh), b)
    checkpoint(a.join("\n"))
    ck a == b
    ck a.len >= 7

  test "a real session on it: the terminal's FILES pane and GPUI's view list both roots":
    require resolved.outcome == foRecorded
    let trace = copyTrace(resolved.tracePath, "session")
    defer: removeDir(trace)
    removeFile(trace / "paths.json")
    let rt = newTuiRuntime(newTuiApp(), resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"), initCapabilityFlags()), 200, 60)
    let session = openTuiSession(trace, viewportHeight = 54)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    # The terminal: what the frame draws.
    let screen = rt.shellScreenOf().rows.join("\n")
    for name in ["source folders", "app", "shared", "main.py", "helpers.py",
                 "extra.py"]:
      checkpoint("terminal FILES shows " & name)
      ck screen.contains(name)
    # GPUI: the view its FILES leaf draws, over the SAME session's tree.
    let vm = session.session.session.fileTreeVM
    let pv = paneView(paneFileTree, ViewModel(vm), GpuiPanelBudget, "gpui")
    ck pv.report.len == 0
    var labels: seq[string] = @[]
    proc walk(n: ViewNode) =
      labels.add n.label
      if n.expanded:
        for c in n.children: walk(c)
    walk(pv.root)
    checkpoint($labels)
    for name in ["app", "main.py", "shared", "helpers.py", "pkg",
                 "__init__.py", "extra.py"]:
      ck name in labels

proc sgr(button, row, col: int; pressed: bool): string =
  ## SGR 1006, one-based, as a terminal writes it.
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc regionOf(rt: TuiRuntime; pane: PaneKind): (bool, PaneRegion) =
  ## The projected region `pane` is drawn in: the arrangement places it and
  ## its tab is the active one of its stack.
  for r in rt.layoutGeometry().projection.regions:
    if r.pane == pane and not r.area.isEmptyArea:
      return (true, r)
  (false, PaneRegion())

proc labelCol(rt: TuiRuntime; row, fromCol: int; label: string;
              toCol = high(int)): int =
  ## The cell `label` starts at on `row`, at or right of `fromCol` and
  ## starting left of `toCol`; -1 when it is not drawn there.
  let line = rt.shellScreenOf().rows[row].toRunes
  let want = label.toRunes
  for c in fromCol .. line.len - want.len:
    if c >= toCol:
      break
    if line[c ..< c + want.len] == want:
      return c
  -1

proc pressAndApply(rt: TuiRuntime; session: TuiSession;
                   button, row, col: int) =
  ## A press and its release through the runtime, each outcome applied by
  ## the host, as the event loop does.
  for pressed in [true, false]:
    let outcome = rt.handleToken(sgr(button, row, col, pressed), 0)
    session.applyOutcome(rt, outcome)

suite "M102 (#877): a FILES press on a recording shows the file":

  test "the editor's tab Closed: a press on a row brings it back, painting the file":
    require resolved.outcome == foRecorded
    let trace = copyTrace(resolved.tracePath, "reveal")
    defer: removeDir(trace)
    let rt = newTuiRuntime(newTuiApp(), resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"), initCapabilityFlags()), 200, 60)
    discard rt.enableLayoutBinding()
    let session = openTuiSession(trace, viewportHeight = 54)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    # The tab menu's Close on the editor's tab.
    let (shown, editor) = rt.regionOf(paneEditor)
    require shown
    let label = if editor.tabs.len > 0 and editor.activeTab >= 0:
                  editor.tabs[editor.activeTab]
                else: terminalPaneName(paneEditor)
    var tabCol = rt.labelCol(editor.area.row, editor.area.col, label)
    if tabCol < 0:
      # A bare pane's strip names what it shows, not the pane: the strip is
      # its one-tab header (`tabStripOf`), and a right-click anywhere on it
      # is a right-click on the pane's tab.
      tabCol = editor.area.col
    rt.pressAndApply(session, 2, editor.area.row, tabCol + 1)
    require rt.app.contextMenu.open
    let close = rt.app.contextMenu.menu.labels.find("Close")
    require close >= 0
    while rt.app.contextMenu.selected < close:
      session.applyOutcome(rt, rt.handleToken("\x1b[B", 0))
    session.applyOutcome(rt, rt.handleToken("\r", 0))
    ck not rt.app.layoutBinding.layout.tree.contains(paneEditor)
    ck not rt.regionOf(paneEditor)[0]
    # A press on `helpers.py`'s row in FILES.
    let (hasFiles, files) = rt.regionOf(paneFileTree)
    require hasFiles
    var row = -1
    var col = -1
    for r in files.area.row + 1 ..< files.area.row + files.area.height:
      let c = rt.labelCol(r, files.area.col, "helpers.py",
                          files.area.col + files.area.width)
      if c >= 0:
        row = r
        col = c
        break
    ck row > 0
    rt.pressAndApply(session, 0, row, col + 1)
    ck rt.app.viewedFile.endsWith("helpers.py")
    ck rt.app.layoutBinding.layout.tree.contains(paneEditor)
    let (back, region) = rt.regionOf(paneEditor)
    ck back
    var painted = false
    let rows = rt.shellScreenOf().rows
    for r in region.area.row ..< region.area.row + region.area.height:
      let line = rows[r].toRunes
      let last = min(line.len, region.area.col + region.area.width)
      if region.area.col < last and
         ($line[region.area.col ..< last]).contains("def add(left, right):"):
        painted = true
    checkpoint(rows.join("\n"))
    ck painted
    let (had, focused) = rt.focus.focusedPane()
    ck had and focused == paneEditor
    ck rt.app.notification.contains("opened ")

suite "the replay FILES pane: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
