#!/usr/bin/env bash

set -e

# setup env (based on nix/shells/main.nix):

export CODETRACER_BUILD_PLATFORM="$1"
export CODETRACER_BUILD_OS="$2"

# =========================================

rm -rf "$DIST_DIR"
rm -rf "$ROOT_DIR/non-nix-build/CodeTracer.app"

mkdir -p "$DIST_DIR/bin"
mkdir -p "$DIST_DIR/src"

# setup node deps (includes webpack)
bash setup_node_deps.sh

# Build everything via tup generate (avoids FUSE requirement)
pushd "$ROOT_DIR/src"
if [ ! -d .tup ]; then
    tup init
fi
TUP_OUTPUT_SCRIPT=tup-generated-build-once.sh
tup generate --config build-release/tup.config "$TUP_OUTPUT_SCRIPT"
./"$TUP_OUTPUT_SCRIPT"
rm "$TUP_OUTPUT_SCRIPT"
popd

BUILD_DIR="$ROOT_DIR/src/build-release"

# Copy compiled binaries from tup build output
cp "$BUILD_DIR"/bin/ct "$DIST_DIR"/bin/ct
cp "$BUILD_DIR"/bin/codetracer_depending_on_env_vars_in_tup "$DIST_DIR"/bin/codetracer_depending_on_env_vars_in_tup
cp "$BUILD_DIR"/bin/db-backend-record "$DIST_DIR"/bin/db-backend-record
cp "$BUILD_DIR"/bin/db-backend "$DIST_DIR"/bin/db-backend
cp "$BUILD_DIR"/bin/backend-manager "$DIST_DIR"/bin/backend-manager

# Copy JS files
cp "$BUILD_DIR"/index.js "$DIST_DIR"/index.js
cp "$BUILD_DIR"/src/index.js "$DIST_DIR"/src/index.js
cp "$BUILD_DIR"/subwindow.js "$DIST_DIR"/subwindow.js
cp "$BUILD_DIR"/ui.js "$DIST_DIR"/ui.js
cp "$BUILD_DIR"/helpers.js "$DIST_DIR"/helpers.js
cp "$BUILD_DIR"/src/helpers.js "$DIST_DIR"/src/helpers.js

# Copy HTML files
cp "$BUILD_DIR"/index.html "$DIST_DIR"/index.html
cp "$BUILD_DIR"/subwindow.html "$DIST_DIR"/subwindow.html

# Copy config and public assets
rm -f "$DIST_DIR"/config
rm -f "$DIST_DIR"/public
cp -r "$BUILD_DIR"/config "$DIST_DIR"/config
cp -r "$BUILD_DIR"/public "$DIST_DIR"/public

# Copy frontend styles
mkdir -p "$DIST_DIR/frontend/styles"
cp "$BUILD_DIR"/frontend/styles/*.css "$DIST_DIR"/frontend/styles/

# setup/copy/link non-tup-managed files
cp "$ROOT_DIR"/resources/electron "$DIST_DIR"/bin/

if [ "$CODETRACER_BUILD_OS" == "mac" ]; then
    # The built-in macOS ruby binary is too old and has to be hacked around
    ln -s "$(brew --prefix ruby)"/bin/ruby "$DIST_DIR"/bin/ruby
fi

cp -Lr "${ROOT_DIR}"/libs/codetracer-ruby-recorder "$DIST_DIR"/
cp "$(which ctags)" "$DIST_DIR"/bin/ctags
cp -r "$BIN_DIR"/* "$DIST_DIR"/bin/

# Mac-specific binary post-processing
if [ "$CODETRACER_BUILD_OS" == "mac" ]; then
    install_name_tool \
        -add_rpath "@executable_path/../../Frameworks" \
        "${DIST_DIR}/bin/ct"
    install_name_tool -add_rpath "@loader_path" "${DIST_DIR}/bin/ct"
    codesign -s - --force --deep "${DIST_DIR}/bin/ct"

    install_name_tool \
        -add_rpath "@executable_path/../../Frameworks" \
        "${DIST_DIR}/bin/db-backend-record"
    codesign -s - --force --deep "${DIST_DIR}/bin/db-backend-record"
fi

mv "$DIST_DIR"/bin/ct "$DIST_DIR"/bin/ct_unwrapped

cat <<'EOF' >"${DIST_DIR}"/bin/ct
#!/usr/bin/env bash

export HERE=$(dirname $(dirname "$0"))

export CODETRACER_RUBY_RECORDER_PATH="${HERE}/codetracer-ruby-recorder/gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder"

exec ${HERE}/bin/ct_unwrapped "$@"
EOF

chmod +x "${DIST_DIR}"/bin/ct

# Enable the installation prompt. Extra argument to be compatible with FreeBSD coreutils
sed -i "" "s/skipInstall.*/skipInstall: false/g" "$DIST_DIR/config/default_config.yaml"
