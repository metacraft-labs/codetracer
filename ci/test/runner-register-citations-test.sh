#!/usr/bin/env bash
#
# runner-register-citations-test.sh -- keep ci/runner/README.md honest.
#
# WHY A DOCUMENT NEEDS A GATE
# ---------------------------
# The register exists because this list previously lived only in one person's
# head and was recounted from memory as five when it was seven. Moving it into
# the tree fixes that exactly once; without a check it then rots in the usual
# way -- the assertion gets corrected and the sentence describing it does not,
# and a register nobody trusts is worth no more than the memory it replaced.
#
# So this suite pins the parts of the document that can be MECHANICALLY checked:
#
#   * every repository file it cites exists;
#   * every gate it claims is wired into a lane really is;
#   * every commit it cites is a real commit;
#   * the scoreboard still has one row per defect, and the count is the
#     reconciled SEVEN.
#
# Line numbers are deliberately NOT asserted: they drift on every edit to the
# workflow, and a check that fails for a true document teaches people to delete
# the check. Existence and count are the durable claims.
#
# Pure bash + git. No nix, no network.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTER="$REPO_ROOT/ci/runner/README.md"
LINT="$REPO_ROOT/ci/lint/bash.sh"

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

printf 'the self-hosted runner defect register\n'

if [ ! -f "$REGISTER" ]; then
	printf 'FAIL: %s is missing -- the register is back in someone'"'"'s head\n' "$REGISTER"
	exit 1
fi

# --- 1: every repository path it cites exists ------------------------------
# Only paths under directories this repository owns. The register also cites
# `libs/repro_daemon_core/...`, which lives in reprobuild, and asserting that
# from here would fail for a correct document.
missing=0
checked_paths=0
# shellcheck disable=SC2016  # the backticks below are literal MARKDOWN
# delimiters being matched inside the document, not command substitution.
while IFS= read -r path; do
	checked_paths=$((checked_paths + 1))
	if [ ! -e "$REPO_ROOT/$path" ]; then
		fail "cited path exists: $path" \
			"The register names a file this repository does not have."
		missing=$((missing + 1))
	fi
done < <(grep -oE '`(ci|scripts|nix|\.github)/[A-Za-z0-9._/-]+`' "$REGISTER" |
	tr -d '`' | sort -u)

if [ "$checked_paths" -eq 0 ]; then
	fail "the register cites at least one repository path" \
		"Extracted zero paths -- the extraction broke, or the document lost its" \
		"citations. Either way this suite is measuring nothing."
elif [ "$missing" -eq 0 ]; then
	ok "all $checked_paths cited repository paths exist"
fi

# --- 2: every gate it names is wired into the bash lint lane ---------------
# The register's value is that a reader can trust "Gate: X". A named gate that
# no lane runs is the "unrun check" defect the lane comments already warn about.
gates=(
	ci/test/reprobuild-daemon-guard-test.sh
	ci/test/detect-siblings-recorder-artifacts-test.sh
	ci/test/recorder-clone-implies-build-test.sh
	ci/test/readonly-leftovers-sweep-test.sh
)
unwired=0
for g in "${gates[@]}"; do
	# Anchored to end-of-line, NOT a bare substring. A substring test passes
	# for `bash <gate>.MOVED`, which runs nothing -- caught by planting exactly
	# that rename and watching an earlier version of this check stay green.
	if ! grep -qE "bash ${g//./\\.}[[:space:]]*\$" "$LINT"; then
		fail "gate is registered in ci/lint/bash.sh: $g" \
			"The register claims this gate runs. Nothing in the lint lane" \
			"invokes it (checked as a whole-argument match, not a substring)."
		unwired=$((unwired + 1))
	fi
done
if [ "$unwired" -eq 0 ]; then
	ok "all ${#gates[@]} gates named in the register are wired into the bash lint lane"
fi

# --- 3: every commit it cites is real --------------------------------------
# Short SHAs in prose are the first thing to go stale after a rebase.
bad_sha=0
sha_count=0
# shellcheck disable=SC2016  # literal markdown backticks, as above.
while IFS= read -r sha; do
	sha_count=$((sha_count + 1))
	if ! git -C "$REPO_ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null; then
		fail "cited commit exists: $sha" \
			"The register cites a commit this repository does not contain."
		bad_sha=$((bad_sha + 1))
	fi
done < <(grep -oE '`[0-9a-f]{9,40}`' "$REGISTER" | tr -d '`' | sort -u)

if [ "$sha_count" -eq 0 ]; then
	fail "the register cites at least one commit" \
		"Extracted zero SHAs -- the extraction broke, or the provenance was lost."
elif [ "$bad_sha" -eq 0 ]; then
	ok "all $sha_count cited commits resolve"
fi

# --- 4: the count is seven ------------------------------------------------
# This is the specific failure the register was written to end: the list was
# reported as five, twice, before being reconciled UPWARD to seven. If a defect
# is genuinely added or merged away, change this number in the same commit as
# the register -- and only after reconciling it to the document, never the
# document to it.
rows="$(sed -n '/^| # | Defect | State |/,/^$/p' "$REGISTER" |
	grep -cE '^\| [0-9]' || true)"
if [ "$rows" -eq 7 ]; then
	ok "the scoreboard lists all 7 defects"
else
	fail "the scoreboard lists all 7 defects" \
		"found $rows row(s)." \
		"The count was reported as five twice before being reconciled to seven." \
		"If this changed, reconcile the number to the document -- not the" \
		"document to the number."
fi

# --- 5: the numbered sections and the scoreboard agree ---------------------
# A row with no section, or a section with no row, is how a register starts
# lying while still looking complete.
sections="$(grep -cE '^## [0-9]' "$REGISTER" || true)"
# Entry "5 & 6" is one section covering two numbered defects, so sections are
# expected to be one fewer than rows. Stated here rather than left implicit,
# because the next person to add a defect needs to know why these differ.
if [ "$sections" -eq 6 ]; then
	ok "the register has a section for every defect (5 & 6 share one)"
else
	fail "the register has a section for every defect (5 & 6 share one)" \
		"found $sections numbered section(s), expected 6 for 7 defects."
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
