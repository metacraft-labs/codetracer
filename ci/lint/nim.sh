#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Testing nimsuggest'
echo '###############################################################################'

# Use Nim 1.6 for nimsuggest - vendored libs aren't compatible with Nim 2.x nimsuggest
./scripts/with-nim-1.6 just test-nimsuggest

echo '###############################################################################'
echo 'TODO: nim check'
echo '###############################################################################'
