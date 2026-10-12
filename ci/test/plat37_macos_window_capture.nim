## plat37_macos_window_capture.nim — attest a real `codetracer-gpui` window on
## macOS and capture **its own surface**.
##
## ## Why this file exists at all
##
## `ci/test/plat37-window-frame.sh` is PLAT-37's windowed lane and it reads its
## frames with `grim`, a `zwlr_screencopy_manager_v1` client, under a nested
## headless `sway`. None of `sway`, `grim`, `wayland-info`, `wtype` or
## `tesseract` exists on aarch64-darwin, which is what
## `codetracer-specs/issues/2026-09-29-gpui-window-capture-lanes-are-wayland-only.md`
## records. PLAT-35's answer was the OTHER pixel path —
## `gpui_render_to_pixels` off screen — and that path says `satisfiesG1: false`
## in every record it writes, correctly: PLAT-23's G1 asks that *a window has
## been observed*, and an off-screen RGBA buffer is not one.
##
## PLAT-37's own note is `"G1 ON macOS: A WINDOW IS OBSERVED; ITS PIXELS ARE
## NOT."` This module closes the second half of that sentence, and it is the
## first thing in this tree entitled to write `satisfiesG1: true`.
##
## ## What makes the record an attestation rather than a claim
##
## Three independent statements, all taken BEFORE the image is written and all
## carried into the census whether the capture then succeeds or fails:
##
##   1. **`CGWindowListCopyWindowInfo` saw the window.** Unprivileged — it
##      needs no TCC grant — so a zero here means there is no GUI session or no
##      window, never "I was not allowed to look". The window's id, owner pid,
##      frame in POINTS, layer and on-screen flag are all recorded.
##   2. **The capture was taken through `SCContentFilter(desktopIndependent
##      Window:)`**, which is the window's own surface. A crop of a display
##      still to the same rectangle would capture whatever is stacked on top,
##      and nothing in the resulting image distinguishes the two.
##   3. **The helper reports the same window id back**, out of
##      `SCShareableContent.windows`. So the surface that was captured and the
##      window that was attested are the same object, said by two different
##      APIs.
##
## ## Points, pixels, and why both are written
##
## Measured on this host (aarch64-darwin, macOS 26.5.2 build 25F84,
## 2026-10-12): the single display is **1728x1117 POINTS** and
## `pointPixelScale` is **2.000**, so a 1440-point-wide window is captured as a
## **2880-pixel-wide** PNG.
##
## `src/tests/visual/scenarios.json`'s viewports are in POINTS — that is what
## both `codetracer-gpui --width/--height` and Playwright's `viewport` mean —
## and Playwright sets **no `deviceScaleFactor` anywhere** in this tree, so the
## Electron reference lands at 1x and its pixel extent equals its point extent.
## A parity comparison that read this lane's PNG dimensions as if they were an
## Electron capture's would see a factor of two and call it a defect.
##
## So every record carries `requestedPoints`, `windowFramePoints`,
## `pointPixelScale`, `capturedPixels` AND the derived `capturedPoints`, plus
## `logicalPixelsEqualDevicePixels: false`. Nothing downstream has to infer the
## scale, and a reader that ignores it is contradicting a field rather than
## missing one.
##
## ## The viewport that cannot be honoured, recorded rather than hidden
##
## A window cannot be wider than the display. `scenarios.json`'s `wide`
## viewport is 1920x1080 and the display is 1728x1117 points, so macOS clamps
## it — measured, not assumed: `--width=1920 --height=1080` produced a window
## frame of **1728x1084** points. `laptop` (1440x900) is honoured exactly: a
## frame of **1440x929**, the 29 extra points being the title bar.
##
## `viewportHonoured` is therefore computed from the window the system actually
## made, not from the flag that asked for it, and a clamped run is `false` with
## the deviation spelled out. Labelling a 1728-point window `1920` is the
## defect class this campaign exists to catch.

when defined(js):
  {.error: "plat37_macos_window_capture is native-only.".}

import std/[json, os, osproc, streams, strutils, times]

import gui_assert/screen_capture
import gui_assert/window_layout

const
  TitleBarPoints* = 29
    ## How many POINTS a standard titled window's frame is taller than the
    ## content area `--width`/`--height` asked for.
    ##
    ## **IT IS SUBTRACTED, NOT TOLERATED, AND THAT IS THE WHOLE POINT.** The
    ## first spelling of the comparison below tested the frame height with
    ## `>=`, reasoning that an equality test would call every honoured
    ## viewport a deviation because the frame carries a title bar the content
    ## area does not. The reasoning is right and the remedy was not: `>=` is a
    ## one-sided test, and on this host it reported the `wide` scenario's
    ## height as HONOURED with a deviation of `+4` when that window's content
    ## area is 25 points SHORT of the 1080 it asked for. Measured 2026-10-12:
    ## the display is 1728x1117 points, the window sits at `y = 33` with a
    ## frame height of 1084, and `33 + 1084 = 1117` — its bottom is flush with
    ## the display's. It was clamped in BOTH dimensions and the height test
    ## could not see it. Relabelling a short window as honoured is the same
    ## defect class as relabelling a 1728-point window `1920`.
    ##
    ## WHERE THE 29 COMES FROM, and why using it here is not circular. It is
    ## measured on the `laptop` scenario, whose window was demonstrably NOT
    ## clamped in height: asked for 1440x900, the frame is 1440x929 and its
    ## bottom (109 + 929 = 1038) is 79 points clear of the display's. The
    ## constant is taken from that window and applied to a DIFFERENT one,
    ## which is ordinary use of a measurement; it would only be circular if it
    ## were re-derived per window from the comparison it is used to decide.
    ##
    ## A host or an OS whose title bar is a different height will make every
    ## viewport report as deviating. That is the correct failure: it is loud,
    ## the record carries `titleBarPoints` and the raw frame beside it, and a
    ## reader can see in one line which of the two numbers moved.

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

type
  Mode = enum
    mHost      ## probe the host and write its record; capture nothing
    mCapture   ## attest + place + capture one scenario

  Config = object
    mode: Mode
    owner: string
    outPath: string
    recordPath: string
    view, scenario: string
    requestedWidth, requestedHeight: int
    place: bool
    placeX, placeY: int
    timeoutMs: int
    waitMs: int
    settleMs: int

const Usage = """
plat37_macos_window_capture — PLAT-37's macOS window capture

  plat37_macos_window_capture host --record=<json>
  plat37_macos_window_capture capture --out=<png> --record=<json> \
      --view=<name> --scenario=<id> \
      --requested-width=<points> --requested-height=<points> \
      [--owner=<name>] [--place] [--place-x=<p>] [--place-y=<p>] \
      [--timeout-ms=<n>] [--wait-ms=<n>]

`--wait-ms` is how long to WAIT for the window to appear (default 90000, 0
polls once). It is not a settle delay: `--replay-ops` runs BEFORE the window
is drawn, so a 21-step scenario opens its window tens of seconds after the
process starts, and a fixed sleep either wastes that time on every short
scenario or misses the window on every long one. MEASURED 2026-10-12: with a
6-second fixed settle, the three `stepIn` scenarios found NO WINDOW and the
three without one all captured.

Every extent on this command line is in POINTS. The PNG is in DEVICE PIXELS
and the record carries the scale that relates them.
"""

proc parseConfig(args: seq[string]): Config =
  result = Config(mode: mCapture, owner: "codetracer-gpui",
                  requestedWidth: 0, requestedHeight: 0,
                  placeX: 0, placeY: 0, timeoutMs: 30_000,
                  waitMs: 90_000, settleMs: 2_000)
  if args.len == 0:
    quit(Usage, 2)
  case args[0]
  of "host": result.mode = mHost
  of "capture": result.mode = mCapture
  else: quit("unknown mode '" & args[0] & "'\n" & Usage, 2)
  for arg in args[1 .. ^1]:
    if arg.startsWith("--owner="): result.owner = arg["--owner=".len .. ^1]
    elif arg.startsWith("--out="): result.outPath = arg["--out=".len .. ^1]
    elif arg.startsWith("--record="):
      result.recordPath = arg["--record=".len .. ^1]
    elif arg.startsWith("--view="): result.view = arg["--view=".len .. ^1]
    elif arg.startsWith("--scenario="):
      result.scenario = arg["--scenario=".len .. ^1]
    elif arg.startsWith("--requested-width="):
      result.requestedWidth = parseInt(arg["--requested-width=".len .. ^1])
    elif arg.startsWith("--requested-height="):
      result.requestedHeight = parseInt(arg["--requested-height=".len .. ^1])
    elif arg == "--place": result.place = true
    elif arg.startsWith("--place-x="):
      result.placeX = parseInt(arg["--place-x=".len .. ^1])
    elif arg.startsWith("--place-y="):
      result.placeY = parseInt(arg["--place-y=".len .. ^1])
    elif arg.startsWith("--timeout-ms="):
      result.timeoutMs = parseInt(arg["--timeout-ms=".len .. ^1])
    elif arg.startsWith("--wait-ms="):
      result.waitMs = parseInt(arg["--wait-ms=".len .. ^1])
    elif arg.startsWith("--settle-ms="):
      result.settleMs = parseInt(arg["--settle-ms=".len .. ^1])
    else: quit("unknown argument '" & arg & "'\n" & Usage, 2)
  if result.recordPath.len == 0:
    quit("--record is required: the record is this program's answer", 2)
  if result.mode == mCapture:
    if result.outPath.len == 0: quit("--out is required for capture", 2)
    if result.view.len == 0 or result.scenario.len == 0:
      quit("--view and --scenario are required for capture", 2)
    if result.requestedWidth <= 0 or result.requestedHeight <= 0:
      quit("--requested-width / --requested-height are required for capture", 2)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc toolVersion(argv: seq[string]): string =
  ## First line of a tool's own version output, or why it could not be asked.
  ## Recorded rather than quoted from a document: an OCR or SSIM figure is only
  ## meaningful beside the binary that produced it.
  ## `startProcess` with a real argv and `poUsePath`, NOT `execCmdEx` over a
  ## joined string. `findExe("uname")` on this host resolves through the
  ## symlink to coreutils' MULTI-CALL binary, which then reads `-srm` as its
  ## own option and answers `invalid option -- 's'`. The argv form keeps
  ## argv[0] as the name the multi-call binary dispatches on.
  try:
    let p = startProcess(command = argv[0], args = argv[1 .. ^1],
                         options = {poStdErrToStdOut, poUsePath})
    let output = p.outputStream().readAll()
    let code = p.waitForExit()
    p.close()
    let lines = output.strip.splitLines
    if lines.len == 0: return "<no output, rc " & $code & ">"
    return lines[0]
  except CatchableError as e:
    return "<unavailable: " & e.msg.splitLines()[0] & ">"

proc windowJson(w: WindowInfo): JsonNode =
  ## One attested window. **`title` IS DELIBERATELY NOT HERE** — see the note
  ## on `writeRecord` below.
  %*{
    "windowId": w.windowId,
    "ownerPid": w.ownerPid,
    "ownerName": w.ownerName,
    "boundsPoints": {"x": w.bounds[0], "y": w.bounds[1],
                     "w": w.bounds[2], "h": w.bounds[3]},
    "layer": w.layer,
    "onScreen": w.onScreen,
    "hasTitle": w.title.len > 0,
  }

proc hostRecord(): JsonNode =
  ## The host, named as PLAT-23's G1 requires: *"at least one codetracer-gpui
  ## window opened on some host … The host is named."*
  result = %*{
    "uname": toolVersion(@["uname", "-srm"]),
    "productVersion": toolVersion(@["sw_vers", "-productVersion"]),
    "buildVersion": toolVersion(@["sw_vers", "-buildVersion"]),
    "swiftc": toolVersion(@["swiftc", "--version"]),
    "ffmpeg": toolVersion(@["ffmpeg", "-version"]),
    # NAMED BECAUSE IT IS ABSENT FROM THIS ENVIRONMENT. Every other `plat3x`
    # lane's host block records a tesseract version. There is none on the
    # ambient PATH and codetracer's own flake declares none, which is half of
    # why those lanes cannot run here and why this one reads with Apple
    # Vision. GuiAssert's OWN dev shell does carry tesseract 5.5.1; this lane
    # does not run in it, and the field records what THIS process can reach.
    "tesseract": toolVersion(@["tesseract", "--version"]),
    "compositor": "quartz (no sway, no grim, no wayland)",
  }

# ---------------------------------------------------------------------------
# Writing the record
# ---------------------------------------------------------------------------

proc writeRecord(path: string, node: JsonNode) =
  ## **NO WINDOW TITLE REACHES THIS FILE.** `kCGWindowName` is redacted by
  ## macOS until the calling code holds the ScreenCapture grant — and this
  ## bundle holds it, so every title on the desktop is readable here. A lane
  ## that logged them would put *other applications'* window titles into a
  ## record under `build/`, and a title is often the most sensitive string a
  ## machine has on it. `hasTitle` is the only thing the record says about
  ## them, because it is the only thing the lane needs: a `codetracer-gpui`
  ## window is selected by OWNER.
  let dir = path.parentDir
  if dir.len > 0: createDir(dir)
  writeFile(path, node.pretty & "\n")

proc fail(cfg: Config, node: JsonNode, why: string, code: int) =
  node["outcome"] = %"refused"
  node["refusal"] = %why
  writeRecord(cfg.recordPath, node)
  stderr.writeLine("plat37-macos-window-capture: " & why)
  stderr.writeLine("plat37-macos-window-capture: the record is at " &
                   cfg.recordPath)
  quit(code)

# ---------------------------------------------------------------------------
# host mode
# ---------------------------------------------------------------------------

proc runHost(cfg: Config) =
  var node = %*{
    "probe": "plat37-macos-window-capture/host",
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "host": hostRecord(),
  }
  if not stillCaptureProbablyAvailable():
    fail(cfg, node, "this host cannot provide still capture at all " &
         "(not macOS, or no swiftc, or no helper source)", 3)
  var app: string
  try:
    app = ensureCaptureApp()
  except CatchableError as e:
    fail(cfg, node, "the capture bundle could not be built or re-signed: " &
         e.msg.splitLines()[0], 3)
  node["captureApp"] = %app
  node["captureBundleId"] = %captureBundleId()
  # THE REQUIREMENT IS SUMMARISED, NOT QUOTED. A certificate-signed bundle's
  # designated requirement embeds the signing identity's common name — a
  # person's legal name and their Apple team id. That is the operator's, not
  # the product's, and it has no business in a build artefact. What the record
  # needs is whether the grant is pinned to an IDENTITY (survives a rebuild)
  # or to a cdhash (dies on the next one), and that is a predicate.
  let dr = designatedRequirement(app)
  node["designatedRequirement"] = %*{
    "bindsBundleIdentifier": "identifier \"" & captureBundleId() & "\"" in dr,
    "bindsSigningIdentity": "certificate leaf[subject.CN]" in dr,
    "bindsCodeBytesOnly": "cdhash" in dr and
                          "certificate leaf[subject.CN]" notin dr,
    "why": "a cdhash-only requirement means the grant dies on the next " &
           "rebuild; an identity-bound one survives it. The requirement " &
           "itself is NOT recorded: it carries the signer's legal name.",
  }

  let pf = screenCapturePreflight()
  node["preflight"] = %*{
    "status": $pf.status,
    "granted": pf.status == csOk,
    "message": pf.message,
    "windowsSeen": pf.windowsSeen,
    "titlesVisible": pf.titlesVisible,
  }
  if pf.status != csOk:
    # A REFUSAL, NEVER A SKIP. The remedy travels with the failure.
    fail(cfg, node, "the capture bundle holds no ScreenCapture grant.\n" &
         grantInstructions(app), 4)

  # The display, measured rather than read off a document. This is what makes
  # `viewportHonoured` falsifiable: a viewport wider than this cannot be had.
  let probe = getTempDir() / "plat37-macos-display-probe.png"
  try:
    let rep = captureDisplayStill(probe, timeoutMs = cfg.timeoutMs)
    var points = ""
    for line in rep.raw.splitLines:
      if line.startsWith("display_points="):
        points = line["display_points=".len .. ^1]
    node["display"] = %*{
      "pointsText": points,
      "capturedPixels": {"width": rep.width, "height": rep.height},
      "pointPixelScale": rep.scale,
      "note": "the still itself is a positive control: a host that cannot " &
              "capture a display cannot capture a window either, and this " &
              "distinguishes the two failures before any scenario runs",
    }
    if points.len > 0:
      let parts = points.split('x')
      if parts.len == 2:
        node["display"]["widthPoints"] = %parseInt(parts[0])
        node["display"]["heightPoints"] = %parseInt(parts[1])
  except CatchableError as e:
    fail(cfg, node, "the display positive control failed, so no window " &
         "capture below it could be believed: " & e.msg.splitLines()[0], 5)
  finally:
    removeFile(probe)

  node["outcome"] = %"ok"
  writeRecord(cfg.recordPath, node)
  echo "host: ", node["host"]["uname"].getStr
  echo "  bundle:  ", app
  echo "  display: ", node["display"]["pointsText"].getStr, " points, scale ",
       node["display"]["pointPixelScale"].getFloat

# ---------------------------------------------------------------------------
# capture mode
# ---------------------------------------------------------------------------

proc runCapture(cfg: Config) =
  let q = initWindowQuery(owner = cfg.owner)
  var node = %*{
    "probe": "SCScreenshotManager/SCContentFilter(desktopIndependentWindow:)",
    "subject": cfg.owner,
    "view": cfg.view,
    "scenario": cfg.scenario,
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    # EVERY EXTENT ON THE COMMAND LINE IS IN POINTS, and is labelled so.
    "requestedPoints": {"width": cfg.requestedWidth,
                        "height": cfg.requestedHeight},
    "host": hostRecord(),
  }

  # --- 1. ATTEST, before anything is captured ------------------------------
  #
  # POLLED, NOT SLEPT. `--replay-ops` is applied before the window is drawn,
  # so the time between `codetracer-gpui` starting and its window existing is
  # a function of the SCENARIO. A fixed settle is wrong in both directions,
  # and the first run of this lane proved it: at 6 seconds, `stepped-editor`
  # (stepIn=5), `advanced-state` (stepIn=5,next=3), `returned-calltrace`
  # (stepIn=21,stepOut=1) and `breakpoint-editor` all reported NO WINDOW,
  # while the three scenarios that step nothing all captured. That is a
  # measurement of the harness, not of the front-end, and reporting it as a
  # capture failure would have been a defect in the instrument.
  #
  # The poll is the unprivileged `CGWindowListCopyWindowInfo` read, so waiting
  # costs nothing but time and cannot itself be refused.
  var before: seq[WindowInfo]
  let deadline = epochTime() + float(cfg.waitMs) / 1000.0
  var polls = 0
  while true:
    inc polls
    try:
      before = listWindows(q, viaApp = true, timeoutMs = cfg.timeoutMs)
    except CatchableError as e:
      fail(cfg, node, "the window list could not be read: " &
           e.msg.splitLines()[0], 5)
    if before.len > 0 or epochTime() >= deadline: break
    sleep(500)
  node["windowWait"] = %*{
    "polls": polls,
    "waitMsAllowed": cfg.waitMs,
    "how": "CGWindowListCopyWindowInfo, polled until the window appeared. " &
           "--replay-ops runs before the window is drawn, so this interval " &
           "is a property of the scenario, not a settle constant.",
  }
  node["attestation"] = %*{
    "how": "CGWindowListCopyWindowInfo, read by the capture bundle before " &
           "any pixel was taken. Unprivileged: a zero here is a dead GUI " &
           "session or no window, never a TCC denial.",
    "matched": before.len,
    "windows": newJArray(),
  }
  for w in before: node["attestation"]["windows"].add windowJson(w)
  # A WINDOW THAT EXISTS HAS NOT NECESSARILY PAINTED. The window server
  # publishes the window to `CGWindowListCopyWindowInfo` when it is created;
  # the first frame lands later. `--settle-ms` is the ONLY fixed delay in this
  # program and it is bounded by what it is for — one paint — rather than by
  # how long a scenario takes, which the poll above already absorbs.
  if before.len > 0 and cfg.settleMs > 0:
    sleep(cfg.settleMs)
    node["windowWait"]["settleMs"] = %cfg.settleMs
  if before.len == 0:
    fail(cfg, node, "no window whose owner is '" & cfg.owner &
         "' is in CGWindowListCopyWindowInfo. The front-end did not open " &
         "one, or it had already closed by the time this ran.", 6)

  # --- 2. PLACE, through GuiAssert's own mechanism --------------------------
  #
  # RECORDED AND NEVER FATAL. `buildSetBoundsScript` emits
  # `tell application "<name>" to set bounds of front window to {...}`, which
  # needs the target to answer AppleScript. `codetracer-gpui` is a bare
  # executable with no bundle and no scripting dictionary, and the System
  # Events route around that needs `kTCCServiceAccessibility`, which no
  # subject on this host holds. So the authoritative sizing mechanism is the
  # front-end's OWN `--width`/`--height`, which `gpui_launch` passes to the
  # platform window; this is the belt. What matters is that the record says
  # which one actually moved the window, and the re-attestation below is what
  # says it.
  if cfg.place:
    let script = buildSetBoundsScript(cfg.owner, cfg.placeX, cfg.placeY,
                                      cfg.requestedWidth, cfg.requestedHeight)
    var placed = %*{"attempted": true, "script": script}
    try:
      # `buildOsascriptArgv` is GuiAssert's own wire format, handed to
      # `startProcess` as a real argv: no shell, so a script carrying a quote
      # cannot be reinterpreted on the way.
      let bin = findExe("osascript")
      if bin.len == 0:
        raise newException(OSError, "osascript is not on PATH")
      let proc0 = startProcess(command = bin,
                               args = buildOsascriptArgv(script),
                               options = {poStdErrToStdOut})
      let output = proc0.outputStream().readAll()
      let code = proc0.waitForExit()
      proc0.close()
      placed["exitCode"] = %code
      placed["output"] = %output.strip.splitLines.join(" | ")
      placed["succeeded"] = %(code == 0)
    except CatchableError as e:
      placed["succeeded"] = %false
      placed["output"] = %e.msg.splitLines()[0]
    node["placement"] = placed
  else:
    node["placement"] = %*{
      "attempted": false,
      "why": "the window is sized by `codetracer-gpui --width/--height`, " &
             "which gpui_launch hands to the platform window. Pass --place " &
             "to also drive GuiAssert's buildSetBoundsScript.",
    }

  # --- 3. RE-ATTEST, so the record names the window as it was CAPTURED -----
  var target: WindowInfo
  var after: seq[WindowInfo]
  try:
    after = listWindows(q, viaApp = true, timeoutMs = cfg.timeoutMs)
  except CatchableError as e:
    fail(cfg, node, "the window list could not be re-read: " &
         e.msg.splitLines()[0], 5)
  if after.len == 0:
    fail(cfg, node, "the window vanished between attestation and capture", 6)
  # Largest area wins, exactly as the helper's own chooser does, so the window
  # this record describes is the window the helper will capture.
  target = after[0]
  for w in after:
    if w.bounds[2] * w.bounds[3] > target.bounds[2] * target.bounds[3]:
      target = w
  node["attestationAfterPlacement"] = %*{
    "matched": after.len,
    "windows": newJArray(),
    "chosen": windowJson(target),
    "chosenBy": "largest area, which is the helper's own rule, so the " &
                "window described here is the window captured below",
  }
  for w in after: node["attestationAfterPlacement"]["windows"].add windowJson(w)
  if after.len > 1:
    node["ambiguousTarget"] = %true

  # --- 4. CAPTURE the window's OWN surface ---------------------------------
  var rep: StillCaptureReport
  try:
    rep = captureWindowStill(cfg.outPath, initWindowQuery(
      windowId = target.windowId), timeoutMs = cfg.timeoutMs)
  except StillCaptureDenied as e:
    node["capture"] = %*{"status": $e.report.status,
                         "message": e.report.message}
    fail(cfg, node, "the capture bundle was refused by TCC mid-run, " &
         "although preflight passed: " & e.report.message, 4)
  except StillCaptureError as e:
    node["capture"] = %*{"status": $e.report.status,
                         "message": e.report.message,
                         "windowsSeen": e.report.windowsSeen}
    fail(cfg, node, "the capture failed: " & e.report.message, 7)
  except CatchableError as e:
    fail(cfg, node, "the capture failed: " & e.msg.splitLines()[0], 7)

  # --- 5. THE CENSUS -------------------------------------------------------
  let scale = rep.scale
  let capturedPointsW =
    if scale > 0.0: int(float(rep.width) / scale) else: 0
  let capturedPointsH =
    if scale > 0.0: int(float(rep.height) / scale) else: 0
  node["capture"] = %*{
    "status": $rep.status,
    "windowId": rep.windowId,
    "sameWindowAsAttested": rep.windowId == target.windowId,
    "candidates": rep.candidates,
    "outPath": cfg.outPath,
    "pngBytes": (if fileExists(cfg.outPath): getFileSize(cfg.outPath) else: 0),
  }
  node["windowFramePoints"] = %*{
    "x": target.bounds[0], "y": target.bounds[1],
    "width": target.bounds[2], "height": target.bounds[3],
  }
  node["capturedPixels"] = %*{"width": rep.width, "height": rep.height}
  node["pointPixelScale"] = %scale
  node["capturedPoints"] = %*{"width": capturedPointsW,
                              "height": capturedPointsH}
  node["logicalPixelsEqualDevicePixels"] = %(scale == 1.0)
  node["pixelNote"] =
    %("`capturedPixels` is DEVICE pixels; every other extent in this record " &
      "is LOGICAL POINTS. They differ by `pointPixelScale` here and by " &
      "nothing at all in an Electron Playwright capture, which sets no " &
      "deviceScaleFactor: compare in POINTS or a 2x difference reads as a " &
      "parity defect.")

  # THE VIEWPORT, GRADED AGAINST THE WINDOW THE SYSTEM MADE rather than
  # against the flag that asked for it. A clamped window is `false` here with
  # its deviation spelled out, and is never relabelled with the figure it
  # could not reach.
  let contentHeight = target.bounds[3] - TitleBarPoints
  let honouredW = target.bounds[2] == cfg.requestedWidth
  let honouredH = contentHeight == cfg.requestedHeight
  node["titleBarPoints"] = %TitleBarPoints
  node["windowContentHeightPoints"] = %contentHeight
  node["viewportHonoured"] = %(honouredW and honouredH)
  node["viewportDeviationPoints"] = %*{
    "width": target.bounds[2] - cfg.requestedWidth,
    "height": contentHeight - cfg.requestedHeight,
  }
  node["viewportNote"] =
    %("BOTH dimensions are compared with equality, and the height is " &
      "compared in the CONTENT area rather than in the frame: a macOS " &
      "window frame includes its title bar, so the 900 points asked for " &
      "arrive as a 929-point frame and `windowFramePoints.height` minus " &
      "`titleBarPoints` is what the request was about. The deviation " &
      "reported here is therefore the CONTENT deviation — negative when the " &
      "display clamped the window short, which a one-sided `>=` on the " &
      "frame height could not see and did report as a surplus. A window " &
      "NARROWER or SHORTER than the request is the display clamping it, " &
      "which no flag can undo; it is recorded and never relabelled.")

  # THE THIRD STATEMENT IS ENFORCED, NOT MERELY RECORDED. `whyG1` asserts
  # that ScreenCaptureKit reported the same window id back; before this, the
  # claim was written unconditionally while `sameWindowAsAttested` could say
  # otherwise two keys above it. A record that contradicts itself is worse
  # than one that refuses: the lane's census does check the flag, but a
  # record has to be readable on its own.
  node["satisfiesG1"] = %(rep.windowId == target.windowId)
  if rep.windowId != target.windowId:
    node["whyG1"] =
      %("NOT CLAIMED. CGWindowListCopyWindowInfo attested window " &
        $target.windowId & " and ScreenCaptureKit captured window " &
        $rep.windowId & ". The two are different objects, so nothing here " &
        "says which window these pixels are of.")
  else:
   node["whyG1"] =
    %("PLAT-23's G1 asks that a window has been observed. One was: " &
      "CGWindowListCopyWindowInfo reported window " & $target.windowId &
      " owned by " & target.ownerName & " at " & $target.bounds[2] & "x" &
      $target.bounds[3] & " points before any pixel was read, the capture " &
      "went through SCContentFilter(desktopIndependentWindow:) over that " &
      "window's OWN surface rather than a crop of the display, and " &
      "ScreenCaptureKit reported the same window id back. The host is " &
      "named in `host`.")
  node["standing"] =
    %("HOST-CONDITIONAL EVIDENCE, NEVER A REQUIRED GATE. This lane needs a " &
      "live macOS GUI session and a kTCCServiceScreenCapture grant held by " &
      "com.metacraft-labs.guiassert.capture. Neither exists on a fresh " &
      "host or in CI, which is the non-reproducibility the owning issue " &
      "warns about, and PLAT-23's G5 — `a gate cannot be passed by a " &
      "measurement that could not have failed` — cuts the other way too: a " &
      "gate that cannot RUN is not a gate. It is evidence where it runs.")
  node["outcome"] = %"captured"
  writeRecord(cfg.recordPath, node)

  echo "captured window ", target.windowId, ": ",
       target.bounds[2], "x", target.bounds[3], " points -> ",
       rep.width, "x", rep.height, " pixels at scale ", scale
  echo "  ", cfg.outPath

# ---------------------------------------------------------------------------

when isMainModule:
  let cfg = parseConfig(commandLineParams())
  case cfg.mode
  of mHost: runHost(cfg)
  of mCapture: runCapture(cfg)
