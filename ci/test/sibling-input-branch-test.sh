#!/usr/bin/env bash
# =============================================================================
# sibling-input-branch-test.sh — flake.nix and the CI sibling-clone step must
# agree on which BRANCH of each metacraft-labs sibling this repo builds against.
#
# WHY THIS EXISTS
# ---------------
# CodeTracer builds its siblings two different ways, and only one of them was
# ever checked:
#
#   * the cross-repo lanes clone them, at the refs named in the workflow's
#     `siblings:` list (`codetracer-trace-format=dev`, ...);
#   * the Nix lane consumes them as FLAKE INPUTS, at the refs named in
#     `flake.nix` (`github:metacraft-labs/<repo>/<ref>`).
#
# Nothing made those two lists agree. On 2026-08-27 they did not:
# `codetracer-trace-format` was declared `/main` in flake.nix -- alone among
# every metacraft-labs sibling input, all of which track `dev` -- while the
# workflow cloned it at `dev`. `main` was 55 commits behind and lacked
# `NimTraceReaderHandle::{refresh, event_metadata}`,
# `{Call,Step,Value}StreamReader::from_files` and a public
# `decode_chunk_records`, all of which `src/db-backend/src/ctfs_trace_reader`
# calls. Result: `nix build '.?submodules=1#codetracer'` died with 13 compile
# errors in `db-backend`, while every lane that clones the sibling was green.
#
# That is the characteristic shape of this defect: the disagreement is
# invisible to every lane except the one that consumes the input, and the branch
# name is one word in a URL that no reviewer diffs against a YAML list 800 lines
# away.
#
# WHAT IT ASSERTS
# ---------------
#   1. Every `metacraft-labs/<repo>` named with an explicit `<ref>` in BOTH
#      files names the SAME ref in both.
#   2. The comparison is not vacuous: at least one repo appears in both lists.
#      Without this, renaming either file's syntax would turn the check into a
#      green tick over an empty intersection.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT
# ------------------------------------
# That a repo in one list appears in the other. `flake.nix` legitimately carries
# inputs no CI job clones (`isonim`, `nim-pty`, ...) and the workflow
# legitimately clones repos that are not flake inputs. Only the OVERLAP is a
# contract; requiring more would make the check something people delete.
#
# Pure bash + grep over two files in this repo. No nix, no network, no clone.
#
# Run: bash ci/test/sibling-input-branch-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

FLAKE=flake.nix
WORKFLOW=.github/workflows/codetracer.yml

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '  ok    %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$1" >&2
	if [ -n "${2:-}" ]; then
		printf '        %s\n' "$2" >&2
	fi
}

for f in "$FLAKE" "$WORKFLOW"; do
	if [ ! -f "$f" ]; then
		echo "ERROR: $f does not exist; this suite cannot check anything." >&2
		exit 1
	fi
done

echo "sibling input branch alignment ($FLAKE vs $WORKFLOW)"

# ---------------------------------------------------------------------------
# flake.nix: `github:metacraft-labs/<repo>/<ref>` and
#            `github:metacraft-labs/<repo>?ref=<ref>`.
#
# A bare `github:metacraft-labs/<repo>` (default branch) and a pinned
# `.../<repo>/<40-hex>` are both skipped: neither states a branch, so neither
# can disagree with one. The 40-hex exclusion matters -- `runquota` and
# `reprobuild` are deliberately pinned to commits and are guarded by
# scripts/test-flake-pin-alignment.sh instead.
# ---------------------------------------------------------------------------
flake_refs() {
	grep -oE 'github:metacraft-labs/[A-Za-z0-9._-]+(/[A-Za-z0-9._/-]+|\?ref=[A-Za-z0-9._/-]+)' "$FLAKE" |
		sed -E 's#github:metacraft-labs/##; s#\?ref=#/#' |
		awk -F/ 'NF >= 2 { repo = $1; sub(/^[^/]*\//, ""); print repo "\t" $0 }' |
		grep -vE "$(printf '\t')[0-9a-f]{40}$" |
		sort -u
}

# ---------------------------------------------------------------------------
# The workflow's `siblings:` entries, which are `name=ref` lines. A bare `name`
# (no `=`) asks the action to resolve the revision from a workspace lock rather
# than naming a branch, so it states no ref and is skipped for the same reason
# a bare flake URL is.
# ---------------------------------------------------------------------------
workflow_refs() {
	grep -oE '^[[:space:]]+[A-Za-z0-9._-]+=[A-Za-z0-9._/-]+[[:space:]]*$' "$WORKFLOW" |
		tr -d '[:blank:]' |
		awk -F= '{ print $1 "\t" $2 }' |
		sort -u
}

flake_list=$(flake_refs)
workflow_list=$(workflow_refs)

if [ -z "$flake_list" ]; then
	fail "flake.nix names at least one branch-tracking metacraft-labs input" \
		"the extractor matched nothing; its pattern has drifted from the file"
fi
if [ -z "$workflow_list" ]; then
	fail "the workflow names at least one sibling at an explicit ref" \
		"the extractor matched nothing; its pattern has drifted from the file"
fi

overlap=0
for repo in $(printf '%s\n' "$flake_list" "$workflow_list" | cut -f1 | sort -u); do
	fref=$(printf '%s\n' "$flake_list" | awk -F'\t' -v r="$repo" '$1 == r { print $2 }' | sort -u)
	wref=$(printf '%s\n' "$workflow_list" | awk -F'\t' -v r="$repo" '$1 == r { print $2 }' | sort -u)

	[ -n "$fref" ] && [ -n "$wref" ] || continue
	overlap=$((overlap + 1))

	if [ "$fref" = "$wref" ]; then
		pass "$repo: both name '$fref'"
	else
		fail "$repo: flake.nix and the workflow name different branches" \
			"flake.nix says '$(printf '%s' "$fref" | tr '\n' ' ')', the workflow says '$(printf '%s' "$wref" | tr '\n' ' ')'. The Nix lane builds the first; every cross-repo lane builds the second."
	fi
done

# The vacuity guard: an empty intersection satisfies the loop above trivially.
if [ "$overlap" -gt 0 ]; then
	pass "the two lists overlap on $overlap repo(s), so the comparison is not vacuous"
else
	fail "the two lists overlap" \
		"no metacraft-labs repo names an explicit ref in both files. Either both extractors have drifted, or the contract this suite exists to hold no longer has anything to hold."
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
