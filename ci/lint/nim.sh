#!/usr/bin/env bash
#
# Nim lint stage.
#
# Every check here runs through ci/lib/lint-steps.sh, which reports all of them
# from one run and decides the exit status at the end. The reason is written up
# in that file: this script used to be a flat `set -e` list whose FIRST command
# was `just test-nimsuggest`, and that command had been crashing, so the
# test-lane coverage guard below it had never executed in CI. A guard that
# cannot run is not a guard.
#
# Order is now cheapest-and-most-portable first. The lane-coverage checks are
# pure bash and git — no Nim toolchain, about a second — so their answer
# ("you added a test file and no lane will ever run it") reaches the log before
# anything that needs a compiler.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# The pre-commit shellcheck hook runs without -x, so it cannot follow the
# source and reports SC1091; the source= directive above still tells the -x
# runs (ci/lint/bash.sh) where the library lives.
# shellcheck source=ci/lib/lint-steps.sh disable=SC1091
source ci/lib/lint-steps.sh

# See the note in ci/lint/bash.sh: the stage names its tools before it runs, so
# a shell missing one says so by name instead of failing obscurely inside a
# contract suite. `nimsuggest` is here for ci/test/nimsuggest-check.sh, and
# python3 for ci/test/dap-command-sync.py.
lint_step "tools this stage invokes are present" \
	bash ci/lib/require-tools.sh bash git python3 nimsuggest awk diff sha256sum

# The contract suite runs before the guard it covers, and for the same reason
# ci/lint/bash.sh executes scripts/resolve-sibling-rev-test.sh: a guard that has
# only ever been watched printing OK is not evidence. It drives the guard
# against synthetic trees and asserts each of its checks fires by name.
lint_step "test-lane coverage guard: contract suite" \
	bash ci/test/test-lane-coverage-test.sh

# The guard itself: every test-shaped Nim file is either run by a lane or
# declares why it is not.
lint_step "test-lane coverage: every test-shaped file runs somewhere" \
	bash ci/test/test-lane-coverage.sh

# THE SAME QUESTION, ONE FILE EXTENSION OVER. `test-lane-coverage.sh` is scoped
# in its own first line to "any test-shaped **Nim** file", and `ci/test/` holds
# sixty-three SHELL gates that nothing measured. Twelve of them were reachable
# from no workflow, no recipe and no other reachable gate — several with their
# own self-tests beside them, which is work that went in and then ran nowhere.
#
# It sits here, beside its Nim sibling, because the two are one guard asking one
# question about two file types, and a reader who finds one should find the
# other. Its contract suite runs first, for the reason the block above gives.
lint_step "shell-gate coverage guard: contract suite" \
	bash ci/test/shell-gate-coverage-test.sh

lint_step "shell-gate coverage: every gate under ci/ and scripts/ is reachable from a workflow lane" \
	bash ci/test/shell-gate-coverage.sh

# AND THE THIRD ASKING OF THE SAME QUESTION, one level down: not "does this file
# run" but "does anything reach this symbol". Its own header calls it "CI entry
# point for the exported-symbol reachability guard" and no CI root has ever
# named it — the guard against unreachable capability was itself unreachable,
# which `shell-gate-coverage.sh` above has been reporting as an UNRECORDED dark
# gate.
#
# It belongs in this stage rather than a heavier one because it is pure python3
# over the checked-out tree: no Nim toolchain, no browser, no network, under
# five seconds.
#
# THE RATCHET IS NOW ENGAGED. It was not, and that was the defect.
#
# The script is built to bite in two escalating ways — `CT_REACHABILITY_MAX=<n>`
# for a ceiling that can only fall, `CT_REACHABILITY_ENFORCE=1` for zero — and it
# documents both in its own header. Neither variable had a SETTER anywhere in
# this repository: `grep -rn CT_REACHABILITY .github/ justfile ci/ scripts/`
# returned exactly one hit, and it was the sentence that used to be on this line
# saying somebody should do it. So the guard ran on every push, printed its
# findings, and could not fail over any of them, for any number of them. A
# report is not a gate. Its ALLOW-LIST hygiene could redden this lane; its stated
# subject could not.
#
# 1228 is this tree's exact count, re-measured on 2026-09-04 after the three
# raises below. THE NUMBER IN THIS PARAGRAPH SAID 1224 FOR HALF A DAY WHILE THE
# LINE BELOW SAID 1228, and that is the defect worth recording here rather than
# only in a commit. The ceiling went 1224 -> 1226 -> 1228 in twenty-nine
# minutes, and no raising commit's SUBJECT mentioned the ratchet:
#
#   896166e27  ci(lint-nim): engage the reachability ratchet at 1224   1224
#   6954db651  ci: settle the gate-coverage merge against the tree     1226
#   9f9bbbef5  ci: clone python-recorder from `dev`, like the other 12 1228
#
# Each raise moved the `env` on the next line and left every sentence about it
# behind — this one, the step LABEL one line down, and the header of
# `frontend-reachability.sh`. A guard whose documented threshold and actual
# threshold differ by four is a guard a reader cannot check. The three are now
# asserted to agree by `assert_reachability_prose_agrees` below, so the next
# raise cannot land without touching all three.
#
# WHAT THIS BUYS, PRECISELY: the count can go down and can never go up. A new
# unreached export fails this lane by pushing the total to 1229. It does NOT ask
# anyone to clear the backlog, and deliberately so — a guard that reddens CI over
# 1228 pre-existing findings on day one is a guard that gets switched off on day
# one, which is the argument in the script's own header and is still right.
#
# IT HAS ALREADY BITTEN ONCE, and the bite was correct. `layout.mountComponent-
# Container` carried a `*` no other module used; b59186fa0 added a test that
# mentions the name, which moved it from the uncounted "only its own module
# reaches it" bucket into the counted "tested, and no product module reaches it"
# one and took the tree to 1229. The fix was to drop the `*` — the export nobody
# outside could use — and not to raise this number a fourth time.
#
# WHEN YOU DELETE OR WIRE A SYMBOL, LOWER THIS NUMBER — AND SINCE 2026-09-04
# THE GUARD MAKES YOU. That paragraph used to end "Nothing forces that yet:
# unlike the shell-gate inventory next door, `--max` is a `>` and not an `=`, so
# slack accumulates silently under it", and it was describing live slack rather
# than a hypothetical: the backlog had been brought down to 1223 by deleting
# dead entry points while this line still said 1228, so FIVE new unreached
# exports could have landed without reddening anything.
#
# `--max` is now an equality. Fewer findings than the number fails as "lower it
# to what you measured", the same rule and very nearly the same sentence the
# shell-gate inventory uses for its own ceiling. 1223 is this tree's exact
# count, measured on 2026-09-04 after the three raises above and the deletions
# that followed them.

# THE PROSE GUARD. Three sentences name this threshold and all three drifted off
# it; the cheapest permanent fix is to make a raise that does not touch them
# fail. Pure grep over two checked-in files, no toolchain, milliseconds.
assert_reachability_prose_agrees() {
	local setter="${CT_PROSE_SETTER_FILE:-ci/lint/nim.sh}"
	local header="${CT_PROSE_HEADER_FILE:-ci/test/frontend-reachability.sh}"
	local max label hdr hdr_set hdr_fail hdr_pass rc=0

	# THE THRESHOLD ITSELF, read from the only line that decides anything.
	max="$(grep -oE 'CT_REACHABILITY_MAX=[0-9]+' "${setter}" | grep -oE '[0-9]+' | head -1)"
	if [ -z "${max}" ]; then
		echo "  [FAILED] no 'CT_REACHABILITY_MAX=<n>' setter in ${setter}." >&2
		echo "           This guard asserts prose against that line; with no line to" >&2
		echo "           read it would pass over anything, so it fails instead." >&2
		return 1
	fi

	# (1) THE STEP LABEL, which is the sentence a reader of the CI log sees.
	label="$(grep -oE 'frontend reachability: exported symbols nothing reaches \(ratchet at [0-9]+' \
		"${setter}" | grep -oE '[0-9]+$' | head -1)"
	if [ "${label}" != "${max}" ]; then
		echo "  [FAILED] ${setter}: the step label says 'ratchet at ${label:-<none>}'," >&2
		echo "           the setter says CT_REACHABILITY_MAX=${max}." >&2
		rc=1
	fi

	# (2) AND (3) THE SCRIPT'S OWN HEADER: it quotes the invocation and then
	# states both sides of the boundary. Comment markers are stripped and the
	# block is joined onto one line first, so re-wrapping the paragraph cannot
	# hide a stale number from this check.
	#
	# The quoted path below is the REPO-RELATIVE one the header names, and is
	# deliberately not `${header}`: that variable is the file being READ, which
	# the contract suite points at a copy under /tmp. Interpolating it made this
	# check silently unmatchable for every arm, which is how the suite's own
	# unmutated control caught it before it landed.
	hdr="$(sed -e 's/^#[[:space:]]\{0,1\}//' "${header}" | tr '\n' ' ')"
	hdr_set="$(printf '%s' "${hdr}" |
		grep -oE 'CT_REACHABILITY_MAX=[0-9]+ bash ci/test/frontend-reachability\.sh' |
		grep -oE '[0-9]+' | head -1)"
	hdr_fail="$(printf '%s' "${hdr}" |
		grep -oE 'so +[0-9]+ +findings fail' | grep -oE '[0-9]+' | head -1)"
	hdr_pass="$(printf '%s' "${hdr}" |
		grep -oE 'and +[0-9]+ +do not\.' | grep -oE '[0-9]+' | head -1)"
	if [ "${hdr_set}" != "${max}" ] || [ "${hdr_fail}" != "$((max + 1))" ] ||
		[ "${hdr_pass}" != "${max}" ]; then
		echo "  [FAILED] ${header}'s header describes a ratchet at ${hdr_set:-<none>}," >&2
		echo "           where ${hdr_fail:-<none>} findings fail and ${hdr_pass:-<none>} pass." >&2
		echo "           The setter says ${max}, so $((max + 1)) fails and ${max} passes." >&2
		rc=1
	fi

	if [ "${rc}" -ne 0 ]; then
		echo "           RAISING THE CEILING MEANS CORRECTING THE SENTENCES THAT" >&2
		echo "           DESCRIBE IT, IN THE SAME DIFF. The ceiling moved 1224 ->" >&2
		echo "           1226 -> 1228 in twenty-nine minutes on 2026-09-04 and none" >&2
		echo "           of the three descriptions moved with it." >&2
		return 1
	fi
	echo "  label, header and setter all say ${max} (so $((max + 1)) fails, ${max} passes)"
	return 0
}
# Its contract suite runs first, for the reason the shell-gate block above
# gives: a guard over PROSE is the easiest kind to write so that it can never
# fail, and one that has not been watched fail is not evidence. The suite proved
# its worth immediately — the first draft of the function interpolated the file
# being READ into the pattern matching the quoted invocation, so it could not
# match a copy, and the unmutated control caught that before it landed.
lint_step "reachability prose guard: contract suite" \
	bash ci/test/reachability-prose-guard-test.sh

# THE THRESHOLD ITSELF, WHICH NOTHING TESTED UNTIL 2026-09-04. The suite above
# tests the SENTENCES that describe the ceiling; this one tests the ceiling. The
# gap is how `--max` stayed a `>` while the paragraph below described the slack
# that produced, in the present tense, for as long as it was true. Four synthetic
# unreached exports, no Nim toolchain, milliseconds.
lint_step "reachability ratchet: contract suite (equality, both directions)" \
	bash ci/test/reachability-ratchet-test.sh

lint_step "frontend reachability: the ratchet's prose agrees with its threshold" \
	assert_reachability_prose_agrees

lint_step "frontend reachability: exported symbols nothing reaches (ratchet at 1223 + allow-list hygiene)" \
	env CT_REACHABILITY_MAX=1223 bash ci/test/frontend-reachability.sh

# ONE CHAIN, ENFORCED, BECAUSE THE RATCHET ABOVE CANNOT ENFORCE IT.
#
# The ratchet is the right instrument for a 1228-finding backlog and the wrong
# one for a specific feature: a chain that breaks INSIDE the ceiling reddens
# nothing, and the Show Generated Code chain was inside it — `produceAnchors`
# and `readArtefactJson` were reported as unreached, in report mode, exiting 0,
# among twelve hundred other lines.
#
# So the operation a developer invokes to see what their code compiled to gets
# its own check, at --enforce, with no ceiling and no allow-list. It is proved
# able to fail: against `origin/dev` at a861f5b7b it exits 1 on 22 of its 24
# links, and its header records that measurement -- including WHICH four were
# tested-but-unreached -- rather than a claim about it. The number lives in the
# guard's own header too, which is the only place worth updating it; this
# sentence is a pointer and will go stale if it is treated as the record.
lint_step "Show Generated Code: the operation's chain is reached from production" \
	python3 ci/test/generated-code-operation-guard.py

# The Embed SDK's boundary, in both directions: a consumer may reach the SDK
# only through `codetracer_embed`, and the SDK's own import graph carries no
# rendering and no chain concept. CodeTracer-Embed-SDK.md §3.2 says in as many
# words that "enforcement is an import lint, not discipline", and
# BlockTracer/Client-SDK.md §1.1 asks for the mirror of the same rule.
#
# Same order as above and for the same reason: the contract suite runs before
# the guard it covers, because a guard nobody has watched fail is not evidence.
lint_step "SDK facade boundary: contract suite" \
	bash ci/test/sdk-facade-boundary-test.sh

lint_step "SDK facade boundary: no reach past the facade, no chain concept inside it" \
	bash ci/test/sdk-facade-boundary.sh

# `VALID_DAP_COMMANDS` against the tables it mirrors, in BOTH directions. The
# allow-list is hand-written but no longer hand-CHECKED: the guard derives the
# engine's dispatch from `src/db-backend/src/dap_server.rs` and the event
# mapping from `src/frontend/dap.nim`. It had drifted in the direction nothing
# looked at — ten engine-implemented commands missing, two of them already in
# `EVENT_KIND_TO_DAP_MAPPING`.
#
# Contract suite first, same order and same reason as the two guards above. It
# matters more here than usual: every check the guard makes is a SUBSET test,
# and a subset test against an empty set passes, so a broken extraction regex
# would turn this guard green rather than red.
lint_step "DAP command sync: contract suite" \
	bash ci/test/dap-command-sync-test.sh

lint_step "DAP command sync: the allow-list names everything the engine dispatches" \
	python3 ci/test/dap-command-sync.py

# Canary for the chronicles/distinct-type breakage that takes every editor in
# the project down. Currently QUARANTINED against an upstream nimsuggest crash;
# ci/test/nimsuggest-check.sh carries the diagnosis, tells a toolchain defect
# apart from a real regression in src/lsp.nim, and re-arms itself automatically.
lint_step "nimsuggest starts on src/lsp.nim" \
	bash ci/test/nimsuggest-check.sh

# TODO: nim check

lint_summary
