#!/usr/bin/env bash
#
# web-core-browser.sh — the browser front-end's WebAssembly ViewModel core
# (`src/frontend/web_core/web_core.nim`) on a real recording, served by a real
# replay-server, in Chromium and Firefox.
#
# Builds the core for wasm32 (Emscripten, `-sENVIRONMENT=web`) and with
# `nim js`, both `-d:ctWasmCore`, assembles the page with IsoNim's frame
# applier and `web_core_host.js`, and runs `web-core-browser/browser.mjs`,
# which opens the recording, steps it and compares the two cores' documents.
#
#   REPLAY_SERVER_BIN          the engine (required)
#   CT_WEB_CORE_RECORDING      the recording folder; without one, CT_WEB_CORE_PROGRAM
#                              (default test-programs/js_flow_test/flow_test.js) is
#                              recorded with CT_BIN (default the build's ct)
#   CT_WEB_CORE_ENGINES        engines to run (default "chromium firefox")
#   CT_WEB_CORE_STEPS          steps per run (default 4)
#   CT_WEB_CORE_RELEASE=1      build both cores -d:release
#   CT_WEB_CORE_OUT            build directory (default test-logs/web-core)
#
# Exit 0 when every engine passed, 1 when a build or a check failed, 2 when a
# prerequisite is missing — a failure, never a skip.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

for tool in nim emcc node; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		echo "ERROR: ${tool} is not on PATH; run inside this repo's dev shell." >&2
		exit 2
	fi
done
replay_server="${REPLAY_SERVER_BIN:-}"
# Unset: the places the other suites search, in src/common/replay_server_path's
# order (a CI job builds it into cargo's tree with `test-vm-recorder-gated`).
if [ -z "${replay_server}" ]; then
	for c in "src/build-debug-repro/bin/replay-server" "src/build-debug/bin/replay-server" \
		src/db-backend/target/debug/replay-server src/db-backend/target/release/replay-server; do
		if [ -x "${c}" ]; then replay_server="${repo_root}/${c}" && break; fi
	done
fi
recording="${CT_WEB_CORE_RECORDING:-}"
if [ -z "${replay_server}" ] || [ ! -x "${replay_server}" ]; then
	echo "ERROR: REPLAY_SERVER_BIN must name a replay-server binary (got '${replay_server}')." >&2
	exit 2
fi
# No recording given: make one, with the same `ct record` a user records
# with, from CT_WEB_CORE_PROGRAM (default: the JavaScript flow test, which the
# CI job's JS recorder can record).
if [ -z "${recording}" ]; then
	program="${CT_WEB_CORE_PROGRAM:-test-programs/js_flow_test/flow_test.js}"
	ct_bin="${CT_BIN:-}"
	if [ -z "${ct_bin}" ]; then
		for c in src/build-debug/bin/ct src/build-debug-repro/bin/ct src/build-release/bin/ct; do
			[ -x "${c}" ] && ct_bin="${c}" && break
		done
	fi
	if [ -z "${ct_bin}" ] || [ ! -x "${ct_bin}" ]; then
		echo "ERROR: no recording given and no ct to record one (set CT_BIN or build ct)." >&2
		exit 2
	fi
	recording="${CT_WEB_CORE_OUT:-${repo_root}/test-logs/web-core}-recording"
	rm -rf "${recording}"
	echo "--- recording ${program} with ${ct_bin} ---"
	if ! "${ct_bin}" record -o "${recording}" "${program}"; then
		echo "  FAIL: ct record ${program} failed"
		exit 1
	fi
fi
if [ ! -d "${recording}" ]; then
	echo "ERROR: CT_WEB_CORE_RECORDING must name a recording folder (got '${recording}')." >&2
	exit 2
fi

isonim_src="${ISONIM_SRC:-${repo_root}/../isonim/src}"
applier="${isonim_src}/isonim/web/frame_applier.js"
if [ ! -f "${applier}" ]; then
	echo "ERROR: ${applier} is missing; IsoNim is too old or not beside this checkout." >&2
	exit 2
fi

out="${CT_WEB_CORE_OUT:-${repo_root}/test-logs/web-core}"
rm -rf "${out}"
# The core (both builds), the decoration bundle and the host files.
bash ci/lib/web-core-build.sh "${out}" js
rc=$?
[ "${rc}" -eq 0 ] || exit "${rc}"
cp ci/test/web-core-browser/page.html "${out}/"

failures=0
for engine in ${CT_WEB_CORE_ENGINES:-chromium firefox}; do
	echo "--- ${engine} ---"
	CT_REPO="${repo_root}" node ci/test/web-core-browser/browser.mjs "${out}" "${engine}" \
		"${replay_server}" "${recording}" "${CT_WEB_CORE_STEPS:-4}"
	rc=$?
	if [ "${rc}" -eq 2 ]; then
		exit 2
	elif [ "${rc}" -ne 0 ]; then
		failures=$((failures + 1))
	fi
done
if [ "${failures}" -ne 0 ]; then
	echo "web-core-browser: ${failures} engine(s) failed"
	exit 1
fi
echo "web-core-browser: ok"
