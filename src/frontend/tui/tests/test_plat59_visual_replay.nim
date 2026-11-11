## test_plat59_visual_replay.nim — PLAT-59, Tier 1. **The Visual Replay panes
## on the terminal — the frame with its built-in scrubber, the nested
## draw-call scrubber, the picker and magnifier, pixel history rows that
## navigate, shader debug and the desktop's keys — on a REAL visual
## recording.**
##
## A real `gl_scene` recording (`fixtures/visual_fixture`: `ct-mcr`'s, its gfx
## stream extracted), opened by the terminal's own `openTuiSession` over a real
## `replay-server`; its graphics by the terminal's own producer
## (`attachVisualReplay`: a real `ct_gfx_player`, the shared
## `VisualReplayPanesVM`); driven through the runtime's own token and mouse
## handlers and painted by its own `shellScreen`, at a pinned CELL tier
## (half-block: the tier this terminal draws a frame at without a graphics
## protocol):
##
##   * ACTIVATION: the three panes are added to the layout — the Video
##     Player a tab beside the editor, Pixel History and Shader Debug tabs
##     beside the state pane — and the user's tabs stay the ones shown;
##   * THE FRAME AT THREE POSITIONS (frame 0, the scrubber's middle, the
##     last): the pixels the pane holds are the program's — every quad's
##     colour `gl_scene`'s formula gives for that frame — the IMAGE top row
##     first (the player's GL rows are bottom-up), and the CELLS the pane
##     paints carry those colours; the same three frames the desktop's Video
##     Player showed (`src/tests/visual/answers/plat59-visual-replay.electron.json`);
##   * THE SCRUBBER: a press on the bottom track, a drag and a release — the
##     thumb under the pointer while held, the frame under the release
##     settled; the frame count and the release semantics (playing resumes);
##   * THE NESTED DRAW-CALL SCRUBBER: a press on its track shows the
##     framebuffer after that draw call of the frame — the quads drawn so
##     far coloured, the rest the clear colour;
##   * THE PICKER AND MAGNIFIER: `p` opens §5's magnifier at the frame's
##     centre, the arrows move its SOURCE pixel, Enter commits it;
##   * PIXEL HISTORY: the committed pixel's rows are the draw calls of that
##     frame that wrote it, the last one the quad's colour; a press on a row
##     shows that draw call in the Video Player;
##   * SHADER DEBUG: the fragment's context and the shader's source;
##   * THE DESKTOP'S KEYS, scoped to the pane: Space plays and pauses, `l`
##     cycles the rate, Home / End, Left / Right a frame, Shift+Right a draw.
##
## No mocks: the recording, the engine, the player, the runtime and the
## painters are the product's.

import std/[json, options, os, strutils, unicode, unittest]

import isonim/core/[signals]

import headless_session
import headless_app/layout_model
import codetracer_embed

import ../app/runtime
import ../../viewmodel/keymap/[keymap_router, user_keymap]
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/image_capability
import ../app/views/shell
import ../app/views/styled_row
import ../app/views/frame_viewer
import ../app/views/visual_replay_panes
import ../host/tui_session
import ../host/frame_image
import ../../viewmodel/host/native_visual_replay_host
import view_vocabulary/pane_views
import ../../../common/view_vocabulary
import ./fixtures/fixture_provider
import ./fixtures/visual_fixture

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as the suite's RUNTIME assertion count.
const ExpectedAssertions = 119

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 60

proc newRuntime(): TuiRuntime =
  let env = initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                            lang = "en_US.UTF-8")
  var flags = initCapabilityFlags()
  flags.imageTier = itHalfBlock
  flags.imageTierPinned = true
  let caps = resolveCapabilities(env, flags)
  result = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()
  result.imageCapability = resolveImageCapability(env, initImageEnv(), caps,
                                                  flags)

proc sgr(code, row, col: int; release = false): string =
  "\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
    (if release: "m" else: "M")

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc settle(s: TuiSession; rt: TuiRuntime) =
  ## Every request the panes asked answered and applied, the panes read.
  discard s.visual.settleAll()
  s.refreshVisual(rt)
  discard rt.shellScreenOf()
  s.refreshVisual(rt)

proc open(): (TuiRuntime, TuiSession) =
  let rt = newRuntime()
  let s = openTuiSession(visualFixtureFolder(), viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  rt.app.visualAct = proc(act: VisualAct): VisualActResult =
    s.visualAct(rt, act)
  s.attachVisualReplay(rt, visualFixtureFolder())
  s.syncVisualLayout(rt)
  s.settle(rt)
  (rt, s)

proc regionOf(rt: TuiRuntime; kind: PaneKind): CellArea =
  let screen = rt.shellScreenOf()
  for region in screen.geometry.projection.regions:
    if region.pane == kind:
      return region.area
  CellArea()

proc cellStyle(rt: TuiRuntime; row, col: int): CellStyle =
  let screen = rt.shellScreenOf()
  var c = 0
  for span in screen.styledRows[row]:
    let w = span.text.runeLen
    if col >= c and col < c + w:
      return span.style
    c += w
  CellStyle()

proc hexOf(c: tuple[r, g, b: int]): string =
  "#" & toHex(c.r, 2).toLowerAscii & toHex(c.g, 2).toLowerAscii &
    toHex(c.b, 2).toLowerAscii

proc frameMatchesProgram(panes: VisualReplayPanesVM; frame: int): bool =
  ## Every quad's centre is the colour `gl_scene` drew it in at `frame`, in
  ## the image's own orientation (top row first).
  let pic = panes.frame.picture.val
  if pic.width != GlSceneSize or pic.height != GlSceneSize:
    return false
  for (x, y) in [(64, 64), (192, 64), (64, 192), (192, 192)]:
    if pic.pixels.pixelOf(pic.width, x, y) != quadColour(frame,
                                                         quadrantAt(x, y)):
      return false
  true

proc pictureCellColours(rt: TuiRuntime): seq[string] =
  ## The four quads' colours as the PAINTED CELLS carry them: the cell at the
  ## centre of each quadrant of the picture (a half block's top sample is its
  ## foreground, the bottom its background; both are inside one quad there).
  let (area, screen) = rt.videoPlayerScreen()
  if screen.pictureTop < 0:
    return @[]
  for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]:
    let col = area.col + int(fx * float(screen.pictureCols))
    let row = screen.pictureTop + int(fy * float(screen.pictureRows))
    result.add rt.cellStyle(row, col).fg

const AnswersFile = "src/tests/visual/answers/plat59-visual-replay.electron.json"
  ## The desktop's Video Player and Pixel History on this recording, captured
  ## from the real Electron app (`just plat59-capture-electron`).

proc desktopAnswers(): JsonNode =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / AnswersFile) and dir.parentDir != dir:
    dir = dir.parentDir
  parseJson(readFile(dir / AnswersFile))

let skip = visualFixtureSkip()

suite "PLAT-59: the Visual Replay panes on the terminal":
  if skip.len > 0:
    test "the Visual Replay suites need a visual recording and its player":
      echo skip
      skip()
  else:
    let (rt, s) = open()
    let panes = s.visualPanes
    let answers = desktopAnswers()

    test "a recording the engine refuses opens with its graphics, and says why":
      # The fixture is a premain recording: the debug server has no stage0
      # boundary to replay it from, so the session has no engine, as on the
      # desktop, and the Visual Replay panes do not need one.
      let (rt, s) = open()
      defer: s.close()
      ck s.session.engineRefusal.contains("no stage0 boundary")
      ck s.ended
      ck rt.app.notification.startsWith("No debugging session for this recording: ")
      ck rt.app.notification.contains("no stage0 boundary")
      ck not s.session.session.visualReplay.isNil
      ck s.session.session.visualReplay.available.val

    test "the panes are added as the desktop adds them, additively":
      let tree = rt.app.layoutBinding.layout.tree
      ck tree.contains(paneVideoPlayer)
      ck tree.contains(panePixelHistory)
      ck tree.contains(paneShaderDebug)
      # The user's tabs are still the ones shown.
      ck rt.regionOf(paneEditor).width > 0
      ck rt.regionOf(paneState).width > 0
      ck not panes.isNil
      ck panes.playerError.val == ""
      ck panes.frame.frameCount.val == GlSceneFrames

    test "the frame at three positions is the program's, and the desktop's":
      # Show the Video Player's tab and give it the focus.
      discard rt.app.layoutBinding.dispatch(cmdActivateTab(paneVideoPlayer))
      rt.showVisualPane(paneVideoPlayer)
      s.settle(rt)
      ck rt.regionOf(paneVideoPlayer).width > 0
      ck panes.frameMatchesProgram(0)
      ck panes.frame.frameDrawCount.val == GlSceneDrawsPerFrame
      ck rt.app.frameViewer.hasRaster
      ck rt.app.frameViewer.gap == fdgNone
      ck rt.app.frameViewer.capability.tier == itHalfBlock
      let cells0 = rt.pictureCellColours()
      ck cells0.len == 4
      ck cells0[0] == hexOf(quadColour(0, 2))   # the image's top-left: Q2
      ck cells0[3] == hexOf(quadColour(0, 1))   # its bottom-right: Q1
      # The middle of the scrubber, by a press and release on its track.
      let (area, screen) = rt.videoPlayerScreen()
      ck screen.scrubberRow >= 0
      # The column of the frame the desktop's capture went to, so the two
      # read the same three frames.
      var mid = area.col
      while mid < area.col + area.width - 1 and
            rt.app.frameViewer.frameAtColumn(area, mid) < GlSceneFrames div 2:
        inc mid
      s.send(rt, sgr(0, screen.scrubberRow, mid))
      s.send(rt, sgr(0, screen.scrubberRow, mid, release = true))
      s.settle(rt)
      let middle = rt.app.frameViewer.frameAtColumn(area, mid)
      ck middle > 0 and middle < GlSceneFrames - 1
      ck panes.frame.currentFrame.val == middle
      ck panes.frameMatchesProgram(middle)
      ck rt.pictureCellColours()[0] == hexOf(quadColour(middle, 2))
      # The last frame, by the desktop's End.
      rt.app.layoutBinding.focus = paneVideoPlayer
      discard rt.focus.focusPaneKind(paneVideoPlayer)
      s.send(rt, "\x1b[F")
      s.settle(rt)
      ck panes.frame.currentFrame.val == GlSceneFrames - 1
      ck panes.frameMatchesProgram(GlSceneFrames - 1)
      # The desktop's Video Player showed the same three frames.
      let desk = answers["frames"]
      ck desk.len == 3
      for (i, f) in [(0, 0), (1, middle), (2, GlSceneFrames - 1)]:
        ck desk[i]["frame"].getInt == f
        var quads: seq[string] = @[]
        for q in 0 .. 3:
          quads.add hexOf(quadColour(f, q))
        var deskQuads: seq[string] = @[]
        for q in desk[i]["quadColours"]:
          deskQuads.add q.getStr
        ck deskQuads == quads

    test "the scrubber holds, follows the pointer and settles on the release":
      let (area, screen) = rt.videoPlayerScreen()
      let row = screen.scrubberRow
      s.send(rt, sgr(0, row, area.col + 2))
      ck rt.app.frameViewer.scrubbing
      ck panes.player.frameScrub.held
      s.send(rt, sgr(32, row, area.col + area.width div 4))
      let held = rt.app.frameViewer.frameAtColumn(area, area.col +
                                                  area.width div 4)
      ck rt.app.frameViewer.frameIndex == held   # the thumb under the pointer
      s.send(rt, sgr(32, row, area.col + area.width div 3))
      s.send(rt, sgr(0, row, area.col + area.width div 3, release = true))
      s.settle(rt)
      let released = rt.app.frameViewer.frameAtColumn(area, area.col +
                                                      area.width div 3)
      ck not panes.player.frameScrub.held
      ck panes.frame.currentFrame.val == released
      ck panes.frameMatchesProgram(released)
      # A drag while playing pauses; the release resumes as it was.
      s.send(rt, "l")
      ck panes.player.playState.val == Playing
      s.send(rt, sgr(0, row, area.col + 4))
      ck panes.player.playState.val == Paused
      s.send(rt, sgr(0, row, area.col + 4, release = true))
      ck panes.player.playState.val == Playing
      s.send(rt, " ")
      ck panes.player.playState.val == Paused
      s.settle(rt)

    test "the nested draw-call scrubber shows a frame's draw calls":
      s.send(rt, "\x1b[H")                 # Home: frame 0
      s.settle(rt)
      ck panes.frame.currentFrame.val == 0
      let (area, screen) = rt.videoPlayerScreen()
      ck screen.drawScrubberRow >= 0
      ck screen.drawScrubberRow == screen.scrubberRow + 1
      # The second draw call: quads 0 and 1 drawn, 2 and 3 still cleared.
      let col = area.col + (area.width - 1) div 3
      ck rt.app.frameViewer.drawAtColumn(area, col) == 1
      s.send(rt, sgr(0, screen.drawScrubberRow, col))
      s.send(rt, sgr(0, screen.drawScrubberRow, col, release = true))
      s.settle(rt)
      ck panes.frame.drawInFrame.val == 1
      ck panes.frame.currentFrame.val == 0
      let pic = panes.frame.picture.val
      ck pic.pixels.pixelOf(pic.width, 64, 192) == quadColour(0, 0)
      ck pic.pixels.pixelOf(pic.width, 192, 192) == quadColour(0, 1)
      ck pic.pixels.pixelOf(pic.width, 64, 64) == (0, 0, 0)
      # Shift+Right: the next draw call of the frame.
      s.send(rt, "\x1b[1;2C")
      s.settle(rt)
      ck panes.frame.drawInFrame.val == 2
      ck panes.frame.picture.val.pixels.pixelOf(GlSceneSize, 64, 64) ==
        quadColour(0, 2)

    test "the picker's magnifier picks a source pixel and its history loads":
      s.send(rt, "\x1b[F")                 # End: the last frame, whole
      s.settle(rt)
      s.send(rt, "p")
      ck rt.app.frameViewer.magnified
      ck panes.player.pickerState.val == PickerActive
      let (cx, cy) = rt.app.frameViewer.magnifier.pickedPixel()
      # Up and left by whole source pixels, into the top-left quad.
      for i in 0 ..< 70:
        s.send(rt, "\x1b[1;2D")            # Shift+Left: 8 pixels
        s.send(rt, "\x1b[1;2A")            # Shift+Up
      let (px, py) = rt.app.frameViewer.magnifier.pickedPixel()
      ck px < cx and py < cy
      ck px < GlSceneSize div 2 and py < GlSceneSize div 2
      s.send(rt, "\r")                     # Enter commits
      s.settle(rt)
      ck not rt.app.frameViewer.magnified
      ck panes.player.pickerState.val == PickerOff
      ck panes.pickedPixel.isSome
      ck panes.pickedPixel.get.x == px and panes.pickedPixel.get.y == py
      ck panes.pickedPixel.get.frame == GlSceneFrames - 1
      let rows = panes.history.entries.val
      ck rows.len >= 1
      let last = rows[^1]
      let start = (GlSceneFrames - 1) * GlSceneDrawsPerFrame
      ck last.drawCallIndex == start + 2      # quad 2 (the top-left)
      let c = quadColour(GlSceneFrames - 1, 2)
      ck colorByte(last.postColor.r) == c.r
      ck colorByte(last.postColor.g) == c.g
      ck colorByte(last.postColor.b) == c.b
      for e in rows:
        ck e.drawCallIndex >= start and
           e.drawCallIndex < start + GlSceneDrawsPerFrame
      # The pane lists them in the desktop's words.
      ck rt.app.pixelHistory.loaded
      ck rt.app.pixelHistory.rows.len == rows.len
      ck rt.app.pixelHistory.header ==
        "Pixel " & $px & ", " & $py & " frame " & $(GlSceneFrames - 1)
      ck rt.app.pixelHistory.rows[^1].draw == "Draw " & $(start + 2)
      # The desktop's pixel history of the same pixel.
      let deskHistory = answers["history"]
      ck deskHistory["pixel"]["x"].getInt >= 0
      var deskDraws: seq[int] = @[]
      for e in deskHistory["entries"]:
        deskDraws.add e["drawCallIndex"].getInt
      # Same quadrant, same frame: the same draw calls wrote it.
      var draws: seq[int] = @[]
      for e in rows:
        draws.add e.drawCallIndex
      ck deskDraws == draws

    test "a history row navigates: the Video Player shows its draw call":
      rt.showVisualPane(panePixelHistory)
      discard rt.shellScreenOf()
      let (_, hs) = rt.pixelHistoryScreen()
      ck hs.listTop >= 0
      let n = panes.history.entries.val.len
      let target = panes.history.entries.val[n - 1].drawCallIndex
      s.send(rt, sgr(0, hs.listTop + (n - 1), rt.regionOf(
        panePixelHistory).col + 2))
      s.send(rt, sgr(0, hs.listTop + (n - 1), rt.regionOf(
        panePixelHistory).col + 2, release = true))
      s.settle(rt)
      ck panes.history.selectedEntry.val == some(n - 1)
      ck panes.frame.shownDraw.val == target
      ck panes.frame.drawInFrame.val == 2
      # Its fragment's shader was asked for.
      ck panes.shader.selectedContext.val.isSome
      ck panes.shader.selectedContext.val.get.drawCallIndex == some(target)

    test "shader debug shows the fragment and the shader's source":
      rt.showVisualPane(paneShaderDebug)
      s.settle(rt)
      ck rt.app.shaderDebug.loaded
      ck rt.app.shaderDebug.context.startsWith("Pixel ")
      ck "draw " in rt.app.shaderDebug.context
      ck rt.app.shaderDebug.hasInfo
      ck rt.app.shaderDebug.sourceLines.len > 0
      var joined = ""
      for l in rt.app.shaderDebug.sourceLines: joined.add l & "\n"
      ck "u_color" in joined
      let (_, ss) = rt.shaderDebugScreen()
      ck ss.toolbarRow >= 0
      ck ss.buttons.len == 4

    test "at tier 0 the frame is transmitted over the cells the pane reserves":
      # The same pane on a Kitty terminal: the capability says tier 0 and the
      # Kitty protocol, as a measured path would.
      var kitty = rt.app.frameViewer
      kitty.capability.tier = itProtocol
      kitty.capability.protocol = ipKitty
      ck kitty.transmitsProtocol
      let saved = rt.app.frameViewer
      rt.app.frameViewer = kitty
      let (_, screen) = rt.videoPlayerScreen()
      ck screen.protocolRect.width > 0 and screen.protocolRect.height > 0
      ck screen.pictureTop == screen.protocolRect.row
      var state = FrameImageState()
      let bytes = frameImageBytes(state, screen.protocolRect, kitty)
      ck "a=t,f=32,s=256,v=256,i=" & $FrameImageId in bytes
      ck "a=p,i=" & $FrameImageId & ",p=1,c=" & $screen.protocolRect.width &
         ",r=" & $screen.protocolRect.height in bytes
      # Nothing changed: nothing is sent again.
      ck frameImageBytes(state, screen.protocolRect, kitty) == ""
      # The rectangle gone: the placement is taken down.
      ck "a=d,d=i,i=" & $FrameImageId in
        frameImageBytes(state, CellArea(), kitty)
      rt.app.frameViewer = saved

    test "the vocabulary's Video Player view says the shared words":
      let view = videoPlayerPaneView(panes.player)
      var found = ""
      for n in walk(view.root):
        if n.id == "videoPlayer.frame": found = n.text
      ck found.startsWith("Frame " & $panes.frame.currentFrame.val & " / 59")

    test "the desktop's keys, scoped to the Video Player":
      rt.showVisualPane(paneVideoPlayer)
      rt.app.layoutBinding.focus = paneVideoPlayer
      discard rt.focus.focusPaneKind(paneVideoPlayer)
      s.send(rt, "\x1b[H")                 # Home
      s.settle(rt)
      ck panes.frame.currentFrame.val == 0
      s.send(rt, "\x1b[C")                 # Right: the next frame
      s.settle(rt)
      ck panes.frame.currentFrame.val == 1
      ck panes.frameMatchesProgram(1)
      s.send(rt, "\x1b[D")                 # Left
      s.settle(rt)
      ck panes.frame.currentFrame.val == 0
      s.send(rt, "l")                      # forward 1x
      ck panes.player.rate.val == Rate1x
      s.send(rt, "l")                      # 2x
      ck panes.player.rate.val == Rate2x
      ck rt.app.frameViewer.transport.playing
      ck "2x >" in rt.app.frameViewer.transport.transportStatus
      s.send(rt, "k")                      # pause
      ck panes.player.playState.val == Paused
      s.settle(rt)
      # Focus elsewhere: the keys are not the player's.
      rt.app.layoutBinding.focus = paneEventLog
      ck rt.focus.focusPaneKind(paneEventLog)
      ck not rt.videoPlayerOwnsToken(" ")

    test "the player's keys and its buttons' presses follow a user's rows":
      # Input-Routing §4.3 / §5.1: the keys are keymap rows and a transport
      # button runs the operation it carries, so a user's `keybindings.json`
      # rebinds both — a key in the pane's scope, a press on its buttons.
      rt.showVisualPane(paneVideoPlayer)
      rt.app.layoutBinding.focus = paneVideoPlayer
      discard rt.focus.focusPaneKind(paneVideoPlayer)
      rt.router.applyUserKeymap(parseUserKeymap("""[
        { "key": "j", "command": "video-player.jump-end",
          "when": "paneKind == videoPlayer" },
        { "key": "click", "command": "video-player.jump-start",
          "when": "paneKind == videoPlayer && elementKind == button" }
      ]"""))
      defer: rt.router.applyUserKeymap(parseUserKeymap("[]"))
      s.send(rt, "\x1b[H")                 # Home: the first frame
      s.settle(rt)
      ck panes.frame.currentFrame.val == 0
      s.send(rt, "j")                      # rebound: the last frame
      s.settle(rt)
      ck panes.frame.currentFrame.val == GlSceneFrames - 1
      ck panes.player.playState.val == Paused
      # A press on Play now runs the user's row: the first frame, not playing.
      let (_, screen) = rt.videoPlayerScreen()
      var playCol = -1
      for b in screen.transportButtons:
        if b.action == VpaTogglePlay: playCol = b.col
      ck playCol >= 0
      s.send(rt, sgr(0, screen.transportRow, playCol))
      s.send(rt, sgr(0, screen.transportRow, playCol, release = true))
      s.settle(rt)
      ck panes.frame.currentFrame.val == 0
      ck panes.player.playState.val == Paused

    s.close()

  test "every assertion ran":
    if skip.len == 0:
      check countedAssertions == ExpectedAssertions
