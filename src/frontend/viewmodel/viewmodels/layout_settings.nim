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
##     and `modern-unicode`;
##   * the TERMINAL settings (PLAT-71, CodeTracer-TUI-Terminal-Adaptation.md
##     §5.3): `glyphs` (auto | ascii | basic | extended), `modern-unicode`
##     (off | on | auto — it governs ALL chrome, not only the scrollbars,
##     OQ-T9), `ambiguous-width` (auto | narrow | wide), `colors` (auto |
##     truecolor | 256 | 16 | mono), `terminal-probe` (on | off),
##     `reduce-motion` (auto | on | off) and `terminal-hints` (on | off).
##     They are the TERMINAL's (`isTerminalSetting`): the window front-end
##     draws with real fonts and offers none of them. Any of them may be
##     scoped to one terminal by a `[terminal "<glob>"]` section of the
##     remembered file (`ScopedSettings`, OQ-T6).
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
    lsGlyphs = "glyphs"
    lsAmbiguousWidth = "ambiguous-width"
    lsColors = "colors"
    lsTerminalProbe = "terminal-probe"
    lsReduceMotion = "reduce-motion"
    lsTerminalHints = "terminal-hints"

  TerminalSettingWords* = object
    ## The terminal settings' value words (PLAT-71). `modern-unicode` lives
    ## here as a WORD (`off`, `on`, `auto`): what it resolves to on a given
    ## terminal is the capability profile's decision, which then sets
    ## `ScrollbarOptions.modernUnicode`.
    glyphs*: string
    modernUnicode*: string
    ambiguousWidth*: string
    colors*: string
    terminalProbe*: string
    reduceMotion*: string
    terminalHints*: string

  ScopedSettings* = object
    ## A `[terminal "<glob>"]` section: the settings it scopes to the
    ## terminals whose identity matches `glob`.
    glob*: string
    values*: seq[(LayoutSetting, string)]

  LayoutSettings* = object
    focusHighlight*: bool
    liveResize*: bool
    overflowMarkers*: bool
    scrollbars*: ScrollbarOptions
    terminal*: TerminalSettingWords
    scoped*: seq[ScopedSettings]

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

const
  DefaultTerminalSettingWords* = TerminalSettingWords(
    glyphs: "auto", modernUnicode: "off", ambiguousWidth: "auto",
    colors: "auto", terminalProbe: "on", reduceMotion: "auto",
    terminalHints: "on")
    ## §5.3's defaults. `modern-unicode` is `off` (the user's decision).

func defaultLayoutSettings*(overflowMarkers = true): LayoutSettings =
  ## The highlight shows, the divider reflows live; the overflow markers are
  ## the front-end's default (on in the terminal, off in GPUI — OQ-H1).
  LayoutSettings(focusHighlight: true, liveResize: true,
                 overflowMarkers: overflowMarkers,
                 scrollbars: DefaultScrollbarOptions,
                 terminal: DefaultTerminalSettingWords)

func isTerminalSetting*(which: LayoutSetting): bool =
  ## PLAT-71: a setting only the terminal front-end has (§5.3).
  which in {lsModernUnicode, lsGlyphs, lsAmbiguousWidth, lsColors,
            lsTerminalProbe, lsReduceMotion, lsTerminalHints}

func isOnOff*(which: LayoutSetting): bool =
  ## Whether the setting is on / off (else it takes `settingValues`).
  which notin {lsScrollbarThickness, lsScrollbarClick, lsModernUnicode,
               lsGlyphs, lsAmbiguousWidth, lsColors, lsReduceMotion}

func settingValues*(which: LayoutSetting): seq[string] =
  ## The words the setting takes, in the order the omnibox lists them.
  case which
  of lsScrollbarThickness:
    for t in BarThickness: result.add $t
  of lsScrollbarClick:
    for r in TrackClickRule: result.add $r
  of lsModernUnicode: result = @["off", "on", "auto"]
  of lsGlyphs: result = @["auto", "ascii", "basic", "extended"]
  of lsAmbiguousWidth: result = @["auto", "narrow", "wide"]
  of lsColors: result = @["auto", "truecolor", "256", "16", "mono"]
  of lsReduceMotion: result = @["auto", "on", "off"]
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
  of lsModernUnicode: s.terminal.modernUnicode
  of lsGlyphs: s.terminal.glyphs
  of lsAmbiguousWidth: s.terminal.ambiguousWidth
  of lsColors: s.terminal.colors
  of lsTerminalProbe: s.terminal.terminalProbe
  of lsReduceMotion: s.terminal.reduceMotion
  of lsTerminalHints: s.terminal.terminalHints

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
  of lsModernUnicode:
    s.terminal.modernUnicode = v
    # On an extended, narrow terminal `on` is what it resolves to; the
    # terminal front-end re-decides it from its profile (`auto` too).
    s.scrollbars.modernUnicode = v == "on"
  of lsGlyphs: s.terminal.glyphs = v
  of lsAmbiguousWidth: s.terminal.ambiguousWidth = v
  of lsColors: s.terminal.colors = v
  of lsTerminalProbe: s.terminal.terminalProbe = v
  of lsReduceMotion: s.terminal.reduceMotion = v
  of lsTerminalHints: s.terminal.terminalHints = v
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
  ## The remembered preference's text: one `name=value` line per setting,
  ## then each `[terminal "<glob>"]` section with the settings it scopes.
  for which in LayoutSetting:
    result.add $which & "=" & s.valueText(which) & "\n"
  for scope in s.scoped:
    if scope.values.len == 0:
      continue
    result.add "[terminal \"" & scope.glob & "\"]\n"
    for (which, value) in scope.values:
      result.add $which & "=" & value & "\n"

func parseSectionHeader*(line: string): tuple[ok: bool; glob: string] =
  ## `[terminal "kitty*"]` -> `(true, "kitty*")`.
  let l = line.strip
  const prefix = "[terminal \""
  if l.startsWith(prefix) and l.endsWith("\"]") and
     l.len > prefix.len + 2:
    return (true, l[prefix.len ..< l.len - 2])
  (false, "")

proc setScoped*(s: var LayoutSettings; glob: string; which: LayoutSetting;
                value: string): bool =
  ## Remember `which = value` for the terminals `glob` matches (a
  ## `[terminal "<glob>"]` section). Only a terminal setting can be scoped.
  if not which.isTerminalSetting:
    return false
  let (ok, v) = parseValue(which, value)
  if not ok:
    return false
  for scope in s.scoped.mitems:
    if scope.glob == glob:
      for entry in scope.values.mitems:
        if entry[0] == which:
          entry[1] = v
          return true
      scope.values.add (which, v)
      return true
  s.scoped.add ScopedSettings(glob: glob, values: @[(which, v)])
  true

func decodeLayoutSettings*(text: string; defaults = defaultLayoutSettings()):
    tuple[ok: bool; settings: LayoutSettings; message: string] =
  ## The remembered preference, read back. Lines it does not know are
  ## refused by name (never silently dropped); a setting it does not mention
  ## keeps the default.
  result = (true, defaults, "")
  var section = ""
  for raw in text.splitLines():
    let line = raw.strip
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("["):
      let (isHeader, glob) = parseSectionHeader(line)
      if not isHeader:
        return (false, defaults, "not a section header: '" & line & "'")
      section = glob
      continue
    let at = line.find('=')
    if at < 0:
      return (false, defaults, "not a setting line: '" & line & "'")
    let (known, which) = parseSettingName(line[0 ..< at])
    if section.len > 0:
      if not known or not result.settings.setScoped(section, which,
                                                    line[at + 1 .. ^1]):
        return (false, defaults, "not a terminal setting in [terminal \"" &
                section & "\"]: '" & line & "'")
      continue
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
    of lsGlyphs: "Terminal glyphs"
    of lsAmbiguousWidth: "Ambiguous-width characters"
    of lsColors: "Terminal colours"
    of lsTerminalProbe: "Terminal probe"
    of lsReduceMotion: "Reduce motion"
    of lsTerminalHints: "Terminal hints"
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
