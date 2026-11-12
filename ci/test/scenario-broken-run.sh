#!/usr/bin/env bash
# ci/test/scenario-broken-run.sh <terminal|gpui|electron> — a test-run
# recording identifies the step that failed.
#
# Runs src/tests/scenarios/tests/broken-trace-macro-expectation.yaml — the
# user's example scenario (tracing/trace-macro-at-caret.yaml) with ONE wrong
# expectation: after the macro is traced, the new tab is expected stopped on
# lines 10..12, while the macro's body is lines 3..4 — on the given flavour,
# against the real front-end, recording and replay server, and checks what an
# agent reading the run would rely on (DemoVideoScript recordings.md):
#
#   * the run FAILED (exit 1), and the runner printed its recording directory;
#   * manifest.json names that step (path 3.5, kind expect) as the failed one,
#     every step before it passed and every step after it did not run;
#   * failure/observation.json is that step, with the observed `current-line`
#     (4, the macro's body) that contradicts the expectation;
#   * there is a still and a state file for every step that ran, and a still
#     of the screen at the failure (failure/surface.*);
#   * the session media (a cast or a video) is there.
#
# A recording that pointed at the wrong step, or held no observation, would
# leave an agent to re-run the scenario to find out what happened — the
# recording exists so that it does not have to.
set -uo pipefail
flavour="${1:?usage: scenario-broken-run.sh <terminal|gpui|electron>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
build="${CT_SCENARIO_BUILD:-${root}/build}"
out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

bash ci/test/scenarios.sh run "${flavour}" \
	src/tests/scenarios/tests/broken-trace-macro-expectation.yaml >"${out}" 2>&1
rc=$?
cat "${out}"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
[ "${rc}" -eq 1 ] || fail "the broken scenario exited ${rc}, not 1 (failed)"
dir="$(sed -n 's/^recording: //p' "${out}" | tail -1)"
[ -n "${dir}" ] && [ -d "${dir}" ] || fail "the runner printed no recording directory"
python3 - "${dir}" <<'EOF' || exit 1
import json, os, sys
d = sys.argv[1]
m = json.load(open(os.path.join(d, "manifest.json")))
problems = []
if m.get("outcome") != "failed":
    problems.append(f"manifest outcome {m.get('outcome')!r}, not 'failed'")
steps = m["steps"]
failed = [s for s in steps if s["status"] == "failed"]
if len(failed) != 1 or failed[0]["path"] != "3.5" or failed[0]["kind"] != "expect":
    problems.append(f"failed steps {[(s['path'], s['kind']) for s in failed]}, not exactly 3.5 expect")
else:
    f = failed[0]
    for s in steps:
        if s["index"] < f["index"] and s["status"] != "passed":
            problems.append(f"step {s['path']} before the failure is {s['status']}")
        if s["index"] > f["index"] and s["status"] in ("passed", "failed"):
            problems.append(f"step {s['path']} after the failure ran ({s['status']})")
    obs = json.load(open(os.path.join(d, "failure", "observation.json")))
    if obs["step"]["path"] != "3.5":
        problems.append(f"failure/observation.json is step {obs['step']['path']}")
    seen = json.dumps(obs) + json.dumps(f)
    if '"current-line": 4' not in seen and '"current-line": 3' not in seen:
        problems.append("the failure records no observed current-line in 3..4 (the macro's body)")
    for s in steps:
        if s["index"] > f["index"]:
            continue
        state = os.path.join(d, "steps", f"{s['index']}-state.json")
        if not os.path.isfile(state):
            problems.append(f"no state file for step {s['path']}")
        stills = [a for a in s.get("artifacts", []) if os.path.basename(a).split(".")[-1] in ("png", "svg", "txt")]
        if not stills:
            problems.append(f"no still for step {s['path']}")
    if not any(n.startswith("surface.") for n in os.listdir(os.path.join(d, "failure"))):
        problems.append("no failure/surface still")
if not any(n.startswith("session.") and not n.endswith(".json") for n in os.listdir(d)):
    problems.append("no session media (cast or video)")
for p in problems:
    print("PROBLEM", p)
print(f"broken-run recording {d}: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
EOF
echo "OK: the ${flavour} recording identifies step 3.5 and what it observed"
