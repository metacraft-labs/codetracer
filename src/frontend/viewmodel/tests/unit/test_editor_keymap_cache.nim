## The real keymap and resolver run here; no clocks, timings or fake adapters.
## JS identity checks catch trie rebuilds and value copies directly, regardless
## of host contention or the number of bindings in a shipped base.
import std/[tables, unittest]
import ../../keymap/vim_keymap

when defined(js):
  proc sameIdentity(a, b: EditingTrie): bool {.importjs: "(# === #)".}
  proc watchTrieCopies(t: EditingTrie) =
    # Instrument the runtime's actual object-copy traversal, not a production
    # counter that a different resolution route could accidentally bypass.
    {.emit: """
      var savedCopy = nimCopyAux;
      var watchedTrie = `t`;
      var trieCopies = 0;
      nimCopyAux = function(dest, src, info) {
        if (src === watchedTrie) ++trieCopies;
        return savedCopy(dest, src, info);
      };
      globalThis.__ctFinishTrieWatch = function() {
        nimCopyAux = savedCopy;
        return trieCopies;
      };
    """.}
  proc finishTrieWatch(): int {.importjs: "globalThis.__ctFinishTrieWatch()".}

suite "compiled editing keymap reuse":
  when defined(js):
    test "repeated scope lookup reuses the compiled trie":
      let km = vimKeymap().keymap
      let scope = EditingScope(model: bkVim, mode: emNormal)
      let first = trieFor(km, scope)
      let second = trieFor(km, scope)
      check first.nodes.len > 1
      check sameIdentity(first, second)

    test "a resolution layer retains the compiled trie by reference":
      let km = vimKeymap().keymap
      let scope = EditingScope(model: bkVim, mode: emNormal)
      let trie = trieFor(km, scope)
      let layer = ResolutionLayer(name: "base:editor", source: lsBase,
                                  trie: trie, atFocus: true)
      check layer.trie.nodes.len > 1
      check sameIdentity(trie, layer.trie)

when defined(js):
  suite "JavaScript key resolution copying":
    test "resolve does not traverse the compiled trie to copy it":
      let km = vimKeymap().keymap
      let scope = EditingScope(model: bkVim, mode: emNormal)
      let trie = trieFor(km, scope)
      let state = initEditorState("abc")
      watchTrieCopies(trie)
      var operation = ""
      for _ in 0 ..< 32:
        operation = resolve(trie, state, scope, "h", 0).operation
        discard resolveKey(state, km, scope, "h", 0)
      let copies = finishTrieWatch()
      check operation == "move-char-left"
      check copies == 0

proc row(key, operation: string; table = "editor"): EditingBinding =
  EditingBinding(model: bkVim, table: table, chords: @[key],
                 operation: operation, spelling: key)

proc resolved(km: EditingKeymap; scope: EditingScope; key = "x";
              table = "editor"; laterFirst = false): string =
  resolve(trieFor(km, scope, table, laterFirst), initEditorState("abc"),
          scope, key, 0).operation

suite "compiled editing keymap snapshot isolation":
  test "constructor, getter and compiled trie reads cannot mutate bindings":
    var input = @[row("x", "undo")]
    input[0].scope.cond = parseWhen("editorReadOnly").expr
    var scope = EditingScope(model: bkVim, mode: emNormal)
    scope.context.values[ckEditorReadOnly] = "true"
    let km = newEditingKeymap(input)
    let trie = trieFor(km, scope)
    input[0].chords[0] = "y"
    input[0].scope.cond.key = ckReplayLoaded
    var read = km.bindings
    read[0].chords[0] = "z"
    read[0].scope.cond.key = ckReplayLoaded
    var found = km.bindingsFor("undo")
    check found.len == 1 and km.bindingsFor("redo").len == 0
    found[0].chords[0] = "z"
    found[0].scope.cond.key = ckReplayLoaded
    var compiled = trie.bindings
    compiled[0].operation = "redo"
    compiled[0].scope.cond.key = ckReplayLoaded
    var nodes = trie.nodes
    nodes[0].children.clear()
    check km.resolved(scope) == "undo"
    # New context forces a new compilation from the snapshot, rather than
    # merely asking whether the already compiled trie remained intact.
    scope.context.values[ckReplayLoaded] = "false"
    check km.resolved(scope) == "undo"
    check km.resolved(scope, "y") == ""
    check km.resolved(scope, "z") == ""

  test "adding and replacing bindings detach copied keymaps and caches":
    let original = newEditingKeymap(@[row("x", "undo")])
    let scope = EditingScope(model: bkVim, mode: emNormal)
    let old = trieFor(original, scope)
    var edited = original
    edited.addBinding row("y", "redo")
    check original.resolved(scope, "y") == ""
    check edited.resolved(scope, "y") == "redo"
    edited.bindings = @[row("x", "redo")]
    check original.resolved(scope) == "undo"
    check edited.resolved(scope) == "redo"
    check resolve(old, initEditorState("abc"), scope, "x", 0).operation == "undo"

  test "scope, table and precedence changes never reuse incompatible rows":
    var rows = @[row("x", "undo"), row("x", "redo"),
                 row("x", "move-char-left", "global")]
    rows[0].scope.modes = {emNormal}
    rows[1].scope.modes = {emInsert}
    let km = newEditingKeymap(rows)
    var scope = EditingScope(model: bkVim, mode: emNormal)
    check km.resolved(scope) == "undo"
    scope.mode = emInsert
    check km.resolved(scope) == "redo"
    scope.mode = emNormal
    check km.resolved(scope) == "undo"
    check km.resolved(scope, table = "global") == "move-char-left"
    scope.model = bkKakoune
    check km.resolved(scope) == ""
    let duplicates = newEditingKeymap(@[row("x", "undo"), row("x", "redo")])
    scope.model = bkVim
    check duplicates.resolved(scope) == "undo"
    check duplicates.resolved(scope, laterFirst = true) == "redo"
    check duplicates.resolved(scope) == "undo"

  test "all admission dimensions and context participate in the cache key":
    var binding = row("x", "undo")
    binding.scope = BindingScope(modes: {emNormal}, navModes: {nmNormal},
      products: {pmEdit}, panes: {epEditor}, platforms: {pkMac},
      whenText: "editorReadOnly", cond: parseWhen("editorReadOnly").expr)
    let km = newEditingKeymap(@[binding])
    let scope = EditingScope(model: bkVim, mode: emNormal, navMode: nmNormal,
      product: pmEdit, pane: epEditor)
    var live = scope
    live.context.values[ckPlatform] = "mac"
    live.context.values[ckEditorReadOnly] = "true"
    check km.resolved(live) == "undo"
    var changed = live
    changed.mode = emInsert
    check km.resolved(changed) == ""
    changed = live
    changed.navMode = nmSearch
    check km.resolved(changed) == ""
    changed = live
    changed.product = pmDebug
    check km.resolved(changed) == ""
    changed = live
    changed.pane = epOtherPane
    check km.resolved(changed) == ""
    changed = live
    changed.context.values[ckPlatform] = "linux"
    check km.resolved(changed) == ""
    changed = live
    changed.context.values[ckEditorReadOnly] = "false"
    check km.resolved(changed) == ""
    changed = live
    changed.textEntry = true
    let unconditional = newEditingKeymap(@[row("x", "undo")])
    check resolve(trieFor(unconditional, changed), initEditorState("abc"), changed,
                  "x", 0).kind == erCharacter
    check km.resolved(live) == "undo"
