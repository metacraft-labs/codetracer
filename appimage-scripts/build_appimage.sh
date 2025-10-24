#!/usr/bin/env bash

# THIS SCRIPT IS TO BE RUN IN OUR DEV SHELL

# The goal of this script is to prepare an `AppDir` (see the spec below)
# and then to launch the appimagetool to create an AppImage.
#
# AppDir spec: https://github.com/AppImage/AppImageSpec/blob/master/draft.md#appdir
# appimagetool: https://github.com/AppImage/appimagetool
echo "============================"
echo "AppImage build start"
echo "============================"
set -euo pipefail

cleanup() {
  echo "Performing cleanup..."
  if [ -d ./squashfs-root ]; then
    chmod -R u+rwX ./squashfs-root >/dev/null 2>&1 || true
    rm -rf ./squashfs-root
  fi
}

trap cleanup EXIT

ROOT_PATH=$(git rev-parse --show-toplevel)
export ROOT_PATH

APP_DIR="${ROOT_PATH}/squashfs-root"
export APP_DIR

if [ -e "${ROOT_PATH}/CodeTracer.AppImage" ]; then
  chmod -f u+rw "${ROOT_PATH}/CodeTracer.AppImage" >/dev/null 2>&1 || true
  rm -f "${ROOT_PATH}/CodeTracer.AppImage"
fi

if [ -d "${APP_DIR}" ]; then
  chmod -R u+rwX "${APP_DIR}" >/dev/null 2>&1 || true
  rm -rf "${APP_DIR}"
fi
mkdir -p "${APP_DIR}"

# This environment variable controls where build artifacts and static resources end up.
export NIX_CODETRACER_EXE_DIR="${APP_DIR}"

CURRENT_NIX_SYSTEM=$(nix eval --impure --raw --expr 'builtins.currentSystem')
APPIMAGE_PAYLOAD=$(nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.appimagePayload" --no-link --print-out-paths | tail -n1)

cp -Lr "${APPIMAGE_PAYLOAD}/." "${APP_DIR}/"

chmod -R u+rwX "${APP_DIR}"

# Copy over electron
# bash "${ROOT_PATH}/appimage-scripts/install_electron_nix.sh"
bash "${ROOT_PATH}/appimage-scripts/install_electron.sh"

# Setup node deps
bash "${ROOT_PATH}/appimage-scripts/setup_node_deps.sh"

cp -Lr "${ROOT_PATH}/src/public" "${APP_DIR}/public"
chmod -R +wr "${APP_DIR}/public"
mkdir -p "${APP_DIR}/public/dist"
cp -Lr "${ROOT_PATH}/src/public/dist/frontend_bundle.js" "${APP_DIR}/frontend_bundle.js"


chmod -R +x "${APP_DIR}/electron"

CURRENT_ARCH=$(uname -m)
if [[ "${CURRENT_ARCH}" == "aarch64" ]]; then
  INTERPRETER_PATH=/lib/ld-linux-aarch64.so.1
else
  INTERPRETER_PATH=/lib64/ld-linux-x86-64.so.2
fi

APPIMAGE_ARCH=${CURRENT_ARCH}
if [[ "${APPIMAGE_ARCH}" == "aarch64" ]]; then
  # The appimagetool has its own convention for specifying the ARM64 arch.
  APPIMAGE_ARCH=arm_aarch64
fi

# Use AppImage tool to create AppImage itself
ARCH=${APPIMAGE_ARCH} appimagetool "${APP_DIR}" CodeTracer.AppImage

patchelf --set-interpreter "${INTERPRETER_PATH}" "${ROOT_PATH}/CodeTracer.AppImage"
patchelf --remove-rpath "${ROOT_PATH}/CodeTracer.AppImage"

echo "============================"
echo "AppImage successfully built!"
echo "============================"
