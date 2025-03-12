#!/usr/bin/env bash

set -e

# TODO: maybe pass the result from the build stage as artifact to this job?
# ./ci/build/build.sh

# reset processes before running the ui tests
# stop_processes
# DISPLAY: ":99" in .gitlab-ci.yml?
# not sure if relevant

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

echo "========================"
echo "RUNNING ui e2e tests"

nix-shell -p xvfb-run --command "xvfb-run just test-e2e"

echo "========================"

# stop_processes
