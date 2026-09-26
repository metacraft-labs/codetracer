## Headless cover for a RESTORED auto-hide panel — issue #691 (M47).
##
## The report: move any component into a left/right/bottom auto-hide tab, save
## the layout, close the trace, reopen it.  The tab comes back; expanding it
## shows an empty panel.
##
## Spec grounding
## --------------
## `codetracer-specs/Planned-Features/Auto-Hide-Panes.md` §6.3, "When loading a
## layout": *"3. For each auto-hidden panel: create the auto-hide tab in the
## appropriate strip, **store its component config for later instantiation**"*.
## Step 3 promises instantiation from the stored config.  The tab was created;
## the instantiation did not exist.  `restoreAutoHideState` built the panel with
## `liveElement: nil,  # ... will use config fallback` and nothing in the module
## read `panel.config` to build a DOM node, so `showDockedPanel` cleared the
## pane, took its nil-`liveElement` arm, logged `console.warn` and stopped.
##
## M41 (#608) fixed SERIALIZATION — the state reaches disk and comes back.  It
## did not fix instantiation, and the two are easy to confuse because the
## symptom of a broken restore and the symptom of a broken mount are the same
## empty rectangle.
##
## WHAT THE DISCRIMINATING ASSERTION IS, AND WHY IT IS THAT ONE
## ------------------------------------------------------------
## `Testing/Verification-Harness-Traps.md` §7 asks what the defect itself would
## satisfy.  Three candidates, and only the third survives:
##
## * `panel.liveElement != nil` — real, but satisfied by a half-fix that builds
##   an element and never attaches it.  A detached div is the same empty pane.
## * "the docked content element has a child" — better, and it is asserted, but
##   it is satisfied by attaching ANY node, including a bare `<div>` with no id
##   that no pane could ever mount into.
## * **`document.getElementById(<the label from the stored config>)` resolves.**
##   That id is the whole contract between the layout and the panes: every
##   `tryMountIsoNim…Panel` finds its container with exactly that lookup
##   (`ui/layout.nim`'s `mountComponentContainer` is what creates it for a
##   GoldenLayout pane).  It is false before the fix, false for a detached
##   element, false for an unlabelled one, and true only when a labelled
##   container is really in the document — which is the precondition the mount
##   needs and the one the restore path never met.
##
## Each case states its own control before acting, so "resolves afterwards"
## cannot pass because it resolved all along (§4).
##
## WHAT IS COVERED, AND WHAT IS NOT.  Read this before quoting the suite.
## ---------------------------------------------------------------------
## COVERED — the shipped procs, run:
##   * `restoreAutoHideState` on the object `serializeAutoHideState` really
##     produces, not a hand-copied JSON literal (case "the save/restore round
##     trip");
##   * `showDockedPanel` (tab click) and `showOverlay` (hover/preview), both
##     driven end to end against a document;
##   * `instantiatePanelElement`'s two refusals, and that each of them puts a
##     VISIBLE message in the pane rather than leaving it blank.
##
## NOT COVERED, and no claim is made about it:
##   * The pane's own content.  Filling the container is `ui/layout.nim`'s
##     `onPanelShown` -> `mountPaneForState`, a closure built inside
##     `initLayout`, which needs a GoldenLayout instance and the `data` graph;
##     it cannot be reached headlessly, for the same reason
##     `auto-hide/auto_hide_unpin_test.nim` cannot reach the component
##     registration.  This suite asserts that the hook fires with the right
##     panel and that the container it will look for is present and findable;
##     the NATIVE half below asserts that `layout.nim` routes a restored panel
##     into the factory's own dispatch rather than into a second copy of it.
##   * Anything about what the user sees.  That is Playwright's job
##     (`src/tests/gui/tests/auto-hide/auto-hide-panes.spec.ts`).
##
## THE ONE TEST DOUBLE, justified where it is used (workspace policy)
## ------------------------------------------------------------------
## `auto_hide_dom_harness` is a DOM, and it is a HOST SHIM rather than a stub
## of anything under test: no proc in `ui/auto_hide.nim` is replaced or
## simulated, and every assertion reads the tree the production code built.
## Its own header says why the `-d:nodejs` emulation is not enough on its own.
## `layout/layout_config_roundtrip_test.nim` shares it rather than keeping a
## second copy.
##
## Red-before / green-after
## ------------------------
## Measured by reverting the PRODUCTION change, never by deleting a case.  See
## the milestone entry in `codetracer-specs/Pxor-Bugs.milestones.org` §M47 for
## the figures and the exact revert.

import std/unittest

when defined(js):
  import std/jsffi
  import kdom
  import ../../../../frontend/types
  import ../../../../frontend/ui/auto_hide
  import ../../../../frontend/ui/auto_hide_panel_config

  import ./auto_hide_dom_harness

  proc jsonParse(raw: cstring): JsObject {.importjs: "JSON.parse(#)".}
  proc jsonStringify(value: JsObject): cstring {.importjs: "JSON.stringify(#)".}

  const StateLabel = cstring"stateComponent-0"
    ## The component label `Content.State` mounts into — the id
    ## `state.tryMountIsoNimStatePanel` resolves its container by, and the id
    ## a restored panel's config carries.

  proc freshWorld() =
    ## `autoHideState` is module-level and `initAutoHideState` is a no-op on a
    ## non-nil state, so every case tears it down first.
    autoHideState = nil
    initAutoHideState()
    installAutoHideDocument()

  proc savedStatePanel(
      label: cstring; contentOrdinal: int; edgeOrdinal: int;
      componentKey: cstring = cstring"componentType";
      componentName: cstring = cstring"genericUiComponent"): JsObject =
    ## One entry in the shape `serializeAutoHideState` writes and
    ## `auto_hide_state.json` holds — GoldenLayout's RESOLVED spelling
    ## (`componentType`), which is what a config that has been through
    ## `contentItem.toConfig()` and `JSON.stringify` carries.
    let config = js{
      "type": cstring"component",
      "componentState": js{
        "id": 0,
        "label": label,
        "content": contentOrdinal,
        "isEditor": componentName == cstring"editorComponent"
      }
    }
    config[componentKey] = componentName.toJs
    js{
      "edge": edgeOrdinal,
      "title": cstring"STATE",
      "content": contentOrdinal,
      "componentId": 0,
      "overlayWidth": 420,
      "overlayHeight": 0,
      "config": config
    }

  proc restoreOne(panelEntry: JsObject) =
    let panels = newJsObject()
    restoreAutoHideState(js{"panels": jsonParse(
      cstring"[" & jsonStringify(panelEntry) & cstring"]").toJs})
    discard panels

  suite "#691 a restored auto-hide panel is instantiated from its config":

    test "the container ids this suite builds are the ids production asks for":
      ## THE EMPTY-HAYSTACK GUARD (§4).  Every case below reveals a panel into
      ## `#auto-hide-docked-<edge>-content`; if production looked those up
      ## under different ids, `showDockedPanel` would bail at its
      ## `contentEl.isNil` check and every "the pane is empty before" control
      ## would pass for the wrong reason.  The ids are private to
      ## `auto_hide.nim`, so they are checked through the behaviour instead:
      ## a panel WITH a live element must reach the content element this suite
      ## created.
      freshWorld()
      let live = newStubElement(cstring"already-live")
      addStandaloneAutoHidePanel(
        cstring"BUILD", Content.Build, 0, live,
        componentLabel = cstring"buildComponent-0",
        edge = AutoHideEdge.Bottom)
      showDockedPanel(autoHideState.panels[0])
      check stubChildCount(document.getElementById(DockedBottomContentId)) == 1

    test "expanding a restored tab mounts the pane's container":
      ## THE BUG.  Everything before the reveal is the control; everything
      ## after it is what was missing.
      freshWorld()
      restoreOne(savedStatePanel(StateLabel, ord(Content.State),
                                 ord(AutoHideEdge.Bottom)))
      check autoHideState.panels.len == 1
      let panel = autoHideState.panels[0]

      # CONTROL.  The restore produced a tab and nothing else: no live
      # element, and no container anywhere in the document for the pane to
      # mount into.
      check panel.liveElement.isNil
      check not panel.instantiatedFromConfig
      check document.getElementById(StateLabel).isNil
      check stubChildCount(document.getElementById(DockedBottomContentId)) == 0

      showDockedPanel(panel)

      # THE DISCRIMINATING ASSERTION.  `stateComponent-0` is the id
      # `state.tryMountIsoNimStatePanel` resolves its container by; until it
      # exists in the document there is nothing for any pane to mount into,
      # and before this fix it never came into existence at all.
      check not document.getElementById(StateLabel).isNil
      check $stubClassOf(document.getElementById(StateLabel)) ==
        "component-container"

      # And it got there the way a GoldenLayout pane's container does: inside
      # the panel's live element, which is what the sidebar now holds.
      check not panel.liveElement.isNil
      check panel.instantiatedFromConfig
      let contentEl = document.getElementById(DockedBottomContentId)
      check stubChildCount(contentEl) == 1
      check stubChildAt(contentEl, 0) == panel.liveElement

    test "the hover overlay instantiates it too, not only the tab click":
      ## Two reveal gestures, two code paths (`showDockedPanel` and
      ## `doShowOverlayImpl`), and the module's own header calls out how often
      ## they are mixed up.  A fix wired into one of them is half a fix.
      freshWorld()
      restoreOne(savedStatePanel(StateLabel, ord(Content.State),
                                 ord(AutoHideEdge.Left)))
      let panel = autoHideState.panels[0]
      check document.getElementById(StateLabel).isNil

      showOverlay(panel)

      check not document.getElementById(StateLabel).isNil
      let overlayContent = document.getElementById(OverlayContentId)
      check stubChildCount(overlayContent) == 1
      check stubChildAt(overlayContent, 0) == panel.liveElement

    test "the save/restore round trip, through the real serializer":
      ## The reporter's sequence, with no hand-written JSON in it: pin a panel,
      ## `serializeAutoHideState`, JSON round trip, `restoreAutoHideState`,
      ## reveal.  A literal fixture can drift from what the serializer writes;
      ## this cannot.
      freshWorld()
      # A panel in the state `pinPanel` leaves behind.  `pinPanel` itself needs
      # a GoldenLayout content item, so the panel is registered through
      # `addStandaloneAutoHidePanel` and given `pinPanel`'s config shape —
      # `standaloneComponentConfig` builds exactly that shape, which is why the
      # two are interchangeable here (see its own doc comment).
      addStandaloneAutoHidePanel(
        cstring"STATE", Content.State, 0,
        newStubElement(cstring"live-state"),
        componentLabel = StateLabel, edge = AutoHideEdge.Right)
      # `serializeAutoHideState` deliberately drops `standalone` panels, so the
      # pane is marked as an ordinary pinned one for the round trip — which is
      # what it would be had it come from `pinPanel`.
      autoHideState.panels[0].standalone = false

      let saved = jsonParse(jsonStringify(serializeAutoHideState()))
      # CONTROL: the state really did serialise something.  An empty `panels`
      # array would make the restore below a no-op and the case vacuous.
      check jsonStringify(saved["panels"]).len > 2

      freshWorld()
      restoreAutoHideState(saved)
      check autoHideState.panels.len == 1
      let panel = autoHideState.panels[0]
      check panel.liveElement.isNil
      check document.getElementById(StateLabel).isNil

      showDockedPanel(panel)

      check not document.getElementById(StateLabel).isNil
      check stubChildCount(document.getElementById(DockedRightContentId)) == 1

    test "instantiation happens once — a second reveal reuses the element":
      ## The module's central design principle is live DOM element
      ## preservation: hiding a panel detaches its element and keeps it.  A
      ## rebuild on every reveal would throw away everything the pane had
      ## rendered, which is the same class of bug one level down.
      freshWorld()
      restoreOne(savedStatePanel(StateLabel, ord(Content.State),
                                 ord(AutoHideEdge.Bottom)))
      let panel = autoHideState.panels[0]
      showDockedPanel(panel)
      let first = panel.liveElement
      check not first.isNil
      # A second click on the same tab collapses the sidebar; a third reopens.
      showDockedPanel(panel)
      showDockedPanel(panel)
      check panel.liveElement == first
      check stubChildCount(document.getElementById(DockedBottomContentId)) == 1

    test "the panel the reveal hook is handed is the one that was rebuilt":
      ## `ui/layout.nim` fills the rebuilt container from `onPanelShown`, and
      ## it dispatches on `panel.instantiatedFromConfig`.  A hook that fired
      ## with the wrong panel — or with the flag still false — would leave the
      ## container empty, which is the original symptom with extra steps.
      freshWorld()
      restoreOne(savedStatePanel(StateLabel, ord(Content.State),
                                 ord(AutoHideEdge.Bottom)))
      let panel = autoHideState.panels[0]
      var shown: seq[bool] = @[]
      var shownPanelMatched = false
      autoHideState.onPanelShown = proc(p: AutoHidePanel) =
        shown.add(p.instantiatedFromConfig)
        shownPanelMatched = p == panel
      showDockedPanel(panel)
      check shown.len >= 1
      check shown[0]
      check shownPanelMatched

    test "a config that cannot be rebuilt says so IN THE PANE":
      ## Deliverable 2.  An empty object is a config no component can be built
      ## from — it is what `addStandaloneAutoHidePanel` stored before M46, and
      ## a hand-edited or downgraded `auto_hide_state.json` can still produce
      ## one.  The old behaviour was `console.warn` plus an empty rectangle,
      ## which the user cannot tell from a pane that rendered nothing.
      freshWorld()
      let entry = savedStatePanel(StateLabel, ord(Content.State),
                                  ord(AutoHideEdge.Bottom))
      entry["config"] = js{}
      restoreOne(entry)
      check autoHideState.panels.len == 1
      let panel = autoHideState.panels[0]
      # CONTROL: the predicate really does refuse this config.  Asked of the
      # production rule, not re-derived here (§30).
      check not isReattachableConfig(panel.config)

      showDockedPanel(panel)

      let contentEl = document.getElementById(DockedBottomContentId)
      check stubChildCount(contentEl) == 1
      let notice = stubChildAt(contentEl, 0)
      check $stubClassOf(notice) == "auto-hide-panel-unavailable"
      check stubTextOf(notice).len > 0
      # And nothing was invented: no container was mounted for a panel that
      # cannot be rebuilt.
      check document.getElementById(StateLabel).isNil
      check panel.liveElement.isNil

    test "an editor pinned to an edge is refused, not mounted blank":
      ## An editor tab is built by the separate `editorComponent` registration,
      ## which creates a Monaco instance against the container; there is no
      ## path from a component state alone to a working editor.  Mounting the
      ## generic container for it would produce exactly the blank pane this
      ## milestone is about, while looking like it had worked.
      ##
      ## §6.1 of the spec lists Editor as the one pane that is NOT an auto-hide
      ## candidate — but every tab carries a pin button, so the state is
      ## reachable and must not be silent.
      freshWorld()
      restoreOne(savedStatePanel(
        cstring"/home/u/proj/src/main.nim", ord(Content.EditorView),
        ord(AutoHideEdge.Bottom),
        componentName = cstring"editorComponent"))
      let panel = autoHideState.panels[0]
      # CONTROL: the config is otherwise perfectly well-formed — it is refused
      # for its COMPONENT, not for being malformed.
      check isReattachableConfig(panel.config)
      check $configComponentName(panel.config) == "editorComponent"

      showDockedPanel(panel)

      let contentEl = document.getElementById(DockedBottomContentId)
      check stubChildCount(contentEl) == 1
      check $stubClassOf(stubChildAt(contentEl, 0)) == "auto-hide-panel-unavailable"

    test "a panel that already has a live element is left alone":
      ## The regression guard.  CALLTRACE / STATE / TERMINAL / EVENT LOG pinned
      ## within a session, and the four standalone bottom panes, all arrive at
      ## a reveal with a live element already carrying a mounted IsoNim root.
      ## Rebuilding it would discard their rendered content, and setting
      ## `instantiatedFromConfig` on them would make `onPanelShown` re-run
      ## their mount on every hover.
      freshWorld()
      let live = newStubElement(cstring"live-build")
      addStandaloneAutoHidePanel(
        cstring"BUILD", Content.Build, 0, live,
        componentLabel = cstring"buildComponent-0",
        edge = AutoHideEdge.Bottom)
      let panel = autoHideState.panels[0]
      check ensurePanelLiveElement(panel)
      check panel.liveElement == live
      check not panel.instantiatedFromConfig

      showDockedPanel(panel)
      check panel.liveElement == live
      check not panel.instantiatedFromConfig
      check stubChildAt(document.getElementById(DockedBottomContentId), 0) == live

    test "the rebuilt host carries the label from the config, not the title":
      ## `panel.title` is what the strip tab shows — "STATE", or for an editor
      ## a file path.  `componentState.label` is the mount id.  They are
      ## different strings and reaching for the wrong one produces a container
      ## no pane can find, which fails exactly like no container at all.
      freshWorld()
      let entry = savedStatePanel(cstring"calltraceComponent-0",
                                  ord(Content.Calltrace),
                                  ord(AutoHideEdge.Bottom))
      entry["title"] = cstring"CALL TRACE".toJs
      restoreOne(entry)
      let panel = autoHideState.panels[0]
      showDockedPanel(panel)
      check not document.getElementById(cstring"calltraceComponent-0").isNil
      check document.getElementById(cstring"CALL TRACE").isNil

else:
  import std/strutils

  const
    AutoHidePath = "src/frontend/ui/auto_hide.nim"
    LayoutPath = "src/frontend/ui/layout.nim"
    ConfigPath = "src/frontend/ui/auto_hide_panel_config.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: the production file this
    ## contract describes was moved or deleted.
    readFile(path)

  proc codeOnly(body: string): string =
    ## `body` with every comment dropped.  A contract that greps raw source
    ## answers "the file mentions X", and a comment explaining why X was
    ## removed mentions it as loudly as the code would.
    var lines: seq[string] = @[]
    for line in body.splitLines:
      let hash = line.find('#')
      lines.add(if hash >= 0: line[0 ..< hash] else: line)
    lines.join("\n")

  proc region(body, fromMarker: string; toMarkers: varargs[string]): string =
    let start = body.find(fromMarker)
    doAssert start >= 0, "marker not found in source: " & fromMarker
    var stop = body.len
    for marker in toMarkers:
      let candidate = body.find(marker, start + fromMarker.len)
      if candidate >= 0 and candidate < stop:
        stop = candidate
    body[start ..< stop]

  suite "#691 restored-panel instantiation (source contract)":
    ## The JS half above cannot reach `ui/layout.nim` — its subject is a
    ## closure built inside `initLayout`.  These cases cover the half of the
    ## fix that lives there, in the same shape
    ## `auto-hide/auto_hide_unpin_test.nim` and
    ## `layout/layout_config_roundtrip_test.nim` use for the same two files.

    test "both reveal paths ask for the config fallback":
      ## A fix wired into the tab click and not the hover is half a fix, and
      ## the two arms sit 400 lines apart.
      let body = codeOnly(source(AutoHidePath))
      let docked = region(body, "proc showDockedPanel*", "\nproc ")
      check docked.contains("ensurePanelLiveElement(panel)")
      let overlay = region(body, "proc doShowOverlayImpl", "\nproc ")
      check overlay.contains("ensurePanelLiveElement(panel)")

    test "neither answers a missing panel with a log line alone":
      ## Deliverable 2.  `console.warn "auto_hide: no live element for docked
      ## panel"` was the whole of the old nil arm.
      let body = codeOnly(source(AutoHidePath))
      let docked = region(body, "proc showDockedPanel*", "\nproc ")
      check docked.contains("showPanelUnavailable(contentEl, panel)")
      check not docked.contains("no live element for docked panel")
      let overlay = region(body, "proc doShowOverlayImpl", "\nproc ")
      check overlay.contains("showPanelUnavailable(contentEl, panel)")
      check not overlay.contains("overlay will be empty")

    test "the notice is written as text, never as markup":
      ## A panel title is user data — for an editor tab it is the file path —
      ## and `src/frontend/tests/htmlSinks.test.mjs` asserts that no source
      ## writes panel titles as markup.
      # Sliced from the RAW source and stripped afterwards: `codeOnly` deletes
      # the `# ---` banner that closes this region, so slicing a
      # comment-stripped body would run to the end of the file and the
      # negative below would be answered by some other proc's `innerHTML`.
      let notice = codeOnly(region(
        source(AutoHidePath), "proc showPanelUnavailable", "\n# ---"))
      # POSITIVE CONTROL for the negative below: this really is the proc that
      # builds the notice.
      check notice.contains("auto-hide-panel-unavailable")
      check notice.contains("notice.textContent")
      check not notice.contains("innerHTML")

    test "the rebuild reuses the component-config rules, it does not restate them":
      ## `Verification-Harness-Traps.md` §30.  `auto_hide_panel_config.nim`
      ## already owns "can GoldenLayout build this?" and "what does it name?";
      ## a second copy inside `auto_hide.nim` would drift.
      let body = codeOnly(source(AutoHidePath))
      let rebuild = region(body, "proc instantiatePanelElement*", "\nproc ")
      check rebuild.contains("isReattachableConfig(panel.config)")
      check rebuild.contains("configComponentName(panel.config)")
      check rebuild.contains("configComponentLabel(panel.config)")
      # And the rules are still in the dependency-free module, so they stay
      # reachable from a headless test.
      let config = codeOnly(source(ConfigPath))
      check config.contains("proc configComponentName*")
      check config.contains("proc configComponentLabel*")

    test "layout.nim mounts a restored panel through the factory's own dispatch":
      ## THE ANTI-DUPLICATION CONTRACT, and the reason the dispatch was
      ## extracted rather than copied.
      ## `viewmodel/tests/unit/test_every_mountable_pane_has_a_factory_arm.nim`
      ## asserts that every direct-mount `Content` has an arm in ONE place; a
      ## restored panel mounted from a second hand-written switch would be
      ## invisible to that scan and would rot the first time a pane is added.
      let body = codeOnly(source(LayoutPath))
      check body.count("proc mountPaneForState") == 1
      # The GoldenLayout registration still routes through it...
      let registration = region(
        body, "registerComponent(cstring\"genericUiComponent\")", "\nproc ")
      check registration.contains("mountPaneForState(state)")
      # ...and so does the reveal of a panel rebuilt from its config.
      let onShown = region(body, "autoHideState.onPanelShown = proc",
                           "\n  autoHideState.onChanged = proc")
      check onShown.contains("panel.instantiatedFromConfig")
      check onShown.contains("mountPaneForState(")

    test "the mount dispatch still carries its arms":
      ## POSITIVE CONTROL for the case above (§4): "there is exactly one
      ## `mountPaneForState`" and "the registration calls it" are both
      ## satisfied by an empty proc.  These are three of the panes the factory
      ## is known to be the only mount site for.
      let dispatch = codeOnly(region(source(LayoutPath),
        "proc mountPaneForState", "\nproc "))
      check dispatch.contains("tryMountIsoNimStatePanel()")
      check dispatch.contains("tryMountIsoNimCalltrace()")
      check dispatch.contains("discard component.afterInit()")

    test "restoreAutoHideState no longer promises a fallback that does not exist":
      ## The recorded root cause: the comment at the `liveElement: nil` line
      ## said "will use config fallback" and there was none.  A comment is not
      ## a call site, so the check is that the PROC the comment now names is
      ## really reachable from the reveal paths — asserted above — and that the
      ## builder exists here.
      let body = codeOnly(source(AutoHidePath))
      check body.contains("proc instantiatePanelElement*")
      check body.contains("proc ensurePanelLiveElement*")
      let restore = region(body, "proc restoreAutoHideState*", "\nproc ")
      # The restore still leaves the element nil — a DOM node cannot be
      # persisted — which is exactly why the reveal has to build one.
      check restore.contains("liveElement: nil")
