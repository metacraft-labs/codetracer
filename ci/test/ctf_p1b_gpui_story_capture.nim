## CTF-P1b — the GPUI captures of the Agent Harbor stories, as REAL WINDOWS.
##
## GPUI has no headless renderer off macOS, so on Linux a GPUI capture is
## what a user would see: a window on a compositor — GuiAssert's headless sway
## target — read back with the compositor's own capture. This is PLAT-35's
## window path (`plat35_gpui_window_capture.nim`) for a different window: the
## story host `codetracer-gpui-story`
## (`src/frontend/gpui/agent_harbor/ah_story_window.nim`), which opens ONE
## story of the `CodeTracer/Agent Harbor` section in a colour mode and at a
## size.
##
## For every story the host lists (`--list`: the section's own declaration,
## so a story added there is captured here on the day it is declared), in
## each theme and at each size: launch the window with the region declaration,
## wait until the compositor reports it at exactly the size asked for and its
## pixels have settled, write `<out>/<capture id>.ppm`, and wait for the
## regions file the window writes once its layout has settled
## (`<capture id>.regions.json`). The capture id is the web capture's
## (`capture-storybook.mjs`): `agent-harbor-<story>-<size>-<theme>`, so the two
## captures of one story pair by name.
##
## The window floats (so sway does not tile it) under server-side decorations
## that the headless sway draws as nothing, so its frame IS the story's
## viewport — the extent of the web capture's CSS viewport.
##
## Environment (set by `ci/test/ctf-p1b-gpui-story-capture.sh`):
##   CTF_P1B_STORY_BIN, CTF_P1B_GPUI_LD_LIBRARY_PATH, CTF_P1B_REGIONS (the
##   declaration), CTF_P1B_OUT; optional CTF_P1B_ONLY (comma-separated
##   substrings of the story ids to keep), CTF_P1B_SIZES (default `laptop,sidebar`,
##   and `panel` too for the session activity timeline's stories),
##   CTF_P1B_THEMES (default `dark,light`), CTF_P1B_MOMENTS.
##
## With `CTF_P1B_MOMENTS=1` (CTF-P1c, `just ctf-p1c-gpui-captures`) it
## captures each PLAYBACK story at each named moment of its scenario instead
## of each story at its first frame: the host lists a story's moments
## (`--list-moments`, from the scenario itself; a story that is not a
## playback story lists none and is not captured) and opens each with
## `--moment=<name>`, paused there. The capture id names the moment,
## `agent-harbor-<story>-at-<moment>-<size>-<theme>`, as the web capture's
## (`capture-storybook.mjs --moments`) does, so the two captures of one story
## at one moment pair by name.
##
## A capture that produces no settled frame at its size, or no regions, fails
## the run by name; nothing is skipped.

import std/[os, osproc, strutils, times]
import gui_assert/desktop_env
import gui_assert/desktop_env/sway

const
  AppId = "codetracer-story"
  StoryIdPrefix = "codetracer-agent-harbor--"
  ViewPrefix = "agent-harbor-"
  # The design brief's named sizes, as `capture-storybook.mjs` names them.
  Sizes = [("laptop", 1440, 900), ("panel", 760, 640), ("sidebar", 360, 900)]

proc need(name: string): string =
  result = getEnv(name)
  if result.len == 0: quit("ctf_p1b_gpui_story_capture: " & name & " is not set", 2)

proc listOf(name, default: string): seq[string] =
  for part in getEnv(name, default).split(','):
    if part.strip.len > 0: result.add part.strip

proc writePpm(img: RgbImage; path: string) =
  var s = "P6\n" & $img.width & " " & $img.height & "\n255\n"
  s.setLen(s.len + img.data.len)
  let off = s.len - img.data.len
  for i, b in img.data: s[off + i] = char(b)
  writeFile(path, s)

let bin = need("CTF_P1B_STORY_BIN")
let libs = need("CTF_P1B_GPUI_LD_LIBRARY_PATH")
let regionsDecl = need("CTF_P1B_REGIONS")
let outDir = need("CTF_P1B_OUT")
let only = listOf("CTF_P1B_ONLY", "")
let sizes = listOf("CTF_P1B_SIZES", "laptop,sidebar")
let sizesGiven = getEnv("CTF_P1B_SIZES").len > 0
const PanelFamily = StoryIdPrefix & "session-activity"
  ## The session activity timeline's stories, which are also taken at the
  ## `panel` size (the timeline is a panel) unless CTF_P1B_SIZES names the
  ## sizes.

proc sizesFor(id: string): seq[string] =
  result = sizes
  if not sizesGiven and id.startsWith(PanelFamily): result.add "panel"
let themes = listOf("CTF_P1B_THEMES", "dark,light")
let atMoments = getEnv("CTF_P1B_MOMENTS") == "1"

proc momentsOf(story: string): seq[string] =
  ## The named moments the host lists for `story` (none for a story that is
  ## not a playback story). A host that cannot list them fails the run.
  let (listing, rc) = execCmdEx(quoteShellCommand(
    ["env", "LD_LIBRARY_PATH=" & libs, bin, "--story=" & story, "--list-moments"]))
  if rc != 0:
    quit("ctf_p1b_gpui_story_capture: " & bin & " --story=" & story &
         " --list-moments exited " & $rc & ":\n" & listing, 1)
  for line in listing.splitLines:
    if line.strip.len > 0: result.add line.strip

# The stories, from the host itself (the section's declaration).
let (listing, listRc) = execCmdEx(quoteShellCommand(
  ["env", "LD_LIBRARY_PATH=" & libs, bin, "--list"]))
if listRc != 0:
  quit("ctf_p1b_gpui_story_capture: " & bin & " --list exited " & $listRc &
       ":\n" & listing, 1)
var stories: seq[string]
for line in listing.splitLines:
  let id = line.strip
  if not id.startsWith(StoryIdPrefix): continue
  var keep = only.len == 0
  for o in only:
    if o in id: keep = true
  if keep: stories.add id
if stories.len == 0:
  quit("ctf_p1b_gpui_story_capture: no story selected (listing:\n" & listing & ")", 1)
for s in sizes:
  var known = false
  for (name, _, _) in Sizes:
    if name == s: known = true
  if not known: quit("ctf_p1b_gpui_story_capture: unknown size " & s, 2)
for th in themes:
  if th notin ["dark", "light"]: quit("ctf_p1b_gpui_story_capture: unknown theme " & th, 2)

var shots: seq[(string, string)]
  ## Each (story, moment) to capture; "" is the story's first frame.
for id in stories:
  if atMoments:
    for moment in momentsOf(id): shots.add (id, moment)
  else:
    shots.add (id, "")
if shots.len == 0:
  quit("ctf_p1b_gpui_story_capture: no playback story among the selected stories", 1)

createDir(outDir)
let t = newSwayTarget(2560, 1440, floatingAppIds = @[AppId])
t.start()
var failed: seq[string]
var captured = 0
try:
  for (id, moment) in shots:
    let view = ViewPrefix & id[StoryIdPrefix.len .. ^1] &
               (if moment.len > 0: "-at-" & moment else: "")
    for (sizeName, w, h) in Sizes:
      if sizeName notin sizesFor(id): continue
      for theme in themes:
        let captureId = view & "-" & sizeName & "-" & theme
        let regionsOut = outDir / (captureId & ".regions.json")
        removeFile(regionsOut)
        removeFile(outDir / (captureId & ".ppm"))
        echo "=== ", captureId
        let argv = @[bin, "--story=" & id, "--theme=" & theme, "--width=" & $w,
                     "--height=" & $h, "--regions=" & regionsDecl,
                     "--regions-out=" & regionsOut, "--quit-after-ms=600000"] &
                    (if moment.len > 0: @["--moment=" & moment] else: @[])
        let p = t.spawn(@["/bin/sh", "-c", "exec \"$0\" \"$@\" >" &
                          quoteShell(outDir / (captureId & ".run.log")) & " 2>&1"] & argv,
          extraEnv = [("LD_LIBRARY_PATH", libs),
                      # Server-side decorations, which the headless sway
                      # draws as nothing (no border, no title bar): the
                      # window's frame is the story's viewport. Client-side
                      # ones would make the shim draw its fallback title bar
                      # over a story that declares none.
                      ("ISONIM_GPUI_DECORATIONS", "server")])
        try:
          let win = t.waitWindow(AppId, timeout = initDuration(seconds = 120),
            until = proc(x: EnvWindow): bool = x.rect.w == w and x.rect.h == h)
          t.placeWindow(win, 0, 0)
          t.waitUntil("the window at 0,0", proc(): bool =
            let r = t.window(AppId).rect
            r.x == 0 and r.y == 0)
          let img = t.captureSettled(t.window(AppId).rect, agree = 4,
                                     intervalMs = 300, timeout = initDuration(seconds = 60))
          t.waitUntil("the window's regions in " & regionsOut,
                      proc(): bool = fileExists(regionsOut),
                      timeout = initDuration(seconds = 60))
          img.writePpm(outDir / (captureId & ".ppm"))
          inc captured
          echo "  captured ", captureId
        except EnvError as e:
          echo "  FAILED: ", e.msg
          failed.add captureId
        p.terminate()
        discard p.waitForExit(10000)
        p.close()
        # The next window must not be mistaken for this one.
        try:
          t.waitUntil("the window closed", proc(): bool = not t.findWindow(AppId)[0],
                      timeout = initDuration(seconds = 20))
        except EnvError as e:
          echo "  FAILED: ", e.msg
          failed.add captureId & " (did not close)"
finally:
  t.stop()
echo "ctf_p1b_gpui_story_capture: ", captured, " captures of ", stories.len, " stories",
  (if atMoments: " at " & $shots.len & " (story, moment) pairs" else: "")
if failed.len > 0:
  quit("ctf_p1b_gpui_story_capture: no frame or no regions for " & failed.join(", "), 1)
