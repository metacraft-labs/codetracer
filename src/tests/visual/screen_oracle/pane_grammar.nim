## PLAT-39 — the published grammar, one rule per model type.
##
## **PUBLISHED SO THAT A ROW THAT DOES NOT MATCH IS `urGrammarMismatch` RATHER
## THAN A SILENT DROP.** A reader that skips what it cannot parse reports a
## short list and looks healthy; `Verification-Harness-Traps.md` §4 is the same
## defect one level up (a scan that matches nothing satisfies every "must not
## contain" check). Every rule here is written where a reader can dispute it.
##
## ===========================================================================
## WHAT OCR ACTUALLY RETURNS, MEASURED 2026-09-22 BEFORE THIS FILE WAS WRITTEN
## ===========================================================================
##
## These numbers come from tesseract 5.5.1 over the six pinned Electron frames
## (1,289 words across 15 populated regions). They are the reason the rules
## below are shaped the way they are, and none of them was guessed:
##
## * **Variable NAMES survive OCR intact.** All 11 names in `stepped-editor`'s
##   state pane came back exactly: `__builtins__`, `__cached__`, `__doc__`,
##   `__file__`, `__loader__`, `__name__`, `__package__`, `__spec__`, `add`,
##   `mul`, `sub`. Names are therefore the field this reader is confident about.
## * **TYPES DO NOT survive.** `NoneType` was read as `NoneTuype` twice and
##   `NoneType` once — in one pane, in one font, on one frame. A rule that
##   required an exact type match would be red for OCR's reasons rather than the
##   product's, so `valueType` is read on a best-effort basis and `LAW-R5`
##   carries it as a declared divergence rather than an equality.
## * **VALUES ARE TRUNCATED BY THE PANE, NOT BY THE READER.** The screen shows
##   `__doc__:"calc - the small, fast, determ` and stops: the pane is narrower
##   than the value. The DOM producer sees the whole string. This is not OCR
##   noise and no amount of tuning removes it — **a pixel producer cannot read
##   what was never drawn.** `value` is therefore a VISIBLE PREFIX, declared as
##   such, and compared as a prefix relation. That declaration is the honest
##   form; a loosened equality would be the dishonest one.
## * **CONFIDENCE DOES NOT SEPARATE SIGNAL FROM NOISE, so it is not used to.**
##   Measured: real content sits at confidence 0.0 (`0x7fffe7ebf420>`,
##   `"__main__""`) alongside genuine noise (`CEiliL,`, `+++/`, `ErolectU=y`).
##   A per-word floor high enough to drop the noise deletes real values. What
##   the confidence DOES do cleanly is answer "is there anything here at all":
##   every one of the 15 populated regions had a maximum word confidence of at
##   least **92.9**. So the floor is applied to the region's BEST word, not to
##   each word, and its job is to raise `urNoWordAboveFloor` for a region that
##   contains nothing legible. See `OcrConfidenceFloor`.

import std/[sequtils, strutils]
from std/unicode import runeLen

const
  OcrConfidenceFloor* = 60.0
    ## **A REGION-LEVEL floor, not a per-word filter. Chosen by measurement.**
    ##
    ## The rule: if no word in a located region reaches this confidence, the
    ## region is `urNoWordAboveFloor`. Individual words BELOW it are still kept,
    ## because the measurement above shows real values at confidence 0.
    ##
    ## **Derivation, and the rejected values, because §36b requires the losers
    ## to be visible rather than described.** Over the six pinned frames the
    ## worst per-region maximum was **92.9** (`entry-shell`'s state pane, which
    ## holds few variables). Every populated region was at or above that.
    ##
    ## | candidate | keeps all 15 populated regions? | why not chosen |
    ## |---|---|---|
    ## | 0.0 | yes | an implicit zero accepts a region of pure noise; this is the value the milestone names as the thing not to do |
    ## | 30.0 | yes | below the noise floor of a blank region's stray marks, so it fails to reject |
    ## | **60.0** | **yes, with 32.9 of margin** | **chosen** |
    ## | 90.0 | yes, with 2.9 of margin | margin smaller than the 3.6-point spread already observed between frames of one pane; a font or viewport change would make it flap |
    ## | 95.0 | **no — drops 4 of 15** | rejects real regions |
    ##
    ## The ratchet rule applies: this constant may be LOWERED with a measurement
    ## and may not be raised twice. `plat39-threshold-probe` re-derives the
    ## table above from the current corpus and the suite fails if the chosen
    ## value stops being the one the table selects.

  MinRegionWords* = 1
    ## A located region with zero OCR words is `urNoWordAboveFloor`, not
    ## `srEmpty`. "I found the pane and read nothing out of it" is a failure to
    ## read; only the grammar may conclude emptiness, and only from words it
    ## successfully parsed.

type
  GrammarRule* = object
    ## One published rule. `name` and `shape` exist so the suite can print the
    ## grammar as a table and so a reviewer can dispute a rule by name.
    name*: string
    shape*: string
    note*: string

const
  ProgramStateGrammar* = GrammarRule(
    name: "state-variable-row",
    shape: "<name> ':' <value> [ ' ' <type> ]",
    note: "Split on the FIRST colon. The name is everything before it and is " &
          "the field this reader is confident about (measured: 11/11 exact). " &
          "The remainder is the VISIBLE PREFIX of the value; the pane " &
          "truncates it, so it is compared as a prefix, never as an equality. " &
          "A trailing capitalised bare word is taken as the type when one is " &
          "present, best-effort, because OCR corrupts type names " &
          "(NoneType -> NoneTuype, measured twice in one pane).")

  EventLogGrammar* = GrammarRule(
    name: "event-log-row",
    shape: "<rrTicks> <n> <file> ':' <line> <channel> ':' <text>",
    note: "The console output is everything from the channel token onward, " &
          "which is the field EventDataModel declares. Rows that do not " &
          "contain a channel token are urGrammarMismatch rather than dropped.")

  EventLogFooterGrammar* = GrammarRule(
    name: "event-log-footer",
    shape: "'Rows' <from> 'to' <to> 'of' <total>",
    note: "Only <total> is consumed, as EventLogModel.ofRows. The footer is " &
          "read with a TOLERANT rule for a measured reason: 'Rows 1 to 6 of 6' " &
          "OCRs as 'Rows 1 toBof6' — the words fuse and a '6' is read as 'B'. " &
          "The trailing integer survives that, so the rule takes the LAST " &
          "integer on the footer line rather than matching the whole phrase. " &
          "A strict phrase match would be red for the font's reasons.")

  EditorGrammar* = GrammarRule(
    name: "editor-highlighted-line",
    shape: "<digits> in the gutter cell of the highlighted row",
    note: "The highlighted row is located GEOMETRICALLY, by its distinct " &
          "background, and only then is its gutter cell OCR'd for digits. " &
          "Measured: OCRing the whole editor pane as text does not reliably " &
          "recover line numbers — a narrow gutter-plus-code strip returned " &
          "line 44 as '42' and lost most other numbers entirely. Locating " &
          "first and reading a digits-only cell second is what makes this " &
          "field recoverable at all.")

  EventLogTableGrammar* = GrammarRule(
    name: "event-log-table-row",
    shape: "<n> <channel> <text>",
    note: "PLAT-40. The vocabulary's event-log TABLE, as the terminal and the " &
          "native window draw it: the event's index, its channel as a bare " &
          "word, its text. Read into the SAME `EventDataModel` as the " &
          "desktop's row, as `<channel>: <text>`, so the two shapes compare " &
          "as one value. Tried only on a line the desktop rule did not match.")

  CalltraceGrammar* = GrammarRule(
    name: "calltrace-row",
    shape: "[indent] <name> [ '#' <index> ] [ '(' <args> ')' ] ...",
    note: "PLAT-40. The call's NAME is the row's first token, cut at a '#' " &
          "or '(' fused onto it: the desktop draws `name #index` and the " &
          "arguments after it, the vocabulary draws the name alone, indented " &
          "by depth. A name holds a letter; a token of punctuation or digits " &
          "alone is chrome or noise and is urGrammarMismatch, not a call.")

  PointListGrammar* = GrammarRule(
    name: "point-row",
    shape: "<kind> ... <path> ':' <line> [ ')' ]",
    note: "PLAT-40. The kind is the FIRST token and must be `breakpoint` or " &
          "`tracepoint`; the location is the LAST `<path>:<digits>` on the " &
          "line, so a label between the two cannot be taken for it. Only the " &
          "path's base name is kept: the pane draws the path at whatever " &
          "width it has.")

  TerminalEventRowGrammar* = GrammarRule(
    name: "terminal-event-row",
    shape: "<tick> <category> <file> ':' <line> <text>",
    note: "PLAT-40. The shipped terminal's event pane (`TRACEPOINTS`): the " &
          "tick, a four-cell CATEGORY (`out`, `err`, `mut`, `sys`, `trc`), " &
          "the location, the text. The category is not a channel — `out` " &
          "covers stdout and stderr alike — so the row answers the TEXT " &
          "alone, and the three front-ends are compared on the text.")

const AllGrammarRules* = [ProgramStateGrammar, EventLogGrammar,
                          EventLogFooterGrammar, EditorGrammar,
                          EventLogTableGrammar, CalltraceGrammar,
                          PointListGrammar, TerminalEventRowGrammar]

const TerminalEventCategories* = ["out", "mut", "sys", "err", "trc", "???"]
  ## `app/views/event_log.categoryLabel`'s spellings, trimmed.

const EventChannels* = ["stdout", "stderr", "stdin"]
  ## The channels an event's output travels on, as both row shapes spell them.


func splitVariableRow*(line: string): tuple[ok: bool, name, value, valueType: string] =
  ## `ProgramStateGrammar`. Returns ok=false for a line the rule does not
  ## describe, and the caller turns that into `urGrammarMismatch`.
  let s = line.strip()
  if s.len == 0: return (false, "", "", "")
  # Leading disclosure triangles and markers that the UI draws and OCR renders
  # as punctuation. Stripped by CLASS, not by an exhaustive list of glyphs, so
  # a new marker glyph does not silently become part of a variable's name.
  var i = 0
  while i < s.len and s[i] in {'>', '<', '^', 'v', '*', '+', '-', ' ', '\t'}:
    inc i
  let body = s[i .. ^1]
  let colon = body.find(':')
  if colon <= 0: return (false, "", "", "")
  let name = body[0 ..< colon].strip()
  if name.len == 0: return (false, "", "", "")
  # A name is an identifier-ish token. `main.py:112` from the event log must
  # NOT parse as a variable named `main.py`, which is why this is checked.
  for ch in name:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      return (false, "", "", "")
  var rest = body[colon + 1 .. ^1].strip()
  # Trailing icon glyphs: the expand and help buttons OCR as stray single
  # characters ("H @", "B @", "@ @" measured). Drop trailing runs of 1-char
  # tokens; a real value never ends in a lone symbol followed by another.
  var toks = rest.splitWhitespace()
  # **TRAILING ICON GLYPHS.** The expand and help buttons the UI draws at the
  # end of a variable row OCR as stray single characters — `B`, `H`, `X`, `@`
  # were all measured on the pinned corpus. They are dropped when a token is a
  # single character that is a symbol or a bare CAPITAL: a real value's last
  # token is essentially never a lone capital letter, while a lowercase or
  # digit single-character token (`5`, `x`) plausibly IS the value and is kept.
  # Without this, `__name__:"__main__" String B` yields no type at all, because
  # the type test then looks at `B` instead of at `String`.
  while toks.len >= 2 and toks[^1].len == 1 and
        (not toks[^1][0].isAlphaNumeric or toks[^1][0] in {'A'..'Z'}):
    discard toks.pop()
  var valueType = ""
  if toks.len >= 2:
    let last = toks[^1]
    # A bare capitalised alphabetic token at the end is the type.
    if last.len > 1 and last[0] in {'A'..'Z'} and last.allCharsInSet({'a'..'z', 'A'..'Z'}):
      valueType = last
      discard toks.pop()
  (true, name, toks.join(" "), valueType)

func parseEventRow*(line: string): tuple[ok: bool, consoleOutput: string] =
  ## `EventLogGrammar`. The console output is from the channel token onward.
  let s = line.strip()
  if s.len == 0: return (false, "")
  for channel in ["stdout:", "stderr:", "stdin:"]:
    let idx = s.find(channel)
    if idx >= 0:
      return (true, s[idx .. ^1].strip())
  (false, "")

func parseFooterTotal*(line: string): tuple[ok: bool, total: int] =
  ## `EventLogFooterGrammar`. Takes the LAST integer on the line — see the
  ## rule's note for the measured reason a strict phrase match is wrong.
  let s = line.strip()
  if not s.toLowerAscii.startsWith("rows"): return (false, 0)
  var last = -1
  var i = 0
  while i < s.len:
    if s[i].isDigit:
      var j = i
      while j < s.len and s[j].isDigit: inc j
      last = parseInt(s[i ..< j])
      i = j
    else:
      inc i
  if last < 0: (false, 0) else: (true, last)

func parseGutterDigits*(text: string): tuple[ok: bool, line: int] =
  ## `EditorGrammar`. The gutter cell is OCR'd alone and must be digits, once
  ## the execution marker the UI draws beside the line number is removed.
  ##
  ## Measured: the highlighted cell OCRs as `"> 44"` at psm 7 — the `>` is the
  ## execution arrow, which is part of the gutter and not noise. Leading marker
  ## glyphs are stripped by CLASS, exactly as `splitVariableRow` does, so a new
  ## marker glyph cannot silently become part of a line number. Anything else
  ## non-numeric still rejects: this must not quietly return a number from a
  ## cell that is not a gutter.
  # Marker glyphs, stripped by class. **Some are MULTI-BYTE**: the execution
  # arrow renders as U+00BB GUILLEMET, which is `\xC2\xBB` in UTF-8, and a
  # byte-set test that only listed ASCII rejected the cell outright — measured,
  # the gutter read `"\xC2\xBB 56"` and the whole editor model came back
  # `urGrammarMismatch` on three of six frames. Any byte >= 0x80 is part of a
  # non-ASCII glyph and cannot be a digit, so skipping it is safe here.
  var i = 0
  while i < text.len and (text[i] in {'>', '<', '^', 'v', '*', '+', '-',
                                      ' ', '\t', '\n', '\r', '.'} or
                          uint8(text[i]) >= 0x80'u8):
    inc i
  var digits = ""
  for ch in text[i .. ^1]:
    if ch.isDigit: digits.add ch
    elif ch in {' ', '\n', '\t', '\r'}: discard
    else: return (false, 0)   # a non-digit means this is not a gutter cell
  if digits.len == 0: return (false, 0)
  (true, parseInt(digits))

func isVisiblePrefixOf*(visible, full: string): bool =
  ## The declared comparison for `value`. `visible` is what the pane drew;
  ## `full` is what the DOM holds. Equality is the special case where the pane
  ## was wide enough.
  ##
  ## Compared on a NORMALISED form (whitespace collapsed) because the pane
  ## wraps and OCR inserts spaces at glyph boundaries; nothing else is
  ## relaxed, and in particular no character substitution is forgiven here —
  ## OCR corruption must surface as a divergence, not be absorbed.
  func norm(s: string): string =
    s.splitWhitespace().join(" ")
  let v = norm(visible)
  let f = norm(full)
  v.len > 0 and f.startsWith(v)

func parseEventTableRow*(line: string): tuple[ok: bool, consoleOutput: string] =
  ## `EventLogTableGrammar`: `<n> <channel> <text>`, answered in the desktop
  ## rule's form, `<channel>: <text>`.
  let toks = line.strip().splitWhitespace()
  if toks.len < 3: return (false, "")
  for ch in toks[0]:
    if not ch.isDigit: return (false, "")
  if toks[1] notin EventChannels: return (false, "")
  (true, toks[1] & ": " & toks[2 .. ^1].join(" "))

func eventText*(consoleOutput: string): string =
  ## The event's TEXT without its channel — what two front-ends are compared
  ## on, since OCR spaces `stdout:` and the text differently per face.
  let s = consoleOutput.strip()
  for ch in EventChannels:
    if s.startsWith(ch & ":"):
      return s[ch.len + 1 .. ^1].strip()
  s

func withinOneEdit*(a, b: string): bool =
  ## At most one insertion, deletion or substitution apart — the declared
  ## tolerance for an OCR reading against an exact one (measured on PLAT-40's
  ## native-window frame: `10 - 4 + 1 = 7` read as `10-4+1=17`).
  if abs(a.len - b.len) > 1: return false
  var i, j, edits = 0
  while i < a.len and j < b.len:
    if a[i] == b[j]:
      inc i; inc j
      continue
    inc edits
    if edits > 1: return false
    if a.len > b.len: inc i
    elif a.len < b.len: inc j
    else:
      inc i; inc j
  edits + (a.len - i) + (b.len - j) <= 1

func parseCallRow*(line: string): tuple[ok: bool, name: string] =
  ## `CalltraceGrammar`.
  ##
  ## A leading ONE-CHARACTER token with more after it is the row's
  ## expand/collapse ICON, not its name: the desktop draws `⊟ main #1 ()`, and
  ## OCR reads the icon as `B`, `©` or `@` (measured on PLAT-40's desktop
  ## frame, where every row read as `B` before this rule).
  ## A leading token with no letter or digit at all (`@&`) is the same icon
  ## read as two glyphs.
  var toks = line.strip().splitWhitespace()
  while toks.len > 1 and (toks[0].runeLen == 1 or
                          not toks[0].anyIt(it.isAlphaNumeric)):
    toks.delete(0)
  if toks.len == 0: return (false, "")
  var name = toks[0]
  for stop in ['#', '(']:
    let at = name.find(stop)
    if at >= 0: name = name[0 ..< at]
  if name.len == 0: return (false, "")
  var letters = 0
  for ch in name:
    if ch.isAlphaAscii: inc letters
    elif ch notin {'_', '<', '>', '.', ':', '$', '0'..'9'}:
      return (false, "")
  if letters == 0: return (false, "")
  (true, name)

func parsePointRow*(line: string): tuple[ok: bool, kind, fileName: string,
                                        lineNumber: int] =
  ## `PointListGrammar`.
  let toks = line.strip().splitWhitespace()
  if toks.len < 2: return (false, "", "", 0)
  # The kind, stripped of the punctuation OCR fuses onto a row's first glyph
  # (`'BREAKPOINT`) and matched within `withinOneEdit` (`BREAKPONT`, measured
  # on the desktop's small-caps face), answered in its canonical spelling.
  var word = ""
  for ch in toks[0]:
    if ch.isAlphaAscii: word.add ch.toLowerAscii
  var kind = ""
  for k in ["breakpoint", "tracepoint"]:
    if word == k or withinOneEdit(word, k): kind = k
  if kind.len == 0: return (false, "", "", 0)
  for i in countdown(toks.high, 1):
    var t = toks[i].strip(chars = {'(', ')', ',', ' '})
    let colon = t.rfind(':')
    if colon <= 0 or colon == t.high: continue
    let digits = t[colon + 1 .. ^1]
    if not digits.allCharsInSet({'0'..'9'}): continue
    let path = t[0 ..< colon]
    let slash = path.rfind('/')
    return (true, kind, path[slash + 1 .. ^1], parseInt(digits))
  (false, "", "", 0)

func parseTerminalEventRow*(line: string): tuple[ok: bool, consoleOutput: string] =
  ## `TerminalEventRowGrammar`.
  let toks = line.strip().splitWhitespace()
  if toks.len < 4: return (false, "")
  if not toks[0].allCharsInSet({'0'..'9'}): return (false, "")
  if toks[1] notin TerminalEventCategories: return (false, "")
  let colon = toks[2].rfind(':')
  if colon <= 0 or not toks[2][colon + 1 .. ^1].allCharsInSet({'0'..'9'}) or
     colon == toks[2].high:
    return (false, "")
  (true, toks[3 .. ^1].join(" "))

func compactText*(s: string): string =
  ## A row's text with every space removed — the form two readings are
  ## compared in, because OCR spaces `2 + 3 = 5` as `2+3 =5` and neither
  ## spacing is the product's claim.
  for ch in s:
    if ch notin Whitespace: result.add ch


func callNameKey*(name: string): string =
  ## A call-trace row's name as two readings are compared: its first token
  ## (the `CalltraceGrammar` cut — `<end of program>` is `<end`), with runs of
  ## `_` collapsed to one, because OCR reads `<__main__>` as `<_main_>` on
  ## every face measured and the underscores' COUNT is not what differs
  ## between two front-ends' call traces.
  let row = parseCallRow(name)
  let base = if row.ok: row.name else: name.strip()
  for ch in base:
    if ch == '_' and result.len > 0 and result[^1] == '_': continue
    result.add ch

func eventRowsFused*(line: string): bool =
  ## A line carrying MORE THAN ONE channel token is several event rows OCR
  ## fused into one — the engine grouped the table column by column — and not
  ## an event whose text happens to mention a channel.
  var n = 0
  for ch in EventChannels:
    n += line.count(ch & ":")
  n > 1

func variableNameKey*(name: string): string =
  ## A variable's name as two screen readings are compared: without the
  ## underscores at its ends and with inner runs collapsed. OCR drops an edge
  ## underscore on both faces measured (`__package__` read as `__package_`,
  ## `__builtins__` as `builtins__`), and a dunder's underscore COUNT is not
  ## what differs between two front-ends' state panes.
  let core = name.strip(chars = {'_'})
  for ch in core:
    if ch == '_' and result.len > 0 and result[^1] == '_': continue
    result.add ch

func namesAgree*(a, b: openArray[string]): bool =
  ## Every name the SMALLER reading holds is in the larger one, by
  ## `variableNameKey` — a pane shorter than its variable list, or a line OCR
  ## lost, leaves a reading with fewer names, never with different ones.
  var small, large: seq[string]
  for n in (if a.len <= b.len: a else: b): small.add variableNameKey(n)
  for n in (if a.len <= b.len: b else: a): large.add variableNameKey(n)
  for n in small:
    if n notin large: return false
  true
