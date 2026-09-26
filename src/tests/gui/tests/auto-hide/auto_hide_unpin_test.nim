## Headless cover for Unpin on an auto-hide strip tab — issue #692 (M46).
##
## The report: the four panes CodeTracer pins to the bottom strip on every
## startup — BUILD, PROBLEMS, FIND IN FILES, REQUESTS — offer an Unpin action
## in their tab context menu that does nothing at all.  The reporter expects
## unpinning to turn them into ordinary dockable panels, the way CALLTRACE /
## STATE / TERMINAL / EVENT LOG behave.
##
## Spec grounding
## --------------
## `codetracer-specs/Planned-Features/Auto-Hide-Panes.md` §3.2:
## "**Right-click**: opens the tab context menu (re-pin to another edge,
## Unpin). This is the only unpin/close affordance a strip tab has."  The
## sentence is unconditional — there is no carve-out for these four — so the
## fix is to make Unpin work, not to hide it.
##
## What is asserted where, and why it is split
## -------------------------------------------
## * **JS backend, suite 1** — the config helper, against the real production
##   functions in `src/frontend/ui/auto_hide_panel_config.nim`.
## * **JS backend, suite 2** — `unpinPanel` ITSELF, run.  See that suite's own
##   header for what it does and does not cover; the short version is that the
##   shipped proc is called on the shipped `autoHideState`, and the outcome is
##   read back through `bottomStripModel()`, the proc the bottom strip renders
##   from.  GoldenLayout and `layout.nim`'s component registration are stood in
##   for, and are not covered.
## * **Native backend** — a source contract over `auto_hide.nim` and
##   `layout.nim`, the two call sites the extracted rule has to be reached
##   from.  A correct helper that nothing calls is the failure mode this half
##   exists to catch, and it is the same pattern
##   `layout/layout_config_roundtrip_test.nim` uses for the persistence
##   invariants of the same two files.
##
## One mock, justified where it is used (workspace policy): the GoldenLayout
## stand-in in suite 2.  Everything else calls the shipped procs, and the
## native half reads the shipped sources off disk.
##
## Red-before-green-after, and WHICH HALVES CARRY IT
## -------------------------------------------------
## Both the source-contract suite and suite 2 fail against the tree as it was
## before M46 (`e96d65a0a`), where `addStandaloneAutoHidePanel` stored
## `config: js{}` and `unpinPanel` handed that empty object straight to
## GoldenLayout.  Measured at `b98719133` with the pre-M46
## `addStandaloneAutoHidePanel` config line and the whole pre-M46 `unpinPanel`
## body restored verbatim: **five of suite 2's eight cases fail, exit 1.**
##
## **The nine cases in suite 1 do not, and that is why suite 2 exists.**
## Dropped into the pre-M46 tree with `auto_hide_panel_config.nim` as their
## only addition — `auto_hide.nim` and `layout.nim` still entirely unfixed —
## all nine pass. They are real behavioural assertions against the real procs,
## but their subject is the new module alone, so their whole red-before is
## "the file did not exist".
##
## Known residual, `Testing/Verification-Harness-Traps.md` §35b
## ------------------------------------------------------------
## The source-contract cases compare SUBSTRINGS, and Nim's identifier equality
## is not string equality: `is_Editor` and `isEditor` are one identifier and
## two strings. Five of the six cases are wrong only in the safe direction — a
## respelled needle makes them fail, not pass. The sixth, *the unpin target
## does not dereference a state it never checked*, is a negative, so
## `panel.config.componentState.is_Editor` would satisfy it. Closing that
## needs a token-level normaliser (`nimIdentKey` / `identifierKeys` in §35b),
## and no shared one exists in this tree yet; re-deriving a private copy here
## is what §30a forbids. So it is written down rather than papered over, and
## the rule that actually guards the defect at runtime is `unpinPanel`'s
## `isReattachableConfig` call, covered by its own case.

import std/unittest

when defined(js):
  import std/jsffi
  import ../../../../frontend/ui/auto_hide_panel_config

  # `Content` ordinals, mirrored as literals so the test keeps the
  # dependency-free property of the module under test.  Source of truth:
  # `src/common/common_types/codetracer_features/frontend.nim`.
  const
    ContentBuild = 11
    ContentBuildErrors = 21
    ContentRequestPanel = 40
    ContentState = 4

  proc jsonStringify(value: JsObject): cstring {.importjs: "JSON.stringify(#)".}
  proc jsonParse(raw: cstring): JsObject {.importjs: "JSON.parse(#)".}

  suite "#692 standalone auto-hide panes carry a re-attachable config":

    test "an empty object is NOT something GoldenLayout can rebuild":
      ## This is the defect itself.  `addStandaloneAutoHidePanel` stored
      ## `js{}` and `unpinPanel` passed it to `addItem`, which has no
      ## component type to construct from — so nothing was added and the
      ## Unpin gesture was a no-op.
      check not isReattachableConfig(js{})

    test "neither is a config GoldenLayout cannot even be asked about":
      # `jsUndefined` / `jsNull` are `std/jsffi`'s own bindings for the two
      # values a config field can hold when nothing ever wrote it.
      check not isReattachableConfig(jsUndefined)
      check not isReattachableConfig(jsNull)

    test "a standalone pane's config names a component and a mount label":
      let config = standaloneComponentConfig(
        cstring"errorsComponent-0", ContentBuildErrors, 0)
      check $config["type"].to(cstring) == "component"
      check $config["componentName"].to(cstring) == "genericUiComponent"
      check $config["componentState"]["label"].to(cstring) ==
        "errorsComponent-0"
      check config["componentState"]["content"].to(int) == ContentBuildErrors
      check config["componentState"]["id"].to(int) == 0
      # `unpinPanelTarget` used to read this field on its very first line,
      # which is why an absent `componentState` threw a native `TypeError`
      # before `addItem` was ever reached.
      check not config["componentState"]["isEditor"].to(bool)

    test "and it IS something GoldenLayout can rebuild":
      check isReattachableConfig(
        standaloneComponentConfig(cstring"buildComponent-0", ContentBuild, 0))

    test "the config survives the JSON round-trip persistence uses":
      let raw = jsonStringify(
        standaloneComponentConfig(
          cstring"requestPanelComponent-0", ContentRequestPanel, 0))
      check isReattachableConfig(jsonParse(raw))

    test "a component type with no mount label is refused":
      ## `genericUiComponent`'s registration returns immediately when
      ## `state.label.len == 0`, so such a config produces an EMPTY GL
      ## container rather than nothing at all — a worse outcome than the
      ## no-op, because it looks like it worked.
      check not isReattachableConfig(js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{"id": 0, "content": ContentBuild}
      })
      check not isReattachableConfig(js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{"id": 0, "label": cstring"",
                             "content": ContentBuild}
      })

    test "a config with no component type at all is refused":
      check not isReattachableConfig(js{
        "type": cstring"component",
        "componentState": js{"label": cstring"buildComponent-0"}
      })

    test "a pinned panel's own config is accepted unchanged":
      ## `pinPanel` builds this shape from a live GoldenLayout item; the four
      ## panes CALLTRACE / STATE / TERMINAL / EVENT LOG reach `unpinPanel`
      ## with it, and they are the ones that already work.  The guard must
      ## not start refusing them.
      check isReattachableConfig(js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{
          "id": 0, "label": cstring"calltraceComponent-0",
          "content": ContentState, "isEditor": false
        }
      })

    test "a RESOLVED config restored from disk is accepted too":
      ## `auto_hide_state.json` stores GoldenLayout's resolved form, which
      ## spells the component `componentType` rather than `componentName` —
      ## see `layout/layout_config_roundtrip_test.nim`'s restore case.
      check isReattachableConfig(jsonParse(cstring"""
        {"componentType":"genericUiComponent",
         "componentState":{"id":0,"label":"stateComponent-0","content":4}}"""))

  # =========================================================================
  # THE UNPIN ITSELF.  `unpinPanel`, run.
  # =========================================================================
  #
  # WHAT THIS SUITE IS AND WHY IT EXISTS
  # ------------------------------------
  # Everything above this line tests the config helper and the source wiring.
  # The milestone shipped saying, in as many words, that *no test anywhere
  # exercised `unpinPanel`* and that the end-to-end claim rested on reading
  # the code.  This suite is that measurement: it calls the shipped
  # `auto_hide.unpinPanel` and asserts on the state the strip renders from.
  #
  # It is possible at all because of a fact the milestone assumed the other
  # way round: **`src/frontend/ui/auto_hide.nim` DOES compile under
  # `nim js -d:nodejs --path:src/frontend/viewmodel`**, the exact command the
  # `vm-js` lane runs (measured at `b98719133`, exit 0).  The note in
  # `ci/lib/test-lane-files.sh` about the renderer not building under
  # `-d:nodejs` is real, but narrower than it sounds: the same probe over
  # `frontend/renderer` dies at
  # `src/frontend/utils.nim(60, 16) Error: undeclared identifier:
  # 'createElementNS'` — `std/dom`'s, absent under the define.  `auto_hide.nim`
  # imports `kdom` but never reaches `utils.nim`.  So the seam does not have to
  # be extracted — the production proc can simply be called.
  #
  # WHAT IS COVERED, AND WHAT IS NOT.  Read this before quoting the suite.
  # ---------------------------------------------------------------------
  # COVERED — the real `unpinPanel`, on the real `autoHideState`, over a
  # panel registered by the real `addStandaloneAutoHidePanel`:
  #   * that the pane leaves the strip, asserted through `bottomStripModel()`
  #     — the production proc `requestAutoHideBottomStripRender` renders the
  #     bottom strip from, not a field read;
  #   * that a re-attachable config reaches GoldenLayout's `addItem`, carrying
  #     the component name, the mount label and the `isReparenting` handshake
  #     `unpinPanel`'s `{.emit.}` sets;
  #   * that `panel.isUnpinning` is never left latched — on refusal, on a
  #     re-attach that silently adds nothing, and on one that raises.
  #
  # NOT COVERED, and no claim is made about it:
  #   * GoldenLayout itself.  It is a browser library; there is no DOM here.
  #     `fakeLayout` below stands in for it.
  #   * `layout.nim`'s `genericUiComponent` registration.  It is a closure
  #     built inside `initLayout`, which needs a document, a `data` graph and
  #     a live GL instance; it cannot be reached headlessly.  `fakeLayout`'s
  #     component factory stands in for it too.
  #   * The DOM reparenting — moving the live element's children into the new
  #     GL container — which is entirely inside that registration.
  #   * `auto_hide.unpinPanelTarget`.  In the shipped product `initLayout`
  #     installs a closure there (`layout.nim`, `auto_hide.unpinPanelTarget =
  #     proc(...)`) and THAT is what calls
  #     `addItem`, choosing the insertion index from `panel.edge`.  It cannot
  #     be installed headlessly for the same reason the registration cannot, so
  #     the var is nil here and `unpinPanel` takes its own fallback branch.
  #     Everything this suite asserts sits either side of that call — the
  #     refusal that happens before it, the flag reset that happens after it,
  #     and the CONFIG handed across it, which is byte-identical on both
  #     branches (`discard target.addItem(panel.config)`).  The edge-dependent
  #     index the closure picks is not covered.
  #   * Anything about what the user sees.  That is the Playwright case the
  #     milestone describes, and it is still not written.
  #
  # THE TEST DOUBLE, AND WHY IT IS ONE (workspace policy: every mock is
  # justified where it is used)
  # -------------------------------------------------------------------
  # `fakeLayout` is a GoldenLayout stand-in with a component registry.  It is
  # a double because the real one is a third-party browser library that needs
  # a document; there is no version of this test that uses the real one and
  # still runs in a lane.  It is deliberately built to model the boundary as
  # the root-cause analysis describes it, and no more.
  #
  # The `layout.nim:NNNN` citations below were re-read at `f940ae392`.  They
  # rot FAST — three others in this file drifted by four and five lines within
  # a day, on a rebase that changed nothing about auto-hide — so the SYMBOL
  # each one names is the reference, and the number only shortens the search.
  # Anywhere a symbol alone was unambiguous, the number has been dropped.
  #
  #   * `addItem(config)` looks `config.componentName` up in a registry.  A
  #     name that is not registered constructs nothing, adds nothing, and
  #     DOES NOT RAISE — that last clause is issue #692's whole mechanism and
  #     the reason the pre-fix `except`-only reset never fired.
  #   * the registered factory reproduces exactly the two decisions
  #     `layout.nim:1866-1900` makes and nothing else: return on an empty
  #     `state.label`, and — when the panel resolves and the reparenting flag
  #     is set — drop it from `autoHideState.panels`.
  #   * it resolves the panel with the REAL `findPanelByContentAndId`, the
  #     same production proc `layout.nim` calls.  That is the load-bearing
  #     half: a config whose `content`/`id` do not lead back to the panel
  #     fails here for the same reason it would fail in the renderer.
  #
  # It deliberately does NOT re-implement `isReattachableConfig`.  Asking a
  # second copy of the predicate under test whether the config is good is
  # `Verification-Harness-Traps.md` §30 exactly; the registry lookup answers
  # a different question (is this component name known?) and the assertions
  # below read the handed config's FIELDS rather than running it back through
  # the production predicate, so no arm here is decided by the code it is
  # testing.

  import std/sequtils
  import kdom
  import ../../../../frontend/types
  import ../../../../frontend/ui/auto_hide

  # `unpinPanel` ends in `dispatchLayoutUpdated()`, which is
  # `window.dispatchEvent(new CustomEvent(...))`.  node has no `window`.
  # This is a host shim, not a stub of anything under test: without it the
  # proc under test dies on its last line for a reason that has nothing to do
  # with unpinning.
  {.emit: """
  if (typeof globalThis.window === 'undefined') {
    globalThis.window = { dispatchEvent: function () { return true; } };
  }
  if (typeof globalThis.CustomEvent === 'undefined') {
    globalThis.CustomEvent = function (name) { this.type = name; };
  }
  """.}

  # Undefined-safe field reads.  `handed["componentState"]["label"]` on an
  # empty config is a native TypeError, and a test that dies on its own
  # subject reports nothing useful.
  proc jsStringField(obj: JsObject, key: cstring): cstring {.importjs: """
  (function (o, k) {
    if (!o || typeof o !== 'object') return '';
    var v = o[k];
    return (typeof v === 'string') ? v : '';
  })(#, #)""".}

  proc jsField(obj: JsObject, key: cstring): JsObject {.importjs: """
  (function (o, k) {
    if (!o || typeof o !== 'object') return undefined;
    return o[k];
  })(#, #)""".}

  proc jsIsTrue(value: JsObject): bool {.importjs: "(# === true)".}

  proc jsIntField(obj: JsObject, key: cstring): int {.importjs: """
  (function (o, k) {
    if (!o || typeof o !== 'object') return -1;
    var v = o[k];
    return (typeof v === 'number') ? v : -1;
  })(#, #)""".}

  type UnpinObservation = object
    ## Everything the GoldenLayout stand-in saw, so the assertions read one
    ## recorded fact each instead of re-deriving them.
    addItemCalls: int
    handedConfig: JsObject
    factoryInvocations: int
    labelSeen: cstring
    reparentFlagSeen: bool
    panelResolvedByLookup: bool

  var observed: UnpinObservation

  proc stubLiveElement(): Element =
    ## `layout.nim`'s reparenting branch requires `panel.liveElement` to be
    ## non-nil.  An opaque object is enough: nothing here touches its children
    ## (the DOM move is the part this suite does not cover).
    cast[Element](js{"__ctTestStubElement": true})

  proc genericUiComponentStandIn(state: JsObject) =
    ## The two decisions `layout.nim:1866-1900` makes, and no others.
    let label = jsStringField(state, cstring"label")
    if label.len == 0:
      # layout.nim:1867-1868 — `if state.label.len == 0: return`.  A config
      # with a component type but no label leaves an EMPTY container behind.
      return
    observed.factoryInvocations.inc
    observed.labelSeen = label
    let panel = autoHideState.findPanelByContentAndId(
      Content(jsIntField(state, cstring"content")),
      jsIntField(state, cstring"id"))
    observed.panelResolvedByLookup = not panel.isNil
    # layout.nim:1873 reads `(data.ui.isReparenting or state.isReparenting)`.
    # Only the second disjunct is modelled: `data.ui` is behind
    # `when defined(ctRenderer)`, which no lane defines, so the first is never
    # set here — and it is `state.isReparenting`, written by `unpinPanel`'s
    # own `{.emit.}`, that this suite is trying to observe.
    let isReparenting = not panel.isNil and not panel.liveElement.isNil and
      jsIsTrue(jsField(state, cstring"isReparenting"))
    observed.reparentFlagSeen = isReparenting
    if isReparenting:
      # layout.nim:1893 — the pane stops being an auto-hide panel.
      autoHideState.panels = autoHideState.panels.filterIt(it != panel)
      if not autoHideState.onChanged.isNil:
        autoHideState.onChanged()

  proc fakeLayout(registeredComponent: cstring): GoldenLayout =
    ## A GoldenLayout whose registry holds exactly `registeredComponent`.
    ## Pass `""` for a layout that can construct nothing — the shape that
    ## makes `addItem` add nothing without raising.
    let stack = GoldenContentItem(
      contentItems: @[],
      addItem: proc(itemConfig: js, index: int = 0): int =
        let config = cast[JsObject](itemConfig)
        observed.addItemCalls.inc
        observed.handedConfig = config
        let name = jsStringField(config, cstring"componentName")
        if name.len == 0 or name != registeredComponent:
          # Nothing registered under that name: GoldenLayout builds nothing,
          # adds nothing, and returns quietly.  #692's mechanism.
          return 0
        genericUiComponentStandIn(jsField(config, cstring"componentState"))
        return 0
    )
    GoldenLayout(groundItem: GoldenContentItem(contentItems: @[stack]))

  proc layoutWithNoGround(): GoldenLayout =
    ## `unpinPanel`'s explicit "no ground item" raise, so the raising exit is
    ## exercised too and not only the quiet one.
    GoldenLayout(groundItem: nil)

  proc freshAutoHideWorld() =
    ## `autoHideState` is module-level, and `initAutoHideState` is a no-op on
    ## a non-nil state, so every case starts from a torn-down one.
    autoHideState = nil
    initAutoHideState()
    # `labelSeen` is initialised to the empty string rather than left nil:
    # `$`-ing a nil `cstring` on the JS backend is `null.length`, an unhandled
    # exception that ABORTS the case at the first failing assertion and takes
    # every assertion after it with it.  `Verification-Harness-Traps.md` §33 —
    # an arm that dies upstream of its own subject reports nothing.
    observed = UnpinObservation(handedConfig: nil, labelSeen: cstring"")

  proc registerBuildPane(): AutoHidePanel =
    ## The real production registration, with the real arguments `layout.nim`'s
    ## only `addStandaloneAutoHidePanel` call passes for BUILD — it reads them
    ## off the `standaloneAutoHidePanels` table just above itself.
    addStandaloneAutoHidePanel(
      cstring"BUILD", Content.Build, 0, stubLiveElement(),
      componentLabel = cstring"buildComponent-0", edge = AutoHideEdge.Bottom)
    doAssert autoHideState.panels.len == 1
    autoHideState.panels[0]

  proc stripTitles(): seq[string] =
    ## What the bottom strip would render, through the production proc
    ## `requestAutoHideBottomStripRender` reads.
    bottomStripModel().mapIt($it.title)

  suite "#692 unpinPanel, run":

    test "the mirrored Content ordinals still match the enum":
      ## The suite above hardcodes these so it can stay dependency-free.  Now
      ## that this file imports `types` anyway, the mirror can be checked
      ## instead of trusted — a renumbered `Content` would otherwise make
      ## those nine cases quietly describe the wrong panes.
      check ord(Content.Build) == ContentBuild
      check ord(Content.BuildErrors) == ContentBuildErrors
      check ord(Content.RequestPanel) == ContentRequestPanel
      check ord(Content.State) == ContentState

    test "unpinning BUILD takes it out of the strip and hands GL its config":
      ## The reporter's ask, measured.  Before M46 this pane's stored config
      ## was `js{}`; `addItem` had nothing to construct, nothing was added,
      ## and the pane stayed in the strip forever.
      freshAutoHideWorld()
      let panel = registerBuildPane()

      # POSITIVE CONTROL (`Verification-Harness-Traps.md` §4): the pane is in
      # the strip BEFORE the unpin, so "gone afterwards" cannot pass by the
      # strip having been empty all along.
      check stripTitles() == @["BUILD"]

      unpinPanel(fakeLayout(cstring"genericUiComponent"), panel)

      # 1. The config reached the layout, and it is one GL can build from.
      check observed.addItemCalls == 1
      check observed.handedConfig == cast[JsObject](panel.config)
      check $jsStringField(observed.handedConfig, cstring"type") == "component"
      check $jsStringField(observed.handedConfig, cstring"componentName") ==
        "genericUiComponent"
      let state = jsField(observed.handedConfig, cstring"componentState")
      check $jsStringField(state, cstring"label") == "buildComponent-0"
      check jsIntField(state, cstring"content") == ord(Content.Build)
      check jsIntField(state, cstring"id") == 0

      # 2. The reparenting handshake `unpinPanel`'s `{.emit.}` performs was
      #    visible to the component registration when it ran — the thing that
      #    could not happen while `componentState` did not exist.
      check observed.factoryInvocations == 1
      check $observed.labelSeen == "buildComponent-0"
      check observed.panelResolvedByLookup
      check observed.reparentFlagSeen

      # 3. And the pane is gone from the auto-hide strip — REMOVED, not
      #    merely HIDDEN, and that distinction is load-bearing.
      #
      #    `bottomStripModel` filters on `not it.isUnpinning`, so THE PRE-FIX
      #    DEFECT SATISFIES "gone from the strip" ALL BY ITSELF: the panel
      #    latched mid-unpin disappears from the strip while still sitting in
      #    `autoHideState.panels` with no GL panel anywhere — the invisible,
      #    unreachable state.  Measured, not reasoned: with the pre-M46
      #    `unpinPanel` restored, `stripTitles()` here is `@[]` and the case
      #    fails only on the assertions above and the two below.
      #    `Verification-Harness-Traps.md` §7 — a green fixture that is an
      #    instance of the defect it exists to catch.
      #
      #    So the assertion that DISCRIMINATES is `panels.len == 0`, and it is
      #    the one to keep if this case is ever trimmed.  Note what cannot be
      #    asserted here: `panel.isUnpinning` is deliberately still `true` on
      #    a SUCCESSFUL unpin — `unpinPanel`'s `finally` clears it only when
      #    the panel is still registered, because a panel that is no longer in
      #    `panels` is unreachable and its flag can no longer hide anything.
      #    That was measured, not assumed: asserting `not panel.isUnpinning`
      #    here failed on the fixed tree.  The flag's real contract is the
      #    three cases below, where the re-attach did NOT happen.
      check stripTitles() == newSeq[string]()
      check autoHideState.panels.len == 0
      check autoHideState.findPanelByContentAndId(Content.Build, 0).isNil

    test "so do the other three panes #692 named":
      ## PROBLEMS is the one that proves the label is not derivable from the
      ## content: `Content.BuildErrors` mounts into `errorsComponent-0`.
      ## Table copied from `layout.nim`'s `standaloneAutoHidePanels`.
      const panes = [
        (Content.Build, cstring"BUILD", cstring"buildComponent-0"),
        (Content.BuildErrors, cstring"PROBLEMS", cstring"errorsComponent-0"),
        (Content.SearchResults, cstring"FIND IN FILES",
         cstring"searchResultsComponent-0"),
        (Content.RequestPanel, cstring"REQUESTS",
         cstring"requestPanelComponent-0")
      ]
      for pane in panes:
        freshAutoHideWorld()
        addStandaloneAutoHidePanel(
          pane[1], pane[0], 0, stubLiveElement(),
          componentLabel = pane[2], edge = AutoHideEdge.Bottom)
        check stripTitles() == @[$pane[1]]
        unpinPanel(fakeLayout(cstring"genericUiComponent"),
                   autoHideState.panels[0])
        check observed.addItemCalls == 1
        check $jsStringField(
          jsField(observed.handedConfig, cstring"componentState"),
          cstring"label") == $pane[2]
        check observed.factoryInvocations == 1
        # The first of these two is ALSO satisfied by the pre-fix defect and
        # is kept only as a reading aid; the second is what discriminates.
        # See the long note in the case above.
        check stripTitles() == newSeq[string]()
        check autoHideState.panels.len == 0

    test "an unpin that adds nothing puts the pane back, not into limbo":
      ## The second, independent defect.  `isUnpinning` hides the strip tab
      ## (`panelsForEdge`) AND drops the panel from `serializeAutoHideState`,
      ## so a panel left latched is absent from the strip and absent from the
      ## layout — unreachable until the next restart.  The reset used to live
      ## in the `except` arm alone, and `addItem` adding nothing is not a
      ## raise.
      freshAutoHideWorld()
      let panel = registerBuildPane()

      # A layout with an empty component registry: the config is fine, the
      # call happens, and nothing is constructed from it.
      unpinPanel(fakeLayout(cstring""), panel)

      # POSITIVE CONTROL: the re-attach was genuinely ATTEMPTED.  Without
      # this, the assertions below are also satisfied by an unpin that
      # returned before doing anything.
      check observed.addItemCalls == 1
      check observed.factoryInvocations == 0

      check not panel.isUnpinning
      check stripTitles() == @["BUILD"]

    test "nor does an unpin that raises":
      ## The path that already worked before M46 — `except` caught it — kept
      ## as a regression guard now that the reset moved to `finally`.
      freshAutoHideWorld()
      let panel = registerBuildPane()
      unpinPanel(layoutWithNoGround(), panel)
      check observed.addItemCalls == 0
      check not panel.isUnpinning
      check stripTitles() == @["BUILD"]

    test "the empty config #692 left behind is refused, not attempted":
      ## THE PRE-FIX CONDITION, constructed directly: `js{}` is exactly what
      ## `addStandaloneAutoHidePanel` stored for these four panes before M46.
      ## A config in that state can still arrive from a restored
      ## `auto_hide_state.json` or a future caller, so the guard is not
      ## dead code.
      ##
      ## Against the pre-fix `unpinPanel` all three checks below fail, for two
      ## reasons: the config IS handed to `addItem`, and `isUnpinning` is left
      ## latched because nothing raised — which is also why the pane is missing
      ## from the strip.
      freshAutoHideWorld()
      let panel = registerBuildPane()
      panel.config = js{}

      unpinPanel(fakeLayout(cstring"genericUiComponent"), panel)

      check observed.addItemCalls == 0
      check not panel.isUnpinning
      check stripTitles() == @["BUILD"]

    test "a panel whose config names no mount label is refused too":
      ## Worse than the no-op, because `genericUiComponent` returns on the
      ## empty label and leaves an EMPTY GL container: it looks like it
      ## worked.  The guard must stop it before `addItem`.
      freshAutoHideWorld()
      let panel = registerBuildPane()
      panel.config = js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{"id": 0, "content": ord(Content.Build)}
      }

      unpinPanel(fakeLayout(cstring"genericUiComponent"), panel)

      check observed.addItemCalls == 0
      check not panel.isUnpinning
      check stripTitles() == @["BUILD"]

    test "a pinPanel-shaped config is unpinned exactly as before":
      ## CALLTRACE / STATE / TERMINAL / EVENT LOG reach `unpinPanel` with the
      ## config `pinPanel` captures, and they were never broken.  This is the
      ## arm that would fail if the new guard were too strict.
      freshAutoHideWorld()
      addStandaloneAutoHidePanel(
        cstring"STATE", Content.State, 0, stubLiveElement(),
        componentLabel = cstring"stateComponent-0", edge = AutoHideEdge.Bottom)
      let panel = autoHideState.panels[0]
      panel.config = js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{
          "id": 0, "label": cstring"stateComponent-0",
          "content": ord(Content.State), "isEditor": false
        }
      }

      unpinPanel(fakeLayout(cstring"genericUiComponent"), panel)

      check observed.addItemCalls == 1
      check observed.factoryInvocations == 1
      check observed.reparentFlagSeen
      check stripTitles() == newSeq[string]()
      check autoHideState.panels.len == 0

else:
  import std/strutils

  const
    AutoHidePath = "src/frontend/ui/auto_hide.nim"
    LayoutPath = "src/frontend/ui/layout.nim"
    ConfigPath = "src/frontend/ui/auto_hide_panel_config.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: it means the production
    ## file this contract describes was moved or deleted.
    readFile(path)

  proc codeOnly(body: string): string =
    ## `body` with every comment dropped.
    ##
    ## A contract that greps raw source answers "the file mentions X", and a
    ## comment explaining why X was REMOVED mentions it just as loudly as the
    ## code would.  This whole suite is about text that must not be in the
    ## compiled program, so the comments come out first.  (Dropping from the
    ## first `#` also mangles `#`-bearing string literals; nothing asserted
    ## here reads one.)
    var lines: seq[string] = @[]
    for line in body.splitLines:
      let hash = line.find('#')
      lines.add(if hash >= 0: line[0 ..< hash] else: line)
    lines.join("\n")

  proc importedModules(body: string): seq[string] =
    ## Every module named by a top-level `import` / `from` in `body`.
    for line in codeOnly(body).splitLines:
      let stripped = line.strip()
      if stripped.startsWith("import ") or stripped.startsWith("from "):
        result.add(stripped)

  proc region(body, fromMarker: string; toMarkers: varargs[string]): string =
    let start = body.find(fromMarker)
    doAssert start >= 0, "marker not found in source: " & fromMarker
    var stop = body.len
    for marker in toMarkers:
      let candidate = body.find(marker, start + fromMarker.len)
      if candidate >= 0 and candidate < stop:
        stop = candidate
    body[start ..< stop]

  suite "#692 unpin (source contract)":

    test "the config module stays dependency-free":
      ## The whole reason it is a separate file is that the rule can then be
      ## exercised headlessly.  An import of `kdom`, `../types` or
      ## GoldenLayout would drag in the DOM world and kill the JS suite above.
      check importedModules(source(ConfigPath)) == @["import std/jsffi"]

    test "a standalone pane is registered WITH a GoldenLayout config":
      ## The defect: `config: js{},  # No GL config — standalone panel`.
      let body = codeOnly(region(source(AutoHidePath),
        "proc addStandaloneAutoHidePanel*", "\nproc ", "\ntype"))
      check not body.contains("config: js{}")
      check body.contains("standaloneComponentConfig(")

    test "layout.nim hands the component label to that registration":
      ## The label is not derivable from the content: PROBLEMS is
      ## `Content.BuildErrors` but mounts into `errorsComponent-0`.
      let body = codeOnly(region(source(LayoutPath),
        "      addStandaloneAutoHidePanel(", "\n  , 500)"))
      check body.contains("panelDef.label")

    test "unpinPanel asks whether the config can be rebuilt":
      let body = codeOnly(
        region(source(AutoHidePath), "proc unpinPanel*", "\nproc "))
      check body.contains("isReattachableConfig(")

    test "unpinPanel never leaves a panel latched mid-unpin":
      ## `panel.isUnpinning` suppresses the panel's strip tab
      ## (`panelsForEdge`) and its persistence (`serializeAutoHideState`).
      ## Leaving it set on a failed unpin makes the tab vanish with no panel
      ## anywhere — the second, independent half of issue #692.  The reset
      ## used to sit in the `except` arm alone, which is only reached when
      ## something raises; `addItem` returning quietly is not a raise.
      let body = codeOnly(
        region(source(AutoHidePath), "proc unpinPanel*", "\nproc "))
      let finallyAt = body.find("finally:")
      check finallyAt >= 0
      let tail = body[finallyAt .. ^1]
      check tail.contains("panel.isUnpinning = false")

    test "the unpin target does not dereference a state it never checked":
      ## `let isEditor = panel.config.componentState.isEditor.to(bool)` was
      ## the FIRST line of `unpinPanelTarget`, it bound a value nothing in
      ## the proc ever read, and on an empty config it threw a native
      ## `TypeError` before `addItem` was reached at all.
      let body = codeOnly(
        region(source(LayoutPath), "auto_hide.unpinPanelTarget =",
               "\n  autoHideState.onPanelShown"))
      # POSITIVE CONTROL, and the only case here that needs one.
      #
      # Every other case in this suite pairs its "must not contain" with a
      # "must contain" over the SAME region, so an empty or mis-sliced subject
      # shows up as a failure of the positive half.  This case is a lone
      # negative, and `Testing/Verification-Harness-Traps.md` §4 is exactly
      # that shape: a scan that matches nothing satisfies every "must not
      # contain" check written against it.  These two lines are the proc body
      # that the negative is about; if they are gone, the subject is no longer
      # `unpinPanelTarget` and the negative below means nothing.
      check body.contains("discard main.addItem(panel.config")
      check body.contains("let edge = panel.edge")
      check not body.contains("panel.config.componentState.isEditor")
