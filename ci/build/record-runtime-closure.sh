#!/usr/bin/env bash
# record-runtime-closure.sh OUT PATH... -- write to OUT the Nix store closure
# the ELF files at or under each PATH need at run time: each one's interpreter, its DT_RUNPATH and
# DT_RPATH directories and any DT_NEEDED given by absolute path, closed over
# with `nix-store -qR`. Non-ELF files and store paths this host lacks are
# skipped, so the list holds only what the binaries were built against here.
#
# ct-build packs the list with its products, and
# ci/unpack-ct-build-products.sh realises whatever a shard is missing: since
# build-once links ct through repro's own Nix tool provisioning, ct names
# glibc-2.40-66's loader, which the dev shell does not pull in, and every GPUI
# shard's `ct record` in run 44612896066 exited 127 on it. The interpreter
# alone is not enough, since each library on the RUNPATH is the next miss.
# ci/test/unpack-ct-build-products-test.sh holds it.
set -euo pipefail
out="${1:?usage: record-runtime-closure.sh OUT PATH...}"
shift
roots="$(find "$@" -type f -size +3c 2>/dev/null | while IFS= read -r f; do
	[ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
	readelf -lW "$f" 2>/dev/null | sed -nE 's/.*Requesting program interpreter: ([^]]+)\]/\1/p'
	readelf -dW "$f" 2>/dev/null | sed -nE 's/.*\((RUNPATH|RPATH)\).*\[([^]]*)\]/\2/p' | tr ':' '\n'
	readelf -dW "$f" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(\/[^]]*)\]/\1/p'
done | grep -oE '^/nix/store/[a-z0-9]{32}-[^/]+' | sort -u | while IFS= read -r p; do
	[ -e "$p" ] && echo "$p"
done || true)"
if [ -z "$roots" ]; then
	: >"$out"
else
	# shellcheck disable=SC2086 # one store path per word
	nix-store -qR $roots | sort -u >"$out"
fi
echo "record-runtime-closure: $(wc -l <"$out") store paths from $(printf '%s\n' "$roots" | grep -c . || true) roots in ${out}"
