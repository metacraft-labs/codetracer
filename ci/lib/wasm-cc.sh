#!/usr/bin/env bash
#
# wasm-cc.sh — the C compiler a wasm32 Nim build calls, in place of `emcc`.
#
# Usage (from Nim): --clang.exe:ci/lib/wasm-cc.sh --clang.linkerexe:emcc
# with the environment `ci/lib/wasm-dev-profile.sh` prepares:
#
#   CT_WASM_CLANG       Emscripten's own clang (`em-config LLVM_ROOT`/clang)
#   CT_WASM_CFLAGS      what `emcc --cflags` prints, one line
#   CT_WASM_OBJ_CACHE   optional: a directory of objects keyed by content
#
# ## WHY NOT `emcc -c`
#
# `emcc` is a Python driver. For a compile it works out the target flags
# (`emcc --cflags` prints them) and then runs Emscripten's clang with them.
# The driver's own start-up costs about 0.8 s per call on the CI host, and a
# Nim test binary is 70-150 C files, so a single suite paid one to two CPU
# minutes of Python before clang compiled anything. That start-up was most of
# what made the wasm32 test lane slower than the native C lane.
#
# This script runs the same clang with the same flags and nothing else, so
# the OBJECT FILES ARE THE SAME BYTES as `emcc -c` writes.
# `ci/test/wasm-dev-profile-test.sh` checks that on every C file of a real
# suite rather than trusting this comment. Linking still goes through `emcc`,
# which is where Emscripten's real work (the JS runtime, the system
# libraries) happens.
#
# ## THE OBJECT CACHE
#
# Nim writes one C file per module into each test's own nimcache, so a lane
# of two hundred suites compiles `system.nim`, `json.nim`, the reactive core
# and the ViewModels two hundred times. Most of those C files differ between
# suites (Nim emits only the procs a program uses), but many are identical.
# With CT_WASM_OBJ_CACHE set, an object is reused when the PREPROCESSED
# source and the compile flags are identical — the key ccache's preprocessor
# mode uses, which also notices a changed header. The preprocessor runs on
# every call (about a tenth of a compile) and writes the dependency file Nim
# asks for. The nimcache directory is written into each C file's header
# comment and into the `-o`/`-MF` paths, so it is taken out of the key.
#
# A missing or unusable cache directory is not an error: the file is
# compiled.

set -uo pipefail

clang_bin="${CT_WASM_CLANG:-}"
if [ -z "${clang_bin}" ] || [ -z "${CT_WASM_CFLAGS:-}" ]; then
	echo "wasm-cc.sh: CT_WASM_CLANG and CT_WASM_CFLAGS must be set (see ci/lib/wasm-dev-profile.sh)" >&2
	exit 2
fi
read -r -a target_flags <<<"${CT_WASM_CFLAGS}"

# Anything that is not a compile goes to emcc unchanged.
is_compile=0
for a in "$@"; do
	if [ "${a}" = "-c" ]; then
		is_compile=1
		break
	fi
done
if [ "${is_compile}" -eq 0 ]; then
	exec emcc "$@"
fi

if [ -z "${CT_WASM_OBJ_CACHE:-}" ]; then
	exec "${clang_bin}" "${target_flags[@]}" "$@"
fi

# Split the command into the parts the cache key must not see (the output,
# the dependency file and the source path, all of which name this test's
# nimcache) and the flags it must see.
obj=""
dep=""
src=""
flags=()
args=("$@")
i=0
while [ "${i}" -lt "${#args[@]}" ]; do
	a="${args[${i}]}"
	case "${a}" in
	-o)
		i=$((i + 1))
		obj="${args[${i}]}"
		;;
	-MF)
		i=$((i + 1))
		dep="${args[${i}]}"
		;;
	-MD | -c) ;;
	*.c) src="${a}" ;;
	*) flags+=("${a}") ;;
	esac
	i=$((i + 1))
done

if [ -z "${obj}" ] || [ -z "${src}" ]; then
	exec "${clang_bin}" "${target_flags[@]}" "$@"
fi

cache="${CT_WASM_OBJ_CACHE}"
pre="${obj}.pp.i"
dep_args=()
if [ -n "${dep}" ]; then
	dep_args=(-MD -MF "${dep}" -MT "${obj}")
fi
# The preprocessor run is also the one that writes the dependency file, so a
# cache hit leaves exactly what a compile would.
if ! "${clang_bin}" "${target_flags[@]}" "${flags[@]}" -E -P "${src}" -o "${pre}" ${dep_args[@]+"${dep_args[@]}"}; then
	rm -f "${pre}"
	exec "${clang_bin}" "${target_flags[@]}" "$@"
fi
nimcache_dir="$(dirname "${obj}")"
key="$(
	{
		printf '%s\n' "${clang_bin}" "${CT_WASM_CFLAGS}"
		printf '%s\0' "${flags[@]//"${nimcache_dir}"/@NIMCACHE@}"
		cat "${pre}"
	} | sha256sum | cut -c1-64
)"
rm -f "${pre}"

hit="${cache}/${key:0:2}/${key}.o"
if [ -f "${hit}" ] && cp "${hit}" "${obj}" 2>/dev/null; then
	exit 0
fi

"${clang_bin}" "${target_flags[@]}" -c "${flags[@]}" -o "${obj}" "${src}" || exit $?

if mkdir -p "${cache}/${key:0:2}" 2>/dev/null; then
	tmp="${hit}.tmp.$$"
	cp "${obj}" "${tmp}" 2>/dev/null && mv -f "${tmp}" "${hit}" 2>/dev/null
	rm -f "${tmp}"
fi
exit 0
