#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"

if ! command -v go >/dev/null 2>&1; then
	echo "SKIPPED: go compiler not on PATH" >&2
	exit 2
fi
GOFLAGS="${GOFLAGS:--gcflags=all=-N -l}"
# shellcheck disable=SC2086
go build $GOFLAGS -o "$BUILD_DIR/main" main.go

RECORDER="${CT_NATIVE_REPLAY:-${CODETRACER_NATIVE_RECORDER:-ct-native-replay}}"
if ! command -v "$RECORDER" >/dev/null 2>&1; then
	echo "SKIPPED: $RECORDER not on PATH" >&2
	exit 2
fi
exec "$RECORDER" record -o "$OUT_DIR" -- "$BUILD_DIR/main"
