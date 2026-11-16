#!/usr/bin/env bash
# ci/test/ct-build-gate-test.sh -- a step that runs past an earlier failure
# (`if: !cancelled()` / `always()`) and needs `ct` waits on the build of `ct`.
#
# In run 43806398582 the macOS leg's ct-mcr build failed, every step up to and
# including "Build CodeTracer (nix dev shell)" was skipped, and "Event Log stays
# static across a jump" -- `if: always()` -- still ran and failed both of its
# tests with `spawnSync .../bin/ct ENOENT`: one failure reported twice, the
# second time as something it was not.
#
# The rule, per job of every workflow (codetracer.yml and the reusable
# workflows it calls, tui-tests.yml and gpui-window-captures.yml): once a step with `id: ct` or
# `id: ct-darwin` (the job's build of ct) has been seen, every later step whose
# `if:` lets it run after a failure (`!cancelled()` or `always()`, without
# `failure()`) must name `steps.ct` / `steps.ct-darwin` in that `if:`. Uploads,
# cache saves and summaries (`Upload`/`Save`/`Show` steps) are exempt: they do
# not run ct.
#
# The negative control strips the gate back off the live file and requires the
# checker to name every step it just lost, so the check is shown to be able to
# fail on whatever the workflow currently contains.
set -euo pipefail
cd "$(dirname "$0")/../.."
workflows=(.github/workflows/*.yml)

check() {
	python3 - "$1" <<'EOF'
import re, sys
job = None; seen = False; step = None; bad = []
def close(st):
    if st is None or not seen or st.get('isbuild'):
        return
    cond = st.get('if', '')
    if not re.search(r'!cancelled\(\)|always\(\)', cond) or 'failure()' in cond:
        return
    if re.match(r'(Upload|Save|Show)\b', st.get('name', '')):
        return
    if not re.search(r'steps\.ct(-darwin)?\.outcome', cond):
        bad.append(f"{job}: {st.get('name')} (L{st['line']}): {cond}")
for n, line in enumerate(open(sys.argv[1]), 1):
    m = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', line)
    if m:
        close(step); step = None; job = m.group(1); seen = False
        continue
    if re.match(r'^      - ', line):
        close(step)
        step = {'line': n}
        m = re.match(r'^      - name:\s*(.*)$', line)
        if m: step['name'] = m.group(1).strip()
        continue
    if step is None:
        continue
    m = re.match(r'^        (name|id|if):\s*(.*)$', line)
    if m:
        k, v = m.group(1), m.group(2).strip()
        if k == 'id' and v in ('ct', 'ct-darwin'):
            seen = True; step['isbuild'] = True
        else:
            step[k] = v
close(step)
for b in bad: print('    ' + b)
sys.exit(1 if bad else 0)
EOF
}

failures=0
echo "== a step that needs ct and runs past a failure waits on the ct build"
for workflow in "${workflows[@]}"; do
	if out="$(check "$workflow")"; then
		echo "  ok   every such step in $(basename "$workflow") names its job's ct build"
	else
		echo "  FAIL steps in $(basename "$workflow") that can run without a ct:"
		echo "$out"
		failures=$((failures + 1))
	fi
done

gated=0
named=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for workflow in "${workflows[@]}"; do
	g="$(grep -c "steps\.ct\(-darwin\)\?\.outcome == 'success'" "$workflow" || true)"
	gated=$((gated + g))
	sed -e "s/ && (steps\.ct\.outcome == 'success' || steps\.ct-darwin\.outcome == 'success')//" \
		-e "s/ && steps\.ct\.outcome == 'success'//" "$workflow" >"$tmp"
	n="$(check "$tmp" | grep -c ': ' || true)"
	named=$((named + n))
done
if [ "$gated" -gt 0 ] && [ "$named" -eq "$gated" ]; then
	echo "  ok   with the gate stripped, the checker names all $gated steps it lost"
else
	echo "  FAIL with the gate stripped, the checker named $named of $gated steps"
	failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
	echo "ct-build-gate: $failures failure(s)"
	exit 1
fi
echo "ct-build-gate: ok"
