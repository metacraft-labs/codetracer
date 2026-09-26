## test_gpui_layout_flag.nim — **a saved layout with a DOCKED pane opens
## through the shipped binary's `--layout=`.**
##
## Run (needs `just build-gpui`, the `calc` recording under
## `test-logs/tui-fixtures/`, and `REPLAY_SERVER_BIN`):
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_layout_flag.nim
##
## `codetracer-gpui --layout=<file>` used to decode with the TREE-ONLY
## `restoreLayout`, which refuses any document whose `docked` list is not empty
## (`ldeDockedPanesUnsupported`). So a layout saved after `:dock bottom` in the
## terminal — whose document is exactly `saveLayout(Layout)` — or after a dock
## in a GPUI window could not be opened here, although the same document
## restores through `GpuiShell.restoreWindowLayout`. This suite runs the SHIPPED
## binary on a REAL recording and reads the arrangement back out of the render
## plan it prints (the Rust-side shadow tree), never out of the `Layout` it
## wrote:
##
##   * the docked pane is drawn in the dock's BOTTOM region, every other pane
##     in the centre, and the drawn pane set is the document's pane set;
##   * the negative twin: the same run WITHOUT `--layout=` draws that pane in
##     the centre, so "bottom" is the document's doing and not the default's;
##   * an unreadable docked entry is still refused loudly, by kind, with a
##     non-zero exit — the flag's "no silent fallback" rule.
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a real
## recording and a real file.

import std/[json, os, osproc, sets, streams, strtabs, strutils, tempfiles,
            unittest]

import headless_app/layout_model

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = repo.parentDir / "isonim-gpui/rust/target/debug"
let calc = repo / CalcFixture

proc requirePrereq(ok: bool; what: string) =
  ## **A MISSING PREREQUISITE FAILS BY NAME. It does not skip.**
  if not ok:
    raise newException(IOError, "prerequisite missing: " & what)

proc runBinary(extra: seq[string]): (int, string, string) =
  ## `(rc, stdout, stderr)` of one headless `--report-plan` run on `calc`.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  let errFile = genTempPath("gpui-layout-flag-", ".err")
  var args = @["--report-plan", "--width=1440", "--height=900"]
  args.add extra
  args.add calc
  # stderr to a file rather than merged: the plan on stdout must parse as JSON.
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  (rc, output, err)

proc drawnPanes(plan: JsonNode): seq[(string, string)] =
  ## Every `(data-ct-pane, data-ct-slot-path)` the plan carries, in plan order.
  result = @[]
  proc walk(n: JsonNode; acc: var seq[(string, string)]) =
    if n.kind != JObject:
      return
    if n.hasKey("attributes") and n["attributes"].kind == JObject:
      let a = n["attributes"]
      if a.hasKey("data-ct-pane"):
        acc.add((a["data-ct-pane"].getStr,
                 (if a.hasKey("data-ct-slot-path"):
                    a["data-ct-slot-path"].getStr
                  else: "")))
    if n.hasKey("children") and n["children"].kind == JArray:
      for c in n["children"]:
        walk(c, acc)
  walk(plan, result)

proc regionOf(drawn: seq[(string, string)]; pane: PaneKind): string =
  for (id, path) in drawn:
    if id == $pane:
      return path.split('/')[0]
  ""

suite "codetracer-gpui --layout= opens a saved layout with a docked pane":

  test "the prerequisites are here":
    requirePrereq(fileExists(bin), bin & " (just build-gpui)")
    requirePrereq(dirExists(calc), calc & " (run 'just test-tui' once)")
    requirePrereq(existsEnv("REPLAY_SERVER_BIN") and
                  fileExists(getEnv("REPLAY_SERVER_BIN")),
                  "REPLAY_SERVER_BIN naming a built replay-server")
    ck true

  test "the docked pane is drawn in the dock's bottom region":
    # The document a terminal writes after `:dock bottom` on the Event Log —
    # `saveLayout(Layout)`, the same encoder its persistence uses.
    let docked = apply(initLayout(defaultReplayLayout()),
                       cmdDock(paneEventLog, leBottom))
    ck docked.kind == loApplied
    doAssert docked.kind == loApplied, "the dock command was refused"
    let saved = saveLayout(docked.layout)
    ck saved["docked"].len == 1
    let dir = createTempDir("gpui-layout-flag-", "")
    try:
      let file = dir / "layout.json"
      writeFile(file, $saved)
      let (rc, output, err) = runBinary(@["--layout=" & file])
      checkpoint("rc " & $rc & "; stderr: " & err)
      ck rc == 0
      ck not err.contains("cannot open")
      let drawn = if rc == 0: drawnPanes(parseJson(output)) else: @[]
      checkpoint($drawn)
      ck regionOf(drawn, paneEventLog) == "bottom"
      var ids = initHashSet[string]()
      var othersCentred = true
      for (id, path) in drawn:
        ids.incl id
        if id != $paneEventLog and not path.startsWith("center/"):
          othersCentred = false
      ck othersCentred
      # Every pane the document places or docks, and nothing else.
      var want = initHashSet[string]()
      for p in docked.layout.allPanes():
        want.incl $p
      ck ids == want
    finally:
      removeDir(dir)

  test "the negative twin: without --layout= the same pane is in the centre":
    let (rc, output, err) = runBinary(@[])
    checkpoint("rc " & $rc & "; stderr: " & err)
    ck rc == 0
    let drawn = if rc == 0: drawnPanes(parseJson(output)) else: @[]
    checkpoint($drawn)
    ck regionOf(drawn, paneEventLog) == "center"

  test "an unreadable docked entry is still refused, loudly and by kind":
    var saved = saveLayout(initLayout(defaultReplayLayout()))
    saved["docked"] = %*[{"pane": $paneShell, "edge": "diagonal",
                          "order": 0}]
    let dir = createTempDir("gpui-layout-flag-", "")
    try:
      let file = dir / "layout.json"
      writeFile(file, $saved)
      let (rc, _, err) = runBinary(@["--layout=" & file])
      checkpoint("rc " & $rc & "; stderr: " & err)
      ck rc == 1
      ck err.contains("--layout: cannot open")
      ck err.contains($ldeUnknownEdge)
    finally:
      removeDir(dir)

  test "every check ran":
    echo "CHECKS: ", CHECKS
    check CHECKS == 13
