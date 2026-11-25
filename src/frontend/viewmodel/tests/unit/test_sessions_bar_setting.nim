## The sessions bar's setting (`sessions_bar_setting`): the top-level
## `sessionsBar:` and `sessionsBarOverflow:` entries of a configuration
## file, read into where the bar is drawn and what it does with the tabs
## that do not fit.
##
## Each case reads a real configuration text with the production reader; no
## test doubles are used. The expected settings and problem words are
## written out by hand.

import std/[strutils, unittest]
import ../../viewmodels/sessions_bar_setting

proc read(text: string): tuple[setting: SessionsBarSetting; problems: seq[string]] =
  sessionsBarSettingOfConfigText(text)

suite "the sessions bar's setting":
  test "without either entry the bar is at the bottom and wraps onto rows":
    let none = read("")
    check none.setting.placement == sbpBottom
    check none.setting.overflow == sboRows
    check none.problems.len == 0
    let other = read("theme: dark\nbuild:\n  autoReveal: true\n")
    check other.setting == SessionsBarSetting(placement: sbpBottom, overflow: sboRows)
    check other.problems.len == 0
    check DefaultSessionsBarSetting.placement == sbpBottom
    check DefaultSessionsBarSetting.overflow == sboRows

  test "a missing entry keeps its default while the other is read":
    let onlyOverflow = read("sessionsBarOverflow: popup\n")
    check onlyOverflow.setting.placement == sbpBottom
    check onlyOverflow.setting.overflow == sboPopup
    check onlyOverflow.problems.len == 0
    let onlyPlacement = read("sessionsBar: top\n")
    check onlyPlacement.setting.placement == sbpTop
    check onlyPlacement.setting.overflow == sboRows
    check onlyPlacement.problems.len == 0

  test "each placement and each overflow":
    for (word, placement) in [("bottom", sbpBottom), ("top", sbpTop), ("panel", sbpPanel)]:
      for (oword, overflow) in [("rows", sboRows), ("popup", sboPopup)]:
        let r = read("sessionsBar: " & word & "\nsessionsBarOverflow: " & oword & "\n")
        check r.setting == SessionsBarSetting(placement: placement, overflow: overflow)
        check r.problems.len == 0

  test "values in any letter case, quoted, and followed by a comment":
    let r = read("""
# where the session tabs go
sessionsBar: "TOP"   # beside the omnibox
sessionsBarOverflow: 'Popup' # one line
""")
    check r.setting == SessionsBarSetting(placement: sbpTop, overflow: sboPopup)
    check r.problems.len == 0
    let commentedOut = read("# sessionsBar: top\nsessionsBar: panel\n")
    check commentedOut.setting.placement == sbpPanel
    check commentedOut.problems.len == 0

  test "an unknown value keeps the default and is named in exactly one problem":
    let r = read("sessionsBar: left\n")
    check r.setting == DefaultSessionsBarSetting
    check r.problems.len == 1
    check "sessionsBar" in r.problems[0]
    check "'left'" in r.problems[0]
    let o = read("sessionsBar: top\nsessionsBarOverflow: scroll\n")
    check o.setting.placement == sbpTop
    check o.setting.overflow == sboRows
    check o.problems.len == 1
    check "sessionsBarOverflow" in o.problems[0]
    check "'scroll'" in o.problems[0]
    let both = read("sessionsBar: middle\nsessionsBarOverflow: wrap\n")
    check both.setting == DefaultSessionsBarSetting
    check both.problems.len == 2

  test "a value is a whole word, not its first word or a prefix":
    for value in ["top bar", "top-bar", "topp", "to", "rows please"]:
      let r = read("sessionsBar: " & value & "\n")
      check r.setting.placement == sbpBottom
      check r.problems.len == 1
    let r = read("sessionsBarOverflow: popup menu\n")
    check r.setting.overflow == sboRows
    check r.problems.len == 1
    let empty = read("sessionsBar:\n")
    check empty.setting.placement == sbpBottom
    check empty.problems.len == 1

  test "an indented entry belongs to another key and is not read":
    let r = read("ui:\n  sessionsBar: top\n  sessionsBarOverflow: popup\n")
    check r.setting == DefaultSessionsBarSetting
    check r.problems.len == 0

  test "an entry given twice takes its last value":
    let r = read("sessionsBar: top\nsessionsBar: panel\n")
    check r.setting.placement == sbpPanel
    check r.problems.len == 0
