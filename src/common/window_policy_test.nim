## PLAT-69 (C5): the window policy both front-ends read — the `window:`
## setting's parse, its defaults, and how `--width` / `--height` override it.

import std/[os, strutils, unittest]
import ./window_policy

const ShippedConfig = staticRead("../config/default_config.yaml")

suite "window policy: the setting":

  test "no setting is the desktop's behaviour before the setting existed":
    let (s, problems) = windowSettingOfConfigText("theme: \"default_dark\"\n")
    check problems.len == 0
    check s == DefaultWindowSetting
    check s.initial == iwsMaximized
    check (s.width, s.height) == (1900, 1400)

  test "the shipped configuration states the default exactly":
    # The shipped file is what a fresh install copies into the user's
    # `.config.yaml`, so its entry must BE the default, not merely parse.
    check "\nwindow:\n" in ShippedConfig
    let (s, problems) = windowSettingOfConfigText(ShippedConfig)
    check problems.len == 0
    check s == DefaultWindowSetting

  test "a windowed setting with a size":
    let (s, problems) = windowSettingOfConfigText(
      "flow:\n  enabled: true\nwindow:\n  initial: windowed  # comment\n" &
      "  width: 1280\n  height: \"720\"\ntheme: x\n")
    check problems.len == 0
    check s.initial == iwsWindowed
    check (s.width, s.height) == (1280, 720)

  test "keys of other sections are not read as the window's":
    let (s, _) = windowSettingOfConfigText(
      "flow:\n  width: 1200\nwindow:\n  initial: windowed\nother:\n  height: 700\n")
    check (s.width, s.height) == (1900, 1400)

  test "a bad value is reported and only that value falls back":
    let (s, problems) = windowSettingOfConfigText(
      "window:\n  initial: fullscreen\n  width: 1300\n  height: tall\n")
    check s.initial == iwsMaximized
    check s.width == 1300
    check s.height == DefaultWindowHeight
    check problems.len == 2
    check "fullscreen" in problems.join("\n")
    check "tall" in problems.join("\n")

  test "a size below the minimum is raised to it, and said so":
    let (s, problems) = parseWindowSetting("windowed", 400, 300)
    check (s.width, s.height) == (MinWindowWidth, MinWindowHeight)
    check problems.len == 2

  test "a size that is no size falls back":
    let (s, problems) = parseWindowSetting("", -5, 100000)
    check (s.width, s.height) == (1900, 1400)
    check problems.len == 2

  test "unknown keys are reported, not silently ignored":
    let (_, problems) = windowSettingOfConfigText("window:\n  inital: windowed\n")
    check problems.len == 1
    check "inital" in problems[0]

suite "window policy: the launch":

  test "the default opens maximized, restoring to the desktop's size":
    let l = resolveWindowLaunch(DefaultWindowSetting)
    check l.maximized
    check (l.width, l.height) == (1900, 1400)
    check (l.minWidth, l.minHeight) == (1050, 600)
    check not l.explicitSize

  test "windowed opens at its size":
    let l = resolveWindowLaunch(WindowSetting(initial: iwsWindowed,
                                              width: 1500, height: 1000))
    check not l.maximized
    check (l.width, l.height) == (1500, 1000)

  test "an explicit size opens windowed at that size, whatever the setting":
    let l = resolveWindowLaunch(DefaultWindowSetting, 1920, 1080)
    check not l.maximized
    check l.explicitSize
    check (l.width, l.height) == (1920, 1080)

  test "one explicit dimension takes the other from the setting":
    let l = resolveWindowLaunch(DefaultWindowSetting, cliWidth = 1600)
    check not l.maximized
    check (l.width, l.height) == (1600, 1400)

  test "an explicit size below the minimum lowers the minimum":
    let l = resolveWindowLaunch(DefaultWindowSetting, 800, 500)
    check (l.width, l.height) == (800, 500)
    check (l.minWidth, l.minHeight) == (800, 500)

suite "window policy: which file":

  test "the nearest file up the tree, else the user's":
    let root = getTempDir() / ("window-policy-" & $getCurrentProcessId())
    let user = root / "user"
    let deep = root / "a" / "b"
    createDir(deep)
    createDir(user)
    defer: removeDir(root)
    check findUserConfigFile(deep, user) == ""
    writeFile(user / ".config.yaml", "window:\n  initial: windowed\n")
    check findUserConfigFile(deep, user) == user / ".config.yaml"
    writeFile(root / "a" / ".config.yaml", "")
    check findUserConfigFile(deep, user) == root / "a" / ".config.yaml"
