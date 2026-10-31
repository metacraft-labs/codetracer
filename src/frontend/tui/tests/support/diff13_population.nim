## diff13_population.nim — DIFF-13's POPULATION, derived from the tables
## (PLAT-68, "Differential — the cross-front-end gate (KL-6)").
##
## Base-Keymaps-And-Layer-Stack.md KL-6: *the same configuration, the same
## base and the same scope path yield the same operation on every front-end.*
## This module says WHICH tuples that is asserted over, and what the shared
## router answers for each, so the terminal, GPUI and the desktop can each be
## held to the one answer:
##
##   * every row of the four bases (`base_keymaps.keymapOf`) in every
##     situation whose scope path puts the row's table on it — a row is
##     probed by its FIRST chord (a longer sequence answers `pending` there,
##     which is compared like any answer);
##   * the user layer (`userKeymapText`): per situation, one row that
##     OVERRIDES a base row of the situation's innermost table, one REMOVAL of
##     another, one `when`-SPLIT pair, and one GLOBAL row shadowing an inner
##     base row — every one tagged with its base;
##   * the §3.10 legacy fallbacks (rows whose `when` reads `keyProtocol ==
##     legacy`), which only a terminal without extended key reporting sends.
##
## The situations are DECLARED here — their scope path and the ViewModels'
## facts in them — because the scope-path half of the gate compares each
## front-end's own producer with the declaration; the suite and the desktop
## capture put each front-end in the situation by input.
##
## Everything a front-end cannot express is COUNTED and named
## (`Inexpressible`), never dropped: a row for another platform, a chord a
## device has no form for, a row that reads `frontEnd`.
##
## Test support (the suite's driver); pure.

import std/[algorithm, json, sets, strutils, tables]

import ../../../viewmodel/keymap/base_keymaps
import ../../../viewmodel/keymap/base_rows
import ../../../viewmodel/keymap/context_keys
import ../../../viewmodel/keymap/editing_keymap
import ../../../viewmodel/keymap/keymap_router
import ../../../viewmodel/keymap/operation_catalogue
import ../../../viewmodel/keymap/user_keymap
import ../../../viewmodel/viewmodels/product_mode
import ../../../viewmodel/editor/editor_state
import ../../../../common/key_names
import ./key_devices

type
  DiffArm* = enum
    fTerminal = "terminal"
    fGpui = "gpui"
    fDesktop = "desktop"

  Situation* = object
    name*: string
    path*: ScopePath
      ## Declared. The editor element's id is `editor:<SourceToken>`; each
      ## front-end's id is normalised to it (`normalisedPath`).
    pushed*: seq[tuple[table, owner, label: string]]
      ## The overlay layers open in it, oldest first.
    palette*: bool
      ## The palette is open (its facts say so).
    writable*: bool
      ## The editor document has been made writable (`Ctrl+E`).
    opens*: string
      ## The operation that puts a front-end in it from the read-only editor
      ## (`palette.open-commands`, `editor.toggle-read-only`), typed with the
      ## base's OWN chord for it (`openingChords`); "" when the focus is put
      ## on a pane instead.

  Probe* = object
    ## One key asked in one situation under one base, with or without the
    ## user layer.
    base*: BaseKeymap
    situation*: int
    user*: bool
    chord*: string
      ## The canonical name.
    rows*: int
      ## How many rows of the population this key stands for there.
    expected*: array[DiffArm, string]
      ## `describeResolution` of the shared router for each front-end's
      ## delivery, over the declared path and facts.

  Inexpressible* = object
    base*: BaseKeymap
    situation*: int
    chord*: string
    frontEnd*: DiffArm
    why*: string

  Population* = object
    situations*: seq[Situation]
    probes*: seq[Probe]
    legacy*: seq[Probe]
      ## The legacy fallbacks: terminal-only, `expected[fTerminal]` under
      ## `keyProtocol == legacy`.
    inexpressible*: seq[Inexpressible]
    rowTuples*: int
      ## (base, situation, row) tuples, before keys were shared.
    rowTuplesByBase*: array[BaseKeymap, int]
    userRows*: int
    userTuples*: int

const
  SourceToken* = "<source>"
  HostPlatform* = pkLinux
  PaletteOwner* = "window"

func editorElement*(): ScopeElement = element(ekEditor, "editor:" & SourceToken)

func normalisedPath*(path: ScopePath): ScopePath =
  ## A front-end's path with the editor element's file path replaced by
  ## `SourceToken`: the three front-ends name the open file by the path they
  ## opened it at, which is the recording's and not the producer's choice.
  result = path
  for e in result.mitems:
    if e.kind == ekEditor and e.id.startsWith("editor:"):
      e.id = "editor:" & SourceToken

func deliveryOf*(f: DiffArm; protocol = kpKitty): KeyDelivery =
  case f
  of fTerminal: KeyDelivery(frontEnd: feTerminal, platform: HostPlatform,
                            keyProtocol: protocol)
  of fGpui: KeyDelivery(frontEnd: feGpui, platform: HostPlatform,
                        keyProtocol: kpNative)
  of fDesktop: KeyDelivery(frontEnd: feDesktop, platform: HostPlatform,
                           keyProtocol: kpNative)

func debugFacts*(editor: EditorFacts; palette = false): SessionFacts =
  SessionFacts(product: pmDebug, replayLoaded: true, editor: editor,
               paletteVisible: palette)

proc tablesOn*(s: Situation): HashSet[string] =
  ## The binding tables live in `s`: each path element's, the pushed layers',
  ## and the global table.
  result = initHashSet[string]()
  for e in s.path:
    for t in tablesOf(e): result.incl t
  for p in s.pushed: result.incl p.table
  result.incl GlobalTable

proc factsOf*(s: Situation; base: BaseKeymap): SessionFacts =
  ## What the ViewModels say in `s` under `base`: Debug mode on a recording;
  ## the read-only source view, or the document made writable — in insert
  ## mode under CUA and Emacs, which have no modes, and in normal mode under
  ## Vim and Kakoune, where a document opens in normal mode.
  let editor =
    if not s.writable: sourceViewFacts()
    elif base in {bkVim, bkKakoune}: EditorFacts(readOnly: false, mode: emNormal)
    else: EditorFacts(readOnly: false, mode: emInsert)
  debugFacts(editor, palette = s.palette)

proc routerFor*(base: BaseKeymap; delivery: KeyDelivery; s: Situation;
                user: UserKeymap): KeymapRouter =
  result = initKeymapRouter(base, delivery, ksCommand, user)
  for p in s.pushed:
    discard result.pushLayer(p.table, p.owner, p.label)

proc answer*(router: KeymapRouter; s: Situation; chord: string): string =
  ## What the shared router answers for `chord` in `s` — `route` on a copy,
  ## so nothing pending carries over.
  var r = router
  describeResolution(r.route(factsOf(s, router.base), s.path, nmNormal,
                             chord, 0))

proc openingChords*(s: Situation; base: BaseKeymap;
                    readOnlyEditor: Situation): seq[string] =
  ## The canonical chords `base` itself types `s.opens` with, from the
  ## read-only editor — what a user of that base presses. Empty when no key
  ## of the base reaches it there (Vim and Kakoune bind no key to
  ## `editor.toggle-read-only`).
  if s.opens.len == 0: return @[]
  let router = routerFor(base, deliveryOf(fTerminal), readOnlyEditor,
                         UserKeymap())
  let shown = router.chordFor(s.opens, factsOf(readOnlyEditor, base),
                              readOnlyEditor.path, nmNormal)
  if shown.len == 0: return @[]
  normalizeChordSequence(shown).splitWhitespace()

func readsDelivery(whenText: string): bool =
  whenText.contains("frontEnd") or whenText.contains("platform") or
    whenText.contains("keyProtocol")

func isLegacyRow(b: EditingBinding): bool =
  b.scope.whenText.contains("keyProtocol == legacy")

# ---------------------------------------------------------------------------
# The user layer
# ---------------------------------------------------------------------------

func innermostTable(s: Situation): string =
  ## The table the situation's focused element contributes first — a pushed
  ## layer when one is open.
  if s.pushed.len > 0: return s.pushed[^1].table
  for i in countdown(s.path.len - 1, 0):
    let ts = tablesOf(s.path[i])
    for t in ts:
      if t.startsWith(PaneTablePrefix): continue
      return t
  GlobalTable

proc plainOpsOf(table: string): seq[string] =
  for c in Catalogue:
    if c.table == table and c.arg == oaNone: result.add c.name

proc singleChordRows(base: BaseKeymap; table: string): seq[EditingBinding] =
  for b in keymapOf(base).keymap.bindings:
    if tableOf(b) == table and b.chords.len == 1 and b.scope.platforms == {} and
       not readsDelivery(b.scope.whenText) and b.scope.navModes == {} and
       b.scope.modes == {} and b.argument.len == 0:
      result.add b

proc userKeymapText*(situations: seq[Situation]): string =
  ## ONE `keybindings.json` for the whole population, every row tagged with
  ## its base (`base`), as a user would write it.
  var rows = newJArray()
  var done = initHashSet[(BaseKeymap, string)]()
  for base in BaseKeymap:
    for s in situations:
      let table = innermostTable(s)
      if (base, table) in done: continue
      done.incl (base, table)
      let candidates = singleChordRows(base, table)
      if candidates.len < 3: continue
      let ops = plainOpsOf(if table == EditorTable: EditorTable else: table)
      let spelled = proc (b: EditingBinding): string =
        writtenSequence(b.chords.join(" "))
      let opOf = proc (b: EditingBinding): string =
        if isCatalogued(b.operation): b.operation
        else: EditorOperationPrefix & b.operation
      # 1. An override: the first row's key, another operation of its table.
      var other = ""
      for o in ops:
        if o != candidates[0].operation: other = o; break
      if other.len > 0:
        rows.add %*{"key": spelled(candidates[0]), "command": other,
                    "base": $base}
      # 2. A removal of the second row.
      rows.add %*{"key": spelled(candidates[1]),
                  "command": "-" & opOf(candidates[1]), "base": $base}
      # 3. A `when`-split pair on the third row's key: one operation while
      #    the editor is read-only, another while it is not.
      rows.add %*{"key": spelled(candidates[2]), "command": "debugger.step-over",
                  "when": "editorReadOnly", "base": $base}
      rows.add %*{"key": spelled(candidates[2]), "command": "debugger.reverse-step-over",
                  "when": "!editorReadOnly", "base": $base}
      # 4. A global row shadowing an inner base row (VS Code's precedence,
      #    KL-11): the last candidate's key, a global operation.
      rows.add %*{"key": spelled(candidates[^1]),
                  "command": "debugger.continue", "base": $base}
  $rows

# ---------------------------------------------------------------------------
# The population
# ---------------------------------------------------------------------------

proc expectedFor(base: BaseKeymap; s: Situation; user: UserKeymap;
                 chord: string): array[DiffArm, string] =
  for f in DiffArm:
    result[f] = routerFor(base, deliveryOf(f), s, user).answer(s, chord)

proc derive*(situations: seq[Situation]): Population =
  ## The whole population: rows × situations, the user layer, the legacy
  ## fallbacks, and what each front-end cannot express.
  result.situations = situations
  let userText = userKeymapText(situations)
  let userKeymap = parseUserKeymap(userText)
  if userKeymap.errors.len > 0:
    var why: seq[string] = @[]
    for e in userKeymap.errors: why.add describe(e)
    raise newException(ValueError, "the population's own keybindings.json " &
                       "does not load: " & why.join("; "))
  result.userRows = userKeymap.rows.len
  for base in BaseKeymap:
    let rows = keymapOf(base).keymap.bindings
    for si, s in situations:
      let live = tablesOn(s)
      var keys = initOrderedTable[string, int]()
      for b in rows:
        if tableOf(b) notin live or b.chords.len == 0: continue
        if isLegacyRow(b):
          result.legacy.add Probe(base: base, situation: si,
            chord: b.chords[0], rows: 1,
            expected: [fTerminal: routerFor(base, deliveryOf(fTerminal,
                                                             kpLegacy), s,
                                            UserKeymap()).answer(s,
                                                                 b.chords[0]),
                       fGpui: "", fDesktop: ""])
          for f in [fGpui, fDesktop]:
            result.inexpressible.add Inexpressible(base: base, situation: si,
              chord: b.chords[0], frontEnd: f,
              why: "a §3.10 legacy fallback: only a terminal without " &
                   "extended key reporting sends it")
          continue
        inc result.rowTuples
        inc result.rowTuplesByBase[base]
        if b.scope.platforms != {} and HostPlatform notin b.scope.platforms:
          for f in DiffArm:
            result.inexpressible.add Inexpressible(base: base, situation: si,
              chord: b.chords[0], frontEnd: f,
              why: "a row for " & $b.scope.platforms & " only; the suite " &
                   "runs on " & $HostPlatform)
          continue
        keys.mgetOrPut(b.chords[0], 0) += 1
      # The user rows' keys, asked in the situation too.
      var userKeys = initOrderedTable[string, int]()
      for r in userKeymap.rows:
        if r.appliesTo(base) and r.chords.len > 0:
          userKeys.mgetOrPut(r.chords[0], 0) += 1
      for chord, n in keys:
        result.probes.add Probe(base: base, situation: si, user: false,
          chord: chord, rows: n,
          expected: expectedFor(base, s, UserKeymap(), chord))
      var withUser = keys
      for chord, n in userKeys:
        withUser.mgetOrPut(chord, 0) += n
        result.userTuples += n
      for chord, n in withUser:
        result.probes.add Probe(base: base, situation: si, user: true,
          chord: chord, rows: n,
          expected: expectedFor(base, s, userKeymap, chord))
  # Device forms: a probe a device has no form for is inexpressible there.
  for p in result.probes:
    if p.base in {bkVim, bkKakoune} and situations[p.situation].writable:
      result.inexpressible.add Inexpressible(base: p.base,
        situation: p.situation, chord: p.chord, frontEnd: fDesktop,
        why: "the desktop's editor (Monaco) has no modal editing: a " &
             "writable document takes text, in insert mode, under Vim and " &
             "Kakoune too (desktopFacts)")
    if kittyBytes(p.chord).len == 0:
      result.inexpressible.add Inexpressible(base: p.base,
        situation: p.situation, chord: p.chord, frontEnd: fTerminal,
        why: "no terminal sends it (a modifier pressed alone)")
    if gpuiKeystroke(p.chord).key.len == 0:
      result.inexpressible.add Inexpressible(base: p.base,
        situation: p.situation, chord: p.chord, frontEnd: fGpui,
        why: "GPUI delivers it as a modifier change, not a keystroke")
    if domKey(p.chord).code.len == 0:
      result.inexpressible.add Inexpressible(base: p.base,
        situation: p.situation, chord: p.chord, frontEnd: fDesktop,
        why: "a modifier's own keydown, not a key")

func expressible*(pop: Population; p: Probe; f: DiffArm): bool =
  for x in pop.inexpressible:
    if x.frontEnd == f and x.base == p.base and x.situation == p.situation and
       x.chord == p.chord:
      return false
  true

proc userText*(pop: Population): string = userKeymapText(pop.situations)

# ---------------------------------------------------------------------------
# The situations
# ---------------------------------------------------------------------------

const
  WindowElement = ScopeElement(kind: ekWindow, id: "window")
  SessionTab = ScopeElement(kind: ekTab, id: "tab:1")
    ## The first session tab — every front-end opens the recording in it.

proc declaredSituations*(): seq[Situation] =
  ## The six situations every front-end is put in, in Debug mode on a
  ## recording: what the scope path IS there. Panes sit under the session
  ## tab; the editor element under the editor pane; overlays hang at the
  ## window (the palette replaces the chain below it).
  @[
    Situation(name: "the read-only editor",
              path: @[WindowElement, SessionTab, pane("editor"),
                      editorElement()]),
    Situation(name: "the call trace (a list)",
              path: @[WindowElement, SessionTab, pane("calltrace")]),
    Situation(name: "the variables (a tree)",
              path: @[WindowElement, SessionTab, pane("state")]),
    Situation(name: "the event log (a list)",
              path: @[WindowElement, SessionTab, pane("eventLog")]),
    Situation(name: "the palette over the editor",
              path: @[WindowElement, element(ekOverlay, "palette"),
                      element(ekInput, "palette-query")],
              pushed: @[(PaletteTable, PaletteOwner, "PALETTE")],
              palette: true, opens: "palette.open-commands"),
    Situation(name: "the writable editor",
              path: @[WindowElement, SessionTab, pane("editor"),
                      editorElement()],
              writable: true, opens: "editor.toggle-read-only")]
