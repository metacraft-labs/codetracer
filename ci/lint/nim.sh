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

lint_step "shell-gate coverage: every gate in ci/test/ is reachable from CI" \
	bash ci/test/shell-gate-coverage.sh

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
