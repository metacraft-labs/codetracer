#!/usr/bin/env bash
# =============================================================================
# Contract: `.envrc` loads the flake-overrides plugin from content that cannot
# change, and stops when the plugin does not load.
#
# # The defect
#
# When no `../direnv-nix-flake-overrides` checkout exists (CI clones, standalone
# clones), `.envrc` fetched the plugin with
#
#     source_url "https://direnv-flake-overrides.blocksense.network/plugin" \
#         "sha256-ixCgoLDPJelkuT5gukgffNxg9edSZEfVOK5QciktI74="
#
# That URL redirects to the upstream repository's moving `stable` branch. Its
# bytes changed on 2026-11-04, so direnv logged a hash mismatch, then
# `flake_override_args_quoted: command not found`, and the rest of `.envrc` ran
# anyway: `use flake '.?submodules=1'` was called with NO overrides, and
# `direnv exec` exited 0. CI that enters this repo through `direnv exec`
# (codetracer-ci's cross-repo legs) silently built against the flake-locked
# inputs instead of the sibling checkouts it had cloned.
#
# # What is asserted
#
#   1. The fallback URL names an upstream commit (40 hex digits), not a branch
#      or the unversioned redirect.
#   2. When the plugin cannot be fetched, the real `.envrc` fails: `direnv exec`
#      exits non-zero, does not run its command, and `use flake` is never
#      reached.
#   2b. A plugin that is sourced but does not define
#      `flake_override_args_quoted` stops `.envrc` the same way.
#   3. Positive control: with a sibling plugin checkout present, the same
#      `.envrc` loads, runs the command, and passes the plugin's override
#      arguments to `use flake`. Without this, (2) could pass because the
#      harness never gets as far as `use flake` for some unrelated reason.
#
# # Mocks, and why
#
# The `.envrc` under test is the committed file, run by the real `direnv` and
# its real stdlib. Two things are stubbed, through a scratch direnvrc:
#
#   - `use_flake` records its arguments instead of evaluating this repository's
#     flake. Evaluating the flake needs nix, the network and minutes; what this
#     contract is about is WHICH arguments `.envrc` hands to it, and whether it
#     is reached at all.
#   - `nix_direnv_version` answers "present", so `.envrc` does not fetch
#     nix-direnv from GitHub. That fetch is not the subject of this contract.
#
# The fetch failure in (2) is real: direnv's own `fetchurl` goes through an
# HTTPS proxy on a port nothing listens on, with an empty download cache. It is
# the same code path a hash mismatch takes (`fetchurl` exits non-zero).
#
# The sibling plugin in (3) is a stub that defines `flake_override_args_quoted`,
# because the real plugin runs `nix flake metadata` and the point of (3) is
# only that the harness can see override arguments arrive.
#
# Run: bash ci/test/envrc-flake-overrides-plugin-test.sh
# Lane: a step of `lint-bash` (bash + direnv + git, no nix, no network).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
ENVRC="${1:-$REPO_ROOT/.envrc}"
readonly ENVRC

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

for _tool in direnv git; do
	if ! command -v "$_tool" >/dev/null 2>&1; then
		echo "FAIL: '$_tool' is not on PATH; this suite cannot run" >&2
		exit 3
	fi
done
if [ ! -f "$ENVRC" ]; then
	echo "FAIL: $ENVRC does not exist" >&2
	exit 3
fi

# ---------------------------------------------------------------------------
# 1. The fallback URL is immutable.
# ---------------------------------------------------------------------------
echo "the flake-overrides plugin is fetched from a commit"

# Every URL in .envrc that points at the plugin, outside comments.
mapfile -t plugin_urls < <(
	grep -vE '^[[:space:]]*#' "$ENVRC" |
		grep -oE 'https://[^"'"'"'[:space:]]*(direnv-flake-overrides|direnv-nix-flake-overrides)[^"'"'"'[:space:]]*'
)
IMMUTABLE='^https://raw\.githubusercontent\.com/blocksense-network/direnv-nix-flake-overrides/[0-9a-f]{40}/plugin/flake-overrides\.bash$'

if [ "${#plugin_urls[@]}" -eq 0 ]; then
	fail ".envrc fetches the plugin from a URL" \
		"No plugin URL was found. The fallback for clones without a" \
		"../direnv-nix-flake-overrides checkout is gone, or this scanner stopped" \
		"matching it; either way this check compared nothing."
fi
for _u in "${plugin_urls[@]}"; do
	if [[ $_u =~ $IMMUTABLE ]]; then
		ok "plugin URL names an upstream commit: $_u"
	else
		fail "plugin URL names an upstream commit: $_u" \
			"A branch or redirect URL serves whatever the upstream publishes next;" \
			"on 2026-11-04 that broke the pinned hash and the dev shell loaded" \
			"without sibling overrides. Pin a reviewed commit's raw URL instead."
	fi
done
unset _u

# ---------------------------------------------------------------------------
# Harness for (2) and (3): a scratch workspace holding a copy of the committed
# .envrc, with direnv's config, data and cache directories all scratch.
# ---------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/config/direnv" "$SCRATCH/data" "$SCRATCH/cache" "$SCRATCH/ws/codetracer"
cat >"$SCRATCH/config/direnv/direnvrc" <<'EOF'
nix_direnv_version() { return 0; }
use_flake() { printf '%s\n' "$*" >>"$ENVRC_TEST_USE_FLAKE_LOG"; }
EOF
cp "$ENVRC" "$SCRATCH/ws/codetracer/.envrc"
# `.envrc` runs `git submodule update`; give it a repository of its own so it
# never touches this checkout.
git -C "$SCRATCH/ws/codetracer" init -q

# Run `direnv exec` on the scratch copy with nothing inherited from a direnv
# environment the caller may already be in. Prints the command's marker on
# stdout when the command runs; direnv's own log goes to $SCRATCH/direnv.log.
run_envrc() {
	rm -f "$SCRATCH/use_flake.log" "$SCRATCH/direnv.log"
	(
		cd "$SCRATCH/ws/codetracer" || exit 99
		unset DIRENV_DIR DIRENV_FILE DIRENV_DIFF DIRENV_WATCHES DIRENV_CONFIG \
			NO_NIX NO_PROXY no_proxy
		export XDG_CONFIG_HOME="$SCRATCH/config" XDG_DATA_HOME="$SCRATCH/data" \
			XDG_CACHE_HOME="$SCRATCH/cache" \
			ENVRC_TEST_USE_FLAKE_LOG="$SCRATCH/use_flake.log" \
			HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
			HTTP_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9
		direnv allow . 2>>"$SCRATCH/direnv.log"
		direnv exec . sh -c 'echo ENVRC_TEST_COMMAND_RAN' 2>>"$SCRATCH/direnv.log"
	)
}

# ---------------------------------------------------------------------------
# 2. A plugin that cannot be fetched stops .envrc.
# ---------------------------------------------------------------------------
echo
echo "a failed plugin fetch stops .envrc"

out="$(run_envrc)"
status=$?
if [ "$status" -ne 0 ]; then
	ok "direnv exec fails (exit $status)"
else
	fail "direnv exec fails" \
		"It exited 0: the dev shell loaded although the plugin did not." \
		"direnv log:" "$(sed 's/^/  /' "$SCRATCH/direnv.log")"
fi
if [ -z "$out" ]; then
	ok "the command is not run"
else
	fail "the command is not run" "It printed: $out"
fi
if [ ! -s "$SCRATCH/use_flake.log" ]; then
	ok "use flake is not reached"
else
	fail "use flake is not reached" \
		"It was called with: $(cat "$SCRATCH/use_flake.log")" \
		"That is a dev shell built from the flake-locked inputs, not the siblings."
fi
# The fetch failure has to be what stopped it, or this case proves nothing.
if grep -q 'proxyconnect\|connection refused' "$SCRATCH/direnv.log"; then
	ok "the fetch was attempted and failed"
else
	fail "the fetch was attempted and failed" \
		"direnv log:" "$(sed 's/^/  /' "$SCRATCH/direnv.log")"
fi
if grep -q 'plugin could not be fetched' "$SCRATCH/direnv.log"; then
	ok ".envrc reports the failed fetch as the reason it stopped"
else
	fail ".envrc reports the failed fetch as the reason it stopped" \
		"direnv log:" "$(sed 's/^/  /' "$SCRATCH/direnv.log")"
fi

# ---------------------------------------------------------------------------
# 2b. A plugin that loads but does not define the override function (a sibling
# checkout on a revision that renamed it, a truncated file) stops .envrc too.
# This is the only case that reaches the `declare -F` guard: in (2) the fetch
# failure already stops .envrc before it.
# ---------------------------------------------------------------------------
echo
echo "a plugin without flake_override_args_quoted stops .envrc"

mkdir -p "$SCRATCH/ws/direnv-nix-flake-overrides/plugin"
printf '# defines nothing\n' >"$SCRATCH/ws/direnv-nix-flake-overrides/plugin/flake-overrides.bash"

out="$(run_envrc)"
status=$?
if [ "$status" -ne 0 ] && [ -z "$out" ]; then
	ok "direnv exec fails without running the command (exit $status)"
else
	fail "direnv exec fails without running the command" \
		"exit $status, output '$out'; direnv log:" "$(sed 's/^/  /' "$SCRATCH/direnv.log")"
fi
if [ ! -s "$SCRATCH/use_flake.log" ]; then
	ok "use flake is not reached"
else
	fail "use flake is not reached" \
		"It was called with: $(cat "$SCRATCH/use_flake.log")"
fi
if grep -q 'did not define flake_override_args_quoted' "$SCRATCH/direnv.log"; then
	ok "the missing function is what stopped it"
else
	fail "the missing function is what stopped it" \
		"direnv log:" "$(sed 's/^/  /' "$SCRATCH/direnv.log")"
fi

# ---------------------------------------------------------------------------
# 3. Positive control: with a sibling plugin, override arguments arrive.
# ---------------------------------------------------------------------------
echo
echo "with a sibling plugin checkout, .envrc passes its overrides to use flake"

mkdir -p "$SCRATCH/ws/direnv-nix-flake-overrides/plugin"
cat >"$SCRATCH/ws/direnv-nix-flake-overrides/plugin/flake-overrides.bash" <<'EOF'
flake_override_args_quoted() { printf '%s' "--override-input envrc-test-input path:/envrc-test"; }
EOF

out="$(run_envrc)"
status=$?
if [ "$status" -eq 0 ] && [ "$out" = "ENVRC_TEST_COMMAND_RAN" ]; then
	ok "direnv exec loads and runs the command"
else
	fail "direnv exec loads and runs the command" \
		"exit $status, output '$out'; direnv log:" "$(sed 's/^/  /' "$SCRATCH/direnv.log")"
fi
if grep -qx -- ".?submodules=1 --override-input envrc-test-input path:/envrc-test" \
	"$SCRATCH/use_flake.log" 2>/dev/null; then
	ok "use flake receives the plugin's override arguments"
else
	fail "use flake receives the plugin's override arguments" \
		"use_flake was called with: $(cat "$SCRATCH/use_flake.log" 2>/dev/null || echo '<never>')"
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "PASS: $assertions assertions"
	exit 0
fi
echo "FAIL: $failures of $assertions assertions"
exit 1
