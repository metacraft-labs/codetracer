#!/bin/sh
# CodeTracer installer for Linux and macOS.
#
#   curl -fsSL https://get.codetracer.com/sh | sh
#   curl -fsSL https://get.codetracer.com/sh | sh -s -- --version 26.09.1
#   curl -fsSL https://get.codetracer.com/sh | sh -s -- --uninstall
#
# The job of this script is to make the system's own package manager able to
# install and update CodeTracer, and then ask it to. After one run, updates
# come from `apt upgrade`, `dnf upgrade`, your AUR helper or `emerge`; this
# script is not run again. (metacraft-specs infrastructure/package-distribution.md §13)
#
#   Debian, Ubuntu and derivatives   the Metacraft Labs apt repository, deb.metacraft-labs.com
#   Fedora, RHEL and derivatives     the Metacraft Labs RPM repository, rpm.metacraft-labs.com
#   Arch and derivatives             the AUR package `codetracer`, through yay, paru or pamac
#   Gentoo                           the metacraft-overlay ebuild `codetracer-bin`
#   macOS (Apple silicon)            the release DMG, copied to /Applications
#   NixOS                            nothing is installed; the flake to use is printed
#   anything else on Linux x86_64    the release AppImage, as ~/.local/bin/ct (no updates)
#
# ## The repository is the organisation's, and shared
#
# deb.metacraft-labs.com and rpm.metacraft-labs.com carry every Metacraft Labs
# product, signed with one organisation key. So the source entry and the key
# this script writes are the SAME files every Metacraft installer writes:
#
#   /usr/share/keyrings/metacraft-labs-archive-keyring.asc
#   /etc/apt/sources.list.d/metacraft-labs.sources
#   /etc/yum.repos.d/metacraft-labs.repo
#
# Installing a second product finds them and reuses them. Each product records
# itself in /var/lib/metacraft-labs/repository-users/<package>, and --uninstall
# removes the shared entry only when no other product's record remains.
#
# ## Trust
#
# The repository key is fetched over HTTPS and must match the SHA-256 pinned
# below before it is trusted. apt and dnf then verify every later transaction
# against it themselves. The key is 22F8 0A4A 65B0 8E36 AEA8 9F57 E127 BF3A C4CE 1719;
# changing the digest below is a key rotation.
#
# The AppImage and DMG downloads are checked against the release's SHA256SUMS,
# and SHA256SUMS against its signature by the CodeTracer release key
# 0389 4920 AC59 5EDF 9B79 5B0D A941 7A0B 6297 F790. Without gpg the signature
# cannot be checked, and the script refuses unless
# CODETRACER_INSTALL_ALLOW_UNVERIFIED=1 is set.
#
# ## Privileges
#
# The script runs as you. Only the steps that change the system (writing the
# key and the source entry, and running the package manager) use sudo or doas,
# and each one says so first.
set -eu

PKG_NAME='codetracer'
REPO_DOMAIN="${CODETRACER_REPO_DOMAIN:-metacraft-labs.com}"
DEB_URL="${CODETRACER_DEB_URL:-https://deb.$REPO_DOMAIN}"
RPM_URL="${CODETRACER_RPM_URL:-https://rpm.$REPO_DOMAIN}"
KEYS_URL="${CODETRACER_KEYS_URL:-https://deb.$REPO_DOMAIN/keys}"
RELEASES_URL="${CODETRACER_RELEASES_URL:-https://github.com/metacraft-labs/codetracer/releases}"
RELEASES_API="${CODETRACER_RELEASES_API:-https://api.github.com/repos/metacraft-labs/codetracer/releases}"
RELEASE_KEY_URL="${CODETRACER_RELEASE_KEY_URL:-https://downloads.codetracer.com/CodeTracer.pub.asc}"

KEYRING_FILE='metacraft-labs-archive-keyring.asc'
KEYRING_DEST='/usr/share/keyrings/metacraft-labs-archive-keyring.asc'
KEYRING_SHA256='aa89db2215ce0b33e029b8302d4d94fac742b92d279f178437abe10d9b54c988'
APT_SOURCES_DEST='/etc/apt/sources.list.d/metacraft-labs.sources'
RPM_REPO_DEST='/etc/yum.repos.d/metacraft-labs.repo'
REPO_USERS_DIR='/var/lib/metacraft-labs/repository-users'
RELEASE_KEY_FPR='03894920AC595EDF9B795B0DA9417A0B6297F790'

# Entries earlier CodeTracer installers wrote for deb./rpm.codetracer.com.
# Those hosts now redirect to the organisation's repositories, which are signed
# with a different key, so the old entries only produce signature errors.
LEGACY_FILES='/etc/apt/sources.list.d/metacraft-debs.list /etc/apt/trusted.gpg.d/metacraft-debs.asc /etc/yum.repos.d/metacraft-rpms.repo'

method='auto'
want_version="${VERSION:-}"
do_uninstall=0
dry_run=0

log()  { printf '[CodeTracer installer] %s\n' "$*" >&2; }
warn() { printf '[CodeTracer installer] WARNING: %s\n' "$*" >&2; }
die()  { printf '[CodeTracer installer] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: curl -fsSL https://get.codetracer.com/sh | sh -s -- [OPTIONS]

  --method auto|apt|dnf|aur|portage|dmg|appimage
                     How to install. "auto" (the default) picks the package
                     manager of this system.
  --version X.Y.Z    Install this version instead of the newest (also VERSION=).
  --uninstall        Remove CodeTracer; remove the Metacraft Labs repository
                     entry too, unless another Metacraft product still uses it.
  --dry-run          Print what would be run; change nothing.
  -h, --help         This text.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --method)  [ $# -ge 2 ] || die '--method needs an argument'; method="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || die '--version needs an argument'; want_version="$2"; shift 2 ;;
    --uninstall|--remove) do_uninstall=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --yes|-y) shift ;;  # accepted for habit's sake; this script never prompts
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done
want_version="${want_version#v}"

# ── privileges ────────────────────────────────────────────────────────────────
SUPER=''
as_root() {
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN would run as root: $*"
    return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  if [ -z "$SUPER" ]; then
    if command -v sudo >/dev/null 2>&1; then SUPER='sudo'
    elif command -v doas >/dev/null 2>&1; then SUPER='doas'
    else die 'this step needs root, and neither sudo nor doas is available. Re-run as root.'
    fi
  fi
  "$SUPER" "$@"
}

run() {
  if [ "$dry_run" -eq 1 ]; then log "DRY-RUN would run: $*"; return 0; fi
  "$@"
}

# ── detection ─────────────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
DISTRO_ID=''
DISTRO_LIKE=''
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  DISTRO_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  # shellcheck disable=SC1091
  DISTRO_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
fi
[ ! -e /etc/NIXOS ] || DISTRO_ID='nixos'

detect_method() {
  case "$OS" in
    Darwin)
      [ "$ARCH" = arm64 ] || die "CodeTracer publishes macOS builds for Apple silicon only (this Mac is $ARCH)."
      echo dmg; return ;;
    Linux) ;;
    *) die "unsupported system: $OS $ARCH. On Windows, use: irm https://get.codetracer.com/pwsh | iex" ;;
  esac
  case "$ARCH" in
    x86_64|amd64) ;;
    *) die "CodeTracer publishes Linux builds for x86_64 only; this machine is $ARCH (ID=$DISTRO_ID)." ;;
  esac
  case " $DISTRO_ID $DISTRO_LIKE " in
    *' nixos '*) echo nix; return ;;
    # Gentoo before Debian: some Gentoo systems carry an unrelated `apt` command.
    *' gentoo '*) echo portage; return ;;
    *' debian '*|*' ubuntu '*) echo apt; return ;;
    *' fedora '*|*' rhel '*|*' centos '*) echo dnf; return ;;
    *' arch '*|*' archlinux '*) echo aur; return ;;
  esac
  if command -v emerge >/dev/null 2>&1; then echo portage
  elif command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1 || command -v dnf5 >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then echo dnf
  elif command -v pacman >/dev/null 2>&1; then echo aur
  else
    log "no package manager with a CodeTracer repository was found (ID=${DISTRO_ID:-unknown} ID_LIKE=${DISTRO_LIKE:--})"
    echo appimage
  fi
}

# ── downloads ─────────────────────────────────────────────────────────────────
fetch() { # fetch <url> <dest>
  log "fetch $1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1" || die "download failed: $1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only -O "$2" "$1" || die "download failed: $1"
  else
    die 'neither curl nor wget is available'
  fi
  [ -s "$2" ] || die "downloaded an empty file from $1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die 'no sha256sum or shasum available to check a download'
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ── the shared repository entry ───────────────────────────────────────────────
install_repository_key() {
  fetch "$KEYS_URL/$KEYRING_FILE" "$TMP/$KEYRING_FILE"
  got="$(sha256_of "$TMP/$KEYRING_FILE")"
  [ "$got" = "$KEYRING_SHA256" ] || die "the repository key does not match the one this installer pins.
  expected sha256 $KEYRING_SHA256
  got             $got
Refusing to trust it. This is what a substituted key looks like."
  log "repository key verified (sha256 $got)"
  log "installing the key at $KEYRING_DEST (needs root)"
  as_root mkdir -p "$(dirname "$KEYRING_DEST")"
  as_root install -m 0644 "$TMP/$KEYRING_FILE" "$KEYRING_DEST"
}

remove_legacy_entries() {
  for f in $LEGACY_FILES; do
    if [ -e "$f" ]; then
      log "removing $f, left by an earlier CodeTracer installer (needs root)"
      as_root rm -f "$f"
    fi
  done
}

claim_shared_entry() {
  as_root mkdir -p "$REPO_USERS_DIR"
  as_root touch "$REPO_USERS_DIR/$PKG_NAME"
}

other_shared_users() {
  [ -d "$REPO_USERS_DIR" ] || return 0
  for u in "$REPO_USERS_DIR"/*; do
    [ -e "$u" ] || continue
    [ "$(basename "$u")" = "$PKG_NAME" ] || basename "$u"
  done
}

write_root_file() { # write_root_file <dest>  (content on stdin)
  cat > "$TMP/root-file"
  if [ "$dry_run" -eq 1 ]; then log "DRY-RUN would write $1:"; sed 's/^/    /' "$TMP/root-file" >&2; return 0; fi
  as_root mkdir -p "$(dirname "$1")"
  as_root install -m 0644 "$TMP/root-file" "$1"
}

# ── apt ───────────────────────────────────────────────────────────────────────
install_apt() {
  command -v apt-get >/dev/null 2>&1 || die 'apt-get not found'
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  install_repository_key
  remove_legacy_entries
  log "registering $DEB_URL as $APT_SOURCES_DEST (needs root)"
  # The same deb822 entry every Metacraft installer writes. Signed-By scopes
  # the key to this repository instead of trusting it system-wide.
  write_root_file "$APT_SOURCES_DEST" <<SOURCES
Types: deb
URIs: $DEB_URL
Suites: stable
Components: main
Architectures: $arch
Signed-By: $KEYRING_DEST
SOURCES
  claim_shared_entry
  target="$PKG_NAME"
  [ -z "$want_version" ] || target="$PKG_NAME=$want_version-1"
  log "installing $target with apt (needs root)"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update || die 'apt-get update failed; see its output above'
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$target" || die "apt-get install $target failed; see its output above"
}

remove_apt() {
  status="$(dpkg-query -W -f='${Status}' "$PKG_NAME" 2>/dev/null || true)"
  if [ "$status" = 'install ok installed' ]; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$PKG_NAME"
  else
    log "$PKG_NAME is not installed with apt"
  fi
  [ -n "$(other_shared_users)" ] || as_root rm -f "$APT_SOURCES_DEST"
}

# ── dnf ───────────────────────────────────────────────────────────────────────
dnf_bin() {
  for d in dnf5 dnf yum; do
    if command -v "$d" >/dev/null 2>&1; then echo "$d"; return; fi
  done
  die 'no dnf, dnf5 or yum found'
}

install_dnf() {
  d="$(dnf_bin)"
  install_repository_key
  remove_legacy_entries
  log "registering $RPM_URL as $RPM_REPO_DEST (needs root)"
  # gpgcheck covers the packages, repo_gpgcheck the repository metadata.
  write_root_file "$RPM_REPO_DEST" <<REPO
[metacraft-labs]
name=Metacraft Labs
baseurl=$RPM_URL
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$KEYRING_DEST
REPO
  claim_shared_entry
  as_root rpm --import "$KEYRING_DEST" || die "rpm --import $KEYRING_DEST failed"
  target="$PKG_NAME"
  [ -z "$want_version" ] || target="$PKG_NAME-$want_version"
  log "installing $target with $d (needs root)"
  as_root "$d" -y makecache || die "$d makecache failed; see its output above"
  as_root "$d" -y install "$target" || die "$d install $target failed; see its output above"
}

remove_dnf() {
  d="$(dnf_bin)"
  if rpm -q "$PKG_NAME" >/dev/null 2>&1; then as_root "$d" -y remove "$PKG_NAME"
  else log "$PKG_NAME is not installed with $d"
  fi
  [ -z "$(other_shared_users)" ] || return 0
  as_root rm -f "$RPM_REPO_DEST"
  for k in $(rpm -qa 'gpg-pubkey*' 2>/dev/null || true); do
    info="$(rpm -qi "$k" 2>/dev/null || true)"
    if printf '%s\n' "$info" | grep -i 'metacraft labs package repositories' >/dev/null; then
      as_root rpm -e --allmatches "$k" || warn "could not remove the imported key $k"
    fi
  done
}

# ── Arch (AUR) ────────────────────────────────────────────────────────────────
aur_helper() {
  for h in yay paru pamac; do
    if command -v "$h" >/dev/null 2>&1; then echo "$h"; return; fi
  done
}

install_aur() {
  h="$(aur_helper)"
  if [ -z "$h" ]; then
    warn 'no AUR helper (yay, paru or pamac) was found, so CodeTracer cannot be installed from the AUR.
  Install one to get CodeTracer updates with the rest of your system. Installing the AppImage instead.'
    install_appimage
    return
  fi
  [ -z "$want_version" ] || warn "the AUR carries only the newest CodeTracer; --version $want_version is ignored"
  log "installing $PKG_NAME from the AUR with $h"
  case "$h" in
    pamac) run pamac build --no-confirm "$PKG_NAME" ;;
    *)     run "$h" -S --noconfirm "$PKG_NAME" ;;
  esac || die "$h could not install $PKG_NAME; see its output above"
}

remove_aur() {
  if pacman -Q "$PKG_NAME" >/dev/null 2>&1; then as_root pacman -Rns --noconfirm "$PKG_NAME"
  else log "$PKG_NAME is not installed with pacman"
  fi
}

# ── Gentoo ────────────────────────────────────────────────────────────────────
install_portage() {
  command -v emerge >/dev/null 2>&1 || die 'emerge not found'
  if ! command -v eselect >/dev/null 2>&1 || ! eselect repository list >/dev/null 2>&1; then
    log 'installing eselect-repository (needs root)'
    as_root emerge --noreplace app-eselect/eselect-repository || die 'could not install eselect-repository'
  fi
  enabled="$(eselect repository list -i 2>/dev/null || true)"
  case "$enabled" in *metacraft-overlay*) ;; *)
    log 'enabling the metacraft-overlay repository (needs root)'
    as_root eselect repository enable metacraft-overlay 2>/dev/null \
      || as_root eselect repository add metacraft-overlay git https://github.com/metacraft-labs/metacraft-overlay.git \
      || die 'could not add metacraft-overlay' ;;
  esac
  as_root emerge --sync metacraft-overlay || die 'could not sync metacraft-overlay'
  target='dev-debug/codetracer-bin'
  [ -z "$want_version" ] || target="=dev-debug/codetracer-bin-$want_version"
  log "installing $target with emerge (needs root)"
  as_root emerge "$target" || die "emerge $target failed; see its output above"
}

remove_portage() { as_root emerge --depclean dev-debug/codetracer-bin; }

# ── release downloads (DMG, AppImage) ─────────────────────────────────────────
resolve_version() {
  [ -z "$want_version" ] || { echo "$want_version"; return; }
  fetch "$RELEASES_API/latest" "$TMP/latest.json"
  v="$(sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' "$TMP/latest.json" | head -n 1)"
  [ -n "$v" ] || die 'could not determine the latest CodeTracer release'
  echo "$v"
}

# Download a release asset and verify it: its digest against SHA256SUMS, and
# SHA256SUMS against the CodeTracer release key's signature.
download_verified() { # download_verified <version> <asset>
  base="$RELEASES_URL/download/$1"
  fetch "$base/$2" "$TMP/$2"
  fetch "$base/SHA256SUMS" "$TMP/SHA256SUMS"
  want="$(awk -v f="$2" '$2 == f || $2 == "*" f { print $1 }' "$TMP/SHA256SUMS")"
  [ -n "$want" ] || die "$2 is not listed in the release's SHA256SUMS"
  got="$(sha256_of "$TMP/$2")"
  [ "$got" = "$want" ] || { rm -f "$TMP/$2"; die "$2 does not match SHA256SUMS (expected $want, got $got). Refusing to install it."; }
  log "$2 matches SHA256SUMS"
  if ! command -v gpg >/dev/null 2>&1; then
    if [ "${CODETRACER_INSTALL_ALLOW_UNVERIFIED:-0}" = 1 ]; then
      warn "gpg is not installed, so the signature on SHA256SUMS was NOT checked. Proceeding because CODETRACER_INSTALL_ALLOW_UNVERIFIED=1."
      return 0
    fi
    die 'gpg is not installed, so the signature on SHA256SUMS cannot be checked.
  Install gnupg and retry, or set CODETRACER_INSTALL_ALLOW_UNVERIFIED=1 if you accept the risk.'
  fi
  fetch "$base/SHA256SUMS.asc" "$TMP/SHA256SUMS.asc"
  fetch "$RELEASE_KEY_URL" "$TMP/release-key.asc"
  mkdir -m 700 "$TMP/gnupg"
  GNUPGHOME="$TMP/gnupg" gpg --batch --quiet --import "$TMP/release-key.asc" 2>/dev/null \
    || die 'could not import the CodeTracer release key'
  signer="$(GNUPGHOME="$TMP/gnupg" gpg --batch --status-fd 1 --verify "$TMP/SHA256SUMS.asc" "$TMP/SHA256SUMS" 2>/dev/null \
    | awk '$2 == "VALIDSIG" { print $12 }')"
  [ "$signer" = "$RELEASE_KEY_FPR" ] || { rm -f "$TMP/$2"; die "SHA256SUMS is not signed by the CodeTracer release key $RELEASE_KEY_FPR. Refusing to install."; }
  log 'SHA256SUMS signature verified'
}

install_dmg() {
  v="$(resolve_version)"
  asset="CodeTracer-$v-arm64.dmg"
  download_verified "$v" "$asset"
  [ "$dry_run" -eq 0 ] || { log "DRY-RUN would copy CodeTracer.app from $asset to /Applications"; return 0; }
  mnt="$TMP/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$TMP/$asset" >/dev/null || die "could not mount $asset"
  app="$mnt/CodeTracer.app"
  [ -d "$app" ] || { hdiutil detach "$mnt" >/dev/null; die "$asset has no CodeTracer.app"; }
  rm -rf /Applications/CodeTracer.app
  ditto "$app" /Applications/CodeTracer.app
  hdiutil detach "$mnt" >/dev/null || true
  xattr -cr /Applications/CodeTracer.app
  ct='/Applications/CodeTracer.app/Contents/MacOS/bin/ct'
  if [ -x "$ct" ]; then
    "$ct" install || warn "ct install failed; retry it with: $ct install"
  fi
  log 'NOTE: this install does not update itself. Re-run this installer to upgrade.'
}

install_appimage() {
  v="$(resolve_version)"
  asset="CodeTracer-$v-amd64.AppImage"
  download_verified "$v" "$asset"
  [ "$dry_run" -eq 0 ] || { log "DRY-RUN would install $asset as $HOME/.local/bin/ct"; return 0; }
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$TMP/$asset" "$HOME/.local/bin/ct"
  # `ct install` adds the desktop entry and icons and puts ~/.local/bin on PATH.
  "$HOME/.local/bin/ct" install || warn "ct install failed; retry it with: $HOME/.local/bin/ct install"
  log 'NOTE: this install does not update itself. Re-run this installer to upgrade.'
}

print_nix() {
  cat >&2 <<'NIX'
[CodeTracer installer] This is NixOS. The installer does not change a NixOS system imperatively.
Add CodeTracer from its flake instead, for example in your configuration:

    inputs.codetracer.url = "github:metacraft-labs/codetracer";
    environment.systemPackages = [ inputs.codetracer.packages.x86_64-linux.default ];

or, for your user profile only:

    nix profile install github:metacraft-labs/codetracer
NIX
}

# ── uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  case "$method" in
    apt) remove_apt ;;
    dnf) remove_dnf ;;
    aur) remove_aur ;;
    portage) remove_portage ;;
    dmg) run rm -rf /Applications/CodeTracer.app ;;
    appimage) run rm -f "$HOME/.local/bin/ct" ;;
    nix) print_nix; return ;;
    *) die "cannot uninstall with --method $method" ;;
  esac
  case "$method" in
    apt|dnf)
      as_root rm -f "$REPO_USERS_DIR/$PKG_NAME"
      others="$(other_shared_users | tr '\n' ' ')"
      if [ -n "$others" ]; then
        log "keeping the Metacraft Labs repository entry and key: still used by ${others% }"
      else
        as_root rm -f "$KEYRING_DEST"
        as_root rmdir "$REPO_USERS_DIR" 2>/dev/null || true
      fi ;;
  esac
  log 'CodeTracer was uninstalled.'
}

# ── main ──────────────────────────────────────────────────────────────────────
[ "$method" != auto ] || method="$(detect_method)"
log "system: $OS $ARCH, ID=${DISTRO_ID:--} ID_LIKE=${DISTRO_LIKE:--}; method: $method${want_version:+; version $want_version}"

if [ "$do_uninstall" -eq 1 ]; then
  uninstall
  exit 0
fi

case "$method" in
  apt) install_apt ;;
  dnf) install_dnf ;;
  aur) install_aur ;;
  portage) install_portage ;;
  dmg) install_dmg ;;
  appimage) install_appimage ;;
  nix) print_nix; exit 0 ;;
  *) die "unsupported --method $method" ;;
esac

case "$method" in
  apt|dnf|aur|portage)
    log "CodeTracer is installed. Updates come from your package manager from now on, not from this script." ;;
esac
if [ "$dry_run" -eq 0 ] && command -v ct >/dev/null 2>&1; then
  log "$(ct --version 2>/dev/null | head -n 1 || true)"
fi
log "Start CodeTracer from your applications menu, or run 'ct' in a terminal."
