## views/cut_text_rules.nim
##
## How every front-end cuts a text that does not fit: the one trim rule
## around the "…" (CTF-P1c D6) and the middle cut of a file path, which
## keeps its first segment and its file name (D6, amended for paths).
##
## ## Why this module exists
##
## These rules started in `agent_harbor_words.nim`, beside the Agent Harbor
## views' words, and that module imports the Agent Harbor viewmodels. The
## GPUI window's own status bar cuts its location by the same path rule, and
## must not pull the Agent Harbor viewmodels into the shell to reach it. So
## the rules live here, on the standard library alone, and
## `agent_harbor_words` re-exports them, so its callers are unchanged.

import std/strutils


const
  CutEllipsis* = "\xE2\x80\xA6"
    ## What ends a cut text.
  CutSeparators* = ["\xC2\xB7", "\xE2\x80\x94"]
    ## The separators a cut drops when they end what it keeps: `·`, and the
    ## `—` of ` — `. Spaces are always dropped too. The GPUI views hand this
    ## set to isonim-gpui's text element (`ah_theme.text`), so the native
    ## cut follows the same rule.

proc trimBeforeEllipsis*(kept: string): string =
  ## The kept start of a cut text, without what would dangle before its
  ## "…": trailing spaces, and a separator (`CutSeparators`: `·`, or
  ## ` — `) the cut left last, so `5ca1ab1e · ` reads `5ca1ab1e…` and
  ## `Telemetry upload ` reads `Telemetry upload…`. Every host's cut text
  ## goes through this rule: the terminal's `ah_tui_canvas.elide`, the web's
  ## `ah_cut_text` and, through `CutSeparators`, the GPUI text element.
  result = kept.strip(leading = false)
  var trimmed = true
  while trimmed:
    trimmed = false
    for sep in CutSeparators:
      if result.endsWith(sep):
        result = result[0 ..< result.len - sep.len].strip(leading = false)
        trimmed = true

proc danglesBeforeEllipsis*(shown: string): bool =
  ## Whether a drawn text breaks the rule above: it ends in "…" and what it
  ## keeps before the "…" ends in a space or a separator. A bare "…"
  ## keeps nothing and does not dangle. The hosts' tests read their drawn
  ## cut texts through this; it reads the text itself rather than asking
  ## `trimBeforeEllipsis`, so a broken trim cannot also blind the check.
  if not shown.endsWith(CutEllipsis): return false
  let kept = shown[0 ..< shown.len - CutEllipsis.len]
  if kept.len == 0: return false
  if kept[^1] in Whitespace: return true
  for sep in CutSeparators:
    if kept.endsWith(sep): return true
  false

proc trimAfterEllipsis*(kept: string): string =
  ## The kept end of a text cut in its middle, without what would dangle
  ## after its "…": leading spaces, and a separator (`CutSeparators`) the
  ## cut left first. The mirror of `trimBeforeEllipsis`.
  result = kept.strip(trailing = false)
  var trimmed = true
  while trimmed:
    trimmed = false
    for sep in CutSeparators:
      if result.startsWith(sep):
        result = result[sep.len .. ^1].strip(trailing = false)
        trimmed = true

const PathSeparator* = '/'
  ## Where a path's segments meet; a path is cut only between them.

proc joinPathCut(head, tail: string): string =
  ## `head…tail`, each side trimmed by the one rule.
  trimBeforeEllipsis(head) & CutEllipsis & trimAfterEllipsis(tail)

proc pathCutCandidates*(path: string): seq[string] =
  ## The middle cuts of a file path, longest first (CTF-P1c D6, amended for
  ## paths): the path keeps its first segment and its file name, and the
  ## segments between give way one at a time from the second
  ## (`src/upload/retry/client.py`: `src/…/retry/client.py`, then
  ## `src/…/client.py`); then only the file name is kept (`…/client.py`).
  ## A host draws the first candidate that fits, and when none does, cuts
  ## the whole path at its end like any other text. A path with no segment
  ## between its first and its file name has only the last candidate, and a
  ## path of one segment has none. A leading `/` belongs to the first
  ## segment. Each side of the "…" is trimmed by the one rule
  ## (`trimBeforeEllipsis`, `trimAfterEllipsis`).
  let start = if path.len > 0 and path[0] == PathSeparator: 1 else: 0
  let firstSep = path.find(PathSeparator, start)
  let lastSep = path.rfind(PathSeparator)
  if firstSep < 0 or lastSep <= start - 1 or lastSep == path.high: return
  # The separators between the first segment and the file name: each one
  # starts a segment that may give way.
  var seps: seq[int]
  var i = firstSep
  while i >= 0 and i <= lastSep:
    seps.add i
    i = path.find(PathSeparator, i + 1)
  let head = path[0 .. firstSep]
  # Keep the segments after seps[k] (k = 1 .. high): drop the ones before.
  for k in 1 .. seps.high:
    result.add joinPathCut(head, path[seps[k] .. ^1])
  result.add joinPathCut("", path[lastSep .. ^1])

proc cutPath*(path: string; fits: proc(text: string): bool;
              endCut: proc(): string): string =
  ## A file path as a host draws it in the room it has: whole when it fits,
  ## else the first of `pathCutCandidates` that fits, else `endCut()` (the
  ## host's end cut of the whole path). `fits` measures in the host's unit.
  if fits(path): return path
  for candidate in pathCutCandidates(path):
    if fits(candidate): return candidate
  endCut()

proc runeStarts(s: string): seq[int] =
  ## The byte offset of every rune of `s`, and `s.len` last: where a cut
  ## may fall. A cut never splits a rune.
  var i = 0
  while i < s.len:
    result.add i
    let b = ord(s[i])
    i += (if b < 0x80: 1 elif b < 0xE0: 2 elif b < 0xF0: 3 else: 4)
  result.add s.len

proc cutInputValue*(value: string; room: int; widthOf: proc(text: string): int;
                    ellipsisWidth, startMax, startMin: int): string =
  ## **THE ONE-LINE INPUT RULE** (the P2c study's D35): a one-line input's
  ## value in at most `room` units of the host (terminal cells, GPUI
  ## pixels; `widthOf` measures a text in them, `ellipsisWidth` is the
  ## "…"'s). Whole when it fits; else cut in its MIDDLE with "…", keeping
  ## its start -- at most `startMax`, a quarter of the room at narrow
  ## widths, never under `startMin` -- and as much of its end as fits.
  ## When a path's last segment, with the `/` before it, fits beside
  ## `startMin` of the start, the start gives way to it, so a path keeps its
  ## file name whole (`m…/client.py`). An input holds one line at every
  ## width, so the value is never wrapped. Either side of the "…" follows
  ## the one trim rule (`trimBeforeEllipsis`, `trimAfterEllipsis`).
  ##
  ## Each side is the longest run of whole runes that fits its share, so a
  ## wide glyph on the cut stays whole on the side its start is on. The
  ## terminal's `ah_tui_canvas.elideMiddle` and the GPUI composer's fields
  ## both draw through this, each in its own unit.
  if room <= 0: return ""
  if widthOf(value) <= room: return value
  let avail = room - ellipsisWidth
  if avail <= 0: return CutEllipsis
  var startBudget = clamp(avail div 4, startMin, max(startMin, startMax))
  let lastSep = value.rfind(PathSeparator)
  if lastSep > 0:
    let lastSegment = widthOf(value[lastSep .. ^1])
    if lastSegment > avail - startBudget and lastSegment <= avail - startMin:
      startBudget = avail - lastSegment
  let starts = runeStarts(value)
  # The start: the longest prefix of whole runes within its budget.
  var headEnd = 0
  for k in 1 ..< starts.len:
    if widthOf(value[0 ..< starts[k]]) > startBudget: break
    headEnd = starts[k]
  let head = value[0 ..< headEnd]
  # The end: the longest suffix of whole runes within what is left.
  let endBudget = avail - widthOf(head)
  var tailStart = value.len
  for k in countdown(starts.len - 2, 0):
    if starts[k] < headEnd or widthOf(value[starts[k] .. ^1]) > endBudget: break
    tailStart = starts[k]
  # A zero-width rune (a combining mark) belongs to the rune before it, which
  # the end did not keep: it goes with that rune.
  var t = starts.find(tailStart)
  while t >= 0 and t + 1 < starts.len and tailStart < value.len and
      widthOf(value[starts[t] ..< starts[t + 1]]) == 0:
    inc t
    tailStart = starts[t]
  let tail = if tailStart < value.len: value[tailStart .. ^1] else: ""
  trimBeforeEllipsis(head) & CutEllipsis & trimAfterEllipsis(tail)

proc danglesAroundEllipsis*(shown: string): bool =
  ## Whether a drawn cut breaks the trim rule: an end cut (it ends in "…")
  ## by `danglesBeforeEllipsis`; a middle cut on either side of its last
  ## "…" -- what it keeps before ends in a space or a separator, or what it
  ## keeps after starts with one. Reads the text itself, as
  ## `danglesBeforeEllipsis` does.
  if shown.endsWith(CutEllipsis): return danglesBeforeEllipsis(shown)
  let at = shown.rfind(CutEllipsis)
  if at < 0: return false
  if danglesBeforeEllipsis(shown[0 ..< at + CutEllipsis.len]): return true
  let after = shown[at + CutEllipsis.len .. ^1]
  if after.len == 0: return false
  if after[0] in Whitespace: return true
  for sep in CutSeparators:
    if after.startsWith(sep): return true
  false
