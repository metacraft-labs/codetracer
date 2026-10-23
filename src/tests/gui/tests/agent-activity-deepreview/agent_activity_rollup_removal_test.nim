## AA-1 — the DeepReview roll-up is gone, and its layout identity is not.
##
## `codetracer-specs/DeepReview/Agent-Activity-Panel.milestones.org`, AA-1:
## "Remove the DeepReview section: coverage summary, test-results row,
## per-file coverage table and notification feed, along with
## `AgentActivityDeepReviewVM` and its view", and — separately — "decide and
## record whether the id itself survives".
##
## Both halves are asserted here, and they pull in opposite directions, which
## is why one file owns both: a guard that only checked for absence would be
## satisfied by deleting `Content.AgentActivityDeepReview` too, and that is
## exactly what AA-1 decided *not* to do.
##
## **The decision, recorded.**  The id survives.  Three things in the code say
## so, and each is pinned below:
##
##   1. `Content` ordinals are persisted — a saved GoldenLayout config stores
##      `componentState.content` as a number — so a layout written by an older
##      build may host a pane of content 39.  It must still construct.
##      `Content.DeepReview` (36) went the other way at DR-R8 and had to leave
##      a `RetiredDeepReviewPanel` placeholder behind to keep the enum
##      contiguous; keeping 39 alive avoids a second such stub.
##   2. `index/config.reviewPillarContentIds` names it, so review mode keeps
##      it visible where edit mode would hide it.  That rule is about the
##      Agent Activity pillar, which a review still has.
##   3. AA-2 (`ct test` run summaries) and AA-3 (evidence tool calls) both
##      keep a review role for this panel, so the identity is not dead — only
##      its contents changed.
##
## This suite is deliberately NOT a rewrite of the deleted
## `agent_activity_deepreview_vm_test.nim`.  That file tested the roll-up's
## ViewModel, which no longer exists; its behavioural claims that survive AA-1
## moved to the surfaces that still make them:
##
##   * per-file coverage       -> `materialized_review_dataset_test.nim` and
##                                the VCS suites, over
##                                `VCSFileRow.coverageText`;
##   * the aggregate coverage  -> `deepreview_entry_test.nim`, over
##                                `ReviewDataset`;
##   * "this dataset carries   -> `materialized_review_dataset_test.nim`, at
##     no test results"           the dataset level, which is where the
##                                absence actually lives;
##   * "the panel renders no   -> `isonim_views_test.nim`, which owns the
##     roll-up"                   Agent Activity panel's rendering.
##
## ## Test doubles
##
## None.  Everything asserted is either a `ReviewDataset` projection (pure) or
## a fact about the production source tree, read from disk.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/agent-activity-deepreview/agent_activity_rollup_removal_test.nim

import std/[strutils, tables, unittest]

import isonim/core/[computation, owner, signals]

import viewmodels/[review_entry, vcs_vm]

import ../deepreview/lib/review_dataset_json

proc fixtureDirPath(): string {.compileTime.} =
  let p = currentSourcePath()
  var cut = p.rfind('/')
  let backslash = p.rfind('\\')
  if backslash > cut:
    cut = backslash
  p[0 .. cut] & "../deepreview/fixtures/"

const SampleReviewJson = staticRead(fixtureDirPath() & "sample-review.json")
  ## The same dataset the DeepReview Playwright suite launches CodeTracer over.

# ---------------------------------------------------------------------------
# Behaviour: entering a review populates the VCS panel and nothing else
# ---------------------------------------------------------------------------

suite "AA-1: entering a review no longer populates a roll-up":

  test "test_review_entry_writes_only_to_the_vcs_panel":
    ## Before AA-1, `enterReview` took an `AgentActivityDeepReviewVM` and
    ## filled it with a coverage summary, a per-file table and a selection.
    ## It takes no such argument now, and the review is still complete: the
    ## changeset, the header, the trace context and the first opened file all
    ## arrive, and the per-file coverage a reviewer used to read in the
    ## roll-up is on the Changed Files row where the VCS panel spec puts it.
    createRoot proc(dispose: proc()) =
      let dataset = reviewDatasetFrom(decodeReviewDatasetJson(SampleReviewJson))
      let vcs = createVCSVM()
      var documents: seq[string] = @[]
      discard enterReview(
        vcs, dataset,
        proc(action: VCSOpenAction) =
          if action.documentKey notin documents:
            documents.add(action.documentKey),
        nil)

      check vcs.deepReviewMode.val
      check vcs.changedFiles.val.len == 3
      check documents == @["diff:file:src/main.rs"]
      # The coverage the deleted per-file table showed, on the row that now
      # carries it.  An empty badge for a file the dataset measured nothing
      # for is the honest rendering; "0/0" would read as "measured, and
      # nothing ran".
      check vcs.changedFiles.val[0].coverageText == "15/17"
      # …and the aggregate the deleted summary card showed is still derivable
      # from the dataset, so nothing was *lost* by deleting the card.
      var covered = 0
      var total = 0
      for file in dataset.files:
        covered += file.coveredLines
        total += file.totalLines
      check covered == 20
      check total == 24
      check dataset.functionsTraced == 3

      dispose()

# ---------------------------------------------------------------------------
# Source contract (native only)
# ---------------------------------------------------------------------------

when not defined(js):
  ## `Content`, the component registry and the stylesheet live in modules that
  ## need Electron (or a stylus build) to run, so reading them is the only way
  ## to assert headlessly which half of AA-1 landed on which symbol.  Same
  ## pattern as `deepreview_entry_test.nim`'s source-contract suite.
  import std/os

  proc contractSource(path: string): string =
    ## `readFile` raising here is the right failure: it means a production
    ## file this contract describes was moved or deleted.
    readFile(path)

  const RollupClassPrefix = "activity-dr-"
    ## Every one of the roll-up's 45 classes starts with this, hyphen
    ## included, and nothing that survived AA-1 does.

  proc nimJsByteArray(s: string): string =
    ## The body of the array literal the Nim JS backend emits for `s`:
    ## `"ab"` -> `"97,98"`.  The debug `ui.js` spells most string constants
    ## this way rather than as a JS string — measured on a debug build of
    ## codetracer `06c0f829b` (2026-10-23), where the Agent Activity container
    ## class is emitted as `[99,111,…,32,97,103,101,110,116,45,104,97,45,…]`
    ## and the text `agent-ha-container` occurs nowhere in the bundle.
    var parts: seq[string] = @[]
    for c in s:
      parts.add($ord(c))
    parts.join(",")

  const RollupClassBoundaries = ['.', '"', '\'', '`', ' ']
    ## The characters a class name can follow: a selector's `.`, a string
    ## literal's opening quote, and the space separating two classes in one
    ## attribute value or two compound selectors.

  proc rollupClassForms(): seq[string] =
    ## The shapes a roll-up class takes in a built artefact: the prefix after
    ## each of `RollupClassBoundaries`, spelled both as text and as a Nim
    ## byte array (`46` + the prefix's bytes for `.`, `32` for a space, …,
    ## opening the array with `[` or following an element with `,`), plus
    ## the prefix as the first element (`[`) of a byte array.  The
    ## byte-array `.` is not hypothetical: the debug `ui.js` emits selector
    ## strings such as `".agent-user-copy-button[data-id='"` and
    ## `" .editor-textarea"` as `[46,97,…]` and `[…,32,46,101,…]`.
    ##
    ## The bare prefix is NOT one of them, and must not be: the debug
    ## `ui.js` carries the absolute path of every source in `/* line N
    ## "<path>" */` comments, so a checkout under a directory such as
    ## `fix-agent-activity-drops-…` put `activity-dr` in the bundle 82231
    ## times without a single class behind it
    ## (codetracer-pm `issues/2026-10-21-rollup-removal-artefact-check-matches-the-checkout-path.md`).
    ## A path component reaches the prefix after `/` or `-`, and neither is
    ## a class boundary.  Only a directory whose own name begins with
    ## `.activity-dr-` (or contains ` activity-dr-`) could still collide.
    let bytes = nimJsByteArray(RollupClassPrefix)
    result = @["[" & bytes]
    for boundary in RollupClassBoundaries:
      result.add(boundary & RollupClassPrefix)
      for opener in ["[", ","]:
        result.add(opener & $ord(boundary) & "," & bytes)

  proc rollupClassesIn(contents: string): seq[string] =
    ## The roll-up class forms present in `contents`; empty when the
    ## artefact carries none, whatever paths it embeds.
    for form in rollupClassForms():
      if form in contents:
        result.add(form)

  suite "AA-1: recognising a roll-up class in a built artefact":
    ## The matcher behind `test_the_rollup_is_absent_from_the_built_artefacts`,
    ## held to both halves of its job: a checkout path never counts, and
    ## every form a class actually takes does.  Without the second half the
    ## first is satisfied by a matcher that recognises nothing.

    test "test_a_checkout_path_is_not_a_rollup_class":
      let dir = "/home/u/m/fixes/fix-agent-activity-drops-a-rejected-acp-prom"
      for contents in [
          # The line comment the debug `ui.js` puts on every statement.
          "if (x == 0){ /* line 858:7 \"" & dir &
            "/codetracer/src/frontend/ui/vcs.nim\" */",
          # The same path as a Nim string constant and as a byte array.
          "makeNimstrLit(\"" & dir & "/codetracer/src/x.nim\")",
          "[" & nimJsByteArray(dir & "/x.nim") & "]",
          # A directory named for the prefix itself, hyphen and all.
          "/* line 1:1 \"/home/u/activity-dr-scratch/codetracer/x.nim\" */",
          "/* line 1:1 \"/home/u/agent-activity-dr-x/codetracer/x.nim\" */"]:
        check rollupClassesIn(contents).len == 0

    test "test_every_form_of_a_rollup_class_is_recognised":
      for contents in [
          ".activity-dr-summary { color: red; }",
          "el.className = \"activity-dr-files\";",
          "el.querySelector('.activity-dr-files-row')",
          "makeNimstrLit(\"component-container activity-dr-panel\")",
          "x = `activity-dr-${name}`",
          "setAttribute([99,108,97,115,115], [" &
            nimJsByteArray("activity-dr-summary") & "]);",
          "setAttribute([99,108,97,115,115], [" &
            nimJsByteArray("component-container activity-dr-panel") & "]);",
          # Selectors, which the bundle also spells as byte arrays: alone,
          # and as the descendant half of a compound selector.
          "querySelector(toJSStr([" &
            nimJsByteArray(".activity-dr-files-row") & "]))",
          "querySelector(toJSStr([" &
            nimJsByteArray(".agent-ha-container .activity-dr-body") & "]))"]:
        check rollupClassesIn(contents).len > 0

  suite "AA-1: the id survives the deletion (source contract)":

    test "test_the_content_id_and_its_component_survive":
      let frontend = contractSource(
        "src/common/common_types/codetracer_features/frontend.nim")
      check frontend.contains("AgentActivityDeepReview = 39")

      # The review keeps the pane visible where an editing session hides it.
      let config = contractSource("src/frontend/index/config.nim")
      check config.contains("ord(Content.AgentActivityDeepReview)")

      # A layout persisted by an older build still constructs its component
      # rather than raising out of `makeComponent`'s catch-all.
      let utils = contractSource("src/frontend/utils.nim")
      check utils.contains("makeAgentActivityDeepReviewComponent")
      check utils.contains(
        "of Content.AgentActivityDeepReview: " &
        "data.makeAgentActivityDeepReviewComponent(id)")

      # …and it is still a direct-mount component, so the pane comes up empty
      # rather than with a stale Karax rendering.
      let layout = contractSource("src/frontend/ui/layout.nim")
      check layout.contains("Content.AgentActivityDeepReview")

  suite "AA-1: the roll-up is gone (source contract)":

    test "test_the_rollup_modules_are_off_disk":
      for path in [
          "src/frontend/ui/agent_activity_deepreview.nim",
          "src/frontend/viewmodel/viewmodels/agent_activity_deepreview_vm.nim",
          "src/frontend/viewmodel/views/isonim_agent_activity_deepreview_view.nim",
          "src/frontend/styles/components/agent_activity_deepreview.styl"]:
        check not fileExists(path)
      # `DeepReviewVM` is architecture, not the roll-up: `AgenticSessionVM`
      # composes it, so it stays.  Naming it here is what keeps a future
      # deletion from taking the wrong DeepReview again.
      check fileExists("src/frontend/viewmodel/viewmodels/deepreview_vm.nim")

    test "test_the_rollup_symbols_are_gone_from_the_wiring":
      let wiring = {
        "src/frontend/ui/vcs.nim": @[
          "agent_activity_deepreview", "syncActivitySelectionFromVCS",
          "handleActivityFileSelection"],
        "src/frontend/ui/agent_activity.nim": @[
          "agent_activity_deepreview", "AgentActivityDeepReviewCallbacks"],
        "src/frontend/ui_js.nim": @[
          "agent_activity_deepreview"],
        "src/frontend/ui/layout.nim": @[
          "tryMountIsoNimAgentActivityDeepReviewPanel"],
        "src/frontend/viewmodel/viewmodels/review_entry.nim": @[
          "populateReviewActivity", "reviewCoverageSummary", "coverageRows",
          "AgentActivityDeepReviewVM"],
        "src/frontend/viewmodel/store/types.nim": @[
          "AgentDeepReviewCoverageSummary", "AgentDeepReviewTestResults",
          "AgentDeepReviewFileCoverage", "AgentDeepReviewNotification"],
        "src/frontend/viewmodel/collab/signal_registry.nim": @[
          "AgentActivityDeepReviewVM"],
        "src/frontend/viewmodel/views/isonim_agent_activity_view.nim": @[
          "AgentActivityDeepReviewVM", "agent-ha-deepreview-host"],
        "src/frontend/storybook_components.nim": @[
          "agent-activity-deepreview"],
      }.toTable
      for path, symbols in wiring:
        let contents = contractSource(path)
        for symbol in symbols:
          check not contents.contains(symbol)

    test "test_the_rollup_stylesheet_has_no_producer_left":
      ## The stylesheet went because its selectors lost their only producer,
      ## measured rather than assumed: 35 of the 45 `activity-dr-*` classes in
      ## `components/agent_activity_deepreview.styl` were emitted by the
      ## deleted view and read by its tests, and **ten had no producer even
      ## before AA-1** — `activity-dr-coverage-bar`, `-bar-fill`,
      ## `activity-dr-files-col-bar` and the four `coverage-bar-*` modifiers
      ## (never-built per-row graphics), plus
      ## `activity-dr-test-{status,name,duration}`, Karax-era spans the IsoNim
      ## port flattened away while `agentic-page.ts` kept reading
      ## `.textContent()` off them.
      let codetracer = contractSource("src/frontend/styles/codetracer.styl")
      check not codetracer.contains("agent_activity_deepreview")
      let agentActivity = contractSource(
        "src/frontend/styles/components/agent_activity.styl")
      check not agentActivity.contains("agent-ha-deepreview-host")

    test "test_the_rollup_is_absent_from_the_built_artefacts":
      ## The build tree is what a screenshot photographs and what a launched
      ## `ct` loads, so the absence is asserted there too — sources can be
      ## clean while a stale bundle still draws the pane.
      ##
      ## Skipped, loudly, when the tree has not been built: this suite also
      ## runs in the release gate, which has no build tree, and a missing
      ## artefact is not evidence either way.
      ## The check covers the whole `activity-dr-` prefix rather than one
      ## class: with the view gone not a single one of the 45 has a producer,
      ## so any class at all means a stale bundle or a resurrected pane.  It
      ## matches the prefix only where a class can start (`rollupClassesIn`),
      ## because the bundle also embeds the checkout's own path.
      for artefact in [
          "src/build-debug/ui.js",
          "src/build-debug/frontend/styles/default_dark_theme_electron.css"]:
        if not fileExists(artefact):
          echo "  (skipped: no ", artefact, " — run `just build-once`)"
          continue
        let found = rollupClassesIn(readFile(artefact))
        checkpoint(artefact & " carries " & $found)
        check found.len == 0
