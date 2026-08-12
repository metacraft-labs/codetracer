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
shellcheck scripts/require-fuse-mount-helper.sh
echo OK
