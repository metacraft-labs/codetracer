#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running C# UI e2e playwright tests'
echo '###############################################################################'

just test-csharp-ui xvfb
