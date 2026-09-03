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
	chmod -R 777 "${APP_DIR}" || true
	rm -rf ./squashfs-root
}

trap cleanup EXIT ERR INT TERM HUP QUIT

ROOT_PATH=$(git rev-parse --show-toplevel)
export ROOT_PATH

APP_DIR="${ROOT_PATH}/squashfs-root"
export APP_DIR

if [ -e "${ROOT_PATH}"/CodeTracer.AppImage ]; then
	rm -rf "${ROOT_PATH}"/CodeTracer.AppImage
fi

if [ -d "${APP_DIR}" ]; then
	chmod -R u+w "${APP_DIR}" || true
	rm -rf "${APP_DIR}"
fi

mkdir "${APP_DIR}"

# This is the env var which essentially controls where we'll put our
# compiled files/static resources
export CODETRACER_PREFIX="${APP_DIR}"

mkdir -p "${APP_DIR}"/bin
mkdir -p "${APP_DIR}"/src
mkdir -p "${APP_DIR}"/lib
mkdir -p "${APP_DIR}"/views

# Install Ruby
bash "${ROOT_PATH}"/appimage-scripts/install_ruby.sh

cat <<'EOF' >"${APP_DIR}/bin/ruby"
#!/usr/bin/env bash

HERE="${HERE:-..}"

# TODO: This includes references to x86_64. What about aarch6?
export RUBYLIB="${HERE}/ruby/lib/ruby/3.3.0:${HERE}/ruby/lib/ruby/3.3.0/x86_64-linux:${RUBYLIB}"

"${HERE}/ruby/bin/ruby" "$@"

EOF

# ruby recorder — prefer sibling repo, fall back to submodule (deprecated)
WORKSPACE_ROOT="$(cd "${ROOT_PATH}/.." 2>/dev/null && pwd)"
if [ -d "${WORKSPACE_ROOT}/codetracer-ruby-recorder" ]; then
	cp -Lr "${WORKSPACE_ROOT}/codetracer-ruby-recorder" "${APP_DIR}/"
elif [ -d "${ROOT_PATH}/libs/codetracer-ruby-recorder" ]; then
	cp -Lr "${ROOT_PATH}/libs/codetracer-ruby-recorder" "${APP_DIR}/"
else
	echo "WARNING: codetracer-ruby-recorder not found; AppImage will lack Ruby tracing support"
fi

# Make the ruby recorder discoverable via PATH (in ${APP_DIR}/bin/)
if [ -x "${APP_DIR}/codetracer-ruby-recorder/gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder" ]; then
	ln -sf "../codetracer-ruby-recorder/gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder" "${APP_DIR}/bin/codetracer-ruby-recorder"
fi

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

# libbpf — needed by the native BPF process monitor used by `ct ci`.
# ct_unwrapped links against libbpf.so.1; libbpf itself transitively
# pulls in libelf.so.1, which is also rarely shipped by base distro
# images.  Bundling both keeps the AppImage self-contained on Debian/
# Fedora/Arch where neither lib is installed by default.
nix build --no-link "nixpkgs#libbpf"
LIBBPF=$(nix eval --raw "nixpkgs#libbpf.out" 2>/dev/null)
cp -L "${LIBBPF}"/lib/libbpf.so.1 "${APP_DIR}"/lib

nix build --no-link "nixpkgs#elfutils"
LIBELF=$(nix eval --raw "nixpkgs#elfutils.out" 2>/dev/null)
cp -L "${LIBELF}"/lib/libelf.so.1 "${APP_DIR}"/lib

# Copy over electron
# bash "${ROOT_PATH}"/appimage-scripts/install_electron_nix.sh
bash "${ROOT_PATH}"/appimage-scripts/install_electron.sh

# Setup node deps
bash "${ROOT_PATH}"/appimage-scripts/setup_node_deps.sh

# Build our css files
bash "${ROOT_PATH}"/appimage-scripts/build_css.sh

# Build/setup nim-based files
bash "${ROOT_PATH}"/appimage-scripts/build_with_nim.sh

cat <<'EOF' >"${APP_DIR}/bin/ct"
#!/usr/bin/env bash

HERE=${HERE:-$(dirname "$(readlink -f "${0}")")}

exec "${HERE}"/bin/ct_unwrapped "$@"

EOF

# Build/setup db-backend
bash "${ROOT_PATH}"/appimage-scripts/build_db_backend.sh

# Build/setup backend-manager
bash "${ROOT_PATH}"/appimage-scripts/build_backend_manager.sh

# Noir
cp -L "$(which nargo)" "${APP_DIR}/bin/nargo"
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
cp -L "$(which ctags)" "${APP_DIR}/bin/ctags"
chmod +x "${APP_DIR}/bin/ctags"
# We want splitting
# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/ctags" | grep -v glibc | grep /nix) "${APP_DIR}"/lib

# curl
cp -L "$(which curl)" "${APP_DIR}/bin/curl"
chmod +x "${APP_DIR}/bin/curl"
# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/curl" | grep -v glibc | grep /nix) "${APP_DIR}"/lib

# ct-remote
cp -L "$(which ct-remote)" "${APP_DIR}/bin/ct-remote"
chmod +x "${APP_DIR}/bin/ct-remote"
# shellcheck disable=SC2046
ct_remote_libs=$(lddtree -l "${APP_DIR}/bin/ct-remote" | grep -v glibc | grep /nix || true)
if [ -n "${ct_remote_libs}" ]; then
	# shellcheck disable=SC2086
	cp -n ${ct_remote_libs} "${APP_DIR}"/lib
fi
ls -al "${APP_DIR}"/lib

# node
cp -L "$(which node)" "${APP_DIR}/bin/node"
chmod +x "${APP_DIR}/bin/node"

# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/node" | grep -v glibc | grep /nix) "${APP_DIR}"/lib

# shellcheck disable=SC2046
cp -n $(lddtree -l "${APP_DIR}/bin/cargo-stylus" | grep -v glibc | grep /nix) "${APP_DIR}"/lib

chmod -R +x "${APP_DIR}/bin"
chmod -R +x "${APP_DIR}/electron"

chmod -R 777 "${APP_DIR}"

# cp "${ROOT_PATH}"/libs/codetracer-ruby-recorder/src/*.rb "${APP_DIR}/src/"

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

export CODETRACER_PREFIX=$HERE
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
for SIZE in 16 32 128 256 512; do
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

if [[ $CURRENT_ARCH == "aarch64" ]]; then
	INTERPRETER_PATH=/lib/ld-linux-aarch64.so.1
else
	INTERPRETER_PATH=/lib64/ld-linux-x86-64.so.2
fi

# =============================================================================
# Bundle glibc AND its dynamic loader.
#
# WHY.  Everything else in this AppDir is already self-contained: each binary's
# RPATH is rewritten to $ORIGIN/../lib below, and the bundled .so files load
# correctly on every distro.  glibc was the one exception -- it was deliberately
# excluded (`lddtree -l ... | grep -v glibc` above) and PT_INTERP was pointed at
# the HOST's /lib64/ld-linux-x86-64.so.2.  So the bundled libraries loaded and
# then asked the *host* libc for symbol versions it could not supply:
#
#   ct_unwrapped: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_ABI_GNU2_TLS'
#       not found (required by .../lib/libbpf.so.1)
#   ct_unwrapped: /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38'
#       not found (required by .../bin/ct_unwrapped)
#
# Note the second one: it is ct_unwrapped ITSELF, not just a bundled dependency.
# There is a single root cause -- we build against the pinned nixpkgs' glibc
# 2.42 -- with two symptoms.  `GLIBC_2.36`/`GLIBC_2.38` are ordinary version
# floors (new-ish functions we call).  `GLIBC_ABI_GNU2_TLS` is not a version at
# all but an ABI marker that glibc 2.42 stamps on objects using GNU2/TLSDESC
# thread-local storage; only glibc >= 2.42 provides it, which is why the
# AppImage ran on rolling-release Arch and on nothing else.
#
# Rebuilding against an older glibc (the conventional AppImage answer) would
# mean overriding the toolchain glibc that every CodeTracer repo shares through
# the codetracer-toolchains pin, and would cap the toolchain permanently.  We
# already have the right glibc sitting in the Nix closure, so ship it.
#
# WHY A WRAPPER AND NOT patchelf --set-interpreter.  PT_INTERP must be an
# ABSOLUTE path, and the kernel resolves it before any of our code runs, so
# neither $ORIGIN nor LD_LIBRARY_PATH can redirect it.  An AppImage extracts to
# an unpredictable directory (/tmp/appimage_extracted_<random> or
# ./squashfs-root), so there is no absolute path to bake in.  The only portable
# way to use a bundled loader is to invoke it explicitly, which is what the
# generated wrappers below do.
#
# The loader and libc MUST be the matched pair the binaries were linked
# against, so take both from the exact store path ct_unwrapped's PT_INTERP
# already points at.  This must run BEFORE the --set-interpreter loop rewrites
# that value away.
#
# WHY THE LOADER GOES IN bin/ AND NOT lib/.  When a program is started as
# `ld.so prog`, the kernel sets /proc/self/exe to the LOADER, not to prog --
# measured, and `--argv0` fixes argv[0] only.  Nim's getAppFilename() and
# getAppDir() read /proc/self/exe, and this tree calls them in a dozen places to
# locate sibling binaries (ct_gfx_player, ct-mcr), the share/ directory and the
# prefix.  Keeping the loader in bin/ makes getAppDir() still return
# <AppDir>/bin exactly as it does today, so every getAppDir()-based lookup keeps
# working untouched; only the four getAppFilename() callers that want the full
# path to the ct executable need help, and they get it from
# CODETRACER_APP_FILENAME which the wrappers below export.
# =============================================================================
GLIBC_LOADER_SRC=$(patchelf --print-interpreter "${APP_DIR}/bin/ct_unwrapped")
GLIBC_LIB_SRC=$(dirname "${GLIBC_LOADER_SRC}")
BUNDLED_LOADER=$(basename "${GLIBC_LOADER_SRC}")
echo "Bundling glibc from ${GLIBC_LIB_SRC} (loader: ${BUNDLED_LOADER})"

cp -L "${GLIBC_LOADER_SRC}" "${APP_DIR}/bin/${BUNDLED_LOADER}"
chmod +x "${APP_DIR}/bin/${BUNDLED_LOADER}"

# libpthread/libdl/librt/libutil are stubs since glibc 2.34 (everything moved
# into libc) but binaries built earlier still carry NEEDED entries for them, so
# copy whichever the closure actually has.
for glibc_lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 \
	libutil.so.1 libresolv.so.2 libanl.so.1 libnsl.so.1 \
	libBrokenLocale.so.1 libthread_db.so.1 libnss_files.so.2 \
	libnss_dns.so.2 libnss_compat.so.2; do
	if [ -e "${GLIBC_LIB_SRC}/${glibc_lib}" ]; then
		cp -L "${GLIBC_LIB_SRC}/${glibc_lib}" "${APP_DIR}/lib/"
	fi
done

# libgcc_s.so.1 comes from gcc rather than glibc, but glibc dlopen()s it for
# pthread_cancel and backtraces, and a dlopen has no RPATH to fall back on.
if [ ! -e "${APP_DIR}/lib/libgcc_s.so.1" ]; then
	libgcc_src=$(lddtree -l "${APP_DIR}/bin/ct_unwrapped" 2>/dev/null | grep '/libgcc_s\.so\.1$' | head -1 || true)
	if [ -n "${libgcc_src}" ]; then
		cp -L "${libgcc_src}" "${APP_DIR}/lib/"
	fi
fi

ls -al "${APP_DIR}"/lib

# Helper: skip patchelf on statically-linked binaries (e.g. Go binaries built with CGO_ENABLED=0)
try_patchelf() {
	local binary="$1"
	shift
	if file "$binary" | grep -q "statically linked"; then
		echo "Skipping patchelf for statically-linked binary: $binary"
		return 0
	fi
	patchelf "$@" "$binary"
}

# Patchelf the executable's interpreter
PATCHELF_BINARIES=(
	"${APP_DIR}"/bin/ct_unwrapped
	"${APP_DIR}"/bin/replay-server
	"${APP_DIR}"/bin/db-backend-record
	"${APP_DIR}"/bin/session-manager
	"${APP_DIR}"/bin/nargo
	"${APP_DIR}"/bin/wazero
	"${APP_DIR}"/bin/ctags
	"${APP_DIR}"/bin/curl
	"${APP_DIR}"/bin/cargo-stylus
	"${APP_DIR}"/bin/node
	"${APP_DIR}"/ruby/bin/ruby
	"${APP_DIR}"/bin/ct-remote
)
for binary in "${PATCHELF_BINARIES[@]}"; do
	try_patchelf "$binary" --set-interpreter "${INTERPRETER_PATH}"
done

# Clear up the executable's rpath.  Bundled .so files that have their
# own NEEDED libs (libbpf needs libelf, etc.) get the same treatment so
# the loader falls back to ct_unwrapped's $ORIGIN/../lib instead of
# searching the Nix-store paths baked in at build time.
REMOVE_RPATH_TARGETS=(
	"${PATCHELF_BINARIES[@]}"
	"${APP_DIR}"/lib/libicui18n.so.76
	"${APP_DIR}"/lib/libgssapi_krb5.so.2
	"${APP_DIR}"/lib/libbpf.so.1
	"${APP_DIR}"/lib/libelf.so.1
)
for binary in "${REMOVE_RPATH_TARGETS[@]}"; do
	try_patchelf "$binary" --remove-rpath
done

# Set rpath for binaries and libraries
# Note: $ORIGIN is an ELF rpath token, not a shell variable - it should NOT be expanded
RPATH_BINARIES=(
	"${PATCHELF_BINARIES[@]}"
	"${APP_DIR}"/lib/libicui18n.so.76
	"${APP_DIR}"/lib/libgssapi_krb5.so.2
	"${APP_DIR}"/lib/libbpf.so.1
	"${APP_DIR}"/lib/libelf.so.1
)
for binary in "${RPATH_BINARIES[@]}"; do
	# shellcheck disable=SC2016
	try_patchelf "$binary" --set-rpath '$ORIGIN/../lib'
done

# Route every bundled executable through the bundled loader.
#
# Renames `foo` to `foo.real` and puts a wrapper at `foo` that execs
#
#   $APPDIR/lib/ld-linux-x86-64.so.2 --library-path $APPDIR/lib $APPDIR/bin/foo.real
#
# `--library-path` is a loader ARGUMENT, not the LD_LIBRARY_PATH environment
# variable, so it applies to this process only and is not inherited by children.
# That matters: Electron is intentionally NOT wrapped (it ships prebuilt against
# an old glibc and works on the host loader today), and leaking our glibc 2.42
# into it via the environment is exactly the kind of accidental coupling that
# would turn a packaging fix into a GUI regression.
#
# The wrapper must be generated AFTER every patchelf call above -- patchelf on a
# shell script is an error. PT_INTERP is still set to the host path so a binary
# run directly (bypassing the wrapper) degrades to the old behaviour instead of
# failing to exec at all.
wrap_with_bundled_loader() {
	local binary="$1"
	local dir base rel_lib rel_bin
	dir=$(dirname "${binary}")
	base=$(basename "${binary}")

	# Statically-linked binaries (e.g. Go with CGO_ENABLED=0) have no PT_INTERP
	# and must not be run through a loader.
	if ! patchelf --print-interpreter "${binary}" >/dev/null 2>&1; then
		echo "Skipping loader wrapper for non-dynamic binary: ${binary}"
		return 0
	fi

	# Works for bin/* and ruby/bin/ruby alike.
	rel_lib=$(realpath --relative-to="${dir}" "${APP_DIR}/lib")
	rel_bin=$(realpath --relative-to="${dir}" "${APP_DIR}/bin")

	mv "${binary}" "${dir}/${base}.real"
	cat >"${binary}" <<EOF
#!/usr/bin/env bash
# GENERATED by appimage-scripts/build_appimage.sh -- do not edit.
# Runs ${base}.real against the glibc bundled in the AppImage rather than the
# host's, which is the only way the AppImage can be portable across distros
# whose glibc is older than the one we build against.
# Deliberately NOT named HERE/LIB/BIN. AppRun does \`export HERE=<AppDir>\` and
# bin/ruby reads it as \${HERE}/ruby/bin/ruby; assigning to an already-exported
# name updates the EXPORTED value, so reusing HERE here would hand every child
# process <AppDir>/bin and break the Ruby recorder. These names are private and
# were never exported.
_ctw_here=\$(dirname "\$(readlink -f "\${0}")")
_ctw_lib=\${_ctw_here}/${rel_lib}
_ctw_bin=\${_ctw_here}/${rel_bin}
# Starting via the loader makes /proc/self/exe name the loader, so hand the
# process the path it should report for itself. See src/common/paths.nim.
# Set unconditionally, never inherited: a wrapped child (db-backend-record,
# session-manager) must report ITSELF, not whichever ct spawned it.
export CODETRACER_APP_FILENAME="\${_ctw_here}/${base}"
# --argv0 keeps usage/error text saying "${base}" rather than "${base}.real"
# (confutils and friends read argv[0]); it does NOT affect /proc/self/exe.
exec "\${_ctw_bin}/${BUNDLED_LOADER}" --argv0 "\${_ctw_here}/${base}" --library-path "\${_ctw_lib}" "\${_ctw_here}/${base}.real" "\$@"
EOF
	chmod +x "${binary}"
	echo "Wrapped ${binary} -> ${base}.real via ${BUNDLED_LOADER}"
}

for binary in "${PATCHELF_BINARIES[@]}"; do
	wrap_with_bundled_loader "$binary"
done

# Measure the staged tree before it is sealed. This is the only moment the
# artefact's contents are readable without unpacking a squashfs: `cleanup` on
# EXIT deletes ${APP_DIR}. The guard reports the RESOLVED Electron version and
# every package outside the production dependency closure, by name, and fails
# the build rather than publishing a signed artefact nobody has looked inside.
bash "${ROOT_PATH}"/ci/test/electron-supply-chain.sh "${APP_DIR}"

APPIMAGE_ARCH=$CURRENT_ARCH
if [[ $APPIMAGE_ARCH == "aarch64" ]]; then
	# The appimagetool has its own convention for specifying the ARM64 arch
	APPIMAGE_ARCH=arm_aarch64
fi

# Use AppImage tool to create AppImage itself
ARCH=$APPIMAGE_ARCH appimagetool "${APP_DIR}" CodeTracer.AppImage

try_patchelf "${ROOT_PATH}"/CodeTracer.AppImage --set-interpreter "${INTERPRETER_PATH}"
try_patchelf "${ROOT_PATH}"/CodeTracer.AppImage --remove-rpath

echo "============================"
echo "AppImage successfully built!"
echo "size: $(du -h "${ROOT_PATH}"/CodeTracer.AppImage | cut -f1) ($(stat -c %s "${ROOT_PATH}"/CodeTracer.AppImage 2>/dev/null || stat -f %z "${ROOT_PATH}"/CodeTracer.AppImage) bytes)"
echo "============================"
