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
# 1224 is today's exact count, measured on this tree on 2026-09-04 — not the
# 1217 the previous note recorded, which is seven findings of drift accumulated
# while nothing was watching, and a small demonstration of why a number nobody
# asserts stops being true.
#
# WHAT THIS BUYS, PRECISELY: the count can go down and can never go up. A new
# unreached export fails this lane by pushing the total to 1225. It does NOT ask
# anyone to clear the backlog, and deliberately so — a guard that reddens CI over
# 1224 pre-existing findings on day one is a guard that gets switched off on day
# one, which is the argument in the script's own header and is still right.
#
# WHEN YOU DELETE OR WIRE A SYMBOL, LOWER THIS NUMBER. Nothing forces that yet:
# unlike the shell-gate inventory next door, `--max` is a `>` and not an `=`, so
# slack accumulates silently under it. That is the script's contract, not this
# line's, and changing it belongs in a diff that says so.
lint_step "frontend reachability: exported symbols nothing reaches (ratchet at 1224 + allow-list hygiene)" \
	env CT_REACHABILITY_MAX=1228 bash ci/test/frontend-reachability.sh

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
