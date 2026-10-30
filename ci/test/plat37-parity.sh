#!/usr/bin/env bash
# The published parity path owns independent captures and the stability gate.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Invalidate an older successful report even if compiling the oracle fails.
if [ "${1:-}" != "--test" ]; then
	if [ "${1:-}" = "--grade-saved" ]; then
		report=""
		output_flag="--output"
	else
		report="${root}/build/plat37-parity/grade.json"
		output_flag="--out"
	fi
	previous=""
	for arg in "$@"; do
		if [ "$previous" = "$output_flag" ]; then
			report="$arg"
			if [ "$output_flag" = "--out" ]; then report="${report}/grade.json"; fi
		fi
		case "$arg" in
		--out=*)
			if [ "$output_flag" = "--out" ]; then report="${arg#--out=}/grade.json"; fi
			;;
		--output=*)
			if [ "$output_flag" = "--output" ]; then report="${arg#--output=}"; fi
			;;
		esac
		previous="$arg"
	done
	if [ -n "$report" ]; then
		python3 - "$report" <<'PYTHON'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({"verdict": "REFUSED", "reason": "parity invocation incomplete"}) + "\n")
PYTHON
	fi
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/plat37-flip.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# Compile the owning library's unchanged C ABI shim. Only one compiler process;
# no additional workspace or heavyweight frontend build is needed for grading.
cxx="${CXX:-c++}"
# `-dynamiclib` is Apple's spelling; GNU ld wants `-shared` and position-
# independent code. The library is loaded by path through ctypes either way.
case "$(uname -s)" in
Darwin) shared=(-dynamiclib) ;;
*) shared=(-shared -fPIC) ;;
esac
"$cxx" -std=c++17 -O2 "${shared[@]}" \
	-I "${root}/../codetracer-image-diff/vendor/flip" \
	"${root}/../codetracer-image-diff/src/flip_wrapper.cpp" \
	-o "${scratch}/flip.dylib"
if [ "${1:-}" = "--test" ]; then
	shift
	python3 "${root}/ci/test/plat37-parity-test.py" "${scratch}/flip.dylib" "$@"
elif [ "${1:-}" = "--grade-saved" ]; then
	shift
	python3 "${root}/ci/test/plat37_parity.py" --flip-library "${scratch}/flip.dylib" "$@"
else
	python3 "${root}/ci/test/plat37_parity_capture.py" --flip-library "${scratch}/flip.dylib" "$@"
fi
