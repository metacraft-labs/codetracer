#!/usr/bin/env bash
# ci/test/unpack-ct-build-products-test.sh -- a short ct-build products download
# is caught before extraction and downloaded again; a whole one unpacks.
#
# Run 44269676398: GPUI shard 15 and TUI shard 7 got a truncated archive from
# actions/download-artifact, which reported success, and failed in tar.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
check() {
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "$good"; else fail "$bad"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src/codetracer/src/build-debug" "$work/dl" "$work/short" "$work/dest" "$work/dest2"
head -c 2000000 /dev/urandom >"$work/src/codetracer/src/build-debug/ct"
tar -czf "$work/dl/ct-build-products.tar.gz" -C "$work/src" codetracer
size="$(stat -c %s "$work/dl/ct-build-products.tar.gz")"
head -c $((size / 2)) "$work/dl/ct-build-products.tar.gz" >"$work/short/ct-build-products.tar.gz"

unpack() {
	CT_BUILD_PRODUCTS_DEST="$2" bash ci/unpack-ct-build-products.sh "$1" >"$work/out" 2>&1
}
check "a whole archive unpacks" "a whole archive did not unpack: $(cat "$work/out" 2>/dev/null)" \
	unpack "$work/dl" "$work/dest"
check "and its files arrive intact" "the unpacked file differs" \
	cmp -s "$work/src/codetracer/src/build-debug/ct" "$work/dest/codetracer/src/build-debug/ct"
set +e
unpack "$work/short" "$work/dest2"
rc=$?
set -e
check "a truncated archive exits 3" "a truncated archive exited ${rc}" test "$rc" = 3
check "and says it is incomplete" "no 'incomplete' message: $(cat "$work/out")" grep -q "is incomplete" "$work/out"
check "and extracts nothing" "a truncated archive left files behind" test -z "$(ls -A "$work/dest2")"
set +e
unpack "$work/no-such-dir" "$work/dest2"
rc=$?
set -e
check "a missing archive exits 3" "a missing archive exited ${rc}" test "$rc" = 3

# shellcheck disable=SC2016 # the workflow lines, literally
for f in .github/workflows/gpui-window-captures.yml .github/workflows/tui-tests.yml; do
	check "$f unpacks through the script, and may fail into a retry" "$f: no checked unpack step" \
		grep -q 'run: bash ci/unpack-ct-build-products.sh "${RUNNER_TEMP}/ct-build"$' "$f"
	check "$f downloads again when the first unpack fails" "$f: no retry download" \
		grep -q 'Restore the ct-build products again, the first download being incomplete' "$f"
	check "$f unpacks the second download" "$f: no second unpack" \
		grep -q 'run: bash ci/unpack-ct-build-products.sh "${RUNNER_TEMP}/ct-build-retry"$' "$f"
done

# ct-build packs build-once's output directory, which the justfile names as
# `require-runtime-assets`' OUT_ROOT. 471fb023529 moved it to
# src/build-debug-repro and ct-build kept packing src/build-debug: run
# 44444132651's ct-build failed at "Cannot stat" and no shard ran.
out_root="$(sed -nE 's/^require-runtime-assets OUT_ROOT="([^"]+)":.*/\1/p' justfile)"
if [ -n "$out_root" ] && grep -qF " codetracer/${out_root} \\" .github/workflows/ct-build.yml; then
	ok "ct-build packs build-once's output directory (${out_root})"
else
	fail "ct-build does not pack build-once's output directory '${out_root}' (justfile require-runtime-assets OUT_ROOT)"
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
