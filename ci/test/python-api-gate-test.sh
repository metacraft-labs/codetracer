#!/usr/bin/env bash
# Exercise the real recipe against a filesystem copy, including an intentionally
# failing pytest test. No command mocks: failure must travel through pytest and
# just. The copy keeps the developer's suite and state untouched.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$root"
just --dry-run test >"$work/aggregate" 2>&1
if ! grep -Eq '^[[:space:]]*test-python-api[[:space:]\\]*$' "$work/aggregate"; then
	echo 'FAIL: just test does not invoke test-python-api' >&2
	exit 1
fi
# Pin the two existing CI edges as executable lines, rather than accepting
# documentation mentioning a recipe that no job actually invokes.
if ! grep -Eq '^[[:space:]]*run: \./ci/test/non-gui\.sh[[:space:]]*$' .github/workflows/codetracer.yml ||
	! grep -Eq '^[[:space:]]*just test[[:space:]]*$' ci/test/non-gui.sh; then
	echo 'FAIL: non-GUI CI no longer invokes just test' >&2
	exit 1
fi
mkdir -p "$work/ci/lib"
cp justfile "$work/justfile"
cp ci/lib/codetracer-home.sh "$work/ci/lib/"
cp -R python-api "$work/python-api"
# This new file proves discovery is directory-wide, rather than a fixed list
# of the tests present when the recipe was introduced.
cat >"$work/python-api/tests/test_gate_probe.py" <<'PY'
import os

def test_gate_probe():
    assert os.environ.get("CODETRACER_HOME"), "test lane must isolate state"
    assert False, "python-api-gate-intentional-failure"
PY
if just --justfile "$work/justfile" test-python-api >"$work/failure" 2>&1; then
	cat "$work/failure" >&2
	echo 'FAIL: the Python API recipe hid a failing test' >&2
	exit 1
fi
if ! grep -q 'python-api-gate-intentional-failure' "$work/failure"; then
	cat "$work/failure" >&2
	echo 'FAIL: recipe failed before executing the injected pytest test' >&2
	exit 1
fi
# Removing only the intentional assertion must make the same real invocation
# pass; missing dependencies, imports, or recipe errors cannot satisfy this test.
sed -i.bak '/assert False/d' "$work/python-api/tests/test_gate_probe.py"
just --justfile "$work/justfile" test-python-api
printf '%s\n' 'PASS: Python API gate discovers new tests and propagates failures'
