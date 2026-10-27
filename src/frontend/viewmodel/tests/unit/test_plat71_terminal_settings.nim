## test_plat71_terminal_settings.nim — PLAT-71 (CodeTracer-TUI-Terminal-
## Adaptation.md §5.3): the terminal's settings, as the shared layout
## settings carry them.
##
##   * every terminal setting takes exactly §5.3's words, through every text
##     form — the flag, the `:set` line, the omnibox target, the remembered
##     `name=value` line;
##   * `modern-unicode` is `off | on | auto` with `off` the default (the
##     user's decision), and it is the TERMINAL's (OQ-T9);
##   * a `[terminal "<glob>"]` section scopes a terminal setting to one
##     terminal and round-trips through the remembered file; a setting that
##     is not a terminal one is refused inside a section, by name;
##   * the window front-end offers none of the terminal settings in its
##     omnibox (`layoutSettingCommands(terminalSettings = false)`).
##
## Pure values; no mocks.

import std/[strutils, unittest]

import viewmodels/layout_settings
import viewmodels/omnibar_sources

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 184

const TerminalSettings = [lsModernUnicode, lsGlyphs, lsAmbiguousWidth,
                          lsColors, lsTerminalProbe, lsReduceMotion,
                          lsTerminalHints]

suite "PLAT-71: the terminal settings":

  test "§5.3's words, in every text form":
    ck settingValues(lsGlyphs) == @["auto", "ascii", "basic", "extended"]
    ck settingValues(lsModernUnicode) == @["off", "on", "auto"]
    ck settingValues(lsAmbiguousWidth) == @["auto", "narrow", "wide"]
    ck settingValues(lsColors) == @["auto", "truecolor", "256", "16", "mono"]
    ck settingValues(lsTerminalProbe) == @["on", "off"]
    ck settingValues(lsReduceMotion) == @["auto", "on", "off"]
    for which in TerminalSettings:
      ck which.isTerminalSetting
      for value in settingValues(which):
        let flag = parseSettingFlag("--" & $which & "=" & value)
        ck flag.isFlag and flag.ok and flag.setting == which and
           flag.word == value
        let line = parseSetLine(":set " & $which & " " & value)
        ck line.isSet and line.ok and line.value == value
        let target = parseSettingCommandTarget(settingCommandTarget(which,
                                                                    value))
        ck target.ok and target.value == value
        var s = defaultLayoutSettings()
        ck s.assignValue(which, value)
        ck s.valueText(which) == value
        let back = decodeLayoutSettings(encodeLayoutSettings(s))
        ck back.ok and back.settings.valueText(which) == value
      ck not parseSettingFlag("--" & $which & "=sideways").ok
    for which in LayoutSetting:
      if which notin TerminalSettings:
        ck not which.isTerminalSetting

  test "modern-unicode: off by default, auto a value, owned by the terminal":
    let d = defaultLayoutSettings()
    ck d.valueText(lsModernUnicode) == "off"
    ck not d.scrollbars.modernUnicode
    var s = d
    ck s.assignValue(lsModernUnicode, "on")
    ck s.scrollbars.modernUnicode
    ck s.assignValue(lsModernUnicode, "auto")
    ck s.valueText(lsModernUnicode) == "auto"
    # `auto` is the terminal profile's to resolve; the shared options say
    # nothing is drawn until it does.
    ck not s.scrollbars.modernUnicode
    # A remembered file from before PLAT-71 (on / off only) still reads.
    ck decodeLayoutSettings("modern-unicode=on\n").settings.scrollbars.modernUnicode

  test "a [terminal \"<glob>\"] section scopes a terminal setting":
    var s = defaultLayoutSettings()
    ck s.setScoped("kitty*", lsModernUnicode, "on")
    ck s.setScoped("kitty*", lsGlyphs, "basic")
    ck s.setScoped("kitty*", lsModernUnicode, "auto")   # replaced, not added
    ck s.setScoped("foot", lsAmbiguousWidth, "wide")
    ck not s.setScoped("foot", lsFocusHighlight, "off")
    ck not s.setScoped("foot", lsGlyphs, "sideways")
    ck s.scoped.len == 2
    ck s.scoped[0].values == @[(lsModernUnicode, "auto"), (lsGlyphs, "basic")]
    let text = encodeLayoutSettings(s)
    ck text.contains("[terminal \"kitty*\"]\nmodern-unicode=auto\nglyphs=basic\n")
    let back = decodeLayoutSettings(text)
    ck back.ok
    ck back.settings.scoped == s.scoped
    # The global value is untouched by a section.
    ck back.settings.valueText(lsModernUnicode) == "off"
    let refused = decodeLayoutSettings(
      "[terminal \"x\"]\nfocus-highlight=off\n")
    ck not refused.ok and refused.message.contains("not a terminal setting")
    ck not decodeLayoutSettings("[nonsense\n").ok
    ck parseSectionHeader("[terminal \"tmux>*\"]") == (true, "tmux>*")

  test "the window front-end offers no terminal setting":
    var terminalLabels, windowLabels = 0
    for e in layoutSettingCommands(terminalSettings = true):
      if parseSettingCommandTarget(e.target).ok and
         parseSettingCommandTarget(e.target).setting.isTerminalSetting:
        inc terminalLabels
    for e in layoutSettingCommands(terminalSettings = false):
      let t = parseSettingCommandTarget(e.target)
      if t.ok and t.setting.isTerminalSetting:
        inc windowLabels
    ck terminalLabels == 3 + 4 + 3 + 5 + 2 + 3 + 2
    ck windowLabels == 0

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
