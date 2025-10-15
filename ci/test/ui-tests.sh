#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running ui e2e playwright tests'
echo '###############################################################################'

# TODO: maybe pass the result from the build stage as artifact to this job?
# TODO: tup generate seems problematic with variants: we need to fix/change the resulting dirs to work correctly
# ./ci/build/dev.sh

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

# CODETRACER_E2E_CT_PATH="$(pwd)/result/bin/ct"
# export CODETRACER_E2E_CT_PATH

# pushd ui-tests
# nix develop --command ./ci.sh

# popd
