#!/usr/bin/env bash
# PLAT-40 — every pane producer has a caller a USER can reach.
#
# **THE DISTINCTION THIS GATE EXISTS TO MAKE.** *A unit test is a production
# caller as far as a coverage tool is concerned, and is not one as far as a user
# is concerned.* PLAT-23 recorded the consequence at least eight separate times
# — *"the mechanism works and nothing feeds it"* — and named the instrument that
# finds it: **`grep` for the call site, run against the SHIPPED tree**. It took
# until PLAT-22 for anyone to run the binary.
#
# The defect is invisible to every other check in this repository. The producer
# compiles, its unit tests pass, its ViewModel is correct, and the pane draws a
# well-formed apology. `requestAndLoadCalltrace` had NINE callers when this gate
# was written and every one of them was under `tests/`, so `getCalltraceLines()`
# returned an empty sequence on every real run and `callBoundaries` was silently
# always `@[]`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# `|| exit` because a cd that fails would run every path below against the
# WRONG TREE and report a confident answer about it (SC2164).
cd "$ROOT" || exit 1

fail=0
note() { printf '  %s\n' "$*"; }
bad() {
	printf 'FAIL: %s\n' "$*"
	fail=1
}

# The producers this milestone is about. Declared by name rather than derived,
# because "which procs are pane producers" is a judgement about MEANING that no
# directory listing answers. What IS mechanical, and is checked below, is that
# each name still exists in the tree — so a rename fails this gate loudly rather
# than silently emptying it, which is the §35 failure mode in its other
# direction.
PRODUCERS=(
	requestAndLoadCalltrace
	requestAndLoadEventLog
	applyCollections
)

# A file is a TEST if it lives under a tests/ directory or its name says so.
# Matched on the path, and the pattern is deliberately generous: a false
# "this is a test" makes the gate STRICTER, never weaker.
is_test_path() {
	case "$1" in
	*/tests/* | */test_* | *_test.nim | */storybook_components.nim) return 0 ;;
	*) return 1 ;;
	esac
}

# Count callers of $1 outside test paths. A DECLARATION is not a call, so the
# line that defines the proc is excluded — otherwise every producer trivially
# "has a caller", which is the shape of a check that cannot fail.
production_callers() {
	local name="$1" n=0
	while IFS= read -r line; do
		local file="${line%%:*}"
		local text="${line#*:}"
		text="${text#*:}"
		is_test_path "$file" && continue
		case "$text" in
		*"proc $name"* | *"func $name"* | *"template $name"*) continue ;; # declaration
		*"##"*) continue ;;                                               # doc comment
		esac
		# A line whose first non-space character is '#' is a comment, not a call.
		local trimmed="${text#"${text%%[![:space:]]*}"}"
		case "$trimmed" in \#*) continue ;; esac
		n=$((n + 1))
	done < <(grep -rn --include='*.nim' "\b$name\b" src 2>/dev/null)
	echo "$n"
}

echo "=== PLAT-40: production callers for the pane producers ==="
for p in "${PRODUCERS[@]}"; do
	# The name must still EXIST. A renamed producer would otherwise score zero
	# callers and be reported as unfed, which is a true-looking failure for the
	# wrong reason — and worse, a DELETED producer would look identical.
	decls=$(grep -rn --include='*.nim' -E "^\s*(proc|func|template)\s+$p\b" src 2>/dev/null | wc -l)
	if [ "$decls" -eq 0 ]; then
		bad "$p is not declared anywhere in src/. Renamed or deleted?"
		continue
	fi
	n=$(production_callers "$p")
	if [ "$n" -eq 0 ]; then
		bad "$p has NO caller outside tests/ — the mechanism works and nothing feeds it."
	else
		note "$p: $n production caller(s)"
	fi
done

# --- THE POSITIVE CONTROL -----------------------------------------------------
# A gate that cannot go red is not evidence. A producer with test-only callers
# is planted and the scan is required to report it.
PLANT_SRC="src/frontend/tui/tests/.plat40_control_test.nim"
# shellcheck disable=SC2329  # invoked by the `trap` below, not directly.
cleanup() { rm -f "$PLANT_SRC"; }
trap cleanup EXIT

mkdir -p "$(dirname "$PLANT_SRC")"
cat >"$PLANT_SRC" <<'EOF'
# PLAT-40 gate control. Calls a producer that exists nowhere else, FROM A TEST
# PATH, so the scan must report it as having no production caller.
proc plat40ControlProducer*() = discard
plat40ControlProducer()
EOF

control_n=$(production_callers plat40ControlProducer)
if [ "$control_n" -eq 0 ]; then
	note "positive control fired: a test-only producer scores 0 production callers"
else
	bad "POSITIVE CONTROL DID NOT FIRE: a producer called only from a test path" \
		"scored $control_n production caller(s). The scan counts test callers as" \
		"production ones, so its green means nothing."
fi
rm -f "$PLANT_SRC"

# --- THE NEGATIVE CONTROL -----------------------------------------------------
# And a producer called from a real path must score at least one, or the scan
# is simply reporting zero for everything.
if [ "$(production_callers requestAndLoadEventLog)" -ge 1 ]; then
	note "negative control silent: a genuinely-fed producer scores > 0"
else
	bad "NEGATIVE CONTROL FIRED: requestAndLoadEventLog scored 0, but" \
		"tui_session.nim calls it. The scan is under-counting."
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "OK: every declared pane producer has a caller a user can reach."
	exit 0
fi
echo "PLAT-40 production-caller gate FAILED"
exit 1
