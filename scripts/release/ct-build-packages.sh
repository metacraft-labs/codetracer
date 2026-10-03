#!/bin/sh
# Build CodeTracer's native Linux packages (.deb, .rpm) from the release AppImage.
#
#   ct-build-packages.sh --version 26.09.1 --appimage CodeTracer.AppImage \
#       --out <dir> [--ecosystem deb|rpm|all] [--arch x86_64] [--release 1]
#
# ## What the packages carry
#
# The AppImage is the Linux release payload. The packages are carriers for the
# same bytes: the AppImage's whole embedded tree (its AppDir) is installed
# intact under /usr/lib/codetracer, and /usr/bin/ct execs that tree's AppRun.
# Nothing is rebuilt, so a user who switches between the AppImage and a
# package runs the same program.
#
# The WHOLE tree, not a list of known subdirectories: AppRun and the programs
# under bin/ find everything else (lib/, electron/, config/, public/, ruby/,
# the bundled glibc loader) relative to their own location. A package that
# carried part of the tree would install cleanly and fail on first use.
# `ct-verify-packages.sh` proves each package installs the tree intact.
#
# Installing the extracted tree, rather than the AppImage file itself as
# /usr/bin/ct, also removes the FUSE dependency the AppImage has.
#
# ## What differs from the AppImage
#
#   * Modes. build_appimage.sh leaves the AppDir `chmod -R 777`. A system
#     package must not install world-writable files under /usr, so group and
#     other write bits are cleared. Contents and names are unchanged.
#   * Desktop integration. The tree's codetracer.desktop and hicolor icons are
#     also installed under /usr/share, where desktop environments look.
#
# ## Dependencies
#
# The tree bundles its own glibc, loader and libraries, so the only hard
# dependency is bash (AppRun and the bin/ wrappers are bash scripts). Electron
# loads the host's GTK, NSS, ALSA and X libraries for the desktop UI. Those are
# Recommends rather than Depends, so a headless install of the command-line
# tools can skip them (apt --no-install-recommends, dnf --setopt=install_weak_deps=False).
set -eu

HERE_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

version=''; appimage=''; out=''; ecosystem='all'; asset_arch='x86_64'
release_num="${CT_PACKAGE_RELEASE:-1}"
maintainer="${CT_PACKAGE_MAINTAINER:-Metacraft Labs <support@codetracer.com>}"
homepage='https://codetracer.com'
summary='User-friendly time-traveling debugger for many programming languages'

log() { printf 'ct-build-packages: %s\n' "$*" >&2; }
die() { printf 'ct-build-packages: ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   version="$2"; shift 2 ;;
    --appimage)  appimage="$2"; shift 2 ;;
    --out)       out="$2"; shift 2 ;;
    --ecosystem) ecosystem="$2"; shift 2 ;;
    --arch)      asset_arch="$2"; shift 2 ;;
    --release)   release_num="$2"; shift 2 ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$version" ]  || die '--version is required'
[ -n "$appimage" ] || die '--appimage is required'
[ -f "$appimage" ] || die "--appimage $appimage does not exist"
[ -n "$out" ]      || die '--out is required'
case "$version" in
  [0-9][0-9].[0-9][0-9].[0-9]*) ;;
  *) die "--version $version is not a CodeTracer YY.MM.N version" ;;
esac
mkdir -p "$out"
out="$(CDPATH='' cd -- "$out" && pwd)"

case "$asset_arch" in
  x86_64)  deb_arch='amd64'; rpm_arch='x86_64' ;;
  aarch64) deb_arch='arm64'; rpm_arch='aarch64' ;;
  *) die "unsupported --arch $asset_arch" ;;
esac

stage="$(mktemp -d)"
trap 'chmod -R u+w "$stage" 2>/dev/null; rm -rf "$stage"' EXIT INT TERM

log "extracting $appimage"
sh "$HERE_DIR/appimage-extract.sh" "$appimage" "$stage/appdir"
payload="$stage/appdir"
[ -x "$payload/bin/ct" ] || die 'the AppImage tree has no executable bin/ct; refusing to package it'
[ -f "$payload/codetracer.desktop" ] || die 'the AppImage tree has no codetracer.desktop'
nfiles="$(find "$payload" -type f | wc -l | tr -d ' ')"
log "payload: $nfiles files"

# The installed filesystem tree, shared by both ecosystems.
stage_tree() {
  _t="$1"
  mkdir -p "$_t/usr/bin" "$_t/usr/lib" "$_t/usr/share/applications"
  cp -a "$payload" "$_t/usr/lib/codetracer"
  chmod -R u+rwX,go+rX,go-w "$_t/usr/lib/codetracer"
  # A wrapper, not a symlink: AppRun resolves its own directory with
  # `readlink -f "$0"`, and exec keeps $0 pointing into the tree.
  printf '#!/bin/sh\nexec /usr/lib/codetracer/AppRun "$@"\n' > "$_t/usr/bin/ct"
  chmod 0755 "$_t/usr/bin/ct"
  install -m 0644 "$payload/codetracer.desktop" "$_t/usr/share/applications/codetracer.desktop"
  if [ -d "$payload/usr/share/icons/hicolor" ]; then
    mkdir -p "$_t/usr/share/icons"
    cp -R "$payload/usr/share/icons/hicolor" "$_t/usr/share/icons/hicolor"
    chmod -R u+rwX,go+rX,go-w "$_t/usr/share/icons/hicolor"
  fi
}

want() { [ "$ecosystem" = all ] || [ "$ecosystem" = "$1" ]; }

build_deb() {
  command -v dpkg-deb >/dev/null 2>&1 || die 'dpkg-deb not found'
  _root="$stage/deb"
  stage_tree "$_root"
  mkdir -p "$_root/DEBIAN"
  _kb="$(du -sk "$_root/usr" | awk '{print $1}')"
  cat > "$_root/DEBIAN/control" <<CONTROL
Package: codetracer
Version: $version-$release_num
Section: devel
Priority: optional
Architecture: $deb_arch
Maintainer: $maintainer
Installed-Size: $_kb
Depends: bash
Recommends: libgtk-3-0t64 | libgtk-3-0, libnss3, libasound2t64 | libasound2, libgbm1, libxss1, libxtst6, libnotify4, libsecret-1-0, libatspi2.0-0t64 | libatspi2.0-0, xdg-utils
Homepage: $homepage
Description: $summary
 CodeTracer records a program's execution and lets you move backward and
 forward through it in a debugger.
 .
 This package installs the CodeTracer-$version-amd64.AppImage release
 asset's tree under /usr/lib/codetracer.
CONTROL
  _deb="$out/codetracer_${version}-${release_num}_${deb_arch}.deb"
  dpkg-deb --build --root-owner-group -Zxz "$_root" "$_deb" >/dev/null \
    || die 'dpkg-deb --build failed'
  log "built $_deb"
}

build_rpm() {
  command -v rpmbuild >/dev/null 2>&1 || die 'rpmbuild not found'
  _top="$stage/rpmbuild"
  mkdir -p "$_top/SPECS" "$_top/SOURCES" "$_top/BUILD" "$_top/RPMS" "$_top/SRPMS"
  _tree="$stage/rpmtree"
  stage_tree "$_tree"
  ( cd "$_tree" && tar -cf "$_top/SOURCES/tree.tar" usr ) || die 'could not archive the rpm tree'
  # Literal paths, not %{_bindir}: an rpmbuild from Nix defines those as its
  # own store path. __os_install_post is disabled because the brp scripts
  # would strip and rewrite the prebuilt binaries; _build_id_links because
  # rpm fails on build-id collisions between unrelated prebuilt ELF files.
  cat > "$_top/SPECS/codetracer.spec" <<SPEC
%global __os_install_post %{nil}
%global debug_package %{nil}
%define _build_id_links none
%define _binary_payload w10T.zstdio

Name:           codetracer
Version:        $version
Release:        $release_num
Summary:        $summary
License:        AGPL-3.0-only
URL:            $homepage
Source0:        tree.tar
BuildArch:      $rpm_arch
AutoReqProv:    no
Requires:       bash
Recommends:     gtk3
Recommends:     nss
Recommends:     alsa-lib
Recommends:     mesa-libgbm
Recommends:     libXScrnSaver
Recommends:     libXtst
Recommends:     libnotify
Recommends:     libsecret
Recommends:     at-spi2-core
Recommends:     xdg-utils

%description
CodeTracer records a program's execution and lets you move backward and
forward through it in a debugger.

This package installs the CodeTracer-$version-amd64.AppImage release
asset's tree under /usr/lib/codetracer.

%prep

%build

%install
mkdir -p %{buildroot}
tar -xf %{SOURCE0} -C %{buildroot}

%files
/usr/bin/ct
/usr/lib/codetracer
/usr/share/applications/codetracer.desktop
/usr/share/icons/hicolor/*/apps/codetracer.png

%changelog
* $(LC_ALL=C date -u '+%a %b %d %Y') $maintainer - $version-$release_num
- Packaged from the CodeTracer $version release AppImage.
SPEC
  rpmbuild --define "_topdir $_top" -bb "$_top/SPECS/codetracer.spec" > "$stage/rpmbuild.log" 2>&1 || {
    tail -n 40 "$stage/rpmbuild.log" >&2
    die 'rpmbuild -bb failed'
  }
  _rpm="$_top/RPMS/$rpm_arch/codetracer-${version}-${release_num}.${rpm_arch}.rpm"
  [ -f "$_rpm" ] || die "rpmbuild did not produce $(basename "$_rpm") (got: $(ls "$_top/RPMS"/*/ 2>/dev/null))"
  cp "$_rpm" "$out/"
  log "built $out/$(basename "$_rpm")"
}

built=0
if want deb; then build_deb; built=$((built + 1)); fi
if want rpm; then build_rpm; built=$((built + 1)); fi
[ "$built" -gt 0 ] || die "--ecosystem $ecosystem selected nothing to build"
ls -la "$out" >&2
