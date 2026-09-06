## test_keymap_no_conflicts.nim — CTUI-9, Tier 1, STRUCTURAL.
##
## ## What this suite is for, and why it is the load-bearing one
##
## CTUI-9: "a structural test over the keymap table: no key is bound twice in
## one mode, and every action named in §4.2 has a binding. This test is what
## keeps the implementation and the published table from drifting."
##
## ## THE ORACLE IS THE PUBLISHED DOCUMENT, PARSED
##
## The expected keybinding table is not transcribed here. It is READ, at run
## time, out of `codetracer-specs/Front-Ends/CodeTracer-TUI.md` §4.2 — the same
## markdown a reader of the specification sees — and compared against
## `app/input/keymap.defaultKeymap()`. So "the implementation and the published
## table cannot drift apart" is a property of a comparison rather than of two
## people having copied the same rows carefully.
##
## That also satisfies the rule this campaign has been bitten by most: AN
## EXPECTED VALUE MUST NEVER BE PRODUCED BY THE CODE UNDER TEST. A hand-written
## copy of §4.2 in this file would have been written from the same reading that
## produced `keymap.nim`, and the two would agree about a misreading.
##
## THE SPEC BEING ABSENT IS A FAILURE, NOT A SKIP. `docs/tui-testing.md`'s first
## test-quality rule and the Silent-Self-Pass audit are both explicit: a test
## that detects a missing prerequisite, returns early and is counted PASSED is
## the defect. The failure below names the path and the sibling checkout.
##
## ## The four checks, and what each one can catch that the others cannot
##
##   1. **Coverage** — every action §4.2 names has at least one binding, and the
##      keymap names no §4.2 action the document does not. Catches a row
##      implemented and forgotten, and a row invented here.
##   2. **Key-set equality, per row** — the components of the keys bound to a
##      row's action are exactly the backticked tokens in that row's Keybinding
##      cell. Catches `F10` bound where §4.2 says `F11`, which coverage cannot.
##   3. **Uniqueness, per mode** — no chord sequence bound twice, and no
##      sequence a proper PREFIX of another. The second half is the one that
##      matters: a bare `r` beside `rf` makes `rf` unreachable rather than
##      ambiguous, and only a structural check notices.
##   4. **Reachability** — every chord in the table is a name `keymap.keyName`
##      produces from a REAL xterm byte sequence. A binding spelled `Ctrl-W` or
##      `PgDn` is not a binding; it is a row nothing can ever match.
##
## ## No mocks
##
## Two files and no processes: the specification, and the table.
##
## ## Templates, not procs, for anything that calls `check`

import std/[algorithm, os, sequtils, strutils, tables, unittest]

import ../input/keymap
import ../input/modal_state

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 282

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  SpecRow = object
    ## One row of §4.2's markdown table.
    category: string
    keyCell: string
    tokens: seq[string]   ## the backticked spellings in the Keybinding cell
    action: string

const
  SpecSectionHeading = "### 4.2 Keybindings Reference Table"
  SpecRelativePath = "codetracer-specs/Front-Ends/CodeTracer-TUI.md"

  ExpectedSpecRows = 33
    ## §4.2's row count, counted from the document on 2026-09-06. Asserted so
    ## that a parser which silently stopped at the first odd row — or a table
    ## that lost a row — is red here rather than quietly checking less.

  ExpectedBindingCount = 85
    ## Every binding in `defaultKeymap()`, across all four modes. The
    ## NON-VACUITY FLOOR: every "for every binding …" sweep below is satisfied
    ## for free by an empty table, and this is the one assertion that is not.

  # Real xterm byte sequences, and the canonical name each must decode to.
  # This list is the "reachability" oracle of check 4, and it is written from
  # xterm's own ctlseqs document rather than from `keymap.nim`:
  # https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  KeyBytes = [
    ("\t", "Tab"), ("\x1b[Z", "Shift+Tab"),
    ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4"),
    ("z", "z"), ("n", "n"), ("N", "N"), ("p", "p"), ("s", "s"), ("b", "b"),
    ("f", "f"), ("r", "r"), ("c", "c"), ("o", "o"), ("O", "O"), ("j", "j"),
    ("k", "k"), ("l", "l"), ("h", "h"), ("m", "m"), ("x", "x"), ("q", "q"),
    ("g", "g"), ("G", "G"), ("t", "t"), ("i", "i"),
    ("[", "["), ("]", "]"), ("{", "{"), ("}", "}"), (".", "."),
    ("/", "/"), ("?", "?"), (":", ":"), (" ", "Space"),
    ("\r", "Enter"), ("\n", "Enter"), ("\x7f", "Backspace"),
    ("\b", "Backspace"), ("\x1b", "Esc"),
    ("\x1b[A", "Up"), ("\x1b[B", "Down"), ("\x1b[C", "Right"),
    ("\x1b[D", "Left"),
    ("\x15", "Ctrl+u"), ("\x04", "Ctrl+d"), ("\x10", "Ctrl+p"),
    ("\x03", "Ctrl+c"), ("\x17", "Ctrl+w"),
    ("\x1bOP", "F1"), ("\x1bOQ", "F2"),
    ("\x1b[15~", "F5"), ("\x1b[20~", "F9"), ("\x1b[21~", "F10"),
    ("\x1b[23~", "F11"),
    ("\x1b[15;2~", "Shift+F5"), ("\x1b[21;2~", "Shift+F10"),
    ("\x1b[23;2~", "Shift+F11"), ("\x1b[15;3~", "Alt+F5"),
    ("\x1b[21;5~", "Ctrl+F10"),
  ]

# ---------------------------------------------------------------------------
# Reading §4.2 out of the specification
# ---------------------------------------------------------------------------

proc specPath(): string =
  ## Where the published table lives, resolved from THIS FILE rather than from
  ## the working directory, so the suite answers the same way however it is
  ## invoked.
  ##
  ## `currentSourcePath` is `<repo>/src/frontend/tui/app/tests/<this>.nim`, so
  ## six `parentDir`s reach the repo root and a seventh reaches the workspace
  ## the sibling checkouts share (see `CLAUDE.md`: "the parent directory of the
  ## checkout IS the workspace root, by definition").
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 5:
    dir = dir.parentDir()
  dir.parentDir() / SpecRelativePath

proc backtickedTokens(cell: string): seq[string] =
  ## Every `…`-quoted spelling in a Keybinding cell, in order.
  result = @[]
  var i = 0
  while i < cell.len:
    if cell[i] == '`':
      let close = cell.find('`', i + 1)
      if close < 0:
        break
      result.add cell[i + 1 ..< close]
      i = close + 1
    else:
      inc i

proc cleanCell(cell: string): string =
  ## A markdown cell as text: trimmed, with bold markers removed.
  cell.strip().replace("**", "").strip()

proc readSpecRows(path: string): seq[SpecRow] =
  ## Parse §4.2's markdown table.
  ##
  ## Raises rather than returning an empty sequence when the heading or the
  ## table is missing: an empty oracle would make every comparison below pass
  ## vacuously, which is the exact shape of failure this campaign's audit
  ## catalogues.
  if not fileExists(path):
    raise newException(IOError,
      "the §4.2 oracle is missing: " & path & " does not exist. This suite " &
      "reads the published keybinding table out of the codetracer-specs " &
      "sibling checkout; clone it beside this repo (see CLAUDE.md on the " &
      "workspace layout) — there is nothing to configure and nothing to skip.")
  let text = readFile(path)
  var inSection = false
  var inTable = false
  var lastCategory = ""
  result = @[]
  for line in text.splitLines():
    if not inSection:
      if line.strip() == SpecSectionHeading:
        inSection = true
      continue
    let trimmed = line.strip()
    if trimmed.startsWith("###") or trimmed.startsWith("## "):
      break                                   # the next section: table is over
    if not trimmed.startsWith("|"):
      if inTable and trimmed.len == 0:
        continue
      continue
    let parts = trimmed.split('|')
    if parts.len < 5:
      continue
    let keyCell = parts[2]
    if keyCell.contains("---"):
      inTable = true                          # the header separator
      continue
    if cleanCell(parts[3]) == "Action":
      continue                                # the header row
    let category = cleanCell(parts[1])
    if category.len > 0:
      lastCategory = category
    result.add SpecRow(category: lastCategory, keyCell: keyCell.strip(),
                       tokens: backtickedTokens(keyCell),
                       action: cleanCell(parts[3]))
  if result.len == 0:
    raise newException(IOError,
      "found " & SpecSectionHeading & " in " & path & " but parsed no table " &
      "rows out of it. The oracle is empty, so every comparison in this " &
      "suite would pass without checking anything.")

proc componentsOf(spelling: string): seq[string] =
  ## A §4.2 spelling split into the tokens the document writes it with:
  ## `Ctrl+w h` -> @["Ctrl+w", "h"], `rf` -> @["rf"], `t <tick> Enter` ->
  ## @["t", "<tick>", "Enter"].
  spelling.splitWhitespace()

proc sortedUnique(items: seq[string]): seq[string] =
  result = @[]
  for s in items:
    if s notin result:
      result.add s
  result.sort()

# ---------------------------------------------------------------------------

let km = defaultKeymap()
let rows = readSpecRows(specPath())

suite "CTUI-9: the keymap is §4.2, and it has no conflicts":

  test "§4.2 is read out of the published specification, not out of this file":
    checkpoint("oracle: " & specPath())
    ck fileExists(specPath())
    checkpoint("parsed rows: " & $rows.len)
    ck rows.len == ExpectedSpecRows
    # Every row carries all four fields. A parser that dropped the action cell
    # would make the coverage check below compare two empty sets.
    var wellFormed = 0
    for row in rows:
      if row.category.len > 0 and row.tokens.len > 0 and row.action.len > 0:
        inc wellFormed
    ck wellFormed == ExpectedSpecRows
    # …and the categories are §4.2's own eight, which is what proves the parse
    # walked the WHOLE table rather than one block of it.
    let categories = sortedUnique(rows.mapIt(it.category))
    checkpoint("categories: " & categories.join(" | "))
    ck categories.len == 8
    for wanted in ["Command Mode", "Omniscient Stepping", "Pane Navigation",
                   "Search and Palette", "Source Navigation",
                   "Time-Travel Seeking", "Value Origin Tracking",
                   "Variables Tree"]:
      checkpoint("category present: " & wanted)
      ck wanted in categories

  test "every §4.2 action has a binding, and the keymap invents none":
    let published = sortedUnique(rows.mapIt(it.action))
    checkpoint("distinct published actions: " & $published.len)
    ck published.len == ExpectedSpecRows      # every row names a distinct action

    var implemented: seq[string] = @[]
    var unbound: seq[string] = @[]
    for a in KeyAction:
      if a == kaNone:
        continue
      if specSectionOf(a) != ssSpec42:
        continue
      let name = specAction(a)
      if name notin implemented:
        implemented.add name
      if km.bindingsOf(a).len == 0:
        unbound.add $a
    implemented.sort()

    var missing: seq[string] = @[]
    for name in published:
      if name notin implemented:
        missing.add name
    var extra: seq[string] = @[]
    for name in implemented:
      if name notin published:
        extra.add name
    if missing.len > 0:
      checkpoint("§4.2 actions with NO implementation: " & missing.join(", "))
    if extra.len > 0:
      checkpoint("actions the keymap claims are §4.2 but are not: " &
                 extra.join(", "))
    if unbound.len > 0:
      checkpoint("actions declared but bound to nothing: " & unbound.join(", "))
    ck missing.len == 0
    ck extra.len == 0
    ck unbound.len == 0
    ck implemented == published

    # THE THREE ACTIONS THAT ARE NOT IN §4.2 ARE EXACTLY THREE, AND NAMED.
    # `keymap.nim`'s header says why each exists; this is what stops a fourth
    # from arriving unannounced.
    var fromSpec41: seq[string] = @[]
    for a in KeyAction:
      if a != kaNone and specSectionOf(a) == ssSpec41:
        fromSpec41.add $a
    fromSpec41.sort()
    checkpoint("§4.1-sourced actions: " & fromSpec41.join(", "))
    ck fromSpec41 == @["commit-prompt", "enter-inspect", "prompt-backspace"]
    for a in [kaEnterInspect, kaCommitPrompt, kaPromptBackspace]:
      checkpoint("§4.1 action is bound: " & $a)
      ck km.bindingsOf(a).len > 0
      ck specAction(a) == ""

  test "each §4.2 row's keys are exactly the keys the keymap binds":
    var comparisons = 0
    var wrong: seq[string] = @[]
    for row in rows:
      inc comparisons
      var bound: seq[string] = @[]
      for a in KeyAction:
        if a == kaNone or specAction(a) != row.action:
          continue
        for bnd in km.bindingsOf(a):
          for component in componentsOf(bnd.spelling):
            if component notin bound:
              bound.add component
      bound.sort()
      let wanted = sortedUnique(row.tokens)
      if bound != wanted:
        wrong.add row.action & ": spec " & wanted.join(",") & " vs keymap " &
          bound.join(",")
    if wrong.len > 0:
      for w in wrong:
        checkpoint(w)
    ck wrong.len == 0
    # THE SWEEP'S OWN SIZE, against its parameter rather than against a number
    # from a run: a `continue` that skipped a category would leave the loop
    # above with nothing to disagree about.
    checkpoint("rows compared: " & $comparisons)
    ck comparisons == ExpectedSpecRows
    ck comparisons == rows.len

  test "no chord sequence is bound twice, or unreachable, in any mode":
    var modesChecked = 0
    var pairsCompared = 0
    var duplicates: seq[string] = @[]
    var shadowed: seq[string] = @[]
    var totalBindings = 0
    for mode in ModalMode:
      inc modesChecked
      let inMode = km.bindingsFor(mode)
      totalBindings += inMode.len
      for i in 0 ..< inMode.len:
        for j in 0 ..< inMode.len:
          if i == j:
            continue
          inc pairsCompared
          let a = inMode[i]
          let bnd = inMode[j]
          if a.chords == bnd.chords:
            let note = $mode & " " & a.chords.join(" ") & ": " & $a.action &
              " and " & $bnd.action
            if note notin duplicates:
              duplicates.add note
          elif a.chords.len < bnd.chords.len and
               bnd.chords[0 ..< a.chords.len] == a.chords:
            # `a` SHADOWS `bnd`: a user who types `a`'s sequence can never
            # reach `bnd`, because the shorter one fires first.
            shadowed.add $mode & ": " & a.chords.join(" ") & " (" & $a.action &
              ") makes " & bnd.chords.join(" ") & " (" & $bnd.action &
              ") unreachable"
    if duplicates.len > 0:
      for d in duplicates:
        checkpoint("DOUBLE BINDING " & d)
    if shadowed.len > 0:
      for s in shadowed:
        checkpoint("UNREACHABLE " & s)
    ck duplicates.len == 0
    ck shadowed.len == 0
    ck modesChecked == 4
    ck totalBindings == ExpectedBindingCount
    ck totalBindings == km.bindings.len
    # The comparison count is the sum of n*(n-1) over the four modes, computed
    # here from the per-mode sizes rather than copied from a run.
    var expectedPairs = 0
    for mode in ModalMode:
      let n = km.bindingsFor(mode).len
      expectedPairs += n * (n - 1)
    checkpoint("ordered pairs compared: " & $pairsCompared & " over " &
               $totalBindings & " bindings")
    ck pairsCompared == expectedPairs
    ck pairsCompared > 0

    # THE MUTATION ARM. The check above must be able to FAIL, or it is
    # indistinguishable from one that is not reading the table. A bare `r`
    # planted beside §4.2's `rf` is the exact defect it exists to catch.
    var mutated = defaultKeymap()
    mutated.bindings.add Binding(mode: mmNormal, spelling: "r", chords: @["r"],
                                 action: kaStepInto)
    var mutantShadows = 0
    let mutatedNormal = mutated.bindingsFor(mmNormal)
    for i in 0 ..< mutatedNormal.len:
      for j in 0 ..< mutatedNormal.len:
        if i == j: continue
        let a = mutatedNormal[i]
        let bnd = mutatedNormal[j]
        if a.chords.len < bnd.chords.len and
           bnd.chords[0 ..< a.chords.len] == a.chords:
          inc mutantShadows
    checkpoint("planted a bare `r`: " & $mutantShadows & " shadowing pair(s)")
    # Exactly two: `r` makes `rf` unreachable and `rc` unreachable.
    ck mutantShadows == 2

  test "every chord in the table is reachable from real xterm bytes":
    # `keyName` is asserted against the byte sequences first, so the name set
    # below is a fact about the DECODER rather than a list this file also
    # invented.
    var decoded = 0
    var names: seq[string] = @[]
    for pair in KeyBytes:
      inc decoded
      let got = keyName(pair[0])
      checkpoint(pair[0].escape() & " -> '" & got & "' want '" & pair[1] & "'")
      ck got == pair[1]
      if got notin names:
        names.add got
    ck decoded == KeyBytes.len
    ck decoded == 62

    var unreachable: seq[string] = @[]
    var chordsChecked = 0
    for bnd in km.bindings:
      ck bnd.chords.len > 0
      for chord in bnd.chords:
        inc chordsChecked
        if chord notin names:
          unreachable.add $bnd.mode & " " & bnd.spelling & ": '" & chord & "'"
    if unreachable.len > 0:
      for u in unreachable:
        checkpoint("UNREACHABLE CHORD " & u)
    ck unreachable.len == 0
    checkpoint("chords checked: " & $chordsChecked)
    # Every binding contributes one chord, plus one extra for each of the SEVEN
    # two-chord bindings §4.2 has: `Ctrl+w` h/j/k/l, `rf`, `rc` and `g` `g`.
    var twoChord = 0
    for bnd in km.bindings:
      if bnd.chords.len == 2:
        inc twoChord
    ck twoChord == 7
    ck chordsChecked == ExpectedBindingCount + twoChord

    # …and the decoder REFUSES what is not a key, so "every chord decodes" is
    # not satisfied by a decoder that names everything.
    for junk in ["", "\x1b[<0;12;5M", "\x1b[", "\x1b[99~", "\x1b[1;9P",
                 "\x1b[15;99~", "\x1bOZ", "\x1b[0;1;2X"]:
      checkpoint("must not decode: " & junk.escape())
      ck keyName(junk) == ""

  test "§4.2's `n` is bound in two modes to two different actions":
    var boundIn: seq[string] = @[]
    var actions: seq[KeyAction] = @[]
    for bnd in km.bindings:
      if bnd.chords == @["n"]:
        boundIn.add $bnd.mode
        if bnd.action notin actions:
          actions.add bnd.action
    boundIn.sort()
    checkpoint("`n` is bound in: " & boundIn.join(", ") & " -> " & $actions)
    ck boundIn == @["NORMAL", "SEARCH"]
    ck actions.len == 2
    ck kaStepOver in actions
    ck kaNextMatch in actions
    # The resolution is TOTAL: `n` is bound in exactly the two modes, so there
    # is no third mode where §4.2's collision is left unresolved.
    ck boundIn.len == 2
    # `N` exists only in SEARCH, which is what makes the pair a pair rather
    # than a coincidence.
    var nUpper: seq[string] = @[]
    for bnd in km.bindings:
      if bnd.chords == @["N"]:
        nUpper.add $bnd.mode
    ck nUpper == @["SEARCH"]

  test "every action a mode binds raises the modal event §4.1 gives it":
    # The keymap and the state machine agree about which keys change the mode.
    # Without this, `Ctrl+p` could be bound and open nothing.
    var mapped = 0
    let expected = {
      kaOpenCommandPrompt: meOpenCommand,
      kaCommandPalette: meOpenCommand,
      kaSearchForward: meOpenSearchForward,
      kaSearchBackward: meOpenSearchBackward,
      kaEnterInspect: meOpenInspect,
      kaCommitPrompt: meCommit,
      kaReturnToNormal: meCancel,
    }.toTable
    for a in KeyAction:
      let (raises, ev) = modalEventFor(a)
      if expected.hasKey(a):
        inc mapped
        checkpoint($a & " must raise " & $expected[a])
        ck raises
        ck ev == expected[a]
      else:
        checkpoint($a & " must raise nothing")
        ck not raises
    ck mapped == 7
    # The palette is a COMMAND-mode surface — a reading of §4.2 recorded in
    # `keymap.nim`'s header — and this is the assertion that pins it.
    let (palRaises, palEvent) = modalEventFor(kaCommandPalette)
    ck palRaises
    ck palEvent == meOpenCommand

  test "a `.cttui-keys` file layers over the table and reports what it cannot":
    let base = defaultKeymap()
    let text = """
# CTUI-9 user keymap.
NORMAL  Ctrl+w  l  = focus-left      # deliberately crossed over
NORMAL  n          = -               # unbind step over
INSPECT y          = value-origin
"""
    let loaded = loadKeymap(base, text)
    ck loaded.errors.len == 0
    # The rebinding replaced rather than added.
    var crossed = 0
    for bnd in loaded.keymap.bindings:
      if bnd.mode == mmNormal and bnd.chords == @["Ctrl+w", "l"]:
        inc crossed
        ck bnd.action == kaFocusLeft
    ck crossed == 1
    # The unbind removed exactly one binding, and left `F10` — §4.2's other
    # spelling of the same action — alone.
    var nInNormal = 0
    var f10InNormal = 0
    for bnd in loaded.keymap.bindings:
      if bnd.mode == mmNormal and bnd.chords == @["n"]:
        inc nInNormal
      if bnd.mode == mmNormal and bnd.chords == @["F10"]:
        inc f10InNormal
    ck nInNormal == 0
    ck f10InNormal == 1
    # One added (`INSPECT y`), one removed (`NORMAL n`), one replaced
    # (`NORMAL Ctrl+w l`), so the total is unchanged.
    ck loaded.keymap.bindings.len == base.bindings.len

    # …and the ORIGINAL is untouched, which is what makes `base` reusable and
    # what stops a user's file from editing the product's defaults in place.
    var nInBase = 0
    for bnd in base.bindings:
      if bnd.mode == mmNormal and bnd.chords == @["n"]:
        inc nInBase
    ck nInBase == 1

    # EVERY WAY A LINE CAN BE WRONG IS REPORTED, one per kind, with its number.
    let bad = """
NORMAL n step-over
VISUAL n = step-over
NORMAL n = teleport
NORMAL = step-over
"""
    let broken = loadKeymap(base, bad)
    var kinds: seq[KeymapErrorKind] = @[]
    for e in broken.errors:
      kinds.add e.kind
      checkpoint(describeError(e))
    ck broken.errors.len == 4
    ck kinds == @[keSyntax, keUnknownMode, keUnknownAction, keEmptyChords]
    ck broken.errors[0].line == 1
    ck broken.errors[1].line == 2
    ck broken.errors[2].line == 3
    ck broken.errors[3].line == 4
    # A file of nothing but errors changes NOTHING, which is the property that
    # makes reporting them worth doing.
    ck broken.keymap.bindings.len == base.bindings.len
    ck describeError(broken.errors[1]).contains("VISUAL")
    ck describeError(broken.errors[1]).startsWith(KeymapFileName & ":2:")

    # THE FILE ITSELF. `loadKeymapFile` is what makes the table "loadable from
    # a `.cttui-keys` file" rather than from a string somebody else read.
    let dir = getTempDir() / "ctui9-keymap-" & $getCurrentProcessId()
    createDir(dir)
    let path = dir / KeymapFileName
    writeFile(path, text)
    let fromFile = loadKeymapFile(base, path)
    ck fromFile.errors.len == 0
    ck fromFile.keymap.bindings.len == loaded.keymap.bindings.len
    var crossedInFile = 0
    for bnd in fromFile.keymap.bindings:
      if bnd.mode == mmNormal and bnd.chords == @["Ctrl+w", "l"] and
         bnd.action == kaFocusLeft:
        inc crossedInFile
    ck crossedInFile == 1
    # A MISSING FILE IS NOT AN ERROR and changes nothing — nobody is required
    # to have one. The positive twin is the load above, through the same call.
    removeFile(path)
    let absent = loadKeymapFile(base, path)
    ck absent.errors.len == 0
    ck absent.keymap.bindings.len == base.bindings.len
    removeDir(dir)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
