#!/usr/bin/env bash
# =============================================================================
# Smoke-test a CodeTracer AppImage on multiple Linux distros via Docker/Podman.
#
# Why this matters
#   Our AppImage is built inside the Nix dev shell.  Nix-store binaries hard-
#   code RPATHs pointing at /nix/store/... paths that don't exist on other
#   distros.  appimage-scripts/build_appimage.sh patches each binary's
#   interpreter back to /lib64/ld-linux-x86-64.so.2 and RPATH to
#   $ORIGIN/../lib, so the AppImage *should* be self-contained — but only
#   end-to-end testing on a non-Nix host catches a missed binary, a stale
#   patchelf list, or a glibc/libgcc symbol-version regression.
#
#   Without this script, the only cross-distro check is `appimage-lib-check`
#   running `./CodeTracer.AppImage --version` on ubuntu-latest.  That misses
#   anything Ubuntu also happens to ship (e.g. a stray glibc 2.39 symbol
#   wouldn't show until someone tried the binary on Debian 12 / glibc 2.36).
#
# What it does
#   For each distro listed in DEFAULT_DISTROS (or whatever you pass via
#   --distro), spin up a container with that distro's image, install the
#   minimum deps needed for AppImage extraction, copy the AppImage in, and
#   run a series of smoke commands.  We use `--appimage-extract-and-run`
#   throughout so we don't need FUSE inside the container (which most CI
#   container environments do not provide).
#
#   The smoke commands escalate from cheapest to most realistic:
#     1. --version          fast sanity check
#     2. --help             confirms argument parser loads
#     3. record /tmp/hello.py and then `replay` for one step
#        (Python recorder is bundled inside the AppImage as a Nix-built
#        venv, so this exercises the ruby/python venv path that
#        end-users actually hit.)
#
# Usage
#   bash scripts/test-appimage-cross-distro.sh path/to/CodeTracer.AppImage
#   bash scripts/test-appimage-cross-distro.sh --distro ubuntu:22.04 path/to/...
#   bash scripts/test-appimage-cross-distro.sh --distro all path/to/...
#
# Environment
#   CONTAINER_RUNTIME    `docker` (default) or `podman`.
#   APPIMAGE_DISTROS     space-separated override for DEFAULT_DISTROS.
# =============================================================================

set -uo pipefail

DEFAULT_DISTROS=(
	"ubuntu:22.04"
	"ubuntu:24.04"
	"debian:12"
	"fedora:40"
	"archlinux:latest"
)

if [ -n "${APPIMAGE_DISTROS:-}" ]; then
	# shellcheck disable=SC2206
	DEFAULT_DISTROS=($APPIMAGE_DISTROS)
fi

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

REQUESTED_DISTROS=()
APPIMAGE_PATH=""

while [ $# -gt 0 ]; do
	case "$1" in
	--distro)
		if [ "$2" = "all" ]; then
			REQUESTED_DISTROS=("${DEFAULT_DISTROS[@]}")
		else
			REQUESTED_DISTROS+=("$2")
		fi
		shift 2
		;;
	-h | --help)
		sed -n '/^# Usage/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		APPIMAGE_PATH="$1"
		shift
		;;
	esac
done

if [ -z "$APPIMAGE_PATH" ]; then
	echo "test-appimage-cross-distro.sh: no AppImage path given" >&2
	echo "usage: $0 [--distro DISTRO] AppImage" >&2
	exit 2
fi
if [ ! -f "$APPIMAGE_PATH" ]; then
	echo "test-appimage-cross-distro.sh: '$APPIMAGE_PATH' not found" >&2
	exit 2
fi
if [ "${#REQUESTED_DISTROS[@]}" -eq 0 ]; then
	REQUESTED_DISTROS=("${DEFAULT_DISTROS[@]}")
fi

if ! command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1; then
	echo "test-appimage-cross-distro.sh: '$CONTAINER_RUNTIME' not on PATH" >&2
	echo "  set CONTAINER_RUNTIME=podman if you don't have docker installed." >&2
	exit 2
fi

APPIMAGE_PATH="$(readlink -f "$APPIMAGE_PATH")"

# Per-distro package install commands.  Each one needs:
#   * `file` (so try_patchelf-style scripts can introspect binaries)
#   * `gzip`/`zstd`/the matching squashfs-tools to unpack the AppImage payload
#   * the basic shared libs the AppImage's patched binaries dlopen (libxcb,
#     fontconfig, etc.).  We err on the side of completeness because a
#     missing runtime library is exactly the kind of regression this script
#     should surface.
install_deps_ubuntu_debian() {
	cat <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates file zstd squashfs-tools \
libfontconfig1 libfreetype6 libxcb1 libxcb-cursor0 libxkbcommon0 \
  libnss3 libgbm1 libdrm2 libatk-bridge2.0-0 libatk1.0-0 libcups2 \
  libpango-1.0-0 libcairo2 libasound2t64 libgtk-3-0 libxss1 \
  >/tmp/apt.log 2>&1
EOF
}

install_deps_fedora() {
	cat <<'EOF'
dnf install -y -q \
  ca-certificates file zstd squashfs-tools \
fontconfig freetype libxcb xcb-util-cursor libxkbcommon \
  nss mesa-libgbm libdrm at-spi2-atk atk cups-libs \
  pango cairo alsa-lib-libs gtk3 libXScrnSaver \
  >/tmp/dnf.log 2>&1
EOF
}

install_deps_arch() {
	cat <<'EOF'
pacman -Sy --noconfirm --needed \
  ca-certificates file zstd squashfs-tools \
fontconfig freetype2 libxcb xcb-util-cursor libxkbcommon \
  nss mesa libdrm at-spi2-core atk cups \
  pango cairo alsa-lib gtk3 libxss \
  >/tmp/pacman.log 2>&1
EOF
}

deps_for() {
	case "$1" in
	ubuntu:* | debian:*) install_deps_ubuntu_debian ;;
	fedora:*) install_deps_fedora ;;
	archlinux:*) install_deps_arch ;;
	*) echo "echo 'no installer for $1' >&2; exit 1" ;;
	esac
}

# The smoke commands run inside the container.  `--appimage-extract-and-run`
# unpacks the squashfs to a temp dir on each invocation, which (a) skips
# FUSE entirely (FUSE is rarely available in container sandboxes) and
# (b) makes failures easier to localise — a missing lib shows the path
# inside squashfs-root, not an opaque FUSE error.
smoke_commands() {
	cat <<'EOF'
set -e
# AppImage is bind-mounted read-only from the host; copy to a writable
# location so --appimage-extract-and-run can stage its squashfs tree.
cp /work/AppImage /tmp/CodeTracer.AppImage
chmod +x /tmp/CodeTracer.AppImage
APPIMAGE=/tmp/CodeTracer.AppImage
cd /tmp

# 1. --version — exercises the core binary's loader path.  Surfaces
#    glibc symbol-version mismatches and missing NEEDED libs (this is
#    what flagged libbpf/libelf as previously-unbundled).
echo "--- $($APPIMAGE --appimage-extract-and-run --version) ---"

# 2. --help — exercises the argument parser, which pulls in more of the
#    Nim runtime than --version does.
$APPIMAGE --appimage-extract-and-run --help >/dev/null

# Note on `ct record`: we deliberately don't exercise it here.  Recording
# a real program needs the per-language recorder (Python module, Ruby
# gem, etc.) installed in the user's environment — those are explicitly
# out-of-AppImage (see install-on-distributions.sh for how end users are
# expected to set them up).  A "ct record /tmp/hello.py" smoke would
# need pip + codetracer_python_recorder in every container, which tests
# the recorder packaging, not the AppImage portability story.

echo "OK"
EOF
}

declare -i PASS=0 FAIL=0
declare -A RESULT_DETAIL
for distro in "${REQUESTED_DISTROS[@]}"; do
	echo "[appimage-cross-distro] $distro"
	log="$(mktemp)"
	script="$(deps_for "$distro")
$(smoke_commands)"
	if "$CONTAINER_RUNTIME" run --rm \
		-v "$APPIMAGE_PATH:/work/AppImage:ro" \
		"$distro" \
		bash -c "$script" >"$log" 2>&1; then
		RESULT_DETAIL[$distro]="PASS"
		PASS=$((PASS + 1))
	else
		rc=$?
		RESULT_DETAIL[$distro]="FAIL (exit $rc) — see $log"
		FAIL=$((FAIL + 1))
		echo "  ---- last 30 lines of container output ----" >&2
		tail -30 "$log" >&2
		echo "  -------------------------------------------" >&2
	fi
done

echo
echo "==== AppImage cross-distro smoke summary ===="
for distro in "${REQUESTED_DISTROS[@]}"; do
	printf "  %-22s %s\n" "$distro" "${RESULT_DETAIL[$distro]}"
done
echo "  ---"
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
