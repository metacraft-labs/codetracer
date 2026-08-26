#!/usr/bin/env bash
# =============================================================================
# Fail early, and by Tupfile:line, when a `: foreach <dir>/<glob>` rule names a
# directory that does not exist (or that holds none of the files the rule
# promises to publish).
#
# Why this exists -- issue #605. `src/public/resources/Tupfile:6` was added as
#
#     : foreach origin-icons/*.svg |> !tup_preserve |> %f
#
# while the eight SVGs still lived in `src/frontend/assets/origin-icons/`.
# tup expands a `foreach` glob at parse time and quietly produces ZERO rules
# when nothing matches, so the rule that was supposed to publish the icons
# published nothing. The build then failed several steps later, at the point
# where something tried to read the icons out of the variant tree -- an error
# that names neither the Tupfile nor the directory that was actually empty.
# (The assets were moved into place by b6a61ce7, so that specific instance is
# resolved; this check is what makes the NEXT one loud.)
#
# `!tup_preserve` rules are pure asset publication: a `foreach` over a
# directory that is not there is always a mistake -- either the rule names the
# wrong path or the assets were never added. There is no legitimate reading of
# "publish every file in a directory that does not exist".
#
# Deliberately NOT an error: a directory that exists but is empty, when the
# build itself is what fills it. `src/public/Tupfile:38` (`: foreach dist/*`)
# globs webpack's output directory, which `build-once.sh` creates with
# `mkdir -p` and webpack populates on the FIRST pass -- which is precisely why
# `build-once.sh` runs tup a second time afterwards. Those directories are
# listed in `generated_glob_dirs` below and only have to EXIST.
#
# Run:  bash scripts/require-tup-globs.sh [SRC_DIR]
# Lane: called by scripts/build-once.sh on the legacy tup branch, immediately
#       before the first `tup` invocation and after `mkdir -p src/public/dist`.
# =============================================================================
set -euo pipefail

src_dir="${1:-}"
if [ -z "$src_dir" ]; then
	src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../src" && pwd)"
fi

if [ ! -d "$src_dir" ]; then
	echo "scripts/require-tup-globs.sh: no such directory: $src_dir" >&2
	exit 1
fi

# Directories the build generates into. They must exist by the time tup parses
# (so the Tupfile's directory-ID lookup resolves) but may legitimately be empty
# on a first pass. Paths are relative to $src_dir. Override for experiments
# with CODETRACER_TUP_GENERATED_GLOB_DIRS (space-separated).
read -r -a generated_glob_dirs <<<"${CODETRACER_TUP_GENERATED_GLOB_DIRS:-public/dist}"

is_generated_dir() {
	local probe="$1" known
	for known in "${generated_glob_dirs[@]}"; do
		if [ "$probe" = "$known" ]; then
			return 0
		fi
	done
	return 1
}

failures=""
failure_count=0

# `-print0` / `read -d ''` so a path with a space cannot silently split.
while IFS= read -r -d '' tupfile; do
	tup_rel="${tupfile#"$src_dir"/}"
	tup_dir="$(dirname "$tupfile")"
	lineno=0
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		# Only rule lines. A leading '#' is a tup comment; the repo has
		# commented-out `foreach` rules (src/frontend/styles/Tupfile:7) that
		# must not be checked.
		case "$line" in
		:*foreach*) ;;
		*) continue ;;
		esac
		# `: foreach <pattern> |> ... |> ...` -- take the token after
		# `foreach`, up to the first `|>`.
		pattern="${line#*foreach}"
		pattern="${pattern%%|>*}"
		# Trim surrounding whitespace without invoking a subprocess.
		pattern="${pattern#"${pattern%%[![:space:]]*}"}"
		pattern="${pattern%"${pattern##*[![:space:]]}"}"
		# Only directory-qualified globs are checkable. A bare `*.*` globs the
		# Tupfile's own directory, which exists by construction.
		case "$pattern" in
		*/*) ;;
		*) continue ;;
		esac
		glob_dir="${pattern%/*}"
		glob_rel="${tup_rel%/Tupfile}/$glob_dir"
		abs_dir="$tup_dir/$glob_dir"

		if [ ! -d "$abs_dir" ]; then
			failure_count=$((failure_count + 1))
			failures="${failures}  * ${tup_rel}:${lineno}"$'\n'
			failures="${failures}      rule:      : foreach ${pattern} |> ... |>"$'\n'
			failures="${failures}      directory: ${glob_rel}  -- DOES NOT EXIST"$'\n'
			failures="${failures}      effect:    tup expands the glob to zero rules, so this rule"$'\n'
			failures="${failures}                 publishes nothing and the build fails later, elsewhere."$'\n'
			continue
		fi

		if is_generated_dir "${glob_rel}"; then
			continue
		fi

		# Expand the glob relative to the Tupfile's directory. `nullglob` makes
		# a non-matching pattern expand to nothing instead of to itself.
		# The `for` loop matters: `printf '%s\0' $pattern` would still run its
		# format once with zero arguments and emit a single empty record, so an
		# empty directory would look like one match.
		matches=()
		while IFS= read -r -d '' match; do
			matches+=("$match")
		done < <(
			cd "$tup_dir" && shopt -s nullglob
			# shellcheck disable=SC2086  # deliberate: $pattern is the glob.
			for entry in $pattern; do printf '%s\0' "$entry"; done
		)
		if [ ${#matches[@]} -eq 0 ]; then
			failure_count=$((failure_count + 1))
			failures="${failures}  * ${tup_rel}:${lineno}"$'\n'
			failures="${failures}      rule:      : foreach ${pattern} |> ... |>"$'\n'
			failures="${failures}      directory: ${glob_rel}  -- exists but MATCHES NO FILES"$'\n'
			failures="${failures}      effect:    tup expands the glob to zero rules, so this rule"$'\n'
			failures="${failures}                 publishes nothing and the build fails later, elsewhere."$'\n'
		fi
	done <"$tupfile"
done < <(find "$src_dir" -type f -name Tupfile -print0)

if [ "$failure_count" -eq 0 ]; then
	exit 0
fi

{
	echo "Cannot start the tup build: ${failure_count} \`: foreach\` rule(s) would expand to nothing."
	echo
	printf '%s' "$failures"
	cat <<'EOF'
Each rule above claims to publish a set of files into the tup variant tree and
would silently publish none. Fix it at the source:

  * the assets belong at the path the rule names -- move or add them (this is
    what issue #605 was: eight origin-icon SVGs sat under
    src/frontend/assets/origin-icons/ while the rule globbed
    src/public/resources/origin-icons/), or
  * the rule names the wrong path -- correct the Tupfile, or
  * the directory is filled by an earlier build step -- add it to
    `generated_glob_dirs` in scripts/require-tup-globs.sh, and make sure the
    step that fills it runs before tup (or that tup runs again afterwards, the
    way build-once.sh does for webpack's dist/).
EOF
} >&2
exit 1
