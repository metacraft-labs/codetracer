#!/usr/bin/env bash
#
# sibling-cargo-locks-workflow-test.sh -- the sibling Cargo.lock guard
# (`scripts/test-sibling-cargo-locks.sh`) RUNS IN CI on every branch changes
# land on, `agents` included, whenever a file that can make a lock stale
# changes.
#
# WHY THIS EXISTS
# ---------------
# The guard ran only inside `just test` (the `test-non-gui` job of
# `codetracer.yml`), which a push triggers on `main`/`dev`/`stable` and never
# on `agents`. Changes land on `agents` first, so a db-backend Cargo.lock
# written against a sibling that was off its pin reached `agents` with nothing
# checking it, and every local `--locked` build refused the lock. The fix is
# `.github/workflows/sibling-cargo-locks.yml`; this suite is what keeps it
# from quietly losing the branch or the files that matter.
#
# WHAT IT ASSERTS, OVER THE LIVE WORKFLOW FILES
# ---------------------------------------------
#   1. Some workflow runs the guard (`just test-sibling-cargo-locks` or the
#      script itself) in a job step, and triggers on `push` to `agents`.
#   2. That workflow's push path filter, if it has one, matches every file
#      that decides whether a lock is stale: every git-tracked Cargo.lock and
#      Cargo.toml, `repro.lock` and `flake.lock`, the guard and this workflow.
#      Matching follows GitHub's filter globs (`**` crosses `/`, `*` does not).
#   3. The guard runs STRICT there (`CT_SIBLING_CARGO_LOCKS_STRICT=1`): a run
#      that could not check a lock is a failure in CI, never a SKIP.
#
# NEGATIVE CONTROLS, NOT MOCKS: each property is also checked against a copy
# of the live workflow with exactly that property removed (no `agents`, no
# `repro.lock` path, no STRICT), and the checker must refuse each copy by
# name. A checker that could not fail would pass all three.
#
# Pure bash + python3 + git (no PyYAML: the dev shell has none, so the `on:`
# block is read by indentation, which is all a trigger list needs).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 2

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CHECKER="$TMP/check.py"
cat >"$CHECKER" <<'PY'
import os, re, subprocess, sys

def block(lines, start, indent):
    """The lines after `start` indented deeper than `indent`."""
    out = []
    for l in lines[start + 1:]:
        if l.strip() and not l.lstrip().startswith("#"):
            if len(l) - len(l.lstrip()) <= indent:
                break
        out.append(l)
    return out

def key_line(lines, key, indent):
    for i, l in enumerate(lines):
        if re.match(r"^" + " " * indent + re.escape(key) + r":(\s|$)", l):
            return i
    return -1

def items(lines, key):
    """`key: [a, b]` or a dash list under `key:`, at its own indentation."""
    for i, l in enumerate(lines):
        m = re.match(r"^(\s*)" + re.escape(key) + r":\s*(.*)$", l)
        if not m:
            continue
        rest = m.group(2).split("#")[0].strip()
        if rest.startswith("["):
            return [x.strip().strip("'\"") for x in rest.strip("[]").split(",") if x.strip()]
        out = []
        for d in block(lines, i, len(m.group(1))):
            dm = re.match(r"^\s*-\s*(.+?)\s*$", d)
            if dm and not d.lstrip().startswith("#"):
                out.append(dm.group(1).split(" #")[0].strip().strip("'\""))
        return out
    return None

def glob_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile("^" + out + "$")

def runs_guard(text):
    """Whether a non-comment line of the workflow runs the guard."""
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    return re.search(r"just test-sibling-cargo-locks\b|scripts/test-sibling-cargo-locks\.sh", body)

def check(path, tracked):
    text = open(path).read()
    lines = text.splitlines()
    errors = []
    on = key_line(lines, "on", 0)
    push = -1
    if on >= 0:
        trig = block(lines, on, 0)
        push = key_line(trig, "push", 2)
    if push < 0:
        return ["no push trigger"]
    push_block = block(trig, push, 2)
    branches = items(push_block, "branches") or []
    if "agents" not in branches:
        errors.append("push does not trigger on `agents` (branches: %s)" % branches)
    paths = items(push_block, "paths")
    if paths is not None:
        rx = [glob_re(p) for p in paths]
        must = [f for f in tracked if os.path.basename(f) in ("Cargo.lock", "Cargo.toml")]
        must += ["repro.lock", "flake.lock", "scripts/test-sibling-cargo-locks.sh",
                 ".github/workflows/" + os.path.basename(path)]
        for f in must:
            if not any(r.match(f) for r in rx):
                errors.append("the push path filter does not match %s" % f)
    body = "\n".join(l for l in lines if not l.lstrip().startswith("#"))
    if "CT_SIBLING_CARGO_LOCKS_STRICT=1" not in body:
        errors.append("the guard does not run STRICT (CT_SIBLING_CARGO_LOCKS_STRICT=1)")
    return errors

tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                         check=True).stdout.split()
targets = sys.argv[1:]
running = [t for t in targets if runs_guard(open(t).read())]
if not running:
    print("FAIL: no workflow runs the sibling Cargo.lock guard")
    sys.exit(1)
best = None
for t in running:
    errs = check(t, tracked)
    if not errs:
        print("OK: %s runs the guard on a push to agents, STRICT, on every file that "
              "can make a lock stale" % t)
        sys.exit(0)
    best = (t, errs) if best is None else best
for e in best[1]:
    print("FAIL: %s: %s" % (best[0], e))
sys.exit(1)
PY

LIVE=.github/workflows/sibling-cargo-locks.yml
pass=0
fail=0
expect() { # <want rc 0|1> <label> <needle in output or ""> <workflow files...>
	local want="$1" label="$2" needle="$3"
	shift 3
	local out rc
	out="$(python3 "$CHECKER" "$@" 2>&1)"
	rc=$?
	if { [ "$want" = 0 ] && [ "$rc" -eq 0 ]; } ||
		{ [ "$want" = 1 ] && [ "$rc" -eq 1 ] && [[ "$out" == *"$needle"* ]]; }; then
		pass=$((pass + 1))
		echo "ok   - $label"
	else
		fail=$((fail + 1))
		echo "FAIL - $label (rc=$rc)"
		printf '       %s\n' "$out"
	fi
}

expect 0 "the live workflows run the guard on agents, STRICT, on the lock files" "" \
	.github/workflows/*.yml

[ -f "$LIVE" ] || {
	echo "FAIL - $LIVE is missing"
	exit 1
}
mkdir -p "$TMP/wf"
sed -E 's/branches: \[main, dev, stable, agents\]/branches: [main, dev, stable]/' "$LIVE" >"$TMP/wf/no-agents.yml"
expect 1 "negative control: a copy without agents is refused" \
	"does not trigger on \`agents\`" "$TMP/wf/no-agents.yml"
awk 'BEGIN{n=0} /^      - .repro\.lock.$/ && n==0 {n=1; next} {print}' "$LIVE" >"$TMP/wf/no-repro-lock.yml"
expect 1 "negative control: a copy whose push filter misses repro.lock is refused" \
	"does not match repro.lock" "$TMP/wf/no-repro-lock.yml"
sed 's/CT_SIBLING_CARGO_LOCKS_STRICT=1 //' "$LIVE" >"$TMP/wf/no-strict.yml"
expect 1 "negative control: a copy that does not run STRICT is refused" \
	"does not run STRICT" "$TMP/wf/no-strict.yml"

echo "sibling-cargo-locks-workflow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
