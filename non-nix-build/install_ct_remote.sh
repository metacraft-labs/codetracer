#!/usr/bin/env bash

set -euo pipefail

: "${DEPS_DIR:=$PWD/deps}"
: "${BIN_DIR:=$PWD/bin}"

mkdir -p "$DEPS_DIR"
mkdir -p "$BIN_DIR"

CT_REMOTE_VERSION=${CT_REMOTE_VERSION:-102d2c8}
DEST_BINARY="$BIN_DIR/ct-remote"
VERSION_FILE="$DEPS_DIR/ct-remote.version"

if [[ -x $DEST_BINARY ]] && [[ -f $VERSION_FILE ]] && grep -qx "$CT_REMOTE_VERSION" "$VERSION_FILE"; then
	echo "ct-remote ${CT_REMOTE_VERSION} already installed at ${DEST_BINARY}"
	exit 0
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
BASE_URL="https://downloads.codetracer.com/DesktopClient.App"
ARCHIVE=""

if [[ $OS == "Darwin" ]]; then
	case "$ARCH" in
	arm64)
		ARCHIVE="DesktopClient.App-osx-arm64-${CT_REMOTE_VERSION}.tar.gz"
		;;
	x86_64)
		ARCHIVE="DesktopClient.App-osx-x64-${CT_REMOTE_VERSION}.tar.gz"
		;;
	*)
		echo "Unsupported macOS architecture for ct-remote: ${ARCH}"
		exit 1
		;;
	esac
elif [[ $OS == "Linux" ]]; then
	case "$ARCH" in
	x86_64)
		ARCHIVE="DesktopClient.App-linux-x64-${CT_REMOTE_VERSION}.tar.gz"
		;;
	*)
		echo "Unsupported Linux architecture for ct-remote: ${ARCH}"
		exit 1
		;;
	esac
else
	echo "Unsupported operating system for ct-remote: ${OS}"
	exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE}"

echo "Downloading ct-remote (${CT_REMOTE_VERSION}) from ${BASE_URL}/${ARCHIVE}"
# Retry with exponential backoff. The downloads server uses a self-signed
# certificate so we fall back to --insecure if the first attempt fails with
# an SSL error (exit code 60). DNS failures on GitHub-hosted macOS runners
# are also retried.
if ! curl --retry 3 --retry-delay 5 --retry-connrefused \
	-L --fail --silent --show-error \
	"${BASE_URL}/${ARCHIVE}" -o "${ARCHIVE_PATH}" 2>/dev/null; then
	echo "  Retrying with --insecure (self-signed cert fallback)..."
	curl --retry 3 --retry-delay 5 --retry-connrefused \
		-L --fail --silent --show-error --insecure \
		"${BASE_URL}/${ARCHIVE}" -o "${ARCHIVE_PATH}"
fi

tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}"
mv "${TMP_DIR}/DesktopClient.App" "${DEST_BINARY}"
chmod +x "${DEST_BINARY}"

echo "${CT_REMOTE_VERSION}" >"${VERSION_FILE}"

echo "ct-remote installed at ${DEST_BINARY}"
