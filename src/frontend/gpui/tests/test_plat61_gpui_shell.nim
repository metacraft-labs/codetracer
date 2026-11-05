## test_plat61_gpui_shell.nim — the Shell pane in the GPUI window, read from
## the window's own render plan.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.
##
## The shipped `codetracer-gpui` (`just build-gpui`) with
## `--report-window-plan` on the `calc` fixture (recorded by `ct record` with
## the pinned recorder, opened by a real `replay-server`), `--window-ops`
## events dispatched through the window's own handlers — `shell:show`, then
## `type:` / `key:enter` into the focused pane's shell (a real bash on a real
## pty, this build's `ct` first on its `PATH`), `shell:wait:` pumping it —
## then the window as a plan. Asserted:
##
##   * THE PANE: running, at the size its layout gives (`data-ct-shell-size`),
##     its header the model's words;
##   * THE RECORDED BUILD: the build's lines in order, the recording's two
##     lines marked (`start` then `range`, in the success tone, their gutter
##     the model's glyph and bar in the design system's success colour), the
##     id `ct record` printed after them unmarked — the same rows the
##     terminal's suite and the desktop's view check;
##   * THE PRESS OPENS THE RECORDING: `shell:gutter:0` opens the recording's
##     folder as a new session tab, shown.
##
## No mocks: the real binary, real recordings, a real engine, a real shell.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env
import ../../tui/tests/fixtures/fixture_provider
import styles/generated/design_tokens

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 17
  W = 1600
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

let fixture = resolveFixture("calc")
if fixture.outcome != foRecorded:
  echo missingPrereqMessage(fixture.spec, fixture.detail)
  quit(1)
let ct = fixture_provider.findCtBinary()
doAssert ct.len > 0, "`ct` is not built (just build-once)"

let project = createTempDir("plat61-gpui-shell-", "")
writeFile(project / "build.sh", """#!/bin/sh
cd "$(dirname "$0")"
echo "building prog.py"
printf 'def add(a, b):\n    return a + b\nprint("sum", add(2, 3))\nprint("done")\n' > prog.py
rm -rf rec-build
ct record -o rec-build prog.py
""")
setFilePermissions(project / "build.sh", {fpUserRead, fpUserWrite, fpUserExec})
# The shell's prompt, fixed: an rc file rather than `PS1` in the environment,
# which the `/bin/sh` the binary is started through does not pass on.
writeFile(project / "shellrc", "PS1='$ '\n")

proc windowPlan(ops: string): tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat61-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  env["CODETRACER_SHELL_COMMAND"] = "bash --noprofile --rcfile " &
                                    project / "shellrc" & " -i"
  env["PATH"] = ct.parentDir & PathSep & getEnv("PATH")
  createDir(state / "ct-home")
  writeFile(state / "ct-home" / ".codetracer-test-home", "")
  let errFile = genTempPath("plat61-gpui-plan-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, fixture.tracePath]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  result.trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & result.trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result.plan = parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

type Row = tuple[text, mark, tone, gutter: string; node: JsonNode]

proc shellRowsOf(plan: JsonNode): seq[Row] =
  for n in plan.nodesWith("data-ct-shell-line"):
    let gutter = if n{"children"}.len > 0: n["children"][0].textOf else: ""
    result.add (n.attr("data-ct-shell-text"), n.attr("data-ct-shell-mark"),
                n.attr("data-ct-shell-tone"), gutter, n)

proc cssHex(rgb: string): string =
  ## `rgb(r, g, b)` (a computed style) as `#rrggbb`.
  let parts = rgb.multiReplace(("rgb(", ""), (")", "")).split(',')
  result = "#"
  for p in parts:
    result.add toHex(parseInt(p.strip), 2).toLowerAscii

proc indexOf(rows: seq[Row]; text: string): int =
  for i, r in rows:
    if r.text == text: return i
  -1

# The wait is for a line the shell prints only once the build has returned
# (`built-42`, which the typed `$((6*7))` is not): `ct record` has reported
# the recording by then. `recordingId:` alone comes before that report.
const BuildOps = "shell:show,shell:wait:$,type:PROJECT/build.sh; echo built-$((6*7))," &
                 "key:enter,shell:wait:built-42"

suite "PLAT-61 the Shell pane in the GPUI window":
  let ops = BuildOps.replace("PROJECT", project)

  test "the pane runs a recorded build; its recording's lines are marked":
    let (plan, trace) = windowPlan(ops)
    checkpoint(trace)
    let panes = plan.nodesWith("data-ct-shell")
    ck panes.len == 1
    ck panes[0].attr("data-ct-shell") == "running"
    let size = panes[0].attr("data-ct-shell-size")
    ck size.split('x').len == 2 and parseInt(size.split('x')[0]) > 20
    ck plan.nodesWith("data-ct-shell-header")[0].attr("data-ct-shell-header") ==
       "running — 1 recording"
    let rows = plan.shellRowsOf
    var shown: seq[string]
    for r in rows: shown.add r.mark & "|" & r.text
    checkpoint("rows:\n" & shown.join("\n"))
    let b = rows.indexOf("building prog.py")
    # The typed line (it may wrap at the pane's width), then the build's.
    var typedAt = -1
    for i in 0 ..< max(0, b):
      if rows[i].text.startsWith("$ " & project / "build.sh"): typedAt = i
    ck b >= 1 and typedAt >= 0 and typedAt < b
    ck rows[b + 1].text == "sum 5" and rows[b + 1].mark == "start" and
       rows[b + 1].tone == "ok"
    ck rows[b + 2].text == "done" and rows[b + 2].mark == "range"
    ck rows[b + 3].text.startsWith("recordingId:") and rows[b + 3].mark == ""
    ck rows[b + 1].gutter == "●" and rows[b + 2].gutter == "│"
    let g = rows[b + 1].node["children"][0]
    ck g{"styles"}{"text_color"}.getStr.toLowerAscii ==
       DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark].toLowerAscii
    ck g.attr("data-ct-shell-gutter").startsWith("recorded command: prog.py")
    # THE DESKTOP'S: the same lines, marks, tones, glyphs and gutter colour
    # (`plat61-shell-capture.spec.ts`), and the same words.
    let answers = parseJson(readFile(
      repo / "src/tests/visual/answers/plat61-shell.electron.json"))
    var mine, desktop: seq[string]
    for i in 0 .. 3:
      let r = rows[b + i]
      var text = r.text
      let at = text.find("recordingId:")
      if at >= 0: text = text[0 ..< at] & "recordingId:<id>"
      mine.add text & "|" & (if r.mark.len == 0: "none" else: r.mark) & "|" &
               r.tone & "|" & r.gutter
    for r in answers["rows"]:
      desktop.add r["text"].getStr & "|" & r["mark"].getStr & "|" &
                  r["tone"].getStr & "|" & r["gutter"].getStr
    ck mine == desktop
    ck cssHex(answers["rows"][1]["gutterColor"].getStr) ==
       g{"styles"}{"text_color"}.getStr.toLowerAscii
    ck plan.nodesWith("data-ct-shell-header")[0].attr("data-ct-shell-header") ==
       answers["status"].getStr

  test "a press on the gutter opens the recording in a new tab":
    let (plan, trace) = windowPlan(ops & ",shell:gutter:0")
    checkpoint(trace)
    ck trace.contains("shell: open " & project / "rec-build")
    ck trace.contains("opened " & project / "rec-build" & " as tab 1")
    ck trace.contains("session shown 1 " & project / "rec-build")
    discard plan

  test "every assertion ran":
    removeDir(project)
    check CHECKS == ExpectedAssertions
