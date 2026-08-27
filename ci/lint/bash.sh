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
	scripts/require-tup-globs.sh \
	scripts/require-runtime-assets.sh

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

# ci/unfold-submodules.sh is what makes codetracer-native-backend's `path:`
# flake inputs resolvable in `Cross-Repo Integration Tests`. Its suite is pure
# bash + git against repositories it builds under mktemp -- no siblings, no
# network, seconds -- and the defect it guards (an unfold that is PARTIAL and
# reports success) is invisible until a Nix evaluation four steps later, so it
# belongs in the cheapest lane that will run it.
lint_step "contract suite: submodule unfold for path: flake inputs" \
	bash ci/test/unfold-submodules-test.sh

# direnv is a declared package of this repo's dev shell because
# src/db-backend/build.rs shells out to it. That declaration cannot put direnv
# in a SIBLING's dev shell, and a step that reached for one died with
# `exec: direnv: not found` / exit 127. Static, pure bash, no nix.
lint_step "contract suite: direnv comes from a dev shell we define" \
	bash ci/test/direnv-provenance-test.sh

# push-gpg-public-key and push-install-script have failed in every completed
# `dev` run for weeks with "experimental Nix feature 'nix-command' is disabled",
# because they run `nix develop` without ever installing Nix. Static, pure bash.
lint_step "contract suite: a job that runs nix installs Nix first" \
	bash ci/test/nix-provisioning-test.sh

# The guard for this whole shape: no ci/lint script may let one failing step
# hide another. It drives every ci/lint/*.sh with a PATH in which every
# external command fails, and asserts each still reports every step it declares.
lint_step "contract suite: lint-step isolation (no step can hide another)" \
	bash ci/test/lint-step-isolation-test.sh

# scripts/require-runtime-assets.sh is the end-of-build guard that a produced
# `ct` can actually start. It is exactly the shape of thing that can rot into a
# vacuous pass -- read no contract, check nothing, print "ok" -- so its own
# contract suite runs here. Pure bash, synthetic trees, about a second.
lint_step "contract suite: runtime-asset guard (a built ct can start)" \
	bash ci/test/require-runtime-assets-test.sh

# The backend-manager derivation's checkPhase excludes one unit test and one
# whole test target from the nix build sandbox, because that sandbox cannot
# supply what they need. Exclusions like that fail by growing until "green"
# means "the tests stopped running", so the phase carries guards against that --
# and this suite is what proves the guards work, by reintroducing each defect
# and asserting the matching guard catches it.
#
# It runs here because it is cheap and self-contained: it reads the checkPhase
# with `nix eval` and drives it against a stub `cargo`, so it needs no rustc and
# no 86-crate compile. The alternative -- learning that a guard was broken from
# `nix build .#codetracer` -- costs that whole compile and blocks six jobs.
# Without nix on PATH it skips loudly rather than passing quietly.
lint_step "contract suite: backend-manager checkPhase exclusion guards" \
	bash ci/test/backend-manager-check-phase-test.sh

# nix/overlays/crates-io-download-url.nix is what lets `importCargoLock` fetch a
# crate at all: crates.io's API host answers 403 to every `curl/*` User-Agent,
# which is exactly what `pkgs.fetchurl` sends, so without it `nix build
# .#backend-manager` / `.#codetracer` dies on its first dependency and takes six
# jobs with it. It runs here for the same reasons the suite above does -- it
# instantiates rather than builds, so it needs no rustc and downloads no crate --
# and because the alternative is learning that the fix rotted from a full nix
# build. Its one live request is deliberate: only a real request can notice the
# CDN adopting the API host's policy.
lint_step "contract suite: crates.io download URL (crate sources are fetchable)" \
	bash ci/test/crates-io-download-url-test.sh

lint_summary
