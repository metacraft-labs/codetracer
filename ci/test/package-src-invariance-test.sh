#!/usr/bin/env bash
# ci/test/package-src-invariance-test.sh -- a commit outside a package's inputs
# leaves its derivation, and so its cached output, unchanged.
#
# The packages used the whole checkout as their source, so every commit -- a
# scenario, a test, a CI script -- changed every package's derivation, no cache
# push could cover the tree a CI run had, and the nixos leg rebuilt db-backend
# and codetracer from source (run 44081496736, cancelled at 150 minutes).
# nix/packages/default.nix now builds them from explicit file sets: the
# packages' source leaves out src/tests/, ci/, docs/, .github/ and nix/, and
# db-backend's holds only its crate and libraries.
#
# This evaluates db-backend's, codetracer's and codetracer-tui's drvPaths at the
# checkout, then with one tracked file edited at a time: each file OUTSIDE a
# package's inputs must leave its drvPath equal, and the control file, inside
# all of them, must change each (or the evaluation is not seeing edits at all).
# Every edited file is restored byte for byte. Run by ci/lint/nix.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

# file|packages it must leave unchanged
outside=(
	"src/tests/scenarios/lanes/terminal.lane.yaml|db codetracer tui"
	"ci/lint/bash.sh|db codetracer tui"
	"docs/UI-Design-Decisions.md|db codetracer tui"
	".github/workflows/codetracer.yml|db codetracer tui"
	"nix/shells/armShell.nix|db codetracer tui"
	"src/frontend/ui/CROSS_WINDOW_PANEL_TRANSFER.md|db"
)
control=src/db-backend/notes.md
for entry in "${outside[@]}" "$control|"; do
	f="${entry%%|*}"
	git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
		echo "  FAIL $f is not a tracked file; pick another"
		exit 1
	}
done

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
drvs() {
	# shellcheck disable=SC2016 # a Nix expression, not shell
	nix eval --raw ".?submodules=1#packages.${system}" --apply \
		'p: "db=${p.db-backend.drvPath} codetracer=${p.codetracer.drvPath} tui=${p.codetracer-tui.drvPath}"' 2>/dev/null
}
pick() { tr ' ' '\n' <<<"$1" | sed -n "s/^$2=//p"; }

backup="$(mktemp)"
edited=""
restore() {
	if [ -n "$edited" ]; then
		cat "$backup" >"$edited"
		edited=""
	fi
}
trap 'restore; rm -f "$backup"' EXIT
probe() {
	edited="$1"
	cat "$1" >"$backup"
	printf '\n# drvPath invariance probe\n' >>"$1"
	drvs
	restore
}

base="$(drvs)"
[ -n "$base" ] || {
	echo "  FAIL could not evaluate the packages' drvPaths"
	exit 1
}
for entry in "${outside[@]}"; do
	f="${entry%%|*}"
	after="$(probe "$f")"
	for pkg in ${entry#*|}; do
		if [ "$(pick "$after" "$pkg")" = "$(pick "$base" "$pkg")" ]; then
			ok "an edit to ${f} leaves ${pkg}'s derivation as it was"
		else
			fail "an edit to ${f} changed ${pkg}'s derivation: $(pick "$base" "$pkg" | sed 's|.*/||') -> $(pick "$after" "$pkg" | sed 's|.*/||')"
		fi
	done
done
after="$(probe "$control")"
for pkg in db codetracer tui; do
	if [ -n "$(pick "$after" "$pkg")" ] && [ "$(pick "$after" "$pkg")" != "$(pick "$base" "$pkg")" ]; then
		ok "control: an edit to ${control} changes ${pkg}'s derivation"
	else
		fail "control: an edit to ${control} did not change ${pkg}'s derivation, so the checks above prove nothing"
	fi
done

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
