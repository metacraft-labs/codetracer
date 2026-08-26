#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Testing nimsuggest'
echo '###############################################################################'

# Use default nim (2.2.x) for nimsuggest
just test-nimsuggest

echo '###############################################################################'
echo 'Nim test-lane coverage (every test-shaped file runs somewhere)'
echo '###############################################################################'
# This is a lint, not a test run: pure bash + git, no Nim toolchain, about a
# second. It belongs here rather than in a test job because the failure it
# reports — "you added a test file and no lane will ever run it" — is worth
# knowing before a build starts, not after one finishes.
#
# The contract suite runs first and for the same reason ci/lint/bash.sh executes
# scripts/resolve-sibling-rev-test.sh: a guard that has only ever been watched
# printing OK is not evidence. It drives the guard against synthetic trees and
# asserts each of its three checks fires by name.
bash ci/test/test-lane-coverage-test.sh
bash ci/test/test-lane-coverage.sh
echo OK

echo
echo '###############################################################################'
echo 'TODO: nim check'
echo '###############################################################################'
