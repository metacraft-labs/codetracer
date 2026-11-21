#!/usr/bin/env bash
# unpack-ct-build-products.sh DIR [ARCHIVE] -- check, then unpack, an archive a
# once-per-run job uploads (DIR/ARCHIVE, default ct-build-products.tar.gz: the
# ct-build job's; visual-replay-tools.tar.gz is the visual-replay-tools job's)
# beside the sibling checkouts.
#
# actions/download-artifact can end "successfully" with a short file: GPUI
# shard 15 and TUI shard 7 of run 44269676398 spent 20 minutes downloading the
# 208 MB archive and then failed in tar with "gzip: stdin: unexpected end of
# file". The archive is tested whole before anything is extracted, so a short
# download is reported as one, exit 3, and the workflow downloads it again; a
# good archive unpacks as before. ci/test/unpack-ct-build-products-test.sh
# holds both.
set -euo pipefail
dir="${1:?usage: unpack-ct-build-products.sh DIR [ARCHIVE]}"
archive="${dir}/${2:-ct-build-products.tar.gz}"
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

# ct-build records the Nix store closure its binaries run against
# (ci/build/record-runtime-closure.sh): build-once links ct through repro's
# own Nix tool provisioning, against a glibc and libraries the dev shell does
# not pull in, and in run 44612896066 every GPUI shard's `ct record` exited
# 127 on the missing glibc-2.40-66 loader. Whatever of that closure this store
# lacks is realised here (it is substitutable); what cannot be is named, since
# a later step will fail on it.
closure="$dest/codetracer/src/build-debug-repro/nix-runtime-closure.txt"
if [ -s "$closure" ]; then
	missing=()
	while IFS= read -r p; do
		[ -n "$p" ] && [ ! -e "$p" ] && missing+=("$p")
	done <"$closure"
	if [ "${#missing[@]}" -gt 0 ]; then
		if command -v nix-store >/dev/null 2>&1 && nix-store --realise "${missing[@]}" >/dev/null 2>"$err"; then
			echo "unpack-ct-build-products: realised ${#missing[@]} store path(s) of the products' runtime closure"
		else
			still=()
			for p in "${missing[@]}"; do [ -e "$p" ] || still+=("$p"); done
			echo "unpack-ct-build-products: ${#still[@]} store path(s) of the products' runtime closure are not in this store and could not be realised, so the binaries needing them will not run: ${still[*]} ($(tail -1 "$err" 2>/dev/null))" >&2
		fi
	fi
fi
