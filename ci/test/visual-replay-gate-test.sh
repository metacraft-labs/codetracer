#!/usr/bin/env bash

# Hermetic adversarial contracts for visual-replay gate result enforcement.
# Synthetic reports exercise negative paths without building product binaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/visual-replay-gate-lib.sh"

fail() {
	echo "visual-replay gate contract failed: $*" >&2
	exit 1
}

expect_failure() {
	local description="$1" fragment="$2" output exit_status
	shift 2
	if output="$("$@" 2>&1)"; then
		fail "$description unexpectedly succeeded"
	else
		exit_status=$?
	fi
	[[ $exit_status -ne 0 ]] || fail "$description returned a zero status"
	grep -Fq "$fragment" <<<"$output" ||
		fail "$description did not report '$fragment': $output"
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/visual-replay-gate-contract.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
python_bin="$(visual_replay_gate_python)"
validator="$VISUAL_REPLAY_GATE_REPORT_VALIDATOR"

write_playwright_report() {
	local output="$1" kind="$2" mutation="${3:-none}"
	"$python_bin" - "$output" "$kind" "$mutation" <<'PYTHON'
import json
import sys

output, kind, mutation = sys.argv[1:]
entries = [
    ("frame-viewer/frame-viewer-storybook.spec.ts", ["Frame Viewer StoryBook"],
     "renders a non-empty frame and updates on frame change"),
    ("frame-viewer/frame-viewer-storybook.spec.ts", ["Frame Viewer StoryBook"],
     "e2e_mcr_visual_layout_contains_frame_viewer"),
]
video_titles = [
    "paused state shows controls and the Paused badge",
    "playing 1x shows the forward arrow and 1x badge",
    "playing 8x shows the rate badge at 8x",
    "picker active draws the blue ring and pressed picker button",
    "player error renders the red bottom-left banner and disables controls",
    "buffering active shows the yellow dot next to the rate badge",
]
for theme in ("dark theme", "light theme"):
    for title in video_titles:
        entries.append(
            (
                "frame-viewer/video-player-storybook.spec.ts",
                ["Visual Replay Video Player storybook", theme],
                title,
            )
        )
for suite, title in (
    ("MCR visual replay real GUI layout",
     "visual-capable trace opens Video Player in production layout"),
    ("MCR visual replay real GUI layout", "e2e_step_updates_video_player"),
    ("MCR visual replay real GUI layout",
     "e2e_pixel_history_click_navigates_source"),
    ("MCR visual replay real GUI layout",
     "e2e_shader_debug_panel_shows_source_and_values"),
    ("MCR visual replay player failure",
     "e2e_visual_player_failure_shows_status_error"),
):
    entries.append(("frame-viewer/visual-replay-gui.spec.ts", [suite], title))

if kind == "real":
    entries = [
        (
            "frame-viewer/visual-replay-real-recording.spec.ts",
            ["MCR visual replay real recording GUI integration"],
            "recorded GL trace drives Video Player chrome end-to-end",
        )
    ]
if mutation == "count":
    entries = entries[:-1]
elif mutation == "file":
    _, suites, title = entries[0]
    entries[0] = ("frame-viewer/replacement.spec.ts", suites, title)
elif mutation == "title":
    file_name, suites, _ = entries[0]
    entries[0] = (file_name, suites, "replacement title")


def test_result():
    return {
        "expectedStatus": "passed",
        "projectName": "chromium",
        "annotations": [],
        "results": [{"status": "passed", "retry": 0}],
        "status": "expected",
    }


top_suites = {}
for file_name, suite_titles, title in entries:
    top = top_suites.setdefault(
        file_name,
        {"title": file_name, "file": file_name, "suites": [], "specs": []},
    )
    parent = top
    for suite_title in suite_titles:
        child = next(
            (suite for suite in parent["suites"] if suite["title"] == suite_title),
            None,
        )
        if child is None:
            child = {"title": suite_title, "suites": [], "specs": []}
            parent["suites"].append(child)
        parent = child
    parent["specs"].append(
        {
            "title": title,
            "file": file_name,
            "ok": True,
            "tests": [test_result()],
        }
    )

count = len(entries)
report = {
    "config": {
        "projects": [{"name": "chromium", "retries": 0, "repeatEach": 1}]
    },
    "suites": list(top_suites.values()),
    "errors": [],
    "stats": {
        "expected": count,
        "skipped": 0,
        "unexpected": 0,
        "flaky": 0,
    },
}

first_parent = report["suites"][0]
while not first_parent["specs"]:
    first_parent = first_parent["suites"][0]
first_spec = first_parent["specs"][0]
first_test = first_spec["tests"][0]
if mutation == "multiple":
    first_test["results"].append({"status": "passed", "retry": 0})
elif mutation == "flaky":
    first_test["results"] = [
        {"status": "failed", "retry": 0},
        {"status": "passed", "retry": 1},
    ]
    first_test["status"] = "flaky"
    report["stats"]["expected"] -= 1
    report["stats"]["flaky"] = 1
elif mutation == "skip":
    first_test["results"][0]["status"] = "skipped"
    first_test["status"] = "skipped"
    report["stats"]["expected"] -= 1
    report["stats"]["skipped"] = 1
elif mutation == "unexpected":
    report["stats"]["expected"] -= 1
    report["stats"]["unexpected"] = 1
elif mutation == "retry-config":
    report["config"]["projects"][0]["retries"] = 2
elif mutation == "retry-bool":
    first_test["results"][0]["retry"] = False
elif mutation == "annotation-skip":
    first_test["annotations"] = [{"type": "skip", "description": "hostile skip"}]
elif mutation == "annotation-fixme":
    first_test["annotations"] = [{"type": "fixme"}]
elif mutation == "annotations-object":
    first_test["annotations"] = {}
elif mutation == "config-array":
    report["config"] = []
elif mutation == "projects-object":
    report["config"]["projects"] = {}
elif mutation == "project-non-object":
    report["config"]["projects"][0] = "chromium"
elif mutation == "suites-object":
    report["suites"] = {}
elif mutation == "suite-non-object":
    report["suites"][0] = "not a suite"
elif mutation == "child-suites-object":
    report["suites"][0]["suites"] = {}
elif mutation == "specs-object":
    first_parent["specs"] = {}
elif mutation == "spec-non-object":
    first_parent["specs"][0] = "not a spec"
elif mutation == "tests-object":
    first_spec["tests"] = {}
elif mutation == "test-non-object":
    first_spec["tests"][0] = "not a test"
elif mutation == "results-object":
    first_test["results"] = {}
elif mutation == "result-non-object":
    first_test["results"][0] = "not a result"
elif mutation == "stats-array":
    report["stats"] = []
elif mutation == "root-array":
    report = []

with open(output, "w", encoding="utf-8") as report_file:
    json.dump(report, report_file)
PYTHON
}

fake_just="$tmp_dir/fake-just"
retry_log="$tmp_dir/retries.log"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'printf "%s:%s\\n" "$FAKE_STAGE_NAME" "$PLAYWRIGHT_RETRIES" >>"$FAKE_RETRY_LOG"' \
	'cp "$FAKE_REPORT_SOURCE" "$CODETRACER_VISUAL_REPLAY_GATE_JSON"' \
	>"$fake_just"
chmod +x "$fake_just"

for kind in fake real; do
	report_source="$tmp_dir/$kind-source.json"
	report_output="$tmp_dir/$kind-output.json"
	write_playwright_report "$report_source" "$kind"
	FAKE_STAGE_NAME="$kind" \
		FAKE_RETRY_LOG="$retry_log" \
		FAKE_REPORT_SOURCE="$report_source" \
		PLAYWRIGHT_RETRIES=9 \
		visual_replay_run_playwright_stage "$kind" "$report_output" "$fake_just"
done
[[ $(cat "$retry_log") == $'fake:0\nreal:0' ]] ||
	fail "both Playwright stages must override inherited retries to exactly zero"

for mutation in \
	multiple flaky skip unexpected retry-config retry-bool \
	annotation-skip annotation-fixme annotations-object \
	config-array projects-object project-non-object \
	suites-object suite-non-object child-suites-object specs-object spec-non-object \
	tests-object test-non-object results-object result-non-object \
	stats-array root-array title file count; do
	report="$tmp_dir/fake-$mutation.json"
	write_playwright_report "$report" fake "$mutation"
	case "$mutation" in
	multiple)
		fragment="exactly one execution result"
		;;
	flaky | skip)
		fragment="status is not expected"
		;;
	unexpected)
		fragment="Playwright stats.expected"
		;;
	retry-config)
		fragment="Playwright retries must be integer 0"
		;;
	retry-bool)
		fragment="Playwright result retry must be integer 0"
		;;
	annotation-skip | annotation-fixme | annotations-object)
		fragment="Playwright test has annotations"
		;;
	config-array)
		fragment="no config object"
		;;
	projects-object)
		fragment="exactly one project"
		;;
	project-non-object)
		fragment="project entry is malformed"
		;;
	suites-object)
		fragment="suites must be an array"
		;;
	suite-non-object)
		fragment="suite entry is malformed"
		;;
	child-suites-object)
		fragment="child suites must be an array"
		;;
	specs-object)
		fragment="specs must be an array"
		;;
	spec-non-object)
		fragment="spec entry is malformed"
		;;
	tests-object)
		fragment="exactly one test"
		;;
	test-non-object)
		fragment="test entry is malformed"
		;;
	results-object)
		fragment="exactly one execution result"
		;;
	result-non-object)
		fragment="result entry is malformed"
		;;
	stats-array)
		fragment="no stats object"
		;;
	root-array)
		fragment="report root must be an object"
		;;
	title | file | count)
		fragment="manifest mismatch"
		;;
	esac
	expect_failure "Playwright $mutation activity" "$fragment" \
		"$python_bin" "$validator" playwright --kind fake --report "$report"
done

malformed_report="$tmp_dir/malformed.json"
printf '{not-json\n' >"$malformed_report"
expect_failure "malformed Playwright report" "not valid JSON" \
	"$python_bin" "$validator" playwright --kind fake --report "$malformed_report"

nim_label="src/tests/gui/tests/frame-viewer/visual_player_lifecycle_test.nim"

write_nim_output() {
	local output="$1" mutation="${2:-none}"
	"$python_bin" - "$output" "$mutation" <<'PYTHON'
import sys

output, mutation = sys.argv[1:]
suite = "Visual replay player lifecycle"
tests = [
    "pipeline command keeps trace path as argv data",
    "pipeline command can pin the player backend",
    "test_visual_player_lifecycle_ready_and_shutdown",
]
status = ["OK"] * len(tests)
extra_suites = []
tail = ["@@CODETRACER_VISUAL_REPLAY_NIM_COMMAND_COMPLETED@@"]

if mutation == "count":
    tests.pop()
    status.pop()
elif mutation == "identity":
    tests[0] = "substituted test identity"
elif mutation == "order":
    tests[0], tests[1] = tests[1], tests[0]
elif mutation == "duplicate":
    tests[1] = tests[0]
elif mutation == "suite":
    suite = "substituted suite identity"
elif mutation == "unknown-suite":
    extra_suites.append("[Suite] unknown empty suite")
elif mutation == "skip":
    status[-1] = "SKIPPED"
elif mutation == "inactive":
    extra_suites.append("1 ignored; 1 filtered out")
elif mutation == "malformed":
    extra_suites.append("[OK")
elif mutation == "missing-sentinel":
    tail = []
elif mutation == "duplicate-sentinel":
    tail.append(tail[0])
elif mutation == "sentinel-not-final":
    tail.append("post-sentinel output")

lines = [f"[Suite] {suite}"]
lines.extend(f"  [{state}] {title}" for state, title in zip(status, tests))
lines.extend(extra_suites)
lines.extend(tail)
text = "\n".join(lines)
if mutation != "truncated":
    text += "\n"
with open(output, "w", encoding="utf-8", newline="") as output_file:
    output_file.write(text)
PYTHON
}

nim_success="$tmp_dir/nim-success.log"
write_nim_output "$nim_success"
"$python_bin" "$validator" nim --log "$nim_success" --label "$nim_label"

for mutation in \
	count identity order duplicate suite unknown-suite skip inactive malformed \
	missing-sentinel duplicate-sentinel sentinel-not-final truncated; do
	nim_report="$tmp_dir/nim-$mutation.log"
	write_nim_output "$nim_report" "$mutation"
	case "$mutation" in
	count | identity | order | duplicate)
		fragment="test identity/order mismatch"
		;;
	suite | unknown-suite)
		fragment="suite identity/order mismatch"
		;;
	skip)
		fragment="non-passing results"
		;;
	inactive)
		fragment="inactive tests"
		;;
	malformed)
		fragment="malformed unittest marker"
		;;
	missing-sentinel | duplicate-sentinel | sentinel-not-final)
		fragment="completion sentinel is missing, duplicated, or not final"
		;;
	truncated)
		fragment="output is truncated"
		;;
	esac
	expect_failure "Nim $mutation report" "$fragment" \
		"$python_bin" "$validator" nim --log "$nim_report" --label "$nim_label"
done

unknown_label="$tmp_dir/nim-unknown-label.log"
write_nim_output "$unknown_label"
expect_failure "unknown Nim label" "not in the required manifest" \
	"$python_bin" "$validator" nim \
	--log "$unknown_label" --label "tests/substituted.nim"

printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'printf "[Suite] Visual replay player lifecycle\\n"' \
	'printf "  [OK] pipeline command keeps trace path as argv data\\n"' \
	'printf "  [OK] pipeline command can pin the player backend\\n"' \
	'printf "  [OK] test_visual_player_lifecycle_ready_and_shutdown\\n"' \
	>"$tmp_dir/fake-nim-command"
chmod +x "$tmp_dir/fake-nim-command"
visual_replay_run_nim_suite "$nim_label" "$tmp_dir/fake-nim-command"

printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'printf "[Suite] Visual replay player lifecycle\\n"' \
	'printf "  [OK] pipeline command keeps trace path as argv data\\n"' \
	'printf "  [OK] pipeline command can pin the player backend\\n"' \
	'printf "  [OK] test_visual_player_lifecycle_ready_and_shutdown\\n"' \
	'exit 7' >"$tmp_dir/failing-nim-command"
chmod +x "$tmp_dir/failing-nim-command"
expect_failure "failed Nim command" "failed before report validation" \
	visual_replay_run_nim_suite "$nim_label" "$tmp_dir/failing-nim-command"

echo "visual-replay gate adversarial contracts passed"
