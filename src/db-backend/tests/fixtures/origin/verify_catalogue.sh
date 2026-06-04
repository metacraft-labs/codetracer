#!/usr/bin/env bash
#
# verify_origin_fixtures_catalogue — M0 verification.
#
# Asserts that every language directory under
# `tests/fixtures/origin/<lang>/` contains all five canonical scenarios
# with both source file(s) and ANSWERS.md. Recorded trace presence is
# advisory — the canonical-scenario coverage check is the substance
# (per the M0 deliverable text: "Recorded trace presence may be
# optional or marked TODO").
#
# Exit non-zero with a clear error message if any language is missing a
# scenario, source file, or ANSWERS.md.
#
# Usage:
#     src/db-backend/tests/fixtures/origin/verify_catalogue.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

LANGUAGES=(python ruby javascript c rust nim go)
SCENARIOS=(
	simple_trivial_chain
	computational_origin
	parameter_pass
	return_capture
	destructuring_or_index
)

# Per-language file extension (the recognised source extensions for
# each recorder). A scenario passes the source-file check if at least
# one file with the language's extension exists in its directory.
declare -A SOURCE_EXT=(
	[python]=".py"
	[ruby]=".rb"
	[javascript]=".js"
	[c]=".c"
	[rust]=".rs"
	[nim]=".nim"
	[go]=".go"
)

errors=()

check_file_present_with_ext() {
	local dir="$1" ext="$2" label="$3"
	if ! find "$dir" -maxdepth 1 -type f -name "*${ext}" -print -quit | grep -q .; then
		errors+=("$label: no source file matching *$ext in $dir")
	fi
}

for lang in "${LANGUAGES[@]}"; do
	lang_dir="$HERE/$lang"
	if [[ ! -d $lang_dir ]]; then
		errors+=("$lang: language directory missing at $lang_dir")
		continue
	fi
	if [[ ! -x "$lang_dir/regenerate.sh" ]]; then
		errors+=("$lang: per-language regenerate.sh missing or not executable at $lang_dir/regenerate.sh")
	fi
	ext="${SOURCE_EXT[$lang]}"
	for sc in "${SCENARIOS[@]}"; do
		sc_dir="$lang_dir/$sc"
		label="$lang/$sc"
		if [[ ! -d $sc_dir ]]; then
			errors+=("$label: scenario directory missing at $sc_dir")
			continue
		fi
		check_file_present_with_ext "$sc_dir" "$ext" "$label"
		if [[ ! -f "$sc_dir/ANSWERS.md" ]]; then
			errors+=("$label: ANSWERS.md missing at $sc_dir/ANSWERS.md")
		fi
		if [[ ! -x "$sc_dir/regenerate.sh" ]]; then
			errors+=("$label: regenerate.sh missing or not executable at $sc_dir/regenerate.sh")
		fi
		# Recorded trace presence is advisory in M0 — not a failure.
		if [[ ! -d "$sc_dir/trace" && ! -e "$sc_dir/trace" ]]; then
			echo "advisory: $label has no recorded trace yet (M0: OK)" >&2
		fi
	done
done

# Top-level orchestrator + the canonical user-patterns fixture must
# also exist for the catalogue to be considered complete.
for required in \
	"$HERE/regenerate-fixtures.sh" \
	"$HERE/user-patterns/ANSWERS.md" \
	"$HERE/user-patterns/_overrides.toml" \
	"$HERE/user-patterns/home-overrides/origin-patterns.toml" \
	"$HERE/user-patterns/faux-library/.codetracer/origin-patterns.toml"; do
	if [[ ! -e $required ]]; then
		errors+=("user-patterns/top-level: required path missing: $required")
	fi
done
if [[ ! -x "$HERE/regenerate-fixtures.sh" ]]; then
	errors+=("regenerate-fixtures.sh exists but is not executable")
fi

if ((${#errors[@]} > 0)); then
	echo "" >&2
	echo "verify_origin_fixtures_catalogue FAILED — ${#errors[@]} issue(s):" >&2
	for e in "${errors[@]}"; do
		echo "  - $e" >&2
	done
	exit 1
fi

echo "verify_origin_fixtures_catalogue: all ${#LANGUAGES[@]} languages have all ${#SCENARIOS[@]} canonical scenarios with source + ANSWERS.md."
echo "verify_origin_fixtures_catalogue: top-level orchestrator + user-patterns fixture present."
exit 0
