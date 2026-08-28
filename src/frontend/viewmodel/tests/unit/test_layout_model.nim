## SDK-CONSUMER: the session/layout model belongs to the shell, not to the
## SDK, so this suite reaches the replay core only through `codetracer_embed`
## — and in fact needs nothing from it at all, which is itself the point:
## `headless_app/layout_model.nim` describes what a session shows without
## knowing what a session is.
##
## test_layout_model.nim
##
## BlockTracer.milestones.org M2a, item 1 — "a session/layout model that is
## not GoldenLayout-typed".
##
## ## What this suite is for
##
## `ReplaySession.savedLayoutConfig` is a `GoldenLayoutResolvedConfig`
## (`src/frontend/types.nim`). Everything a shell wants to know about a
## session's arrangement — which panes exist, which are visible, what happens
## when one is closed, whether a restored layout is even well formed — is
## answerable today only by asking a live GoldenLayout object, which means
## only in a renderer. This suite answers all of it in a process with no
## renderer, in microseconds.
##
## Two properties are worth stating because they are what make the model
## worth having rather than merely different:
##
##   1. **`visiblePanes` is smaller than `allPanes`.** A tabbed region has
##      one visible member. A shell that loads data for hidden panes is
##      wasting a range request per pane, which on BlockTracer's delivery
##      path is a network round trip.
##
##   2. **A malformed layout is a value, not a crash.** `validate` returns an
##      enumerated defect list and `restoreLayout` raises a *typed* error, so
##      a shell that meets a layout from a newer build falls back for a
##      reason it can name.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_layout_model.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_layout_model.nim

import std/[json, options, unittest]

import headless_app/layout_model

# ---------------------------------------------------------------------------
# Construction and the default
# ---------------------------------------------------------------------------

suite "Layout model — the default replay layout":

  test "the default places exactly the five panes BlockTracer renders":
    let l = defaultReplayLayout()
    var seen: set[PaneKind] = {}
    for p in l.allPanes():
      seen.incl(p)
    check seen == BlockTracerPanes
    # Placed once each: five leaves, no duplicates.
    check l.allPanes().len == 5

  test "the default is structurally valid":
    check defaultReplayLayout().validate().len == 0

  test "the default hides a pane, so visible and placed differ":
    # A default in which everything is visible would let `visiblePanes` be
    # wrong in the same direction on every test and still look right.
    let l = defaultReplayLayout()
    check l.visiblePanes().len == 4
    check l.allPanes().len == 5
    check l.isVisible(paneState)
    check not l.isVisible(paneEventLog)
    check l.contains(paneEventLog)

  test "a pane is placed, visible, and both are distinguishable":
    let l = defaultReplayLayout()
    for p in BlockTracerPanes:
      check l.contains(p)
    check l.isVisible(paneEditor)
    check not l.contains(paneScratchpad)
    check not l.isVisible(paneScratchpad)

suite "Layout model — construction":

  test "a bare pane is its own tree":
    let l = pane(paneEditor, "Editor")
    check l.kind == lnPane
    check l.allPanes() == @[paneEditor]
    check l.visiblePanes() == @[paneEditor]
    check l.validate().len == 0

  test "rows and columns show every child":
    let l = row([pane(paneEditor), column([pane(paneState), pane(paneCalltrace)])])
    check l.allPanes() == @[paneEditor, paneState, paneCalltrace]
    check l.visiblePanes() == @[paneEditor, paneState, paneCalltrace]

  test "a stack shows only its active child":
    let l = stack([pane(paneState), pane(paneEventLog), pane(paneFlow)],
                  activeIndex = 1)
    check l.allPanes() == @[paneState, paneEventLog, paneFlow]
    check l.visiblePanes() == @[paneEventLog]

  test "nesting composes: a hidden tab inside a visible row stays hidden":
    let l = row([
      pane(paneEditor),
      stack([pane(paneState), pane(paneEventLog)], activeIndex = 0)])
    check l.visiblePanes() == @[paneEditor, paneState]

  test "clone is deep — two sessions never share a node":
    let a = defaultReplayLayout()
    let b = a.clone()
    check b.activate(paneEventLog)
    check b.isVisible(paneEventLog)
    check not a.isVisible(paneEventLog)
    check a.isVisible(paneState)

  test "clone of nil is nil":
    var n: LayoutNode = nil
    check n.clone().isNil

# ---------------------------------------------------------------------------
# Tab switching — what session_switch.nim does through GoldenLayout
# ---------------------------------------------------------------------------

suite "Layout model — activation":

  test "activating a tabbed pane selects it in its stack":
    let l = defaultReplayLayout()
    check not l.isVisible(paneEventLog)
    check l.activate(paneEventLog)
    check l.isVisible(paneEventLog)
    check not l.isVisible(paneState)

  test "activating an already-visible pane is a no-op that still succeeds":
    let l = defaultReplayLayout()
    let before = l.visiblePanes()
    check l.activate(paneEditor)
    check l.visiblePanes() == before

  test "activating an absent pane changes nothing and says so":
    let l = defaultReplayLayout()
    let before = l.visiblePanes()
    check not l.activate(paneScratchpad)
    check l.visiblePanes() == before

  test "activation selects in every enclosing stack, not just the innermost":
    # Two nested stacks: reaching the target means selecting a tab twice.
    # A one-level implementation passes every single-stack test and fails
    # this one, which is why it is here.
    let inner = stack([pane(paneEventLog), pane(paneFlow)], activeIndex = 0)
    let outer = stack([pane(paneState), pane(paneCalltrace)], activeIndex = 0)
    let l = row([outer, column([inner])])
    check not l.isVisible(paneCalltrace)
    check l.activate(paneCalltrace)
    check l.isVisible(paneCalltrace)
    check l.activate(paneFlow)
    check l.isVisible(paneFlow)
    check l.isVisible(paneCalltrace)

  test "find returns the leaf, and nil for an absent pane":
    let l = defaultReplayLayout()
    let leaf = l.find(paneEditor)
    check not leaf.isNil
    check leaf.kind == lnPane
    check leaf.title == "Editor"
    check l.find(paneShell).isNil

  test "setWeight resizes the region holding a pane":
    let l = defaultReplayLayout()
    check l.setWeight(paneEditor, 7.5)
    check l.find(paneEditor).weight == 7.5
    check not l.setWeight(paneShell, 1.0)

# ---------------------------------------------------------------------------
# Adding and removing
# ---------------------------------------------------------------------------

suite "Layout model — adding and removing panes":

  test "removing a tabbed pane leaves the stack and fixes the active index":
    let l = stack([pane(paneState), pane(paneEventLog)], activeIndex = 1)
    let holder = column([l])
    check holder.removePane(paneEventLog)
    check l.children.len == 1
    check l.activeIndex == 0
    check holder.visiblePanes() == @[paneState]

  test "removing the last child of a container collapses the container":
    let l = row([pane(paneEditor), column([pane(paneState)])])
    check l.removePane(paneState)
    check l.children.len == 1
    check l.allPanes() == @[paneEditor]
    # The collapse is what keeps lpEmptyContainer unreachable through
    # ordinary use, so the tree must still validate afterwards.
    check l.validate().len == 0

  test "removing an absent pane reports false and changes nothing":
    let l = defaultReplayLayout()
    let before = l.allPanes()
    check not l.removePane(paneShell)
    check l.allPanes() == before

  test "adding a pane to a stack selects it":
    let s = stack([pane(paneState)], activeIndex = 0)
    check s.addPane(pane(paneEventLog, "Event Log"))
    check s.activeIndex == 1
    check s.visiblePanes() == @[paneEventLog]

  test "adding to a bare pane is refused rather than silently dropped":
    let leaf = pane(paneEditor)
    check not leaf.addPane(pane(paneState))
    check leaf.allPanes() == @[paneEditor]

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

suite "Layout model — validation":

  test "an empty container is reported":
    let l = column([])
    let problems = l.validate()
    check problems.len == 1
    check problems[0].kind == lpEmptyContainer
    check problems[0].path == ""
    check not l.isValid()

  test "a duplicate pane is reported once, at the second placement":
    let l = row([pane(paneEditor), column([pane(paneEditor)])])
    let problems = l.validate()
    check problems.len == 1
    check problems[0].kind == lpDuplicatePane
    check problems[0].pane == some(paneEditor)
    check problems[0].path == "1/0"

  test "a stack whose active index does not exist is reported":
    let l = stack([pane(paneState), pane(paneEventLog)], activeIndex = 5)
    let problems = l.validate()
    check problems.len == 1
    check problems[0].kind == lpActiveIndexOutOfRange
    # The out-of-range index must not also crash the visibility query.
    check l.visiblePanes().len == 0

  test "a container inside a stack is reported":
    let l = stack([pane(paneState), column([pane(paneEventLog)])])
    var kinds: seq[LayoutProblemKind] = @[]
    for p in l.validate():
      kinds.add(p.kind)
    check lpStackChildNotPane in kinds

  test "a leaf carrying children is reported — the flat-record hazard":
    let bad = LayoutNode(kind: lnPane, pane: paneState,
                         children: @[pane(paneEventLog)])
    var kinds: seq[LayoutProblemKind] = @[]
    for p in bad.validate():
      kinds.add(p.kind)
    check lpPaneWithChildren in kinds

  test "a negative weight is reported":
    let l = column([pane(paneEditor, weight = -1.0)])
    var kinds: seq[LayoutProblemKind] = @[]
    for p in l.validate():
      kinds.add(p.kind)
    check lpNegativeWeight in kinds

  test "every problem kind is reachable from some tree":
    # The catalogue must not grow a value nothing can produce: a defect kind
    # no tree can exhibit is a defect kind no shell will ever handle. The
    # `case` below is exhaustive, so adding a value to LayoutProblemKind
    # without a witness here is a compile error.
    for kind in LayoutProblemKind:
      let witness =
        case kind
        of lpEmptyContainer: column([])
        of lpPaneWithChildren:
          LayoutNode(kind: lnPane, pane: paneState,
                     children: @[pane(paneEventLog)])
        of lpContainerWithPaneField:
          LayoutNode(kind: lnColumn, pane: paneState,
                     children: @[pane(paneEventLog)])
        of lpStackChildNotPane:
          stack([pane(paneState), column([pane(paneEventLog)])])
        of lpActiveIndexOutOfRange:
          stack([pane(paneState)], activeIndex = 9)
        of lpDuplicatePane:
          row([pane(paneEditor), pane(paneEditor)])
        of lpNegativeWeight: column([pane(paneEditor, weight = -1.0)])
      var kinds: seq[LayoutProblemKind] = @[]
      for p in witness.validate():
        kinds.add(p.kind)
      checkpoint("witness for " & $kind & ": " & $witness)
      check kind in kinds

# ---------------------------------------------------------------------------
# Serialisation — the replacement for saving a GoldenLayoutResolvedConfig
# ---------------------------------------------------------------------------

suite "Layout model — save and restore":

  test "a layout round-trips through JSON unchanged":
    let original = defaultReplayLayout()
    check original.activate(paneEventLog)
    check original.setWeight(paneEditor, 4.25)
    let restored = restoreLayout(original.saveLayout())
    check restored.allPanes() == original.allPanes()
    check restored.visiblePanes() == original.visiblePanes()
    check restored.find(paneEditor).weight == 4.25
    check restored.find(paneEditor).title == "Editor"
    check $restored == $original

  test "restoring twice from one document yields independent trees":
    let doc = defaultReplayLayout().saveLayout()
    let a = restoreLayout(doc)
    let b = restoreLayout(doc)
    check a.activate(paneEventLog)
    check a.isVisible(paneEventLog)
    check not b.isVisible(paneEventLog)

  test "a document from an unknown schema version is refused by kind":
    var doc = defaultReplayLayout().saveLayout()
    doc["version"] = %(LayoutSchemaVersion + 1)
    var caught = false
    try:
      discard restoreLayout(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownVersion
      check e.detail == $(LayoutSchemaVersion + 1)
    check caught

  test "an unknown pane name is refused by kind, not silently dropped":
    # This is the failure GoldenLayout has no way to express: an
    # unrecognised componentName becomes an empty tab.
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "pane", "pane": "blockExplorer"}
    }
    var caught = false
    try:
      discard restoreLayout(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownPane
      check e.detail == "blockExplorer"
    check caught

  test "an unknown node kind is refused by kind":
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "grid", "children": []}
    }
    var caught = false
    try:
      discard restoreLayout(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownNodeKind
    check caught

  test "a missing required field is refused by kind":
    for missing in ["version", "layout"]:
      var doc = defaultReplayLayout().saveLayout()
      doc.delete(missing)
      var caught = false
      try:
        discard restoreLayout(doc)
      except LayoutDecodeError as e:
        caught = true
        check e.kind == ldeMissingField
        check e.detail == missing
      checkpoint("missing field: " & missing)
      check caught

  test "a field of the wrong type is refused by kind":
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "pane", "pane": "state", "weight": "wide"}
    }
    var caught = false
    try:
      discard restoreLayout(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeWrongFieldType
    check caught

  test "a pane leaf with no pane name is refused by kind":
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "pane"}
    }
    var caught = false
    try:
      discard restoreLayout(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeMissingField
      check e.detail == "pane"
    check caught

  test "every pane name survives a round trip":
    # The enum's string values ARE the wire format. A renamed value that
    # nobody notices silently invalidates every saved layout, so all eleven
    # are round-tripped rather than a representative sample.
    for p in PaneKind:
      let restored = restoreLayout(pane(p, "t").saveLayout())
      checkpoint("pane " & $p)
      check restored.pane == p
      check restored.allPanes() == @[p]

  test "toJson omits defaults so a hand-written fixture matches":
    let j = pane(paneState).toJson()
    check not j.hasKey("title")
    check not j.hasKey("weight")
    check not j.hasKey("children")
    check j["kind"].getStr == "pane"
    check j["pane"].getStr == "state"
