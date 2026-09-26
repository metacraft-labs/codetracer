## SDK-CONSUMER: the headless application entrypoint's own suite. Like the
## entrypoint it drives, it reaches the replay core only through
## `codetracer_embed` — `headless_app/headless_app` re-exports nothing from
## the SDK subtree, so a reach past the facade here would be caught by
## ci/test/sdk-facade-boundary.sh rather than by review.
##
## test_headless_app_entrypoint.nim
##
## BlockTracer.milestones.org M2a, item 1 — "a headless app entrypoint".
##
## ## What is being asserted
##
## `viewmodel/app/isonim_app.nim` opens with
## `when not defined(js): {.error: "isonim_app requires the JS backend".}`,
## looks up `#isonim-app` in a document, and mounts eleven panels into a
## `WebRenderer`. It is the application entrypoint, and it cannot exist
## without a DOM.
##
## This suite drives the entrypoint that can: several sessions, each with its
## own layout, switched between and torn down, in a process with no Electron,
## no display and no renderer of any kind. Three properties are the point:
##
##   1. **Creating the shell sends nothing.** `MockBackendService
##      .receivedCommands` is pinned before and after, exactly as
##      `test_cross_pane_composition_needs_no_bridge.nim` pins it — a shell
##      that fires `ct/load-locals` at a backend with no trace open is a real
##      defect and an easy one to introduce.
##
##   2. **Switching sessions moves no layout.** The desktop must copy
##      `data.ui.resolvedConfig` into `session.savedLayoutConfig` on the way
##      out and call `callInitLayoutSafe` on the way back in
##      (`src/frontend/ui/session_switch.nim`). Here each slot has held its
##      own tree the whole time, so the assertion is that a round trip
##      through a second session changes the first session's layout by
##      nothing at all.
##
##   3. **The pane enum is not decorative.** `paneViewModel` is an exhaustive
##      `case` over `PaneKind` returning the session's real ViewModel, so a
##      pane that nothing implements does not compile, and `paneIsLive`
##      distinguishes "placed in the layout" from "has a ViewModel behind it".
##
## ## The one stand-in, and why it is justified
##
## Every session here is opened over `MockBackendService` — the only mock in
## this file, and the workspace policy asks for the reason in writing. The
## subject is the SHELL: which sessions exist, which is active, and each one's
## `Layout` and its save/restore document. None of that crosses the backend
## boundary — property 1 above pins `receivedCommands` to prove that opening
## a session sends nothing — so a real `replay-server` would be a process the
## assertions never talk to. The cases that DO drive the backend (launch
## failure, a launched session's live panes) script exactly the DAP replies
## they assert on, and the real-process half of the same shell is covered by
## the GPUI and terminal suites that open a real recording.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_headless_app_entrypoint.nim

import std/[json, options, unittest]

import codetracer_embed
import headless_app/headless_app

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mockBackend(): MockBackendService =
  newMockBackendService(autoRespond = true)

proc failingBackend(message: string): MockBackendService =
  let mock = newMockBackendService(autoRespond = true)
  mock.expect("initialize", %*{"success": true})
  mock.expect("configurationDone", %*{"success": true})
  mock.expect("launch", %*{"success": false, "message": message})
  mock

proc traceOf(path: string): TraceSource =
  localFolderTrace(path)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

suite "Headless app — construction is passive":

  test "a new app has no sessions and no active slot":
    let app = newHeadlessApp()
    check app.slotCount == 0
    check app.activeSlot.isNil
    check app.activeSessionId == NoHeadlessSession
    app.dispose()

  test "opening a session sends nothing to the backend":
    # The whole reason `createAppViewModel(initializePanels = false)` exists.
    # A shell that wakes the panel ViewModels at construction time issues
    # `ct/load-locals` against an engine with no trace open.
    let mock = mockBackend()
    let app = newHeadlessApp()
    let before = mock.receivedCommands.len
    let slot = app.openSession(mock.toBackendService(), "first")
    check mock.receivedCommands.len == before
    check slot.session.phase.val == dspCreated
    app.dispose()

  test "no pane is live before launch, though every one is placed":
    let app = newHeadlessApp()
    let slot = app.openSession(mockBackend().toBackendService())
    for p in ReplayCorePanes:
      check slot.layout.tree.contains(p)
      check not slot.paneIsLive(p)
    check slot.livePanes().len == 0
    app.dispose()

  test "the shell refuses to build its own backend":
    let app = newHeadlessApp()
    var caught = false
    try:
      discard app.openSession(nil, "no backend")
    except HeadlessAppError:
      caught = true
    check caught
    check app.slotCount == 0
    app.dispose()

  test "an invalid layout is refused at open rather than rendered":
    let app = newHeadlessApp()
    var caught = false
    try:
      discard app.openSession(mockBackend().toBackendService(),
                              layout = column([]))
    except HeadlessAppError:
      caught = true
    check caught
    check app.slotCount == 0
    app.dispose()

  test "the default layout is used when none is given":
    let app = newHeadlessApp()
    let slot = app.openSession(mockBackend().toBackendService())
    check slot.layout.allPanes().len == 5
    check slot.visiblePanes().len == 4
    app.dispose()

# ---------------------------------------------------------------------------
# Launch, and the panes coming alive
# ---------------------------------------------------------------------------

suite "Headless app — launch":

  test "launching a session makes every placed pane live":
    let app = newHeadlessApp()
    let slot = app.openSession(mockBackend().toBackendService())
    slot.session.launch(traceOf("/tmp/trace-a"))
    check slot.session.phase.val == dspReady
    for p in slot.layout.allPanes():
      checkpoint("pane " & $p)
      check slot.paneIsLive(p)
    check slot.livePanes().len == slot.layout.allPanes().len
    app.dispose()

  test "every REPLAY PaneKind resolves to a ViewModel on a launched session":
    # `paneViewModel`'s `case` is exhaustive, so an unimplemented pane is a
    # compile error. This is the runtime half: the exhaustive case must also
    # be *correct* — a branch wired to a nil field would compile and would
    # make the pane silently unrenderable.
    #
    # PLAT-16 NARROWED THIS FROM "every PaneKind" TO "every REPLAY PaneKind",
    # AND THE EXCLUSION IS NAMED RATHER THAN SUBTRACTED. `paneFileTree` and
    # `paneBuildOutput` belong to EDIT mode, whose subject is the working tree
    # rather than a recording (CodeTracer-TUI-Edit-Mode.md §2), and a
    # `HeadlessSessionSlot` IS a replay session — so "this replay session has
    # no ViewModel for that pane" is the true answer and `nil` is how
    # `paneViewModel` says it.
    #
    # The exclusion is written as a SET and both halves are asserted, so a
    # pane cannot join it silently: the excluded set has an exact size, the
    # included set is everything else, and both are non-empty.
    #
    # PLAT-41 MOVED `paneFileTree` OUT OF THE SET (54244c2ac, 2026-09-23), and
    # the move is the product's, not this test's: a replay slot now answers
    # the session's `fileTreeVM` — the RECORDING's own source folders, by the
    # desktop's `sourceFoldersFromTracePaths` rule — not the working tree, so
    # "a replay session has no ViewModel for the file tree" stopped being
    # true. Only `paneBuildOutput` is still edit-mode-only. The file tree is
    # now asserted from the replay side, below, like every other replay pane.
    const EditOnlyPanes = {paneBuildOutput}
    let app = newHeadlessApp()
    let slot = app.openSession(mockBackend().toBackendService())
    slot.session.launch(traceOf("/tmp/trace-b"))
    var replayPanes = 0
    var editPanes = 0
    for p in PaneKind:
      checkpoint("pane " & $p)
      if p in EditOnlyPanes:
        inc editPanes
        # THE OTHER HALF, asserted rather than skipped: an Edit-mode pane must
        # answer nil, not a ViewModel that happens to be lying around. A pane
        # wired to some unrelated VM would compile, would render, and would
        # show a replay session's data under an editor's title.
        check slot.paneViewModel(p).isNil
        check not slot.paneIsLive(p)
      else:
        inc replayPanes
        check not slot.paneViewModel(p).isNil
    checkpoint("replay panes " & $replayPanes & ", edit-only " & $editPanes)
    check editPanes == 1
    check replayPanes > 0
    # The pane PLAT-41 moved, pinned by name so the move cannot be undone
    # quietly by re-adding it to the set above.
    check paneFileTree notin EditOnlyPanes
    check not slot.paneViewModel(paneFileTree).isNil
    app.dispose()

  test "a failed launch leaves the shell intact and the failure readable":
    let app = newHeadlessApp()
    let slot = app.openSession(failingBackend("no such trace").toBackendService())
    slot.session.launch(traceOf("/tmp/missing"))
    check slot.session.phase.val == dspFailed
    check slot.session.failure.val.isSome
    # The shell is still a shell: the slot is open, the layout is intact, and
    # a host can render the failure beside the panes rather than instead of
    # the whole application.
    check app.slotCount == 1
    check slot.layout.visiblePanes().len == 4
    app.dispose()

# ---------------------------------------------------------------------------
# Multi-session — spec §3.1, "multi-session in one page"
# ---------------------------------------------------------------------------

suite "Headless app — multi-session":

  test "two sessions are two, with distinct ids and distinct stores":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let b = app.openSession(mockBackend().toBackendService(), "b")
    check app.slotCount == 2
    check a.id != b.id
    check a.session.id != b.session.id
    check a.session.store.storeId != b.session.store.storeId
    check app.activeSessionId == b.id
    app.dispose()

  test "opening a session makes it active; activating switches back":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let b = app.openSession(mockBackend().toBackendService(), "b")
    check app.activeSlot.id == b.id
    check app.activate(a.id)
    check app.activeSlot.id == a.id
    check app.activeSlot.title == "a"
    app.dispose()

  test "activating an unknown session changes nothing and says so":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    check not app.activate(HeadlessSessionId(4242))
    check app.activeSlot.id == a.id
    app.dispose()

  test "each session owns its layout — switching moves nothing":
    # The property `session_switch.nim` gets by saving and restoring a
    # GoldenLayoutResolvedConfig around every switch.
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let b = app.openSession(mockBackend().toBackendService(), "b")
    check a.activatePane(paneEventLog)
    check b.activatePane(paneState)
    let aBefore = $a.layout
    let bBefore = $b.layout
    # A full round trip through the other session.
    check app.activate(b.id)
    check app.activate(a.id)
    check $a.layout == aBefore
    check $b.layout == bBefore
    check a.visiblePanes() != b.visiblePanes()
    app.dispose()

  test "two sessions opened from one layout value do not share nodes":
    let app = newHeadlessApp()
    let shared = defaultReplayLayout()
    let a = app.openSession(mockBackend().toBackendService(), "a",
                            layout = shared)
    let b = app.openSession(mockBackend().toBackendService(), "b",
                            layout = shared)
    check a.activatePane(paneEventLog)
    check a.layout.tree.isVisible(paneEventLog)
    check not b.layout.tree.isVisible(paneEventLog)
    # The caller's own value is untouched too.
    check not shared.isVisible(paneEventLog)
    app.dispose()

  test "each session's commands go only to its own backend":
    let mockA = mockBackend()
    let mockB = mockBackend()
    let app = newHeadlessApp()
    let a = app.openSession(mockA.toBackendService(), "a")
    discard app.openSession(mockB.toBackendService(), "b")
    let bBefore = mockB.receivedCommands.len
    a.session.launch(traceOf("/tmp/trace-a"))
    check mockA.receivedCommands.len > 0
    check mockB.receivedCommands.len == bBefore
    app.dispose()

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

suite "Headless app — teardown":

  test "closing a session disposes it and picks a new active slot":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let b = app.openSession(mockBackend().toBackendService(), "b")
    check app.closeSession(b.id)
    check b.session.isDisposed
    check app.slotCount == 1
    check app.activeSlot.id == a.id
    app.dispose()

  test "closing the last session leaves no active slot":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    check app.closeSession(a.id)
    check app.slotCount == 0
    check app.activeSessionId == NoHeadlessSession
    check app.activeSlot.isNil
    app.dispose()

  test "closing an unknown session reports false":
    let app = newHeadlessApp()
    discard app.openSession(mockBackend().toBackendService(), "a")
    check not app.closeSession(HeadlessSessionId(99))
    check app.slotCount == 1
    app.dispose()

  test "closing without disconnecting leaves the transport to its owner":
    # `disconnectBackend = false` is the `HeadlessDebugSession` case: the DAP
    # pipe to replay-server belongs to the harness, and closing it here would
    # take the child process down while the harness still needs it.
    let mock = mockBackend()
    let app = newHeadlessApp()
    let a = app.openSession(mock.toBackendService(), "a")
    a.session.launch(traceOf("/tmp/trace-a"))
    check app.closeSession(a.id, disconnectBackend = false)
    check a.session.isDisposed
    check not mock.disconnected
    app.dispose()

  test "dispose is idempotent and disposes every session":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let b = app.openSession(mockBackend().toBackendService(), "b")
    app.dispose()
    check a.session.isDisposed
    check b.session.isDisposed
    check app.isDisposed
    app.dispose()
    check app.isDisposed

  test "using a disposed app is an error, not a silent no-op":
    let app = newHeadlessApp()
    app.dispose()
    var caught = 0
    try:
      discard app.openSession(mockBackend().toBackendService())
    except HeadlessAppError:
      inc caught
    try:
      discard app.activate(HeadlessSessionId(0))
    except HeadlessAppError:
      inc caught
    check caught == 2

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

suite "Headless app — saving and restoring layouts":

  test "layouts round-trip across a fresh app with the same slot ids":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let b = app.openSession(mockBackend().toBackendService(), "b")
    check a.activatePane(paneEventLog)
    check b.layout.tree.setWeight(paneEditor, 4.0)
    # Which session was active is shell state too, so it is set BEFORE the
    # save — a document that recorded the wrong active slot would still
    # restore both layouts and would look right.
    check app.activate(a.id)
    let doc = app.saveLayouts()

    let revived = newHeadlessApp()
    let a2 = revived.openSession(mockBackend().toBackendService(), "x")
    let b2 = revived.openSession(mockBackend().toBackendService(), "y")
    check a2.id == a.id
    check b2.id == b.id
    check revived.restoreLayouts(doc) == 2
    check $a2.layout == $a.layout
    check $b2.layout == $b.layout
    # Titles are shell state and travel with the document.
    check a2.title == "a"
    check b2.title == "b"
    check revived.activeSessionId == a.id
    app.dispose()
    revived.dispose()

  test "a session the document does not mention keeps its layout":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    check a.activatePane(paneEventLog)
    let doc = app.saveLayouts()

    let revived = newHeadlessApp()
    let a2 = revived.openSession(mockBackend().toBackendService(), "a")
    let b2 = revived.openSession(mockBackend().toBackendService(), "b")
    let bBefore = $b2.layout
    check revived.restoreLayouts(doc) == 1
    check $a2.layout == $a.layout
    check $b2.layout == bBefore
    app.dispose()
    revived.dispose()

  test "an unreadable document leaves every layout untouched":
    # Decode-then-apply, not apply-as-you-go: a document whose second entry is
    # broken must not leave the first session rearranged.
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let b = app.openSession(mockBackend().toBackendService(), "b")
    let aBefore = $a.layout
    let bBefore = $b.layout
    var doc = app.saveLayouts()
    check doc["sessions"].len == 2
    doc["sessions"][1]["layout"]["kind"] = %"grid"
    var caught = false
    try:
      discard app.restoreLayouts(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownNodeKind
    check caught
    check $a.layout == aBefore
    check $b.layout == bBefore
    app.dispose()

  test "a document from an unknown schema version is refused by kind":
    let app = newHeadlessApp()
    discard app.openSession(mockBackend().toBackendService(), "a")
    var doc = app.saveLayouts()
    doc["version"] = %(LayoutSchemaVersion + 1)
    var caught = false
    try:
      discard app.restoreLayouts(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownVersion
    check caught
    app.dispose()

  test "a DOCKED pane survives saveLayouts -> restoreLayouts":
    # PLAT-4's closing pass (2026-09-26). `HeadlessSessionSlot.layout` was a
    # bare `LayoutNode`, so a session could not hold a docked pane at all and
    # the GPUI shell's sync copied only the tree onto it — the app-level
    # document then had the pane in NEITHER place. The slot holds a whole
    # `Layout` now, and the document carries its `docked` list.
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let docked = apply(a.layout, cmdDock(paneEventLog, leBottom))
    check docked.kind == loApplied
    if docked.kind == loApplied:
      a.layout = docked.layout
    check a.layout.placement(paneEventLog) == plDocked
    check paneEventLog notin a.visiblePanes()
    let doc = app.saveLayouts()
    check doc["sessions"][0]["docked"].len == 1
    check doc["sessions"][0]["docked"][0]["pane"].getStr == $paneEventLog

    let revived = newHeadlessApp()
    let a2 = revived.openSession(mockBackend().toBackendService(), "x")
    check a2.layout.placement(paneEventLog) == plPlaced
    check revived.restoreLayouts(doc) == 1
    check $a2.layout == $a.layout
    check a2.layout.placement(paneEventLog) == plDocked
    # NON-VACUOUS: the Event Log is owned and must be SOMEWHERE — it is on
    # the strip, so the restored layout validates against the whole core set.
    check a2.layout.validate(ReplayCorePanes).len == 0
    # And a restore reopens no overlay (§3.2), through this door too.
    check not a2.layout.docked[0].revealed
    app.dispose()
    revived.dispose()

  test "every session entry writes docked, even empty":
    let app = newHeadlessApp()
    discard app.openSession(mockBackend().toBackendService(), "a")
    let doc = app.saveLayouts()
    check doc["sessions"][0].hasKey("docked")
    check doc["sessions"][0]["docked"].kind == JArray
    check doc["sessions"][0]["docked"].len == 0
    app.dispose()

  test "a document written before sessions held docked panes still restores":
    # Every earlier build wrote each session as a bare tree with no `docked`
    # key. Such an entry means what it meant then — nothing docked — and is
    # read, not refused.
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    check a.activatePane(paneEventLog)
    var doc = app.saveLayouts()
    doc["sessions"][0].delete("docked")
    check not doc["sessions"][0].hasKey("docked")
    let revived = newHeadlessApp()
    let a2 = revived.openSession(mockBackend().toBackendService(), "x")
    check revived.restoreLayouts(doc) == 1
    check $a2.layout == $a.layout
    check a2.layout.docked.len == 0
    app.dispose()
    revived.dispose()

  test "an unreadable docked entry leaves every layout untouched, by kind":
    let app = newHeadlessApp()
    let a = app.openSession(mockBackend().toBackendService(), "a")
    let aBefore = $a.layout
    var doc = app.saveLayouts()
    doc["sessions"][0]["docked"] = %*[{"pane": "editor", "edge": "diagonal",
                                        "order": 0}]
    var caught = false
    try:
      discard app.restoreLayouts(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownEdge
    check caught
    check $a.layout == aBefore
    app.dispose()

  test "a session can be opened over a whole Layout, and a broken one is refused":
    let app = newHeadlessApp()
    let arranged = apply(initLayout(defaultReplayLayout()),
                         cmdDock(paneEventLog, leRight))
    check arranged.kind == loApplied
    if arranged.kind == loApplied:
      let a = app.openSession(mockBackend().toBackendService(), "a",
                              layout = arranged.layout)
      check a.layout.placement(paneEventLog) == plDocked
      # Deep-copied, as the tree overload is: the caller's value is its own.
      check a.layout.tree != arranged.layout.tree
    # §3.3 broken on the way in — placed AND docked — is refused at open.
    var caught = false
    try:
      discard app.openSession(mockBackend().toBackendService(), "b",
        layout = initLayout(defaultReplayLayout(), @[DockedPane(
          pane: paneEventLog, edge: leBottom, order: 0)]))
    except HeadlessAppError:
      caught = true
    check caught
    check app.slotCount == 1
    app.dispose()

  test "an empty app saves a well-formed, restorable document":
    let app = newHeadlessApp()
    let doc = app.saveLayouts()
    check doc["version"].getInt == LayoutSchemaVersion
    check doc["sessions"].len == 0
    check doc["active"].getInt == int(NoHeadlessSession)
    check app.restoreLayouts(doc) == 0
    app.dispose()
