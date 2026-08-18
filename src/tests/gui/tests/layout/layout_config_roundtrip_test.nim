## Headless regression tests for layout persistence — issue #608 (M41).
##
## The reported symptom is that a saved layout breaks on the next open and
## only ``just reset-layout`` recovers it.  Three defects combine to produce
## it, and all three are guarded here:
##
## A. ``sanitizeEditLayoutConfig`` (``src/frontend/index/config.nim``) removes
##    the per-trace editor tabs from every stack on **every replay-mode save**
##    but never remaps the enclosing stack's ``activeItemIndex``.  Mixed
##    stacks are the normal case — "NO SOURCE" (``Content.NoInfo``) and
##    "CALLS" (``Content.CalltraceEditor``) both live in the editor stack — so
##    the written file routinely holds an index past the end of the surviving
##    tabs.  GoldenLayout validates it in ``Stack.init``
##    (``golden-layout/src/ts/items/stack.ts:169-171``) and throws
##    ``ActiveItemIndex out of range``, which aborts ``initLayout`` half-way.
##
## B. Pinning a panel to an edge removes it from the GoldenLayout tree, so a
##    pinned Filesystem panel used to make the layout look "incompatible" and
##    the loader deleted the user's file.
##
## C. Nothing validated the config at *apply* time, only at parse time, so
##    any semantically-rejected shape was fatal rather than recoverable.
##
## The behavioural cases run on the JavaScript backend, against the real
## production logic in ``src/frontend/index/layout_config_repair.nim`` — the
## module was extracted precisely so these invariants can be exercised
## without electron, ``fs`` or GoldenLayout itself.  ``layout_config_repair``
## imports nothing but ``std/jsffi``.
##
## On the native backend the same file runs a source contract instead
## (``std/jsffi`` cannot compile there), asserting that the production call
## sites still route through the repaired helpers and that the auto-hide
## state is actually persisted and restored.  This mirrors
## ``session-chrome/new_trace_caption_chrome_test.nim``.
##
## Do NOT treat ``layout_resilience.spec.ts`` as coverage for any of this:
## every shape it writes is rejected by ``isValidLayoutConfig`` before
## GoldenLayout ever sees the config, which is exactly why the real failure
## slipped through.

import std/unittest

when defined(js):
  import std/jsffi
  import ../../../../frontend/index/layout_config_repair

  # ``Content`` ordinals, mirrored as literals so this test keeps the
  # dependency-free property of the module under test.  Source of truth:
  # ``src/common/common_types/codetracer_features/frontend.nim:259``.
  const
    ContentEditorView = 2
    ContentEventLog = 8
    ContentFilesystem = 9
    ContentState = 4
    ContentCalltraceEditor = 23
    ContentNoInfo = 34

  proc jsonParse(raw: cstring): js {.importjs: "JSON.parse(#)".}
  proc jsonStringify(value: js): cstring {.importjs: "JSON.stringify(#)".}
  proc jsHasOwn(value: js; key: cstring): bool
    {.importjs: "(Object.prototype.hasOwnProperty.call((#) || {}, #))".}
  proc jsLen(value: js): int {.importjs: "(#).length".}
  proc jsIsUndefined(value: js): bool {.importjs: "((#) === undefined)".}

  proc clone(value: js): js = jsonParse(jsonStringify(value))

  proc firstStack(config: js): js =
    ## The first stack in the tree, in document order.
    result = js(nil)
    var pending = @[if jsIsUndefined(config["root"]): config else: config["root"]]
    while pending.len > 0:
      let node = pending[0]
      pending.delete(0)
      if jsIsUndefined(node) or node.isNil:
        continue
      if node["type"].to(cstring) == cstring"stack":
        return node
      if not jsIsUndefined(node["content"]):
        for i in 0 ..< jsLen(node["content"]):
          pending.add(node["content"][i])

  proc contentIds(stack: js): seq[int] =
    for i in 0 ..< jsLen(stack["content"]):
      result.add(stack["content"][i]["componentState"]["content"].to(int))

  proc component(content: int; title: cstring; componentType: cstring): js =
    js{
      "type": cstring"component",
      "componentType": componentType,
      "componentState": js{"id": 0, "label": title, "content": content},
      "title": title
    }

  proc editorTab(title: cstring): js =
    component(ContentEditorView, title, cstring"editorComponent")

  proc genericTab(content: int; title: cstring): js =
    component(content, title, cstring"genericUiComponent")

  proc stackOf(activeItemIndex: int; children: seq[js]): js =
    let node = js{"type": cstring"stack", "content": children}
    if activeItemIndex >= 0:
      node["activeItemIndex"] = activeItemIndex.toJs
    node

  proc rowOf(children: seq[js]): js =
    js{"root": js{"type": cstring"row", "content": children}}

  ## The layout an ordinary replay session produces: the editor stack holds
  ## two source tabs plus the "CALLS" tab (``openCallViewer`` adds
  ## ``Content.CalltraceEditor`` into ``editorPanels[ViewSource]``), and the
  ## user left an editor tab active.  Alongside it sit the Filesystem and
  ## event-log stacks.
  proc mixedEditorStackLayout(activeItemIndex: int): js =
    rowOf(@[
      stackOf(0, @[genericTab(ContentFilesystem, cstring"FILES")]),
      stackOf(activeItemIndex, @[
        editorTab(cstring"a.nim"),
        editorTab(cstring"b.nim"),
        genericTab(ContentCalltraceEditor, cstring"CALLS")]),
      stackOf(0, @[genericTab(ContentEventLog, cstring"EVENTS")])
    ])

  suite "#608 layout config persistence":

    # ---------------------------------------------------------------------
    # Case 2 — the direct regression test for root cause A.
    # ---------------------------------------------------------------------
    test "sanitizer keeps a mixed stack's activeItemIndex in range":
      ## `[editor a.nim, editor b.nim, CALLS]` with `activeItemIndex: 2`.
      ## Before the fix the two editor tabs were dropped and the index was
      ## written out as 2 against a one-tab stack, which makes
      ## GoldenLayout's `Stack.init` throw `ActiveItemIndex out of range`
      ## on the next launch — permanently, because nothing rewrites the file.
      let saved = sanitizeLayoutConfig(
        mixedEditorStackLayout(2), ContentEditorView, @[])
      let stack = firstStack(saved["root"]["content"][1])

      check contentIds(stack) == @[ContentCalltraceEditor]
      check stack["activeItemIndex"].to(int) < jsLen(stack["content"])
      # It must point AT the surviving CALLS tab, not merely be in range.
      check stack["activeItemIndex"].to(int) == 0
      check stackActiveItemIndexInRange(saved)

    test "the whole sanitized tree satisfies GoldenLayout's stack invariant":
      for active in 0 .. 2:
        let saved = sanitizeLayoutConfig(
          mixedEditorStackLayout(active), ContentEditorView, @[])
        check stackActiveItemIndexInRange(saved)

    # ---------------------------------------------------------------------
    # Case 3 — remapping, both when the active tab survives and when it does
    # not.
    # ---------------------------------------------------------------------
    test "sanitizer follows the active tab when it survives":
      ## `[CALLS, editor, NO SOURCE]`, active = 2 (NO SOURCE).  Both
      ## survivors are kept, so the active tab must still be NO SOURCE — at
      ## its new index 1.
      let layout = rowOf(@[stackOf(2, @[
        genericTab(ContentCalltraceEditor, cstring"CALLS"),
        editorTab(cstring"a.nim"),
        genericTab(ContentNoInfo, cstring"NO SOURCE")])])
      let saved = sanitizeLayoutConfig(layout, ContentEditorView, @[])
      let stack = firstStack(saved)

      check contentIds(stack) == @[ContentCalltraceEditor, ContentNoInfo]
      check stack["activeItemIndex"].to(int) == 1
      check contentIds(stack)[stack["activeItemIndex"].to(int)] ==
        ContentNoInfo

    test "sanitizer falls on the next surviving tab when the active one is stripped":
      ## `[CALLS, editor(active), NO SOURCE]` — the active editor tab is
      ## removed, so the selection moves to the nearest survivor on its
      ## right, the way a tab strip behaves when you close the active tab.
      let layout = rowOf(@[stackOf(1, @[
        genericTab(ContentCalltraceEditor, cstring"CALLS"),
        editorTab(cstring"a.nim"),
        genericTab(ContentNoInfo, cstring"NO SOURCE")])])
      let saved = sanitizeLayoutConfig(layout, ContentEditorView, @[])
      let stack = firstStack(saved)

      check contentIds(stack) == @[ContentCalltraceEditor, ContentNoInfo]
      check stack["activeItemIndex"].to(int) == 1
      check contentIds(stack)[stack["activeItemIndex"].to(int)] ==
        ContentNoInfo

    test "sanitizer clamps when every tab to the right is stripped":
      ## `[CALLS, editor, editor(active)]` — nothing survives to the right
      ## of the active tab, so the index must be clamped rather than left
      ## pointing past the end.
      let layout = rowOf(@[stackOf(2, @[
        genericTab(ContentCalltraceEditor, cstring"CALLS"),
        editorTab(cstring"a.nim"),
        editorTab(cstring"b.nim")])])
      let saved = sanitizeLayoutConfig(layout, ContentEditorView, @[])
      let stack = firstStack(saved)

      check jsLen(stack["content"]) == 1
      check stack["activeItemIndex"].to(int) == 0

    test "sanitizer leaves an absent activeItemIndex absent":
      ## GoldenLayout defaults an absent `activeItemIndex` to 0, which is
      ## always in range for a non-empty stack.  Writing the key out anyway
      ## would grow every saved layout for no benefit.
      let layout = rowOf(@[stackOf(-1, @[
        editorTab(cstring"a.nim"),
        genericTab(ContentCalltraceEditor, cstring"CALLS")])])
      let saved = sanitizeLayoutConfig(layout, ContentEditorView, @[])
      let stack = firstStack(saved)

      check jsLen(stack["content"]) == 1
      check not jsHasOwn(stack, cstring"activeItemIndex")
      check stackActiveItemIndexInRange(saved)

    test "sanitizer drops edit-mode hidden panels and still remaps":
      ## Edit mode additionally strips the replay-only panels
      ## (``editModeHiddenContentIds``).  The same remap must apply.
      let layout = rowOf(@[stackOf(2, @[
        genericTab(ContentState, cstring"STATE"),
        editorTab(cstring"a.nim"),
        genericTab(ContentFilesystem, cstring"FILES")])])
      let saved = sanitizeLayoutConfig(
        layout, ContentEditorView, @[ContentState])
      let stack = firstStack(saved)

      check contentIds(stack) == @[ContentFilesystem]
      check stack["activeItemIndex"].to(int) == 0

    test "sanitizing an already-sanitized layout is a no-op":
      ## The sanitizer runs on every save, so it must be idempotent — a
      ## drifting index would corrupt the file over successive sessions.
      let once = sanitizeLayoutConfig(
        mixedEditorStackLayout(2), ContentEditorView, @[])
      let twice = sanitizeLayoutConfig(clone(once), ContentEditorView, @[])
      check $jsonStringify(once) == $jsonStringify(twice)

    # ---------------------------------------------------------------------
    # Case 4 — a corrupt layout must be repaired, never fatal.
    # ---------------------------------------------------------------------
    test "repair clamps an out-of-range activeItemIndex":
      let broken = rowOf(@[stackOf(7, @[
        genericTab(ContentFilesystem, cstring"FILES"),
        genericTab(ContentEventLog, cstring"EVENTS")])])
      let repaired = repairLayoutConfig(broken)

      check repaired.ok
      check repaired.changed
      check repaired.issues.len > 0
      check stackActiveItemIndexInRange(repaired.config)
      check firstStack(repaired.config)["activeItemIndex"].to(int) == 1

    test "repair drops a component with an unregistered componentType":
      ## GoldenLayout falls through to `VirtualLayout.bindComponent` for an
      ## unknown type and CodeTracer's handler returns `undefined`, so
      ## destructuring `{component, virtual}` throws a TypeError.
      let broken = rowOf(@[stackOf(1, @[
        genericTab(ContentFilesystem, cstring"FILES"),
        component(ContentEventLog, cstring"EVENTS", cstring"ghostComponent")])])
      let repaired = repairLayoutConfig(broken)

      check repaired.ok
      check repaired.changed
      check contentIds(firstStack(repaired.config)) == @[ContentFilesystem]
      check firstStack(repaired.config)["activeItemIndex"].to(int) == 0

    test "repair drops a component with no componentState.content":
      let orphan = js{
        "type": cstring"component",
        "componentType": cstring"genericUiComponent",
        "componentState": js{"id": 0, "label": cstring"?"},
        "title": cstring"?"
      }
      let broken = rowOf(@[stackOf(0, @[
        genericTab(ContentFilesystem, cstring"FILES"), orphan])])
      let repaired = repairLayoutConfig(broken)

      check repaired.ok
      check contentIds(firstStack(repaired.config)) == @[ContentFilesystem]

    test "repair removes a size string with an unsupported unit":
      ## `ItemConfig.resolveSize` accepts only `%` and `fr`
      ## (golden-layout/src/ts/config/config.ts:168); `"300px"` makes
      ## `parseSize` throw a ConfigurationError during `loadLayout`.
      let stack = stackOf(0, @[genericTab(ContentFilesystem, cstring"FILES")])
      stack["size"] = cstring"300px".toJs
      stack["minSize"] = cstring"5%".toJs
      let repaired = repairLayoutConfig(rowOf(@[stack]))

      check repaired.ok
      check repaired.changed
      let repairedStack = firstStack(repaired.config)
      check not jsHasOwn(repairedStack, cstring"size")
      check not jsHasOwn(repairedStack, cstring"minSize")

    test "repair keeps size strings GoldenLayout accepts":
      ## Rejecting a size wrongly is worse than the bug being fixed: it
      ## silently resets a panel proportion on every load.  `RowOrColumn`
      ## recomputes sizes as `(size / total) * 100`
      ## (golden-layout/src/ts/items/row-or-column.ts:441), so real saved
      ## layouts are full of fractional percentages, and `fr` units are
      ## accepted alongside `%`.
      for (size, minSize) in @[
          (cstring"40%", cstring"120px"),
          (cstring"33.333333333333336%", cstring"0px"),
          (cstring"1fr", cstring"10px")]:
        let stack = stackOf(0, @[genericTab(ContentFilesystem, cstring"FILES")])
        stack["size"] = size.toJs
        stack["minSize"] = minSize.toJs
        let repaired = repairLayoutConfig(rowOf(@[stack]))

        check repaired.ok
        check not repaired.changed
        check $firstStack(repaired.config)["size"].to(cstring) == $size
        check $firstStack(repaired.config)["minSize"].to(cstring) == $minSize

    test "repair leaves the bundled default layout untouched":
      ## The shipped `src/config/default_layout.json` is the config every
      ## fallback path lands on.  If the repair ever "fixed" something in it,
      ## every launch would rewrite the user's file for no reason.
      const bundledJson = staticRead("../../../../config/default_layout.json")
      let repaired = repairLayoutConfig(jsonParse(cstring(bundledJson)))

      check repaired.ok
      check not repaired.changed
      check repaired.issues.len == 0
      check stackActiveItemIndexInRange(repaired.config)

    test "repair drops an empty stack and keeps the rest of the tree":
      let broken = rowOf(@[
        stackOf(0, @[]),
        stackOf(0, @[genericTab(ContentFilesystem, cstring"FILES")])])
      let repaired = repairLayoutConfig(broken)

      check repaired.ok
      check repaired.changed
      check jsLen(repaired.config["root"]["content"]) == 1
      check contentIds(firstStack(repaired.config)) == @[ContentFilesystem]

    test "repair drops a non-component child of a stack":
      ## `Stack.init` throws `Stack Content Item is not of type ComponentItem`
      ## (stack.ts:174-176) for a nested container inside a stack.
      let broken = rowOf(@[stackOf(0, @[
        genericTab(ContentFilesystem, cstring"FILES"),
        stackOf(0, @[genericTab(ContentEventLog, cstring"EVENTS")])])])
      let repaired = repairLayoutConfig(broken)

      check repaired.ok
      check repaired.changed
      check contentIds(firstStack(repaired.config)) == @[ContentFilesystem]

    test "repair reports a config with no root as unusable":
      check not repairLayoutConfig(js{"settings": js{}}).ok
      check not repairLayoutConfig(jsonParse(cstring"null")).ok
      check not repairLayoutConfig(js{"root": jsonParse(cstring"null")}).ok

    test "repair reports an entirely empty layout as unusable":
      check not repairLayoutConfig(rowOf(@[stackOf(0, @[])])).ok

    test "repair never raises on any of the corrupt shapes":
      ## The whole point of the load-side repair is that a bad file cannot
      ## abort startup.  A native JavaScript `Error` would escape a Nim
      ## `try/except`, so this asserts the repair itself is total.
      let shapes = @[
        rowOf(@[stackOf(7, @[genericTab(ContentFilesystem, cstring"FILES")])]),
        rowOf(@[stackOf(0, @[
          component(ContentEventLog, cstring"E", cstring"ghostComponent")])]),
        rowOf(@[stackOf(0, @[])]),
        js{"settings": js{}},
        jsonParse(cstring"""{"root":{"type":"row","content":"nope"}}"""),
        jsonParse(cstring"""{"root":{"content":[]}}"""),
        jsonParse(cstring"""{"root":{"type":"stack","content":[null]}}""")
      ]
      for shape in shapes:
        var raised = false
        try:
          discard repairLayoutConfig(shape)
        except CatchableError:
          raised = true
        check not raised

    test "an already-valid layout is returned unchanged":
      let good = rowOf(@[
        stackOf(0, @[genericTab(ContentFilesystem, cstring"FILES")]),
        stackOf(1, @[
          genericTab(ContentCalltraceEditor, cstring"CALLS"),
          genericTab(ContentEventLog, cstring"EVENTS")])])
      let before = $jsonStringify(good)
      let repaired = repairLayoutConfig(clone(good))

      check repaired.ok
      check not repaired.changed
      check $jsonStringify(repaired.config) == before

    # ---------------------------------------------------------------------
    # Case 5 — pinning the Filesystem panel must not invalidate the layout.
    # ---------------------------------------------------------------------
    test "a pinned Filesystem panel keeps the layout valid":
      ## `pinPanel` removes the component from the GoldenLayout tree, so the
      ## saved config genuinely no longer contains `Content.Filesystem`.
      ## The validator has to consult the auto-hide state as well —
      ## otherwise it declares the layout incompatible and the loader
      ## DELETES the user's file, which is the "customizations lost with no
      ## visible error" half of the report.
      let pinnedAway = rowOf(@[
        stackOf(0, @[genericTab(ContentEventLog, cstring"EVENTS")])])
      let autoHide = jsonParse(cstring"""
        {"panels":[{"edge":1,"title":"FILES","content":9,"componentId":0,
                    "overlayWidth":320,"overlayHeight":0,
                    "config":{"type":"component",
                              "componentType":"genericUiComponent",
                              "componentState":{"id":0,"label":"filesystemComponent-0",
                                                "content":9}}}]}""")

      check not layoutContainsContentId(pinnedAway, ContentFilesystem)
      check autoHideStateContainsContentId(autoHide, ContentFilesystem)
      check layoutHasRequiredPanel(pinnedAway, autoHide, ContentFilesystem)

    test "a missing Filesystem panel with no auto-hide state is still invalid":
      let broken = rowOf(@[
        stackOf(0, @[genericTab(ContentEventLog, cstring"EVENTS")])])
      check not layoutHasRequiredPanel(
        broken, jsonParse(cstring"null"), ContentFilesystem)
      check not layoutHasRequiredPanel(
        broken, jsonParse(cstring"""{"panels":[]}"""), ContentFilesystem)

    test "an in-tree Filesystem panel is valid with no auto-hide state":
      let good = rowOf(@[
        stackOf(0, @[genericTab(ContentFilesystem, cstring"FILES")])])
      check layoutHasRequiredPanel(
        good, jsonParse(cstring"null"), ContentFilesystem)

    # ---------------------------------------------------------------------
    # Case 1 — the auto-hide state survives a save/load round trip.
    # ---------------------------------------------------------------------
    test "auto-hide state round-trips through JSON without live DOM handles":
      ## `serializeAutoHideState` must emit exactly the persistable fields.
      ## `domTab`, `liveElement` and `containerElement` are live DOM nodes:
      ## `JSON.stringify` would either drop them or (for a cyclic DOM tree)
      ## throw, and `isUnpinning` is a transient of the unpin animation.
      let serialized = jsonParse(cstring"""
        {"panels":[
          {"edge":1,"title":"FILES","content":9,"componentId":0,
           "overlayWidth":320,"overlayHeight":0,
           "config":{"type":"component","componentType":"genericUiComponent",
                     "componentState":{"id":0,"label":"filesystemComponent-0",
                                       "content":9,"isEditor":false}}},
          {"edge":0,"title":"BUILD","content":11,"componentId":0,
           "overlayWidth":0,"overlayHeight":240,
           "config":{"type":"component","componentType":"genericUiComponent",
                     "componentState":{"id":0,"label":"buildComponent-0",
                                       "content":11,"isEditor":false}}}]}""")
      let restored = jsonParse(jsonStringify(serialized))

      check jsLen(restored["panels"]) == 2
      for i in 0 ..< jsLen(restored["panels"]):
        let before = serialized["panels"][i]
        let after = restored["panels"][i]
        check after["edge"].to(int) == before["edge"].to(int)
        check $after["title"].to(cstring) == $before["title"].to(cstring)
        check after["content"].to(int) == before["content"].to(int)
        check after["componentId"].to(int) == before["componentId"].to(int)
        check after["overlayWidth"].to(int) == before["overlayWidth"].to(int)
        check after["overlayHeight"].to(int) == before["overlayHeight"].to(int)
        check $jsonStringify(after["config"]["componentState"]) ==
          $jsonStringify(before["config"]["componentState"])
        # Transients and live DOM handles must not be persisted.
        check not jsHasOwn(after, cstring"isUnpinning")
        check not jsHasOwn(after, cstring"liveElement")
        check not jsHasOwn(after, cstring"domTab")
        check not jsHasOwn(after, cstring"containerElement")

    test "a restored auto-hide panel keeps enough config to be re-attached":
      ## The restored panel has no `liveElement`, so re-attaching it relies
      ## entirely on the persisted GoldenLayout component config.
      let restored = jsonParse(cstring"""
        {"panels":[{"edge":2,"title":"STATE","content":4,"componentId":0,
                    "overlayWidth":420,"overlayHeight":0,
                    "config":{"type":"component",
                              "componentType":"genericUiComponent",
                              "componentState":{"id":0,"label":"stateComponent-0",
                                                "content":4}}}]}""")
      let panel = restored["panels"][0]
      check $panel["config"]["componentType"].to(cstring) ==
        "genericUiComponent"
      check panel["config"]["componentState"]["content"].to(int) ==
        panel["content"].to(int)
      check autoHideStateContainsContentId(restored, 4)

else:
  import std/strutils

  const
    RepairPath = "src/frontend/index/layout_config_repair.nim"
    IndexConfigPath = "src/frontend/index/config.nim"
    IndexWindowPath = "src/frontend/index/window.nim"
    IndexIpcPath = "src/frontend/index/ipc_utils.nim"
    LayoutPath = "src/frontend/ui/layout.nim"
    AutoHidePath = "src/frontend/ui/auto_hide.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: it means the production
    ## file this contract describes was moved or deleted.
    readFile(path)

  suite "#608 layout config persistence (source contract)":

    test "the repair module stays dependency-free":
      ## The whole reason this module exists is that the invariants can be
      ## tested headlessly.  An import of electron_vars / files / types
      ## would drag in the Node and DOM world and silently kill the JS-side
      ## behavioural suite above.
      let body = source(RepairPath)
      check body.contains("import std/jsffi")
      check not body.contains("electron_vars")
      for forbidden in ["./files", "../types", "electron_lib", "ct_logging"]:
        check not body.contains(forbidden)

    test "the sanitizer remaps activeItemIndex":
      let body = source(RepairPath)
      check body.contains("remapActiveItemIndex")
      check body.contains("survivors.indexOf(base)")
      check body.contains("survivors.filter((index) => index < base).length")
      check body.contains("if (mapped > count - 1) mapped = count - 1;")

    test "index/config.nim routes save and load through the repair module":
      let body = source(IndexConfigPath)
      check body.contains("layout_config_repair")
      check body.contains("sanitizeLayoutConfig(")
      check body.contains("repairLayoutConfig(")
      # The load path must rewrite the file after a repair, otherwise the
      # same broken config is re-repaired on every single launch.
      check body.contains("fsWriteFileWithErr")

    test "the Filesystem requirement is auto-hide aware":
      ## Pinning FILES removes the component from the GoldenLayout tree.
      ## Without this the loader treats the layout as incompatible and
      ## deletes the user's file.
      let body = source(IndexConfigPath)
      check body.contains("layoutHasRequiredPanel")
      check body.contains("autoHideStateContainsContentId") or
        body.contains("loadAutoHideState")

    test "the auto-hide state has a handler and a persisted file":
      ## Before the fix `CODETRACER::save-auto-hide-state` was sent by
      ## `ui/layout.nim` and handled by nobody: the string occurred at
      ## exactly one site in the whole repository, the send.
      let window = source(IndexWindowPath)
      let ipc = source(IndexIpcPath)
      check window.contains("proc onSaveAutoHideState*")
      check window.contains("proc onRequestAutoHideState*")
      check window.contains("auto_hide_state.json")
      check ipc.contains("\"save-auto-hide-state\"")
      check ipc.contains("\"request-auto-hide-state\"")

    test "restoreAutoHideState is actually called":
      ## It had zero call sites, which is why pinned panels never survived
      ## a restart.
      let body = source(LayoutPath)
      check body.contains("restoreAutoHideState(")
      let restoreIndex = body.find("restoreAutoHideState(")
      let standaloneIndex = body.find("500)  # 500ms delay")
      check restoreIndex >= 0
      check standaloneIndex >= 0
      # The restore must land BEFORE the standalone-panel registration loop,
      # whose `findPanelByContent` skip is what stops a restored panel from
      # being duplicated as a standalone one.
      check restoreIndex < standaloneIndex

    test "the serialized auto-hide state carries the overlay geometry":
      let body = source(AutoHidePath)
      let start = body.find("proc serializeAutoHideState*")
      check start >= 0
      let stop = body.find("proc restoreAutoHideState*", start)
      check stop > start
      let serializer = body[start ..< stop]
      check serializer.contains("overlayWidth")
      check serializer.contains("overlayHeight")
      # A panel mid-unpin is a transient; persisting it would resurrect a
      # panel the user just dragged back into the layout.  A standalone pane
      # (BUILD / PROBLEMS / SEARCH RESULTS / REQUESTS) is re-registered from
      # scratch every launch and has no GL config to re-attach from, so a
      # persisted copy would only suppress that registration and leave a
      # strip tab whose overlay is empty.
      check serializer.contains("panel.isUnpinning or panel.standalone")
      for forbidden in ["liveElement", "domTab", "containerElement"]:
        check not serializer.contains("\"" & forbidden & "\"")

    test "standalone auto-hide panes are marked as such":
      let body = source(AutoHidePath)
      check body.contains("standalone*: bool")
      let start = body.find("proc addStandaloneAutoHidePanel*")
      check start >= 0
      let stop = body.find("type", start)
      check stop > start
      check body[start ..< stop].contains("standalone: true")

    test "a restored entry never shadows a standalone pane":
      ## The standalone registration loop skips a content that is already in
      ## the auto-hide state.  A restored entry for one of the four
      ## standalone panes has no live element and nothing to build one from,
      ## so it must be replaced rather than honoured.
      let body = source(LayoutPath)
      check body.contains("existing.standalone or not existing.liveElement.isNil")

    test "layout application is guarded against native GoldenLayout errors":
      ## A Nim `try/except` does NOT catch a native JS `Error`; the proven
      ## pattern is the raw-JS try/catch in `ui/session_switch.nim`.
      let body = source(LayoutPath)
      let start = body.find("proc initLayout*")
      check start >= 0
      let region = body[start .. min(start + 40_000, body.high)]
      check region.contains("loadLayoutSafely")
      check body.contains("{.emit:") and body.contains("catch (e)")
