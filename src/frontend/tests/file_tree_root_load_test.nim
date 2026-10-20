## file_tree_root_load_test.nim
##
## The index process's root load of the Files pane (GitHub #785), run against
## a real temporary directory.
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
## The cases:
##
## 1. A live fallback onto a repository gets the live-filesystem rules:
##    `.git` and `node_modules` are skipped, a folder two levels down is a
##    "Loading..." stub, and no payload entry is overlaid into it.
## 2. A payload root is still loaded whole — the fallback rules must not leak
##    into a trace's own source set.
## 3. A root load that rejects still answers `filesystem-loaded`, with an
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

const ExpectedChecks = 11

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
  makeDir(filesRoot, cstring"std")

  # 1. A live fallback gets the live-filesystem rules.
  let liveGroup = await loadFilesystem(@[repo], filesRoot, selfContained = true)
  let repoNode = liveGroup.childNamed("repo")
  ck not repoNode.isNil, "the live fallback root is loaded"
  let names = repoNode.childNames()
  ck ".git" notin names and "node_modules" notin names,
    "the live fallback skips .git and node_modules (got " & $names & ")"
  ck "src" notin names and "std" notin names,
    "no payload entry is overlaid into the live folder (got " & $names & ")"
  let b = repoNode.childNamed("a").childNamed("b")
  ck not b.isNil and b.childNames() == @["Loading..."],
    "a live folder two levels down is a Loading... stub (got " &
      (if b.isNil: "nothing" else: $b.childNames()) & ")"

  # 2. A payload root is loaded whole, as before.
  let payloadGroup = await loadFilesystem(@[cstring"src"], filesRoot,
                                          selfContained = true)
  let src = payloadGroup.childNamed("src")
  ck not src.isNil and "main.nr" in src.childNames(),
    "a payload root is read from the payload"
  let z = src.childNamed("lib").childNamed("x").childNamed("y").childNamed("z")
  ck not z.isNil and z.childNames() == @["deep.nr"],
    "a payload root is loaded whole, with no depth limit"

  # 3. A rejected root load still answers.
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
