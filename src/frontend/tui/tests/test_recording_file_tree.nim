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

import std/[algorithm, json, os, strutils, unittest]

import store/types as store_types
import ../../view_vocabulary/pane_views
import ../../headless_app/layout_model
import ../../../common/view_vocabulary
import ../../../common/value_presentation
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/shell
import ../host/native_host
import ../host/tui_session
import ./fixtures/fixture_provider
import isonim/viewmodel as isonim_viewmodel   # `ViewModel`, the view's input

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 25

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

suite "the replay FILES pane: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
