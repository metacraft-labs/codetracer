## test_plat59_gpui_visual_replay.nim — PLAT-59: **the Visual Replay panes in
## the GPUI window**, read off the SHIPPED binary — its window plan
## (`codetracer-gpui --report-window-plan --window-ops=…`: the window's own
## root builder, its own pointer and key handlers) and the very pixels
## it hands the renderer (`visual_replay_leaf.quadSamples`; what a real window
## then shows is `test_plat59_gpui_window.nim`'s record) — over a REAL visual recording
## (`tui/tests/fixtures/visual_fixture`: `gl_scene`, recorded by `ct-mcr`) and
## a real `ct_gfx_player`:
##
##   * ACTIVATION: the Video Player, Pixel History and Shader Debug panes are
##     in the arrangement for a recording that carries graphics;
##   * THE FRAME AT THREE POSITIONS — frame 0, the scrubber's middle (a press,
##     a drag and a release on its track), the last (`End`): the plan's frame
##     says which, the `img` carries the frame's pixels (`data-gpui-image`),
##     and those pixels are the program's
##     colours — the four quads `gl_scene` drew at that frame, the image's top
##     row first — and the desktop's (`src/tests/visual/answers/
##     plat59-visual-replay.electron.json`);
##   * THE NESTED DRAW-CALL SCRUBBER under the frame scrubber: its position
##     names the draw call within the frame, and the frame shows the quads
##     drawn so far;
##   * THE PICKER: `p`, the loupe over the hovered pixel (its centre the
##     pixel's colour, the readout its coordinate), a press commits;
##   * A PICKED PIXEL'S HISTORY: the rows are the draw calls of that frame
##     that wrote it — the last one the quad's colour — the desktop's rows;
##     a press on a row shows that draw call; the shader's source in Shader
##     Debug;
##   * THE DESKTOP'S KEYS on the focused Video Player: Space, `l`, Home,
##     Right, Shift+Right.
##
## No mocks: the binary, the engine, the player and the recording are the
## product's.

import replay_prerequisite
import ../../tui/tests/fixtures/fixture_provider
import ../../tui/tests/fixtures/visual_fixture
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles,
            unittest]
import ./gpui_child_env

import gpui/visual_replay_leaf

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 46

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc run(args: seq[string]; trace: var string): string =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat59-gpui-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  env["CODETRACER_GPUI_PIXELS_RAW"] = "1"
  let errFile = genTempPath("plat59-gpui-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 300 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args, env = env, options = {})
  result = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the codetracer-gpui run failed (" &
                       args.join(" ") & ")")

proc windowPlan(ops: string; trace: var string): JsonNode =
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add visualFixtureFolder()
  parseJson(run(args, trace))

proc windowPlan(ops: string): JsonNode =
  var t: string
  windowPlan(ops, t)

proc attr(n: JsonNode; name: string): string =
  ## `name`'s value, or "" — also on a node the plan does not have (`first`'s
  ## empty object, whose `{"attributes"}` is nil): an element the window did
  ## not draw is a failed check, not a nil read that kills the suite.
  let a = n{"attributes"}
  if not a.isNil and a.kind == JObject: a{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  let a = n{"attributes"}
  not a.isNil and a.kind == JObject and a.hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc first(plan: JsonNode; attribute: string): JsonNode =
  let all = plan.nodesWith(attribute)
  if all.len > 0: all[0] else: newJObject()

proc hexOf(c: tuple[r, g, b: int]): string =
  "#" & toHex(c.r, 2).toLowerAscii & toHex(c.g, 2).toLowerAscii &
    toHex(c.b, 2).toLowerAscii

proc imageQuads(plan: JsonNode): seq[string] =
  ## The colours of the image the window handed the renderer: its four
  ## quarters, top left, top right, bottom left, bottom right
  ## (`visual_replay_leaf.quadSamples`).
  plan.first(VisualImageQuadsAttribute).attr(VisualImageQuadsAttribute).split(',')

proc imageHeld(plan: JsonNode): string =
  ## The extent of the pixels the frame's `img` HOLDS — set by the renderer
  ## when the element is given them (`setImageRgba`), absent when it is not;
  ## `imageQuads` reads the picture the leaf was asked to draw, not this.
  plan.first(VisualImageAttribute).attr("data-gpui-image")

proc programQuads(frame: int): seq[string] =
  @[hexOf(quadColour(frame, 2)), hexOf(quadColour(frame, 3)),
    hexOf(quadColour(frame, 0)), hexOf(quadColour(frame, 1))]

const AnswersFile = "src/tests/visual/answers/plat59-visual-replay.electron.json"

proc desktopAnswers(): JsonNode =
  var dir = repo
  while not fileExists(dir / AnswersFile) and dir.parentDir != dir:
    dir = dir.parentDir
  parseJson(readFile(dir / AnswersFile))

const
  Show = "visual:show:video,visual:wait"
  Mid = 30

let skip = visualFixtureSkip()

suite "PLAT-59: the Visual Replay panes in the GPUI window":
  if skip.len > 0:
    test "the Visual Replay suites need a visual recording and its player":
      echo skip
      skip()
  else:
    let answers = desktopAnswers()

    test "the panes are in the arrangement, the first frame drawn":
      var trace: string
      let plan = windowPlan(Show, trace)
      let video = plan.first(VideoPlayerAttribute)
      ck video.attr(VideoPlayerAttribute) == "0/" & $GlSceneFrames
      let image = plan.first(VisualImageAttribute)
      ck image.attr(VisualImageAttribute) ==
        $GlSceneSize & "x" & $GlSceneSize
      ck image.attr("data-gpui-image") == $GlSceneSize & "x" & $GlSceneSize
      # Their tabs are beside the state pane's, drawn when shown.
      ck windowPlan("visual:show:history,visual:wait").nodesWith(
        "data-ct-visual-history").len == 1
      let shader = windowPlan("visual:show:shader,visual:wait")
      ck shader.nodesWith("data-ct-visual-shader-context").len +
         shader.nodesWith("data-ct-visual-empty").len >= 1
      ck plan.first("data-ct-visual-thumb").attr("data-ct-visual-thumb") ==
        "frame"
      ck plan.nodesWith("data-ct-visual-track").len == 2  # frame and draw
      ck "visual replay: player at" in trace

    test "the frame at three positions: the program's pixels, the desktop's":
      let size = $GlSceneSize & "x" & $GlSceneSize
      # Frame 0.
      let firstPlan = windowPlan(Show)
      ck firstPlan.imageQuads == programQuads(0)
      ck firstPlan.imageHeld == size
      # The scrubber's middle: a press, a drag, a release.
      let midOps = Show & ",visual:scrub:frame:3:" & $Mid & ",visual:wait"
      let plan = windowPlan(midOps)
      ck plan.first(VideoPlayerAttribute).attr(VideoPlayerAttribute) ==
        $Mid & "/" & $GlSceneFrames
      ck plan.imageQuads == programQuads(Mid)
      ck plan.imageHeld == size
      # The last, by End. `visual:key` names the key as GPUI's keystroke
      # does (`end`, `right`, lower case): since the player's keys are keymap
      # rows the op goes through the window's router, whose key names are
      # `gpui_keys`', and a capitalised `End` names no key there.
      let endOps = Show & ",visual:key:video:end,visual:wait"
      let last = windowPlan(endOps)
      ck last.first(VideoPlayerAttribute).attr(
        VideoPlayerAttribute) == $(GlSceneFrames - 1) & "/" & $GlSceneFrames
      ck last.imageQuads == programQuads(GlSceneFrames - 1)
      ck last.imageHeld == size
      # The desktop's Video Player showed the same frames, in these colours.
      let desk = answers["frames"]
      ck desk[0]["frame"].getInt == 0
      ck desk[2]["frame"].getInt == GlSceneFrames - 1
      var deskEnd: seq[string] = @[]
      for q in desk[2]["quadColours"]: deskEnd.add q.getStr
      ck deskEnd == @[hexOf(quadColour(GlSceneFrames - 1, 0)),
                      hexOf(quadColour(GlSceneFrames - 1, 1)),
                      hexOf(quadColour(GlSceneFrames - 1, 2)),
                      hexOf(quadColour(GlSceneFrames - 1, 3))]

    test "the nested draw-call scrubber shows a frame's draw calls":
      var trace: string
      let ops = Show & ",visual:scrub:draw:3:1,visual:wait"
      let plan = windowPlan(ops, trace)
      let tracks = plan.nodesWith("data-ct-visual-track")
      var drawAt = ""
      for t in tracks:
        if t.attr("data-ct-visual-track") == "draw":
          drawAt = t.attr("data-ct-visual-track-at")
      ck drawAt == "1/" & $GlSceneDrawsPerFrame
      ck "Draw 1 / 3" in plan.first("data-ct-visual-title").attr(
        "data-ct-visual-title")
      let quads = plan.imageQuads
      ck quads[2] == hexOf(quadColour(0, 0))   # drawn
      ck quads[3] == hexOf(quadColour(0, 1))   # drawn
      ck quads[0] == "#000000"                 # not yet
      ck quads[1] == "#000000"

    test "the picker's loupe, a pick, the pixel's history and its navigation":
      let pick = Show & ",visual:key:video:end,visual:wait," &
                 "visual:key:video:p,visual:pixel:40:50:hover"
      let hover = windowPlan(pick)
      ck hover.first("data-ct-visual-picker").attr("data-ct-visual-picker") ==
        "on"
      let loupe = hover.first("data-ct-visual-loupe")
      ck loupe.attr("data-ct-visual-loupe") == "40,50"
      let centre = hover.first("data-ct-visual-loupe-centre")
      ck centre.attr("data-ct-visual-loupe-centre") ==
        hexOf(quadColour(GlSceneFrames - 1, 2))
      ck "x=40" in hover.first("data-ct-visual-readout").attr(
        "data-ct-visual-readout")
      # The press commits; the history is the frame's draws that wrote it.
      let picked = pick & ",visual:pixel:40:50,visual:wait"
      let plan = windowPlan(picked)
      ck plan.first("data-ct-visual-picker").attr("data-ct-visual-picker") ==
        "off"
      ck plan.first("data-ct-visual-pixel").attr("data-ct-visual-pixel") ==
        "Pixel 40, 50 frame " & $(GlSceneFrames - 1)
      let rows = plan.nodesWith(HistoryRowAttribute)
      ck rows.len >= 1
      let start = (GlSceneFrames - 1) * GlSceneDrawsPerFrame
      var draws: seq[int] = @[]
      for r in rows:
        draws.add parseInt(r.attr("data-ct-visual-draw"))
      ck draws[^1] == start + 2
      for d in draws:
        ck d >= start and d < start + GlSceneDrawsPerFrame
      let lastRow = rows[^1]
      var swatch = ""
      for n in lastRow{"children"}.getElems:
        if n.has("data-ct-visual-swatch-post"):
          swatch = n.attr("data-ct-visual-swatch-post")
      ck swatch == hexOf(quadColour(GlSceneFrames - 1, 2))
      # The desktop's rows for the same pixel.
      var deskDraws: seq[int] = @[]
      for e in answers["history"]["entries"]:
        deskDraws.add e["drawCallIndex"].getInt
      ck deskDraws == draws
      # A press on the last row shows that draw call; its shader is asked.
      let nav = picked & ",visual:show:history,visual:history:" &
                $(rows.len - 1) & ",visual:wait,visual:show:shader,visual:wait"
      let after = windowPlan(nav)
      ck "Draw 2 / 3" in after.first("data-ct-visual-title").attr(
        "data-ct-visual-title")
      ck ("draw " & $(start + 2)) in after.first(
        "data-ct-visual-shader-context").attr("data-ct-visual-shader-context")
      var source = ""
      for n in after.nodesWith("data-ct-visual-shader-line"):
        for c in n{"children"}.getElems:
          for t in c{"children"}.getElems:
            source.add t{"text"}.getStr & "\n"
      ck "u_color" in source

    test "the desktop's keys on the focused Video Player":
      let keys = Show & ",visual:key:video:right,visual:wait"
      ck windowPlan(keys).first(VideoPlayerAttribute).attr(
        VideoPlayerAttribute) == "1/" & $GlSceneFrames
      # One press, one step, through the pane's listeners: a pane armed twice
      # ran every key twice, which only a delivered key can show.
      let delivered = Show & ",visual:deliver:right,visual:wait"
      ck windowPlan(delivered).first(VideoPlayerAttribute).attr(
        VideoPlayerAttribute) == "1/" & $GlSceneFrames
      let draw = keys & ",visual:key:video:left,visual:wait," &
                 "visual:key:video:right:shift,visual:wait"
      let plan = windowPlan(draw)
      ck "Draw 0 / 3" in plan.first("data-ct-visual-title").attr(
        "data-ct-visual-title")
      let play = Show & ",visual:key:video:l,visual:key:video:l"
      let p = windowPlan(play)
      ck p.first("data-ct-visual-play-state").attr(
        "data-ct-visual-play-state") == "playing"
      ck "2x >" in p.first("data-ct-visual-status").attr(
        "data-ct-visual-status")
      let paused = play & ",visual:key:video:space"
      ck windowPlan(paused).first("data-ct-visual-play-state").attr(
        "data-ct-visual-play-state") == "paused"

  test "every assertion ran":
    if skip.len == 0:
      check countedAssertions == ExpectedAssertions
