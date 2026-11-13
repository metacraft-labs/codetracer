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

func terminalWords(which: LayoutSetting): seq[string] =
  ## §5.3's settings and their words, as this suite reads the spec; empty for
  ## a setting the terminal does not own. Production's `isTerminalSetting`
  ## and `settingValues` are checked against it, not derived from it.
  ## No `else`: a new `LayoutSetting` does not compile until it is entered
  ## here as the terminal's or not, so neither the ownership check nor the
  ## counts below can pass it by.
  case which
  of lsModernUnicode: @["off", "on", "auto"]
  of lsGlyphs: @["auto", "ascii", "basic", "extended"]
  of lsAmbiguousWidth: @["auto", "narrow", "wide"]
  of lsColors: @["auto", "truecolor", "256", "16", "mono"]
  of lsTerminalProbe: @["on", "off"]
  of lsReduceMotion: @["auto", "on", "off"]
  of lsPointerShapes: @["auto", "on", "off"]
  of lsScreenReader: @["auto", "on", "off"]
  of lsTerminalHints: @["on", "off"]
  of lsFocusHighlight, lsLiveResize, lsOverflowMarkers, lsScrollbarThickness,
     lsScrollbarFade, lsScrollbarTrack, lsScrollbarClick,
     lsMultiClickInterval, lsWordSeparators: @[]

func ownedByTerminal(which: LayoutSetting): bool =
  terminalWords(which).len > 0

var sweptAssertions = 0
template swept(cond: untyped) =
  ## One assertion of the per-setting sweep. Tallied apart from `CHECKS`
  ## because its number follows the settings, and is checked against
  ## `ExpectedSweptAssertions` rather than a hand-kept constant.
  inc sweptAssertions
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 26
  ## The assertions whose number does not depend on how many settings there
  ## are. The sweep in the first case is not in it: until 2026-11-13 it was,
  ## and a new terminal setting (`screen-reader`) turned the suite red until
  ## the number and the suite's own list of terminal settings were edited by
  ## hand.

const ExpectedSweptAssertions = block:
  ## Derived from `terminalWords`: a terminal setting costs one check of its
  ## words, one of its ownership, six for every word and one for a refused
  ## word; any other setting costs one check that the terminal does not own it.
  var n = 0
  for which in LayoutSetting:
    let words = terminalWords(which).len
    n += (if words > 0: 3 + 6 * words else: 1)
  n

suite "PLAT-71: the terminal settings":

  test "§5.3's words, in every text form":
    var owned = 0
    for which in LayoutSetting:
      if not ownedByTerminal(which):
        swept not which.isTerminalSetting
        continue
      inc owned
      swept settingValues(which) == terminalWords(which)
      swept which.isTerminalSetting
      for value in settingValues(which):
        let flag = parseSettingFlag("--" & $which & "=" & value)
        swept flag.isFlag and flag.ok and flag.setting == which and
           flag.word == value
        let line = parseSetLine(":set " & $which & " " & value)
        swept line.isSet and line.ok and line.value == value
        let target = parseSettingCommandTarget(settingCommandTarget(which,
                                                                    value))
        swept target.ok and target.value == value
        var s = defaultLayoutSettings()
        swept s.assignValue(which, value)
        swept s.valueText(which) == value
        let back = decodeLayoutSettings(encodeLayoutSettings(s))
        swept back.ok and back.settings.valueText(which) == value
      swept not parseSettingFlag("--" & $which & "=sideways").ok
    # The sweep saw §5.3's settings, not an empty table.
    ck owned >= 9

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
    var listed = 0
    for which in LayoutSetting:
      listed += terminalWords(which).len
    ck terminalLabels == listed
    ck windowLabels == 0

  test "assertion count":
    echo "CHECKS: " & $(CHECKS + sweptAssertions)
    check CHECKS == ExpectedAssertions
    check sweptAssertions == ExpectedSweptAssertions
