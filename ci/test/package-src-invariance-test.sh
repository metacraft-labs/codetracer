#!/usr/bin/env bash
# ci/test/package-src-invariance-test.sh -- a commit outside a package's inputs
# leaves its derivation, and so its cached output, unchanged.
#
# db-backend used the whole checkout as its source, so every commit changed its
# derivation, no cache push could cover the tree a CI run had, and the nixos leg
# rebuilt it from source for over 100 minutes (run 44081496736, cancelled at
# 150 minutes). nix/packages/default.nix now builds it from an explicit file
# set: its crate and the libraries its manifests reach.
#
# This evaluates db-backend's drvPath at the checkout, then with one tracked
# file edited at a time: each file OUTSIDE its inputs must leave the drvPath
# equal, and the control file, inside them, must change it (or the evaluation
# is not seeing edits at all).
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
	"src/tests/scenarios/lanes/terminal.lane.yaml|db"
	"ci/lint/bash.sh|db"
	"docs/UI-Design-Decisions.md|db"
	".github/workflows/codetracer.yml|db"
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
		'p: "db=${p.db-backend.drvPath}"' 2>/dev/null
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
if [ -n "$(pick "$after" db)" ] && [ "$(pick "$after" db)" != "$(pick "$base" db)" ]; then
	ok "control: an edit to ${control} changes db's derivation"
else
	fail "control: an edit to ${control} did not change db's derivation, so the checks above prove nothing"
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
