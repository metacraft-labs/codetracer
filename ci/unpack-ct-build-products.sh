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

# The binaries name their ELF interpreter by store path, and since tup left,
# build-once links them through repro's own Nix tool provisioning, whose glibc
# is not the dev shell's: in run 44612896066 every GPUI shard's `ct record`
# failed with exit 127 ("No such file or directory") because ct's
# /nix/store/...-glibc-2.40-66/lib/ld-linux-x86-64.so.2 existed on the
# ct-build runner and not on the shard. Each interpreter the unpacked bin/
# files name is realised here if it is missing (it is substitutable); one
# that cannot be is reported by name, since a later step will fail on it.
interps="$(tar -tzf "$archive" | { grep -E '/bin/[^/]+$' || true; } | while IFS= read -r member; do
	f="$dest/$member"
	[ -f "$f" ] || continue
	grep -aoEm1 '/nix/store/[a-z0-9]{32}-[^/[:space:]]+/lib/ld-linux[-A-Za-z0-9_.]*\.so\.[0-9]+' "$f" 2>/dev/null || true
done | sed -E 's|^(/nix/store/[^/]+)/.*|\1|' | sort -u)"
for root in $interps; do
	[ -e "$root" ] && continue
	if command -v nix-store >/dev/null 2>&1 && nix-store --realise "$root" >/dev/null 2>&1; then
		echo "unpack-ct-build-products: realised the ELF interpreter's store path ${root}"
	else
		echo "unpack-ct-build-products: ${root}, the ELF interpreter the unpacked binaries name, is not in this store and could not be realised; they will not run" >&2
	fi
done
