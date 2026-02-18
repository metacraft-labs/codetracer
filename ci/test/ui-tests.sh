#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running C# UI e2e playwright tests'
echo '###############################################################################'

# CI-specific Electron/Chromium flags:
#   --no-sandbox            nix-store chrome-sandbox lacks the SUID bit
#   --no-zygote             prevents Zygote fork failures on restricted CI runners
#   --disable-gpu           no GPU hardware on CI
#   --disable-gpu-compositing  avoid software GPU subprocess fallback
#   --disable-dev-shm-usage use /tmp instead of /dev/shm (small in containers)
export CODETRACER_ELECTRON_ARGS="--no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage"

# TODO: Restore `just ui-tests` here (which also runs `just test-e2e`
#   Playwright TypeScript tests). It was downgraded to C#-only because
#   `just ui-tests` calls `just test-e2e` which needs CODETRACER_REPO_ROOT_PATH
#   (now set in ui-tests.nix) and was failing with "unbound variable" under
#   set -euo. Now that ui-tests.nix exports the variable, `just ui-tests`
#   should work — but needs to be validated in CI first.
just test-csharp-ui xvfb --mode Electron --suite stable-tests --retries 2
