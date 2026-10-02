## test_plat49_gpui_plan.nim — PLAT-49 part A, **what the GPUI window DRAWS
## for the user's 2026-10-01 findings, read out of the window's own render
## plan**: the shipped `build/bin/codetracer-gpui` (`just build-gpui`) with
## `--report-window-plan` — the window's own root builder over a detached
## root, the `--window-ops` events dispatched through the window's own pointer
## and key handlers, the resulting shadow tree printed (the tree the shim
## paints) — on the real `calc` recording stepped by a real replay-server.
##
##   1. MENU — one root button and no folder titles in the band; the button
##      (or `Ctrl+M`) opens the first level as a popover below it; Right on a
##      folder, or a click on it, opens its submenu as a popover to the RIGHT
##      of the first level, level with the folder's row.
##   2. CLICKS — a press on an inactive tab moved less than the click slop
##      and released activates it, and nothing is dragged (no drop tint, no
##      ghost); a press moved past it is a drag.
##   3. NO HEADINGS — no leaf in the window carries a pane-title heading;
##      every pane box, a lone pane's included, has a tab strip naming it.
##   4. TAB STRIPS — every strip on its own ground (`crTabStripBackground`,
##      ui/surface/base/card), the selected tab on a background
##      (`crTabActiveBackground`) and in a foreground (`crTabActiveForeground`)
##      of its own and bold, the others on the strip's ground in the inactive
##      tier; the pane body under the strip on the pane's surface.
##   5. TOOLTIP — the pointer over a control draws the hover popover with the
##      ViewModel's `transportTooltip` (label and the desktop binding's key).
##   3b. A LONE EDITOR'S TAB IS ITS FILE — the open file's name, as the
##      terminal's and the desktop's editor tab are; in an Edit window, " ●"
##      after it once a key has modified the buffer (keys reach the editor,
##      which holds the focus there), and gone again after a save.
##   6. OMNIBAR — the closed field shows the Omnibar ViewModel's placeholder
##      on the input surface; open, the query with its caret — a bar while
##      inserting, a block after `Insert` — where the ViewModel's caret is.
##
## Run (needs `just build-gpui`, the `calc` recording under
## `test-logs/tui-fixtures/`, `REPLAY_SERVER_BIN`, isonim-gpui's shim):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat49_gpui_plan.nim
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a
## real recording. A missing prerequisite fails by name.

import std/[json, os, osproc, streams, strtabs, strutils, tables, tempfiles,
            unittest]

import codetracer_embed
import gpui/chrome
import gpui/window_geometry
import gpui/window_top_bar

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 186
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1920
  H = 1080

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

proc windowPlan(ops: string; geometry: var JsonNode;
                pre: seq[string] = @[]; subject = ""): JsonNode =
  ## The window's root after `ops`, as the shipped binary reports it, and the
  ## geometry file the window wrote (where it drew every pane, tab and part).
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if not dirExists(calc):
    raise newException(IOError, "prerequisite missing: " & calc)
  let state = createTempDir("plat49-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  let geomFile = state / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geomFile
  var args = pre & @["--report-window-plan", "--width=" & $W,
                     "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add (if subject.len > 0: subject else: calc)
  let errFile = genTempPath("plat49-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  geometry = if fileExists(geomFile): parseFile(geomFile) else: newJNull()
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result = parseJson(output)
  # The marks' SVG files the plan names are left for its reader; drop them.
  proc sweep(n: JsonNode) =
    if n{"tag"}.getStr == "img":
      let src = n{"attributes"}{"src"}.getStr
      if src.len > 0 and fileExists(src):
        try: removeDir(src.parentDir)
        except OSError: discard
    for c in n{"children"}.getElems: sweep(c)
  sweep(result)

proc windowPlan(ops: string): JsonNode =
  var g: JsonNode
  windowPlan(ops, g)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc style(n: JsonNode; name: string): string = n{"styles"}{name}.getStr

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc px(n: JsonNode; style: string): int =
  let v = n{"styles"}{style}.getStr
  if v.endsWith("px"): parseInt(v[0 ..< v.len - 2]) else: -1

proc rectOf(n: JsonNode): PxRect =
  PxRect(x: n.px("left"), y: n.px("top"), w: n.px("w"), h: n.px("h"))

proc popover(plan: JsonNode; path: string): JsonNode =
  for p in plan.nodesWith("data-ct-menu-popover"):
    if p.attr("data-ct-menu-popover") == path:
      return p
  nil

proc item(plan: JsonNode; label: string): JsonNode =
  for it in plan.nodesWith("data-ct-menu-item"):
    if it.attr("data-ct-menu-item") == label:
      return it
  nil

proc centre(r: JsonNode): (int, int) =
  (r[0].getInt + r[2].getInt div 2, r[1].getInt + r[3].getInt div 2)

suite "PLAT-49: the GPUI window's chrome, as drawn":

  test "one root menu button; the first level below it; submenus cascade right":
    let plan = windowPlan("")
    ck plan.nodesWith("data-ct-menu-button").len == 1
    ck plan.nodesWith("data-ct-menu-title").len == 0
    ck plan.nodesWith("data-ct-menu-popover").len == 0
    let button = plan.nodesWith("data-ct-menu-button")[0].rectOf
    # Ctrl+M opens the first level, below the button, one folder per row.
    let opened = windowPlan("key:m:control")
    let first = opened.popover("@[]")
    ck not first.isNil
    let fr = first.rectOf
    ck fr.x == button.x
    ck fr.y >= button.y + button.h
    var labels: seq[string] = @[]
    var lastY = -1
    for it in opened.nodesWith("data-ct-menu-item"):
      labels.add it.attr("data-ct-menu-item")
      ck it.rectOf.y > lastY
      lastY = it.rectOf.y
      ck it.rectOf.x == fr.x
    ck labels == @["File", "Edit", "View", "Build", "Reset", "Debug", "Help"]
    # Right on Debug: its items as a second popover, to the right of the first
    # and level with Debug's row.
    let walked = windowPlan("key:m:control,key:down,key:down,key:down," &
                            "key:down,key:down,key:right")
    let debugRow = walked.item("Debug")
    let cont = walked.item("Continue")
    ck not debugRow.isNil and not cont.isNil
    ck cont.rectOf.x >= walked.popover("@[]").rectOf.x +
                        walked.popover("@[]").rectOf.w
    ck abs(cont.rectOf.y - debugRow.rectOf.y) <= 4
    # The pointer: the button, then the folder — the same cascade.
    let clicked = windowPlan("menu:Debug")
    ck not clicked.item("Continue").isNil
    ck clicked.item("Continue").rectOf.x == cont.rectOf.x

  test "no heading in any pane; every pane box has a strip naming it":
    let plan = windowPlan("")
    for n in plan.nodesWith("data-ct-text-role"):
      ck n.attr("data-ct-text-role") != "pane-title"
    let strips = plan.nodesWith("data-ct-tabs")
    ck strips.len >= 5
    var lone = 0
    for s in strips:
      let labels = s.attr("data-ct-tabs").split(',')
      if labels.len == 1: inc lone
      ck s{"children"}.len == labels.len
      for i, t in s{"children"}.getElems:
        ck t.textOf == labels[i]
    ck lone >= 1                     # the editor: a lone pane, one tab
    # …and no pane VIEW titles itself either: the State pane's own first row
    # used to repeat "State" under its strip.
    var stateTexts: seq[string] = @[]
    proc texts(n: JsonNode; acc: var seq[string]) =
      if n.kind != JObject: return
      if n{"kind"}.getStr == "TextNode": acc.add n{"text"}.getStr
      for c in n{"children"}.getElems: texts(c, acc)
    for n in plan.nodesWith("data-ct-pane"):
      if n.attr("data-ct-pane") == "state":
        texts(n, stateTexts)
    ck stateTexts.len > 0
    ck "State" notin stateTexts

  test "a lone editor's tab is its file; an Edit window's marks it dirty":
    proc editorLabel(geom: JsonNode): string =
      for n in geom["nodes"]:
        if n{"kind"}.getStr == "tabs" and
           n["panes"].to(seq[string]) == @["editor"]:
          return n["labels"][0].getStr
      "(no lone editor)"
    proc stripLabel(plan: JsonNode; label: string): bool =
      for s in plan.nodesWith("data-ct-tabs"):
        if s.attr("data-ct-tabs") == label:
          return s{"children"}.len == 1 and
                 s{"children"}[0].textOf == label
      false
    # Debug: the recording's file.
    var geom: JsonNode
    let plan = windowPlan("", geom)
    ck geom.editorLabel == "main.py"
    ck plan.stripLabel("main.py")
    # Edit: a project's file; a typed key makes it dirty; Ctrl+S saves it.
    let project = createTempDir("plat49-gpui-edit-", "")
    writeFile(project / "main.py", "print(1)\n")
    var g2: JsonNode
    let clean = windowPlan("", g2, @["--edit"], project)
    ck g2.editorLabel == "main.py"
    ck clean.stripLabel("main.py")
    var g3: JsonNode
    let typed = windowPlan("key:x", g3, @["--edit"], project)
    ck g3.editorLabel == "main.py ●"
    ck typed.stripLabel("main.py ●")
    ck editorTabLabel("main.py", true) == "main.py ●"
    var g4: JsonNode
    discard windowPlan("key:x,key:s:control", g4, @["--edit"], project)
    ck g4.editorLabel == "main.py"
    removeDir(project)

  test "strips on their own ground; the selected tab its own background and foreground":
    let plan = windowPlan("")
    let stripBg = chromeOf(crTabStripBackground)
    ck stripBg != chromeOf(crPaneBackground)
    ck chromeOf(crTabActiveBackground) != stripBg
    for s in plan.nodesWith("data-ct-tabs"):
      ck s.style("bg") == stripBg
      var active = 0
      for t in s{"children"}.getElems:
        if t.attr("data-ct-tab-active") == "true":
          inc active
          ck t.style("bg") == chromeOf(crTabActiveBackground)
          ck t.style("text_color") == chromeOf(crTabActiveForeground)
          ck t.style("font_weight") == "bold"
        else:
          ck t.style("bg") == ""
          ck t.style("text_color") == chromeOf(crTabInactiveForeground)
      ck active == 1

  test "a press on a tab is a click until it moves; past the slop it is a drag":
    var geom: JsonNode
    discard windowPlan("", geom)
    var vcs = newJNull()
    for n in geom["nodes"]:
      if n{"kind"}.getStr == "tabs" and "vcs" in n["panes"].to(seq[string]):
        let i = n["panes"].to(seq[string]).find("vcs")
        vcs = n["tabs"][i]
    ck vcs.kind == JArray
    let (x, y) = centre(vcs)
    # Moved 2 px (under `ClickSlopPx`) and released: the tab is activated.
    let click = windowPlan("press:" & $x & ":" & $y & ",move:" & $(x + 2) &
                           ":" & $y & ",release:" & $(x + 2) & ":" & $y)
    var vcsActive = false
    for s in click.nodesWith("data-ct-tabs"):
      if "VCS" in s.attr("data-ct-tabs").split(','):
        for t in s{"children"}.getElems:
          if t.textOf == "VCS": vcsActive = t.attr("data-ct-tab-active") == "true"
    ck vcsActive
    ck click.nodesWith("data-ct-drop").len == 0
    ck click.nodesWith("data-ct-drag-ghost").len == 0
    # Held and moved across the window: a drag, with its tint and its ghost.
    let held = windowPlan("press:" & $x & ":" & $y & ",move:" & $(x + 60) &
                          ":" & $(y + 200) & ",move:900:500")
    ck held.nodesWith("data-ct-drag-ghost").len == 1
    ck held.nodesWith("data-ct-drop").len == 1

  test "the pointer over a control: the ViewModel's tooltip":
    let bindings = desktopBindings()
    for id in ["next", "continue", "reverse-step-out"]:
      let plan = windowPlan("control:" & id)
      let labels = plan.nodesWith("data-ct-hover-label")
      ck labels.len == 1
      let c = TransportControls[controlIndex(id)]
      let want = transportTooltip(id, bindings.getOrDefault(c.clientAction))
      ck labels[0].attr("data-ct-hover-label") == want
      ck labels[0].textOf == want
      ck want.startsWith(transportLabel(id))

  test "the omnibar: the ViewModel's placeholder; the query with its caret":
    let closed = windowPlan("")
    let field = closed.nodesWith("data-ct-omnibar")
    ck field.len == 1
    ck field[0].textOf == "⌕ " & OmnibarPlaceholder
    ck field[0].style("bg") == chromeOf(crInputBackground)
    ck field[0].attr("data-ct-omnibar-placeholder") == "true"
    let typed = windowPlan("key:p:control,key:a,key:b,key:left")
    ck typed.nodesWith("data-ct-omnibar")[0].textOf == "⌕ a▏b"
    let over = windowPlan("key:p:control,key:a,key:b,key:left,key:insert")
    ck over.nodesWith("data-ct-omnibar")[0].textOf == "⌕ a█b"
    let replaced = windowPlan("key:p:control,key:a,key:b,key:left," &
                              "key:insert,key:c")
    ck replaced.nodesWith("data-ct-omnibar")[0].textOf == "⌕ ac█"

suite "PLAT-49 GPUI plan: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
