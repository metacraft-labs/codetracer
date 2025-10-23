#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running ui e2e playwright tests'
echo '###############################################################################'

./ci/build/dev.sh

# trying to make it work with the nix build, instead of the tup build:

# TODO: fix again: problem on CI in ui-tests/ci.sh with dotnet run:
# System.Threading.Tasks.TaskCanceledException: A task was canceled.
#    at PlaywrightLauncher.WaitForCdpAsync(Int32 port, TimeSpan timeout) in /var/lib/github-runner-work/github-runner-mcl-003/codetracer/codetracer/ui-tests/Helpers/PlayrwightLauncher.cs:line 28
#    at PlaywrightLauncher.LaunchAsync(String programRelativePath) in /var/lib/github-runner-work/github-runner-mcl-003/codetracer/codetracer/ui-tests/Helpers/PlayrwightLauncher.cs:line 62
#    at UiTests.Tests.TestRunner.RunAsync() in /var/lib/github-runner-work/github-runner-mcl-003/codetracer/codetracer/ui-tests/Tests/TestRunner.cs:line 22
#    at UiTests.Program.Main() in /var/lib/github-runner-work/github-runner-mcl-003/codetracer/codetracer/ui-tests/Program.cs:line 13
#    at UiTests.Program.<Main>()
# backend-manager: no process found
#
# it *should* work with the nix build, but I am not sure if the problem is related

# ./ci/build/nix.sh

CODETRACER_E2E_CT_PATH="$(pwd)/src/build/bin/ct"
LINKS_PATH_DIR="$(pwd)/src/build"
NIX_CODETRACER_EXE_DIR="$(pwd)/src/build"
CODETRACER_LINKS_PATH="$(pwd)/src/build"
CODETRACER_ELECTRON_ARGS="--no-sandbox"

export CODETRACER_E2E_CT_PATH
export LINKS_PATH_DIR
export NIX_CODETRACER_EXE_DIR
export CODETRACER_LINKS_PATH
export CODETRACER_ELECTRON_ARGS

pushd ui-tests
nix develop --command ./ci.sh

popd

git clean -fx ./src/build
git clean -fx ./src/build-debug
