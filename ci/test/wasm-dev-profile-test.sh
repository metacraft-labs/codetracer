#!/usr/bin/env bash
#
# wasm-dev-profile-test.sh — the wasm32 developer profile builds the SAME
# program as `emcc`, and its object cache cannot serve a stale object.
#
# `ci/lib/wasm-cc.sh` replaces `emcc -c` with Emscripten's clang and the
# flags `emcc --cflags` prints, and adds a content-keyed object cache. Both
# are claims that the build's OUTPUT is unchanged, so this test checks the
# output rather than the flags:
#
#   1. IDENTITY. One real ViewModel suite is built twice from cold — through
#      `emcc` (CT_WASM_CC=emcc) and through the profile — and every object
#      file and the linked `.wasm` must be byte-identical between the two.
#   2. THE CACHE IS USED. The suite is built a third time into a fresh
#      nimcache against the now-warm object cache: the cache must not grow
#      (every object was a hit), and the `.wasm` must still be identical.
#   3. IT RUNS. The profile's build runs under node and reports the suite's
#      cases, all passing.
#   4. A CHANGED HEADER IS A MISS. A C file including a header is compiled
#      through `wasm-cc.sh`, the header changes, and the second compile must
#      produce a different object — the cache key is the PREPROCESSED source,
#      so a key that only hashed the `.c` file would serve the first object
#      again.
#   5. THE DEPENDENCY FILE IS WRITTEN on a hit as on a miss, naming the
#      object and the header: Nim reads it to decide what to recompile.
#
# Exit 0 if every check holds; 1 otherwise; 2 if nim, emcc or node is
# missing — a failure, never a skip.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

for tool in nim emcc em-config node; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		echo "ERROR: ${tool} is not on PATH; run inside this repo's dev shell." >&2
		exit 2
	fi
done

# shellcheck source=ci/lib/wasm-dev-profile.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/wasm-dev-profile.sh"

SUITE="${CT_WASM_PROFILE_SUITE:-src/frontend/viewmodel/tests/unit/test_async_compat_wasm_arm.nim}"
work="$(mktemp -d "${TMPDIR:-/tmp}/wasm-dev-profile-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

failures=0
fail() {
	echo "  FAIL: $*"
	failures=$((failures + 1))
}
ok() { echo "  ok: $*"; }

# The vm-unit-wasm lane's flags (ci/lib/run-nim-test-lane.sh), minus the C
# compiler, which each build below chooses.
lane_flags=(--hints:off --warnings:off --cpu:wasm32 --os:linux -d:emscripten
	--mm:orc --threads:off
	--passL:-sSTACK_SIZE=8388608 --passL:-sNODERAWFS=1
	--passL:-sALLOW_MEMORY_GROWTH=1 --passL:-sEXIT_RUNTIME=1
	--path:src/frontend/viewmodel --parallelBuild:8)

build() { # <label> <nimcache> -- uses CT_WASM_CC_FLAGS as set by the caller
	local label=$1 cache=$2
	if ! nim c "${lane_flags[@]}" "${CT_WASM_CC_FLAGS[@]}" \
		--nimcache:"${cache}" -o:"${cache}/suite.js" "${SUITE}" \
		>"${work}/${label}.log" 2>&1; then
		echo "  ${label} build failed:"
		grep -E 'Error|error' "${work}/${label}.log" | head -5 | sed 's/^/    /'
		return 1
	fi
}

echo "=== wasm32 developer profile: ${SUITE} ==="

# -- 1. identity --------------------------------------------------------------
CT_WASM_CC=emcc ct_wasm_dev_profile ""
build emcc "${work}/emcc" || fail "the emcc build did not build"
if ! ct_wasm_dev_profile "${work}/objects"; then
	fail "the profile could not be set up (em-config / emcc --cflags)"
	echo "wasm-dev-profile: ${failures} failure(s)"
	exit 1
fi
build profile "${work}/profile" || fail "the profile build did not build"

objs=0
differ=0
while IFS= read -r o; do
	name="$(basename "${o}")"
	objs=$((objs + 1))
	if ! cmp -s "${o}" "${work}/profile/${name}"; then
		differ=$((differ + 1))
		[ "${differ}" -le 3 ] && echo "    differs: ${name}"
	fi
done < <(find "${work}/emcc" -maxdepth 1 -name '*.o' | sort)
profile_objs="$(find "${work}/profile" -maxdepth 1 -name '*.o' | wc -l)"
if [ "${objs}" -lt 10 ]; then
	fail "the emcc build produced ${objs} object(s); a real suite produces dozens"
elif [ "${objs}" -ne "${profile_objs}" ]; then
	fail "emcc wrote ${objs} objects, the profile ${profile_objs}"
elif [ "${differ}" -ne 0 ]; then
	fail "${differ} of ${objs} objects differ between emcc and the profile"
else
	ok "all ${objs} objects are byte-identical to emcc's"
fi
if cmp -s "${work}/emcc/suite.wasm" "${work}/profile/suite.wasm"; then
	ok "the linked .wasm is byte-identical ($(wc -c <"${work}/profile/suite.wasm") bytes)"
else
	fail "the linked .wasm differs between emcc and the profile"
fi

# -- 2. the cache is used ------------------------------------------------------
cached_before="$(find "${work}/objects" -name '*.o' | wc -l)"
build warm "${work}/warm" || fail "the warm-cache build did not build"
cached_after="$(find "${work}/objects" -name '*.o' | wc -l)"
if [ "${cached_before}" -lt "$((objs / 2))" ]; then
	fail "the cache holds ${cached_before} object(s) after a ${objs}-object build"
elif [ "${cached_after}" -ne "${cached_before}" ]; then
	fail "a rebuild of the same suite added $((cached_after - cached_before)) object(s) to the cache"
else
	ok "a fresh nimcache was built entirely from the cache (${cached_before} objects, none added)"
fi
if cmp -s "${work}/emcc/suite.wasm" "${work}/warm/suite.wasm"; then
	ok "the cache-built .wasm is byte-identical to emcc's"
else
	fail "the cache-built .wasm differs from emcc's"
fi

# -- 3. it runs ------------------------------------------------------------------
run_out="$(timeout 300 node "${work}/warm/suite.js" 2>&1)"
run_rc=$?
oks="$(grep -c '\[OK\]' <<<"${run_out}" || true)"
fails="$(grep -c '\[FAILED\]' <<<"${run_out}" || true)"
if [ "${run_rc}" -eq 0 ] && [ "${oks}" -gt 0 ] && [ "${fails}" -eq 0 ]; then
	ok "the cache-built suite runs: ${oks} case(s), none failed"
else
	fail "the cache-built suite: exit ${run_rc}, ${oks} ok, ${fails} failed"
fi

# -- 4 and 5. a changed header is a miss; the dependency file is written ----------
mkdir -p "${work}/hdr" "${work}/hdr-cache"
printf '#include "value.h"\nint answer(void) { return VALUE; }\n' >"${work}/hdr/unit.c"
printf '#define VALUE 41\n' >"${work}/hdr/value.h"
compile_unit() { # <obj> <dep>
	CT_WASM_OBJ_CACHE="${work}/hdr-cache" "${repo_root}/ci/lib/wasm-cc.sh" \
		-c -I"${work}/hdr" -o "$1" "${work}/hdr/unit.c" -MD -MF "$2"
}
compile_unit "${work}/hdr/a.o" "${work}/hdr/a.d" || fail "the header probe did not compile"
compile_unit "${work}/hdr/b.o" "${work}/hdr/b.d" || fail "the header probe did not compile twice"
printf '#define VALUE 42\n' >"${work}/hdr/value.h"
compile_unit "${work}/hdr/c.o" "${work}/hdr/c.d" || fail "the header probe did not compile after the change"
if cmp -s "${work}/hdr/a.o" "${work}/hdr/b.o"; then
	ok "an unchanged header compiles to the same object"
else
	fail "the same source and header compiled to two different objects"
fi
if cmp -s "${work}/hdr/a.o" "${work}/hdr/c.o"; then
	fail "a changed header was served the old object from the cache"
else
	ok "a changed header is a cache miss"
fi
for d in b c; do
	if grep -q "${work}/hdr/${d}.o" "${work}/hdr/${d}.d" 2>/dev/null &&
		grep -q 'value.h' "${work}/hdr/${d}.d"; then
		ok "the dependency file names the object and the header (${d})"
	else
		fail "the dependency file for ${d} does not name ${d}.o and value.h"
	fi
done

if [ "${failures}" -eq 0 ]; then
	echo "wasm-dev-profile: all checks passed"
	exit 0
fi
echo "wasm-dev-profile: ${failures} failure(s)"
exit 1
