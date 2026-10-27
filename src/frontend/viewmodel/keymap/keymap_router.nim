## keymap_router.nim — THE ROUTER'S STATE and the one route from a key to an
## operation, shared by every front-end.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §5 and §6.1's shared half — the
## active base and why it is active, the user layer laid over it (removals,
## shadows, the rows this front-end cannot deliver), the pushed-layer stack,
## the pending prefix; the assembly of the layers resolution reads for a scope
## path (§5.1: the user pass then the base pass, each pushed layers newest
## first, then the path innermost first); the status line's mode label; the
## chord displayed for an operation (KL-8 / IR-3); and the shortcut reference.
##
## Refuses to own: how a front-end decodes a key or finds its scope path
## (§6.2), what an operation does (the front-end's dispatch onto the
## ViewModels), the rows (the bases, `user_keymap`) and resolution itself
## (`editing_keymap.resolveLayers`, the one resolver).
##
## ## THE CONTRACT (§6.1)
##
##     decode → canonical key ┐
##     focus  → scope path    ├─ route(router, facts, path, navMode, key, now)
##     the ViewModels' facts  ┘        → an operation | pending | character | nothing
##
## The router is a VALUE with no hidden state (§8 item 5): the stack and the
## pending prefix are its fields, displayed by `statusLabel`.
##
## Pure; compiles on C, JS and wasm32.

import std/[strutils, tables]

import ./base_keymaps
import ./base_rows
import ./context_keys
import ./editing_keymap
import ./layer_stack
import ./scope_path
import ./user_keymap
import ./when_expr

export layer_stack, scope_path, user_keymap

type
  BaseSource* = enum
    ## Why the active base is active (§3.6: the status line, the dialog and
    ## `:keymap` say so).
    ksDefault = "default"
    ksStored = "stored"
    ksFlag = "flag"
    ksCommand = "command"

  Shadow* = object
    ## A user row that takes a chord sequence from another row — the user's
    ## intent, by VS Code's rule (§5.1), and LISTED so it is never silent
    ## (§5.6).
    keyText*: string
    userIndex*: int
      ## The shadowing user row (0-based file index).
    shadowedSource*: LayerSource
    shadowedOperation*: string
    shadowedTable*: string
    shadowedIndex*: int
      ## For a user row shadowed by a later one, its file index; -1 for a
      ## base row.

  KeymapRouter* = object
    base*: BaseKeymap
    baseSource*: BaseSource
    delivery*: KeyDelivery
    effective*: EditingKeymap
      ## The shipped base minus the user's `-command` removals.
    user*: EditingKeymap
      ## The user's rows that apply over this base and that this front-end
      ## can deliver, in FILE ORDER (the trie is built later-first).
    userKeymap*: UserKeymap
      ## The parsed file, for the report.
    errors*: seq[UserRowError]
      ## The file's errors and the rows this front-end cannot deliver.
    shadows*: seq[Shadow]
    removed*: int
      ## Base rows the user's removals took out.
    stack*: LayerStack
    pending*: PendingChords
    importedEditor*: EditingKeymap
      ## PLAT-36: a `:source`d Vim configuration's editor table, used for the
      ## editor table instead of the shipped one while `hasImported`.
    hasImported*: bool
    baseByTable: Table[string, EditingKeymap]
    userByTable: Table[string, EditingKeymap]
      ## `effective` and `user` split by table once, when they change, so a
      ## key builds each table's trie from that table's rows alone.

  ReferenceEntry* = object
    ## One line of the shortcut reference: a binding live for the scope path,
    ## in resolution order, and what shadows it.
    layer*: string
    keyText*: string
    operation*: string
    shadowedBy*: string

# ---------------------------------------------------------------------------
# The user layer over the base
# ---------------------------------------------------------------------------

func deliverable(delivery: KeyDelivery; chords: seq[string]): bool =
  ## §7.4: a terminal without extended key reporting cannot send a chord the
  ## classic encoding has no bytes for.
  if delivery.frontEnd != feTerminal or delivery.keyProtocol != kpLegacy:
    return true
  for c in chords:
    if not legacyEncodable(c): return false
  true

func removes(r: UserRow; b: EditingBinding): bool =
  ## VS Code's removal rule: same key and command, and the same `when` when
  ## the removal gives one.
  b.chords == r.chords and b.operation == r.operation and
    b.argument == r.argument and
    (r.whenText.len == 0 or b.scope.whenText == r.whenText)

proc bindingOf(r: UserRow; base: BaseKeymap): EditingBinding =
  let table = tableOfOperation(r.operation)
  EditingBinding(
    model: base,
    scope: BindingScope(modes: {}, products: {},
                        panes: (if table == EditorTable: {epEditor} else: {}),
                        whenText: r.whenText, cond: r.cond),
    table: table, chords: r.chords, operation: r.operation, args: OpArgs(),
    argument: r.argument, spelling: r.keyText)

proc applyUserKeymap*(router: var KeymapRouter; uk: UserKeymap) =
  ## Lay `uk` over the active base: removals out of the base, rows in, every
  ## row this front-end cannot deliver reported, every shadow listed.
  router.userKeymap = uk
  router.errors = uk.errors
  router.effective = keymapOf(router.base).keymap
  router.user = EditingKeymap(bindings: @[])
  router.shadows = @[]
  router.removed = 0
  var userRows: seq[UserRow] = @[]
  for r in uk.rows:
    if not r.appliesTo(router.base): continue
    if r.removal:
      var kept: seq[EditingBinding] = @[]
      for b in router.effective.bindings:
        if removes(r, b): inc router.removed
        else: kept.add b
      router.effective.bindings = kept
      continue
    if not deliverable(router.delivery, r.chords):
      router.errors.add UserRowError(
        kind: ueUndeliverable, index: r.index, text: r.keyText,
        message: "'" & r.keyText & "' has no bytes on a terminal without " &
                 "extended key reporting (the Kitty protocol or " &
                 "modifyOtherKeys would deliver it)")
      continue
    userRows.add r
    router.user.bindings.add bindingOf(r, router.base)
  router.baseByTable = initTable[string, EditingKeymap]()
  for b in router.effective.bindings:
    router.baseByTable.mgetOrPut(tableOf(b), EditingKeymap()).bindings.add b
  router.userByTable = initTable[string, EditingKeymap]()
  for b in router.user.bindings:
    router.userByTable.mgetOrPut(tableOf(b), EditingKeymap()).bindings.add b
  # Shadows: a user row over a base row with the same sequence whose `when`s
  # can both hold, in any table; and an earlier user row in the same table.
  for i, u in router.user.bindings:
    for b in router.effective.bindings:
      if b.chords == u.chords and canBothHold(u.scope.cond, b.scope.cond):
        router.shadows.add Shadow(
          keyText: userRows[i].keyText, userIndex: userRows[i].index,
          shadowedSource: lsBase, shadowedOperation: b.operation,
          shadowedTable: tableOf(b), shadowedIndex: -1)
    for j in 0 ..< i:
      let earlier = router.user.bindings[j]
      if earlier.chords == u.chords and tableOf(earlier) == tableOf(u) and
         canBothHold(u.scope.cond, earlier.scope.cond):
        router.shadows.add Shadow(
          keyText: userRows[i].keyText, userIndex: userRows[i].index,
          shadowedSource: lsUser, shadowedOperation: earlier.operation,
          shadowedTable: tableOf(earlier), shadowedIndex: userRows[j].index)

proc initKeymapRouter*(base: BaseKeymap; delivery: KeyDelivery;
                       source = ksDefault;
                       user = UserKeymap()): KeymapRouter =
  result = KeymapRouter(base: base, baseSource: source, delivery: delivery,
                        stack: initLayerStack(), pending: PendingChords())
  result.applyUserKeymap(user)

proc switchBase*(router: var KeymapRouter; base: BaseKeymap;
                 source: BaseSource) =
  ## A new base, the same user file laid over it; a half-typed prefix is
  ## dropped (it belonged to the old base's grammar). Pushed layers stay —
  ## they are modes the user is in, not rows.
  router.base = base
  router.baseSource = source
  router.pending = PendingChords()
  router.hasImported = false
  router.applyUserKeymap(router.userKeymap)

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

proc factsFor(router: KeymapRouter; facts: SessionFacts;
              chordPending: bool): SessionFacts =
  ## The two facts that are the router's own, filled in so no front-end
  ## spells them. `chordPending` is passed in rather than read off
  ## `router.pending` so `chordFor` can ask about a prefix it is typing
  ## without a router of its own (`ChordLookup`).
  result = facts
  result.modalBase = router.base.isModal
  result.chordPending = chordPending

proc factsFor(router: KeymapRouter; facts: SessionFacts): SessionFacts =
  router.factsFor(facts, router.pending.chords.len > 0)

proc contextFor*(router: KeymapRouter; facts: SessionFacts;
                 path: ScopePath): ContextKeys =
  contextKeysOf(router.factsFor(facts), path, router.delivery)

proc scopeFor(router: KeymapRouter; facts: SessionFacts; path: ScopePath;
              navMode: NavigationMode; chordPending: bool): EditingScope =
  let f = router.factsFor(facts, chordPending)
  let ctx = contextKeysOf(f, path, router.delivery)
  var onEditor = false
  for e in path:
    if e.kind == ekEditor: onEditor = true
  EditingScope(model: router.base, product: f.product,
               pane: (if onEditor: epEditor else: epOtherPane),
               mode: f.editor.mode, navMode: navMode,
               textEntry: ctx.values[ckTextInputFocus] == "true",
               context: ctx)

func tablesInOrder(router: KeymapRouter;
                   path: ScopePath): seq[tuple[table: string, atFocus: bool]] =
  ## §5.1's order within one pass: pushed layers whose owner is on the path,
  ## newest first, then each element of the path, innermost first.
  result = @[]
  for l in activeLayers(router.stack, path):
    result.add (l.table, true)
  for i in countdown(path.len - 1, 0):
    for t in tablesOf(path[i]):
      result.add (t, i == path.len - 1)
  if path.len == 0 or path[0].kind != ekWindow:
    result.add (GlobalTable, false)

proc layersFor(router: KeymapRouter; facts: SessionFacts; path: ScopePath;
               navMode: NavigationMode;
               scope: EditingScope): seq[ResolutionLayer] =
  ## The layers for `path` as seen from `scope` — `scopeFor` with whether a
  ## prefix is pending — so `route` (the router's own prefix) and
  ## `ChordLookup` (a prefix it is typing on a probe) assemble them one way.
  result = @[]
  for source in [lsUser, lsBase]:
    for (table, atFocus) in router.tablesInOrder(path):
      # §5.5: under a modal base a read-only editor has no editing layer —
      # CodeTracer-TUI.md §4.2's navigation table is the read-only source's
      # (its `j` scrolls, its `n` steps).
      if source == lsBase and table == EditorTable and router.base.isModal and
         facts.editor.readOnly:
        continue
      let km =
        if source == lsUser: router.userByTable.getOrDefault(table)
        elif table == EditorTable and router.hasImported: router.importedEditor
        else: router.baseByTable.getOrDefault(table)
      if km.bindings.len == 0: continue
      let trie = trieFor(km, scope, table, laterFirst = source == lsUser)
      if trie.nodes.len > 1:
        result.add ResolutionLayer(name: $source & ":" & table,
                                   source: source, trie: trie,
                                   atFocus: atFocus)

proc layersFor*(router: KeymapRouter; facts: SessionFacts; path: ScopePath;
                navMode: NavigationMode): seq[ResolutionLayer] =
  ## The layers `route` resolves through, in order — exposed so the shortcut
  ## reference and the differential read the SAME list.
  router.layersFor(facts, path, navMode,
                   router.scopeFor(facts, path, navMode,
                                   router.pending.chords.len > 0))

proc chordFor*(router: KeymapRouter; operation: string; facts: SessionFacts;
               path: ScopePath; navMode: NavigationMode;
               argument = ""): string

proc resolveKey(router: var KeymapRouter; facts: SessionFacts; path: ScopePath;
                navMode: NavigationMode; key: string;
                nowMs: int64): EditingResolution =
  ## The resolution itself — the layers, the pending prefix — with no §8.1
  ## annotation.
  let scope = router.scopeFor(facts, path, navMode,
                              router.pending.chords.len > 0)
  result = resolveLayers(router.layersFor(facts, path, navMode, scope),
                         router.pending, pendingTimeoutOf(router.base),
                         scope.textEntry, key, nowMs)
  router.pending = result.pending

proc route*(router: var KeymapRouter; facts: SessionFacts; path: ScopePath;
            navMode: NavigationMode; key: string;
            nowMs: int64): EditingResolution =
  ## **ONE KEY, FROM A FRONT-END, TO A RESOLUTION.** The router keeps the new
  ## pending prefix; the front-end dispatches the answer.
  result = router.resolveKey(facts, path, navMode, key, nowMs)
  # Mode-Transitions §8.1: a key whose operation has no meaning in this
  # product mode is INERT AND SAYS SO. Asked of the same layers in the other
  # mode, with no prefix and no effect on this router's — and only for an
  # operation NO key reaches here (a key merely unbound in this mode, its
  # operation reachable by another, is just unbound).
  if result.kind == erNothing and result.reason == nrUnbound and
     result.pending.chords.len == 0:
    var other = facts
    other.product = (if facts.product == pmDebug: pmEdit else: pmDebug)
    var probe = router
    probe.pending = PendingChords()
    let elsewhere = probe.resolveKey(other, path, navMode, key, nowMs)
    if elsewhere.kind == erOperation and
       router.chordFor(elsewhere.operation, facts, path, navMode,
                       elsewhere.argument).len == 0:
      result.reason = nrDisabled
      result.operation = elsewhere.operation
      result.argument = elsewhere.argument

proc cancelPending*(router: var KeymapRouter) =
  router.pending = PendingChords()

# ---------------------------------------------------------------------------
# The layer stack, through the router
# ---------------------------------------------------------------------------

proc pushLayer*(router: var KeymapRouter; table, owner, label: string): LayerToken =
  let (next, token) = router.stack.push(table, owner, label)
  router.stack = next
  token

proc popLayer*(router: var KeymapRouter; token: LayerToken): PopResult =
  ## Pop `token` — only when it is on top; otherwise nothing changes and the
  ## answer says why (§5.4).
  result = router.stack.pop(token)
  router.stack = result.stack

proc unmountOwner*(router: var KeymapRouter; owner: string): seq[PushedLayer] =
  ## The owner is gone: its layers are popped, newest first, and returned
  ## so the front-end tells each mode (`onLayerPopped`).
  let (next, popped) = router.stack.unmount(owner)
  router.stack = next
  popped

# ---------------------------------------------------------------------------
# What the user is shown
# ---------------------------------------------------------------------------

func pendingLabel*(router: KeymapRouter): string =
  ## `Ctrl+K…` while a prefix waits; "" otherwise.
  if router.pending.chords.len == 0: ""
  else: router.pending.chords.join(" ") & "…"

func statusLabel*(router: KeymapRouter; path: ScopePath;
                  navMode: NavigationMode): string =
  ## THE STATUS LINE'S MODE INDICATOR (§5.4). A pending prefix first, then
  ## the newest active pushed layer (`FIND`, `PALETTE`, `COMMAND`), then —
  ## only under a base that HAS modes — the navigation mode (`NORMAL`,
  ## `INSERT` is the editor's); under CUA and Emacs, which have none, the
  ## base's own name (`CUA`, `EMACS`).
  let pending = router.pendingLabel
  if pending.len > 0: return pending
  let top = router.stack.topLabel(path)
  if top.len > 0: return top
  if router.base.isModal: ($navMode).toUpperAscii
  else: ($router.base).toUpperAscii

type
  ChordLayers = object
    built: bool
    layers: seq[ResolutionLayer]
    textEntry: bool

  ChordLookup* = object
    ## **THE LAYERS `chordFor` RESOLVES THROUGH, BUILT ONCE** for one
    ## (facts, scope path, navigation mode). Asking which chord runs an
    ## operation types each candidate row's sequence on an empty prefix and
    ## checks where it lands; that needs only two layer lists — the one seen
    ## with no prefix pending and the one seen with a prefix pending
    ## (`factsFor` reads only WHETHER one is pending, as `chordPending`) —
    ## whatever the operation, the row or the prefix. A menu asks for every
    ## item's chord on every redraw (the desktop's program menu, the TUI and
    ## GPUI menus), so building those tries once per lookup instead of once
    ## per chord of every candidate row, and never copying the router, is
    ## what keeps a redraw from blocking the window for seconds (#784).
    ##
    ## A lookup answers for the router it was made from, as that router was:
    ## a new user keymap, a pushed or popped layer, another base or other
    ## facts need a new lookup.
    facts: SessionFacts
    path: ScopePath
    navMode: NavigationMode
    timeoutMs: int64
    states: array[2, ChordLayers]
      ## Indexed by `ord` of whether a prefix is pending (an `array[bool, …]`
      ## indexed by a `bool` reads `undefined` on the JS backend); the
      ## prefixed list is built the first time a multi-chord row needs it.

proc initChordLookup*(router: KeymapRouter; facts: SessionFacts;
                      path: ScopePath; navMode: NavigationMode): ChordLookup =
  ChordLookup(facts: facts, path: path, navMode: navMode,
              timeoutMs: pendingTimeoutOf(router.base))

proc ensureLayers(lookup: var ChordLookup; router: KeymapRouter;
                  prefixed: bool) =
  if not lookup.states[ord(prefixed)].built:
    let scope = router.scopeFor(lookup.facts, lookup.path, lookup.navMode,
                                prefixed)
    lookup.states[ord(prefixed)] = ChordLayers(
      built: true, textEntry: scope.textEntry,
      layers: router.layersFor(lookup.facts, lookup.path, lookup.navMode,
                               scope))

proc typesTo(lookup: var ChordLookup; router: KeymapRouter;
             b: EditingBinding): bool =
  ## Whether `b`'s sequence, typed here on an empty prefix, resolves to `b`'s
  ## own operation and argument — `route`'s resolution, one chord at a time,
  ## each through the layers its prefix state sees.
  var pending = PendingChords()
  var res: EditingResolution
  for c in b.chords:
    let prefixed = pending.chords.len > 0
    lookup.ensureLayers(router, prefixed)
    res = resolveLayers(lookup.states[ord(prefixed)].layers, pending,
                        lookup.timeoutMs,
                        lookup.states[ord(prefixed)].textEntry, c, 0)
    pending = res.pending
  res.kind == erOperation and res.operation == b.operation and
    res.argument == b.argument

proc chordFor*(lookup: var ChordLookup; router: KeymapRouter;
               operation: string; argument = ""): string =
  ## **THE CHORD TO DISPLAY FOR `operation` WHERE `path` IS** (KL-8, IR-3):
  ## the first row naming it — user rows first, later rows first — whose
  ## sequence, typed here, RESOLVES to it. A shadowed row is never shown,
  ## because typing it would run something else. "" when nothing typed here
  ## reaches the operation.
  for i in countdown(router.user.bindings.len - 1, 0):
    # A template, not a `let`: on the JS backend a `let` deep-copies the row.
    template b: untyped = router.user.bindings[i]
    if b.operation == operation and b.argument == argument and
       lookup.typesTo(router, b):
      # The display form of a user's row — who may have written
      # `ctrl+alt+n`.
      return displaySequence(b.chords)
  for i in 0 ..< router.effective.bindings.len:
    template b: untyped = router.effective.bindings[i]
    if b.operation == operation and b.argument == argument and
       lookup.typesTo(router, b):
      # The data's own spelling for a base row (CUA's `Ctrl+K Ctrl+W`,
      # §4.2's `r f`).
      return b.spelling
  ""

proc chordFor*(router: KeymapRouter; operation: string; facts: SessionFacts;
               path: ScopePath; navMode: NavigationMode;
               argument = ""): string =
  ## `chordFor` for one operation, through a lookup of its own. A caller that
  ## asks for many operations at once (a menu) keeps one `ChordLookup`.
  var lookup = initChordLookup(router, facts, path, navMode)
  lookup.chordFor(router, operation, argument)

proc inertNote*(router: KeymapRouter; res: EditingResolution;
                facts: SessionFacts; path: ScopePath;
                navMode: NavigationMode): string =
  ## §8.1's *"the reason, on the surface the user is looking at"* for a key
  ## that is inert in this product mode (`nrDisabled`): the operation, the
  ## mode it needs, and the chord that switches (this base's). "" for any
  ## other resolution.
  if res.kind != erNothing or res.reason != nrDisabled:
    return ""
  let needs = if facts.product == pmDebug: "an editing session"
              else: "a replay session"
  result = "`" & res.operation & "` (" & operationLabelOf(res.operation) &
           ") needs " & needs & "; you are in " & $facts.product & " mode."
  let switch = router.chordFor("session.toggle-product-mode", facts, path,
                               navMode)
  if switch.len > 0:
    result.add " " & switch & " switches."

proc shortcutReference*(router: KeymapRouter; facts: SessionFacts;
                        path: ScopePath;
                        navMode: NavigationMode): seq[ReferenceEntry] =
  ## Every binding live for `path`, layer by layer in resolution order (so
  ## the active pushed layers lead), each base row marked with the user row
  ## that shadows it.
  result = @[]
  for layer in router.layersFor(facts, path, navMode):
    for b in layer.trie.bindings:
      var by = ""
      if layer.source == lsBase:
        for s in router.shadows:
          if s.shadowedSource == lsBase and s.shadowedOperation == b.operation and
             s.shadowedTable == tableOf(b) and
             normalizeChordSequence(s.keyText).splitWhitespace() == b.chords:
            by = "your row " & $(s.userIndex + 1)
      result.add ReferenceEntry(layer: layer.name, keyText: b.spelling,
                                operation: b.operation, shadowedBy: by)

func describeResolution*(res: EditingResolution): string =
  ## A resolution as one comparable phrase — what `:keys check`, GPUI's
  ## `probe:` and the cross-front-end differential (DIFF-13) read off each
  ## front-end: `operation <name>[(<arg>)]`, `character <c>`, `pending`, or
  ## `nothing <reason>`.
  case res.kind
  of erOperation:
    "operation " & res.operation &
      (if res.argument.len > 0: "(" & res.argument & ")" else: "")
  of erCharacter: "character " & res.character
  of erPending: "pending"
  of erNothing: "nothing " & $res.reason

func describe*(s: Shadow): string =
  ## *"`Enter` in the list: base `list.activate`, shadowed by your row 12"*.
  "`" & s.keyText & "` in " & s.shadowedTable & ": " &
    $s.shadowedSource & " `" & s.shadowedOperation & "`" &
    (if s.shadowedIndex >= 0: " (row " & $(s.shadowedIndex + 1) & ")" else: "") &
    ", shadowed by your row " & $(s.userIndex + 1)

func loadSummary*(router: KeymapRouter): string =
  ## PLAT-36's shape: a count, then the first problem and why.
  let loaded = router.user.bindings.len
  result = "keybindings.json: " & $loaded & " row(s) bound, " &
           $router.removed & " base row(s) removed, " &
           $router.shadows.len & " shadow(s)"
  if router.errors.len > 0:
    result.add "; " & $router.errors.len & " not loaded, first: " &
               describe(router.errors[0])
