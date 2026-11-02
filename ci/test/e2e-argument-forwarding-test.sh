#!/usr/bin/env bash
# Exercise the real just recipes, including the nested Storybook guard. npm and
# npx are recording doubles: installing dependencies and launching Electron
# cannot add evidence about argv received at those external process boundaries.
# Capture recipes use a recording bash only at the capture-script boundary;
# their recording/build prerequisites are unrelated to argument forwarding.
# A recording uname selects the native-display branch of inline captures so
# their Xvfb setup does not require a display server for an argv assertion.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
real_just="$(command -v just)"
real_bash="$(command -v bash)"
export real_bash
mkdir -p "$work/bin" "$work/tree/src/tests/gui" "$work/tree/ci/lib"
cp "$repo/justfile" "$work/tree/justfile"
cp "$repo/ci/lib/npm-install.sh" "$work/tree/ci/lib/"
cat >"$work/bin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$work/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$ARGV_LOG"
EOF
cat >"$work/bin/bash" <<'EOF'
#!/bin/sh
case "$1" in
  scripts/plat*-capture-electron.sh)
    printf '%s\0' "$@" > "$ARGV_LOG"
    ;;
  *) exec "$real_bash" "$@" ;;
esac
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" DISPLAY=:argument-test
export CODETRACER_REPO_ROOT_PATH="$work/tree" ARGV_LOG="$work/actual"
# Nested `just` calls use the real executable and the copied, unmodified recipe
# file. Work in a scratch tree so npm's lock handling cannot touch this checkout.
ln -s "$real_just" "$work/bin/just"
cd "$work/tree"
check() {
	local recipe="$1" prefix="$2"
	shift 2
	rm -f "$ARGV_LOG"
	if ! just "$recipe" "$@" >"$work/output" 2>&1; then
		cat "$work/output" >&2
		echo "FAIL: $recipe rejected a valid argument" >&2
		return 1
	fi
	if [ "$prefix" = playwright ]; then
		printf '%s\0' playwright test --workers=1 "$@" >"$work/expected"
	else
		printf '%s\0' "$prefix" "$@" >"$work/expected"
	fi
	if ! cmp "$work/expected" "$ARGV_LOG"; then
		echo "FAIL: $recipe changed argument boundaries" >&2
		return 1
	fi
	echo "PASS: $recipe preserves $# arguments"
}
# The reported regression, followed by quotes, metacharacters, glob syntax,
# newlines and the empty string. These must remain data in both recipe layers.
check test-e2e playwright tests/visual/plat51-desktop-capture.spec.ts -g 'Call Trace'
# shellcheck disable=SC2016 # Shell syntax is deliberately passed as data.
check test-e2e playwright tests/example.spec.ts -g "caller's \"Call Trace\"" '[ab]*' '$(touch must-not-exist)' $'line\nbreak' ''
for number in 45 47 48 49 50 51 52; do
	check "plat${number}-capture-electron" "scripts/plat${number}-capture-electron.sh" -g "caller's Call Trace" ''
done
test ! -e must-not-exist
# The older capture recipes keep platform orchestration inline. Select their
# native-display branch with uname so this argument test needs no X server.
cat >"$work/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
chmod +x "$work/bin/uname"
for pair in \
	'35:visual-alignment-capture' \
	'40:plat40-panes-capture' \
	'41:plat41-parity-capture' \
	'46:plat46-token-parity-capture'; do
	number="${pair%%:*}"
	spec="${pair#*:}"
	just "plat${number}-capture-electron" -g "caller's Call Trace" ''
	printf '%s\0' playwright test --workers=1 "tests/visual/$spec.spec.ts" -g "caller's Call Trace" '' >"$work/expected"
	cmp "$work/expected" "$ARGV_LOG"
	echo "PASS: plat${number}-capture-electron preserves argument boundaries"
done
check test-gui-prebuilt playwright tests/example.spec.ts -g "caller's Call Trace" ''
# These wrappers normally build the application and recorders first. Omit only
# those build prerequisites; their real forwarding bodies and nested recipes
# still execute against the same external argv recorder.
for recipe in test-gui test-gui-visible; do
	just --no-deps "$recipe" tests/example.spec.ts -g "caller's Call Trace" ''
	printf '%s\0' playwright test --workers=1 tests/example.spec.ts -g "caller's Call Trace" '' >"$work/expected"
	cmp "$work/expected" "$ARGV_LOG"
	echo "PASS: $recipe preserves argument boundaries"
done
for pair in \
	'test-event-log-static:tests/event-log/event_log_is_static_across_jumps.spec.ts' \
	'test-hcr-launch-under-hcr:tests/hcr-live-edit/flame_launch_under_hcr.spec.ts'; do
	just "${pair%%:*}" -g "caller's Call Trace" ''
	printf '%s\0' playwright test --workers=1 "${pair#*:}" -g "caller's Call Trace" '' >"$work/expected"
	cmp "$work/expected" "$ARGV_LOG"
	echo "PASS: ${pair%%:*} preserves argument boundaries"
done
