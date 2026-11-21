## test_layout_contributed_identity.nim — the layout algebra speaks both pane
## identities (Extensibility-Model.md §10 decision 2: a closed enum for core
## panes, a namespaced string for contributed ones).
##
## Every command that names a pane — activate, weight, divider, move, split,
## split-move, root split, merge, dock, restore, open/close docked, rename, and
## the add anchors — is driven here with a CONTRIBUTED pane, and each case
## asserts the resulting layout (and that the built-in pane sharing the
## contributed leaf's zero value, `paneEditor`, was left alone). The persisted
## half: a contributed pane docked, saved and restored keeps its slot, its
## strip title and its neighbour; a docked entry with a malformed id or both
## identities is refused by kind; a v10 document still opens; an unknown
## contributed id decodes to a slot `classify` reports as
## `prUnloadedExtension`, never to nothing.
##
## No mocks and no stand-ins: the suite is pure model code over real values.

import std/[json, options, sets, unittest]

import headless_app/layout_model
import headless_app/layout_interaction

const
  Metrics = "acme-tools.metrics/overview"
  Flame = "acme-tools.flame/flame"

template ck(cond: untyped) = check cond

template applied(outcome: LayoutOutcome): Layout =
  let o = outcome
  checkpoint("outcome was: " & $o)
  check o.kind == loApplied
  o.layout

proc base(): Layout =
  ## Editor beside a two-tab stack (State | Metrics), and Flame alone below.
  initLayout(column([
    row([pane(paneEditor, "Editor", weight = 2.0),
         stack([pane(paneState, "Variables"),
                contributedPaneNode(Metrics, "Metrics")], activeIndex = 0,
               weight = 1.0)], weight = 3.0),
    contributedPaneNode(Flame, "Flame", weight = 1.0)]))

proc m(): PaneRef = contributedRef(Metrics)
proc f(): PaneRef = contributedRef(Flame)

suite "the layout commands name a contributed pane":

  test "activate selects the contributed tab, and never the editor's slot":
    let l = applied(base().apply(cmdActivateTab(m())))
    ck l.tree.isVisible(m())
    ck not l.tree.isVisible(builtinRef(paneState))
    ck l.tree.isVisible(paneEditor)
    # The zero-value trap: activating the EDITOR must not pick the contributed
    # leaf whose `pane` field holds `paneEditor`.
    let back = applied(l.apply(cmdActivateTab(builtinRef(paneState))))
    ck back.tree.activate(paneEditor)
    ck back.tree.isVisible(builtinRef(paneState))
    ck not back.tree.isVisible(m())
    let noop = base().apply(cmdActivateTab(f()))
    ck noop.kind == loNoOp

  test "activating the editor never selects a contributed tab ahead of it":
    # THE ZERO-VALUE TRAP, positioned to bite: the contributed leaf (whose
    # `pane` field holds `paneEditor`) comes before the editor in the walk.
    let l = initLayout(row([
      stack([contributedPaneNode(Metrics), pane(paneState)], activeIndex = 1),
      pane(paneEditor)]))
    ck l.tree.activate(paneEditor)
    ck l.tree.children[0].activeIndex == 1
    ck l.tree.isVisible(builtinRef(paneState))
    ck l.apply(cmdActivateTab(paneEditor)).kind == loNoOp

  test "set weight and a divider drag resize the contributed leaf":
    let l = applied(base().apply(cmdSetWeight(f(), 2.5)))
    ck l.tree.findContributed(Flame).weight == 2.5
    ck l.tree.find(paneEditor).weight == 2.0
    let d = applied(base().apply(cmdSetDivider(f(), 0.5, ssBefore)))
    ck d.tree.findContributed(Flame).weight == 0.5
    ck d.tree.children[0].weight == 3.5

  test "move a contributed tab within its stack and into another":
    let within = applied(base().apply(
      cmdMoveTab(m(), builtinRef(paneState), 0)))
    ck $within.tree.children[0].children[1] ==
      "stack(*contributed:" & Metrics & ", pane:state)"
    # Flame is a bare leaf; merge it into the stack first, then move Metrics
    # out of it by moving it beside Flame's new home.
    let merged = applied(base().apply(cmdMergeIntoStack(f(), m())))
    ck merged.tree.containsContributed(Flame)
    let stackNode = merged.tree.findContributed(Flame)
    ck not parentOf(merged.tree, stackNode).isNil
    ck parentOf(merged.tree, stackNode).kind == lnStack
    ck merged.validate({paneEditor, paneState}).len == 0

  test "split beside a contributed pane, and split a new contributed pane in":
    let byTarget = applied(base().apply(
      cmdSplitMove(f(), builtinRef(paneState), saRow, ssAfter)))
    let flameLeaf = byTarget.tree.findContributed(Flame)
    let parent = parentOf(byTarget.tree, flameLeaf)
    ck parent.kind == lnRow
    ck parent.children.len == 2
    ck parent.children[1].matches(builtinRef(paneState))
    let fresh = applied(base().apply(cmdSplit(builtinRef(paneEditor),
      contributedRef("acme-tools.extra/notes"), saColumn, ssBefore, "Notes")))
    ck fresh.tree.containsContributed("acme-tools.extra/notes")
    ck fresh.tree.findContributed("acme-tools.extra/notes").title == "Notes"
    let bad = base().apply(cmdSplit(builtinRef(paneEditor),
      contributedRef("not-namespaced"), saRow))
    ck bad.kind == loRefused
    ck bad.problem.kind == lpMalformedContributedPane
    ck bad.problem.contributed == "not-namespaced"
    ck bad.problem.pane.isNone
    let root = applied(base().apply(cmdSplitRootMove(m(), saRow, ssBefore)))
    ck root.tree.kind == lnRow
    ck root.tree.children[0].matches(m())

  test "merge a built-in pane into a contributed one's region":
    let l = applied(base().apply(cmdMergeIntoStack(builtinRef(paneEditor), f())))
    let s = parentOf(l.tree, l.tree.findContributed(Flame))
    ck s.kind == lnStack
    ck s.children.len == 2
    ck s.children[1].matches(builtinRef(paneEditor))

  test "dock, open, close and restore a contributed pane, beside its neighbour":
    let docked = applied(base().apply(cmdDock(m(), leRight, title = "METRICS")))
    ck not docked.tree.containsContributed(Metrics)
    ck docked.dockedIndex(m()) == 0
    ck docked.dockedIndex(paneEditor) == -1
    ck docked.placement(m()) == plDocked
    ck docked.docked[0].isContributed
    ck docked.docked[0].title == "METRICS"
    ck docked.docked[0].beside == some(paneState)
    ck docked.allPanes == @[paneEditor, paneState]
    ck docked.allContributedPanes == @[Flame, Metrics]
    ck docked.validate({paneEditor, paneState}).len == 0
    let opened = applied(docked.apply(cmdOpenDocked(m())))
    ck opened.docked[0].open
    let closed = applied(opened.apply(cmdCloseDocked(m())))
    ck not closed.docked[0].open
    let restored = applied(docked.apply(cmdRestoreDocked(m())))
    ck restored.docked.len == 0
    let leaf = restored.tree.findContributed(Metrics)
    ck leaf.title == "METRICS"
    ck parentOf(restored.tree, leaf).children[0].matches(builtinRef(paneState))
    # A contributed NEIGHBOUR is remembered too.
    let flameDocked = applied(applied(base().apply(
      cmdMergeIntoStack(f(), m()))).apply(cmdDock(f(), leBottom)))
    ck flameDocked.docked[0].besideContributed == Metrics
    ck flameDocked.docked[0].beside.isNone
    let back = applied(flameDocked.apply(cmdRestoreDocked(f())))
    let p = parentOf(back.tree, back.tree.findContributed(Flame))
    ck p.kind == lnStack
    ck p.children[p.children.len - 1].matches(f())
    # Placing a docked contributed pane again is the both-places refusal.
    let twice = docked.apply(cmdAddContributedPane(Metrics))
    ck twice.kind == loRefused
    ck twice.problem.kind == lpPaneBothPlacedAndDocked
    ck twice.problem.contributed == Metrics

  test "rename a contributed pane placed and docked":
    let l = applied(base().apply(cmdRename(f(), "Flame graph")))
    ck l.tree.findContributed(Flame).title == "Flame graph"
    ck l.tree.find(paneEditor).title == "Editor"
    let d = applied(applied(base().apply(cmdDock(f(), leLeft))).apply(
      cmdRename(f(), "FLAME")))
    ck d.docked[0].title == "FLAME"

  test "add anchors on a contributed pane":
    let l = applied(base().apply(cmdAddPane(paneCalltrace, "Calls",
                                            after = some(m()))))
    let s = parentOf(l.tree, l.tree.find(paneCalltrace))
    ck s.kind == lnStack
    ck s.children[2].matches(builtinRef(paneCalltrace))
    let c = applied(base().apply(cmdAddContributedPane("acme-tools.extra/notes",
                                                       after = some(f()))))
    let p = parentOf(c.tree, c.tree.findContributed("acme-tools.extra/notes"))
    ck p == c.tree
    ck p.children[2].matches(contributedRef("acme-tools.extra/notes"))
    let missing = base().apply(cmdAddPane(paneCalltrace,
      after = some(contributedRef("acme-tools.gone/x"))))
    ck missing.kind == loRefused
    ck missing.problem.contributed == "acme-tools.gone/x"

  test "a refusal about a contributed pane names it, never paneEditor":
    let r = base().apply(cmdActivateTab(contributedRef("acme-tools.gone/x")))
    ck r.kind == loRefused
    ck r.problem.kind == lpPaneNotPlaced
    ck r.problem.pane.isNone
    ck r.problem.contributed == "acme-tools.gone/x"

  test "PaneKind commands are the commands they always were":
    ck cmdActivateTab(paneState).subjectRef.sameSlot(builtinRef(paneState))
    ck cmdActivateTab(builtinRef(paneState)).activateTarget == paneState
    ck cmdActivateTab(builtinRef(paneState)).activateContributed == ""
    ck cmdMoveTab(m(), builtinRef(paneState), 0).anchorRef.get.sameSlot(
      builtinRef(paneState))
    let a = base().apply(cmdRemovePane(paneState))
    let b = base().apply(cmdRemovePane(paneState))
    ck $a == $b

  test "NodeInfo names a contributed leaf in its own namespace":
    let path = panePath(base(), m())
    ck path.isSome
    let info = nodeInfoAtPath(base().tree, path.get)
    ck info.isSome
    ck info.get.contributedPane == Metrics
    ck info.get.paneRef.sameSlot(m())
    ck not info.get.paneRef.sameSlot(builtinRef(paneEditor))

suite "a docked contributed pane persists, and an unknown one keeps its slot":

  test "dock, save, restore: the slot, title and neighbour come back":
    let docked = applied(base().apply(cmdDock(m(), leRight, title = "METRICS")))
    let doc = saveLayout(docked)
    ck doc["version"].getInt == LayoutSchemaVersion
    ck LayoutSchemaVersion == 11
    let entry = doc["docked"][0]
    ck entry["contributedPane"].getStr == Metrics
    ck not entry.hasKey("pane")
    ck entry["beside"].getStr == "state"
    let back = restoreLayoutDocument(parseJson($doc))
    ck back.docked.len == 1
    ck back.docked[0].contributedPane == Metrics
    ck back.docked[0].title == "METRICS"
    ck back.docked[0].beside == some(paneState)
    ck back.dockedIndex(paneEditor) == -1
    ck equalTrees(back.tree, docked.tree)
    let restored = applied(back.apply(cmdRestoreDocked(m())))
    ck restored.tree.containsContributed(Metrics)

  test "a contributed neighbour round-trips under its own key":
    let flameDocked = applied(applied(base().apply(
      cmdMergeIntoStack(f(), m()))).apply(cmdDock(f(), leBottom)))
    let doc = saveLayout(flameDocked)
    ck doc["docked"][0]["besideContributedPane"].getStr == Metrics
    ck not doc["docked"][0].hasKey("beside")
    let back = restoreLayoutDocument(parseJson($doc))
    ck back.docked[0].besideContributed == Metrics

  test "a docked entry with a malformed id, or both identities, is refused by kind":
    proc kindOf(entry: JsonNode): LayoutDecodeErrorKind =
      let doc = %*{"version": LayoutSchemaVersion,
                   "layout": {"kind": "pane", "pane": "editor"},
                   "docked": [entry]}
      try:
        discard restoreLayoutDocument(doc)
        checkpoint("decoded without a refusal")
        check false
      except LayoutDecodeError as e:
        return e.kind
    ck kindOf(%*{"contributedPane": "editor", "edge": "left", "order": 0}) ==
      ldeBadContributedPane
    ck kindOf(%*{"contributedPane": Metrics, "pane": "state", "edge": "left",
                 "order": 0}) == ldePaneAndContributedPane
    ck kindOf(%*{"edge": "left", "order": 0}) == ldeMissingField
    ck kindOf(%*{"pane": "state", "edge": "left", "order": 0,
                 "besideContributedPane": "bad id"}) == ldeBadContributedPane
    ck kindOf(%*{"pane": "state", "edge": "left", "order": 0, "beside": "editor",
                 "besideContributedPane": Metrics}) ==
      ldePaneAndContributedPane

  test "a v10 document opens and is re-stamped":
    var doc = saveLayout(base())
    doc["version"] = %10
    let back = restoreLayoutDocument(doc)
    ck back.version == 11
    ck equalTrees(back.tree, base().tree)

  test "an unknown contributed pane decodes to a typed slot, placed or docked":
    let docked = applied(base().apply(cmdDock(f(), leBottom)))
    let back = restoreLayoutDocument(parseJson($saveLayout(docked)))
    let loaded = toHashSet([Flame])  # metrics' extension is not loaded
    let leaf = back.tree.findContributed(Metrics)
    ck not leaf.isNil
    let placed = classify(paneRefOf(leaf), loaded)
    ck placed.kind == prUnloadedExtension
    ck placed.id == Metrics
    ck describe(placed) == "pane 'overview' from the extension " &
      "'acme-tools.metrics', which is not loaded in this session"
    ck classify(back.docked[0].paneRefOf, loaded).kind == prContributed
    ck classify(back.docked[0].paneRefOf, initHashSet[string]()).kind ==
      prUnloadedExtension
    # The slot is kept, so it still answers every command.
    let moved = applied(back.apply(cmdSplitMove(builtinRef(paneEditor), m(),
                                                saRow, ssBefore)))
    ck moved.tree.containsContributed(Metrics)
