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

# THE TOOLS THIS STAGE INVOKES, NAMED BEFORE ANYTHING RUNS.
#
# `devShells.lint` carries only what the lint stages actually call, which is
# what keeps this job away from the Cargo git closure of Sui and Solana. The
# risk that buys is a step silently losing a tool, so the stage says what it
# needs and fails BY NAME if the shell is missing it — rather than a contract
# suite dying three lines in on `node: command not found`, or skipping the half
# of itself that needed it and reporting OK.
#
# Derived from what these scripts INVOKE, not what they mention: this file
# names `cargo`, `nim` and `node` in prose and invokes none of them directly.
# `node` is here because tools/visual-review/deepreview-harness-test.sh runs it.
lint_step "tools this stage invokes are present" \
	bash ci/lib/require-tools.sh shellcheck bash git python3 node awk diff sort comm timeout

lint_step "shellcheck: CI scripts" \
	shellcheck ci/**/*.sh

# THE ONE DEFECT SHELLCHECK DOES NOT HAVE A CODE FOR, and this repository has
# now paid for it in both directions. `producer | grep -q PAT` under `pipefail`
# returns a SUCCESSFUL MATCH AS A FAILURE: `grep -q` exits on the first match,
# the producer takes EPIPE, and the pipeline adopts its 141. Whether it happens
# depends on whether the producer finished first, so it presents as flakiness.
#
# It made `ci/test/shell-gate-coverage.sh` report three unreachable gates on
# `dev` that were reachable, failing `lint-nim` and every build behind it; and
# it made `ci/test/noir-build-mutations.sh` report a RED baseline as green, so
# 27 mutation arms ran against a broken product while claiming coverage. It was
# fixed once, at one site out of roughly a hundred and thirty, and nothing
# stopped the next one being written — which is the whole argument for a lint
# rather than another fix.
#
# It runs first among the guards because it is the cheapest thing here (a git
# ls-files and a grep, no nix, no network, well under a second) and because a
# repository-wide textual rule is exactly what a reader wants to see resolved
# before anything expensive starts. Its own Step 0 runs the detector against a
# fixture carrying one of each shape and fails if any planted defect is missed
# or any correct form is flagged, so a green run is evidence the scan still
# works rather than evidence the regex still parses.
lint_step "contract suite: no producer is piped into 'grep -q' under pipefail" \
	bash ci/test/grep-q-pipefail-gate.sh

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

# Not covered by the `ci/**/*.sh` glob above, and it runs in the deploy lane on
# every push to `cloud`, where a shell defect would surface as a deploy failure
# rather than as a lint one.
lint_step "shellcheck: sibling commit-pin resolver" \
	shellcheck scripts/sibling-pins.sh

# The toolchain half of the same question, and not covered by the glob for the
# same reason. `sibling-pins.sh` pins three REPOSITORIES and says on its own
# passing line that it does not cover the compilers that read them; this is the
# guard that does.
lint_step "shellcheck: toolchain resolver" \
	shellcheck scripts/toolchain-pins.sh

# Its contract suite runs here for the same reason the others do -- pure bash
# and git, no nix, no network, under a second -- and because the thing it
# actually asserts is that the guard's FAILURE PATHS accuse the right thing.
# A guard that reports "flake.lock has no locked rev for input 'runquota'"
# when python3 is merely absent sends the reader to edit a correct pin, and
# that defect is invisible to shellcheck and to every happy-path run.
lint_step "contract suite: flake pin alignment guard" \
	bash ci/test/flake-pin-alignment-test.sh

# scripts/test-python-version-alignment.sh is the static+artifact guard on the
# ONE place this repo chooses a Python version (nix/python.nix). It sits here
# for the same reason the pin guard does: it is not under ci/, so the glob at
# the top does not reach it.
lint_step "shellcheck: python version alignment guard" \
	shellcheck scripts/test-python-version-alignment.sh

# And its contract suite runs here because this guard is unusually exposed to
# passing vacuously: most of what it compares (a venv, a built `.so`, a sibling
# checkout) may simply be absent, and a guard that finds nothing to compare and
# exits 0 is indistinguishable from a guard that checked everything. The suite
# drives it against synthetic trees with one seeded defect each -- including
# one case that MOVES the pin and asserts the verdicts invert, which is what
# proves no version is written into the guard as a literal. Pure bash, stub
# interpreters, no nix, no real Python, about a second.
lint_step "contract suite: python version alignment guard" \
	bash ci/test/python-version-alignment-test.sh

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

# The Nix lane consumes siblings as flake inputs; every other lane clones them.
# Nothing made the two agree on a branch until `codetracer-trace-format` was
# found declared `/main` in flake.nix while the workflow cloned it at `dev`, 55
# commits apart — which broke `nix build .#codetracer` alone, with 13 compile
# errors in db-backend, while the lanes that clone stayed green. Two files, two
# greps, no nix.
lint_step "contract suite: sibling flake inputs track the branch CI clones" \
	bash ci/test/sibling-input-branch-test.sh

# The suite above holds the two lanes to the same BRANCH. That is agreement,
# not determinism: a branch tip moves, so the same codetracer commit built on
# two days took two different sibling revisions and nothing could say which
# artifact a commit was supposed to produce. `flake.lock` already records the
# exact revision each of the three build siblings resolves to, so the fix was
# to feed those revisions to the clone lane and then ASSERT the cloned trees
# are at them. This suite covers that guard, and it is registered here rather
# than left to be discovered because an unrun check is the defect it exists to
# catch. Pure bash + git + python3 over mktemp fixtures; no nix, no network.
lint_step "contract suite: build siblings are pinned to commits, not branches" \
	bash ci/test/sibling-pins-test.sh

# The suite above covers three REPOSITORIES; this one covers the COMPILERS that
# read them, which the suite above explicitly does not and says so. Registered
# here rather than left to be discovered for the same reason: an unrun check is
# the defect it exists to catch. Its own arms are mostly failure paths, because
# every way a toolchain guard can be wrong looks like it working -- an ambient
# `nim` that resolves into the store, a `--require` naming a tool that is not
# declared, an emptied tool list. Pure bash + git + python3 over mktemp
# fixtures; no nix, no dev shell, no network.
lint_step "contract suite: the toolchain that answered is the one this commit declares" \
	bash ci/test/toolchain-pins-test.sh

# The Electron the desktop artefact bundles, and the dependency set beside it.
# Run WITHOUT an artefact here, which exercises the half that needs no build:
# the pin is exact, the lockfile resolves to it, and no build script installs
# Electron without naming a version. The artefact half runs inside
# `appimage-scripts/build_appimage.sh`, on the staged AppDir, because that tree
# is deleted the moment the build script exits.
lint_step "Electron pin + dev-dependency prune (static half)" \
	bash ci/test/electron-supply-chain.sh

# Its own arms are the failure paths -- a range where an exact version belongs,
# a lock that resolves elsewhere, a dev-only package staged into the artefact.
# A guard whose red path has never executed is a guard nobody has tested.
lint_step "contract suite: Electron pin + dev-dependency prune" \
	bash ci/test/electron-supply-chain-test.sh

# Whether every path inside a shipped desktop bundle resolves inside it. Run
# WITHOUT a bundle here, which exercises the half that needs no build: the
# stager exists and is tracked, and repro.nim's two staging steps copy
# node_modules' CONTENTS rather than the symlink. The artefact half runs in the
# `dmg-build` workflow job, on `non-nix-build/CodeTracer.app`, because that is
# the only place and moment the tree exists.
lint_step "desktop bundle self-containment (static half)" \
	bash ci/test/desktop-bundle-self-contained.sh

# Its arms are the failure paths, and the first one is the reason the defect
# shipped: an ABSOLUTE /nix/store symlink whose target EXISTS on the machine
# running the check. A guard written as "find broken symlinks" is green on the
# exact artefact that is broken for every user.
lint_step "contract suite: desktop bundle self-containment" \
	bash ci/test/desktop-bundle-self-contained-test.sh

# The pre-checkout sweep that keeps a persistent self-hosted runner cleanable.
# It lives as an inline `run:` block in seven jobs — it has to run BEFORE
# actions/checkout, so it cannot be a script the repository provides — and this
# is the ONLY place it is ever executed outside CI. Registered here rather than
# left to be discovered because an unrun check is the defect it exists to catch,
# and because the failure this guards is precisely a cleanup that silently
# no-ops: it asserts a NON-ZERO count on a poisoned fixture, not merely a zero
# afterwards. Pure bash + git + python3 over mktemp fixtures; no nix, no
# network.
lint_step "contract suite: the read-only-leftovers sweep runs, finds, and fixes" \
	bash ci/test/readonly-leftovers-sweep-test.sh

# The dev shell's git-hooks guard. Registered here for the same reason as the
# sweep above: the thing it protects is developer state on a shared checkout, so
# it is never exercised by any other job, and an unrun guard is exactly the
# defect it exists to catch. The suite builds real `git worktree` fixtures under
# mktemp -- the bug is entirely about what `git rev-parse` reports in a linked
# worktree, so a mock would encode the belief under test. Pure bash + git; no
# nix, no network, no siblings.
lint_step "contract suite: a worktree does not reinstall the shared git hooks" \
	bash ci/test/git-hooks-worktree-test.sh

lint_summary
