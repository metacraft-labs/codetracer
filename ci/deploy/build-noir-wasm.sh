#!/usr/bin/env bash
#
# build-noir-wasm.sh — the two Noir wasm modules, from a pinned ref.
#
# ## The deployment decision this file implements
#
# `wasm_worker_browser.js` and `web_deployment.nim` between them settled that
# the modules are FETCHED at run time and not bundled (~16 MB and ~4.6 MB;
# base64 would put ~27 MB in front of first paint for a capability most
# sessions never invoke). What neither settled is where the bytes come from,
# and until now nothing produced them: `ci/test/noir-wasm-worker-e2e.sh` and
# `ci/test/web-bundle-assets.sh` both take them from environment variables and
# skip loudly when unset, and no CI job ever set one.
#
# Three options were open. This script is the third.
#
#   COMMIT THEM to this repository. Rejected: 20 MB of binary per bump, in a
#   repository that already declines to carry the 18 MB replay engine for the
#   same reason ("a repository that carried it would be carrying a second copy
#   of an artifact whose first copy is already published and versioned
#   elsewhere" — the sibling's fetch-engine.sh).
#
#   FETCH THEM FROM ANOTHER ORIGIN at run time. Rejected on three counts, and
#   the first is not a preference: a cross-origin module is a second origin
#   that must stay up for the product to compile anything, it needs CORS on
#   somebody else's bucket, and it forfeits the one property the fetched design
#   was chosen FOR — `ccImmutable` caching on the product's own origin. The
#   sibling campaign's `fetch-engine.sh` reaches the identical conclusion for
#   the identical reason and calls vendoring "the recommended copy to own
#   origin mode".
#
#   BUILD THEM IN CI and vendor them into the publish directory. Chosen, and
#   the cost is the only thing that made it a question. MEASURED: 58s for
#   `tooling/tracer_wasm` and 42s for `compiler/wasm` from a cold cargo cache
#   on a clean clone — about 100 seconds, once, for a pinned revision that
#   changes when someone changes it. With the workflow's cargo cache keyed on
#   NOIR_REV it is near zero on every deploy that does not bump the pin. That
#   is cheaper than the release-asset plumbing the alternatives need, and it
#   keeps the bytes reproducible from a revision this repository names.
#
# ## The frozen-path rule
#
# This clones into the directory it is given. It does not read, write or build
# in any existing `noir` checkout — an M37 sweep has several of them frozen,
# and a build script that "helpfully" reused a sibling would corrupt one.
#
# Usage:  bash ci/deploy/build-noir-wasm.sh <out-dir> [work-dir]
# Output: <out-dir>/noir_wasm.wasm, <out-dir>/noir_tracer_wasm.wasm
#         and echoes NOIR_REV so a caller can use it as provenance.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="${1:?usage: build-noir-wasm.sh <out-dir> [work-dir]}"
work_dir="${2:-${out_dir}/.noir-wasm-build}"

# shellcheck source=ci/deploy/noir-wasm.pin
# shellcheck disable=SC1091
source "${repo_root}/ci/deploy/noir-wasm.pin"

mkdir -p "${out_dir}" "${work_dir}" || exit 2

command -v cargo >/dev/null 2>&1 || {
	echo "cargo is not on PATH" >&2
	echo "  remedy: run inside the dev shell (nix develop .#ci)" >&2
	exit 2
}

# WHICH COMPILER ANSWERED. This script's two byte counts land in a TRACKED
# FILE — `EXPECT_COMPILER_BYTES` and `EXPECT_TRACER_BYTES` in
# `ci/deploy/noir-wasm.pin` — and that file already records why the toolchain
# reaches them: "A rustc bump moves them further." Until now nothing said WHICH
# rustc produced the recorded figures, so a number in the pin file and a number
# from a later run could differ for a reason nobody could name.
#
# `--require rustc cargo` is the rule from `scripts/toolchain-pins.sh`: it
# verifies strictly and only then prints the stamp, so there is no way to reach
# the number without having passed the refusal. It is SCOPED to the two tools
# this script actually uses — `nim` and `nargo` play no part in a
# `wasm32-unknown-unknown` cargo build, and a stamp that named them would be
# vouching for compilers this run never invoked. The stamp itself lists them
# separately under `not-verified:` for exactly that reason.
#
# A refusal here exits 2 (the environment is wrong), not 1 (the build failed),
# matching the cargo check above.
TOOLCHAIN_STAMP=""
toolchain_guard="${repo_root}/scripts/toolchain-pins.sh"
if [ -f "${toolchain_guard}" ]; then
	if ! TOOLCHAIN_STAMP="$(bash "${toolchain_guard}" --require rustc cargo)"; then
		echo "refusing to produce a byte count from an unattributable toolchain." >&2
		echo "  The two numbers this script prints are copied into" >&2
		echo "  ci/deploy/noir-wasm.pin, so they have to name a compiler." >&2
		echo "  The diagnostics above say which check failed and how to fix it." >&2
		exit 2
	fi
else
	# Say so rather than print a number with no provenance at all. A missing
	# guard is an unrun check, and an unrun check reads exactly like a passing
	# one on the line that follows.
	TOOLCHAIN_STAMP="TOOLCHAIN: UNKNOWN — ${toolchain_guard} is absent, so nothing verified the compiler that produced the figures below."
fi

echo "=== the two Noir wasm modules ==="
echo "  noir:         ${NOIR_REPO} @ ${NOIR_REV}"
echo "  trace-format: ${TRACE_FORMAT_REPO} @ ${TRACE_FORMAT_REV}"
echo "  work dir:     ${work_dir}"
echo "  ${TOOLCHAIN_STAMP}"
echo

# The sibling FIRST. Without it `cargo` fails while loading the workspace
# manifest — before compiling anything — with "failed to read
# .../codetracer-trace-format/codetracer_trace_types/Cargo.toml", an error that
# names a missing file rather than a missing repository. Cloning it first turns
# that into a step that either worked or did not.
clone_at() {
	local repo="$1" rev="$2" dest="$3"
	if [ -d "${dest}/.git" ]; then
		echo "  reusing ${dest}"
	else
		rm -rf "${dest}"
		git init -q "${dest}" || return 1
		git -C "${dest}" remote add origin "${repo}" || return 1
	fi
	git -C "${dest}" fetch -q --depth 1 origin "${rev}" || return 1
	git -C "${dest}" checkout -q FETCH_HEAD || return 1
	echo "  ${dest}: $(git -C "${dest}" rev-parse HEAD)"
}

trace_format_dir="${work_dir}/codetracer-trace-format"
noir_dir="${work_dir}/noir"
clone_at "${TRACE_FORMAT_REPO}" "${TRACE_FORMAT_REV}" "${trace_format_dir}" || {
	echo "could not check out the trace-format sibling" >&2
	exit 1
}
clone_at "${NOIR_REPO}" "${NOIR_REV}" "${noir_dir}" || {
	echo "could not check out noir" >&2
	exit 1
}
echo

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${work_dir}/target}"
release="${CARGO_TARGET_DIR}/wasm32-unknown-unknown/release"

build_module() {
	local crate_dir="$1" artifact="$2" expected="$3"
	shift 3
	echo "  building ${crate_dir} ..."
	local log
	log="${work_dir}/$(basename "${crate_dir}").log"
	# NOT `set -e` and NOT a bare exit-code test on a pipeline: the exit status
	# of a `cargo build` piped anywhere is the pipe's, and this repository has
	# lost hours to exactly that. Run it plainly, capture the status, then read
	# the artifact — which is the fact that actually matters.
	(cd "${noir_dir}/${crate_dir}" && cargo build --release \
		--target wasm32-unknown-unknown "$@") >"${log}" 2>&1
	local status=$?
	if [ "${status}" -ne 0 ]; then
		echo "  cargo exited ${status} for ${crate_dir}:" >&2
		tail -20 "${log}" | sed 's/^/      /' >&2
		return 1
	fi
	local built="${release}/${artifact}"
	if [ ! -f "${built}" ]; then
		echo "  cargo reported success and produced no ${artifact}" >&2
		return 1
	fi
	local bytes
	bytes="$(wc -c <"${built}" | tr -d ' ')"
	# The wasm magic, for the same reason the sibling's fetch-engine.sh checks
	# it: a build that emitted something else, or a truncated copy, must not
	# reach a publish directory and fail inside `WebAssembly.compile` where the
	# message names neither this script nor that file.
	if ! grep -q '^0061736d' <<<"$(head -c 4 "${built}" | od -An -tx1 | tr -d ' \n')"; then
		echo "  ${artifact} does not begin with the wasm magic" >&2
		return 1
	fi
	cp "${built}" "${out_dir}/${artifact}" || return 1
	if [ "${bytes}" != "${expected}" ]; then
		# A REPORT, not a failure. The pin records what these measured when it
		# was written; a toolchain bump legitimately moves them by a few
		# percent and failing here would make an unrelated rustc upgrade break
		# the deploy. A LARGE divergence is visible in the log, and the deploy
		# guard separately compares the published bytes against what the page
		# declares — which is the check that actually protects a visitor.
		echo "  NOTE: ${artifact} is ${bytes} bytes; the pin records ${expected}"
	fi
	# THE NUMBER AND THE COMPILER, ON THE SAME LINE. This figure is what gets
	# copied into ci/deploy/noir-wasm.pin, and the previous bumps' notes show
	# what its absence cost: entries carried forward "unmeasured", divergences
	# attributed to a build DIRECTORY, and no way to tell a rustc bump from a
	# product change. Whoever copies the number now copies the compiler with it.
	echo "  ok: ${artifact} (${bytes} bytes)"
	echo "      ${TOOLCHAIN_STAMP}"
	return 0
}

failures=0
build_module "tooling/tracer_wasm" "noir_tracer_wasm.wasm" \
	"${EXPECT_TRACER_BYTES}" --no-default-features || failures=$((failures + 1))
build_module "compiler/wasm" "noir_wasm.wasm" \
	"${EXPECT_COMPILER_BYTES}" || failures=$((failures + 1))

echo
if [ "${failures}" -ne 0 ]; then
	echo "RESULT: FAILED — ${failures} module(s) did not build"
	exit 1
fi
echo "RESULT: OK — both modules are in ${out_dir}"
echo "NOIR_REV=${NOIR_REV}"
echo "${TOOLCHAIN_STAMP}"
