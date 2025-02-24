#!/usr/bin/env bash

set -e

# TODO: maybe pass the result from the build stage as artifact to this job?
# ./ci/build/build.sh

# reset processes before running the ui tests
# stop_processes
# DISPLAY: ":99" in .gitlab-ci.yml?
# not sure if relevant
#xvfb-run tester ui

# cleanup before recording in local folder
# which is shard with normal user recordings and
# with other job/pipeline non-test recordings
# (the ui playwright tests record in a normal non-test mode!)
# (alexander:
#  without that it seems we had problems when changing the db schema in a MR
#  or at least that's my theory: ct record seemed to be hanging or problematic (?))
# rm -rf "$HOME"/.local/share/codetracer
# dont cleanup this: /tmp/codetracer, as it's useful for looking at logs!
# hopefully it doesn't interfere, usually the problem should be in
# the local share dir, where the db is
# # rm -rf /tmp/codetracer
# rm -rf /dev/shm/codetracer

# pushd ui-tests;
# xvfb-run npx playwright test
# popd;

# stop_processes

echo TODO
