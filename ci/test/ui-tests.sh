#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running C# UI e2e playwright tests'
echo '###############################################################################'

# The nix-store Electron chrome-sandbox binary lacks the SUID bit, so we must
# disable the Chromium sandbox when running in CI.
export CODETRACER_ELECTRON_ARGS="--no-sandbox"

just test-csharp-ui xvfb --mode Electron
