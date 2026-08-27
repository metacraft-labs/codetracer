#!/usr/bin/env bash
#
# Shell lint stage — shellcheck over the scripts CI depends on, plus the two
# contract suites that are cheap enough to belong in a lint job.
#
# Every check runs through ci/lib/lint-steps.sh so that one run reports all of
# them. That is not a stylistic preference. This script used to be a flat
# `set -e` list whose first command was `shellcheck ci/**/*.sh`, and that
# command had been failing on a style finding — so the two suites at the bottom
# (89 assertions and 65 contracts) had never once executed in CI. They passed
# when anyone ran them by hand, which is exactly why nobody noticed.
#
# Cheap and always-runnable first: the static passes need nothing beyond the
# linter itself, and the suites need only a shell and git.

set -uo pipefail

# Without globstar, `ci/**/*.sh` is silently just `ci/*/*.sh` — it reads as
# "every script under ci/" and was in fact skipping ci/setup-rr-backend.sh, the
# one script that sits directly in ci/. Same family as the rest of this file: a
# check that looks broader than it is.
shopt -s globstar

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# The pre-commit shellcheck hook runs without -x, so it cannot follow the
# source and reports SC1091; the source= directive above still tells the -x
# runs (ci/lint/bash.sh) where the library lives.
# shellcheck source=ci/lib/lint-steps.sh disable=SC1091
source ci/lib/lint-steps.sh

lint_step "shellcheck: CI scripts" \
	shellcheck ci/**/*.sh

lint_step "shellcheck: AppImage scripts" \
	shellcheck appimage-scripts/*.sh

# scripts/resolve-sibling-rev.sh decides which sibling revisions
# ci/setup-rr-backend.sh and scripts/run-cross-repo-tests.sh build against,
# so a regression in it mispins cross-repo CI rather than failing visibly.
lint_step "shellcheck: sibling-revision resolver" \
	shellcheck -S warning \
	scripts/resolve-sibling-rev.sh \
	scripts/resolve-sibling-rev-test.sh

# Its contract suite is pure bash + git (no siblings, no network, no dev-shell
# dependencies beyond this shell), so it runs here rather than waiting for a job
# that needs the very pins it validates.
lint_step "contract suite: sibling-revision resolver" \
	bash scripts/resolve-sibling-rev-test.sh

# scripts/require-fuse-mount-helper.sh stands between `just build-once` and a
# tup FUSE mount that cannot succeed. If it is broken, the build either dies
# for the wrong reason or stops reporting the right one, so lint it here --
# the glob above only reaches ci/.
# scripts/require-siblings.sh and scripts/require-tup-globs.sh sit in the same
# position: they are the only place a missing sibling repo, or a `: foreach`
# rule pointing at a directory that is not there, is reported by name instead
# of surfacing minutes later as `cannot open file: <module>`, undefined `mcr*`
# symbols, or a missing asset in the variant tree.
lint_step "shellcheck: build prerequisites checked before tup runs" \
	shellcheck \
	scripts/require-fuse-mount-helper.sh \
	scripts/require-siblings.sh \
	scripts/require-tup-globs.sh

# scripts/test-build-alignment.sh asserts that `just build` is `just build-once`
# plus watchers. It executes both scripts under recording stubs, so a break in
# the harness itself silently stops guarding issue #599 -- lint it here, and
# note that `just test` (ci/test/non-gui.sh) is what actually runs it.
lint_step "shellcheck: build-alignment harness ('just test' runs it)" \
	shellcheck scripts/test-build-alignment.sh

# UD-0's visual-design-iteration harness. Neither `tools/` nor `scripts/docs/`
# is under ci/, so the glob at the top does not reach either; the harness and
# its contract suite are named here.
lint_step "shellcheck: DeepReview design-review harness" \
	shellcheck \
	scripts/docs/deep-review-capture-lib.sh \
	scripts/docs/capture-deep-review-screenshots.sh \
	tools/visual-review/capture-deepreview-views.sh \
	tools/visual-review/deepreview-review-prompt.sh \
	tools/visual-review/deepreview-harness-test.sh

# The suite is executed as well as linted for the same reason the
# sibling-revision resolver's is: it never launches Electron (it stubs `ct`,
# `node`, `Xvfb` and `xdotool` on PATH), so it costs seconds, and if it stops
# running, nothing else notices that a named view was dropped from the review
# matrix or that the design brief lost the expected-elements block a view
# depends on.
lint_step "contract suite: DeepReview design-review harness" \
	bash tools/visual-review/deepreview-harness-test.sh

# scripts/test-flake-pin-alignment.sh is the static guard on the `runquota` /
# `reprobuild` lockstep. It is not under ci/, so the glob at the top does not
# reach it.
lint_step "shellcheck: flake pin alignment guard" \
	shellcheck scripts/test-flake-pin-alignment.sh

# Its contract suite runs here for the same reason the others do -- pure bash
# and git, no nix, no network, under a second -- and because the thing it
# actually asserts is that the guard's FAILURE PATHS accuse the right thing.
# A guard that reports "flake.lock has no locked rev for input 'runquota'"
# when python3 is merely absent sends the reader to edit a correct pin, and
# that defect is invisible to shellcheck and to every happy-path run.
lint_step "contract suite: flake pin alignment guard" \
	bash ci/test/flake-pin-alignment-test.sh

# The guard for this whole shape: no ci/lint script may let one failing step
# hide another. It drives every ci/lint/*.sh with a PATH in which every
# external command fails, and asserts each still reports every step it declares.
lint_step "contract suite: lint-step isolation (no step can hide another)" \
	bash ci/test/lint-step-isolation-test.sh

lint_summary
