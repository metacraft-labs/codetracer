#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo "Lint CI scripts:"
echo '###############################################################################'
shellcheck ci/**/*.sh
echo OK

echo
echo '###############################################################################'
echo "Lint AppImage scripts:"
echo '###############################################################################'
shellcheck appimage-scripts/*.sh
echo OK

echo
echo '###############################################################################'
echo "Sibling-revision resolver (lint + contract suite):"
echo '###############################################################################'
# scripts/resolve-sibling-rev.sh decides which sibling revisions
# ci/setup-rr-backend.sh and scripts/run-cross-repo-tests.sh build against,
# so a regression in it mispins cross-repo CI rather than failing visibly.
# Its contract suite is pure bash + git (no siblings, no network, no
# dev-shell dependencies beyond this shell), so it runs here rather than
# waiting for a job that needs the very pins it validates.
shellcheck -S warning \
	scripts/resolve-sibling-rev.sh \
	scripts/resolve-sibling-rev-test.sh
bash scripts/resolve-sibling-rev-test.sh
echo OK

echo
echo '###############################################################################'
echo "Build prerequisites checked before tup runs:"
echo '###############################################################################'
# scripts/require-fuse-mount-helper.sh stands between `just build-once` and a
# tup FUSE mount that cannot succeed. If it is broken, the build either dies
# for the wrong reason or stops reporting the right one, so lint it here --
# the glob above only reaches ci/*/*.sh.
# scripts/require-siblings.sh and scripts/require-tup-globs.sh sit in the same
# position: they are the only place a missing sibling repo, or a `: foreach`
# rule pointing at a directory that is not there, is reported by name instead
# of surfacing minutes later as `cannot open file: <module>`, undefined `mcr*`
# symbols, or a missing asset in the variant tree.
shellcheck \
	scripts/require-fuse-mount-helper.sh \
	scripts/require-siblings.sh \
	scripts/require-tup-globs.sh
echo OK

echo
echo '###############################################################################'
echo "Build-alignment harness (lint only; 'just test' runs it):"
echo '###############################################################################'
# scripts/test-build-alignment.sh asserts that `just build` is `just build-once`
# plus watchers. It executes both scripts under recording stubs, so a break in
# the harness itself silently stops guarding issue #599 -- lint it here, and
# note that `just test` (ci/test/non-gui.sh) is what actually runs it.
shellcheck scripts/test-build-alignment.sh
echo OK
