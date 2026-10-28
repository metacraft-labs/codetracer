## test_plat58_gpui_requests.nim — the Requests pane in the GPUI window, read
## from the window's own render plan.
##
## Spec: `codetracer-pm` `spec/GUI/Core-Panes/Request-Panel.md` § "The terminal
## and the GPUI window (PLAT-58)".
##
## The shipped `codetracer-gpui` (`just build-gpui`) with
## `--report-window-plan` on the RS-M4 demo session — a real `.ct` container
## carrying eight request spans over a recorded timeline, written by the
## canonical writer (`src/tools/demo_request_session`) and opened by a real
## `replay-server` — `--window-ops` events dispatched through the window's own
## pointer handler (`requests:*`, aimed where the pane was drawn), then the
## window as a plan. Asserted:
##
##   * THE REVEAL: the recording serves requests, so the docked REQUESTS pane
##     is open without being asked for;
##   * THE ROWS: every request's `#`, method, URL, status, duration and size,
##     equal to the producer's input table formatted by hand AND to the real
##     Electron app's rows on the same session (`src/tests/visual/answers/
##     plat58-requests.electron.json`, `just plat58-capture-electron`), each
##     status in the desktop's computed colour, each row's method tone, the
##     filter bar's words;
##   * THE FILTERS: `:requests users` in the omnibox, the Method picker's
##     dropdown (the desktop's options) and an option chosen;
##   * A DOUBLE PRESS GOES TO THE HANDLER: the editor's execution line is the
##     handler's, the Call Trace's selected call is the request's; a single
##     press moves nothing;
##   * THE MENU: its entries in order; Go to Handler moves; Copy URL copies;
##   * KEYS: the pane focused by a press, `list.focus-next` and
##     `list.activate` go to the next request's handler.
##
## No mocks: the real binary, a real container, a real engine, the real
## Electron app's answers.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import results
import ./gpui_child_env

import ../../../tools/demo_request_session
import styles/generated/design_tokens

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 64
    ## Measured. The first case checks EVERY row (those the docked pane shows
    ## first, then the rest after a wheel to the end), so each status bucket
    ## — the 5xx included, below the fold — is compared with the desktop.
  W = 1600
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

let folder = createTempDir("plat58-gpui-requests-", "")
doAssert writeDemoRequestSession(folder).isOk

proc windowPlan(ops: string): tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat58-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  createDir(state / "ct-home")
  writeFile(state / "ct-home" / ".codetracer-test-home", "")
  let errFile = genTempPath("plat58-gpui-plan-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, folder]
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

proc cells(row: JsonNode): seq[string] =
  ## A request row's six cells, as drawn (each a span child).
  for c in row{"children"}.getElems:
    result.add c.textOf.strip()

proc ids(plan: JsonNode): seq[string] =
  for r in plan.nodesWith("data-ct-request-id"):
    result.add r.attr("data-ct-request-id")

proc selectedCall(plan: JsonNode): string =
  for n in plan.nodesWith("data-call-selected"):
    if n.attr("data-call-selected") == "true":
      return n.attr("data-call-index")
  ""

proc executionLine(plan: JsonNode): string =
  for n in plan.nodesWith("data-ct-execution-line"):
    return n.attr("data-ct-execution-line")
  ""

let answers = parseJson(readFile(
  repo / "src/tests/visual/answers/plat58-requests.electron.json"))
  ## The REAL desktop's panel on the same session
  ## (`plat58-requests-capture.spec.ts`, `just plat58-capture-electron`).

proc cssHex(rgb: string): string =
  ## `rgb(r, g, b)` (a computed style) as `#rrggbb`.
  let parts = rgb.strip().replace("rgb(", "").replace(")", "").split(",")
  if parts.len < 3: return ""
  "#" & parts[0].strip.parseInt.toHex(2).toLowerAscii &
        parts[1].strip.parseInt.toHex(2).toLowerAscii &
        parts[2].strip.parseInt.toHex(2).toLowerAscii

proc typed(text: string): string =
  ## `--window-ops` keys typing `text` (the PLAT-50 plan suite's spelling).
  for ch in text:
    result.add(if ch == ' ': ",key:space" else: ",key:" & $ch)

proc handSize(bytes: int): string =
  if bytes < 1024: $bytes & " B"
  else: $(bytes div 1024) & "." & $((bytes mod 1024) * 10 div 1024) & " KB"

proc handDuration(ms: int): string =
  if ms < 1000: $ms & "ms" else: $(ms div 1000) & "." & $((ms mod 1000) div 100) & "s"

proc oracleRow(i: int): seq[string] =
  let d = DemoRequests[i]
  let id = i + 2
  @[(if id < 10: "0" & $id else: $id), d.httpMethod, d.url, $d.statusCode,
    handDuration(d.durationMs), handSize(d.responseSize)]

suite "PLAT-58: the Requests pane in the GPUI window":

  test "revealed by itself, every row as the producer wrote it":
    let (plan, _) = windowPlan("wait:0")
    let pane = plan.nodesWith("data-ct-requests")
    ck pane.len == 1
    if pane.len == 1:
      ck pane[0].attr("data-ct-requests") == $DemoRequests.len
      ck pane[0].attr("data-ct-pane") == "requests"
    let rows = plan.nodesWith("data-ct-request-id")
    ck rows.len >= 3
    # The rows the pane shows first, then the rest after a wheel to the end:
    # every status bucket the recording carries (the 5xx is the 7th row,
    # below the fold of the docked pane) is checked against the desktop.
    let (scrolled, _) = windowPlan("requests:wheel:" & $DemoRequests.len &
                                   ",wait:0")
    var seen: seq[int] = @[]
    for row in rows & scrolled.nodesWith("data-ct-request-id"):
      let i = parseInt(row.attr("data-ct-request-id")) - 2
      if i in seen:
        continue
      seen.add i
      let k = seen.len - 1
      checkpoint("row " & $k & ": " & $row.cells)
      ck row.cells == oracleRow(i)
      let want = case DemoRequests[i].statusCode div 100
                 of 2: "success"
                 of 3: "redirect"
                 of 4: "client-error"
                 else: "server-error"
      ck row.attr("data-ct-request-status-tone") == want
      # The status in its bucket's colour, the desktop's
      # `request-status-<bucket>` token.
      let colour = case DemoRequests[i].statusCode div 100
                   of 2: DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
                   of 3: DesignTokenHex[dtColorsUiTextInformationPrimary][dmDark]
                   of 4: DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark]
                   else: DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
      let status = row{"children"}[3]
      checkpoint("status colour " & status{"styles"}{"text_color"}.getStr)
      ck status{"styles"}{"text_color"}.getStr.toLowerAscii ==
        colour.toLowerAscii
      # …the REAL desktop's computed colour for that status, and its cells.
      let desktop = answers["rows"][i]
      ck colour.toLowerAscii == cssHex(desktop["statusColor"].getStr)
      var cells: seq[string] = @[]
      for c in desktop["cells"]: cells.add c.getStr
      ck row.cells == cells
    ck seen.len == DemoRequests.len
    ck plan.nodesWith("data-ct-requests-search")[0].textOf == "Find by URL..."
    var pickers: seq[string] = @[]
    for p in plan.nodesWith("data-ct-requests-picker"):
      pickers.add p.textOf
    ck pickers == @["Method: All ▾", "Status: All ▾"]
    let header = plan.nodesWith("data-ct-requests-header")[0].cells
    ck header[0] == "#" and header[1] == "method" and header[2] == "URL"

  test "the URL search from the omnibox, and the Method picker":
    let (plan, trace) = windowPlan(
      "key:p:control,key:colon" & typed("requests users") &
      ",key:enter,requests:method,ctx:DELETE")
    ck "context menu request-picker Method: All|GET|POST|PUT|DELETE|PATCH|" &
       "HEAD|OPTIONS" in trace
    ck plan.ids == @["6"]
    ck plan.nodesWith("data-ct-requests-search")[0].textOf == "users"
    var pickers: seq[string] = @[]
    for p in plan.nodesWith("data-ct-requests-picker"):
      pickers.add p.textOf
    ck pickers[0] == "DELETE ▾"

  test "one press selects; a double press goes to the handler":
    let (one, _) = windowPlan("requests:row:4")
    let before = windowPlan("wait:0")[0].selectedCall
    ck one.selectedCall == before
    var selected: seq[string] = @[]
    for r in one.nodesWith("data-ct-selected"):
      if r.has("data-ct-request-id"): selected.add r.attr("data-ct-request-id")
    ck selected == @["4"]
    ck one.nodesWith("data-ct-requests-detail")[0].textOf.contains("200 OK")
    let (two, trace) = windowPlan("requests:double:4")
    ck "requests: the handler of /api/users/42" in trace
    ck two.executionLine == "13"
    ck two.selectedCall == "2"

  test "the row's menu":
    let (plan, trace) = windowPlan(
      "requests:menu:8,ctx:Go to Handler,requests:menu:8,ctx:Copy URL")
    ck "context menu request-row Go to Handler|Copy URL|Filter by Method: " &
       "PUT|Filter by Status: 5xx|Clear Filters" in trace
    ck "requests: the handler of /api/orders/7" in trace
    ck "copied the URL: /api/orders/7" in trace
    ck plan.selectedCall == "6"

  test "keys, with the pane focused by a press":
    let (plan, trace) = windowPlan(
      "requests:row:2,requests:key:list.focus-next," &
      "requests:key:list.activate")
    ck "requests: the handler of /api/users" in trace
    ck plan.selectedCall == "1"

  test "the assertion count":
    removeDir(folder)
    check CHECKS == ExpectedAssertions
