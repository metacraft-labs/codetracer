#!/usr/bin/env bash

set -e

GIT_ROOT=$(git rev-parse --show-toplevel)
export GIT_ROOT

APP_DIR="${GIT_ROOT}/windows"
export APP_DIR

mkdir -p "${APP_DIR}"

# This is the env var which essentially controls where we'll put our
# compiled files/static resources
export NIX_CODETRACER_EXE_DIR="${APP_DIR}"

mkdir -p "${APP_DIR}"/bin
mkdir -p "${APP_DIR}"/src
mkdir -p "${APP_DIR}"/lib

# Copy over resources
cp -Lr "${GIT_ROOT}"/resources "${APP_DIR}"

# Config
cp -Lr "${GIT_ROOT}/config" "${APP_DIR}/config"
cp -Lr "${GIT_ROOT}/src/public" "${APP_DIR}/public"

# Copy over electron
bash "${GIT_ROOT}"/windows-scripts/install_electron.sh

# Setup node deps
bash "${GIT_ROOT}"/windows-scripts/setup_node_deps.sh

cp -Lr "${GIT_ROOT}/src/public/dist/frontend_bundle.js" "${APP_DIR}"

# Build css
bash "${GIT_ROOT}"/windows-scripts/build_css.sh

# Build js
bash "${GIT_ROOT}"/windows-scripts/build_js.sh

# Build db-backend
bash "${GIT_ROOT}"/windows-scripts/build_db_backend.sh

# Build Noir
bash "${GIT_ROOT}"/windows-scripts/build_noir.sh

# cp "${GIT_ROOT}"/windows-scripts/index.js "${APP_DIR}"/src
# cp "${GIT_ROOT}"/windows-scripts/subwindow.js "${APP_DIR}"/src
# cp "${GIT_ROOT}"/windows-scripts/index.js "${APP_DIR}"/src

# JS Helper function definitions
cp "${GIT_ROOT}/src/helpers.js" "${APP_DIR}/src/helpers.js"
cp "${GIT_ROOT}/src/helpers.js" "${APP_DIR}/helpers.js"


# Build CodeTracer
bash "${GIT_ROOT}"/windows-scripts/build_ct.sh
