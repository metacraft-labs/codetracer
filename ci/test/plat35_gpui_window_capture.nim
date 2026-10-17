## PLAT-35 — the GPUI arm of the parity capture, as a REAL WINDOW.
##
## The off-screen capture (`ci/test/plat35-gpui-capture.sh`) needs GPUI's
## headless renderer, which exists only on macOS (`gpui-pre-platform`'s
## `current_headless_renderer()` is `None` elsewhere, measured 2026-10-17:
## every Linux frame refused with `pcsRendererUnavailable`). On Linux the GPUI
## arm is therefore what a user sees: the windowed front-end on a compositor —
## GuiAssert's headless sway target — at each scenario's declared viewport,
## read back with the compositor's own capture.
##
## For each scenario in `src/tests/visual/scenarios.json`: launch
## `codetracer-gpui-window --width=W --height=H --replay-ops=<ops> <trace>`
## (the operations are applied before the first frame, so the window's first
## settled frame is the scenario's state), wait until the compositor reports
## the window at exactly W x H and its pixels have settled, and write
## `<out>/<view>.ppm`. The window floats (so sway does not tile it to the
## output) under server-side decorations with no border, so its frame IS the
## content area — the same extent as the Electron arm's CSS viewport.
##
## Environment (set by `ci/test/plat35-gpui-window-capture.sh`):
##   PLAT35_GPUI_BIN, PLAT35_GPUI_LD_LIBRARY_PATH, PLAT35_TRACE,
##   REPLAY_SERVER_BIN, PLAT35_REPO, PLAT35_OUT, PLAT35_ONLY (a view, optional)
##
## A scenario that produces no settled frame at its declared size fails the run
## by name; nothing is skipped.

import std/[json, os, osproc, strutils, times]
import gui_assert/desktop_env
import gui_assert/desktop_env/sway

const AppId = "codetracer"

proc need(name: string): string =
  result = getEnv(name)
  if result.len == 0: quit("plat35_gpui_window_capture: " & name & " is not set", 2)

let bin = need("PLAT35_GPUI_BIN")
let libs = need("PLAT35_GPUI_LD_LIBRARY_PATH")
let trace = need("PLAT35_TRACE")
let replayServer = need("REPLAY_SERVER_BIN")
let repo = need("PLAT35_REPO")
let outDir = need("PLAT35_OUT")
let only = getEnv("PLAT35_ONLY")

proc opsSpec(ops: JsonNode): string =
  ## The scenario's operations in `--replay-ops` syntax (`stepIn=5,next=3`,
  ## `setBreakpoint@<line>`), as the window lane spells them.
  var parts: seq[string]
  for op in ops:
    let kind = op["kind"].getStr
    if kind == "setBreakpoint":
      parts.add "setBreakpoint@" & $op["line"].getInt
    else:
      parts.add kind & "=" & $op{"times"}.getInt(1)
  parts.join(",")

proc writePpm(img: RgbImage; path: string) =
  var s = "P6\n" & $img.width & " " & $img.height & "\n255\n"
  s.setLen(s.len + img.data.len)
  let off = s.len - img.data.len
  for i, b in img.data: s[off + i] = char(b)
  writeFile(path, s)

let definition = parseJson(readFile(repo / "src" / "tests" / "visual" / "scenarios.json"))
createDir(outDir)
let t = newSwayTarget(2560, 1440, floatingAppIds = @[AppId])
t.start()
var failed: seq[string]
try:
  for sc in definition["scenarios"]:
    let id = sc["id"].getStr
    let view = sc["view"].getStr
    if only.len > 0 and view != only: continue
    let vp = definition["viewports"][sc["viewport"].getStr]
    let (w, h) = (vp["width"].getInt, vp["height"].getInt)
    let ops = opsSpec(sc["operations"])
    echo "=== ", id, " -> ", view, " at ", w, "x", h, " [", (if ops.len > 0: ops else: "no operations"), "]"
    var argv = @[bin, "--quit-after-ms=600000", "--width=" & $w, "--height=" & $h]
    if ops.len > 0: argv.add "--replay-ops=" & ops
    argv.add trace
    let home = outDir / ("home-" & view)
    removeDir(home)
    createDir(home / "config")
    let p = t.spawn(@["/bin/sh", "-c", "exec \"$0\" \"$@\" >" &
                      quoteShell(outDir / (view & ".run.log")) & " 2>&1"] & argv,
      extraEnv = [("LD_LIBRARY_PATH", libs), ("REPLAY_SERVER_BIN", replayServer),
                  ("CODETRACER_HOME", home), ("XDG_STATE_HOME", home / "state"),
                  ("XDG_CONFIG_HOME", home / "config")])
    try:
      let win = t.waitWindow(AppId, timeout = initDuration(seconds = 180),
        until = proc(x: EnvWindow): bool = x.rect.w == w and x.rect.h == h)
      t.placeWindow(win, 0, 0)
      t.waitUntil("the window at 0,0", proc(): bool =
        let r = t.window(AppId).rect
        r.x == 0 and r.y == 0)
      let img = t.captureSettled(t.window(AppId).rect, agree = 4,
                                 intervalMs = 500, timeout = initDuration(seconds = 120))
      img.writePpm(outDir / (view & ".ppm"))
      echo "  captured ", outDir / (view & ".ppm")
    except EnvError as e:
      echo "  FAILED: ", e.msg
      failed.add view
    p.terminate()
    discard p.waitForExit(10000)
finally:
  t.stop()
if failed.len > 0:
  quit("plat35_gpui_window_capture: no frame for " & failed.join(", "), 1)
