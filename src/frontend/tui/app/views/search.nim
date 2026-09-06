## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module is a PURE FUNCTION of a value: it takes lines and a
## query and answers matches. It holds no ViewModel, reads no terminal and
## fetches nothing.
##
## app/views/search.nim — CTUI-10. §4.2's `/` and `?` ("Search Forward" /
## "Search Backward") and `n` / `N` ("Next / Prev Search Match"), with the
## real-time match count §3.3.6 asks for.
##
## ## THE COUNT IS THE FEATURE, AND IT IS LIVE
##
## §3.3.6: *"Prompt `/` for searching text across source code or event logs with
## real-time match count."* So `updateQuery` recomputes the WHOLE match set on
## every keystroke and returns its size, and `matchCountText` renders it. There
## is no incremental narrowing and no cache, deliberately: a search that only
## re-filtered the previous result set would be wrong the moment a character is
## deleted, and the cheap wrong answer is the one a user cannot see is wrong.
##
## The cost is bounded by the text, not by the query: one pass per keystroke
## over the lines the caller handed in. `app/tests/test_incremental_search.nim`
## drives a real recorded program's source one keystroke at a time, asserts the
## count after each against `std/strutils.count` as an independent oracle, and
## asserts the sweep's own length against `Query.len` — so a loop that stopped
## early cannot look like a search that narrowed.
##
## ## SEARCH OUTLIVES ITS PROMPT, WHICH IS WHAT `n` NEEDS
##
## CTUI-9's `modal_state` gives SEARCH two phases: `spTyping` while the prompt
## is open and every printable key is text, `spBrowsing` after `Enter`, where
## `n` and `N` walk the matches. This module is the browsing half. It holds the
## committed query and the cursor into the match set; the prompt itself is
## `app/views/command_line.nim`, which serves `:`, `/` and `?` alike.
##
## ## `n` FOLLOWS THE DIRECTION THE SEARCH WAS OPENED WITH
##
## §4.2 gives one row to both keys — "`n` / `N`: Next / Prev Search Match" —
## and two rows to the two prompts. Vim's rule, which this follows and which
## §4.2 does not spell out, is that `n` means *onward in the direction of the
## search*: after `?foo`, `n` walks BACKWARD. `nextMatch` and `prevMatch`
## therefore consult `direction`, and `advance` — which takes an absolute
## direction — is exposed beside them so a test can drive both spellings and
## assert they compose.
##
## ## WRAPAROUND IS REPORTED, NOT SILENT
##
## Walking off the end wraps to the beginning, and `SearchModel.wrapped` records
## that the LAST move did so. A search that wrapped without saying so is how a
## user reads the same match twice believing it is a new one, and §3.3.6's
## notification area is where the message goes.

import std/strutils

# `textCells` / `fitCells` live in `header.nim` — the one width-measurement
# rule the whole shell shares, exactly as `status_bar.nim` records. A second
# copy of it is how a highlight's columns and a status line's columns come
# apart.
import ./header
import ./styled_row

export header, styled_row

type
  SearchDirection* = enum
    ## Which prompt opened the search. Spelled as the key §4.2 binds, so a
    ## status bar can print the value.
    sdirForward = "/"
    sdirBackward = "?"

  SearchScope* = enum
    ## What is being searched. §4.1: "Incremental search across source text,
    ## variable names, and event logs." The scope does not change the matching
    ## — this module takes lines — but it is carried so the prompt can say what
    ## it is searching and so a count is not read against the wrong pane.
    sscSource = "source"
    sscEventLog = "events"
    sscVariables = "variables"

  SearchMatch* = object
    ## One hit. `line` is 1-based to match every other line number in this
    ## front-end (the gutter, the execution pointer, `:break <line>`);
    ## `column` is 0-based in CELLS, which is what `styled_row.cellSlice`
    ## indexes by and therefore what a highlight can be painted from.
    line*: int
    column*: int
    length*: int
      ## In cells, so a match on a wide glyph highlights the columns it
      ## occupies rather than the bytes it takes.

  SearchModel* = object
    ## A committed search, as a value.
    scope*: SearchScope
    direction*: SearchDirection
    caseSensitive*: bool
    query*: string
    matches*: seq[SearchMatch]
    current*: int
      ## Index into `matches`, or -1 when there are none.
    wrapped*: bool
      ## Whether the LAST `nextMatch` / `prevMatch` wrapped around. Reset by
      ## every move, so it describes the move a user just made rather than any
      ## move they ever made.

const
  NoMatchesText* = "no matches"
  EmptyQueryText* = "type to search"
  WrappedForwardText* = "search hit BOTTOM, continuing at TOP"
  WrappedBackwardText* = "search hit TOP, continuing at BOTTOM"
    ## Vim's own wording, because a user who knows one knows the other and
    ## because "wrapped" alone does not say which way.

  CountStyle* = CellStyle(fg: "bright_black")
  QueryStyle* = CellStyle(fg: "white")
  WrapStyle* = CellStyle(fg: "yellow")

proc initSearchModel*(scope = sscSource; direction = sdirForward;
                      caseSensitive = false): SearchModel =
  SearchModel(scope: scope, direction: direction, caseSensitive: caseSensitive,
              query: "", matches: @[], current: -1, wrapped: false)

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

proc matchesInLine*(line: string; query: string; caseSensitive: bool;
                    lineNumber: int; into: var seq[SearchMatch]): int =
  ## Every NON-OVERLAPPING occurrence of `query` in one line, appended to
  ## `into`, and how many were found.
  ##
  ## NON-OVERLAPPING is a decision and it is Vim's: `aa` in `aaaa` is two
  ## matches, not three. Overlapping would make `n` visit a position the
  ## highlight already covers, and the count in the status bar would exceed the
  ## number of places a reader can see.
  ##
  ## The scan is over CELLS, not bytes: `column` and `length` index the same
  ## space `styled_row.cellSlice` does, so a match found here can be
  ## highlighted without a second width calculation that could disagree.
  result = 0
  if query.len == 0:
    return
  let haystack = if caseSensitive: line else: line.toLowerAscii
  let needle = if caseSensitive: query else: query.toLowerAscii
  var byteAt = 0
  while byteAt <= haystack.len - needle.len:
    let found = haystack.find(needle, byteAt)
    if found < 0:
      break
    into.add SearchMatch(
      line: lineNumber,
      column: cellWidthOf(line[0 ..< found]),
      length: cellWidthOf(line[found ..< found + needle.len]))
    inc result
    byteAt = found + max(1, needle.len)

proc findMatches*(lines: openArray[string]; query: string;
                  caseSensitive = false): seq[SearchMatch] =
  ## Every match in `lines`, in document order.
  ##
  ## Document order regardless of `direction`: the ORDER is a property of the
  ## text and the DIRECTION is a property of the walk. Keeping them apart is
  ## what lets `?` and `/` share one match set and lets `n` and `N` be exact
  ## inverses over it.
  result = @[]
  if query.len == 0:
    return
  for i, line in lines:
    discard matchesInLine(line, query, caseSensitive, i + 1, result)

proc updateQuery*(model: var SearchModel; lines: openArray[string];
                  query: string): int =
  ## One keystroke: recompute the whole match set and answer the LIVE COUNT.
  ##
  ## `current` is reset to -1 rather than kept, because the match the cursor
  ## was on may not exist under the new query and a cursor that survived would
  ## point at a different hit than the one the user was looking at.
  model.query = query
  model.matches = findMatches(lines, query, model.caseSensitive)
  model.current = -1
  model.wrapped = false
  model.matches.len

# ---------------------------------------------------------------------------
# The cursor
# ---------------------------------------------------------------------------

proc firstAtOrAfter*(model: SearchModel; line: int): int =
  ## The index of the first match on or after `line`, or -1.
  for i, m in model.matches:
    if m.line >= line:
      return i
  -1

proc lastAtOrBefore*(model: SearchModel; line: int): int =
  ## The index of the last match on or before `line`, or -1.
  result = -1
  for i, m in model.matches:
    if m.line <= line:
      result = i

proc commit*(model: var SearchModel; fromLine: int): bool =
  ## `Enter` at the prompt: place the cursor on the first match the search's
  ## own direction reaches from `fromLine`, wrapping when there is none.
  ##
  ## Answers whether a match was found, so the caller reports `no matches`
  ## rather than leaving a prompt that appears to have done nothing.
  model.wrapped = false
  if model.matches.len == 0:
    model.current = -1
    return false
  case model.direction
  of sdirForward:
    var idx = model.firstAtOrAfter(fromLine)
    if idx < 0:
      idx = 0
      model.wrapped = true
    model.current = idx
  of sdirBackward:
    var idx = model.lastAtOrBefore(fromLine)
    if idx < 0:
      idx = model.matches.high
      model.wrapped = true
    model.current = idx
  true

proc advance*(model: var SearchModel; forward: bool): (bool, SearchMatch) =
  ## Move the cursor one match in an ABSOLUTE direction, wrapping.
  ##
  ## Returns `(false, …)` only when there is nothing to move over — an empty
  ## match set. A single match is a successful move onto itself, which is what
  ## `n` does in Vim and what keeps "the count says 1/1" honest.
  model.wrapped = false
  if model.matches.len == 0:
    model.current = -1
    return (false, SearchMatch())
  if model.current < 0:
    model.current = if forward: 0 else: model.matches.high
    return (true, model.matches[model.current])
  if forward:
    if model.current == model.matches.high:
      model.current = 0
      model.wrapped = true
    else:
      inc model.current
  else:
    if model.current == 0:
      model.current = model.matches.high
      model.wrapped = true
    else:
      dec model.current
  (true, model.matches[model.current])

proc nextMatch*(model: var SearchModel): (bool, SearchMatch) =
  ## §4.2's `n`: onward in the direction the search was opened with.
  model.advance(model.direction == sdirForward)

proc prevMatch*(model: var SearchModel): (bool, SearchMatch) =
  ## §4.2's `N`: the exact inverse of `n`.
  model.advance(model.direction != sdirForward)

# ---------------------------------------------------------------------------
# What the user sees
# ---------------------------------------------------------------------------

proc matchCountText*(model: SearchModel): string =
  ## §3.3.6's "real-time match count", as the one string the status bar shows.
  if model.query.len == 0:
    return EmptyQueryText
  if model.matches.len == 0:
    return NoMatchesText
  if model.current < 0:
    return "[" & $model.matches.len & "]"
  "[" & $(model.current + 1) & "/" & $model.matches.len & "]"

proc wrapNotice*(model: SearchModel): string =
  ## The wraparound message, or "". See this module's header.
  if not model.wrapped:
    return ""
  case model.direction
  of sdirForward: WrappedForwardText
  of sdirBackward: WrappedBackwardText

proc searchStatusText*(model: SearchModel; width: int): string =
  ## The whole search line: the sigil, the query, the count, and the wrap
  ## notice, fitted to `width` cells.
  if width <= 0:
    return ""
  var line = $model.direction & model.query & "  " & model.matchCountText()
  let notice = model.wrapNotice()
  if notice.len > 0:
    line.add "  " & notice
  fitCells(line, width)

proc currentMatch*(model: SearchModel): (bool, SearchMatch) =
  if model.current < 0 or model.current >= model.matches.len:
    return (false, SearchMatch())
  (true, model.matches[model.current])

proc matchesOnLine*(model: SearchModel; line: int): seq[SearchMatch] =
  ## Every match on one line, for a pane painting highlights.
  result = @[]
  for m in model.matches:
    if m.line == line:
      result.add m
