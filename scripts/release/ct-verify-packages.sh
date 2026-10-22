#!/bin/sh
# Prove the native packages carry the release AppImage intact, and that the
# program they install runs.
#
#   ct-verify-packages.sh --version 26.09.1 --appimage CodeTracer.AppImage \
#       --deb codetracer_26.09.1-1_amd64.deb --rpm codetracer-26.09.1-1.x86_64.rpm
#
# Two halves, both fatal:
#
# 1. Identical tree. The AppImage's embedded tree and each package's
#    /usr/lib/codetracer are listed entry by entry: type, path, and the SHA-256
#    of every regular file (the target of every symlink). The lists must be
#    equal. A package that dropped a directory, or carried different bytes,
#    fails here, before anyone installs it.
#
# 2. The installed program works. Each package is installed by its own
#    package manager in a clean container -- the .deb with apt in
#    $CT_DEB_IMAGE (debian:12), the .rpm with dnf in $CT_RPM_IMAGE (fedora:40)
#    -- and `ct --version` and `ct --help` must succeed, with --version naming
#    this release. That is the image a package user actually runs, not a copy
#    of it on the build host.
#
# Needs: od, unsquashfs, dpkg-deb, rpm2cpio, cpio, sha256sum, GNU find, and
# docker or podman (CONTAINER_RUNTIME picks one explicitly).
set -eu

HERE_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
version=''
appimage=''
deb=''
rpm=''
deb_image="${CT_DEB_IMAGE:-debian:12}"
rpm_image="${CT_RPM_IMAGE:-fedora:40}"

log() { printf 'ct-verify-packages: %s\n' "$*" >&2; }
die() {
	printf 'ct-verify-packages: ERROR: %s\n' "$*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--version)
		version="$2"
		shift 2
		;;
	--appimage)
		appimage="$2"
		shift 2
		;;
	--deb)
		deb="$2"
		shift 2
		;;
	--rpm)
		rpm="$2"
		shift 2
		;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$version" ] && [ -f "$appimage" ] || die '--version and an existing --appimage are required'
[ -n "$deb$rpm" ] || die 'nothing to verify: pass --deb and/or --rpm'
for f in "$deb" "$rpm"; do [ -z "$f" ] || [ -f "$f" ] || die "$f does not exist"; done

abspath() { printf '%s/%s\n' "$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"; }
appimage="$(abspath "$appimage")"
[ -z "$deb" ] || deb="$(abspath "$deb")"
[ -z "$rpm" ] || rpm="$(abspath "$rpm")"

work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT INT TERM

# manifest <dir>: one line per entry, sorted: "<type> <path> <sha256|target>".
manifest() {
	(cd "$1" && {
		find . -mindepth 1 ! -type f -printf '%y %p %l\n'
		find . -type f -print0 | xargs -0 -r sha256sum | sed -E 's/^([0-9a-f]{64})  (.*)$/f \2 \1/'
	}) | LC_ALL=C sort
}

log "listing the AppImage tree"
sh "$HERE_DIR/appimage-extract.sh" "$appimage" "$work/appimage"
manifest "$work/appimage" >"$work/appimage.manifest"
n="$(wc -l <"$work/appimage.manifest" | tr -d ' ')"
[ "$n" -gt 0 ] || die 'the AppImage tree is empty'

check_tree() { # check_tree <label> <extracted-root>
	_r="$2"
	[ -d "$_r/usr/lib/codetracer" ] || die "$1 does not install /usr/lib/codetracer"
	[ -x "$_r/usr/bin/ct" ] || die "$1 does not install an executable /usr/bin/ct"
	grep -q '/usr/lib/codetracer/AppRun' "$_r/usr/bin/ct" || die "$1's /usr/bin/ct does not run /usr/lib/codetracer/AppRun"
	manifest "$_r/usr/lib/codetracer" >"$work/pkg.manifest"
	if ! diff -u "$work/appimage.manifest" "$work/pkg.manifest" >"$work/pkg.diff"; then
		head -40 "$work/pkg.diff" >&2
		die "$1 does not install the AppImage's tree intact under /usr/lib/codetracer"
	fi
	_ww="$(find "$_r/usr" -perm -o+w ! -type l | head -5)"
	[ -z "$_ww" ] || die "$1 installs world-writable files under /usr, e.g.: $_ww"
	log "ok  $1: $n entries, identical to the AppImage"
}

if [ -n "$deb" ]; then
	dpkg-deb -x "$deb" "$work/deb"
	check_tree "$(basename "$deb")" "$work/deb"
fi
if [ -n "$rpm" ]; then
	mkdir -p "$work/rpm"
	(cd "$work/rpm" && rpm2cpio "$rpm" | cpio -idm --quiet)
	check_tree "$(basename "$rpm")" "$work/rpm"
fi

# ── the installed program works ───────────────────────────────────────────────
runtime="${CONTAINER_RUNTIME:-}"
if [ -z "$runtime" ]; then
	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		runtime=docker
	elif command -v podman >/dev/null 2>&1; then
		runtime=podman
	else
		die 'neither a working docker nor podman is available for the install check'
	fi
fi
log "install check with $runtime"

# The package directory is mounted read-only; the check script runs as root
# in the container, exactly as a user's `sudo apt install` would.
in_container() { # in_container <image> <package> <install command>
	_dir="$(CDPATH='' cd -- "$(dirname -- "$2")" && pwd)"
	_pkg="$(basename -- "$2")"
	log "installing $_pkg in $1"
	"$runtime" run --rm -v "$_dir:/pkgs:ro" -e "PKG=/pkgs/$_pkg" -e "WANT=$version" "$1" sh -euc "
    $3
    command -v ct
    out=\$(ct --version 2>&1) || { echo \"\$out\"; echo 'ct --version failed'; exit 1; }
    echo \"\$out\"
    case \"\$out\" in *\"\$WANT\"*) ;; *) echo \"ct --version does not name \$WANT\"; exit 1 ;; esac
    ct --help > /dev/null 2>&1 || { ct --help; echo 'ct --help failed'; exit 1; }
    echo 'installed ct works'
  " || die "$_pkg did not install a working ct in $1"
}

# The install commands are expanded inside the container, where $PKG is set.
# shellcheck disable=SC2016
if [ -n "$deb" ]; then
	in_container "$deb_image" "$deb" \
		'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq --no-install-recommends "$PKG"'
fi
# shellcheck disable=SC2016
if [ -n "$rpm" ]; then
	in_container "$rpm_image" "$rpm" \
		'dnf install -y -q --setopt=install_weak_deps=False "$PKG"'
fi
log 'all packages verified'
