#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running Go smoke UI tests'
echo '###############################################################################'

# CI-specific Electron/Chromium flags:
#   --no-sandbox            nix-store chrome-sandbox lacks the SUID bit
#   --no-zygote             prevents Zygote fork failures on restricted CI runners
#   --disable-gpu           no GPU hardware on CI
#   --disable-gpu-compositing  avoid software GPU subprocess fallback
#   --disable-dev-shm-usage use /tmp instead of /dev/shm (small in containers)
export CODETRACER_ELECTRON_ARGS="--no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage"

just test-csharp-ui xvfb --mode Electron --suite go-smoke --retries 2
