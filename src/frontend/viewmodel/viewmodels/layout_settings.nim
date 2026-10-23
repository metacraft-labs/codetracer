## viewmodels/layout_settings.nim — PLAT-51 deliverables 9 and 11: the
## LAYOUT PREFERENCES the native front-ends share, as values.
##
##   * `focus-highlight` (Native-Front-End-Parity.md §2): whether the focused
##     pane's tab strip takes the focus colour and its ring is drawn;
##   * `live-resize` (Layout-ViewModel §4.3a): whether dragging a divider
##     reflows the panes at every pointer position (the default) or draws a
##     guide and reflows on release;
##   * `overflow-markers` (PLAT-70, Horizontal-Overflow.md §4.6): whether a
##     text pane's rows cut by its horizontal view show `‹` / `›`. On by
##     default in the terminal, off in GPUI (OQ-H1) — the one setting whose
##     default is the front-end's (`defaultLayoutSettings(overflowMarkers)`);
##   * the scrollbar options (PLAT-70 Part H, Scrollbar-Scrubbers.md §7.1):
##     `scrollbar-thickness` (hairline | thin | thick | full),
##     `scrollbar-fade`, `scrollbar-track`, `scrollbar-click` (jump | page)
##     and `modern-unicode`.
##
## A setting is on / off, or takes one of a list of VALUES
## (`settingValues`); every text form — the flag, the `:set` line, the
## omnibox target and the remembered `name=value` line — carries the value's
## word, so the two kinds share one parser.
##
## Each is decided three ways, in increasing order of reach: a CLI flag
## (`--focus-highlight=on|off`, `--live-resize=on|off`) for one session; a
## command (`:set focus-highlight off`, the same through the omnibox's
## commands) that also REMEMBERS the choice; and the remembered preference,
## read at start-up (`host/layout_preferences.nim`, beside each product's
## remembered layout). The flag beats the preference for its session.
##
## Pure: the terminal and the GPUI window parse the same words and offer the
## same omnibox commands. C and JavaScript backends.

import std/strutils

import ./scrollbar_interaction

export scrollbar_interaction

type
  LayoutSetting* = enum
    lsFocusHighlight = "focus-highlight"
    lsLiveResize = "live-resize"
    lsOverflowMarkers = "overflow-markers"
    lsScrollbarThickness = "scrollbar-thickness"
    lsScrollbarFade = "scrollbar-fade"
    lsScrollbarTrack = "scrollbar-track"
    lsScrollbarClick = "scrollbar-click"
    lsModernUnicode = "modern-unicode"

  LayoutSettings* = object
    focusHighlight*: bool
    liveResize*: bool
    overflowMarkers*: bool
    scrollbars*: ScrollbarOptions

  SettingOverride* = enum
    ## A CLI flag's answer for one setting. The zero value is "not given".
    soUnset = "unset"
    soOn = "on"
    soOff = "off"

  SetLine* = object
    ## `:set <name> <value>`, parsed.
    isSet*: bool
      ## The line is a `set` command at all.
    ok*: bool
    setting*: LayoutSetting
    value*: string
      ## The value's word (`on`, `off`, `thick` …).
    on*: bool
      ## An on / off setting's value, as a bool.
    message*: string
      ## Why it was refused, or what it reports when it only asked.

const
  LayoutSettingCommandPrefix* = "layoutSetting:"
    ## The omnibox entries' target prefix: `layoutSetting:<name>:<on|off>`.
  LayoutSettingTogglePrefix* = "layoutSettingToggle:"
    ## A palette entry that FLIPS a setting: `layoutSettingToggle:<name>`
    ## (**View: Toggle Overflow Markers**).
  ToggleOverflowMarkersLabel* = "View: Toggle Overflow Markers"
    ## Horizontal-Overflow.md §4.6's palette entry.

func defaultLayoutSettings*(overflowMarkers = true): LayoutSettings =
  ## The highlight shows, the divider reflows live; the overflow markers are
  ## the front-end's default (on in the terminal, off in GPUI — OQ-H1).
  LayoutSettings(focusHighlight: true, liveResize: true,
                 overflowMarkers: overflowMarkers,
                 scrollbars: DefaultScrollbarOptions)

func isOnOff*(which: LayoutSetting): bool =
  ## Whether the setting is on / off (else it takes `settingValues`).
  which notin {lsScrollbarThickness, lsScrollbarClick}

func settingValues*(which: LayoutSetting): seq[string] =
  ## The words the setting takes, in the order the omnibox lists them.
  case which
  of lsScrollbarThickness:
    for t in BarThickness: result.add $t
  of lsScrollbarClick:
    for r in TrackClickRule: result.add $r
  else: result = @["on", "off"]

func valuesText(which: LayoutSetting): string =
  let v = settingValues(which)
  if v.len == 2: v[0] & " or " & v[1]
  else: v[0 ..< v.len - 1].join(", ") & " or " & v[^1]

func settingNames*(): string =
  var parts: seq[string] = @[]
  for s in LayoutSetting:
    parts.add $s
  parts.join(", ")

func parseSettingName*(word: string): tuple[ok: bool; setting: LayoutSetting] =
  for s in LayoutSetting:
    if $s == word.strip.toLowerAscii:
      return (true, s)
  (false, lsFocusHighlight)

func parseOnOff*(word: string): tuple[ok: bool; on: bool] =
  case word.strip.toLowerAscii
  of "on", "true", "yes", "1": (true, true)
  of "off", "false", "no", "0": (true, false)
  else: (false, false)

func parseValue*(which: LayoutSetting; word: string):
    tuple[ok: bool; value: string] =
  ## A word for `which`, as its canonical value word.
  if which.isOnOff:
    let (ok, on) = parseOnOff(word)
    return (ok, (if on: "on" else: "off"))
  let w = word.strip.toLowerAscii
  for v in settingValues(which):
    if v == w:
      return (true, v)
  (false, "")

func onOffWord(on: bool): string = (if on: "on" else: "off")

func valueText*(s: LayoutSettings; which: LayoutSetting): string =
  ## The setting's current value, as its word.
  case which
  of lsFocusHighlight: onOffWord(s.focusHighlight)
  of lsLiveResize: onOffWord(s.liveResize)
  of lsOverflowMarkers: onOffWord(s.overflowMarkers)
  of lsScrollbarThickness: $s.scrollbars.thickness
  of lsScrollbarFade: onOffWord(s.scrollbars.fade)
  of lsScrollbarTrack: onOffWord(s.scrollbars.track)
  of lsScrollbarClick: $s.scrollbars.click
  of lsModernUnicode: onOffWord(s.scrollbars.modernUnicode)

proc assignValue*(s: var LayoutSettings; which: LayoutSetting;
                  value: string): bool =
  ## Set `which` from a value word; false (and nothing changed) when the word
  ## is not one of its values.
  let (ok, v) = parseValue(which, value)
  if not ok:
    return false
  let on = v == "on"
  case which
  of lsFocusHighlight: s.focusHighlight = on
  of lsLiveResize: s.liveResize = on
  of lsOverflowMarkers: s.overflowMarkers = on
  of lsScrollbarFade: s.scrollbars.fade = on
  of lsScrollbarTrack: s.scrollbars.track = on
  of lsModernUnicode: s.scrollbars.modernUnicode = on
  of lsScrollbarThickness:
    for t in BarThickness:
      if $t == v: s.scrollbars.thickness = t
  of lsScrollbarClick:
    for r in TrackClickRule:
      if $r == v: s.scrollbars.click = r
  true

func valueOf*(s: LayoutSettings; which: LayoutSetting): bool =
  ## An on / off setting's value.
  s.valueText(which) == "on"

proc assign*(s: var LayoutSettings; which: LayoutSetting; on: bool) =
  ## Set an on / off setting.
  discard s.assignValue(which, onOffWord(on))

func describe*(which: LayoutSetting; value: string): string =
  $which & " " & value

func describe*(which: LayoutSetting; on: bool): string =
  describe(which, onOffWord(on))

func parseSetLine*(line: string): SetLine =
  ## `set focus-highlight off` (with or without the leading `:`). A line that
  ## is not a `set` command answers `isSet: false`; one that is, but names an
  ## unknown setting or value, is refused by name.
  var text = line.strip
  if text.startsWith(":"):
    text = text[1 .. ^1].strip
  let words = text.splitWhitespace()
  if words.len == 0 or words[0] != "set":
    return SetLine(isSet: false)
  result = SetLine(isSet: true)
  if words.len < 2:
    result.message = ":set needs a setting (" & settingNames() & ")"
    return
  let (known, which) = parseSettingName(words[1])
  if not known:
    result.message = "unknown setting '" & words[1] & "'; the settings are " &
                     settingNames()
    return
  result.setting = which
  if words.len < 3:
    result.message = ":set " & $which & " needs " & valuesText(which)
    return
  let (okValue, value) = parseValue(which, words[2])
  if not okValue:
    result.message = "unknown value '" & words[2] & "' for " & $which &
                     "; use " & valuesText(which)
    return
  result.ok = true
  result.value = value
  result.on = value == "on"

func parseSettingFlag*(arg: string): tuple[isFlag, ok: bool;
                                           setting: LayoutSetting;
                                           value: SettingOverride;
                                           word: string;
                                           message: string] =
  ## `--focus-highlight=on|off`, `--scrollbar-thickness=thin` … `value` is an
  ## on / off setting's answer (`soOn` for any value of a valued one); `word`
  ## the value's word for every setting.
  for which in LayoutSetting:
    let prefix = "--" & $which & "="
    if arg == "--" & $which:
      var choices: seq[string] = @[]
      for v in settingValues(which): choices.add "=" & v
      return (true, false, which, soUnset, "",
              "'" & arg & "' needs a value: " &
                choices[0 ..< choices.len - 1].join(", ") & " or " &
                choices[^1])
    if arg.startsWith(prefix):
      let (ok, value) = parseValue(which, arg[prefix.len .. ^1])
      if not ok:
        return (true, false, which, soUnset, "",
                "'" & arg & "': " & $which & " takes " & valuesText(which))
      let o = if which.isOnOff and value == "off": soOff else: soOn
      return (true, true, which, o, value, "")
  (false, false, lsFocusHighlight, soUnset, "", "")

proc applyOverride*(s: var LayoutSettings; which: LayoutSetting;
                    o: SettingOverride) =
  case o
  of soUnset: discard
  of soOn: s.assign(which, true)
  of soOff: s.assign(which, false)

proc applyOverride*(s: var LayoutSettings; which: LayoutSetting;
                    word: string) =
  ## A flag's value word for any setting; "" leaves it.
  if word.len > 0:
    discard s.assignValue(which, word)

func encodeLayoutSettings*(s: LayoutSettings): string =
  ## The remembered preference's text: one `name=value` line per setting.
  for which in LayoutSetting:
    result.add $which & "=" & s.valueText(which) & "\n"

func decodeLayoutSettings*(text: string; defaults = defaultLayoutSettings()):
    tuple[ok: bool; settings: LayoutSettings; message: string] =
  ## The remembered preference, read back. Lines it does not know are
  ## refused by name (never silently dropped); a setting it does not mention
  ## keeps the default.
  result = (true, defaults, "")
  for raw in text.splitLines():
    let line = raw.strip
    if line.len == 0 or line.startsWith("#"):
      continue
    let at = line.find('=')
    if at < 0:
      return (false, defaults, "not a setting line: '" & line & "'")
    let (known, which) = parseSettingName(line[0 ..< at])
    if not known or not result.settings.assignValue(which, line[at + 1 .. ^1]):
      return (false, defaults,
              "unknown stored setting '" & line & "'")

func settingCommandTarget*(which: LayoutSetting; value: string): string =
  LayoutSettingCommandPrefix & $which & ":" & value

func settingCommandTarget*(which: LayoutSetting; on: bool): string =
  settingCommandTarget(which, onOffWord(on))

func parseSettingCommandTarget*(target: string): tuple[ok: bool;
                                                      setting: LayoutSetting;
                                                      on: bool;
                                                      value: string] =
  ## `layoutSetting:<name>:<value>` -> its parts.
  if not target.startsWith(LayoutSettingCommandPrefix):
    return (false, lsFocusHighlight, false, "")
  let rest = target[LayoutSettingCommandPrefix.len .. ^1].split(':')
  if rest.len != 2:
    return (false, lsFocusHighlight, false, "")
  let (known, which) = parseSettingName(rest[0])
  if not known:
    return (false, lsFocusHighlight, false, "")
  let (okValue, value) = parseValue(which, rest[1])
  if not okValue:
    return (false, lsFocusHighlight, false, "")
  (true, which, value == "on", value)

func settingCommandLabel*(which: LayoutSetting; value: string): string =
  ## What the omnibox lists: `Focus highlight: off`, `Scrollbar thickness:
  ## thin`.
  let name = case which
    of lsFocusHighlight: "Focus highlight"
    of lsLiveResize: "Live resize"
    of lsOverflowMarkers: "Overflow markers"
    of lsScrollbarThickness: "Scrollbar thickness"
    of lsScrollbarFade: "Scrollbar fade"
    of lsScrollbarTrack: "Scrollbar track"
    of lsScrollbarClick: "Scrollbar click"
    of lsModernUnicode: "Modern Unicode glyphs"
  name & ": " & value

func settingCommandLabel*(which: LayoutSetting; on: bool): string =
  settingCommandLabel(which, onOffWord(on))

func settingToggleTarget*(which: LayoutSetting): string =
  LayoutSettingTogglePrefix & $which

func parseSettingToggleTarget*(target: string): tuple[ok: bool;
                                                     setting: LayoutSetting] =
  ## `layoutSettingToggle:<name>` -> the setting it flips.
  if not target.startsWith(LayoutSettingTogglePrefix):
    return (false, lsFocusHighlight)
  parseSettingName(target[LayoutSettingTogglePrefix.len .. ^1])
