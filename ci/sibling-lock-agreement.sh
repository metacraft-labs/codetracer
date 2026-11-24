#!/usr/bin/env bash
# sibling-lock-agreement.sh -- every repro.lock build-input sibling beside this
# codetracer checkout sits at the revision repro.lock pins, except at most ONE
# named, acknowledged override.
#
# The launcher <-> recorder E2E gate builds codetracer with the CALLING
# recorder checked out at the commit under test, which is generally not the
# revision codetracer's lock pins for it: that difference is the thing the
# gate tests. It sets CODETRACER_OFF_LOCK_SIBLING to exactly that one name, and
# this check prints the override (name, lock revision, actual revision) to the
# log and the job summary and still fails on ANY other disagreement. The lock
# is never edited, so what the gate claims stays visible.
#
# Usage: sibling-lock-agreement.sh [CODETRACER_DIR]
#   CODETRACER_OFF_LOCK_SIBLING  the one sibling allowed off-lock (optional)
# Exit 0 when every present build-input sibling agrees (modulo the override).
set -euo pipefail

ct_dir="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
override="${CODETRACER_OFF_LOCK_SIBLING:-}"
lock="$ct_dir/repro.lock"

if [[ "$override" == *[,[:space:]]* ]]; then
	echo "sibling-lock-agreement: CODETRACER_OFF_LOCK_SIBLING names more than one sibling ('$override'); exactly one is allowed" >&2
	exit 1
fi

lock_rev() { # $1 = name -> the revision repro.lock pins, or ''
	grep -o "{ name = \"$1\", \\(self = \"true\", \\|path = \"[^\"]*\", \\)\\?coord_kind = \"vcs\", url = \"[^\"]*\", revision = \"[0-9a-f]*\"" "$lock" 2>/dev/null |
		sed 's/.*revision = "//; s/"$//' | head -n 1
}

inputs="$(bash "$ct_dir/ci/repro-lock-build-input-siblings.sh" "$lock")"
IFS=, read -r -a names <<<"$inputs"

if [ -n "$override" ] && [[ ",$inputs," != *",$override,"* ]]; then
	echo "sibling-lock-agreement: CODETRACER_OFF_LOCK_SIBLING='$override' is not a repro.lock build-input sibling, so it overrides nothing" >&2
	exit 1
fi

failures=()
for name in "${names[@]}"; do
	dir="$ct_dir/../$name"
	[ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
	want="$(lock_rev "$name")"
	have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
	[ -n "$want" ] && [ "$want" != "$have" ] || continue
	if [ "$name" = "$override" ]; then
		msg="acknowledged off-lock sibling: $name at $have (repro.lock pins $want)"
		echo "sibling-lock-agreement: $msg"
		if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
			printf -- '- %s\n' "$msg" >>"$GITHUB_STEP_SUMMARY"
		fi
	else
		failures+=("$name is at ${have:-<no HEAD>} but repro.lock pins $want")
	fi
done

if [ "${#failures[@]}" -gt 0 ]; then
	echo "sibling-lock-agreement: build-input siblings disagree with repro.lock:" >&2
	printf '  %s\n' "${failures[@]}" >&2
	exit 1
fi
echo "sibling-lock-agreement: every present build-input sibling agrees with repro.lock${override:+ (override: $override)}"
