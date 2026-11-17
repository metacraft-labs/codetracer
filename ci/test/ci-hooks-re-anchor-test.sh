#!/usr/bin/env bash
# ci/test/ci-hooks-re-anchor-test.sh -- on a CI runner the dev shell re-anchors
# Repro hooks a different Repro build wrote; on a workstation it does not.
#
# Persistent runners keep the checkout's .git/hooks between jobs. When the
# reprobuild pin moved (0.2.24 -> 0.2.25), `repro hooks ensure --vcs` refused
# the hooks the old build had written and failed sibling provisioning on every
# gpu-server-002 job (run 44081496736). nix/git-hooks.nix now passes
# `--re-anchor` when GITHUB_ACTIONS=true. This runs that part of the shell hook
# with a fake `repro` that records its arguments, both ways, and fails a
# shell hook that drops the flag or passes it outside CI.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repro/bin"
cat >"$work/repro/bin/repro" <<FAKE
#!/usr/bin/env bash
echo "\$*" >"$work/args"
FAKE
chmod +x "$work/repro/bin/repro"

# The shell hook from its `ct_repro_anchor=()` to the `ensure` call's closing
# brace, with Nix's escapes undone and `${repro}` pointed at the fake.
snippet="$(sed -n '/^  ct_repro_anchor=()$/,/^  unset ct_repro_anchor$/p' nix/git-hooks.nix |
	sed -e "s|''\\\${|\${|g" -e "s|\\\${repro}|$work/repro|g")"
if [ -z "$snippet" ]; then
	fail "nix/git-hooks.nix has no ct_repro_anchor block: the shell hook no longer re-anchors in CI"
else
	for ci in true ""; do
		rm -f "$work/args"
		(
			export GITHUB_ACTIONS="$ci" ROOT_PATH=/checkout
			eval "$snippet"
		) >/dev/null 2>&1 || true
		args="$(cat "$work/args" 2>/dev/null || echo '<not called>')"
		if [ "$ci" = true ]; then
			want="hooks ensure --vcs --re-anchor /checkout"
		else
			want="hooks ensure --vcs /checkout"
		fi
		if [ "$args" = "$want" ]; then
			ok "GITHUB_ACTIONS='${ci}': repro ${args}"
		else
			fail "GITHUB_ACTIONS='${ci}': repro ${args} (want: repro ${want})"
		fi
	done
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
