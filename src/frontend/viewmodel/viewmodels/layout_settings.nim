## viewmodels/layout_settings.nim — PLAT-51 deliverables 9 and 11: the two
## LAYOUT PREFERENCES the native front-ends share, as values.
##
##   * `focus-highlight` (Native-Front-End-Parity.md §2): whether the focused
##     pane's tab strip takes the focus colour and its ring is drawn;
##   * `live-resize` (Layout-ViewModel §4.3a): whether dragging a divider
##     reflows the panes at every pointer position (the default) or draws a
##     guide and reflows on release.
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

type
  LayoutSetting* = enum
    lsFocusHighlight = "focus-highlight"
    lsLiveResize = "live-resize"

  LayoutSettings* = object
    focusHighlight*: bool
    liveResize*: bool

  SettingOverride* = enum
    ## A CLI flag's answer for one setting. The zero value is "not given".
    soUnset = "unset"
    soOn = "on"
    soOff = "off"

  SetLine* = object
    ## `:set <name> on|off`, parsed.
    isSet*: bool
      ## The line is a `set` command at all.
    ok*: bool
    setting*: LayoutSetting
    on*: bool
    message*: string
      ## Why it was refused, or what it reports when it only asked.

const
  LayoutSettingCommandPrefix* = "layoutSetting:"
    ## The omnibox entries' target prefix: `layoutSetting:<name>:<on|off>`.

func defaultLayoutSettings*(): LayoutSettings =
  ## Both on: the highlight shows, the divider reflows live.
  LayoutSettings(focusHighlight: true, liveResize: true)

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

func valueOf*(s: LayoutSettings; which: LayoutSetting): bool =
  case which
  of lsFocusHighlight: s.focusHighlight
  of lsLiveResize: s.liveResize

proc assign*(s: var LayoutSettings; which: LayoutSetting; on: bool) =
  case which
  of lsFocusHighlight: s.focusHighlight = on
  of lsLiveResize: s.liveResize = on

func describe*(which: LayoutSetting; on: bool): string =
  $which & " " & (if on: "on" else: "off")

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
    result.message = ":set " & $which & " needs on or off"
    return
  let (okValue, on) = parseOnOff(words[2])
  if not okValue:
    result.message = "unknown value '" & words[2] & "' for " & $which &
                     "; use on or off"
    return
  result.ok = true
  result.on = on

func parseSettingFlag*(arg: string): tuple[isFlag, ok: bool;
                                           setting: LayoutSetting;
                                           value: SettingOverride;
                                           message: string] =
  ## `--focus-highlight=on|off` / `--live-resize=on|off`.
  for which in LayoutSetting:
    let prefix = "--" & $which & "="
    if arg == "--" & $which:
      return (true, false, which, soUnset,
              "'" & arg & "' needs a value: =on or =off")
    if arg.startsWith(prefix):
      let (ok, on) = parseOnOff(arg[prefix.len .. ^1])
      if not ok:
        return (true, false, which, soUnset,
                "'" & arg & "': " & $which & " takes on or off")
      return (true, true, which, (if on: soOn else: soOff), "")
  (false, false, lsFocusHighlight, soUnset, "")

proc applyOverride*(s: var LayoutSettings; which: LayoutSetting;
                    o: SettingOverride) =
  case o
  of soUnset: discard
  of soOn: s.assign(which, true)
  of soOff: s.assign(which, false)

func encodeLayoutSettings*(s: LayoutSettings): string =
  ## The remembered preference's text: one `name=on|off` line per setting.
  for which in LayoutSetting:
    result.add $which & "=" & (if s.valueOf(which): "on" else: "off") & "\n"

func decodeLayoutSettings*(text: string): tuple[ok: bool;
                                                settings: LayoutSettings;
                                                message: string] =
  ## The remembered preference, read back. Lines it does not know are
  ## refused by name (never silently dropped); a setting it does not mention
  ## keeps the default.
  result = (true, defaultLayoutSettings(), "")
  for raw in text.splitLines():
    let line = raw.strip
    if line.len == 0 or line.startsWith("#"):
      continue
    let at = line.find('=')
    if at < 0:
      return (false, defaultLayoutSettings(), "not a setting line: '" & line & "'")
    let (known, which) = parseSettingName(line[0 ..< at])
    let (okValue, on) = parseOnOff(line[at + 1 .. ^1])
    if not known or not okValue:
      return (false, defaultLayoutSettings(),
              "unknown stored setting '" & line & "'")
    result.settings.assign(which, on)

func settingCommandTarget*(which: LayoutSetting; on: bool): string =
  LayoutSettingCommandPrefix & $which & ":" & (if on: "on" else: "off")

func parseSettingCommandTarget*(target: string): tuple[ok: bool;
                                                      setting: LayoutSetting;
                                                      on: bool] =
  ## `layoutSetting:<name>:<on|off>` -> its parts.
  if not target.startsWith(LayoutSettingCommandPrefix):
    return (false, lsFocusHighlight, false)
  let rest = target[LayoutSettingCommandPrefix.len .. ^1].split(':')
  if rest.len != 2:
    return (false, lsFocusHighlight, false)
  let (known, which) = parseSettingName(rest[0])
  let (okValue, on) = parseOnOff(rest[1])
  if not known or not okValue:
    return (false, lsFocusHighlight, false)
  (true, which, on)

func settingCommandLabel*(which: LayoutSetting; on: bool): string =
  ## What the omnibox lists: `Focus highlight: off`.
  let name = case which
    of lsFocusHighlight: "Focus highlight"
    of lsLiveResize: "Live resize"
  name & ": " & (if on: "on" else: "off")
