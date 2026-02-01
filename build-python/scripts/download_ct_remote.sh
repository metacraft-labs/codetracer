#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
	echo "Usage: $0 <target-os> <target-arch> <output-dir>" >&2
	exit 1
fi

TARGET_OS="$1"
TARGET_ARCH="$2"
OUTPUT_DIR="$3"

CT_REMOTE_VERSION="${CT_REMOTE_VERSION:-102d2c8}"
BASE_URL="https://downloads.codetracer.com/DesktopClient.App"

case "${TARGET_OS}" in
linux)
	case "${TARGET_ARCH}" in
	amd64 | x86_64)
		ARCHIVE="DesktopClient.App-linux-x64-${CT_REMOTE_VERSION}.tar.gz"
		;;
	*)
		echo "Unsupported Linux architecture for ct-remote: ${TARGET_ARCH}" >&2
		exit 1
		;;
	esac
	;;
macos)
	case "${TARGET_ARCH}" in
	amd64 | x86_64)
		ARCHIVE="DesktopClient.App-osx-x64-${CT_REMOTE_VERSION}.tar.gz"
		;;
	arm64 | aarch64)
		ARCHIVE="DesktopClient.App-osx-arm64-${CT_REMOTE_VERSION}.tar.gz"
		;;
	*)
		echo "Unsupported macOS architecture for ct-remote: ${TARGET_ARCH}" >&2
		exit 1
		;;
	esac
	;;
*)
	echo "Unsupported operating system for ct-remote: ${TARGET_OS}" >&2
	exit 1
	;;
esac

mkdir -p "${OUTPUT_DIR}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE}"

echo "Downloading ct-remote ${CT_REMOTE_VERSION} from ${BASE_URL}/${ARCHIVE}"
curl -L "${BASE_URL}/${ARCHIVE}" -o "${ARCHIVE_PATH}"

tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}"
mv "${TMP_DIR}/DesktopClient.App" "${OUTPUT_DIR}/ct-remote"
chmod +x "${OUTPUT_DIR}/ct-remote"

echo "ct-remote fetched to ${OUTPUT_DIR}/ct-remote"
