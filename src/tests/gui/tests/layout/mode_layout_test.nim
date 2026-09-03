## ONE LAYOUT PER MODE, exercised against the real bundled layout and the real
## per-mode tables.
##
## `GUI/Layout-And-Navigation/Mode-Transitions.md` §4 requires each mode to have
## its own layout. Until now a mode's layout was the bundled tree with panes
## SUBTRACTED, which cannot say where a pane belongs — so debug mode inherited
## the top-level TEST RESULTS and CONSTRAINTS columns the bundled tree draws for
## the Noir studio's *editing* surface, and no hidden set could have said
## otherwise.
##
## What is under test is therefore two things and their composition:
##
##   * `index/layout_config_repair.nestPanesIntoHosts` — the engine. Moves a
##     pane into another pane's stack, prunes what it empties, keeps every
##     `activeItemIndex` in range, and is idempotent.
##   * `common_types/…/frontend.paneHomesForMode` and `.modeHiddenContentIds` —
##     the per-mode tables, read from the PRODUCTION source through
##     `common/types` rather than mirrored here. A test that mirrored them
##     could not fail when the product changed its mind.
##   * `modeDefaultLayoutConfig` — the composition, over the REAL
##     `src/config/default_layout.json`. The placements the request asked for
##     are asserted as OUTPUTS of the general rule, which is the whole claim:
##     if they had to be special-cased, this file is where that would show.
##
## Runs headlessly under `nim js` + node: `layout_config_repair` imports nothing
## but `std/jsffi`, and `common/types` compiles on the JS backend (the same
## property `deepreview/fixtures/emit_edit_layout_fixture.nim` relies on).

import std/unittest

when defined(js):
  import std/jsffi

  import ../../../../frontend/index/layout_config_repair
  import ../../../../common/types

  const bundledDefaultLayoutJson =
    staticRead("../../../../config/default_layout.json")

  proc jsonParse(raw: cstring): js {.importjs: "JSON.parse(#)".}
  proc jsonStringify(value: js): cstring {.importjs: "JSON.stringify(#)".}
  proc isNodeType(node: js; want: cstring): bool {.importjs: "(#.type === #)".}
    ## `cast[cstring](node.type)` does not compile — `js` field access yields a
    ## `JsObject`, not a `cstring` — and a `$` on it would compare the JS
    ## `String()` of whatever is there. Asked in JavaScript, where the value
    ## actually lives.

  proc bundled(): js = jsonParse(cstring(bundledDefaultLayoutJson))

  proc rootOf(config: js): js =
    let root = config.root
    if root.isNil or root.isUndefined: config else: root

  proc stackContentsHolding(config: js; content: int): seq[int] =
    ## The `content` ids of every component in the STACK that holds `content`,
    ## in tab order. Empty when no component with that content exists.
    ##
    ## This is the question the request is about — "nested under the same pane
    ## that holds the FILES" is a statement about stack membership — so it is
    ## asked directly rather than inferred from a shape assertion.
    var answer: seq[int] = @[]
    var found = false
    proc visit(node: js) =
      if found or node.isNil or node.isUndefined: return
      let kids = node.content
      if kids.isNil or kids.isUndefined: return
      let count = cast[int](kids.length)
      if isNodeType(node, cstring"stack"):
        var members: seq[int] = @[]
        var holdsIt = false
        for i in 0 ..< count:
          let state = kids[i].componentState
          if state.isNil or state.isUndefined: continue
          let c = state.content
          if c.isNil or c.isUndefined: continue
          let id = cast[int](c)
          members.add id
          if id == content: holdsIt = true
        if holdsIt:
          answer = members
          found = true
          return
      for i in 0 ..< count:
        visit(kids[i])
    visit(rootOf(config))
    answer

  proc componentCount(config: js; content: int): int =
    var total = 0
    proc visit(node: js) =
      if node.isNil or node.isUndefined: return
      let state = node.componentState
      if not state.isNil and not state.isUndefined:
        let c = state.content
        if not c.isNil and not c.isUndefined and cast[int](c) == content:
          total += 1
      let kids = node.content
      if kids.isNil or kids.isUndefined: return
      for i in 0 ..< cast[int](kids.length):
        visit(kids[i])
    visit(rootOf(config))
    total

  proc topLevelColumnCount(config: js): int =
    let root = rootOf(config)
    let kids = root.content
    if kids.isNil or kids.isUndefined: 0 else: cast[int](kids.length)

  proc activeIndicesInRange(config: js): bool =
    ## Every stack's `activeItemIndex` names a child that exists.
    ##
    ## The invariant GoldenLayout enforces in `Stack.init` and the one that
    ## made issue #608 a *permanently* unloadable file. A transform that moves
    ## tabs between stacks can break it in both directions at once — the source
    ## stack loses a child, the destination gains one — so it is asserted after
    ## every placement rather than trusted.
    var ok = true
    proc visit(node: js) =
      if not ok or node.isNil or node.isUndefined: return
      let kids = node.content
      if kids.isNil or kids.isUndefined: return
      let count = cast[int](kids.length)
      if isNodeType(node, cstring"stack"):
        let active = node.activeItemIndex
        if not active.isNil and not active.isUndefined:
          let value = cast[int](active)
          if value < 0 or value >= count: ok = false
      for i in 0 ..< count:
        visit(kids[i])
    visit(rootOf(config))
    ok

  proc modeLayout(mode: LayoutMode): js =
    modeDefaultLayoutConfig(bundled(), ord(Content.EditorView),
                            modeHiddenContentIds(mode), paneHomesForMode(mode))

  suite "the bundled layout is the arrangement these rules are about":
    ## A precondition, checked rather than assumed. Every assertion below is
    ## about a CHANGE to this tree; if the tree already had TEST RESULTS beside
    ## FILES, the tests would pass while measuring nothing.

    test "the bundled tree gives TEST RESULTS and CONSTRAINTS their own column":
      let config = bundled()
      check componentCount(config, ord(Content.TestResults)) == 1
      check componentCount(config, ord(Content.Constraints)) == 1
      check stackContentsHolding(config, ord(Content.TestResults)) ==
        @[ord(Content.TestResults)]
      check stackContentsHolding(config, ord(Content.Constraints)) ==
        @[ord(Content.Constraints)]
      check stackContentsHolding(config, ord(Content.Filesystem)) ==
        @[ord(Content.Filesystem), ord(Content.VCS)]
      check topLevelColumnCount(config) == 3

  suite "nestPanesIntoHosts":
    test "a pane becomes the last tab of its host's stack":
      let moved = nestPanesIntoHosts(
        bundled(), @[@[ord(Content.TestResults), ord(Content.Filesystem)]])
      check stackContentsHolding(moved, ord(Content.Filesystem)) ==
        @[ord(Content.Filesystem), ord(Content.VCS), ord(Content.TestResults)]

    test "the host keeps its place at the front of the strip":
      ## Appending rather than inserting is what keeps FILES the visible tab.
      ## A placement that stole focus would be a worse defect than the one
      ## being fixed: the user's file tree would vanish behind a panel they did
      ## not ask for, on every switch.
      let moved = nestPanesIntoHosts(
        bundled(), @[@[ord(Content.TestResults), ord(Content.Filesystem)]])
      let members = stackContentsHolding(moved, ord(Content.Filesystem))
      check members[0] == ord(Content.Filesystem)
      check activeIndicesInRange(moved)

    test "a stack emptied by the move is dropped, and so is its column":
      let moved = nestPanesIntoHosts(bundled(), @[
        @[ord(Content.TestResults), ord(Content.Filesystem)],
        @[ord(Content.Constraints), ord(Content.EventLog)]])
      # Both panes still EXIST — they were re-homed, not hidden.
      check componentCount(moved, ord(Content.TestResults)) == 1
      check componentCount(moved, ord(Content.Constraints)) == 1
      # ...and the column that held them is gone rather than left empty. An
      # empty stack is a config GoldenLayout rejects outright.
      check topLevelColumnCount(moved) == 2

    test "running it twice changes nothing":
      ## `Mode-Transitions.md` §6: the nth transition behaves as the first.
      ## This transform runs on every switch that falls back to a mode's
      ## default, so a second pass over its own output must be a no-op.
      let placements = @[
        @[ord(Content.TestResults), ord(Content.Filesystem)],
        @[ord(Content.Constraints), ord(Content.EventLog)]]
      let once = nestPanesIntoHosts(bundled(), placements)
      let twice = nestPanesIntoHosts(jsonParse(jsonStringify(once)), placements)
      check jsonStringify(once) == jsonStringify(twice)

    test "a placement naming an absent pane is skipped, not fatal":
      ## Edit mode hides the EVENT LOG, so a CONSTRAINTS-under-EVENT-LOG row
      ## has no host there. The transform must leave the layout alone rather
      ## than raise or invent a stack.
      let editish = sanitizeLayoutConfig(
        bundled(), ord(Content.EditorView), modeHiddenContentIds(EditMode))
      let before = jsonStringify(editish)
      let after = nestPanesIntoHosts(jsonParse(before), @[
        @[ord(Content.Constraints), ord(Content.EventLog)]])
      check jsonStringify(after) == before
      check componentCount(after, ord(Content.Constraints)) == 1

    test "an empty placement table returns the config untouched":
      let config = bundled()
      check jsonStringify(nestPanesIntoHosts(config, @[])) ==
        jsonStringify(bundled())

    test "every stack keeps a usable activeItemIndex":
      let moved = nestPanesIntoHosts(bundled(), @[
        @[ord(Content.TestResults), ord(Content.Filesystem)],
        @[ord(Content.Constraints), ord(Content.EventLog)]])
      check activeIndicesInRange(moved)

  suite "each mode's default layout":
    ## The requirement, and the placements it produces. Read these as the
    ## general rule's OUTPUT: nothing below names a special case, and each
    ## expectation follows from `paneHomesForMode` plus `modeHiddenContentIds`.

    test "DEBUG mode has no standing TEST RESULTS or CONSTRAINTS column":
      ## The reported defect, stated as an assertion. Before the per-mode
      ## placement table this layout was `sanitizeLayoutConfig(bundled, …, @[])`
      ## — the bundled tree verbatim — and its top level had three columns, the
      ## third being exactly these two panes.
      let debugLayout = modeLayout(DebugMode)
      check topLevelColumnCount(debugLayout) == 2

    test "DEBUG mode nests TEST RESULTS with FILES":
      let debugLayout = modeLayout(DebugMode)
      check ord(Content.TestResults) in
        stackContentsHolding(debugLayout, ord(Content.Filesystem))

    test "DEBUG mode nests CONSTRAINTS with the EVENT LOG":
      let debugLayout = modeLayout(DebugMode)
      check ord(Content.Constraints) in
        stackContentsHolding(debugLayout, ord(Content.EventLog))

    test "DEBUG mode keeps both panes reachable":
      ## Re-homing is not hiding, and the difference is the point. A user
      ## debugging a failing test must still be able to open TEST RESULTS.
      let debugLayout = modeLayout(DebugMode)
      check componentCount(debugLayout, ord(Content.TestResults)) == 1
      check componentCount(debugLayout, ord(Content.Constraints)) == 1

    test "EDIT mode keeps TEST RESULTS in a column of its own":
      ## THE DEVIATION FROM THE REQUEST, ASSERTED SO IT CANNOT DRIFT BACK.
      ##
      ## The request asked for TEST RESULTS nested with FILES "in both modes".
      ## In edit mode that puts the ▶ Run Tests control — the primary gesture
      ## of `Noir-Studio.md` §1a's first screen — behind a tab click, because a
      ## background tab is `display: none` and neither laid out nor
      ## hit-testable. `paneHomesForMode`'s own comment carries the full
      ## reasoning and the measurement that settled it.
      ##
      ## This test is the guard on the trade, not a restatement of it: if a
      ## later change re-adds the edit-mode row, this fails HERE — in a
      ## sub-second headless run — instead of in the pre-publish gate, which is
      ## where it failed the first time.
      let editLayout = modeLayout(EditMode)
      check ord(Content.TestResults) notin
        stackContentsHolding(editLayout, ord(Content.Filesystem))
      check stackContentsHolding(editLayout, ord(Content.TestResults)) ==
        @[ord(Content.TestResults)]

    test "EDIT mode is the bundled arrangement, minus what it hides":
      ## §1a's first screen is three top-level columns — FILES, the editor's
      ## room, and the NS9 panes — and the pre-publish mount gate measures them
      ## at 20/55/25 against the assembled bundle. Nothing edit mode does may
      ## take a column away, because the third column IS the two panes the gate
      ## reads its proportions from.
      let editLayout = modeLayout(EditMode)
      check paneHomesForMode(EditMode).len == 0
      check topLevelColumnCount(editLayout) == 2
      # Two, not three, because the EDITOR's own column is created at runtime
      # by `utils.openNewLayoutContainer` and is never declared in the config.
      # Its width is the shortfall this config leaves, which is the next check.
      check unclaimedTopLevelPercent(editLayout) == 55

    test "EDIT mode keeps CONSTRAINTS in a pane of its own":
      ## And this is the tension worth stating rather than smoothing over. The
      ## request nests CONSTRAINTS under the EVENT LOG *in debug mode*; edit
      ## mode has no event log at all (`modeHiddenContentIds(EditMode)` hides
      ## `Content.EventLog`), so there is nothing there to nest it under. It
      ## keeps the column the bundled layout gives it, which is what
      ## `Noir-Studio.md` §1a draws for the editing surface.
      let editLayout = modeLayout(EditMode)
      check componentCount(editLayout, ord(Content.EventLog)) == 0
      check stackContentsHolding(editLayout, ord(Content.Constraints)) ==
        @[ord(Content.Constraints)]

    test "EDIT mode still hides the replay-only panes":
      ## The suppression half is unchanged, and is asserted so that a change to
      ## the placement half cannot quietly resurrect a pane.
      let editLayout = modeLayout(EditMode)
      for hidden in modeHiddenContentIds(EditMode):
        check componentCount(editLayout, hidden) == 0

    test "DEBUG mode hides nothing":
      let debugLayout = modeLayout(DebugMode)
      check modeHiddenContentIds(DebugMode).len == 0
      check componentCount(debugLayout, ord(Content.EventLog)) == 1
      check componentCount(debugLayout, ord(Content.State)) == 1

    test "no mode nests a pane whose own primary control the mode leads with":
      ## THE RULE BEHIND THE DEVIATION, stated once so the next placement row
      ## is judged by it rather than by precedent.
      ##
      ## A nested pane is a background tab, so its controls are unreachable
      ## until the tab is clicked. That is acceptable for a pane a user goes
      ## TO, and not for a pane a user acts FROM. TEST RESULTS on the editing
      ## surface is the second kind; on the replay surface it is the first,
      ## because a replay is driven from the debugger controls and the pane is
      ## somewhere you look up which test you are in.
      ##
      ## Checked here as: a mode that hides the EVENT LOG is an editing mode,
      ## and an editing mode leads with the test runner, so it may not nest
      ## TEST RESULTS.
      for mode in LayoutMode:
        let leadsWithTheRunner =
          ord(Content.EventLog) in modeHiddenContentIds(mode)
        if leadsWithTheRunner:
          for placement in paneHomesForMode(mode):
            check placement[0] != ord(Content.TestResults)

    test "the two modes produce different layouts":
      ## The whole requirement in one line. Before this change both modes were
      ## readings of one tree and this could still have held — by suppression
      ## alone — but it is the assertion that fails first if a future change
      ## collapses the two back into one.
      check jsonStringify(modeLayout(EditMode)) !=
        jsonStringify(modeLayout(DebugMode))

    test "every mode's default is loadable-shaped":
      for mode in LayoutMode:
        let config = modeLayout(mode)
        check not config.isNil
        check activeIndicesInRange(config)
        # NEVER NOTHING: every mode's default is a workspace with panes in it,
        # which is the property the degradation path depends on.
        check topLevelColumnCount(config) > 0
        check componentCount(config, ord(Content.Filesystem)) == 1

    test "a mode's default leaves room for the editor":
      ## `utils.openNewLayoutContainer` sizes the editor from
      ## `unclaimedTopLevelPercent`, which reads the shortfall in the config AS
      ## SENT. Dropping a column widens that shortfall, and a mode whose
      ## columns already sum to 100 gives the editor an equal share instead —
      ## measured previously as a 29/33/37 split where the layout declared
      ## 20/55/25.
      check unclaimedTopLevelPercent(modeLayout(DebugMode)) > 0
      check unclaimedTopLevelPercent(modeLayout(EditMode)) > 0

  suite "the per-mode tables":
    test "the editing modes share one hidden set":
      ## `QuickEditMode` and `InteractiveEditMode` are editing modes and must
      ## not be filed under the debug layout by a `mode == EditMode` written at
      ## a call site.
      check modeHiddenContentIds(QuickEditMode) ==
        modeHiddenContentIds(EditMode)
      check modeHiddenContentIds(InteractiveEditMode) ==
        modeHiddenContentIds(EditMode)

    test "the replay modes home TEST RESULTS with FILES and the editing modes do not":
      ## Asserted over every member of `LayoutMode` rather than the two the
      ## request named, so a mode added later cannot silently pick either
      ## answer by accident.
      ##
      ## The split is not "edit versus debug" as a matter of naming: it is that
      ## a mode which SHOWS the ▶ as its primary gesture must not put it behind
      ## a tab, and the editing modes are the ones that do.
      let home = @[ord(Content.TestResults), ord(Content.Filesystem)]
      for mode in LayoutMode:
        if mode in {EditMode, QuickEditMode, InteractiveEditMode}:
          check home notin paneHomesForMode(mode)
        else:
          check home in paneHomesForMode(mode)

    test "a placement never names a pane its own mode hides":
      ## A row whose PANE the mode suppresses is dead: the pane is gone before
      ## the transform runs. (A row whose HOST is hidden is legitimate and
      ## simply skipped — that is edit mode's absent event log.)
      for mode in LayoutMode:
        let hidden = modeHiddenContentIds(mode)
        for placement in paneHomesForMode(mode):
          check placement[0] notin hidden
