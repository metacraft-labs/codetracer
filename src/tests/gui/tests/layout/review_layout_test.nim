## Headless regression tests for RV-2: **a review over a dataset opens the
## editor layout, not the debugging layout.**
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §1.1:
##
##   "`ct review` opens the editor layout, not the debugging layout.  A review
##    over a dataset is an editing-and-reading task, not a replay session.  The
##    editor layout omits the panels a dataset cannot populate (EVENT LOG,
##    CALLTRACE, TIMELINE, TERMINAL OUTPUT), so a review does not present empty
##    panels that imply missing data.  Where a review *does* have a live
##    recording — launch method 2, and method 3 when the agent recorded one —
##    the panels that recording populates behave exactly as they do in ordinary
##    replay."
##
## The reported symptom: `ct review <PATH>` came up with EVENT LOG, CALLTRACE,
## TIMELINE and TERMINAL OUTPUT present but empty, because `ct review` loads no
## recording at all (`index/args.nim` forces `recordingID = ""`).  Four empty
## panels read as missing data, not as "this launch has no replay".
##
## Two layers are guarded here, for the same reason
## `deepreview_layout_test.nim` guards two:
##
##   * The behavioural suite (JavaScript backend) runs the REAL production
##     rules — `index/layout_config_repair.reviewModeHiddenContentIds` and
##     `sanitizeLayoutConfig` — over the REAL bundled
##     `src/config/default_layout.json`, embedded with `staticRead` so the
##     assertions describe the layout users actually get.
##   * The source-contract suite (native only, it reads production sources)
##     asserts the WIRING: that the dataset launch path loads the review
##     layout, that the other two launch methods still get the debugging one,
##     that the review still enters through the one shared routine, and that
##     every recovery path inside the loader is sanitised too.
##
## The split is forced: `index/config.nim` needs electron and `fs` and cannot
## be imported by a test at all, so which loader the startup path calls is only
## establishable by reading the source.  `index/layout_config_repair` imports
## nothing but `std/jsffi`, which is why the *rule* lives there.
##
## Spec: codetracer-specs/DeepReview/Review-Command.milestones.org (RV-2);
## codetracer-specs/DeepReview/DeepReview-GUI.md §1.1;
## codetracer-specs/GUI/Layout-And-Navigation/Layout-System.md,
## "DeepReview and the Layout".

import std/unittest

## `Content` ordinals, mirrored as literals so the behavioural suite keeps the
## dependency-free property of the module under test — the same convention
## `layout_config_roundtrip_test.nim` uses.  Source of truth:
## `src/common/common_types/codetracer_features/frontend.nim`.  The
## correspondence between these literals and the production sets is asserted by
## the source contract at the bottom of this file (and, for the edit-mode set,
## by `session-chrome/new_trace_caption_chrome_test.nim`).
const
  ContentTrace = 1
  ContentEditorView = 2
  ContentState = 4
  ContentCalltrace = 6
  ContentEventLog = 8
  ContentFilesystem = 9
  ContentRepl = 10
  ContentScratchpad = 17
  ContentTimeline = 19
  ContentTraceLog = 22
  ContentCalltraceEditor = 23
  ContentTerminalOutput = 24
  ContentStepList = 33
  ContentAgentActivity = 35
  ContentAgentActivityDeepReview = 39
  ContentVCS = 41
  ContentPixelHistory = 43
  ContentShaderDebug = 44
  ContentVideoPlayer = 45

  ## `index/config.editModeHiddenContentIds()`, verbatim and in order.
  EditModeHiddenIds = @[
    ContentTrace,
    ContentState,
    ContentScratchpad,
    ContentRepl,
    ContentEventLog,
    ContentTimeline,
    ContentTerminalOutput,
    ContentStepList,
    ContentCalltrace,
    ContentCalltraceEditor,
    ContentTraceLog,
    ContentAgentActivity,
    ContentAgentActivityDeepReview,
    ContentPixelHistory,
    ContentShaderDebug,
    ContentVideoPlayer
  ]

  ## `index/config.reviewPillarContentIds()`.
  ReviewPillarIds = @[ContentAgentActivity, ContentAgentActivityDeepReview]

  ## The four panels §1.1 names by hand as the ones a dataset cannot populate.
  ## A review must show none of them.
  UnpopulatableByADatasetIds = @[
    ContentEventLog,
    ContentCalltrace,
    ContentTimeline,
    ContentTerminalOutput
  ]

when defined(js):
  import std/[json, jsffi]
  import ../../../../frontend/index/layout_config_repair
  import ../../../../frontend/viewmodel/viewmodels/deepreview_layout

  ## The layout CodeTracer ships with, embedded at compile time — the same
  ## file `resetLayoutToDefault` copies into the user's config directory, and
  ## therefore the exact input both the fresh-install fallback and the reset
  ## paths hand the sanitiser.  `staticRead` rather than `readFile` because
  ## `std/os` file reads do not exist on this backend.
  const bundledDefaultLayoutJson =
    staticRead("../../../../config/default_layout.json")

  proc jsonParse(raw: cstring): js {.importjs: "JSON.parse(#)".}
  proc jsonStringify(value: js): cstring {.importjs: "JSON.stringify(#)".}
  proc jsLen(value: js): int {.importjs: "(#).length".}
  proc jsIsUndefined(value: js): bool {.importjs: "((#) === undefined)".}

  proc bundledLayout(): js = jsonParse(cstring(bundledDefaultLayoutJson))

  proc contentIdsIn(config: js): seq[int] =
    ## Every `componentState.content` in the tree, in document order.
    var pending = @[if jsIsUndefined(config["root"]): config else: config["root"]]
    while pending.len > 0:
      let node = pending[0]
      pending.delete(0)
      if node.isNil or jsIsUndefined(node):
        continue
      if node["type"].to(cstring) == cstring"component":
        result.add(node["componentState"]["content"].to(int))
      if not jsIsUndefined(node["content"]):
        for i in 0 ..< jsLen(node["content"]):
          pending.add(node["content"][i])

  proc component(content: int; title: cstring): js =
    js{
      "type": cstring"component",
      "componentType": cstring"genericUiComponent",
      "componentState": js{"id": 0, "label": title, "content": content},
      "title": title
    }

  proc reviewHiddenIds(): seq[int] =
    ## What `index/config.reviewModeHiddenContentIds()` computes.
    reviewModeHiddenContentIds(EditModeHiddenIds, ReviewPillarIds)

  proc asReviewLayout(config: js): js =
    ## What `loadReviewLayoutConfig` produces from a layout file: the
    ## edit-mode sanitiser with the review's hidden set.
    sanitizeLayoutConfig(config, ContentEditorView, reviewHiddenIds())

  proc asEditLayout(config: js): js =
    sanitizeLayoutConfig(config, ContentEditorView, EditModeHiddenIds)

  proc savedEditLayoutFile(): cstring =
    ## The bytes `index/window.onSaveConfig` writes to
    ## `~/.config/codetracer/default_edit_layout.json` when an editing session
    ## ends: the live layout run through `sanitizeEditLayoutJson`, which is
    ## `sanitizeLayoutConfig` with edit mode's hidden set.
    ##
    ## Its input here is the bundled default because that is what the FIRST
    ## editing session on a machine is handed — CodeTracer ships no edit
    ## layout, so `loadEditLayoutConfig` falls back to `default_layout.json`.
    ## Every later session re-saves what it loaded, so this file shape is a
    ## fixed point, not a one-off.
    jsonStringify(asEditLayout(bundledLayout()))

  proc reviewStartupLayout(savedFile: cstring): JsonNode =
    ## The whole chain a `ct review <PATH>` launch puts a layout file through:
    ##
    ##   file on disk
    ##     -> `index/config.loadReviewLayoutConfig` (the edit-mode sanitiser
    ##        with the REVIEW hidden set)
    ##     -> IPC `CODETRACER::start-deepreview`
    ##     -> `ui_js.onStartDeepReview` -> `deepreview_layout.focusReviewPanels`
    ##
    ## The IPC hop is a JSON round trip (`resolvedConfigToJsonNode`), which is
    ## why the two halves can be composed here across the `js` / `JsonNode`
    ## boundary exactly as production composes them.
    focusReviewPanels(parseJson($jsonStringify(
      asReviewLayout(jsonParse(savedFile)))))

  suite "RV-2 — a review over a dataset opens the editor layout":

    test "test_dataset_review_drops_the_panels_a_dataset_cannot_populate":
      ## The defect itself.  Every one of these four came up present and empty
      ## in a `ct review` session, because the debugging layout was loaded.
      let ids = contentIdsIn(asReviewLayout(bundledLayout()))
      for contentId in UnpopulatableByADatasetIds:
        check contentId notin ids

      # They really are in the layout a review used to get, so the assertion
      # above is falsifiable rather than vacuous.
      let debugIds = contentIdsIn(bundledLayout())
      for contentId in UnpopulatableByADatasetIds:
        check contentId in debugIds

    test "test_the_review_hidden_set_never_hides_a_pillar":
      ## DeepReview-GUI.md: "DeepReview introduces no panel of its own.  It is
      ## a combination of features of three existing surfaces: 1. the Editor,
      ## 2. the VCS panel, 3. the Agent Activity panel."  All three must
      ## survive the switch to the editor layout, or the switch deletes a
      ## required surface.
      ##
      ## SCOPE, stated honestly.  This test's input is the BUNDLED
      ## `default_layout.json`, which is what the review loader reads only on
      ## a machine that has never opened a folder in edit mode — CodeTracer
      ## ships no `default_edit_layout.json`, so the loader falls back to the
      ## debugging layout and sanitises it.  It therefore covers the hidden-set
      ## rule and the fresh-install path, and NOT the file a review reads once
      ## edit mode has written one; that file has no Agent Activity panel to
      ## keep, and no hidden set can put one back.  The persisted-file case is
      ## `test_a_persisted_edit_layout_still_gives_the_review_its_third_pillar`
      ## below.  It was recorded as covering the rule outright, and it did not.
      let hidden = reviewHiddenIds()
      # The Editor: `Content.EditorView` may never be *hidden*.  (Saved
      # per-trace editor tabs are still stripped — that is the `editorContent`
      # argument, and it is why a review opens its own diff tab rather than
      # inheriting one — but the kind itself stays openable.)
      check ContentEditorView notin hidden
      check ContentVCS notin hidden
      check ContentAgentActivity notin hidden
      check ContentAgentActivityDeepReview notin hidden

      let ids = contentIdsIn(asReviewLayout(bundledLayout()))
      check ContentVCS in ids
      check ContentAgentActivity in ids
      # `index/config.isValidLayoutConfig` rejects a layout with no Filesystem
      # panel, so a review layout that lost FILES would be thrown away on the
      # next launch.
      check ContentFilesystem in ids

    test "test_review_layout_keeps_a_docked_agent_activity_deepreview_pane":
      ## `Content.AgentActivityDeepReview` is a different id from the retired
      ## `Content.DeepReview`, and it is the review's identity in the Agent
      ## Activity pillar's layout.  AA-1 deleted the roll-up the pane used to
      ## draw but kept the id, precisely so this stays true: the bundled layout
      ## does not host it as a pane of its own, but a saved one may, and edit
      ## mode hides it while a review must not.
      let layout = js{
        "root": js{
          "type": cstring"row",
          "content": @[
            js{"type": cstring"stack", "content": @[
              component(ContentFilesystem, cstring"FILES"),
              component(ContentVCS, cstring"VCS")]},
            js{"type": cstring"stack", "content": @[
              component(ContentAgentActivityDeepReview, cstring"REVIEW"),
              component(ContentEventLog, cstring"EVENT LOG")]}]}}
      let ids = contentIdsIn(asReviewLayout(layout))
      check ContentAgentActivityDeepReview in ids
      check ContentEventLog notin ids

    test "test_the_review_set_is_the_edit_set_minus_the_review_pillars":
      ## The rule, stated as a rule: a review hides everything an editing
      ## session hides *except* its own pillars, so a panel added to edit
      ## mode's hidden set is hidden by a review too without anyone
      ## remembering to add it twice.
      let hidden = reviewHiddenIds()
      for contentId in EditModeHiddenIds:
        if contentId in ReviewPillarIds:
          check contentId notin hidden
        else:
          check contentId in hidden
      check hidden.len == EditModeHiddenIds.len - ReviewPillarIds.len

    test "test_the_pillar_rescue_is_load_bearing":
      ## Without it, loading the edit layout for a review would delete the
      ## Agent Activity panel — the review's third pillar — and silently turn
      ## `deepreview_layout.focusReviewActivityPane` into a no-op.  This is the
      ## conflict RV-2 has to resolve, asserted rather than described.
      let editIds = contentIdsIn(asEditLayout(bundledLayout()))
      check ContentAgentActivity notin editIds

      let reviewIds = contentIdsIn(asReviewLayout(bundledLayout()))
      check ContentAgentActivity in reviewIds

      # ...and it is the ONLY difference between the two layouts.
      check reviewIds.len == editIds.len + 1
      for contentId in editIds:
        check contentId in reviewIds

    test "test_the_fresh_install_fallback_is_a_review_layout_too":
      ## RV-2's fourth deliverable.  CodeTracer ships no
      ## `default_edit_layout.json` at all — `src/config/` holds only
      ## `default_layout.json` — so on a fresh install the edit-layout loader
      ## always takes its fallback and reads the DEBUGGING layout.  If that
      ## fallback returned what it read, the fix would be a no-op for every
      ## first-time user.
      ##
      ## The fallback's input is exactly the bundled default, so sanitising
      ## that input IS the fallback's result; asserting on it is asserting on
      ## the fresh-install path.  That the fallback (and every reset path)
      ## really does sanitise is the source contract's business.
      let ids = contentIdsIn(asReviewLayout(bundledLayout()))
      for contentId in UnpopulatableByADatasetIds:
        check contentId notin ids
      check ContentVCS in ids
      check ContentAgentActivity in ids

    test "test_a_review_layout_is_still_a_layout":
      ## The sanitiser prunes emptied stacks, so the result must still be a
      ## tree GoldenLayout can load: a root with a type and at least one
      ## component under it.
      let sanitized = asReviewLayout(bundledLayout())
      check not jsIsUndefined(sanitized["root"])
      check sanitized["root"]["type"].to(cstring) == cstring"row"
      check contentIdsIn(sanitized).len > 0
      # Round-trips as JSON, which is how it reaches the renderer.
      check jsonStringify(sanitized).len > 0

  suite "RV-2 — a review over a PERSISTED edit layout keeps its three pillars":
    ## The blind spot the suite above left, and the file a real `ct review`
    ## actually reads.
    ##
    ## RV-2's hidden set stops the LOADER from removing the Agent Activity
    ## panel.  It cannot put back one that is not in the file, and usually it
    ## is not: `index/window.onSaveConfig` writes `default_edit_layout.json`
    ## through `sanitizeEditLayoutJson`, whose hidden set CONTAINS
    ## `Content.AgentActivity`.  So the moment a user has opened a folder in
    ## edit mode, the file a review reads holds FILES and VCS and nothing
    ## else, and the review comes up missing the third of the three surfaces
    ## it is assembled from.
    ##
    ## Before RV-2 this could not happen — a review read the debugging layout,
    ## which always declares the panel.  Moving the launch onto the shared
    ## edit-mode file turned a rare case (a user who closed the tab by hand)
    ## into the default for anyone who has used edit mode.
    ##
    ## The whole chain is exercised, not a stage of it: the bytes edit mode
    ## SAVES, read back by the review LOADER, prepared by the renderer's
    ## review layout preparation.  Asserting on any single stage is what let
    ## this through — every stage is individually doing what it was told.

    test "test_the_e2e_fixture_is_what_edit_mode_actually_writes":
      ## The Playwright suite cannot run the save-side sanitiser, so it seeds
      ## `default_edit_layout.json` from a checked-in fixture
      ## (`editLayoutPath` in `lib/fixtures.ts`).  A fixture that drifts away
      ## from what edit mode really writes would turn the only end-to-end
      ## coverage of this defect into a test of a file nobody produces.
      ##
      ## Pinned here rather than in the spec because this is the only place
      ## that can run the real `sanitizeLayoutConfig` over the real bundled
      ## layout.
      const e2eEditLayoutFixture = staticRead(
        "../deepreview/fixtures/edit-layout-without-agent-activity.json")
      check jsonStringify(jsonParse(cstring(e2eEditLayoutFixture))) ==
        savedEditLayoutFile()

    test "test_the_saved_edit_layout_really_has_no_agent_activity_panel":
      ## The premise, asserted rather than assumed, so the tests below cannot
      ## quietly become vacuous if edit mode's hidden set ever changes.
      let saved = savedEditLayoutFile()
      let ids = contentIdsIn(jsonParse(saved))
      check ContentFilesystem in ids
      check ContentVCS in ids
      check ContentAgentActivity notin ids
      check ContentAgentActivityDeepReview notin ids

    test "test_a_persisted_edit_layout_still_gives_the_review_its_third_pillar":
      ## The defect. `focusReviewActivityPane` can only retarget a stack at a
      ## panel that is there; with the panel gone it is a no-op and the pillar
      ## never appears.  Obligation 4 of Layout-System.md, "DeepReview and the
      ## Layout" — "Absent panels are materialised, not substituted" — is what
      ## closes it.
      let prepared = reviewStartupLayout(savedEditLayoutFile())
      check prepared.layoutHasContent(AgentActivityContentId)
      check prepared.layoutHasContent(VcsContentId)
      check prepared.layoutHasContent(FilesystemContentId)

    test "test_the_persisted_review_layout_shows_all_three_pillars_at_once":
      ## Present is not enough: DeepReview-GUI.md §2 requires the VCS panel to
      ## be "the visible tab of whichever stack hosts it when a review
      ## starts", and Layout-System.md obligation 2 requires the same of the
      ## Agent Activity panel.  Two panels in one stack cannot both be
      ## visible, so a materialisation that dropped the pillar into the
      ## FILES/VCS stack would satisfy the test above and still break the
      ## review — the VCS panel would be hidden behind the panel just added.
      let prepared = reviewStartupLayout(savedEditLayoutFile())
      let vcsStack = prepared.findStackWithContent(VcsContentId)
      let activityStack = prepared.findStackWithContent(AgentActivityContentId)
      check not vcsStack.isNil
      check not activityStack.isNil
      check vcsStack != activityStack

      proc visibleContentId(stack: JsonNode): int =
        let index = stack{"activeItemIndex"}.getInt(0)
        let children = stack{"content"}.getElems
        if index < 0 or index >= children.len:
          return -1
        children[index]{"componentState"}{"content"}.getInt(-1)

      check visibleContentId(vcsStack) == VcsContentId
      check visibleContentId(activityStack) == AgentActivityContentId

    test "test_the_review_erases_nothing_the_user_arranged":
      ## Issue #610's subject, restated for the materialisation: putting the
      ## pillar back may not cost the user a panel, a stack-mate or an order.
      let saved = savedEditLayoutFile()
      let before = contentIdsIn(jsonParse(saved))
      let prepared = reviewStartupLayout(saved)
      let after = contentIdsInLayout(prepared)
      for contentId in before:
        check after.contains(contentId)
      # Exactly one panel was added, and it is the pillar.
      check after.len == before.len + 1
      check after.contains(AgentActivityContentId)
      # FILES keeps VCS as its stack-mate, in that order.
      let vcsStack = prepared.findStackWithContent(VcsContentId)
      var stackIds: seq[int] = @[]
      for child in vcsStack{"content"}.getElems:
        stackIds.add(child{"componentState"}{"content"}.getInt(-1))
      check stackIds == @[FilesystemContentId, VcsContentId]

    test "test_the_persisted_review_layout_still_shows_no_replay_panels":
      ## The materialisation must not smuggle the debugging layout back in:
      ## RV-2's own requirement still holds over this input.
      let prepared = reviewStartupLayout(savedEditLayoutFile())
      for contentId in UnpopulatableByADatasetIds:
        check not prepared.layoutHasContent(contentId)
      check not prepared.layoutHasContent(RetiredDeepReviewContentId)

    test "test_a_second_review_over_the_same_layout_adds_nothing":
      ## Obligation 3, over the real input: a review must not accumulate a
      ## second pillar when it runs on a layout a previous review prepared.
      let once = reviewStartupLayout(savedEditLayoutFile())
      let twice = focusReviewPanels(once)
      check twice == once

when not defined(js):
  ## Source contract.  The behavioural suite above describes the RULE; these
  ## tests describe the WIRING, which is the half that was wrong: the rule and
  ## the editor layout both already existed, and the review launch simply did
  ## not use them.
  import std/strutils

  const
    StartupPath = "src/frontend/index/startup.nim"
    IndexConfigPath = "src/frontend/index/config.nim"
    LayoutRepairPath = "src/frontend/index/layout_config_repair.nim"
    TracesPath = "src/frontend/index/traces.nim"
    VcsPath = "src/frontend/ui/vcs.nim"
    AgenticLauncherPath = "src/frontend/ui/agentic_session_launcher.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: it means a production file
    ## this contract describes was moved or deleted.
    readFile(path)

  proc sectionBetween(body, start, stop: string): string =
    ## The slice of `body` that begins at `start` and ends before the next
    ## `stop`, or the rest of the file when there is no `stop`.
    ##
    ## A missing `start` anchor used to fall through to `body[-1 .. ^1]` and
    ## die with a bare `IndexDefect` naming a line inside `std/strutils` — no
    ## anchor, no file, no clue which contract lost its footing.  That is the
    ## normal way one of these tests breaks: every anchor is a *production*
    ## spelling, and renaming a proc is exactly the routine change that
    ## invalidates one.  Fail with the anchor in the message instead, so the
    ## report says what to go and look for.
    let startIndex = body.find(start)
    if startIndex < 0:
      raise newException(ValueError,
        "source-contract anchor not found: " & escape(start) &
        " — the production spelling it names was renamed, moved or removed, " &
        "so this contract no longer describes anything")
    let rest = body[startIndex .. ^1]
    let stopIndex = rest.find(stop, start.len)
    if stopIndex < 0: rest else: rest[0 ..< stopIndex]

  proc deepReviewStartupBranch(): string =
    ## The `withDeepReview` branch of `index/startup.init` — the whole of the
    ## dataset launch path on the index side.
    sectionBetween(source(StartupPath),
      "if data.startOptions.withDeepReview:",
      "  # TODO: leave this to backend/DAP if possible")

  suite "RV-2 — review layout wiring (source contract)":

    test "test_the_dataset_launch_loads_the_editor_layout":
      ## Deliverable 1.  The branch must load the edit-mode layout file
      ## through the review loader instead of forwarding the debugging layout
      ## `init` was handed.
      let branch = deepReviewStartupBranch()
      check branch.contains("loadReviewLayoutConfig(")
      check branch.contains("default_edit_layout.json")
      check branch.contains("layout: reviewLayout")
      # The debugging layout `init` receives must NOT be what is forwarded.
      check not branch.contains("layout: layout")

    test "test_the_review_loader_is_the_edit_loader_with_the_review_set":
      ## The editor layout is not re-implemented for reviews: it is the same
      ## loader, over the same user file, with one different argument.
      let config = source(IndexConfigPath)
      let loader = sectionBetween(config,
        "proc loadReviewLayoutConfig*(main: js, filename: string)",
        "\nproc ")
      check loader.contains(
        "loadEditLayoutConfig(main, filename, reviewModeHiddenContentIds())")

    test "test_the_review_hidden_set_is_derived_from_the_edit_one":
      ## Deliverable: the review's set is edit mode's minus the review's own
      ## pillars, computed rather than hand-listed, so the two cannot drift.
      let config = source(IndexConfigPath)
      let derived = sectionBetween(config,
        "proc reviewModeHiddenContentIds(): seq[int] =",
        "\nproc ")
      check derived.contains("editModeHiddenContentIds()")
      check derived.contains("reviewPillarContentIds()")
      check derived.contains("layout_config_repair.reviewModeHiddenContentIds(")

      let pillars = sectionBetween(config,
        "proc reviewPillarContentIds(): seq[int] =",
        "\nproc ")
      check pillars.contains("ord(Content.AgentActivity)")
      check pillars.contains("ord(Content.AgentActivityDeepReview)")
      # The Editor and the VCS panel are pillars too, but they are not in edit
      # mode's hidden set to begin with, so subtracting them would be noise
      # that hides a real regression if either is ever added to it.
      check not pillars.contains("ord(Content.EditorView)")
      check not pillars.contains("ord(Content.VCS)")

      # The rule itself lives in the dependency-free module, which is what
      # makes the behavioural suite above possible.
      check source(LayoutRepairPath).contains(
        "proc reviewModeHiddenContentIds*(editModeHidden: seq[int];")

    test "test_every_recovery_path_is_sanitised_too":
      ## Deliverable 4.  `resetLayoutToDefault` hands back the *debugging*
      ## layout; returning that raw from the edit/review loader reintroduces
      ## exactly the panels the mode excludes.  No call inside the loader may
      ## be the bare one.
      let config = source(IndexConfigPath)
      let loader = sectionBetween(config,
        "proc loadEditLayoutConfig*(main: js, filename: string;",
        "proc loadReviewLayoutConfig*")
      check not loader.contains("await resetLayoutToDefault(")
      check loader.count("resetHiddenPanelLayoutToDefault(") == 6

      let reset = sectionBetween(config,
        "proc resetHiddenPanelLayoutToDefault(filename: string;",
        "proc loadEditLayoutConfig*")
      check reset.contains("await resetLayoutToDefault(filename)")
      check reset.contains("sanitizeEditLayoutConfig(")
      check reset.contains("ord(Content.EditorView), hiddenContents)")

    test "test_launch_methods_two_and_three_keep_the_debugging_layout":
      ## Deliverable 2.  A review over a diff-associated trace, and an agentic
      ## handoff, HAVE a recording, so EVENT LOG / CALLTRACE / TIMELINE /
      ## TERMINAL OUTPUT are populated and belong.  Neither may reach the
      ## review loader, and neither may replace the layout at all.
      ## The distinction IS the assertion: it is only worth checking that
      ## these two paths kept the debugging layout because one path stopped
      ## getting it.  So the review loader must exist, and exactly one call
      ## site — the dataset launch — may use it.
      check source(IndexConfigPath).count("proc loadReviewLayoutConfig*") == 1
      check source(StartupPath).count("loadReviewLayoutConfig(") == 1

      for path in [VcsPath, AgenticLauncherPath]:
        let body = source(path)
        check not body.contains("loadReviewLayoutConfig")
        check not body.contains("default_edit_layout.json")

      # Launch method 2 assembles its dataset and calls the entry routine; it
      # touches no layout.
      let traceDiffEntry = sectionBetween(source(VcsPath),
        "proc startReviewForTraceDiff*(data: Data; diff: Diff; title: string;",
        "\nproc ")
      check traceDiffEntry.contains("startDeepReviewNavigation(data)")
      check not traceDiffEntry.contains("resolvedConfig")

      # Launch method 3 likewise.
      let handoff = sectionBetween(source(AgenticLauncherPath),
        "proc syncDeepReview(launcher: AgenticSessionLauncher) =",
        "\nproc ")
      check handoff.contains("vcs.startDeepReviewNavigation(data)")
      check not handoff.contains("resolvedConfig")

      # And the ordinary trace-loading startup paths still send the layout
      # they always sent — the debugging one.
      let traces = source(TracesPath)
      check traces.count("layout: data.layout,") == 2
      let init = sectionBetween(source(StartupPath),
        "\"CODETRACER::init\",",
        "bypass: bypass")
      check init.contains("layout: layout,")

    test "test_the_review_still_enters_through_the_one_shared_routine":
      ## Deliverable 3.  RV-2 changes which layout is loaded, not how a review
      ## is entered: all three launch methods still converge on
      ## `vcs.startDeepReviewNavigation` (DR-R7), and the dataset launch adds
      ## no second entry path alongside its new loader.
      let branch = deepReviewStartupBranch()
      # The branch gained a layout load and nothing else: it still hands the
      # renderer the same one message and configures no review state of its
      # own.  Asserting both halves together is what makes this a test of
      # "which layout, not how entered" rather than of either alone.
      check branch.contains("loadReviewLayoutConfig(")
      check not branch.contains("startDeepReviewNavigation")
      check not branch.contains("deepReviewActive")
      check branch.contains("CODETRACER::start-deepreview")

      let vcs = source(VcsPath)
      check vcs.count("proc startDeepReviewNavigation*(data: Data) =") == 1
      check source(AgenticLauncherPath).contains(
        "vcs.startDeepReviewNavigation(data)")
      check source("src/frontend/ui_js.nim").contains(
        "vcs.startDeepReviewNavigation(data)")
