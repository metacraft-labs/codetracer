#!/usr/bin/env bash
# Assert that the agent instructions name the directory the Playwright recipes
# actually run, so a new GUI test is written where a lane finds it.
#
# AGENTS.md § "Running Playwright e2e tests" once said the tests lived in
# `tsc-ui-tests/`, a directory the suite had moved out of. `just test-e2e`,
# `just test-gui-prebuilt` and `just test-gui` run `npx playwright test` from
# the suite's own directory, and Playwright collects specs only under that
# config's `testDir`, so a spec written where the instructions pointed was run
# by no recipe and no lane. One such spec had already been committed there.
#
# The expected directory is DERIVED, never hard-coded: it is read from the
# `cd` in the `test-e2e` recipe that precedes `npx playwright test`, after
# checking that `test-gui-prebuilt` and `test-gui` still delegate to it, and
# the spec directory is that config's `testDir`. Moving the suite therefore
# moves the expectation with it, and a broken derivation fails loudly instead
# of passing against an empty string.
#
# Two assertions, each against the checkout:
#   1. The AGENTS.md section names the config and its testDir, and every
#      directory path it names (a backticked token ending in `/`) lies inside
#      the suite directory.
#   2. No `*.spec.ts` the next commit would carry (tracked, or untracked and
#      not ignored) sits outside that testDir unless an ancestor
#      directory carries its own Playwright or Vitest config, i.e. it belongs
#      to a different, self-contained suite (the ct_test framework fixtures and
#      the HMR fixture are such suites).
#
# The checker is first run against a scratch tree built from the real justfile
# and Playwright config: a correct section with no stray spec must pass, and
# the old sentence and a stray spec must each fail. That proves the gate bites
# before its verdict on this checkout is trusted.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
section_title='## Running Playwright e2e tests'

# Print the indented body of a just recipe (lines after its header up to the
# next unindented, non-blank line).
recipe_body() {
	awk -v name="$2" '
		$0 ~ "^" name "( |:)" { inside = 1; next }
		inside && /^[^ \t#]/ { exit }
		inside { print }
	' "$1/justfile"
}

# Derive the Playwright suite directory (relative to the tree root) from the
# recipes. Prints it on success; prints FAIL lines and returns 1 otherwise.
derive_suite_dir() {
	local root="$1" body dir
	body="$(recipe_body "$root" test-e2e)"
	if ! grep -q 'npx playwright test' <<<"$body"; then
		echo "FAIL: the test-e2e recipe no longer runs 'npx playwright test'" >&2
		return 1
	fi
	# shellcheck disable=SC2016 # the pattern matches a literal ${CODETRACER_REPO_ROOT_PATH}
	dir="$(sed -n 's|.*cd "\{0,1\}\${CODETRACER_REPO_ROOT_PATH}/\([^" ]*\)"\{0,1\}.*|\1|p' <<<"$body" | head -n 1)"
	if [ -z "$dir" ]; then
		echo "FAIL: cannot find the directory test-e2e cds into before Playwright" >&2
		return 1
	fi
	if ! grep -q 'just test-e2e' <<<"$(recipe_body "$root" test-gui-prebuilt)"; then
		echo "FAIL: test-gui-prebuilt no longer delegates to test-e2e" >&2
		return 1
	fi
	if ! grep -q 'just test-gui-prebuilt' <<<"$(recipe_body "$root" test-gui)"; then
		echo "FAIL: test-gui no longer delegates to test-gui-prebuilt" >&2
		return 1
	fi
	printf '%s\n' "${dir%/}"
}

# Read `testDir` from the suite's Playwright config, relative to the tree root.
derive_test_dir() {
	local root="$1" dir="$2" config test_dir
	config="$root/$dir/playwright.config.ts"
	if [ ! -f "$config" ]; then
		echo "FAIL: the recipes run Playwright in $dir/, which has no playwright.config.ts" >&2
		return 1
	fi
	test_dir="$(sed -n 's|^[[:space:]]*testDir:[[:space:]]*"\([^"]*\)".*|\1|p' "$config" | head -n 1)"
	if [ -z "$test_dir" ]; then
		echo "FAIL: $dir/playwright.config.ts declares no string testDir" >&2
		return 1
	fi
	test_dir="${test_dir#./}"
	printf '%s/%s\n' "$dir" "${test_dir%/}"
}

# True when some ancestor directory of $2 (below the tree root) holds its own
# Playwright or Vitest config, i.e. the file belongs to a self-contained suite.
has_own_suite_config() {
	local root="$1" d
	d="$(dirname "$2")"
	while [ "$d" != "." ] && [ "$d" != "/" ]; do
		if compgen -G "$root/$d/playwright.config.*" >/dev/null ||
			compgen -G "$root/$d/vitest.config.*" >/dev/null; then
			return 0
		fi
		d="$(dirname "$d")"
	done
	return 1
}

# Run both assertions against the tree at $1 (a git work tree).
check_tree() {
	local root="$1" dir test_dir section token path status=0 spec
	dir="$(derive_suite_dir "$root")" || return 1
	test_dir="$(derive_test_dir "$root" "$dir")" || return 1

	section="$(awk -v title="$section_title" '
		$0 == title { inside = 1; next }
		inside && /^## / { exit }
		inside { print }
	' "$root/AGENTS.md")"
	if [ -z "$section" ]; then
		echo "FAIL: AGENTS.md has no '$section_title' section" >&2
		return 1
	fi
	if ! grep -qF "\`$test_dir/\`" <<<"$section"; then
		echo "FAIL: AGENTS.md '$section_title' does not name \`$test_dir/\`, the testDir the recipes run" >&2
		status=1
	fi
	if ! grep -qF "\`$dir/playwright.config.ts\`" <<<"$section"; then
		echo "FAIL: AGENTS.md '$section_title' does not name \`$dir/playwright.config.ts\`" >&2
		status=1
	fi
	# shellcheck disable=SC2016 # the backticks below are markdown code spans
	while IFS= read -r token; do
		path="${token//\`/}"
		path="${path%/}"
		case "$path" in
		"$dir" | "$dir"/*) ;;
		*)
			echo "FAIL: AGENTS.md '$section_title' names \`$path/\`, but the recipes run Playwright in $dir/" >&2
			status=1
			;;
		esac
	done < <(grep -o '`[^` ]*/`' <<<"$section" || true)

	# Tracked plus untracked-but-not-ignored files, minus deletions not yet
	# staged: the set the next commit would carry.
	while IFS= read -r spec; do
		[ -e "$root/$spec" ] || continue
		case "$spec" in
		"$test_dir"/* | */node_modules/*) continue ;;
		esac
		if has_own_suite_config "$root" "$spec"; then
			continue
		fi
		echo "FAIL: $spec is outside $test_dir/ and no recipe's Playwright config collects it" >&2
		status=1
	done < <(git -C "$root" ls-files --cached --others --exclude-standard -- '*.spec.ts' | sort -u)
	return "$status"
}

# --- Controls: prove the checker passes a correct tree and bites a wrong one.
control="$work/control"
mkdir -p "$control"
cp "$repo/justfile" "$control/justfile"
suite_dir="$(derive_suite_dir "$repo")"
suite_test_dir="$(derive_test_dir "$repo" "$suite_dir")"
mkdir -p "$control/$suite_dir" "$control/$suite_test_dir/example"
cp "$repo/$suite_dir/playwright.config.ts" "$control/$suite_dir/"
touch "$control/$suite_test_dir/example/example.spec.ts"
mkdir -p "$control/fixtures/other_suite/tests"
touch "$control/fixtures/other_suite/playwright.config.ts" \
	"$control/fixtures/other_suite/tests/other.spec.ts"
write_agents() {
	{
		echo '# Agents'
		echo
		echo "$section_title"
		echo
		echo "$1"
		echo
		echo '## Next section'
		echo
		# shellcheck disable=SC2016 # literal markdown backticks
		echo 'Mentions `elsewhere/` outside the section, which is not checked.'
	} >"$control/AGENTS.md"
}
good_text="The suite is \`$suite_dir/\`: config \`$suite_dir/playwright.config.ts\`, specs under \`$suite_test_dir/\`."
write_agents "$good_text"
git -C "$control" init -q
git -C "$control" add -A
if ! check_tree "$control" 2>"$work/err"; then
	cat "$work/err" >&2
	echo "FAIL: control: the checker rejects a correct tree" >&2
	exit 1
fi
echo "PASS: control: a correct section and suite layout pass"

# shellcheck disable=SC2016 # literal markdown backticks: the sentence the gate exists to reject
write_agents 'The Playwright tests live in `tsc-ui-tests/`. They launch the real Electron app.'
if check_tree "$control" 2>"$work/err"; then
	echo "FAIL: control: the checker accepts the stale 'tsc-ui-tests/' sentence" >&2
	exit 1
fi
# shellcheck disable=SC2016 # literal markdown backticks
grep -q 'names `tsc-ui-tests/`' "$work/err" || {
	cat "$work/err" >&2
	echo "FAIL: control: the stale sentence failed for the wrong reason" >&2
	exit 1
}
echo "PASS: control: the stale 'tsc-ui-tests/' sentence is rejected"

write_agents "$good_text"
mkdir -p "$control/tsc-ui-tests/tests/elixir"
touch "$control/tsc-ui-tests/tests/elixir/stray.spec.ts"
git -C "$control" add -A
if check_tree "$control" 2>"$work/err"; then
	echo "FAIL: control: the checker accepts a spec no recipe runs" >&2
	exit 1
fi
grep -q 'tsc-ui-tests/tests/elixir/stray.spec.ts is outside' "$work/err" || {
	cat "$work/err" >&2
	echo "FAIL: control: the stray spec failed for the wrong reason" >&2
	exit 1
}
echo "PASS: control: a tracked spec outside the testDir is rejected"

# --- The real checkout.
if ! check_tree "$repo"; then
	echo "FAIL: AGENTS.md or the spec layout disagrees with the Playwright recipes" >&2
	exit 1
fi
echo "PASS: AGENTS.md names $suite_test_dir/, and every tracked spec is in a suite a config collects"
