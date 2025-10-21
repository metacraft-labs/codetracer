#!/usr/bin/env bash

# THIS SCRIPT IS TO BE RUN IN OUR DEV SHELL

# The goal of this script is to prepare an `AppDir` (see the spec below)
# and then to launch the appimagetool to create an AppImage.
#
# AppDir spec: https://github.com/AppImage/AppImageSpec/blob/master/draft.md#appdir
# appimagetool: https://github.com/AppImage/appimagetool

set -euo pipefail

cleanup() {
  echo "Performing cleanup..."
  rm -rf ./squashfs-root
}

trap cleanup EXIT

ROOT_PATH=$(git rev-parse --show-toplevel)
export ROOT_PATH

APP_DIR="${ROOT_PATH}/squashfs-root"
export APP_DIR

if [ -e "${ROOT_PATH}/CodeTracer.AppImage" ]; then
  rm -rf "${ROOT_PATH}/CodeTracer.AppImage"
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"

# This environment variable controls where build artifacts and static resources end up.
export NIX_CODETRACER_EXE_DIR="${APP_DIR}"

CURRENT_NIX_SYSTEM=$(nix eval --impure --raw --expr 'builtins.currentSystem')
APPIMAGE_DEPS=$(nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.appimageDeps" --no-link --print-out-paths | tail -n1)

cp -Lr "${APPIMAGE_DEPS}/." "${APP_DIR}/"

chmod -R u+rwX "${APP_DIR}"

mkdir -p "${APP_DIR}/bin" "${APP_DIR}/src" "${APP_DIR}/views"

# Install Ruby
bash "${ROOT_PATH}/appimage-scripts/install_ruby.sh"

cat <<'EOF' >"${APP_DIR}/bin/ruby"
#!/usr/bin/env bash

HERE="${HERE:-..}"

# TODO: This includes references to x86_64. What about aarch64?
export RUBYLIB="${HERE}/ruby/lib/ruby/3.3.0:${HERE}/ruby/lib/ruby/3.3.0/x86_64-linux:${RUBYLIB}"

"${HERE}/ruby/bin/ruby" "$@"

EOF

# ruby recorder
cp -Lr "${ROOT_PATH}/libs/codetracer-ruby-recorder" "${APP_DIR}/"

# Copy over electron
# bash "${ROOT_PATH}/appimage-scripts/install_electron_nix.sh"
bash "${ROOT_PATH}/appimage-scripts/install_electron.sh"

# Setup node deps
bash "${ROOT_PATH}/appimage-scripts/setup_node_deps.sh"

# Build our css files
bash "${ROOT_PATH}/appimage-scripts/build_css.sh"

# Build/setup nim-based files
bash "${ROOT_PATH}/appimage-scripts/build_with_nim.sh"

cat <<'EOF' >"${APP_DIR}/bin/ct"
#!/usr/bin/env bash

HERE=${HERE:-$(dirname "$(readlink -f "${0}")")}

# TODO: This includes references to x86_64. What about aarch64?

exec "${HERE}/bin/ct_unwrapped" "$@"

EOF

# Build/setup db-backend
bash "${ROOT_PATH}/appimage-scripts/build_db_backend.sh"

# Build/setup backend-manager
bash "${ROOT_PATH}/appimage-scripts/build_backend_manager.sh"

# Ensure copied binaries are executable.
chmod +x "${APP_DIR}/bin/"{cargo-stylus,ctags,curl,nargo,node,wazero}

chmod -R +x "${APP_DIR}/bin"
chmod -R +x "${APP_DIR}/electron"

chmod -R 777 "${APP_DIR}"

cp "${ROOT_PATH}/src/helpers.js" "${APP_DIR}/src/helpers.js"
cp "${ROOT_PATH}/src/helpers.js" "${APP_DIR}/helpers.js"

cp "${ROOT_PATH}/src/frontend/index.html" "${APP_DIR}/src/index.html"
cp "${ROOT_PATH}/src/frontend/index.html" "${APP_DIR}/index.html"

cp "${ROOT_PATH}/src/frontend/subwindow.html" "${APP_DIR}/subwindow.html"
cp "${ROOT_PATH}/src/frontend/subwindow.html" "${APP_DIR}/src/subwindow.html"

cp "${ROOT_PATH}/views/server_index.ejs" "${APP_DIR}/views/server_index.ejs"

rm -rf "${APP_DIR}/config"
rm -rf "${APP_DIR}/public"
cp -Lr "${ROOT_PATH}/src/config" "${APP_DIR}/config"

# Enable the installation prompt
sed -i "s/skipInstall.*/skipInstall: false/g" "${APP_DIR}/config/default_config.yaml"

cp -Lr "${ROOT_PATH}/src/public" "${APP_DIR}/public"
chmod -R +wr "${APP_DIR}/public"

cp -Lr "${ROOT_PATH}/src/public/dist/frontend_bundle.js" "${APP_DIR}"

# Create AppRun script
cat <<'EOF' >"${APP_DIR}/AppRun"
#!/usr/bin/env bash

export HERE=$(dirname "$(readlink -f "${0}")")

# TODO: This includes references to x86_64. What about aarch64?
export LINKS_PATH_DIR=$HERE
export PATH="${HERE}/bin:${PATH}"
export CODETRACER_RUBY_RECORDER_PATH="${HERE}/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder"

exec ${HERE}/bin/ct "$@"
EOF

chmod +x "${APP_DIR}/AppRun"

# Copy over desktop file
cp "${ROOT_PATH}/resources/codetracer.desktop" "${APP_DIR}/"

# Copy over resources
cp -Lr "${ROOT_PATH}/resources" "${APP_DIR}"

SRC_ICONSET_DIR="${ROOT_PATH}/resources/Icon.iconset"

# TODO: discover these dynamically perhaps
for SIZE in 16 32 128 256 512; do
  XSIZE="${SIZE}x${SIZE}"
  DST_PATH="${APP_DIR}/usr/share/icons/hicolor/${XSIZE}/apps/"
  DOUBLE_SIZE_DST_PATH="${APP_DIR}/usr/share/icons/hicolor/${XSIZE}@2/apps/"
  mkdir -p "${DST_PATH}" "${DOUBLE_SIZE_DST_PATH}"
  cp "${SRC_ICONSET_DIR}/icon_${XSIZE}.png" "${DST_PATH}/codetracer.png"
  cp "${SRC_ICONSET_DIR}/icon_${XSIZE}@2x.png" "${DOUBLE_SIZE_DST_PATH}/codetracer.png"
done

cp "${ROOT_PATH}/resources/Icon.iconset/icon_256x256.png" "${APP_DIR}/codetracer.png"

CURRENT_ARCH=$(uname -m)
if [[ "${CURRENT_ARCH}" == "aarch64" ]]; then
  INTERPRETER_PATH=/lib/ld-linux-aarch64.so.1
else
  INTERPRETER_PATH=/lib64/ld-linux-x86-64.so.2
fi

# Patchelf the executable's interpreter
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/ct_unwrapped"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/db-backend"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/db-backend-record"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/backend-manager"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/nargo"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/wazero"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/ctags"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/curl"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/cargo-stylus"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/bin/node"
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}/ruby/bin/ruby"

# Clear up the executable's rpath
patchelf --remove-rpath "${APP_DIR}/bin/ct_unwrapped"
patchelf --remove-rpath "${APP_DIR}/bin/db-backend"
patchelf --remove-rpath "${APP_DIR}/bin/db-backend-record"
patchelf --remove-rpath "${APP_DIR}/bin/backend-manager"
patchelf --remove-rpath "${APP_DIR}/bin/nargo"
patchelf --remove-rpath "${APP_DIR}/bin/wazero"
patchelf --remove-rpath "${APP_DIR}/bin/ctags"
patchelf --remove-rpath "${APP_DIR}/bin/curl"
patchelf --remove-rpath "${APP_DIR}/bin/cargo-stylus"
patchelf --remove-rpath "${APP_DIR}/bin/node"
patchelf --remove-rpath "${APP_DIR}/ruby/bin/ruby"

patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/node"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/ct_unwrapped"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/db-backend"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/db-backend-record"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/backend-manager"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/nargo"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/wazero"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/ctags"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/curl"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/node"
patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/ruby/bin/ruby"

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
