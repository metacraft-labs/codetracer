## test_command_palette_fuzzy.nim — CTUI-10, Tier 1.
##
## ## What this suite is for
##
## CTUI-10: *"indexes real symbols from the fixture, types a subsequence,
## asserts the intended match ranks first and that selecting it navigates"*, and
## the verification gate: *"Fuzzy search over 2,000 symbols < 8 ms."*
##
## ## THE SYMBOLS ARE REAL, AND THEY COME OFF DISK
##
## `noir_space_ship` is CTUI-1's fixture and its program is in this checkout at
## `test-programs/noir_space_ship/src/`. This suite reads those two `.nr` files
## and extracts the `fn` and `let` bindings the recorder will record — so
## "real symbols from the fixture" is a file this repository ships rather than a
## list written in a test.
##
## It does NOT open a trace, and that is forced rather than chosen:
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under `app/`,
## including this directory, and fails on an import that resolves to
## `headless_session` — which is the only thing that can start a
## `replay-server`. So the SYMBOLS are read from the program's source here, and
## the claim that selecting a hit really seeks is
## `tests/test_value_origin_jump.nim`'s, on a real session, through this very
## `PaletteEntry.command`.
##
## A MISSING PROGRAM IS A FAILURE, NOT A SKIP — it is checked into this repo, so
## its absence is a broken checkout and not a missing prerequisite.
##
## ## THE ORACLE IS `isonim-tui`, CALLED DIRECTLY
##
## `app/views/command_palette.rank` is the code under test. The expected
## ordering is computed here by calling `isonim_tui/command/fuzzy`'s
## `newMatcher(query).match(text)` on each entry — a DIFFERENT call into the
## same library, not a second copy of its arithmetic — and comparing. What that
## asserts is exactly what this module is responsible for: that it loses no
## entry, invents none, joins each `Hit` back to the right entry, and orders by
## the library's own rule. It asserts nothing about the heuristic itself, which
## is `isonim-tui`'s to test (`tests/test_fuzzy_matcher_corpus.nim`) and which
## this front-end must not fork.
##
## Beside that there is a NON-CIRCULAR property: for the query `cdmg`, the
## entry `calculate_damage` must score strictly higher than EVERY other entry
## in the index. That is a statement about the fixture and the heuristic
## together, and a ranking bug that preserved order-by-score would still be
## caught by the equality above.
##
## ## THE TIMING GATE IS A BEST-OF, AND THE REASON IS STATED
##
## The gate is about the ALGORITHM's cost. A scheduler preemption is not the
## algorithm, so the assertion is on the MINIMUM of `GateRuns` runs and every
## one is echoed. Each run does exactly the same work and each is cold —
## `rankWith` calls `fuzzy.newMatcher` and `searchProvider` calls it again, and
## both build a fresh `(query, candidate)` cache — so the minimum is the
## cleanest slot the scheduler gave, not the cheapest query.
##
## ## Templates, not procs, for anything that calls `check`

import std/[algorithm, monotimes, os, strutils, times, unittest]

import isonim_tui

import ../commands/interpreter
import ../views/command_palette

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 90

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureProgram = "test-programs/noir_space_ship"
  FixtureSources = ["src/main.nr", "src/shield.nr"]

  GateSymbols = 2000
    ## CTUI-10's verification gate: "Fuzzy search over 2,000 symbols < 8 ms."
  GateBudgetMs = 8
  GateRuns = 9
    ## NINE, not five, and the reason is a measurement rather than a
    ## preference. On this 24-core host the same query measures 4.1 ms best-of-
    ## five idle and 7.2 ms best-of-five under 48 busy loops (load 18.5) — a
    ## 10% margin on a gate the lane has to keep passing. More samples of the
    ## SAME work narrows the estimator without touching the budget: the
    ## assertion is still "< 8 ms" and the runs are still cold and identical.

  IntendedQuery = "cdmg"
    ## A SUBSEQUENCE, not a prefix and not a substring — `c`, `d`, `m`, `g` in
    ## order inside `calculate_damage`. Chosen because it is a subsequence of
    ## exactly one symbol in this program: the other two `calculate_*`
    ## functions have no `m` after their first `d`.
  IntendedSymbol = "calculate_damage"

  ExpectedFunctions = 6
    ## `main`, `iterate_asteroids`, `calculate_damage`,
    ## `calculate_shield_regeneration`, `calculate_remaining_shield_pct`,
    ## `status_report`. Counted from the two `.nr` files on 2026-09-06 and
    ## asserted, so an extractor that silently stopped early is red here.
  ExpectedBindings = 14
    ## Distinct `let` bindings across the same two files, counted from them on
    ## 2026-09-06.

  MultiQuery = "cal"
    ## A query with SEVERAL hits, needed because `IntendedQuery` deliberately
    ## has exactly one and a selection cannot be moved through a list of one.

# ---------------------------------------------------------------------------
# Real symbols, off disk
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## `<repo>`, from this file: `<repo>/src/frontend/tui/app/tests/<this>.nim`.
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 5:
    dir = dir.parentDir()
  dir

proc identifierAt(line: string; start: int): string =
  ## The identifier beginning at `start`, or "".
  var i = start
  while i < line.len and (line[i] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}):
    inc i
  line[start ..< i]

proc symbolsAfter(line, keyword: string): string =
  ## The identifier a `fn ` / `let ` introduces on this line, or "".
  ##
  ## Deliberately literal about Noir's surface syntax: `fn name(`,
  ## `pub fn name(`, `let name =`, `let mut name =`. A parser would be a second
  ## thing to keep true, and what this suite needs is REAL NAMES, not a
  ## complete symbol table.
  var text = line.strip()
  if text.startsWith("pub "):
    text = text[4 .. ^1]
  if not text.startsWith(keyword & " "):
    return ""
  var rest = text[keyword.len + 1 .. ^1].strip()
  if keyword == "let" and rest.startsWith("mut "):
    rest = rest[4 .. ^1].strip()
  identifierAt(rest, 0)

proc readFixtureSymbols(): (seq[string], seq[string], seq[string]) =
  ## `(functions, bindings, files)` from the recorded program's own source.
  var functions: seq[string] = @[]
  var bindings: seq[string] = @[]
  var files: seq[string] = @[]
  for rel in FixtureSources:
    let path = repoRoot() / FixtureProgram / rel
    if not fileExists(path):
      raise newException(IOError,
        "the fixture program is missing: " & path & " does not exist. " &
        "`test-programs/noir_space_ship/` is checked into THIS repository — " &
        "its absence is a broken checkout, not a missing prerequisite, and " &
        "there is nothing to skip.")
    files.add path
    for line in readFile(path).splitLines():
      let fn = symbolsAfter(line, "fn")
      if fn.len > 0 and fn notin functions:
        functions.add fn
      let binding = symbolsAfter(line, "let")
      if binding.len > 0 and binding notin bindings:
        bindings.add binding
  (functions, bindings, files)

proc gateIndex(base: seq[string]): seq[PaletteEntry] =
  ## `GateSymbols` entries whose stems are the fixture's own names.
  ##
  ## The fixture has nineteen distinct symbols and the gate names two thousand,
  ## so the names are CYCLED with an ordinal suffix. Stated rather than hidden:
  ## the gate is about the matcher's cost per candidate, and a candidate built
  ## from a real identifier has the length and the word-boundary structure the
  ## heuristic's `first_letters` bonus keys on — which a run of random strings
  ## would not.
  result = @[]
  var i = 0
  while result.len < GateSymbols:
    let stem = base[i mod base.len]
    result.add PaletteEntry(kind: pekFunction, text: stem & "_" & $i,
                            help: "synthetic gate entry " & $i,
                            command: ":goto " & $i)
    inc i

proc independentBest(entries: openArray[PaletteEntry];
                     query: string): (string, float64, int) =
  ## `(text, score, matchCount)` computed by calling `isonim-tui`'s matcher
  ## DIRECTLY. The oracle — see this file's header.
  let m = newMatcher(query)
  var bestText = ""
  var best = 0.0
  var matched = 0
  for e in entries:
    let s = m.match(e.text)
    if s > 0.0:
      inc matched
      if s > best or (s == best and e.text < bestText):
        best = s
        bestText = e.text
  (bestText, best, matched)

# ---------------------------------------------------------------------------

let (fixtureFunctions, fixtureBindings, fixtureFiles) = readFixtureSymbols()

proc fixtureIndex(): seq[PaletteEntry] =
  ## §4.2's three kinds — "files, functions, commands" — over real things.
  result = @[]
  for spec in Spec43Commands:
    result.add commandEntry(spec.name, spec.summary, spec.argument)
  var tick = 100'u64
  for i, fn in fixtureFunctions:
    result.add functionEntry(fn, fixtureFiles[0], i + 1, tick)
    tick += 37
  for path in fixtureFiles:
    result.add fileEntry(path, 1)

suite "CTUI-10: the palette ranks isonim-tui's way over real symbols":

  test "the index is built from the recorded program's own source":
    checkpoint("fixture sources: " & fixtureFiles.join(", "))
    ck fixtureFiles.len == FixtureSources.len
    for path in fixtureFiles:
      ck fileExists(path)
    checkpoint("functions: " & fixtureFunctions.join(", "))
    ck fixtureFunctions.len == ExpectedFunctions
    ck IntendedSymbol in fixtureFunctions
    checkpoint("let bindings: " & fixtureBindings.join(", "))
    ck fixtureBindings.len == ExpectedBindings
    # THE EXTRACTOR IS NOT SATISFIED BY AN EMPTY FILE: every name it found is
    # really in the text it read, checked back against the file.
    let joined = readFile(fixtureFiles[0]) & readFile(fixtureFiles[1])
    var verified = 0
    for name in fixtureFunctions & fixtureBindings:
      if joined.contains(name):
        inc verified
    ck verified == fixtureFunctions.len + fixtureBindings.len

    let index = fixtureIndex()
    checkpoint("index entries: " & $index.len)
    ck index.len == Spec43Commands.len + ExpectedFunctions + fixtureFiles.len
    let (wellFormed, why) = indexIsWellFormed(index)
    if not wellFormed:
      checkpoint("index is malformed: " & why)
    ck wellFormed
    ck why == ""
    # …and the well-formedness check REFUSES a duplicate, which is what makes
    # the line above a statement rather than a formality.
    var duplicated = index
    duplicated.add index[0]
    let (dupOk, dupWhy) = indexIsWellFormed(duplicated)
    ck not dupOk
    ck dupWhy.contains(index[0].text)
    var commandless = @[PaletteEntry(kind: pekFile, text: "x", command: "")]
    let (cmdOk, cmdWhy) = indexIsWellFormed(commandless)
    ck not cmdOk
    ck cmdWhy.contains("runs nothing")

  test "a subsequence ranks the intended symbol first; selecting navigates":
    var model = initPaletteModel(fixtureIndex())
    let discovered = model.open()
    checkpoint("discovery hits: " & $discovered)
    # THE DISCOVERY VIEW IS THE WHOLE INDEX, in index order — §4.3's published
    # order first, so a palette opened with no query is a menu of what exists.
    ck discovered == model.entries.len
    ck model.hits[0].entry.text == ":" & Spec43Commands[0].name
    ck model.selected == 0

    let count = model.setQuery(IntendedQuery)
    checkpoint("`" & IntendedQuery & "` -> " & $count & " hit(s)")
    ck count > 0
    ck count < model.entries.len              # it really filtered
    let (hasTop, top) = model.topHit()
    ck hasTop
    checkpoint("top hit: " & top.entry.text & " score " & $top.score)
    ck top.entry.text == IntendedSymbol
    ck top.entry.kind == pekFunction
    ck top.offsets.len == IntendedQuery.len

    # THE ORACLE: `isonim-tui`'s matcher, called directly on the same index.
    let (oracleText, oracleScore, oracleMatched) =
      independentBest(model.entries, IntendedQuery)
    checkpoint("oracle best: " & oracleText & " " & $oracleScore & " over " &
               $oracleMatched & " match(es)")
    ck oracleText == IntendedSymbol
    ck count == oracleMatched
    ck top.score == oracleScore
    # …and it is STRICTLY better than every other entry, which is the
    # non-circular property. Computed from the oracle, not from `rank`.
    let m = newMatcher(IntendedQuery)
    var beatenBy = 0
    var scored = 0
    for e in model.entries:
      if e.text == IntendedSymbol:
        continue
      inc scored
      if m.match(e.text) >= oracleScore:
        inc beatenBy
    checkpoint("entries scored against the top hit: " & $scored)
    ck scored == model.entries.len - 1
    ck beatenBy == 0

    # THE WHOLE ORDERING is the library's, entry for entry.
    var expected: seq[(float64, string)] = @[]
    for e in model.entries:
      let s = m.match(e.text)
      if s > 0.0:
        expected.add (s, e.text)
    expected.sort(proc(a, b: (float64, string)): int =
      if a[0] > b[0]: -1 elif a[0] < b[0]: 1 else: cmp(a[1], b[1]))
    var got: seq[(float64, string)] = @[]
    for h in model.hits:
      got.add (h.score, h.entry.text)
    checkpoint("ranked: " & $got)
    ck got == expected
    ck got.len == count

    # SELECTING IT NAVIGATES. The palette answers a §4.3 line and nothing else
    # — see `command_palette.nim`'s header — so "navigates" is a claim about
    # the line, and it is checked by parsing it with the interpreter.
    let (hasSelection, line) = model.selectedCommand()
    checkpoint("selected command: " & line)
    ck hasSelection
    ck line.startsWith(":goto ")
    let invocation = parseCommand(line)
    ck invocation.status == csOk
    ck invocation.kind == cmdGoto
    ck invocation.argument.len > 0
    let (bound, action) = keyActionFor(cmdGoto)
    ck bound
    ck action == kaSeekToTick

    # `cdmg` is a subsequence of exactly ONE symbol in this program, which is
    # what makes "the intended match ranks first" a statement rather than a
    # coincidence — and it is asserted as an equality so a fixture that grew a
    # second `calculate_*_damage_*` says so here.
    ck count == 1

    # MOVING THE SELECTION needs a query with more than one hit, so it is a
    # different query and the count is asserted before the walk.
    let many = model.setQuery(MultiQuery)
    checkpoint("`" & MultiQuery & "` -> " & $many & " hit(s)")
    ck many > 1
    ck model.selected == 0
    let (_, first) = model.selectedCommand()
    ck model.moveSelection(1)
    ck model.selected == 1
    let (_, second) = model.selectedCommand()
    ck second != first
    for _ in 0 ..< many - 1:
      discard model.moveSelection(1)
    ck model.selected == 0
    let (_, wrapped) = model.selectedCommand()
    ck wrapped == first
    # …and backwards wraps the other way.
    ck model.moveSelection(-1)
    ck model.selected == many - 1
    discard model.setQuery(IntendedQuery)

    # A QUERY THAT MATCHES NOTHING SAYS SO, and answers no command.
    ck model.setQuery("qqqqqq") == 0
    ck model.selected == -1
    let (noSelection, noLine) = model.selectedCommand()
    ck not noSelection
    ck noLine == ""
    let rows = paletteRows(model, 60, 6)
    ck rows.len == 6
    ck rows[2].contains(NoResultsText)

    # Backspacing back to a prefix restores the hits — the LIVE COUNT, per
    # keystroke, over the same index.
    ck model.setQuery("") == model.entries.len
    var typed = 0
    var counts: seq[int] = @[]
    for ch in IntendedQuery:
      inc typed
      counts.add model.typeChar($ch)
    checkpoint("counts per keystroke: " & $counts)
    ck typed == IntendedQuery.len
    ck counts.len == IntendedQuery.len
    ck counts[^1] == count
    # …and the count is MONOTONICALLY NON-INCREASING, because every keystroke
    # adds a constraint. Asserted as a property of the sweep rather than as a
    # list of numbers, so it survives a re-recorded fixture.
    var decreasing = true
    for i in 1 ..< counts.len:
      if counts[i] > counts[i - 1]:
        decreasing = false
    ck decreasing
    var back = 0
    for _ in 0 ..< IntendedQuery.len:
      inc back
      discard model.backspace()
    ck back == IntendedQuery.len
    ck model.query == ""
    ck model.hits.len == model.entries.len

  test "the palette paints its rows, its selection and its matched columns":
    var model = initPaletteModel(fixtureIndex())
    discard model.open()
    discard model.setQuery(IntendedQuery)
    let width = 64
    let height = 8
    let rows = paletteRows(model, width, height)
    ck rows.len == height
    for row in rows:
      ck cellWidthOf(row) == width
    ck rows[0].startsWith(PaletteTitle)
    ck rows[1].startsWith(PalettePrompt & IntendedQuery)
    ck rows[2].contains(IntendedSymbol)

    var g = newStyledGrid(width, height)
    paint(g, model, 0, 0, width, height)
    ck g.rowText(0) == rows[0]
    ck g.rowText(2) == rows[2]
    # The selected row carries the highlight background on every cell.
    var highlighted = 0
    for col in 0 ..< width:
      if g.styleAt(2, col).bg == command_palette.SelectedBackground:
        inc highlighted
    checkpoint("highlighted cells on the selected row: " & $highlighted)
    ck highlighted == width
    # …and the row BELOW it does not, which is the positive twin.
    var spill = 0
    for col in 0 ..< width:
      if g.styleAt(3, col).bg == command_palette.SelectedBackground:
        inc spill
    ck spill == 0
    # The matched characters are accented, one cell per query character.
    var accented = 0
    for col in 0 ..< width:
      if g.styleAt(2, col).fg == command_palette.MatchStyle.fg:
        inc accented
    checkpoint("accented cells: " & $accented)
    ck accented == IntendedQuery.len
    # A closed palette paints nothing.
    model.close()
    ck paletteRows(model, width, height).len == 0
    ck model.hits.len == 0
    ck model.selected == -1

  test "fuzzy search over 2,000 symbols is inside the gate":
    let base = fixtureFunctions & fixtureBindings
    ck base.len == ExpectedFunctions + ExpectedBindings
    let index = gateIndex(base)
    checkpoint("gate index: " & $index.len)
    ck index.len == GateSymbols
    let (wellFormed, why) = indexIsWellFormed(index)
    if not wellFormed:
      checkpoint(why)
    ck wellFormed

    # THE MEASUREMENT IS OF ONE KEYSTROKE, which is `setQuery` on a model whose
    # provider and lookup were built when the index was set — the cost the user
    # actually pays. Building them per query is a different (and larger) number,
    # and `PaletteModel.provider`'s own comment records it.
    var model = initPaletteModel(index)
    discard model.open()
    var elapsed: seq[int64] = @[]
    var hitCounts: seq[int] = @[]
    for _ in 0 ..< GateRuns:
      # THE SAME QUERY EVERY RUN, and every run is COLD: `rankWith` calls
      # `newMatcher(query)` and `searchProvider` calls it again, and
      # `fuzzy.newMatcher` builds a fresh `FuzzySearch` with an empty
      # `(query, candidate)` cache. So repeating the query measures the search
      # and never a lookup — checked by reading
      # `isonim-tui/src/isonim_tui/command/fuzzy.nim`'s `newMatcher`, not
      # assumed. Varying the query instead would compare five different amounts
      # of work and make "the best of five" mean the cheapest query.
      let started = getMonoTime()
      let n = model.setQuery(IntendedQuery)
      elapsed.add (getMonoTime() - started).inMicroseconds
      hitCounts.add n
      model.query = ""
    let best = min(elapsed)
    echo "CTUI-10 PALETTE GATE: ", GateSymbols, " symbols, query `",
         IntendedQuery, "` -> ", hitCounts[0], " hit(s); ", elapsed,
         " microseconds over ", GateRuns, " run(s); best ", best,
         " us against ", GateBudgetMs * 1000, " us"
    ck elapsed.len == GateRuns
    ck best < GateBudgetMs * 1000
    # THE SWEEP REALLY SWEPT: the first run's hit count is not zero — a matcher
    # that returned nothing would be very fast — and it is what the ORACLE says
    # over the same 2,000 candidates.
    ck hitCounts[0] > 0
    ck hitCounts.len == GateRuns
    let (_, _, oracleMatched) = independentBest(index, IntendedQuery)
    checkpoint("oracle matched " & $oracleMatched & " of " & $index.len)
    ck hitCounts[0] == oracleMatched
    # Every run did the SAME amount of work, which is what makes a best-of-five
    # a measurement of the algorithm rather than of the cheapest query.
    var disagreed = 0
    for n in hitCounts:
      if n != hitCounts[0]:
        inc disagreed
    ck disagreed == 0

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
