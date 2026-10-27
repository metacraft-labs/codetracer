## How CodeTracer's window opens — PLAT-69 (C5): ONE policy, read by BOTH
## front-ends that open a window, the desktop (Electron, `index/window.nim`)
## and GPUI (`frontend/gpui/main.nim`).
##
## The user configures it in the configuration file both already read
## (`.config.yaml`, shipped as `src/config/default_config.yaml`):
##
##   window:
##     initial: maximized     # maximized | windowed
##     width: 1900            # the windowed size (and the size a maximized
##     height: 1400           # window is restored to)
##
## With no `window` entry the answer is the desktop's behaviour before the
## setting existed: open maximized, restore to 1900x1400, never smaller than
## 1050x600.
##
## Pure: strings and integers in, a decision out. The two front-ends read the
## file their own way (js-yaml on the desktop, `windowSettingOfConfigText`
## here for GPUI) and hand the values to `parseWindowSetting`, so a value one
## front-end accepts and the other refuses cannot happen. Compiles for the C
## and the JS backends.

import std/[strutils]

type
  InitialWindowState* = enum
    iwsMaximized = "maximized"
    iwsWindowed = "windowed"

  WindowSetting* = object
    ## The user's `window:` entry, validated.
    initial*: InitialWindowState
    width*, height*: int
      ## The windowed size, in logical pixels.

  WindowLaunch* = object
    ## What a front-end asks the platform for when it opens its window.
    maximized*: bool
    width*, height*: int
      ## The windowed size — the size the window opens at, or, when
      ## `maximized`, the size it is restored to.
    minWidth*, minHeight*: int
      ## The smallest size a resize may leave the window at.
    explicitSize*: bool
      ## The size came from the command line (`--width` / `--height`).

const
  DefaultWindowWidth* = 1900
  DefaultWindowHeight* = 1400
    ## The desktop's `BrowserWindow` size since before this setting existed.
  MinWindowWidth* = 1050
  MinWindowHeight* = 600
    ## The desktop's `minWidth` / `minHeight`.
  MaxWindowExtent* = 32768
    ## Larger than any screen; a value above it is a typo, not a size.
  DefaultWindowSetting* = WindowSetting(initial: iwsMaximized,
                                        width: DefaultWindowWidth,
                                        height: DefaultWindowHeight)

proc parseWindowSetting*(initial: string; width, height: int): tuple[
    setting: WindowSetting, problems: seq[string]] =
  ## The setting from its three raw values. `""` / `0` mean "not given" and
  ## take the default. A value that cannot be used is REPORTED and replaced
  ## by the default for that value only — a typo in `initial` must not also
  ## lose the user's size, and must never stop the window from opening.
  result.setting = DefaultWindowSetting
  let want = initial.strip().toLowerAscii()
  case want
  of "": discard
  of $iwsMaximized: result.setting.initial = iwsMaximized
  of $iwsWindowed: result.setting.initial = iwsWindowed
  else:
    result.problems.add "window.initial: '" & initial &
                        "' is not one of maximized, windowed; using maximized"
  proc extent(name: string; value, fallback, minimum: int;
              problems: var seq[string]): int =
    if value == 0: return fallback
    if value < 0 or value > MaxWindowExtent:
      problems.add "window." & name & ": " & $value &
                   " is not a window size; using " & $fallback
      return fallback
    if value < minimum:
      problems.add "window." & name & ": " & $value & " is below the minimum " &
                   $minimum & "; using " & $minimum
      return minimum
    value
  result.setting.width = extent("width", width, DefaultWindowWidth,
                                MinWindowWidth, result.problems)
  result.setting.height = extent("height", height, DefaultWindowHeight,
                                 MinWindowHeight, result.problems)

proc windowSettingOfConfigText*(text: string): tuple[
    setting: WindowSetting, problems: seq[string]] =
  ## The `window:` entry of a configuration file's TEXT, for a front-end
  ## without a YAML library (GPUI). Reads exactly the shape the entry is
  ## documented in: a column-0 `window:` line and indented `key: value`
  ## lines under it, `#` comments, optional quotes. Every other line of the
  ## file is ignored, so the rest of the configuration's YAML never matters
  ## here. A file with no `window:` entry is the default, with no problem.
  var initial = ""
  var width, height = 0
  var problems: seq[string]
  var inside = false
  for raw in text.splitLines():
    var line = raw
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    if line.strip().len == 0: continue
    let indented = line[0] in {' ', '\t'}
    if not indented:
      inside = line.strip() == "window:"
      continue
    if not inside: continue
    let colon = line.find(':')
    if colon < 0: continue
    let key = line[0 ..< colon].strip()
    var value = line[colon + 1 .. ^1].strip()
    if value.len >= 2 and value[0] in {'"', '\''} and value[^1] == value[0]:
      value = value[1 .. ^2]
    case key
    of "initial": initial = value
    of "width", "height":
      var n = 0
      try: n = parseInt(value)
      except ValueError:
        problems.add "window." & key & ": '" & value & "' is not a number"
        continue
      if n == 0:
        problems.add "window." & key & ": 0 is not a window size"
        continue
      if key == "width": width = n else: height = n
    else:
      problems.add "window: unknown key '" & key & "'"
  let parsed = parseWindowSetting(initial, width, height)
  (parsed.setting, problems & parsed.problems)

proc resolveWindowLaunch*(setting: WindowSetting;
                          cliWidth = 0; cliHeight = 0): WindowLaunch =
  ## The launch decision. An explicit `--width` or `--height` (non-zero)
  ## OVERRIDES the setting: the window opens WINDOWED at that size, whatever
  ## `initial` says — a test lane's window is the size it asked for, and a
  ## maximized window's size is the screen's, which no lane controls. The
  ## dimension not given comes from the setting. The minimum is lowered to
  ## an explicit size below it, so an explicitly small window opens as asked.
  let explicit = cliWidth > 0 or cliHeight > 0
  result.explicitSize = explicit
  result.maximized = setting.initial == iwsMaximized and not explicit
  result.width = if cliWidth > 0: cliWidth else: setting.width
  result.height = if cliHeight > 0: cliHeight else: setting.height
  result.minWidth = min(MinWindowWidth, result.width)
  result.minHeight = min(MinWindowHeight, result.height)

when not defined(js):
  import std/os

  proc findUserConfigFile*(startDir, userConfigDir: string;
                           fileName = ".config.yaml"): string =
    ## The configuration file the desktop reads (`index/config.findConfig`):
    ## the first `fileName` in `startDir` or one of its parents, else the
    ## one in `userConfigDir`. "" when there is none — a fresh install, which
    ## is the default setting. Like the desktop's walk it stops below the
    ## filesystem root: `/` itself is never searched.
    var dir = startDir
    while dir.len > 0:
      if fileExists(dir / fileName): return dir / fileName
      let parent = dir.parentDir
      if parent.len == 0 or parent == dir or parent == "/": break
      dir = parent
    if fileExists(userConfigDir / fileName): userConfigDir / fileName
    else: ""
