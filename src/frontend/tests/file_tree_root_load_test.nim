## file_tree_root_load_test.nim
##
## The index process's loads of the Files pane (GitHub #785, and codetracer-pm
## issue `2026-10-21-filesystem-pane-renders-the-whole-enclosing-checkout-
## expanded-and-freezes-the-window.md`), run against a real temporary
## directory.
##
## #785: a Noir program inside a git checkout left the Files pane on
## "Loading...". The recording's source folder was the checkout's root, and
## the trace's payload did not mirror it, so `index/files.loadFile` fell back
## to the live disk — and kept the self-contained rules there: no depth
## limit, no skipped directories, and the payload's top level overlaid into
## every live folder. On the codetracer checkout that was 35 764 rows,
## `.git/modules`, `node_modules` and a Python venv included. And the load
## had no failure path: a rejection left the pane waiting for good.
##
## The 2026-10-21 issue: the tree still arrived EXPANDED, and a payload root
## was still walked whole, so the size of a folder decided whether the window
## froze (40 664 nodes rendered at once). `Viewport-Driven-Loading.md` § V5
## settles it: one level per load, for payload and live trees alike. A root
## load lists each root's own entries, and every folder below a root arrives
## collapsed with one "Loading..." child, read only when it is expanded
## (`load-path-content`). That REVERSES what case 2 used to assert ("a payload
## root is loaded whole, with no depth limit"): walking a payload whole is
## exactly the cost the spec removes, because a payload can be as large as
## any live folder. A lazily loaded payload folder is read from where the
## root load read it (its `payloadPath`), including the folders a portable
## payload overlays at a root, and the payload's top level is overlaid only
## at a root load.
##
## The cases:
##
## 1. A live fallback onto a repository gets the live-filesystem rules:
##    `.git` and `node_modules` are skipped, a folder one level down is a
##    collapsed "Loading..." stub, and no payload entry is overlaid into it.
##    Every node's `index` is its position among its siblings, which is what
##    `ui_js.onUpdatePathContent` walks to place a lazy load's answer.
## 2. A payload root lists its own entries; its subfolders are collapsed
##    "Loading..." stubs that remember where in the payload they were read.
## 3. A lazy load of a payload stub (`loadPathContentPartially`, called as
##    `onLoadPathContent` calls it) returns that folder's entries, and its own
##    subfolders are stubs again.
## 4. A folder a portable payload overlays at an absolute root (`files/src`
##    shown under the recorded folder, whose mirror holds `Nargo.toml`)
##    lazily expands to the payload's `src`, not to the live disk's.
## 5. A lazy load never overlays the payload's top level, and a payload
##    location that leaves `files/` is not followed.
## 6. A root over a large live folder (50 folders of 50 files) costs one
##    listing: the tree holds the root, its 50 entries and one stub each.
## 7. A root load that rejects still answers `filesystem-loaded`, with an
##    `error` and no `folders` (`index/traces.sendFilesystem`).
##
## No fakes but one: the Electron window `sendFilesystem` sends to is an
## object that records what it was sent. The loader, `fs` and the directory
## tree are real.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node. Writes only under one `mkdtemp` directory, which it removes.

import std/[asyncjs, jsffi, strutils]

import lib/src_relative_require
import ../types
import ../index/files
import ../index/traces
import ../../common/trace_source_paths

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}

proc makeTempDir(): cstring {.importjs: """(function () {
  var os = require('os'), path = require('path'), fs = require('fs');
  return fs.mkdtempSync(path.join(os.tmpdir(), 'ct-file-tree-785-'));
})()""".}

proc removeDir(dir: cstring) {.importjs:
  "require('fs').rmSync(#, {recursive: true, force: true})".}

proc writeTree(root: cstring; relPath: cstring) {.importjs: """(function (root, rel) {
  var path = require('path'), fs = require('fs');
  var full = path.join(root, rel);
  fs.mkdirSync(path.dirname(full), {recursive: true});
  fs.writeFileSync(full, 'x');
})(#, #)""".}

proc makeDir(root: cstring; relPath: cstring) {.importjs:
  "require('fs').mkdirSync(require('path').join(#, #), {recursive: true})".}

proc joinPath(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}

proc recordingWindow(): JsObject {.importjs: """(function () {
  var sent = [];
  return { sent: sent,
           webContents: { send: function (channel, payload) {
             sent.push({ channel: channel, payload: payload }); } } };
})()""".}

proc childNamed(node: CodetracerFile; name: string): CodetracerFile =
  if node.isNil:
    return nil
  for child in node.children:
    if $child.text == name:
      return child
  nil

proc childNames(node: CodetracerFile): seq[string] =
  if node.isNil:
    return @[]
  for child in node.children:
    result.add $child.text

proc isOpened(node: CodetracerFile): bool =
  ## `state.opened`, the flag the renderer mirrors into its expanded set.
  not node.isNil and not node.state.isNil and
    node.state[cstring"opened"].to(bool)

proc isCollapsedStub(node: CodetracerFile): bool =
  ## A folder whose entries have not been read: collapsed, with the single
  ## "Loading..." child `ui/filesystem.loadFolderContentIfNeeded` keys on.
  not node.isNil and not node.isOpened() and
    node.childNames() == @["Loading..."]

proc describe(node: CodetracerFile): string =
  if node.isNil: "nothing"
  else: $node.childNames() & (if node.isOpened(): " opened" else: " collapsed")

proc payloadLocation(node: CodetracerFile): string =
  ## The node's `original.payloadPath`, read as a plain JS property so that
  ## a loader which never sets it reads as "" rather than failing to compile.
  if node.isNil:
    return ""
  let value = node.original.toJs[cstring"payloadPath"]
  if value.isNull or value.isUndefined: "" else: $value.to(cstring)

proc indicesArePositions(node: CodetracerFile): bool =
  ## Every child's `index` is its position in `children`, and its
  ## `parentIndices` lead to `node` — the walk `ui_js.onUpdatePathContent`
  ## makes to find the node a lazy load answers.
  if node.isNil:
    return false
  var expectedParents = node.parentIndices
  expectedParents.add node.index
  for position, child in node.children:
    if child.index != position or child.parentIndices != expectedParents:
      return false
  true

proc lazyLoad(node: CodetracerFile; filesRoot: cstring): Future[CodetracerFile] =
  ## Expand a stub the way `index/files.onLoadPathContent` does for a
  ## self-contained trace: the node's own path, index and parent indices,
  ## and the payload location the renderer sends back with them
  ## (`ui/filesystem.loadFolderContentIfNeeded`).
  loadPathContentPartially(node.original.path, node.index, node.parentIndices,
                           filesRoot, selfContained = true,
                           payloadPath = cstring(payloadLocation(node)))

proc countNodes(node: CodetracerFile; stubs: var int): int =
  ## Real nodes in `node`'s subtree; "Loading..." placeholders are counted
  ## into `stubs` instead.
  if node.isNil:
    return 0
  if $node.text == "Loading...":
    inc stubs
    return 0
  result = 1
  for child in node.children:
    result += countNodes(child, stubs)

const ExpectedChecks = 31

proc runCases(dir: cstring) {.async.} =
  # The recording host's repository, which the payload does not mirror.
  let repo = joinPath(dir, cstring"repo")
  writeTree(repo, cstring".git/HEAD")
  writeTree(repo, cstring"node_modules/pkg/index.js")
  writeTree(repo, cstring"top.nr")
  writeTree(repo, cstring"a/b/c/deep.nr")
  # The trace's payload: Noir's relative layout, `files/src/main.nr`.
  let filesRoot = joinPath(dir, cstring"trace/files")
  writeTree(filesRoot, cstring"src/main.nr")
  writeTree(filesRoot, cstring"src/lib/x/y/z/deep.nr")
  writeTree(filesRoot, cstring"src/lib/util.nr")
  makeDir(filesRoot, cstring"std")
  # The recorded Nargo package, an absolute folder. The payload mirrors only
  # its `Nargo.toml`, under the root-stripped path; its sources are the
  # payload's top-level `src`. The live disk has a different `src`, which a
  # lazy load must not reach.
  let project = joinPath(dir, cstring"project")
  writeTree(project, cstring"src/live_only.nr")
  writeTree(joinPath(filesRoot, cstring(stripTraceSourceRoot($project))),
            cstring"Nargo.toml")

  # 1. A live fallback gets the live-filesystem rules.
  let liveGroup = await loadFilesystem(@[repo], filesRoot, selfContained = true)
  let repoNode = liveGroup.childNamed("repo")
  ck not repoNode.isNil, "the live fallback root is loaded"
  let names = repoNode.childNames()
  ck ".git" notin names and "node_modules" notin names,
    "the live fallback skips .git and node_modules (got " & $names & ")"
  ck "src" notin names and "std" notin names,
    "no payload entry is overlaid into the live folder (got " & $names & ")"
  let a = repoNode.childNamed("a")
  ck a.isCollapsedStub(),
    "a live folder one level down is a collapsed Loading... stub (got " &
      a.describe() & ")"
  ck repoNode.isOpened(), "the live root itself is opened"
  ck payloadLocation(a) == "",
    "a live folder carries no payload location (got '" & payloadLocation(a) & "')"
  ck repoNode.indicesArePositions(),
    "a live root's children are indexed by position, skipped .git included"

  # 2. A payload root lists its own entries; its folders are stubs.
  let payloadGroup = await loadFilesystem(@[cstring"src"], filesRoot,
                                          selfContained = true)
  let src = payloadGroup.childNamed("src")
  ck not src.isNil and "main.nr" in src.childNames(),
    "a payload root is read from the payload"
  ck src.isOpened(), "a payload root is opened"
  let lib = src.childNamed("lib")
  ck lib.isCollapsedStub(),
    "a payload root's subfolder is a collapsed Loading... stub (got " &
      lib.describe() & ")"
  ck payloadLocation(lib) == "src/lib",
    "a payload stub remembers where it was read (got '" &
      payloadLocation(lib) & "')"

  # 3. A lazy load of a payload stub lists that folder, one level.
  let libLoaded = await lazyLoad(lib, filesRoot)
  ck libLoaded.childNames() == @["util.nr", "x"],
    "a lazy load lists the payload folder's entries (got " &
      libLoaded.describe() & ")"
  ck libLoaded.isOpened(), "a lazily loaded folder is opened"
  let x = libLoaded.childNamed("x")
  ck x.isCollapsedStub(),
    "a lazily loaded folder's subfolders are stubs (got " & x.describe() & ")"
  ck payloadLocation(x) == "src/lib/x",
    "a lazily loaded stub remembers where it was read (got '" &
      payloadLocation(x) & "')"
  ck libLoaded.index == lib.index and libLoaded.indicesArePositions(),
    "a lazy load keeps the stub's place and indexes its children by position"

  # 4. An overlay folder lazily expands to the payload's contents.
  let projectGroup = await loadFilesystem(@[project], filesRoot,
                                          selfContained = true)
  let projectNode = projectGroup.childNamed("project")
  ck not projectNode.isNil and "Nargo.toml" in projectNode.childNames() and
      "src" in projectNode.childNames(),
    "an absolute payload root shows its mirror and the overlaid top level (got " &
      projectNode.describe() & ")"
  let overlaidSrc = projectNode.childNamed("src")
  ck overlaidSrc.isCollapsedStub(),
    "an overlaid folder is a collapsed stub (got " & overlaidSrc.describe() & ")"
  ck payloadLocation(overlaidSrc) == "src",
    "an overlaid folder remembers the payload's top-level src (got '" &
      payloadLocation(overlaidSrc) & "')"
  ck projectNode.indicesArePositions(),
    "an overlaid folder is indexed by its position under the root"
  let overlaidLoaded = await lazyLoad(overlaidSrc, filesRoot)
  ck overlaidLoaded.childNames() == @["lib", "main.nr"],
    "an overlaid folder lazily expands to the payload's src, not the live " &
      "disk's (got " & overlaidLoaded.describe() & ")"
  ck overlaidLoaded.childNamed("lib").isCollapsedStub() and
      payloadLocation(overlaidLoaded.childNamed("lib")) == "src/lib",
    "an overlaid folder's own subfolders are payload stubs (got " &
      overlaidLoaded.childNamed("lib").describe() & ", '" &
      payloadLocation(overlaidLoaded.childNamed("lib")) & "')"

  # 5. A lazy load never overlays the payload top level.
  let projectLazy = await lazyLoad(projectNode, filesRoot)
  ck projectLazy.childNames() == @["Nargo.toml"],
    "a lazy load from the payload location overlays nothing (got " &
      projectLazy.describe() & ")"
  let projectResolved = await loadPathContentPartially(
    projectNode.original.path, projectNode.index, projectNode.parentIndices,
    filesRoot, selfContained = true)
  ck projectResolved.childNames() == @["Nargo.toml"],
    "a lazy load resolved from the display path overlays nothing (got " &
      projectResolved.describe() & ")"
  # A payload location that leaves files/ is refused, and the load falls
  # back to resolving the display path.
  let escaping = await loadPathContentPartially(
    projectNode.original.path, projectNode.index, projectNode.parentIndices,
    filesRoot, selfContained = true, payloadPath = cstring"../../repo")
  ck escaping.childNames() == @["Nargo.toml"],
    "a payload location outside files/ is not followed (got " &
      escaping.describe() & ")"

  # 6. A root over a large live folder costs one listing.
  let big = joinPath(dir, cstring"big")
  for folder in 0 ..< 50:
    for file in 0 ..< 50:
      writeTree(big, cstring("d" & $folder & "/f" & $file & ".nr"))
  let bigGroup = await loadFilesystem(@[big], cstring"", selfContained = false)
  var stubs = 0
  let nodes = countNodes(bigGroup.childNamed("big"), stubs)
  ck nodes == 51 and stubs == 50,
    "a large live root yields the root and its 50 entries, one stub each " &
      "(got " & $nodes & " nodes, " & $stubs & " stubs)"

  # 7. A rejected root load still answers.
  let window = recordingWindow()
  # A nil payload root makes `path.join` throw inside `loadFile`, before any
  # of its own `try`s: a real rejection of the whole load.
  await sendFilesystem(window.toJs, @[cstring"src"], cstring(nil),
                       selfContained = true)
  let sent = window[cstring"sent"]
  ck sent[cstring"length"].to(int) == 1, "the failed load sent one answer"
  let answer = sent[0]
  ck $answer[cstring"channel"].to(cstring) == "CODETRACER::filesystem-loaded",
    "the answer is on the filesystem-loaded channel"
  let payload = answer[cstring"payload"]
  ck payload[cstring"folders"].isUndefined, "the answer carries no tree"
  let error = $payload[cstring"error"].to(cstring)
  ck error.len > 0 and "src" in error,
    "the answer carries the reason, naming the root (got '" & error & "')"

  # And a load that succeeds answers with its tree.
  let okWindow = recordingWindow()
  await sendFilesystem(okWindow.toJs, @[cstring"src"], filesRoot,
                       selfContained = true)
  let okSent = okWindow[cstring"sent"]
  ck okSent[cstring"length"].to(int) == 1 and
      not okSent[0][cstring"payload"][cstring"folders"].isUndefined,
    "a successful load answers with its tree"

proc main() {.async.} =
  let dir = makeTempDir()
  try:
    await runCases(dir)
  except:
    inc failedChecks
    echo "  [FAILED] the suite raised: ", getCurrentExceptionMsg()
  removeDir(dir)
  echo "CHECKS: ", checks
  if checks != ExpectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", ExpectedChecks, " cases"
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

discard main()
