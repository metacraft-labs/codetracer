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
## Three layers, matching the milestone's three verification entries:
##
##   * **Dispatch** — `review` resolves to launch, collect or inspect, and the
##     collect verb translates into the native collector's own argv.  The argv
##     is asserted as data rather than by running the collector: the
##     translation is the part that can silently rot, and it must be checkable
##     on a machine that has no `ct-native-replay`.
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
##     `deepreview_entry_test.nim` already use.
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
    check not reviewNeedsRawDispatch(@["review", "--help"])
    check not reviewNeedsRawDispatch(@["review"])
    check reviewNeedsRawDispatch(@["review", "collect", "--output", "/tmp/o"])
    check reviewNeedsRawDispatch(@["review", "inspect", "/tmp/o"])
    check reviewNeedsRawDispatch(@["review", "export", "/tmp/o"])
    check not reviewNeedsRawDispatch(@["edit", "collect"])

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
  import std/[os, strutils as nativeStrutils]

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

    test "the_playwright_fixture_launches_the_new_spelling":
      # The GUI suites are the end-to-end coverage of the launch path.  If the
      # fixture kept launching `--deepreview` they would keep passing while
      # the shipped command was broken, which is exactly the gap RV-1's
      # "retarget, do not delete" rule exists to close.
      let fixtures = readSource("src/tests/gui/lib/fixtures.ts")
      check fixtures.contains("\"review\", jsonPath")
      check not fixtures.contains("`--deepreview=${jsonPath}`")
