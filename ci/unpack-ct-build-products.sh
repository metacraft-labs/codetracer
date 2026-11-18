#!/usr/bin/env bash
# unpack-ct-build-products.sh DIR -- check, then unpack, the ct-build job's
# products archive (DIR/ct-build-products.tar.gz) beside the sibling checkouts.
#
# actions/download-artifact can end "successfully" with a short file: GPUI
# shard 15 and TUI shard 7 of run 44269676398 spent 20 minutes downloading the
# 208 MB archive and then failed in tar with "gzip: stdin: unexpected end of
# file". The archive is tested whole before anything is extracted, so a short
# download is reported as one, exit 3, and the workflow downloads it again; a
# good archive unpacks as before. ci/test/unpack-ct-build-products-test.sh
# holds both.
set -euo pipefail
dir="${1:?usage: unpack-ct-build-products.sh DIR}"
archive="${dir}/ct-build-products.tar.gz"
dest="${CT_BUILD_PRODUCTS_DEST:-..}"
if [ ! -s "$archive" ]; then
	echo "unpack-ct-build-products: ${archive} is missing or empty" >&2
	exit 3
fi
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if ! gzip -t "$archive" 2>"$err"; then
	echo "unpack-ct-build-products: ${archive} is incomplete ($(stat -c %s "$archive") bytes): $(tail -1 "$err")" >&2
	exit 3
fi
tar -xzf "$archive" -C "$dest"
echo "unpacked ${archive} ($(stat -c %s "$archive") bytes)"
