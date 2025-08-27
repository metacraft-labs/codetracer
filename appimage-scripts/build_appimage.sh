#!/usr/bin/env bash

# THIS SCRIPT IS TO BE RUN IN OUR DEV SHELL

# The goal of this script is to prepare an `AppDir` (see the spec below)
# and then to launch tha appimagetool to create an AppImage
#
# AppDir spec: https://github.com/AppImage/AppImageSpec/blob/master/draft.md#appdir
# appimagetool: https://github.com/AppImage/appimagetool

set -e

cleanup() {
  echo "Performing cleanup..."
  rm -rf ./squashfs-root
}

trap cleanup EXIT

ROOT_PATH=$(git rev-parse --show-toplevel)
export ROOT_PATH

APP_DIR="${ROOT_PATH}/squashfs-root"
export APP_DIR

if [ -e "${ROOT_PATH}"/CodeTracer.AppImage ]; then
  rm -rf "${ROOT_PATH}"/CodeTracer.AppImage
fi

mkdir "${APP_DIR}"

# This is the env var which essentially controls where we'll put our
# compiled files/static resources
export NIX_CODETRACER_EXE_DIR="${APP_DIR}"

mkdir -p "${APP_DIR}"/bin
mkdir -p "${APP_DIR}"/src
mkdir -p "${APP_DIR}"/lib
mkdir -p "${APP_DIR}"/views

# Install Ruby
bash "${ROOT_PATH}"/appimage-scripts/install_ruby.sh

cat << 'EOF' > "${APP_DIR}/bin/ruby"
#!/usr/bin/env bash

HERE="${HERE:-..}"

# TODO: This includes references to x86_64. What about aarch6?
export RUBYLIB="${HERE}/ruby/lib/ruby/3.3.0:${HERE}/ruby/lib/ruby/3.3.0/x86_64-linux:${RUBYLIB}"

"${HERE}/ruby/bin/ruby" "$@"

EOF

CURRENT_NIX_SYSTEM=$(nix eval --impure --raw --expr 'builtins.currentSystem')
CURRENT_ARCH=$(uname -m)

# Copy over needed Nim libs
# cp -r "${ROOT_PATH}"/libs/nim-appimage-deps/libpcre.so.1 "${APP_DIR}/lib"

# Try and build dependencies, in case we don't have them in the nix-store
nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.sqlite"

SQLITE=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.sqlite.out")
cp -L "${SQLITE}"/lib/libsqlite3.so.0 "${APP_DIR}"/lib
cp -L "${SQLITE}"/lib/libsqlite3.so "${APP_DIR}"/lib

nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.pcre"

PCRE=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.pcre.out")
cp -L "${PCRE}"/lib/libpcre.so.1 "${APP_DIR}"/lib

nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.libzip"

LIBZIP=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.libzip.out")
cp -L "${LIBZIP}"/lib/libzip.so.5 "${APP_DIR}"/lib

nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.curl"

OPENSSL=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.openssl.out")
cp -L "${OPENSSL}"/lib/libssl.so.3 "${APP_DIR}"/lib
cp -L "${OPENSSL}"/lib/libssl.so "${APP_DIR}"/lib
cp -L "${OPENSSL}"/lib/libcrypto.so "${APP_DIR}"/lib
cp -L "${OPENSSL}"/lib/libcrypto.so.3 "${APP_DIR}"/lib

nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.libuv"
LIBUV=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.libuv.out")
cp -L "${LIBUV}"/lib/libuv.so.1 "${APP_DIR}"/lib

# Provide Electron from Nix so yarn/electron-builder operate offline
nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.electron"
ELECTRON=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.electron.out")
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export ELECTRON_OVERRIDE_DIST_PATH="${ELECTRON}/lib/electron"
export npm_config_electron_skip_binary_download=1

# Setup node deps
bash "${ROOT_PATH}"/appimage-scripts/setup_node_deps.sh

# Build electron runtime using electron-builder
pushd "${ROOT_PATH}/node-packages"
npx electron-builder --linux dir
popd
cp -r "${ROOT_PATH}/node-packages/dist/linux-unpacked" "${APP_DIR}/electron"
rm -rf "${ROOT_PATH}/node-packages/node_modules"
cat <<'EOF' > "${APP_DIR}/bin/electron"
#!/usr/bin/env bash

ELECTRON_DIR=${HERE:-..}/electron

export LD_LIBRARY_PATH="${HERE}/ruby/lib:${HERE}/lib:/usr/lib/:/usr/lib64/:/usr/lib/x86_64-linux-gnu/:${LD_LIBRARY_PATH}"

"${ELECTRON_DIR}/codetracer-electron" --no-sandbox "$@"
EOF
chmod +x "${APP_DIR}/bin/electron"

# Build our css files
bash "${ROOT_PATH}"/appimage-scripts/build_css.sh

# Build/setup nim-based files
bash "${ROOT_PATH}"/appimage-scripts/build_with_nim.sh

cat << 'EOF' > "${APP_DIR}/bin/ct"
#!/usr/bin/env bash

HERE=${HERE:-$(dirname "$(readlink -f "${0}")")}

# TODO: This includes references to x86_64. What about aarch64?
export LD_LIBRARY_PATH="${HERE}/ruby/lib:${HERE}/lib:/usr/lib/:/usr/lib64/:/usr/lib/x86_64-linux-gnu/:${LD_LIBRARY_PATH}"

exec "${HERE}"/bin/ct_unwrapped "$@"

EOF

# Build/setup db-backend
bash "${ROOT_PATH}"/appimage-scripts/build_db_backend.sh

# Noir
cp -Lr "${ROOT_PATH}/src/links/nargo" "${APP_DIR}/bin/"
chmod +x "${APP_DIR}/bin/nargo"

# Wazero
nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.wazero"

WAZERO=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.wazero.out")
cp -L "${WAZERO}"/bin/wazero "${APP_DIR}"/bin

# cargo-stylus
nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.cargo-stylus"

CARGO_STYLUS=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.cargo-stylus.out")
cp -L "${CARGO_STYLUS}"/bin/cargo-stylus "${APP_DIR}"/bin

# ctags
cp -Lr "${ROOT_PATH}/src/links/ctags" "${APP_DIR}/bin/"
chmod +x "${APP_DIR}/bin/ctags"
# We want splitting
# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/ctags" | grep -v glibc | grep /nix) "${APP_DIR}"/lib


# curl
cp -Lr "${ROOT_PATH}/src/links/curl" "${APP_DIR}/bin/"
chmod +x "${APP_DIR}/bin/curl"
# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/curl" | grep -v glibc | grep /nix) "${APP_DIR}"/lib
ls -al "${APP_DIR}"/lib


# node
cp -Lr "${ROOT_PATH}/src/links/node" "${APP_DIR}/bin/"
chmod +x "${APP_DIR}/bin/node"

# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/node" | grep -v glibc | grep /nix) "${APP_DIR}"/lib

# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/cargo-stylus" | grep -v glibc | grep /nix) "${APP_DIR}"/lib

chmod -R +x "${APP_DIR}/bin"
chmod -R +x "${APP_DIR}/electron"

chmod -R 777 "${APP_DIR}"

cp "${ROOT_PATH}"/libs/codetracer-ruby-recorder/src/*.rb "${APP_DIR}/src/"
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
cat << 'EOF' > "${APP_DIR}/AppRun"
#!/usr/bin/env bash

export HERE=$(dirname "$(readlink -f "${0}")")

# TODO: This includes references to x86_64. What about aarch64?
export LD_LIBRARY_PATH="${HERE}/ruby/lib:${HERE}/lib:/usr/lib/:/usr/lib64/:/usr/lib/x86_64-linux-gnu/:${LD_LIBRARY_PATH}"
export LINKS_PATH_DIR=$HERE
export PATH="${HERE}/bin:${PATH}"

exec ${HERE}/bin/ct "$@"
EOF

chmod +x "${APP_DIR}/AppRun"

# Copy over desktop file
cp "${ROOT_PATH}/resources/codetracer.desktop" "${APP_DIR}/"

# Copy over resources
cp -Lr "${ROOT_PATH}"/resources "${APP_DIR}"

# We need to copy over the CodeTracer icons. Here is what the spec says:
#
# SHOULD contain icon files below usr/share/icons/hicolor following the Icon
# Theme Specification for the icon identifier as set in the Icon= key of the
# $APPNAME.desktop file. If present, these icon files SHOULD be given
# preference as the icon being used to represent the AppImage.

SRC_ICONSET_DIR="${ROOT_PATH}/resources/Icon.iconset"

# TODO: discover these dinamically perhaps
for SIZE in 16 32 128 256 512
do
  XSIZE="${SIZE}x${SIZE}"
  DST_PATH="${APP_DIR}/usr/share/icons/hicolor/${XSIZE}/apps/"
  DOUBLE_SIZE_DST_PATH="${APP_DIR}/usr/share/icons/hicolor/${XSIZE}@2/apps/"
  mkdir -p "${DST_PATH}" "${DOUBLE_SIZE_DST_PATH}"
  cp "${SRC_ICONSET_DIR}/icon_${XSIZE}.png" "${DST_PATH}/codetracer.png"
  cp "${SRC_ICONSET_DIR}/icon_${XSIZE}@2x.png" "${DOUBLE_SIZE_DST_PATH}/codetracer.png"
done

# From the spec:
#
# MAY contain an $APPICON.svg, $APPICON.svgz or $APPICON.png file in its root
# directory with $APPICON being the icon identifier as set in the Icon= key
# of the $APPNAME.desktop file. If present and no icon files matching the
# icon identifier present below usr/share/icons/hicolor, this icon SHOULD
# be given preference as the icon being used to represent the AppImage.
# If a PNG file, the icon SHOULD be of size 256x256, 512x512, or 1024x1024 pixels.
cp "${ROOT_PATH}/resources/Icon.iconset/icon_256x256.png" "${APP_DIR}/codetracer.png"

if [[ "$CURRENT_ARCH" == "aarch64" ]]; then
  INTERPRETER_PATH=/lib/ld-linux-aarch64.so.1
else
  INTERPRETER_PATH=/lib64/ld-linux-x86-64.so.2
fi

# Patchelf the executable's interpreter
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/ct_unwrapped
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/db-backend
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/db-backend-record
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/nargo
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/wazero
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/ctags
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/curl
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/cargo-stylus
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/bin/node
patchelf --set-interpreter "${INTERPRETER_PATH}" "${APP_DIR}"/ruby/bin/ruby

# Clear up the executable's rpath
patchelf --remove-rpath "${APP_DIR}"/bin/ct_unwrapped
patchelf --remove-rpath "${APP_DIR}"/bin/db-backend
patchelf --remove-rpath "${APP_DIR}"/bin/db-backend-record
patchelf --remove-rpath "${APP_DIR}"/bin/nargo
patchelf --remove-rpath "${APP_DIR}"/bin/wazero
patchelf --remove-rpath "${APP_DIR}"/bin/ctags
patchelf --remove-rpath "${APP_DIR}"/bin/curl
patchelf --remove-rpath "${APP_DIR}"/bin/node
patchelf --remove-rpath "${APP_DIR}"/ruby/bin/ruby

patchelf --set-rpath "\$ORIGIN/../lib" "${APP_DIR}/bin/node"

APPIMAGE_ARCH=$CURRENT_ARCH
if [[ "$APPIMAGE_ARCH" == "aarch64" ]]; then
  # The appimagetool has its own convention for specifying the ARM64 arch
  APPIMAGE_ARCH=arm_aarch64
fi

# Use AppImage tool to create AppImage itself
ARCH=$APPIMAGE_ARCH appimagetool "${APP_DIR}" CodeTracer.AppImage

patchelf --set-interpreter "${INTERPRETER_PATH}" "${ROOT_PATH}"/CodeTracer.AppImage
patchelf --remove-rpath "${ROOT_PATH}"/CodeTracer.AppImage

echo "============================"
echo "AppImage successfully built!"
echo "============================"
