#!/usr/bin/env bash
#
# tui-design-tokens-boundary.sh — the terminal front-end paints ONLY with the
# design system's tokens (PLAT-46 deliverables 1–3).
#
# WHY THIS EXISTS
# ---------------
# Every colour the TUI paints comes from `codetracer-design-system`, through
# the one generated module `src/frontend/styles/generated/design_tokens.nim`
# (written by `scripts/tokens-to-styl.sh`, the same run that writes the
# desktop's stylus). Views paint ROLES (`CellStyle(role: …)`), and
# `app/theme/roles.nim` binds each role to a token. Three ways to undo that
# compile cleanly and look fine on a screenshot, so they are refused here:
#
#   1. a hand-written `#rrggbb` anywhere under `src/frontend/tui/app/` — a
#      second palette, drifting from the design system the day it is written;
#   2. an ANSI colour NAME spelled as a string literal in a view or formatter
#      (`"red"`, `"bright_black"`) — the pre-PLAT-46 way of painting, which
#      cannot carry a 24-bit colour, cannot ask for a background role, and
#      re-creates the collisions `roleFor` had;
#   3. the reverse lookup `roleFor` coming back.
#
# WHAT IS SCANNED, AND WHAT IS NOT
# --------------------------------
# `src/frontend/tui/app/**/*.nim` EXCEPT `app/tests/`: a test that feeds
# `nearestAnsiName("#ff0000")` is asserting the mechanical projection on a
# literal CONTENT colour, which is exactly what it must be allowed to spell.
# Comments are stripped before the scan (`## … #1e1e2e …` in prose is not a
# colour anybody paints), and check 4 proves the stripper still leaves code
# behind while removing prose.
#
# The ANSI-name rule covers `app/views/` and `app/formatters/` — the painters.
# `app/theme/colour_math.nim` legitimately carries the sixteen names (it is the
# table of what the compositor accepts) and is outside that scope.
#
# CONTROLS (inside this file, like `tui-layer-split-boundary.sh`)
# ----------------------------------------------------------------
# Check 5 runs the same predicates over synthetic snippets and REQUIRES them to
# fire: a blocklist that has stopped matching passes every "must not contain"
# rule it makes (Verification-Harness-Traps §4).
#
# Usage: ci/test/tui-design-tokens-boundary.sh   (from anywhere in the repo)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

app=src/frontend/tui/app
fail=0
checks=0

strip_comments() {
	# Drop `##`/`#` comments that begin a line or follow code, but keep `#`
	# inside double-quoted strings (a hex literal IS a string).
	sed -E 's/^[[:space:]]*#.*$//' "$1" |
		awk '{
			out = ""; inq = 0
			for (i = 1; i <= length($0); i++) {
				c = substr($0, i, 1)
				if (c == "\"" ) inq = !inq
				if (c == "#" && !inq) break
				out = out c
			}
			print out
		}'
}

hex_hits() { grep -nE '"#[0-9A-Fa-f]{6}"|#[0-9A-Fa-f]{6}\b' || true; }
ansi_hits() {
	grep -nE '"(black|red|green|yellow|blue|magenta|cyan|white|bright_(black|red|green|yellow|blue|magenta|cyan|white))"' || true
}

mapfile -t app_files < <(find "$app" -name '*.nim' -not -path "$app/tests/*" | sort)
mapfile -t painter_files < <(find "$app/views" "$app/formatters" -name '*.nim' | sort)

# 1. No hand-written hex under app/ (outside tests).
checks=$((checks + 1))
hex_found=0
for f in "${app_files[@]}"; do
	hits="$(strip_comments "$f" | hex_hits)"
	if [ -n "$hits" ]; then
		echo "FAIL: hand-written #rrggbb in $f:" >&2
		printf '    %s\n' "${hits//$'\n'/$'\n    '}" >&2
		hex_found=1
	fi
done
[ "$hex_found" -eq 0 ] || fail=1

# 2. No ANSI colour name spelled as a literal in a painter.
checks=$((checks + 1))
ansi_found=0
for f in "${painter_files[@]}"; do
	hits="$(strip_comments "$f" | ansi_hits)"
	if [ -n "$hits" ]; then
		echo "FAIL: ANSI colour name painted directly in $f (paint a role):" >&2
		printf '    %s\n' "${hits//$'\n'/$'\n    '}" >&2
		ansi_found=1
	fi
done
[ "$ansi_found" -eq 0 ] || fail=1

# 3. The reverse lookup is gone.
checks=$((checks + 1))
if grep -rnE '\broleFor\*?\(' "$app/theme" "$app/views" >/dev/null 2>&1; then
	echo "FAIL: roleFor (the painted-style -> role reverse lookup) is back" >&2
	fail=1
fi

# 4. The stripper removes prose and keeps code.
checks=$((checks + 1))
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
printf '%s\n' '## a comment naming #1e1e2e' 'let x = "#abcdef" # trailing #123456' >"$probe"
stripped="$(strip_comments "$probe")"
if ! grep -q '"#abcdef"' <<<"$stripped" || grep -q '1e1e2e\|123456' <<<"$stripped"; then
	echo "FAIL: the comment stripper is broken: '$stripped'" >&2
	fail=1
fi

# 5. Positive controls: the predicates fire on what they forbid.
checks=$((checks + 1))
if [ -z "$(printf '%s\n' 'const X = CellStyle(fg: "#c678dd")' | hex_hits)" ] ||
	[ -z "$(printf '%s\n' 'const X = CellStyle(fg: "bright_black")' | ansi_hits)" ] ||
	[ -n "$(printf '%s\n' 'const X = CellStyle(role: srChromeMuted)' | hex_hits)$(printf '%s\n' 'const X = CellStyle(role: srChromeMuted)' | ansi_hits)" ]; then
	echo "FAIL: a predicate no longer tells a violation from a role" >&2
	fail=1
fi

# The population, so a walk that found nothing cannot pass.
if [ "${#app_files[@]}" -lt 50 ] || [ "${#painter_files[@]}" -lt 20 ]; then
	echo "FAIL: scanned ${#app_files[@]} app file(s) and ${#painter_files[@]} painter(s); the walk lost its population" >&2
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "OK: $checks checks over ${#app_files[@]} app module(s), ${#painter_files[@]} painter(s): no hand-written colour, no ANSI-name painting, no reverse lookup"
