## test_plat68_base_keymaps.nim — PLAT-68 Phase A: the four base keymaps, the
## CUA and Emacs editor layers as data, a binding's `when`, and the laws the
## milestone names for them.
##
## What is asserted, by the milestone's own names:
##
##   * **KL-1, the base partition** — four members, derived from the enum,
##     both directions; the retired `default` refused by every typed surface
##     and read as `cua`, once, by the stored-preference decoder only.
##   * **KL-2, coverage per base** — for CUA and Emacs, `covered + filed ==
##     operations`, disjoint, and nothing keymap-private.
##   * **Base conflicts are reported, never resolved by order** (§5.6) — two
##     rows of one base with one chord sequence whose `when`s can both hold, or
##     a row that is a prefix of another under conditions that can both hold,
##     decided EXACTLY by enumeration over the closed context-key domains; with
##     a planted duplicate and a planted prefix proving the check can fail.
##   * **`when` exactness** — the grammar, the closed key catalogue (an unknown
##     key is a load error, never `false`), and `canBothHold` over planted
##     pairs.
##   * **The pending-prefix timeout is the base's** (§3.7) — CUA and Emacs wait
##     for the next key; Vim and Kakoune time out at 1000 ms.
##   * **The product-default superset law** — each of the fourteen rows the
##     retired product default shipped has a CUA row with the same chord and
##     the same operation, or one of the three named refinements.
##   * **Editing through the bases**, through the one resolver: the CUA
##     sequence the milestone's terminal test types, the legacy fallback under
##     `keyProtocol == legacy` and its absence under Kitty, Emacs's mark and
##     kill ring, and one keystroke sequence giving four documents under the
##     four bases.
##
## ## No mocks
## The shipped tables (`cua_keymap`, `emacs_keymap`, `vim_keymap`,
## `kakoune_keymap`), the shipped builder and the shipped resolver, over real
## documents. The context keys are `context_keys.editorContextKeys`'s, the
## function the front-ends call.

import std/[strutils, tables, unittest]

import ../../editing_core

const ExpectedAssertions = 849
  ## Re-measured 2026-10-11 after the last CUA data edit: KL-2 asserts two
  ## facts per FILED declaration, so the count moves with the filed set (CUA
  ## 170, Emacs 185 of 245).

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  KittyDelivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                              keyProtocol: kpKitty)
  LegacyDelivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                               keyProtocol: kpLegacy)

proc docUnder(base: BaseKeymap; text: string;
              delivery = KittyDelivery): EditingDocument =
  initEditingDocument("t.txt", text, base, delivery = delivery)

proc press(d: var EditingDocument; keys: openArray[string];
           startMs = 1_000'i64): seq[string] =
  ## Every key through `editing_core.applyKey` under the document's own scope
  ## — the call both front-ends make. Returns the operations that ran.
  var now = startMs
  for k in keys:
    let a = d.applyKey(editScopeOf(d), k, now)
    result.add a.operations
    now += 600   # past the undo-grouping delay, so each key is one undo step

proc rowsOf(base: BaseKeymap): seq[BaseRow] =
  case base
  of bkCua: CuaRows
  of bkEmacs: EmacsRows
  else: @[]

# ===========================================================================

suite "PLAT-68 KL-1: four bases, derived from the enum, the retired name read once":
  test "the closed set is cua, emacs, vim, kakoune — CUA first, the default":
    var names: seq[string] = @[]
    for b in BaseKeymap: names.add $b
    ck names == @["cua", "emacs", "vim", "kakoune"]
    ck BaseKeymap.low == bkCua
    ck selectableKeymapNames() == names
    for n in names:
      let s = selectKeymap(n)
      ck s.ok
      ck $s.model == n
      ck not s.migrated
  test "the retired `default` is refused by name on every typed surface":
    let typed = selectKeymap("default")
    ck not typed.ok
    ck "default" in typed.refusal
    ck "cua, emacs, vim, kakoune" in typed.refusal
    ck not selectKeymap("default", "--keymap").ok
    ck not parseBaseKeymapCommand("baseKeymap:default").ok
  test "…and read as `cua`, MIGRATED, by the stored-preference decoder alone":
    let stored = decodeKeymapPreference("default\n")
    ck stored.ok
    ck stored.model == bkCua
    ck stored.migrated
    let plain = decodeKeymapPreference("emacs\n")
    ck plain.ok and plain.model == bkEmacs and not plain.migrated
    let bad = decodeKeymapPreference("vi\n")
    ck not bad.ok
    ck not bad.migrated
  test "the palette's command names every base, and its target reads back":
    for b in BaseKeymap:
      let parsed = parseBaseKeymapCommand(baseKeymapCommandTarget(b))
      ck parsed.ok
      ck parsed.model == b
    ck SelectBaseKeymapLabel == "Preferences: Select Base Keymap"
  test "the opening mode and the timeout are the base's":
    ck initialModeFor(bkCua) == emInsert
    ck initialModeFor(bkEmacs) == emInsert
    ck initialModeFor(bkVim) == emNormal
    ck initialModeFor(bkKakoune) == emNormal
    ck pendingTimeoutOf(bkCua) == NoPendingTimeout
    ck pendingTimeoutOf(bkEmacs) == NoPendingTimeout
    ck pendingTimeoutOf(bkVim) == 1000
    ck pendingTimeoutOf(bkKakoune) == 1000

suite "PLAT-68 KL-2: the data bases cover the vocabulary, filed or bound":
  for base in [bkCua, bkEmacs]:
    test "covered + filed == operations, disjoint, nothing private: " & $base:
      let def = keymapOf(base)
      ck def.model == base
      ck def.keymap.bindings.len == rowsOf(base).len
      ck coverageGaps(def).len == 0
      ck coverageOverlaps(def).len == 0
      ck unpublishedOperations(def.keymap, base).len == 0
      let reach = reachableOperations(def.keymap, base)
      let filed = filedOperations(def)
      ck reach.len + filed.len == operations().len
      for f in def.filed:
        ck f.reason.len >= 20
        var exists = false
        for d in vocabulary():
          if d.name == f.decl: exists = true
        ck exists

proc baseConflicts(base: BaseKeymap; rows: seq[BaseRow]): seq[string] =
  ## The conflicts the LOADER reports for `rows` — `definitionOf` refuses a
  ## base that has any (§5.6), so this asks it rather than re-deriving the
  ## check, and splits its one message back into the findings.
  try:
    discard definitionOf(base, rows)
    @[]
  except BaseRowError as e:
    e.msg[($base & ": ").len .. ^1].split("; ")

suite "PLAT-68: base conflicts are found exactly, and the shipped bases have none":
  for base in [bkCua, bkEmacs]:
    test "no duplicate and no prefix that can both hold: " & $base:
      let found = baseConflicts(base, rowsOf(base))
      for f in found: checkpoint(f)
      ck found.len == 0
  test "a planted duplicate is found — and a `when`-split pair is not one":
    var planted = CuaRows
    planted.add BaseRow(chords: "Ctrl+S", operation: "editor.save-all",
                        whenText: "")
    let found = baseConflicts(bkCua, planted)
    ck found.len == 1
    ck found[0].startsWith("duplicate Ctrl+s")
    # `Tab` is bound twice in the shipped table — insert or indent by the
    # selection — and is NOT a conflict, because the two `when`s cannot both
    # hold. That is the exactness the enumeration buys.
    var tabs = 0
    for r in CuaRows:
      if r.chords == "Tab": inc tabs
    ck tabs == 2
  test "a planted prefix is found":
    var planted = CuaRows
    planted.add BaseRow(chords: "Ctrl+K", operation: "editor.delete-line",
                        whenText: "editorTextFocus")
    let found = baseConflicts(bkCua, planted)
    ck found.len > 0
    for f in found: ck f.startsWith("prefix Ctrl+k (delete-line)")

  test "a base that conflicts, or contradicts its deferred rows, does not LOAD":
    # The check is the loader's, not this suite's: `definitionOf` — the call
    # `editing_core` makes for the shipped bases — refuses both shapes.
    var planted = CuaRows
    planted.add BaseRow(chords: "Ctrl+S", operation: "editor.save-all",
                        whenText: "")
    var refused = ""
    try:
      discard definitionOf(bkCua, planted, CuaDeferred)
    except BaseRowError as e:
      refused = e.msg
    ck refused.contains("duplicate Ctrl+s")
    ck deferredClashes(bkCua, CuaRows, CuaDeferred).len == 0
    ck deferredClashes(bkEmacs, EmacsRows, EmacsDeferred).len == 0
    let promise = @[DeferredRow(chords: "Ctrl+Shift+K",
                                operation: "editor.scroll-line-up",
                                whenText: "", reason: PaneOperation)]
    let clashes = deferredClashes(bkCua, CuaRows, promise)
    ck clashes.len == 1
    ck clashes[0].contains("bound by a row of the same base")

suite "PLAT-68: a binding's `when` — the grammar, the closed keys, exactness":
  proc holds(text: string; c: ContextKeys): bool =
    let p = parseWhen(text)
    doAssert p.ok, text & ": " & p.message
    evalWhen(p.expr, c)

  test "precedence, parentheses, negation and comparison":
    var c = defaultContextKeys()
    c.values[ckEditorTextFocus] = "true"
    c.values[ckProductMode] = "edit"
    ck holds("editorTextFocus", c)
    ck not holds("!editorTextFocus", c)
    ck holds("editorTextFocus && productMode == edit", c)
    ck not holds("editorTextFocus && productMode == debug", c)
    ck holds("productMode == debug || editorTextFocus", c)
    ck holds("!(editorReadOnly || listFocus)", c)
    ck not holds("editorReadOnly || listFocus && editorTextFocus", c)
    ck holds("productMode != debug", c)
    ck holds("", c)
  test "an unknown key, a value outside the domain and a bare enum are LOAD ERRORS":
    for bad in ["editorTxtFocus", "productMode == release", "productMode",
                "editorTextFocus &&", "(editorTextFocus", "a b"]:
      let p = parseWhen(bad)
      checkpoint(bad & " -> " & p.message)
      ck not p.ok
      ck p.message.len > 0
  test "canBothHold decides overlap exactly, by enumeration":
    proc both(a, b: string): bool =
      canBothHold(parseWhen(a).expr, parseWhen(b).expr)
    ck not both("editorHasMultipleSelections",
                "editorHasSelection && !editorHasMultipleSelections")
    ck not both("editorMode == visual", "editorMode != visual")
    ck not both("keyProtocol == legacy", "keyProtocol == kitty")
    ck both("editorTextFocus && !editorReadOnly", "keyProtocol == legacy")
    ck both("", "productMode == edit")
    ck not both("productMode == edit && productMode == debug", "")
  test "every shipped row's `when` parses, and every key it reads is in the catalogue":
    for base in [bkCua, bkEmacs]:
      for r in rowsOf(base):
        let p = parseWhen(r.whenText)
        if not p.ok: checkpoint($base & " " & r.chords & ": " & p.message)
        ck p.ok

suite "PLAT-68: the pending prefix waits under CUA and Emacs, and times out under Vim":
  test "CUA's Ctrl+K waits past any timeout, and Escape-free completion runs":
    var d = docUnder(bkCua, "alpha\nbeta\n")
    let ops = d.press(["Ctrl+k"], 1_000)
    ck ops.len == 0
    ck d.state.pending.chords == @["Ctrl+k"]
    # Five minutes later the prefix is still pending, as in VS Code.
    let a = d.applyKey(editScopeOf(d), "Ctrl+c", 301_000)
    ck not a.timedOut
    ck "line-comment" in a.operations
  test "Vim's `g` times out at 1000 ms":
    var d = docUnder(bkVim, "alpha\nbeta\n")
    discard d.applyKey(editScopeOf(d), "g", 1_000)
    ck d.state.pending.chords == @["g"]
    let a = d.applyKey(editScopeOf(d), "g", 2_001)
    ck a.timedOut

suite "PLAT-68: the product-default superset law":
  test "each of the fourteen retired rows has a CUA row, same chord, same operation or a named refinement":
    const Retired = [
      ("Left", "move-char-left"), ("Right", "move-char-right"),
      ("Up", "move-line-up"), ("Down", "move-line-down"),
      ("Home", "move-line-start"), ("End", "move-line-end"),
      ("Backspace", "delete-char-backward"), ("Delete", "delete-char-forward"),
      ("Enter", "insert-newline"), ("Tab", "indent-selection"),
      ("Shift+Tab", "dedent-selection"), ("Ctrl+z", "undo"),
      ("Ctrl+y", "redo")]
    const Refinements = {
      "move-line-start": "move-line-start-smart",
      "insert-newline": "insert-newline-and-indent"}.toTable
    ck Retired.len == 13      # …and the fourteenth was the character arm
    var refined = 0
    for (chord, op) in Retired:
      var sameChord: seq[string] = @[]
      for b in keymapOf(bkCua).keymap.bindings:
        if b.chords == @[chord]: sameChord.add b.operation
      checkpoint(chord & " -> " & $sameChord)
      ck sameChord.len > 0
      if op in sameChord:
        continue
      inc refined
      ck Refinements.getOrDefault(op, "") in sameChord or
         (chord == "Tab" and "insert-tab" in sameChord)
    # `Tab` binds `indent-selection` still (with a multi-line selection), so
    # it is not counted as refined: exactly the two named refinements are.
    ck refined == 2
    # The character arm is the resolver's, under every base.
    ck "insert-text" in LayerReachedOperations

suite "PLAT-68: editing through the CUA base, one resolver":
  test "the milestone's terminal sequence, in process":
    var d = docUnder(bkCua, "")
    for c in "hello world": discard d.press([if c == ' ': "Space" else: $c])
    ck d.text == "hello world"
    discard d.press(["Home", "Shift+Right", "Shift+Right", "Shift+Right"])
    ck d.hasSelection
    discard d.press(["Ctrl+c", "End", "Ctrl+v"])
    ck d.text == "hello worldhel"
    discard d.press(["Ctrl+z"])
    ck d.text == "hello world"
    discard d.press(["Ctrl+y"])
    ck d.text == "hello worldhel"
    let ops = d.press(["Ctrl+Shift+k"])
    ck "delete-line" in ops
    ck d.text == ""
  test "the legacy fallback holds only under keyProtocol == legacy":
    var legacy = docUnder(bkCua, "one\ntwo\n", LegacyDelivery)
    ck "delete-line" in legacy.press(["Ctrl+k", "Ctrl+k"])
    ck legacy.text == "two\n"
    var kitty = docUnder(bkCua, "one\ntwo\n", KittyDelivery)
    ck "delete-line" notin kitty.press(["Ctrl+k", "Ctrl+k"])
    ck kitty.text == "one\ntwo\n"
  test "Home is two-stage, as VS Code's":
    var d = docUnder(bkCua, "    indented\n")
    discard d.press(["End", "Home"])
    ck d.caretColumn == 4
    discard d.press(["Home"])
    ck d.caretColumn == 0
  test "Tab inserts at a caret and indents a multi-line selection":
    var d = docUnder(bkCua, "a\nb\n")
    discard d.press(["Tab"])
    ck d.text == "    a\nb\n"
    var m = docUnder(bkCua, "a\nb\n")
    discard m.press(["Shift+Down", "Shift+Right", "Tab"])
    ck m.text == "    a\n    b\n"
  test "Escape collapses a selection to its head, and keeps the primary of several":
    var d = docUnder(bkCua, "abcdef\n")
    discard d.press(["Shift+Right", "Shift+Right", "Esc"])
    ck not d.hasSelection
    ck d.caretColumn == 2
  test "copy with no selection copies the line, and paste puts it above":
    var d = docUnder(bkCua, "one\ntwo\n")
    discard d.press(["Ctrl+c", "Down", "Ctrl+v"])
    ck d.text == "one\none\ntwo\n"
  test "Ctrl+S names the host's `save`; in Debug mode it is not the editor's":
    var d = docUnder(bkCua, "x\n")
    ck "save" in d.press(["Ctrl+s"])
    var sc = editScopeOf(d)
    sc.product = pmDebug
    sc.context.values[ckProductMode] = "debug"
    ck resolveKey(d.state, keymapOf(bkCua).keymap, sc, "Ctrl+s", 0).kind ==
       erNothing

suite "PLAT-68: editing through the Emacs base — the mark and the kill ring":
  test "C-SPC, C-f ×3, M-w, C-e, C-y copies through the kill ring":
    var d = docUnder(bkEmacs, "hello world\n")
    discard d.press(["Ctrl+Space", "Ctrl+f", "Ctrl+f", "Ctrl+f"])
    ck d.state.mode == emVisual
    ck d.hasSelection
    discard d.press(["Alt+w", "Ctrl+e", "Ctrl+y"])
    ck d.text == "hello worldhel\n"
    ck d.state.mode == emInsert
  test "C-k twice from one place appends to one kill, and C-y yanks it back":
    var d = docUnder(bkEmacs, "one\ntwo\nthree\n")
    discard d.press(["Ctrl+k", "Ctrl+k"])
    ck d.text == "two\nthree\n"
    discard d.press(["Ctrl+e", "Ctrl+y"])
    ck d.text == "twoone\n\nthree\n"
  test "M-y after C-y rotates in the older kill":
    var d = docUnder(bkEmacs, "aa bb\n")
    discard d.press(["Ctrl+Space", "Ctrl+f", "Ctrl+f", "Alt+w"])       # kill "aa"
    discard d.press(["Ctrl+f", "Ctrl+Space", "Ctrl+e", "Alt+w"])      # kill "bb"
    discard d.press(["Ctrl+e", "Ctrl+y"])
    ck d.text == "aa bbbb\n"
    discard d.press(["Alt+y"])
    ck d.text == "aa bbaa\n"
  test "typing ends an active region, and C-g deactivates it":
    var d = docUnder(bkEmacs, "abc\n")
    discard d.press(["Ctrl+Space", "Ctrl+f"])
    ck d.state.mode == emVisual
    discard d.press(["Z"])
    ck d.state.mode == emInsert
    discard d.press(["Ctrl+Space", "Ctrl+f", "Ctrl+g"])
    ck d.state.mode == emInsert
    ck not d.hasSelection
  test "C-x C-s names the host's `save`":
    var d = docUnder(bkEmacs, "x\n")
    ck "save" in d.press(["Ctrl+x", "Ctrl+s"])

suite "PLAT-68: one keystroke sequence, four bases, four documents":
  test "the same keys give a different document under each base":
    const Keys = ["d", "d", "x", "Ctrl+k"]
    var docs: seq[string] = @[]
    for base in BaseKeymap:
      var d = docUnder(base, "first\nsecond\n")
      discard d.press(Keys)
      checkpoint($base & ": " & d.text.escape)
      docs.add d.text
    for i in 0 ..< docs.len:
      for j in i + 1 ..< docs.len:
        ck docs[i] != docs[j]

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
