## `ct review` — the whole DeepReview command-line surface (RV-1).
##
## RV-1 of `codetracer-specs/DeepReview/Review-Command.milestones.org` makes
## `ct review` the only way a user reaches DeepReview from a shell, and retires
## the two older spellings outright:
##
##   * the global `ct --deepreview <PATH>` option, and
##   * the `ct-native-replay deepreview {collect,export,inspect}` group.
##
## Everything that decides what a `ct review` line *means* lives in
## `src/ct/review_cli.nim` as a pure function of argv, precisely so it can be
## asserted here without launching Electron and without a native backend
## installed.  Before RV-1 the equivalent behaviour was one confutils field
## whose only observable effect was spawning a GUI, which is why the launch
## path had no headless coverage at all.
##
## Four layers, matching the milestones' verification entries:
##
##   * **Dispatch** — `review` resolves to launch, collect or inspect, and the
##     collect verb translates into the native collector's own argv.  The argv
##     is asserted as data rather than by running the collector: the
##     translation is the part that can silently rot, and it must be checkable
##     on a machine that has no `ct-native-replay`.
##   * **Routing** (RV-3) — `collect` inspects the recordings it was given and
##     chooses the collector that can read them, and the user never names a
##     backend.  Asserted at two levels for two different failure modes: the
##     rules that say what a recording *is*
##     (`src/ct/trace/trace_kind.nim`), and the route those rules produce
##     (`routeReviewCollect`).  Both are pure, so the whole dispatch table is
##     checkable with no recording, no collector and — on the `nim js`
##     backend — no filesystem at all.  What made this worth its own layer:
##     before RV-3, `ct review collect --recordings <a Python recording>`
##     printed "Review dataset ready" and exited 0 over an empty dataset.
##   * **Retirement** — the old spellings fail, and the failure names
##     `ct review`.  A retirement whose diagnostic says only "unrecognized
##     option" is the failure mode `Retired-Names.md` exists to prevent.
##   * **Source contract** (native only) — that the production wiring really
##     is what the dispatch assumes: the `deepreview` option is gone from
##     `CodetracerConf`, `review` is declared in its place, `codetracer.nim`
##     intercepts the verbs ahead of confutils, and the Playwright fixture
##     launches the new spelling.  Those files need confutils, Electron and a
##     browser, so reading them is the only way to assert the wiring
##     headlessly — the same technique `deepreview_layout_test.nim` and
##     `deepreview_entry_test.nim` already use.  RV-3 adds one more source
##     contract: `ct replay` must keep using the *shared* trace-kind rules
##     rather than growing a private copy back, which is the only way a
##     "one rule, one place" claim stays true after the commit that made it.
##
## Mocking justification (workspace policy): there is no mock in this file.
## The planner is production code called directly; the filesystem suite uses a
## real temporary directory; the source-contract suite reads the real sources.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/deepreview/ct_review_cli_test.nim
##   nim js -r src/tests/gui/tests/deepreview/ct_review_cli_test.nim

import std/[strutils, unittest]

import ../../../../ct/review_cli

suite "ct review — dispatch":
  test "review_dispatches_the_launch_form":
    let plan = planReviewCli(@["review", "/tmp/reviews/review.json"])
    check plan.kind == rpkLaunch
    check plan.datasetPath == "/tmp/reviews/review.json"

  test "review_dispatches_collect_and_translates_the_collector_argv":
    let plan = planReviewCli(@["review", "collect",
      "--repo", "/src/project",
      "--diff", "main..HEAD",
      "--recordings", "/tmp/recordings",
      "--output", "/tmp/out",
      "--preset", "comprehensive",
      "--progress"])
    check plan.kind == rpkCollect
    check plan.outputDir == "/tmp/out"
    check plan.collectorArgs == @["collect",
      "--repo", "/src/project",
      "--diff", "main..HEAD",
      "--recordings", "/tmp/recordings",
      "--output", "/tmp/out",
      "--preset", "comprehensive",
      "--progress"]

  test "collect_accepts_a_diff_file_instead_of_a_repository":
    let plan = planReviewCli(@["review", "collect",
      "--diff-file", "/tmp/changes.patch",
      "--recordings", "/tmp/recordings",
      "-o", "/tmp/out"])
    check plan.kind == rpkCollect
    check plan.collectorArgs == @["collect",
      "--diff-file", "/tmp/changes.patch",
      "--recordings", "/tmp/recordings",
      "--output", "/tmp/out"]

  test "collect_accepts_the_equals_spelling_of_every_option":
    let plan = planReviewCli(@["review", "collect",
      "--repo=/src/project", "--diff=main..HEAD",
      "--recordings=/tmp/recordings", "--output=/tmp/out"])
    check plan.kind == rpkCollect
    check plan.collectorArgs == @["collect",
      "--repo", "/src/project", "--diff", "main..HEAD",
      "--recordings", "/tmp/recordings", "--output", "/tmp/out"]

  test "review_dispatches_inspect_with_its_format":
    var plan = planReviewCli(@["review", "inspect", "/tmp/out"])
    check plan.kind == rpkInspect
    check plan.inspectPath == "/tmp/out"
    check plan.inspectFormat == "text"

    plan = planReviewCli(@["review", "inspect", "/tmp/out", "--format", "json"])
    check plan.kind == rpkInspect
    check plan.inspectFormat == "json"

  test "help_is_a_plan_not_an_error":
    for line in [@["review", "--help"], @["review", "-h"],
        @["review", "collect", "--help"], @["review", "inspect", "--help"]]:
      checkpoint(line.join(" "))
      check planReviewCli(line).kind == rpkUsage

  test "only_the_flag_carrying_verbs_bypass_confutils":
    # The launch form must stay an ordinary confutils command so it keeps ct's
    # global options (`--inspect`, `--remote-debugging-port`) that Playwright
    # and the Electron tooling inject.  Intercepting it too would silently
    # drop them.
    check not reviewNeedsRawDispatch(@["review", "/tmp/review.json"])
    check not reviewNeedsRawDispatch(@["review"])
    check reviewNeedsRawDispatch(@["review", "collect", "--output", "/tmp/o"])
    check reviewNeedsRawDispatch(@["review", "inspect", "/tmp/o"])
    check reviewNeedsRawDispatch(@["review", "export", "/tmp/o"])
    check not reviewNeedsRawDispatch(@["edit", "collect"])

  test "asking_the_group_for_help_gets_the_whole_group":
    # RV-2, from RV-1's verification.  `--help` used to be left to confutils,
    # which knows only the shape `review` was declared with and answered
    # `ct review <reviewPath>` — never naming `collect` or `inspect`.  Only
    # bare `ct review` printed the group usage, so the two other commands of
    # the group were undiscoverable from the group itself.
    check reviewNeedsRawDispatch(@["review", "--help"])
    check reviewNeedsRawDispatch(@["review", "-h"])
    check reviewNeedsRawDispatch(@["review", "help"])
    # ...and what they get is the whole group.
    for tokens in [@["review", "--help"], @["review", "-h"],
                   @["review", "help"]]:
      let plan = planReviewCli(tokens)
      check plan.kind == rpkUsage
    # A dataset path that merely *looks* like a help token is not one; only
    # the exact tokens are intercepted, so `ct review ./help` still launches.
    check not reviewNeedsRawDispatch(@["review", "./help"])
    check not reviewNeedsRawDispatch(@["review", "--helpful"])

  test "the_group_usage_names_every_command_of_the_group":
    check ReviewUsage.contains("ct review <PATH>")
    check ReviewUsage.contains("ct review collect")
    check ReviewUsage.contains("ct review inspect")

  test "a_global_option_after_the_dataset_path_is_left_to_confutils":
    # Regression: the interception used to claim the launch form as soon as a
    # second token followed the path, which made
    # `ct review DIR --remote-debugging-port=0` fail with "exactly one dataset
    # path" — the option Playwright and the Electron tooling inject, and one
    # CLI-Reference.md §3.1 promises works here exactly as it does for
    # `ct edit`.  ct's global options are the parser's business, so the line
    # must reach it.
    check not reviewNeedsRawDispatch(
      @["review", "/tmp/out", "--remote-debugging-port=0"])
    check not reviewNeedsRawDispatch(@["review", "/tmp/out", "--inspect"])
    check not reviewNeedsRawDispatch(@["review", "/tmp/out", "--cwd", "/src"])
    # Extra positionals are still refused — by confutils ("The subcommand
    # 'review' does not accept additional arguments"), which is the same
    # answer `ct edit` gives, rather than by a second opinion here.
    check not reviewNeedsRawDispatch(@["review", "/tmp/a.json", "/tmp/b.json"])

suite "trace kinds — one rule for what a recording is":
  # RV-3 requires `collect` to reuse the existing trace-kind machinery rather
  # than invent a second notion of what a recording is.  These cases assert
  # the rules themselves, as evidence rather than as paths, so they hold on
  # both Nim backends and describe exactly which fact decides which answer.

  proc evidence(isDirectory = true, pathIsCtContainer = false,
                hasMcrMarker = false, hasRrVersionFile = false,
                holdsCtContainer = false,
                holdsMaterializedIndex = false): TraceEvidence =
    TraceEvidence(name: "rec", isDirectory: isDirectory,
      pathIsCtContainer: pathIsCtContainer, hasMcrMarker: hasMcrMarker,
      hasRrVersionFile: hasRrVersionFile, holdsCtContainer: holdsCtContainer,
      holdsMaterializedIndex: holdsMaterializedIndex)

  test "an_rr_trace_directory_is_native":
    # rr writes `version` in every trace it records, and it is the same rule
    # the native collector already discovers recordings by, so ct's dispatch
    # and the collector's own discovery cannot disagree about what it will
    # find.
    check traceKindFromEvidence(evidence(hasRrVersionFile = true)) == ctkNative

  test "a_ct_container_is_native_when_the_path_itself_is_one":
    check traceKindFromEvidence(
      evidence(isDirectory = false, pathIsCtContainer = true)) == ctkNative

  test "the_mcr_marker_decides_the_ambiguous_ct_container":
    # Native MCR recordings and materialized traces share the CTFS container,
    # so the container alone cannot answer.  The marker is what `ct replay`
    # has always used to tell them apart, and RV-3 reuses that rather than
    # ruling on it a second time.
    check traceKindFromEvidence(
      evidence(holdsCtContainer = true, hasMcrMarker = true)) == ctkNative
    check traceKindFromEvidence(
      evidence(holdsCtContainer = true)) == ctkMaterialized

  test "the_pre_ctfs_three_file_layout_is_materialized":
    # `trace_metadata.json` + `trace.bin`, which is what the recordings in
    # codetracer-example-recordings/python still are.
    check traceKindFromEvidence(
      evidence(holdsMaterializedIndex = true)) == ctkMaterialized

  test "a_folder_with_no_evidence_is_not_a_recording":
    # The value that did not exist before RV-3, and the reason
    # `--recordings ~/src` used to produce an empty dataset and exit 0: with
    # only "rr" and "db" to choose from, every directory was a recording.
    check traceKindFromEvidence(evidence()) == ctkUnknown
    check traceKindFromEvidence(evidence(isDirectory = false)) == ctkUnknown

  test "the_replay_side_default_is_unchanged":
    # `ct replay` asks a different question — "which backend opens this trace
    # I was told is a trace" — and its long-standing answer for a folder it
    # cannot identify is "rr", whose metadata comes from meta.dat.  Moving
    # the rules into a shared module must not change that.
    check traceKindString(ctkNative) == TraceKindNative
    check traceKindString(ctkMaterialized) == TraceKindMaterialized
    check traceKindString(ctkUnknown) == TraceKindNative

  test "every_kind_can_be_named_to_a_user":
    # A refusal has to name the kind it could not handle, so every value must
    # have a label and no two may share one.
    var labels: seq[string] = @[]
    for kind in CtTraceKind:
      let label = traceKindLabel(kind)
      check label.len > 0
      check label notin labels
      labels.add label
    check traceKindLabel(ctkMaterialized).contains("materialized")
    check traceKindLabel(ctkNative).contains("rr")

suite "ct review collect — the collector is chosen by inspecting the recordings":
  # RV-3.  DeepReview-GUI.md §1.1: "A collector is chosen by inspecting the
  # recording, never by the user naming a backend."

  proc survey(pairs: openArray[(string, CtTraceKind)]):
             seq[RecordingSurveyEntry] =
    result = @[]
    for (name, kind) in pairs:
      result.add RecordingSurveyEntry(name: name, kind: kind)

  test "collect_carries_the_recordings_directory_into_the_dispatch":
    # The dispatch inspects `--recordings` before any collector is chosen, so
    # the plan has to carry it rather than leave the executor to find it
    # again by re-reading the collector's argv.
    let plan = planReviewCli(@["review", "collect",
      "--repo", "/src", "--diff", "a..b",
      "--recordings", "/tmp/recordings", "-o", "/tmp/out"])
    check plan.kind == rpkCollect
    check plan.recordingsDir == "/tmp/recordings"

  test "native_recordings_route_to_the_native_collector":
    let route = routeReviewCollect("/tmp/rec",
      survey({"app-0": ctkNative, "app-1": ctkNative}))
    check route.collector == rcvNative
    check canCollect(route)
    check route.message == ""
    check route.kinds == {ctkNative}

  test "materialized_recordings_route_to_the_db_backend_collector":
    # RV-3 named this collector and refused, because it did not exist.  RV-4
    # implements it, so the route is takeable and carries no message — the
    # change §1.1 asks for: "DeepReview is not an rr-only feature."
    let route = routeReviewCollect("/tmp/rec",
      survey({"py-0": ctkMaterialized, "py-1": ctkMaterialized}))
    check route.collector == rcvMaterialized
    check canCollect(route)
    check route.message == ""
    check route.kinds == {ctkMaterialized}

  test "the_materialized_route_translates_to_the_db_backends_own_argv":
    # The seam decides *whether* a collector runs; this is *how* it is called.
    # Held as a pure function of the plan so it is assertable on either Nim
    # backend with no collector installed, exactly as the native translation
    # is.
    let plan = planReviewCli(@["review", "collect",
      "--repo", "/src", "--diff", "main..HEAD",
      "--recordings", "/tmp/rec", "-o", "/tmp/out",
      "--preset", "comprehensive", "--progress"])
    check plan.kind == rpkCollect
    check materializedCollectorArgs(plan) == @[
      "review-collect", "--repo", "/src", "--diff", "main..HEAD",
      "--recordings", "/tmp/rec", "--output", "/tmp/out",
      "--preset", "comprehensive", "--progress"]
    # The verb is the db-backend's, not the native binary's hidden group.
    check materializedCollectorArgs(plan)[0] == ReplayServerReviewCollectVerb
    check not materializedCollectorArgs(plan).contains(
      NativeReplayReviewDataGroup)

  test "a_materialized_collection_from_a_patch_file_forwards_the_patch":
    # `--diff-file` names no commits, so the dataset carries none; the
    # repository is still forwarded when the user gave one, because the
    # patch's paths are relative to it.
    let withRepo = planReviewCli(@["review", "collect",
      "--diff-file", "/tmp/p.patch", "--recordings", "/rec", "-o", "/out"])
    check materializedCollectorArgs(withRepo) == @[
      "review-collect", "--diff-file", "/tmp/p.patch",
      "--recordings", "/rec", "--output", "/out"]
    check not materializedCollectorArgs(withRepo).contains("--diff")

  test "the_two_collectors_are_handed_the_same_options_under_their_own_names":
    # One parse, two translations: a user who types `--recordings X --output Y`
    # must reach either collector with X and Y, or the seam would change what
    # the command means depending on what was recorded.
    let plan = planReviewCli(@["review", "collect",
      "--diff-file", "/tmp/p.patch", "--recordings", "/rec", "-o", "/out"])
    for argv in [plan.collectorArgs, materializedCollectorArgs(plan)]:
      check argv.contains("/rec")
      check argv.contains("/tmp/p.patch")
      check argv.contains("/out")
    # They differ only in the verb and in the flag naming the output.
    check plan.collectorArgs[0] == "collect"
    check materializedCollectorArgs(plan)[0] == "review-collect"

  test "a_mixed_recordings_directory_is_refused_and_names_both_kinds":
    # The decision recorded in RV-3's judgement calls: refuse, rather than
    # collect per kind and merge.  With one collector implemented, "merge"
    # could only mean "collect the native ones and drop the rest".
    let route = routeReviewCollect("/tmp/rec",
      survey({"app-0": ctkNative, "py-0": ctkMaterialized}))
    check route.collector == rcvNone
    check not canCollect(route)
    check route.kinds == {ctkNative, ctkMaterialized}
    check route.message.contains("mixed")
    check route.message.contains(traceKindLabel(ctkNative))
    check route.message.contains(traceKindLabel(ctkMaterialized))
    check route.message.contains("app-0")
    check route.message.contains("py-0")

  test "an_empty_recordings_directory_is_refused_and_says_it_is_empty":
    # Before RV-3 this printed "Review dataset ready" and exited 0.
    let route = routeReviewCollect("/tmp/rec", newSeq[RecordingSurveyEntry]())
    check route.collector == rcvNone
    check not canCollect(route)
    check route.message.contains("no recordings")
    check route.message.contains("empty")
    check route.message.contains("/tmp/rec")

  test "a_directory_holding_no_recordings_says_what_it_does_hold":
    # A different mistake from an empty directory — almost always a path
    # typed one level too high — and so a different message.
    let route = routeReviewCollect("/home/me/src",
      survey({"README.md": ctkUnknown, "src": ctkUnknown,
              "Cargo.toml": ctkUnknown}))
    check route.collector == rcvNone
    check route.message.contains("no recordings")
    check not route.message.contains("empty")
    check route.message.contains("3 entries")
    check route.message.contains("README.md")
    # and it says what it was looking for, in terms the user can check.
    check route.message.contains("version")
    check route.message.contains(".ct")

  test "entries_that_are_not_recordings_do_not_stop_a_collection":
    # A recordings directory routinely carries a `.gitignore`, a log or a
    # README beside the recordings; failing over those would be hostile.
    let route = routeReviewCollect("/tmp/rec",
      survey({"README.md": ctkUnknown, "app-0": ctkNative,
              "collect.log": ctkUnknown}))
    check route.collector == rcvNative
    check canCollect(route)

  test "a_route_is_takeable_only_when_its_collector_exists":
    # `canCollect` is the single question the executor asks, so a collector
    # that is named but not implemented cannot be run by accident.
    check canCollect(CollectRoute(collector: rcvNative))
    check canCollect(CollectRoute(collector: rcvMaterialized))
    check not canCollect(CollectRoute(collector: rcvNone, message: "x"))
    # The "named but not runnable" state still exists and is still refused —
    # RV-4 filled the materialized arm, it did not remove the mechanism a
    # future trace kind would be refused by.
    check not canCollect(
      CollectRoute(collector: rcvMaterialized, message: "not yet"))

  test "a_missing_recordings_directory_names_the_path_and_what_it_should_be":
    # Diagnosed by ct rather than left to the collector, which answered with
    # a Rust Debug rendering of its own error type:
    #   Error: Custom { kind: Other, error: "invalid data: recordings ...
    let message = missingRecordingsDirMessage("/tmp/nope")
    check message.contains("/tmp/nope")
    check message.contains("--recordings")

  test "the_user_still_never_names_a_backend":
    # RV-3 is what makes §1.1's prohibition affordable: now that the
    # recording decides, there is no reason for a flag, and there is still
    # none in the surface.
    check not ReviewUsage.contains("--backend")
    let plan = planReviewCli(@["review", "collect", "--backend", "db",
      "--repo", "/src", "--diff", "a..b", "--recordings", "/rec", "-o", "/o"])
    check plan.kind == rpkError
    check plan.message.contains("--backend")

suite "ct review — the retired spellings":
  test "the_deepreview_option_is_detected_only_where_it_could_ever_have_worked":
    # `--deepreview` was a *global* option of ct, and confutils honours global
    # options only ahead of the subcommand.  Reporting it anywhere else would
    # hijack a recorded program's own flags.
    check retiredDeepReviewArgIndex(@["--deepreview", "/tmp/x.json"]) == 0
    check retiredDeepReviewArgIndex(@["--deepreview=/tmp/x.json"]) == 0
    check retiredDeepReviewArgIndex(@["--cwd", "/src", "--deepreview",
      "/tmp/x.json"]) == 2
    check retiredDeepReviewArgIndex(@[]) == -1
    check retiredDeepReviewArgIndex(@["review", "/tmp/x.json"]) == -1
    # a recorded program's own `--deepreview` is the child's, not ct's
    check retiredDeepReviewArgIndex(@["record", "./prog", "--deepreview",
      "x"]) == -1
    check retiredDeepReviewArgIndex(@["record", "--", "./prog",
      "--deepreview"]) == -1

  test "the_retirement_message_names_the_replacement":
    let message = retiredDeepReviewMessage()
    check message.contains("--deepreview")
    check message.contains("retired")
    check message.contains("ct review <PATH>")
    check message.contains("ct review collect")
    check message.contains("ct review inspect")

  test "the_retired_option_typed_as_a_review_argument_still_points_at_review":
    let plan = planReviewCli(@["review", "--deepreview", "/tmp/x.json"])
    check plan.kind == rpkError
    check plan.message.contains("ct review <PATH>")

  test "review_export_says_collect_already_wrote_the_json":
    # `export` was the third retired verb.  Its capability did not disappear —
    # `collect` performs it — so the diagnostic has to say that rather than
    # merely reject the word.
    let plan = planReviewCli(@["review", "export", "/tmp/out"])
    check plan.kind == rpkError
    check plan.message.contains(ReviewDatasetJsonName)
    check plan.message.contains("ct review collect")

suite "ct review — argument errors are specific":
  test "collect_requires_an_output_directory":
    let plan = planReviewCli(@["review", "collect",
      "--repo", "/src", "--diff", "a..b", "--recordings", "/rec"])
    check plan.kind == rpkError
    check plan.message.contains("--output")

  test "collect_requires_recordings":
    let plan = planReviewCli(@["review", "collect",
      "--repo", "/src", "--diff", "a..b", "-o", "/out"])
    check plan.kind == rpkError
    check plan.message.contains("--recordings")

  test "collect_requires_a_diff_source":
    let plan = planReviewCli(@["review", "collect",
      "--recordings", "/rec", "-o", "/out"])
    check plan.kind == rpkError
    check plan.message.contains("--diff-file")
    check plan.message.contains("--repo")

  test "collect_refuses_two_ways_of_naming_one_diff":
    let plan = planReviewCli(@["review", "collect",
      "--repo", "/src", "--diff", "a..b", "--diff-file", "/p.patch",
      "--recordings", "/rec", "-o", "/out"])
    check plan.kind == rpkError
    check plan.message.contains("--diff-file")

  test "collect_rejects_a_diff_spec_without_a_range":
    let plan = planReviewCli(@["review", "collect",
      "--repo", "/src", "--diff", "main", "--recordings", "/rec", "-o", "/o"])
    check plan.kind == rpkError
    check plan.message.contains("BASE..HEAD")

  test "collect_never_offers_a_backend_flag":
    # DeepReview-GUI.md §1.1: "A collector is chosen by inspecting the
    # recording, never by the user naming a backend."  RV-3 adds the
    # inspection; the flag must not exist in the meantime either, or the
    # surface it forbids will already be shipped.
    let plan = planReviewCli(@["review", "collect", "--backend", "native",
      "--repo", "/src", "--diff", "a..b", "--recordings", "/rec", "-o", "/o"])
    check plan.kind == rpkError
    check plan.message.contains("--backend")
    check not ReviewUsage.contains("--backend")

  test "inspect_rejects_an_unknown_format":
    let plan = planReviewCli(@["review", "inspect", "/out", "--format", "yaml"])
    check plan.kind == rpkError
    check plan.message.contains("yaml")

  test "inspect_needs_exactly_one_path":
    check planReviewCli(@["review", "inspect"]).kind == rpkError
    check planReviewCli(@["review", "inspect", "/a", "/b"]).kind == rpkError

  test "an_empty_review_argument_reports_usage_rather_than_a_missing_file":
    # confutils fills an omitted argument with "", so this is the shape
    # `ct review` with nothing after it actually arrives in.
    let plan = planReviewCli(@["review", ""])
    check plan.kind == rpkError
    check plan.message.contains("ct review collect")

when not defined(js):
  import std/[os, sequtils, strutils as nativeStrutils]

  proc repoRoot(): string =
    ## ``<repo>/src/tests/gui/tests/deepreview`` -> ``<repo>``
    currentSourcePath.parentDir.parentDir.parentDir.parentDir.parentDir
      .parentDir

  proc readSource(relative: string): string =
    let path = repoRoot() / relative
    check fileExists(path)
    if fileExists(path): readFile(path) else: ""

  suite "ct review — resolving a dataset on disk":
    test "a_json_file_resolves_to_itself":
      let dir = getTempDir() / "ct-review-cli-test-file"
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      let json = dir / "exported.json"
      writeFile(json, "{}")
      let resolved = resolveReviewDatasetJson(json)
      check resolved.error == ""
      check resolved.jsonPath == json

    test "a_collect_output_directory_resolves_to_the_json_inside_it":
      # This is the whole point of `collect` writing JSON: the directory the
      # user passed to `--output` is openable with `ct review` directly, with
      # no export step in between.
      let dir = getTempDir() / "ct-review-cli-test-dir"
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      writeFile(dir / ReviewDatasetJsonName, "{}")
      let resolved = resolveReviewDatasetJson(dir)
      check resolved.error == ""
      check resolved.jsonPath == dir / ReviewDatasetJsonName

    test "a_directory_without_a_dataset_says_so_and_says_how_to_get_one":
      let dir = getTempDir() / "ct-review-cli-test-empty"
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      let resolved = resolveReviewDatasetJson(dir)
      check resolved.jsonPath == ""
      check resolved.error.contains(ReviewDatasetJsonName)
      check resolved.error.contains("ct review collect")

    test "a_missing_path_is_diagnosed_here_not_inside_electron":
      # `--deepreview` used to hand whatever it was given straight to the
      # renderer, which `JSON.parse`d a failed read and died with a stack
      # trace naming nothing the user had typed.
      let resolved = resolveReviewDatasetJson(
        getTempDir() / "ct-review-cli-test-absent.json")
      check resolved.jsonPath == ""
      check resolved.error.contains("ct-review-cli-test-absent.json")

    test "a_missing_native_backend_names_itself_and_the_remedy":
      let message = missingNativeReplayMessage("collect")
      check message.contains("ct-native-replay")
      check message.contains(NativeReplayExeEnvVar)

  suite "ct review collect — surveying real recordings on disk":
    # The suite above asserts the *rules*; this one asserts that the rules are
    # applied to what is actually on a filesystem — real directories, real
    # marker files, no doubles.  The two halves fail in different ways: a
    # wrong rule, versus a rule that is never reached because the evidence was
    # gathered from the wrong place.

    proc makeRecordings(name: string): string =
      result = getTempDir() / name
      removeDir(result)
      createDir(result)

    proc rrTrace(parent, name: string): string =
      result = parent / name
      createDir(result)
      # rr writes `version` into every trace directory it records.
      writeFile(result / "version", "7\n")

    proc materializedTrace(parent, name: string): string =
      result = parent / name
      createDir(result)
      # The pre-CTFS layout the example Python recordings still use.
      writeFile(result / "trace_metadata.json", "{}")
      writeFile(result / "trace.bin", "")

    proc ctfsTrace(parent, name: string): string =
      result = parent / name
      createDir(result)
      writeFile(result / "trace.ct", "")

    test "an_rr_trace_directory_on_disk_routes_to_the_native_collector":
      let dir = makeRecordings("ct-review-survey-native")
      defer: removeDir(dir)
      discard rrTrace(dir, "app-0")
      discard rrTrace(dir, "app-1")
      let entries = surveyRecordings(dir)
      check entries.len == 2
      check entries[0].name == "app-0"
      check entries[0].kind == ctkNative
      check routeReviewCollect(dir, entries).collector == rcvNative

    test "a_materialized_recording_on_disk_routes_to_the_db_backend":
      # Both materialized layouts the debugger reads — the pre-CTFS
      # `trace_metadata.json` + `trace.bin` pair a Python recording has, and a
      # `.ct` container — reach the collector RV-4 added.
      let dir = makeRecordings("ct-review-survey-materialized")
      defer: removeDir(dir)
      discard materializedTrace(dir, "py-0")
      discard ctfsTrace(dir, "py-1")
      let entries = surveyRecordings(dir)
      check entries.len == 2
      for entry in entries:
        checkpoint(entry.name)
        check entry.kind == ctkMaterialized
      let route = routeReviewCollect(dir, entries)
      check route.collector == rcvMaterialized
      check canCollect(route)
      check route.message == ""

    test "a_materialized_collection_names_the_db_backend_when_it_is_missing":
      # The property RV-3's refusal was protecting, kept now that the refusal
      # is gone: a user reviewing a Python recording is never told the *rr*
      # backend is missing, because that would say DeepReview is an rr-only
      # feature (DeepReview-GUI.md §1.1).
      let message = missingReplayServerMessage()
      check message.contains("replay-server")
      check message.contains(ReplayServerExeEnvVar)
      check not message.contains("ct-native-replay")
      check not message.contains(NativeReplayExeEnvVar)

    test "an_mcr_recording_on_disk_stays_native_despite_its_ct_container":
      let dir = makeRecordings("ct-review-survey-mcr")
      defer: removeDir(dir)
      let trace = ctfsTrace(dir, "mcr-0")
      writeFile(trace / "mcr", "")
      check detectTraceKind(trace) == ctkNative
      check routeReviewCollect(dir, surveyRecordings(dir)).collector ==
        rcvNative

    test "a_mixed_directory_on_disk_is_refused":
      let dir = makeRecordings("ct-review-survey-mixed")
      defer: removeDir(dir)
      discard rrTrace(dir, "app-0")
      discard materializedTrace(dir, "py-0")
      let route = routeReviewCollect(dir, surveyRecordings(dir))
      check route.collector == rcvNone
      check route.message.contains("mixed")

    test "a_directory_of_ordinary_files_holds_no_recordings":
      # `--recordings` pointed at a source tree: the survey must say so
      # rather than hand a source tree to a collector.
      let dir = makeRecordings("ct-review-survey-source-tree")
      defer: removeDir(dir)
      writeFile(dir / "README.md", "hi")
      createDir(dir / "src")
      writeFile(dir / "src" / "lib.rs", "")
      let entries = surveyRecordings(dir)
      check entries.len == 2
      for entry in entries:
        checkpoint(entry.name)
        check entry.kind == ctkUnknown
      let route = routeReviewCollect(dir, entries)
      check route.collector == rcvNone
      check route.message.contains("none of which is a recording")

    test "an_empty_directory_on_disk_is_surveyed_as_empty":
      let dir = makeRecordings("ct-review-survey-empty")
      defer: removeDir(dir)
      check surveyRecordings(dir).len == 0
      check routeReviewCollect(dir, surveyRecordings(dir)).message
        .contains("empty")

    test "the_survey_is_sorted_so_a_diagnostic_names_the_same_entries_twice":
      # `walkDir` order is filesystem-dependent; a message that names "the
      # first three" must not name a different three on another machine.
      let dir = makeRecordings("ct-review-survey-order")
      defer: removeDir(dir)
      for name in ["zeta", "alpha", "middle"]:
        discard rrTrace(dir, name)
      let names = surveyRecordings(dir).mapIt(it.name)
      check names == @["alpha", "middle", "zeta"]

    test "the_shared_rules_change_ct_replays_answer_in_exactly_two_places":
      # RV-3 moved `ct replay`'s open-coded trace-kind rules into the shared
      # module.  Whether that is a refactor or a behaviour change is not a
      # matter of opinion, so the rules as they stood are re-implemented here
      # and the two are compared EXHAUSTIVELY rather than over a hand-picked
      # list of shapes: a hand-picked list can only confirm the differences
      # its author already suspected, and the point of this case is to find
      # the ones nobody suspected.
      #
      # The two rules together read five independent facts about a path — the
      # `mcr` marker, rr's `version` file, a `*.ct` file inside, one of the
      # pre-CTFS index files, and whether the path's own name ends in `.ct` —
      # so every shape either rule can tell apart is one of 2^5 combinations,
      # and all of them are built and compared below.  Three of the 32 differ,
      # and they are two distinct rule changes: one combination for the first
      # and two for the second, which is only visible once every combination
      # is enumerated rather than sampled.
      #
      # It pins the migration, not the rule: a deliberate change to what a
      # trace kind means is expected to update this case and say why.  What
      # it forbids is a THIRD, unnoticed difference appearing later.
      proc theRuleReplayNimUsedToHave(traceFolder: string): string =
        var hasCtSibling = false
        if dirExists(traceFolder):
          for entry in walkDir(traceFolder):
            if entry.kind == pcFile and entry.path.endsWith(".ct"):
              hasCtSibling = true
              break
        if traceFolder.endsWith(".ct") or fileExists(traceFolder / "mcr"):
          "rr"
        elif hasCtSibling:
          "db"
        else:
          "rr"

      let root = makeRecordings("ct-review-trace-kind-equivalence")
      defer: removeDir(root)

      # Every combination of the five facts, as a real directory on disk.
      var differing: seq[string] = @[]
      for bits in 0 ..< 32:
        let
          hasMcrMarker = (bits and 1) != 0
          hasRrVersion = (bits and 2) != 0
          holdsContainer = (bits and 4) != 0
          holdsIndexFile = (bits and 8) != 0
          nameEndsInCt = (bits and 16) != 0
        let shape = root / ("shape-" & $bits & (if nameEndsInCt: ".ct" else: ""))
        createDir(shape)
        if hasMcrMarker: writeFile(shape / "mcr", "")
        if hasRrVersion: writeFile(shape / "version", "7\n")
        if holdsContainer: writeFile(shape / "trace.ct", "")
        if holdsIndexFile: writeFile(shape / "trace_metadata.json", "{}")
        checkpoint(shape)
        let was = theRuleReplayNimUsedToHave(shape)
        let now = traceKindString(detectTraceKind(shape))
        if was != now:
          differing.add shape.lastPathPart & ": mcr=" & $hasMcrMarker &
            " version=" & $hasRrVersion & " container=" & $holdsContainer &
            " index=" & $holdsIndexFile & " nameEndsInCt=" & $nameEndsInCt &
            " was=" & was & " now=" & now

      # Paths that are not directories are outside the loop above, and the two
      # rules must still agree about them: a bare container file, and paths
      # that are not there at all (`ct replay --trace-folder <typo>`).
      let bareContainer = root / "loose.ct"
      writeFile(bareContainer, "")
      for shape in [bareContainer, root / "not-there", root / "not-there.ct"]:
        checkpoint(shape)
        check traceKindString(detectTraceKind(shape)) ==
          theRuleReplayNimUsedToHave(shape)

      checkpoint(differing.join("\n"))
      check differing.len == 3  # difference 1 once, difference 2 twice

      # DIFFERENCE 1 — a pre-CTFS materialized folder (`trace_metadata.json` +
      # `trace.bin`, the shape `ct record-web` writes and the shape the
      # example Python recordings still have) has no `.ct` container, so the
      # old rule fell through to its `else` and called it "rr" — a
      # materialized recording registered as one the native replay worker
      # opens, which decides both the language mapping (`detectTraceLang`) and
      # which arm of `trace_index.recordTrace` runs.  The shared rules
      # recognise the layout and say "db".  The old rule never considered it
      # because by the time that branch was written every recording carried a
      # container.
      let legacyMaterialized = materializedTrace(root, "a-materialized-trace")
      check theRuleReplayNimUsedToHave(legacyMaterialized) == TraceKindNative
      check traceKindString(detectTraceKind(legacyMaterialized)) ==
        TraceKindMaterialized

      # DIFFERENCE 2 — an rr trace directory that also happens to hold a `.ct`
      # file.  The old rule tested for a container before it tested for
      # anything native at all (it had no test for rr's `version` file), so it
      # answered "db" and handed an rr trace to the db-backend.  The shared
      # rules read the positive evidence first and answer "rr".  Both
      # differences are the same correction: the old rule decided by
      # fall-through, the new one decides by what is actually on disk.
      let rrWithAContainer = rrTrace(root, "an-rr-trace-holding-a-container")
      writeFile(rrWithAContainer / "extra.ct", "")
      check theRuleReplayNimUsedToHave(rrWithAContainer) ==
        TraceKindMaterialized
      check traceKindString(detectTraceKind(rrWithAContainer)) ==
        TraceKindNative

    test "a_missing_recordings_directory_surveys_as_nothing":
      # The executor diagnoses this before routing; the survey must not
      # pretend an absent directory is an empty one by raising instead.
      check surveyRecordings(
        getTempDir() / "ct-review-survey-absent").len == 0

  suite "ct review — production wiring (source contract)":
    test "the_deepreview_option_is_gone_from_the_conf_and_review_declared":
      let conf = readSource("src/ct/codetracerconf.nim")
      # The retired option's *declaration* is what made `ct --deepreview`
      # parse.  Its absence is the retirement.
      check not conf.contains("name: \"deepreview\"")
      check conf.contains("reviewPath*")
      check conf.contains("of review:")

    test "launch_no_longer_reads_a_deepreview_option":
      let launch = readSource("src/ct/launch/launch.nim")
      check not launch.contains("conf.deepreview")
      check launch.contains("of StartupCommand.review:")
      check launch.contains("resolveReviewDatasetJson")

    test "codetracer_intercepts_review_and_the_retired_flag":
      let main = readSource("src/ct/codetracer.nim")
      check main.contains("reviewNeedsRawDispatch")
      check main.contains("runReviewCli")
      check main.contains("retiredDeepReviewArgIndex")
      check main.contains("retiredDeepReviewMessage")

    test "collect_routes_before_it_looks_for_a_backend":
      # Order is the whole point, not an accident of control flow: a Python
      # user has no `ct-native-replay`, and answering "the native replay
      # backend is missing" for a Python recording names the wrong problem
      # and implies DeepReview is an rr-only feature — the coupling
      # DeepReview-GUI.md §1.1 says must not become architectural.
      let source = readSource("src/ct/review_cli.nim")
      let routeAt = source.find("routeReviewCollect(")
      let backendAt = source.find("if nativeReplayExe().len == 0")
      check routeAt > 0
      check backendAt > 0
      check routeAt < backendAt

    test "ct_replay_keeps_using_the_shared_trace_kind_rules":
      # RV-3's claim is that there is ONE rule for what a recording is, not
      # that there was one on the day it was written.  `ct replay` used to
      # open-code the rules; if a later change puts a private copy back, the
      # dispatch and the replay path can drift apart again without anything
      # failing — so the absence of the old copy is asserted, not assumed.
      let replay = readSource("src/ct/trace/replay.nim")
      check replay.contains("detectTraceKind(traceFolder)")
      check replay.contains("traceKindString(")
      check not replay.contains("hasCtSibling")

    test "the_playwright_fixture_launches_the_new_spelling":
      # The GUI suites are the end-to-end coverage of the launch path.  If the
      # fixture kept launching `--deepreview` they would keep passing while
      # the shipped command was broken, which is exactly the gap RV-1's
      # "retarget, do not delete" rule exists to close.
      let fixtures = readSource("src/tests/gui/lib/fixtures.ts")
      check fixtures.contains("\"review\", jsonPath")
      check not fixtures.contains("`--deepreview=${jsonPath}`")
