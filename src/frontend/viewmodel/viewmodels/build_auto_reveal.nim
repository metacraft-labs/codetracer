## viewmodels/build_auto_reveal.nim — **When a build shows the Build Output
## pane and when it puts it away, decided once** (Build-Output-Pane.md §3.8;
## Auto-Hide-Panes.md).
##
## Every front-end docks panes to an edge (the desktop's auto-hide strips, the
## terminal's and GPUI's docked panes) and can reveal one over the
## arrangement. What a BUILD does with that is the same everywhere, so it is
## this rule over the `BuildVM`'s verdict, and each front-end only applies the
## step it answers to its own docking:
##
## * a build STARTS — `brsReveal`: the pane is brought on screen (revealed from
##   its edge where it is docked, its tab activated where it is placed);
## * a build FAILS — `brsRevealProblems`: the pane and then the Problems pane
##   (the one shown last is the one a user reads first), without moving the
##   keyboard (EMT-D21);
## * a build SUCCEEDS with no warning and no error — the pane is put away
##   `BuildAutoDismissMs` later (`due`), "showing 'Build succeeded in 3.2s'"
##   meanwhile — unless the user touched the pane in between (`interact`: §3.8
##   "pin on interaction"), or another build started;
## * a cancelled build, or a success with warnings, leaves the pane as it is.
##
## Putting it away only ever undoes a REVEAL: a pane the user docked open, or
## placed in the arrangement, stays (each front-end checks that its revealed
## pane is the Build Output pane before hiding it).
##
## The settings are §5.1's `build.autoReveal` and `build.autoDismissOnSuccess`
## (both on by default), read from the configuration file by
## `buildRevealSettingOfConfigText` on the native front-ends and from the
## loaded configuration on the desktop.
##
## Pure Nim, no clock of its own (the host passes `nowMs`). C and JavaScript.

import std/strutils

import ./build_output_model

type
  BuildRevealStep* = enum
    brsNone = "none"
    brsReveal = "reveal"
      ## A build started: bring the Build Output pane on screen.
    brsRevealProblems = "reveal-problems"
      ## A build failed: the Build Output pane, then the Problems pane.
    brsDismiss = "dismiss"
      ## The success's delay ran out: put the revealed pane away.

  BuildRevealSetting* = object
    autoReveal*: bool
    autoDismissOnSuccess*: bool

  BuildAutoReveal* = object
    ## One window's rule, fed the current build after every change.
    setting*: BuildRevealSetting
    seenNumber: int
    seenStatus: BuildStatus
    dismissAtMs*: float
      ## When the pane is put away (ms, the host's clock), 0 for never.
    pinned*: bool
      ## The user touched the pane since the build started: it stays.

const
  BuildAutoDismissMs* = 2000.0
    ## §3.8: "after a brief delay (e.g., 2 seconds …)".
  DefaultBuildRevealSetting* = BuildRevealSetting(autoReveal: true,
                                                  autoDismissOnSuccess: true)

proc initBuildAutoReveal*(setting = DefaultBuildRevealSetting): BuildAutoReveal =
  BuildAutoReveal(setting: setting)

proc observe*(a: var BuildAutoReveal; number: int; status: BuildStatus;
              errors, warnings: int; nowMs: float): BuildRevealStep =
  ## The current build (its number in the window, its verdict, its diagnostic
  ## counts) as it is now. The step to apply, once per change.
  result = brsNone
  let isNew = number != a.seenNumber
  let changed = isNew or status != a.seenStatus
  a.seenNumber = number
  a.seenStatus = status
  if not changed:
    return
  if isNew:
    # A NEW BUILD: whatever the last one scheduled or the user pinned is over.
    # (A build can start and end between two observations — a fast compile
    # read on the next tick — and is then revealed and judged at once.)
    a.dismissAtMs = 0.0
    a.pinned = false
  case status
  of bsRunning:
    if isNew and a.setting.autoReveal:
      result = brsReveal
  of bsFailed:
    a.dismissAtMs = 0.0
    if a.setting.autoReveal:
      result = brsRevealProblems
  of bsSucceeded:
    if isNew and a.setting.autoReveal:
      result = brsReveal
    if a.setting.autoDismissOnSuccess and errors == 0 and warnings == 0 and
       not a.pinned:
      a.dismissAtMs = nowMs + BuildAutoDismissMs
  of bsIdle, bsCancelled:
    a.dismissAtMs = 0.0

proc interact*(a: var BuildAutoReveal) =
  ## The user pressed, scrolled or typed in the revealed pane: it stays (§3.8
  ## "pin on interaction").
  a.pinned = true
  a.dismissAtMs = 0.0

proc pending*(a: BuildAutoReveal): bool =
  ## Whether a dismissal is waiting (the host keeps its clock ticking).
  a.dismissAtMs > 0.0

proc due*(a: var BuildAutoReveal; nowMs: float): BuildRevealStep =
  ## `brsDismiss` once, when the success's delay has run out.
  if a.dismissAtMs > 0.0 and nowMs >= a.dismissAtMs and not a.pinned:
    a.dismissAtMs = 0.0
    return brsDismiss
  brsNone

proc boolWord(v: string; ok: var bool): bool =
  ok = true
  case v.strip.toLowerAscii
  of "true", "yes", "on": true
  of "false", "no", "off": false
  else:
    ok = false
    false

proc buildRevealSettingOfConfigText*(text: string): tuple[
    setting: BuildRevealSetting; problems: seq[string]] =
  ## §5.1's `build:` entry of a configuration file:
  ##
  ##     build:
  ##       autoReveal: true
  ##       autoDismissOnSuccess: true
  ##
  ## A missing entry is the default; a value that is not true or false is a
  ## problem, and the default stands.
  result.setting = DefaultBuildRevealSetting
  var inBuild = false
  for raw in text.splitLines:
    var line = raw
    let hash = line.find(" #")
    if hash >= 0: line = line[0 ..< hash]
    if line.strip.len == 0 or line.strip.startsWith("#"):
      continue
    if line[0] != ' ':
      inBuild = line.strip == "build:"
      continue
    if not inBuild:
      continue
    let colon = line.find(':')
    if colon < 0:
      continue
    let key = line[0 ..< colon].strip
    let value = line[colon + 1 .. ^1].strip.strip(chars = {'"', '\''})
    var ok: bool
    case key
    of "autoReveal":
      let b = boolWord(value, ok)
      if ok: result.setting.autoReveal = b
      else: result.problems.add "build.autoReveal is true or false, not '" &
                                value & "'"
    of "autoDismissOnSuccess":
      let b = boolWord(value, ok)
      if ok: result.setting.autoDismissOnSuccess = b
      else: result.problems.add "build.autoDismissOnSuccess is true or " &
                                "false, not '" & value & "'"
    else:
      discard
