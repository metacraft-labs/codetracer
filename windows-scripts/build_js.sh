#!/usr/bin/env bash

GIT_ROOT=$(git rev-parse --show-toplevel)

# index.js
nim \
    --hints:on --warnings:off --sourcemap:on \
    -d:ctIndex -d:chronicles_sinks=json \
    -d:nodejs --out:"${GIT_ROOT}/windows-scripts/windows/index.js" js "${GIT_ROOT}"/src/frontend/index.nim

# ui.js
nim \
    --hints:off --warnings:off \
    -d:chronicles_enabled=off  \
    -d:ctRenderer \
    --out:"${GIT_ROOT}/windows-scripts/windows/ui.js" js "${GIT_ROOT}"/src/frontend/ui_js.nim

# subwindow.js
nim \
    --hints:off --warnings:off \
    -d:chronicles_enabled=off  \
    -d:ctRenderer \
    --out:"${GIT_ROOT}/windows-scripts/windows/subwindow.js" js "${GIT_ROOT}"/src/frontend/subwindow.nim

# cp "${GIT_ROOT}/src/frontend/subwindow.html" "${GIT_ROOT}"/windows-scripts/subwindow.html
