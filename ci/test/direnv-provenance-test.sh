#!/usr/bin/env bash
# =============================================================================
# Contract: `direnv` is run from THIS repo's dev shell, never from a sibling's.
#
# # The defect
#
# `src/db-backend/build.rs` shells out to `direnv exec <recorder-root> bash
# ct_emulator/build_native_api.sh`, and several CI steps run `direnv allow` on a
# freshly cloned sibling before that. `direnv` therefore has to be on PATH, and
# `nix/shells/ci-base.nix` declares it for exactly that reason -- with a comment
# recording the last time it was missing (run 30726348404, `direnv: not found`,
# exit 127).
#
# What that declaration cannot do is put direnv in SOMEBODY ELSE'S dev shell.
# `cross-repo-tests.yml`'s `rr-backend-tests` ran
#
#     nix develop "$CLONE_DIR" --command direnv allow ...
#
# where `$CLONE_DIR` is the cloned `codetracer-native-backend`. That repo's
# flake declares no direnv, so the step died the same way:
#
#     /tmp/nix-shell.gzS6Kp: line 2685: exec: direnv: not found
#     ##[error]Process completed with exit code 127.
#
# (run 32489213400, job `rr-backend-tests` -- the one run in months that got
# past the submodule unfold, which is what made this reachable at all.) Every
# other direnv call site in this repository already uses `nix develop .` /
# `.#ci` / `.?submodules=1#ci`; this one job was the exception, and it was
# invisible because an earlier step failed first.
#
# A sibling's dev shell is not this repository's to fix. So the contract is not
# "every shell must provide direnv" -- it is "reach for direnv in the shell
# whose flake we control".
#
# # What is asserted
#
#   1. `nix/shells/ci-base.nix` still declares `direnv`, and `devShells.default`
#      still composes ci-base. Both `devShells.ci` and `devShells.default` are
#      used as direnv hosts by the workflows, so if either premise stops
#      holding, the rule below is pointing people at a shell that cannot serve
#      them and this suite must fail rather than keep enforcing it.
#   2. No `nix develop <ref> ... direnv ...` in any workflow names a `<ref>`
#      outside this repository.
#   3. The scanner still matches real call sites (an exact count, so a rename
#      that silently stops matching is a failure and not a vacuous pass).
#
# # No mocks
#
# `.github/workflows/*.yml` and `nix/shells/*.nix` as committed are the input.
#
# Run: bash ci/test/direnv-provenance-test.sh
# Lane: a step of `lint-bash` (pure bash, no nix, no network).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
WORKFLOW_DIR="${1:-$REPO_ROOT/.github/workflows}"
readonly WORKFLOW_DIR

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

# ---------------------------------------------------------------------------
# 1. The premise: our own shells really do carry direnv.
# ---------------------------------------------------------------------------
echo "this repo's dev shells provide direnv"

CI_BASE="$REPO_ROOT/nix/shells/ci-base.nix"
MAIN_SHELL="$REPO_ROOT/nix/shells/main.nix"
CI_SHELL="$REPO_ROOT/nix/shells/ci.nix"

# A bare `direnv` on its own line is how ci-base.nix lists a package; the many
# comment lines that discuss direnv must not satisfy this.
if grep -qE '^[[:space:]]*direnv[[:space:]]*$' "$CI_BASE" 2>/dev/null; then
	ok "nix/shells/ci-base.nix declares direnv as a package"
else
	fail "nix/shells/ci-base.nix declares direnv as a package" \
		"Without it every 'nix develop . -c direnv ...' step in the workflows fails" \
		"with 'direnv: not found' / exit 127, and the rule this suite enforces --" \
		"'use OUR shell, not a sibling's' -- stops being true."
fi

for _s in "$MAIN_SHELL" "$CI_SHELL"; do
	_n="${_s#"$REPO_ROOT"/}"
	# `import ./ci-base.nix`, not a comment that mentions it. Both files open
	# with a header paragraph naming ci-base.nix, so a substring search here
	# is satisfied by prose and keeps passing after the import is changed --
	# which is exactly how this check first failed to catch its own mutation.
	if grep -qE '^[^#]*import[[:space:]]+\./ci-base\.nix' "$_s" 2>/dev/null; then
		ok "$_n composes ci-base.nix (so it inherits direnv)"
	else
		fail "$_n composes ci-base.nix (so it inherits direnv)" \
			"devShells.default and devShells.ci are both used as direnv hosts by the" \
			"workflows; one that no longer builds on ci-base may not carry direnv."
	fi
done
unset _s _n

# ---------------------------------------------------------------------------
# 2. Every direnv call site names one of THIS repo's dev shells.
#
# The scan joins bash line continuations first: the call sites are written
# across two or three lines, e.g.
#
#     nix develop "$CLONE_DIR" --command \
#       direnv allow "$(pwd)/../codetracer-native-recorder"
#
# so a line-at-a-time scanner sees `nix develop` and `direnv` separately and
# matches neither.
#
# A flake reference belonging to this repository starts with `.` -- `.`,
# `.#ci`, `.#devShells.x86_64-linux.default`, `.?submodules=1#ci`. Anything
# else (a variable holding a sibling path, an absolute path, a `github:` URL)
# is a shell this repository does not define and cannot add direnv to.
# ---------------------------------------------------------------------------
echo
echo "direnv is invoked from a dev shell this repo defines"

sites=0
foreign=()

for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
	[ -f "$wf" ] || continue
	wf_name="${wf##*/}"
	line_no=0
	joined=""
	start_line=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"
		# YAML comments are prose. Several of them quote the very command
		# this scanner looks for.
		case "$stripped" in '#'*) continue ;; esac
		if [ -z "$joined" ]; then start_line="$line_no"; fi
		case "$stripped" in
		*\\)
			joined="$joined ${stripped%\\}"
			continue
			;;
		esac
		joined="$joined $stripped"

		case "$joined" in
		*'nix develop'*direnv*)
			sites=$((sites + 1))
			# The token after `nix develop` is the flake reference. `nix
			# develop` with no reference at all means `.`, which is fine.
			ref="${joined#*nix develop}"
			ref="${ref#"${ref%%[![:space:]]*}"}"
			ref="${ref%% *}"
			# `nix develop '.?submodules=1#ci'` -- the shell quoting is
			# part of the workflow text, not part of the reference.
			ref="${ref#\'}"
			ref="${ref#\"}"
			case "$ref" in
			.* | '' | -*) ;;
			*)
				foreign+=("$wf_name:$start_line: 'nix develop $ref ... direnv' -- $ref is not a dev shell this repo defines")
				;;
			esac
			;;
		esac
		joined=""
	done <"$wf"
done

# The number of `nix develop ... direnv` call sites this repository is expected
# to have. An exact count, in the same spirit as EXPECTED_BUILD_SITES in
# ci/test/sibling-provisioning-test.sh: if a step is reworded and the scanner
# stops matching it, "no foreign shells were found" would be true and
# meaningless. Update it deliberately when a call site is added or removed --
# that is the moment to confirm the new one names `.`.
# 11 -> 12: #659 added a shell-BUILD probe beside the direnv probe in
# launcher-recorder-e2e.yml, so that "the shell did not build" and "the shell
# has no direnv" stop being reported as the same thing. It names `.`, so the
# rule below still holds; this count is what made the addition visible.
# 12 -> 13: `5103105f` added .github/workflows/deploy-web-codetracer.yml, whose
# `deploy` job drives the recorder sibling's wasm build through
#     nix develop .#ci --command \
#       direnv exec "$RECORDER_DIR" \
# (:117-118). That is the only site in that file this scanner matches -- its
# other `direnv` uses sit inside `bash -c '...'` strings rather than on a
# backslash-continued `nix develop` line -- and counting the workflows with
# only that one file removed still yields exactly 12. It names `.#ci`, a dev
# shell this repo defines, so the foreign-shell rule below still holds.
# 13 -> 17: dev-build and appimage-build each gained a `direnv allow` and a
# `direnv exec ... nimble install --depsOnly` site (four total), replicating
# lint-rust's native-recorder setup so their db-backend build.rs takes the
# direnv path. All four run `nix develop .#devShells.x86_64-linux.default -c
# direnv ...`, naming `.`'s dev shell, so the foreign-shell rule below holds.
readonly EXPECTED_SITES=17

if [ "$sites" -eq "$EXPECTED_SITES" ]; then
	ok "the scanner still matches the direnv call sites ($sites)"
else
	fail "the scanner still matches the direnv call sites" \
		"expected $EXPECTED_SITES 'nix develop ... direnv' call site(s), found $sites." \
		"If one was added or removed, check it names one of this repo's dev shells" \
		"and update EXPECTED_SITES. If neither, this scanner has stopped matching."
fi

if [ "${#foreign[@]}" -eq 0 ]; then
	ok "no direnv call site reaches for a sibling repo's dev shell"
else
	fail "no direnv call site reaches for a sibling repo's dev shell" \
		"A sibling's flake is not this repository's to fix, and codetracer-native-backend's" \
		"declares no direnv: 'exec: direnv: not found', exit 127 (run 32489213400)." \
		"${foreign[@]}"
fi

echo
readonly EXPECTED_ASSERTIONS=5
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
