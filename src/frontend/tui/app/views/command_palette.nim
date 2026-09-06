## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module is a PURE FUNCTION of a value: it takes an index and
## a query and answers ranked hits. It runs nothing.
##
## app/views/command_palette.nim — CTUI-10. §4.2's `Ctrl+p` / `F1`, "Fuzzy
## Command Palette — open fuzzy searchable action palette (files, functions,
## commands)".
##
## ## WHAT IS REUSED FROM `isonim-tui`, AND WHAT IS NOT
##
## CTUI-10: *"built on `isonim-tui`'s palette widget and fuzzy matcher"*, and
## the campaign instruction is explicit: reuse them, do not write another fuzzy
## matcher. So:
##
##   * the scoring heuristic and its cluster offsets —
##     `isonim_tui/command/fuzzy.nim`'s `newMatcher`, `Matcher.match`,
##     `matchFull` and `MatchResult`;
##   * the provider abstraction and the per-query search —
##     `isonim_tui/command/palette.nim`'s `Provider`, `newSimpleProvider`,
##     `searchProvider` and `Hit`;
##   * the ranking rule — `palette.cmpHit`, descending score with ties broken
##     by text.
##
## Nothing here computes a score, and nothing here decides which of two hits
## ranks first. `app/tests/test_command_palette_fuzzy.nim` asserts that by
## comparing this module's ranking against `newMatcher(query).match(text)` read
## directly out of the sibling — an oracle that is a different call into the
## same library rather than a second copy of its arithmetic.
##
## **The `CommandPalette` WIDGET is deliberately not mounted, and that is
## a deviation worth stating.** `palette.newCommandPalette` builds a DOM of
## `TerminalNode`s inside a `TerminalTestHarness` and paints itself through
## `renderTree`. Every pane in this front-end — CTUI-3's shell, CTUI-5's source,
## CTUI-6's stack, CTUI-7's variables, CTUI-8's timeline — paints into a
## `styled_row.StyledGrid` and is handed to the compositor by `styledRowsTree`,
## because that is what makes a pane a pure function of a value and what makes
## the cross-tier comparison a comparison of screens rather than of trees.
## Mounting one widget that builds its own DOM would give this screen two layout
## models and would put the palette outside every golden the shell records. So
## the widget's DATA and RANKING are reused and its PAINT is this module's,
## through the same grid as every other pane.
##
## ## EVERY ENTRY CARRIES A `:` LINE, WHICH IS HOW THE PALETTE HAS NO DISPATCH
##
## `PaletteEntry.command` is the §4.3 line running that entry executes.
## Selecting a hit does not call a ViewModel and does not know what one is: it
## answers a string, and the caller hands that string to
## `app/commands/interpreter.runCommand`. So the palette is a THIRD SPELLING of
## the same dispatch — after the keymap and the `:` prompt — and CTUI-10's first
## contract holds for it by construction rather than by inspection.
##
## That is also what makes "selecting it navigates" assertable without a
## terminal: the assertion is that the top hit's `command` is the `:goto <tick>`
## of the function the query named, and that running it seeks there.
##
## ## THE INDEX IS BUILT BY THE CALLER, FROM REAL THINGS
##
## `PaletteEntry`s come from three sources and this module builds none of them:
## §4.3's own command table, the recording's own function names (which CTUI-8
## already reads out of `ct/load-calltrace-section`), and the files those
## functions are in. `commandEntry`, `functionEntry` and `fileEntry` are the
## three constructors — each one row's worth — and the INDEX is assembled by the
## caller, for the reason every other seam in this tree is: a view that fetched
## its own contents could not be asserted without the thing that fetches.

import std/[algorithm, tables]

import isonim_tui

import ./header
import ./styled_row

export header, styled_row

type
  PaletteEntryKind* = enum
    ## §4.2's own three: "files, functions, commands".
    pekCommand = "command"
    pekFunction = "function"
    pekFile = "file"

  PaletteEntry* = object
    ## One thing the palette can find and run.
    kind*: PaletteEntryKind
    text*: string
      ## What the fuzzy matcher scores, and the row's label. MUST BE UNIQUE
      ## across the index — `rank` keys hits back onto entries by this string,
      ## and `indexIsWellFormed` is what makes that a checked property rather
      ## than an assumption.
    help*: string
      ## The secondary line: §4.3's summary for a command, the location for a
      ## function.
    command*: string
      ## The §4.3 line selecting this entry runs. See the module header.

  PaletteHit* = object
    ## One ranked result.
    entry*: PaletteEntry
    score*: float64
    offsets*: seq[int]
      ## Byte offsets in `entry.text` the query matched, from
      ## `fuzzy.MatchResult`. Carried so the row can highlight them rather than
      ## re-deriving a match the scorer already computed.

  PaletteModel* = object
    ## The palette, whole, as a value.
    open*: bool
    query*: string
    entries*: seq[PaletteEntry]
    hits*: seq[PaletteHit]
    selected*: int
      ## Index into `hits`, or -1 when there are none.
    provider*: Provider
      ## `isonim-tui`'s own provider over `entries`, BUILT ONCE.
      ##
      ## Per-keystroke cost is what CTUI-10's verification gate measures, and
      ## building the provider inside the query would put a full copy of the
      ## index into every keystroke. Measured at 2,000 entries on this host:
      ## 5.6 ms per query with the copy, and the figure `refresh` now reports
      ## without it. `isonim-tui`'s own `CommandPalette` holds its providers for
      ## the same reason.
    byText*: Table[string, PaletteEntry]
      ## `text` -> entry, so a `Hit` can be joined back to what produced it.
      ## Built beside `provider` and for the same reason.

const
  PaletteTitle* = "COMMAND PALETTE"
  PalettePrompt* = "> "
  NoResultsText* = "no match"

  MaxVisibleHits* = 12
    ## How many rows the palette draws. A ceiling rather than "as many as
    ## fit", so the pane's height is a property of a named constant and the
    ## fuzzy sweep's cost does not depend on the terminal's size.

  TitleStyle* = CellStyle(fg: "white", bold: true)
  PromptStyle* = CellStyle(fg: "yellow", bold: true)
  MatchStyle* = CellStyle(fg: "bright_cyan", bold: true)
  HelpStyle* = CellStyle(fg: "bright_black")
  SelectedBackground* = "bright_black"
  EmptyStyle* = CellStyle(fg: "bright_black", italic: true)

  KindLabels*: array[PaletteEntryKind, string] = [":", "ƒ", "▤"]
    ## One glyph per kind, so a row says what it will do before it is run.

# ---------------------------------------------------------------------------
# Building the index
# ---------------------------------------------------------------------------

proc commandEntry*(name, summary, argument: string): PaletteEntry =
  ## One §4.3 command as a palette row. The `command` it runs is the command
  ## itself — with its placeholder left in, because a command that needs an
  ## argument cannot be run from a palette without one and the row must SAY so
  ## rather than run a broken line.
  PaletteEntry(kind: pekCommand, text: ":" & name,
               help: summary & (if argument.len > 0: "  " & argument else: ""),
               command: ":" & name & (if argument.len > 0: " " & argument
                                      else: ""))

proc functionEntry*(name, path: string; line: int;
                    tick: uint64): PaletteEntry =
  ## One recorded function as a palette row. Selecting it SEEKS to the tick the
  ## calltrace says the call started at — which is what "selecting it navigates"
  ## means, and it goes through `:goto` like everything else.
  PaletteEntry(kind: pekFunction, text: name,
               help: pathBaseName(path) & ":" & $line & "  tick " & $tick,
               command: ":goto " & $tick)

proc fileEntry*(path: string; line: int): PaletteEntry =
  ## One source file as a palette row. Selecting it places a breakpoint at
  ## `line`, which is the only navigation §4.3 gives a file.
  PaletteEntry(kind: pekFile, text: pathBaseName(path), help: path,
               command: ":break " & $line)

proc indexIsWellFormed*(entries: openArray[PaletteEntry]): (bool, string) =
  ## Whether `text` is unique and every entry carries a command.
  ##
  ## Checked rather than assumed because `rank` maps a `Hit` back onto an entry
  ## BY TEXT: a duplicate would make one of the two unreachable, silently, and
  ## the palette would run the wrong command for a row the user could see.
  var seen: seq[string] = @[]
  for e in entries:
    if e.text.len == 0:
      return (false, "an entry has no text")
    if e.command.len == 0:
      return (false, "entry `" & e.text & "` runs nothing")
    if e.text in seen:
      return (false, "two entries share the text `" & e.text & "`")
    seen.add e.text
  (true, "")

proc paletteProvider*(name: string;
                      entries: openArray[PaletteEntry]): Provider =
  ## The index as one of `isonim-tui`'s own providers.
  ##
  ## The `CommandCallback` is `nil` on every row, deliberately: callbacks are
  ## invoked by the WIDGET, which this front-end does not mount (see the module
  ## header), and a closure per entry would be a second place a row's action
  ## lives beside `PaletteEntry.command`.
  var commands: seq[tuple[text, help: string; command: CommandCallback]] = @[]
  for e in entries:
    commands.add (text: e.text, help: e.help, command: CommandCallback(nil))
  newSimpleProvider(name, commands)

# ---------------------------------------------------------------------------
# Ranking — isonim-tui's matcher, isonim-tui's comparator
# ---------------------------------------------------------------------------

proc indexOf*(entries: openArray[PaletteEntry]): Table[string, PaletteEntry] =
  ## `text` -> entry. Built once per index, never per query.
  result = initTable[string, PaletteEntry]()
  for e in entries:
    result[e.text] = e

proc rankWith*(provider: Provider; byText: Table[string, PaletteEntry];
               entries: openArray[PaletteEntry];
               query: string): seq[PaletteHit] =
  ## THE PER-KEYSTROKE WORK, over a provider and a lookup built once.
  ##
  ## `searchProvider` is what scores — it builds one `Matcher` for the query and
  ## drops everything at score 0 — and `cmpHit` is what orders. Neither is
  ## re-implemented here; the only work this proc does is joining a `Hit` back
  ## to the `PaletteEntry` it came from and asking the matcher once more, over
  ## the HITS only, for the offsets `Provider` does not carry.
  ##
  ## An EMPTY query answers the whole index in index order, which is the
  ## palette's discovery view. `searchProvider` on an empty query would score
  ## everything at 0 and `cmpHit` would then sort alphabetically, losing §4.3's
  ## published order — so the empty case is handled here rather than paying for
  ## a sort that destroys information.
  result = @[]
  if entries.len == 0:
    return
  if query.len == 0:
    for e in entries:
      result.add PaletteHit(entry: e, score: 0.0, offsets: @[])
    return
  var hits = searchProvider(provider, query)
  hits.sort(cmpHit)
  let matcher = newMatcher(query)
  for h in hits:
    if not byText.hasKey(h.text):
      continue
    let full = matcher.matchFull(h.text)
    result.add PaletteHit(entry: byText[h.text], score: h.score,
                          offsets: full.offsets)

proc rank*(entries: openArray[PaletteEntry]; query: string): seq[PaletteHit] =
  ## `rankWith` for a caller that has no model: it builds the provider and the
  ## lookup and then throws them away, so it is the ONE-SHOT spelling and NOT
  ## the one a keystroke takes. `PaletteModel.refresh` uses its cached pair.
  rankWith(paletteProvider("CodeTracer TUI", entries), indexOf(entries),
           entries, query)

# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------

proc initPaletteModel*(entries: seq[PaletteEntry] = @[]): PaletteModel =
  PaletteModel(open: false, query: "", entries: entries, hits: @[],
               selected: -1,
               provider: paletteProvider("CodeTracer TUI", entries),
               byText: indexOf(entries))

proc setEntries*(model: var PaletteModel; entries: seq[PaletteEntry]) =
  ## Replace the index. THE ONLY WAY the provider and the lookup are rebuilt,
  ## so neither can drift from `entries`.
  model.entries = entries
  model.provider = paletteProvider("CodeTracer TUI", entries)
  model.byText = indexOf(entries)
  model.hits = @[]
  model.selected = -1

proc refresh*(model: var PaletteModel): int =
  ## Re-rank against the current query and answer the hit count. THE LIVE
  ## COUNT, the same shape `app/views/search.updateQuery` has, and for the same
  ## reason.
  model.hits = rankWith(model.provider, model.byText,
                        model.entries, model.query)
  model.selected = if model.hits.len > 0: 0 else: -1
  model.hits.len

proc open*(model: var PaletteModel): int =
  ## §4.2's `Ctrl+p` / `F1`. Opens on the DISCOVERY view — an empty query, the
  ## whole index — so the palette is a way to find out what exists and not only
  ## a way to reach something already known.
  model.open = true
  model.query = ""
  model.refresh()

proc close*(model: var PaletteModel) =
  model.open = false
  model.query = ""
  model.hits = @[]
  model.selected = -1

proc setQuery*(model: var PaletteModel; query: string): int =
  model.query = query
  model.refresh()

proc typeChar*(model: var PaletteModel; ch: string): int =
  model.setQuery(model.query & ch)

proc backspace*(model: var PaletteModel): int =
  if model.query.len > 0:
    model.query.setLen(model.query.len - 1)
  model.refresh()

proc moveSelection*(model: var PaletteModel; delta: int): bool =
  ## `Down` / `Up`. Wraps, like `isonim-tui`'s own widget does.
  if model.hits.len == 0:
    model.selected = -1
    return false
  if model.selected < 0:
    model.selected = 0
    return true
  model.selected =
    (model.selected + delta + model.hits.len * 2) mod model.hits.len
  true

proc selectedCommand*(model: PaletteModel): (bool, string) =
  ## The §4.3 line the highlighted row runs. THE PALETTE'S WHOLE OUTPUT.
  if model.selected < 0 or model.selected >= model.hits.len:
    return (false, "")
  (true, model.hits[model.selected].entry.command)

proc topHit*(model: PaletteModel): (bool, PaletteHit) =
  if model.hits.len == 0:
    return (false, PaletteHit())
  (true, model.hits[0])

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc rowLabel*(hit: PaletteHit; width: int): string =
  ## One result row: kind glyph, text, help, fitted to `width`.
  let head = KindLabels[hit.entry.kind] & " " & hit.entry.text
  if hit.entry.help.len == 0:
    return fitCells(head, width)
  let gap = width - textCells(head) - textCells(hit.entry.help) - 2
  if gap < 1:
    return fitCells(head, width)
  fitCells(head & repeatGlyph(" ", gap + 2) & hit.entry.help, width)

proc paletteRows*(model: PaletteModel; width, height: int): seq[string] =
  ## The palette as plain rows — the model half of the paint, so a test can
  ## assert what is on screen without a compositor.
  result = @[]
  if width <= 0 or height <= 0 or not model.open:
    return
  result.add fitCells(PaletteTitle & " " &
                      repeatGlyph("─", max(0, width - textCells(PaletteTitle) -
                                           1)), width)
  result.add fitCells(PalettePrompt & model.query, width)
  let room = min(min(height - 2, MaxVisibleHits), model.hits.len)
  for i in 0 ..< room:
    result.add rowLabel(model.hits[i], width)
  if model.hits.len == 0:
    result.add fitCells("  " & NoResultsText, width)
  while result.len < height:
    result.add repeatGlyph(" ", width)
  if result.len > height:
    result.setLen(height)

proc paint*(g: var StyledGrid; model: PaletteModel; top, left,
            width, height: int) =
  ## The palette onto a grid, with the selected row reversed and the matched
  ## offsets accented.
  if width <= 0 or height <= 0 or not model.open:
    return
  let rows = paletteRows(model, width, height)
  for i, text in rows:
    let style =
      if i == 0: TitleStyle
      elif i == 1: PromptStyle
      elif model.hits.len == 0: EmptyStyle
      else: DefaultCellStyle
    g.paint(top + i, left, text, style)
  if model.hits.len == 0:
    return
  let room = min(min(height - 2, MaxVisibleHits), model.hits.len)
  for i in 0 ..< room:
    let row = top + 2 + i
    if i == model.selected:
      # THE BACKGROUND IS A TRANSFORM, not a repaint: the row's foregrounds are
      # already decided and painting a solid style over them would lose the
      # match accents applied just below. `source_pane.nim` does the same for
      # its execution line, and for the same reason.
      g.restyle(row, left, width, proc(s: CellStyle): CellStyle =
        var out2 = s
        out2.bg = SelectedBackground
        out2)
    # The matched characters, accented at the columns the row's label puts
    # them at: the kind glyph and one separating space precede the text.
    let base = left + textCells(KindLabels[model.hits[i].entry.kind]) + 1
    for off in model.hits[i].offsets:
      if off < 0 or off > model.hits[i].entry.text.len:
        continue
      let column = base + cellWidthOf(model.hits[i].entry.text[0 ..< off])
      if column >= left and column < left + width:
        g.restyle(row, column, 1, proc(s: CellStyle): CellStyle =
          var out2 = s
          out2.fg = MatchStyle.fg
          out2.bold = true
          out2)
