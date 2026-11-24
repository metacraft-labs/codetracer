#!/usr/bin/env bash
# ci/test/ctf-p1b-gpui-capture-shards-test.sh — CTF-P1b's GPUI story captures
# fit inside the GPUI job's bound, and are all judged.
#
# The defect (codetracer-specs issues/2026-11-24-gpui-window-captures-shard-1-
# runs-out-of-its-150-minute-bound-in-the-ctf-p1b-step.md): shard 1 of
# `gpui-window-captures` took the whole set of story captures, ~1,400 windows
# at ~8 s each (run 45292632494: ~300 in 40 minutes), after ~110 minutes of
# its own window lanes, and was cancelled at the job's 150-minute bound in
# that step in runs 45118976975 and 45292632494. The step had never
# completed, and the terminal emulators' lane after it had never run.
#
# What is asserted, over the committed workflow and web records:
#
#   1. No step of the shards takes the whole set (`just ctf-p1b-gpui-captures`);
#      the capture step takes a share named by
#      ci/test/ctf-p1b-gpui-capture-share.sh for its `matrix.shard`.
#   2. The shares cover the set exactly once (the share helper names each of
#      1..n for exactly one shard), and shard 1 takes none.
#   3. A share's windows (the count of the committed web records, which the
#      layout tests hold the set to, dealt round robin) fit the capture step's
#      own `timeout-minutes` with room for its builds, and that bound fits in
#      what the job's bound leaves after the slowest shard's other steps.
#   4. Shard 1 runs neither the captures nor the terminal emulators' lane.
#   5. Each share is uploaded, and the `ctf-p1b-gpui-layout` job needs the
#      shards, downloads every share and runs the `agent-harbor-gpui-captures`
#      lane over the union; the shards themselves never run that lane over a
#      partial set.
#   6. The share helper refuses a malformed or out-of-range shard.
#
# No mocks: the committed `.github/workflows/gpui-window-captures.yml`, the
# web records and the share helper are the input. Needs python3 with PyYAML.
# Lane: a step of `lint-bash`.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

helper=ci/test/ctf-p1b-gpui-capture-share.sh

# 6. The helper's refusals, before anything relies on its answers.
for bad in "" "3" "0/20" "21/20" "a/20" "1/2"; do
	if out="$(bash "${helper}" "${bad}" 2>&1)"; then
		fail "the share helper accepted '${bad}' (printed '${out}')"
	else
		ok "the share helper refuses '${bad}'"
	fi
done

python3 - "${helper}" <<'PY' || failures=$((failures + 1))
import json, math, re, subprocess, sys
import yaml

helper = sys.argv[1]
WF = ".github/workflows/gpui-window-captures.yml"
RECORDS = ["src/tests/visual/agent-harbor-web-regions.json",
           "src/tests/visual/agent-harbor-web-regions-at-moments.json"]
# Measured, run 45292632494 job 138270821885: ~300 story windows in the
# step's 40 minutes on a garm runner.
SECONDS_PER_CAPTURE = 8
# The story host's and the capture driver's Nim builds, the shell entries and
# the PPM->PNG pass of both halves, which a share pays whatever its size.
BUILD_ALLOWANCE_MIN = 15
# The slowest shard's steps other than the captures (the header's "22-88m").
SLOWEST_OTHER_STEPS_MIN = 88

failures = 0
def fail(msg):
    global failures
    failures += 1
    print("  FAIL " + msg)
def ok(msg):
    print("  ok   " + msg)

total = 0
for r in RECORDS:
    total += len(json.load(open(r))["captures"])
if total < 1000:
    fail(f"the web records list {total} captures; expected the ~1,400 of the whole set")
else:
    ok(f"the whole set is {total} captures, ~{total * SECONDS_PER_CAPTURE // 60} minutes of windows on one runner")

wf = yaml.safe_load(open(WF))
jobs = wf["jobs"]
job = jobs["gpui-window-captures"]
shards = job["strategy"]["matrix"]["shard"]
n_matrix = len(shards)
job_bound = job["timeout-minutes"]
steps = job["steps"]

def runs_on(step, shard):
    """Whether a step's `if:` lets it run on `shard`, from its matrix.shard
    comparisons alone (every other condition taken as true)."""
    cond = str(step.get("if", ""))
    for op, val in re.findall(r"matrix\.shard\s*(==|>=|<=|>|<|!=)\s*(\d+)", cond):
        v = int(val)
        if not {"==": shard == v, ">=": shard >= v, "<=": shard <= v,
                ">": shard > v, "<": shard < v, "!=": shard != v}[op]:
            return False
    return True

def share_of(shard):
    out = subprocess.run(["bash", helper, f"{shard}/{n_matrix}"], check=True,
                         capture_output=True, text=True).stdout.strip()
    return out

captures = [s for s in steps if re.search(r"ctf-p1b-gpui-captures|ctf-p1b-gpui-story-capture", str(s.get("run", "")))]
if not captures:
    fail("no step of gpui-window-captures takes CTF-P1b's story captures")
for step in captures:
    name = step.get("name", "?")
    run = str(step["run"])
    on = [s for s in shards if runs_on(step, s)]
    whole = re.search(r"just ctf-p1b-gpui-captures(\s|$)", run) is not None
    if whole or "ctf-p1b-gpui-captures-shard" not in run:
        minutes = total * SECONDS_PER_CAPTURE / 60
        fail(f"'{name}' takes all {total} captures on shard(s) {on}: "
             f"~{minutes:.0f} minutes of windows, against the job's {job_bound}")
        continue
    if f'{helper} "${{{{ matrix.shard }}}}/{n_matrix}"' not in run:
        fail(f"'{name}' does not take its share from {helper} for its matrix.shard/{n_matrix}")
    else:
        ok(f"'{name}' takes the share {helper} names for its shard")
    if 1 in on:
        fail(f"'{name}' runs on shard 1, which carries the window lanes")
    # 2. The shares partition the set, and the step runs on every shard that has one.
    shares = {s: share_of(s) for s in shards}
    taking = {s: v for s, v in shares.items() if v != "none"}
    if set(taking) != set(on):
        fail(f"'{name}' runs on shards {on}, the helper deals shares to {sorted(taking)}")
    ns = {v.split("/")[1] for v in taking.values()}
    idx = sorted(int(v.split("/")[0]) for v in taking.values())
    if len(ns) != 1 or idx != list(range(1, int(next(iter(ns))) + 1)):
        fail(f"the shares {sorted(taking.values())} do not cover 1..n once each")
    else:
        n = int(next(iter(ns)))
        ok(f"shards {sorted(taking)} take shares 1..{n} once each; shards {sorted(set(shards) - set(taking))} take none")
        # 3. A share's time inside the step's bound, and the bound inside the job's.
        per_share = math.ceil(total / n)
        need = per_share * SECONDS_PER_CAPTURE / 60 + BUILD_ALLOWANCE_MIN
        bound = step.get("timeout-minutes")
        if bound is None:
            fail(f"'{name}' has no timeout-minutes of its own: a slow share would cancel the job, not fail by name")
        elif need > bound:
            fail(f"a share is {per_share} windows, ~{need:.0f} minutes with its builds, over the step's {bound}")
        elif bound + SLOWEST_OTHER_STEPS_MIN > job_bound:
            fail(f"the step's {bound} minutes after the slowest shard's {SLOWEST_OTHER_STEPS_MIN} exceed the job's {job_bound}")
        else:
            ok(f"a share is {per_share} windows, ~{need:.0f} minutes with its builds, inside the step's {bound}; "
               f"{SLOWEST_OTHER_STEPS_MIN} + {bound} <= the job's {job_bound}")
    # 5. Each share is uploaded under the name the judge downloads.
    uploads = [s for s in steps if "upload-artifact" in str(s.get("uses", ""))
               and str(s.get("with", {}).get("name", "")).startswith("ctf-p1b-gpui-captures-")]
    if not uploads:
        fail("no step uploads a shard's captures as ctf-p1b-gpui-captures-<shard>")
    else:
        up = uploads[0]
        paths = str(up["with"].get("path", ""))
        if "build/ctf-p1b/gpui" not in paths or "build/ctf-p1c/gpui" not in paths:
            fail("the shard upload does not carry both build/ctf-p1b/gpui and build/ctf-p1c/gpui")
        elif [s for s in shards if runs_on(up, s)] != on:
            fail("the shard upload does not run on exactly the shards that capture")
        else:
            ok("each share's frames and regions are uploaded as ctf-p1b-gpui-captures-<shard>")

# 4. Shard 1 carries neither the captures nor the emulators' lane.
before = failures
for step in steps:
    run = str(step.get("run", ""))
    if "test-tui-real-emulators" in run and runs_on(step, 1):
        fail(f"'{step.get('name')}' (the terminal emulators) runs on shard 1")
    if "agent-harbor-gpui-captures" in run:
        fail(f"'{step.get('name')}' runs the layout lane on a shard, over a partial set")
if failures == before:
    ok("shard 1 runs neither the captures nor the terminal emulators; no shard runs the layout lane")

# 5. The judge.
judge = jobs.get("ctf-p1b-gpui-layout")
if judge is None:
    fail("no ctf-p1b-gpui-layout job judges the shares' captures")
else:
    needs = judge.get("needs", [])
    needs = [needs] if isinstance(needs, str) else needs
    jsteps = judge.get("steps", [])
    dl = [s for s in jsteps if "download-artifact" in str(s.get("uses", ""))
          and s.get("with", {}).get("pattern") == "ctf-p1b-gpui-captures-*"
          and s["with"].get("merge-multiple") is True and s["with"].get("path") == "build"]
    lane = [s for s in jsteps if "run-nim-test-lane.sh agent-harbor-gpui-captures" in str(s.get("run", ""))]
    if "gpui-window-captures" not in needs:
        fail("ctf-p1b-gpui-layout does not need gpui-window-captures")
    elif "!cancelled()" not in str(judge.get("if", "")):
        fail("ctf-p1b-gpui-layout does not run when a shard failed")
    elif not dl:
        fail("ctf-p1b-gpui-layout does not download every share (pattern ctf-p1b-gpui-captures-*, merged into build)")
    elif not lane or jsteps.index(lane[0]) < jsteps.index(dl[0]):
        fail("ctf-p1b-gpui-layout does not run the agent-harbor-gpui-captures lane after the download")
    elif not isinstance(judge.get("timeout-minutes"), int):
        fail("ctf-p1b-gpui-layout has no timeout-minutes")
    else:
        ok("ctf-p1b-gpui-layout needs the shards, downloads every share and runs the lane over the union")

sys.exit(1 if failures else 0)
PY

if [ "${failures}" -gt 0 ]; then
	echo "ctf-p1b-gpui-capture-shards: ${failures} failure(s)"
	exit 1
fi
echo "ctf-p1b-gpui-capture-shards: ok"
