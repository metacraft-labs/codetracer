## viewmodels/sessions_bar_setting.nim
##
## Where the Agent Harbor sessions bar is drawn, and what it does with the
## sessions that do not fit: the two top-level entries of a configuration
## file,
##
##     sessionsBar: bottom          # bottom | top | panel
##     sessionsBarOverflow: rows    # rows | popup
##
## read into one value every front-end lays its frame out from.
##
## - `bottom` (the default) puts the session tabs in the status line, after
##   the status line's own words; `top` puts them in the top bar, after the
##   debugger controls and the omnibox; `panel` takes them out of both bars
##   and shows the sessions as a docked list instead.
## - `rows` (the default) lets the tabs that do not fit wrap onto extra rows
##   beside the bar, up to a cap; `popup` keeps the bar one line high and
##   lists the rest behind a `+N` chip.
##
## The reader is pure: it takes the file's text and answers the setting and
## the problems it found, so the configuration loader, the command line and
## the tests all read one rule. A missing entry is the default and is not a
## problem; a value it does not know leaves the default in place and adds
## exactly one problem naming the entry and the value, so a typo is reported
## instead of silently moving the bar.

import std/strutils

type
  SessionsBarPlacement* = enum
    ## Where the session tabs are drawn.
    sbpBottom = "bottom"
      ## In the status line, after its own words.
    sbpTop = "top"
      ## In the top bar, after the debugger controls and the omnibox.
    sbpPanel = "panel"
      ## In neither bar: a docked session list.

  SessionsBarOverflow* = enum
    ## What the bar does with the tabs that do not fit on its line.
    sboRows = "rows"
      ## Extra rows beside the bar, up to a cap; the rest behind `+N`.
    sboPopup = "popup"
      ## One line; the rest behind `+N`.

  SessionsBarSetting* = object
    placement*: SessionsBarPlacement
    overflow*: SessionsBarOverflow

const
  SessionsBarKey* = "sessionsBar"
    ## The configuration entry that names the placement.
  SessionsBarOverflowKey* = "sessionsBarOverflow"
    ## The configuration entry that names the overflow.
  DefaultSessionsBarSetting* = SessionsBarSetting(placement: sbpBottom,
                                                  overflow: sboRows)
    ## The bar sits in the status line and wraps onto rows: the status line
    ## is the one bar every layout keeps, so the tabs are where the reader
    ## already looks for the session's state.

proc wordOf[T: enum](value: string; found: var bool): T =
  ## The enum value spelled `value` (its string form, any letter case);
  ## `found` is false when no value is spelled so. The whole value must be
  ## the word: `top bar` is not `top`.
  found = false
  let word = value.toLowerAscii
  for v in T:
    if $v == word:
      found = true
      return v

proc valueOf(line: string; colon: int): string =
  ## The value after the entry's colon, without its comment, its blanks and
  ## its quotes.
  var value = line[colon + 1 .. ^1]
  let hash = value.find('#')
  if hash >= 0: value = value[0 ..< hash]
  value.strip.strip(chars = {'"', '\''}).strip

proc sessionsBarSettingOfConfigText*(text: string): tuple[
    setting: SessionsBarSetting; problems: seq[string]] =
  ## The sessions bar's setting from a configuration file's text: the
  ## top-level `sessionsBar:` and `sessionsBarOverflow:` entries. Entries
  ## nested under another key (indented) are not these. Values are read in
  ## any letter case, with or without quotes, and a `#` starts a comment.
  ## An entry given twice takes its last value.
  result.setting = DefaultSessionsBarSetting
  for raw in text.splitLines:
    if raw.len == 0 or raw[0] in {' ', '\t', '#'}:
      continue
    let colon = raw.find(':')
    if colon < 0:
      continue
    let key = raw[0 ..< colon].strip
    if key != SessionsBarKey and key != SessionsBarOverflowKey:
      continue
    let value = valueOf(raw, colon)
    var found: bool
    if key == SessionsBarKey:
      let placement = wordOf[SessionsBarPlacement](value, found)
      if found: result.setting.placement = placement
      else:
        result.problems.add SessionsBarKey & " is bottom, top or panel, not '" &
                            value & "'"
    else:
      let overflow = wordOf[SessionsBarOverflow](value, found)
      if found: result.setting.overflow = overflow
      else:
        result.problems.add SessionsBarOverflowKey & " is rows or popup, not '" &
                            value & "'"
