#!/usr/bin/env bash
# ci/test/native-backend-submodules-test.sh -- codetracer-native-backend's
# submodules are checked out, with the job's credentials, before a
# `nix develop '.?submodules=1'` in it runs under the visual replay Git policy.
#
# The sibling is cloned without its submodules. Under the policy
# (ci/test/visual-replay-private-cargo-env.sh: https only), Nix's attempt to
# fetch libs/rr and libs/delve from the empty paths over file:// was refused,
# "transport 'file' not allowed" (run 44081496736, TUI shard 6); checked out,
# Nix reads them in place. libs/rr is private, so the checkout needs the job's
# credentials, which the policy and the gate step do not carry.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
line_of() { { grep -n -m1 -F -- "$2" "$1" || true; } | cut -d: -f1; }

f=ci/test/visual-replay-tools.sh
init="$(line_of "$f" 'submodule update --init --recursive')"
build="$(line_of "$f" "nix develop '.?submodules=1' --command cargo build --bin ct-native-replay")"
# shellcheck disable=SC2016 # the literal line, not an expansion
policy="$(line_of "$f" 'source "${root}/ci/test/visual-replay-private-cargo-env.sh"')"
if [ -n "$init" ] && [ -n "$build" ] && [ -n "$policy" ] && [ "$init" -lt "$build" ] && [ "$build" -lt "$policy" ]; then
	ok "$f checks out the submodules (line $init), builds ct-native-replay ($build), then applies the policy ($policy)"
else
	fail "$f: submodules line '${init}', build '${build}', policy '${policy}' -- want init < build < policy"
fi

w=.github/workflows/codetracer.yml
step="$(line_of "$w" "- name: Check out codetracer-native-backend's submodules")"
gate="$(line_of "$w" '- name: Run visual replay regression gate')"
if [ -n "$step" ] && [ -n "$gate" ] && [ "$step" -lt "$gate" ] &&
	sed -n "${step},$((step + 12))p" "$w" | grep -q 'codetracer-native-backend" submodule update --init --recursive'; then
	ok "$w checks out the submodules (line $step) before the gate step ($gate)"
else
	fail "$w: no submodule checkout step before 'Run visual replay regression gate'"
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
