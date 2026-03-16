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

# setup node deps
bash setup_node_deps.sh

# build our css files
bash build_css.sh

cd "$ROOT_DIR"
# build/setup nim-based files
bash ./non-nix-build/build_with_nim.sh

cd non-nix-build

# build/setup db-backend
bash build_db_backend.sh

# build backend-manager
bash build_backend_manager.sh

# for now just put them in src/
#   not great, but much easier for now as the public/static files
#   are just there, no need for special copying/linking
#   however it would be best to link to them in a separate tup-like
#   src/build-debug!

# setup/copy/link other files
cp "$ROOT_DIR"/resources/electron "$DIST_DIR"/bin/

# The built-in macOS ruby binary is too old and has to be hacked around
ln -s "$(brew --prefix ruby)"/bin/ruby "$DIST_DIR"/bin/ruby
# Detect sibling repos (sets RUBY_RECORDER_ROOT, CODETRACER_*_PATH, etc.)
source "$ROOT_DIR/scripts/detect-siblings.sh" "$ROOT_DIR"

# ruby recorder — copy from detected sibling
if [ -n "${RUBY_RECORDER_ROOT:-}" ]; then
	cp -Lr "${RUBY_RECORDER_ROOT}" "$DIST_DIR"/
else
	echo "WARNING: codetracer-ruby-recorder not found; build will lack Ruby tracing support"
fi
# Make the ruby recorder discoverable via PATH (in bin/)
if [ -x "$DIST_DIR/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder" ]; then
	ln -sf "../codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder" "$DIST_DIR/bin/codetracer-ruby-recorder"
fi
cp "$(which ctags)" "$DIST_DIR"/bin/ctags
cp "$ROOT_DIR"/src/helpers.js "$DIST_DIR"/src/helpers.js
cp "$ROOT_DIR"/src/helpers.js "$DIST_DIR"/helpers.js
cp "$ROOT_DIR"/src/frontend/*.html "$DIST_DIR"/src/
cp "$ROOT_DIR"/src/frontend/*.html "$DIST_DIR"/
rm -f "$DIST_DIR"/config
rm -f "$DIST_DIR"/public
cp -r "$ROOT_DIR"/src/config "$DIST_DIR"/config
cp -r "$ROOT_DIR"/src/public "$DIST_DIR"/public
cp -r "$BIN_DIR"/* "$DIST_DIR"/bin/

mv "$DIST_DIR"/bin/ct "$DIST_DIR"/bin/ct_unwrapped

cat <<'EOF' >"${DIST_DIR}"/bin/ct
#!/usr/bin/env bash

export HERE=$(dirname $(dirname "$0"))

export CODETRACER_PREFIX=$HERE
export PATH="${HERE}/bin:${PATH}"

exec ${HERE}/bin/ct_unwrapped "$@"
EOF

chmod +x "${DIST_DIR}"/bin/ct

# Enable the installation prompt. Extra argument to be compatible with FreeBSD coreutils
sed -i "" "s/skipInstall.*/skipInstall: false/g" "$DIST_DIR/config/default_config.yaml"
