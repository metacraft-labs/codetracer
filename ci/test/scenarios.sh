#!/usr/bin/env bash
# ci/test/scenarios.sh — CodeTracer's scenario pack: build its tools, lint its
# scenarios, run its lanes.
#
#   ci/test/scenarios.sh build [part…]      the runner and the bindings' programs
#   ci/test/scenarios.sh lint               the scenario linter over every scenario
#   ci/test/scenarios.sh lane <flavour>     one lane: terminal | gpui | electron
#   ci/test/scenarios.sh run <flavour> <scenario.yaml> [dvs run args…]
#
# The pack, its scenarios and its lanes are under src/tests/scenarios
# (README.md there). The general-purpose runner and backends are siblings of
# this checkout, at the revisions `repro.lock` pins:
#
#   ../DemoVideoScript               the format, the linter and the one runner
#   ../DemoVideoScript-TermAssert    the terminal backend (over ../TermAssert)
#   ../DemoVideoScript-GuiAssert     the vision backend (over ../GuiAssert)
#   ../DemoVideoScript-Playwright    the desktop arm (Playwright, TypeScript)
#
# Recordings of runs go under build/scenario-runs/<scenario>/<backend>/<run-id>/
# (kept on failure; `--record always` keeps passing ones too). The lane prints
# the directory of every failed run; CI uploads them (the codetracer workflow's
# scenario jobs). How to read one: .agents/codebase-insights.txt, "Scenario
# run recordings".
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
ws="$(cd "${root}/.." && pwd)"
S=src/tests/scenarios
bin="${root}/build/bin"
nimcache="${CT_NIM_CACHE_ROOT:-${root}/build/nimcache}"
build_dir="${CT_SCENARIO_BUILD:-${root}/build}"

dvs_src="${DVS_SRC:-${ws}/DemoVideoScript/src}"
dta_src="${DVS_TERMASSERT_SRC:-${ws}/DemoVideoScript-TermAssert/src}"
dga_src="${DVS_GUIASSERT_SRC:-${ws}/DemoVideoScript-GuiAssert/src}"
ga_src="${GUIASSERT_SRC:-${ws}/GuiAssert/src}"
dpw_root="${DVS_PLAYWRIGHT_ROOT:-${ws}/DemoVideoScript-Playwright}"

require() {
	local what="$1" path="$2"
	if [ ! -e "${path}" ]; then
		echo "scenarios: ${what} is missing at ${path}" >&2
		echo "  (a sibling checkout at the revision repro.lock pins)" >&2
		exit 2
	fi
}

nim_common=(--hints:off --warnings:off --threads:on --path:src/frontend/viewmodel)

build_dvs() {
	require "DemoVideoScript" "${dvs_src}/dvs.nim"
	mkdir -p "${bin}"
	nim c --hints:off --path:"${dvs_src}" -d:release \
		--nimcache:"${nimcache}/scenario-dvs" -o:"${bin}/dvs" "${dvs_src}/dvs.nim"
}

build_stage() {
	nim c "${nim_common[@]}" --nimcache:"${nimcache}/scenario-stage" \
		-o:"${bin}/ct-scenario-stage" "${S}/stages/ct_scenario_stage.nim"
}

build_terminal() {
	require "DemoVideoScript-TermAssert" "${dta_src}/demo_video_script_termassert.nim"
	nim c "${nim_common[@]}" --path:../TermAssert/src --path:../TermAssertClient/src \
		--path:../nim-libvterm/src --path:../nim-pty/src --path:"${dvs_src}" --path:"${dta_src}" \
		--nimcache:"${nimcache}/scenario-termassert" \
		-o:"${bin}/dvs-termassert-codetracer" "${S}/bindings/termassert/dvs_termassert_codetracer.nim"
}

build_gpui() {
	require "DemoVideoScript-GuiAssert" "${dga_src}/demo_video_script_guiassert.nim"
	nim c "${nim_common[@]}" --path:"${ga_src}" --path:"${dvs_src}" --path:"${dga_src}" \
		--nimcache:"${nimcache}/scenario-guiassert" \
		-o:"${bin}/dvs-guiassert-codetracer" "${S}/bindings/guiassert/dvs_guiassert_codetracer.nim"
	# what the binding reads off saved frames (a run's stills), for working on it
	nim c "${nim_common[@]}" --path:"${ga_src}" --path:"${dvs_src}" --path:"${dga_src}" \
		--nimcache:"${nimcache}/scenario-guiassert-surface" \
		-o:"${bin}/ct-gui-surface" "${S}/bindings/guiassert/ct_gui_surface.nim"
}

build_playwright() {
	require "DemoVideoScript-Playwright" "${dpw_root}/src/main.ts"
	# Playwright is the repository's own (node_modules, from the dev shell):
	# the binding imports it from there, and the arm is staged beside a link
	# to the same copy, so both drive one Playwright.
	local pw="${root}/node_modules/playwright-core"
	require "playwright-core (node_modules, from the dev shell)" "${pw}"
	mkdir -p "${build_dir}/scenario-arm/node_modules"
	ln -sfn "${pw}" "${build_dir}/scenario-arm/node_modules/playwright-core"
	rm -rf "${build_dir}/scenario-arm/src"
	cp -r "${dpw_root}/src" "${build_dir}/scenario-arm/src"
	printf '{ "type": "module", "private": true }\n' >"${build_dir}/scenario-arm/package.json"
}

backend_of() {
	case "$1" in
	terminal) echo "termassert" ;;
	gpui) echo "guiassert" ;;
	electron) echo "cmd:node ${build_dir}/scenario-arm/src/main.ts --binding ${root}/${S}/bindings/playwright/codetracer-binding.ts" ;;
	*)
		echo "scenarios: unknown flavour '$1' (terminal, gpui, electron)" >&2
		exit 64
		;;
	esac
}

runner_of() {
	case "$1" in
	terminal) echo "${bin}/dvs-termassert-codetracer" ;;
	gpui) echo "${bin}/dvs-guiassert-codetracer" ;;
	electron) echo "${bin}/dvs" ;;
	esac
}

case "${1:-}" in
build)
	# `build [dvs stage terminal gpui playwright]`: all, or the named parts.
	shift
	parts=("$@")
	[ "${#parts[@]}" -gt 0 ] || parts=(dvs stage terminal gpui playwright)
	for p in "${parts[@]}"; do "build_${p}"; done
	;;
lint)
	[ -x "${bin}/dvs" ] || build_dvs
	# Every scenario, against the pack. Warnings (L4 ordinals, L6 timing)
	# are allowed; an error fails. The pack itself is linted first.
	mapfile -t files < <(find "${S}" -name '*.yaml' -not -path '*/pack/*' -not -path '*/lanes/*' \
		-not -path '*/fixtures/*' -not -path '*/lint-must-fail/*' | sort)
	"${bin}/dvs" lint --pack "${S}/pack/codetracer.pack.yaml"
	set +e
	"${bin}/dvs" lint "${files[@]}" --pack "${S}/pack/codetracer.pack.yaml"
	rc=$?
	set -e
	echo "scenarios: linted ${#files[@]} scenario(s), exit ${rc}"
	[ "${rc}" -le 1 ] || exit 1
	# The linter's own control: each of these smuggles code into the steps
	# and MUST be rejected with an error (exit 2). A linter that let one
	# through would pass every scenario above for the wrong reason.
	for f in "${S}"/tests/lint-must-fail/*.yaml; do
		set +e
		out="$("${bin}/dvs" lint "${f}" --pack "${S}/pack/codetracer.pack.yaml" 2>&1)"
		rc=$?
		set -e
		if [ "${rc}" -ne 2 ]; then
			echo "scenarios: ${f} must fail the linter, and it exited ${rc}:" >&2
			echo "${out}" >&2
			exit 1
		fi
		echo "scenarios: rejected as it must be: ${f##*/}: $(echo "${out}" | grep -o 'error\[L[0-9]*\]' | head -1)"
	done
	;;
lane)
	flavour="${2:?usage: scenarios.sh lane <terminal|gpui|electron>}"
	runner="$(runner_of "${flavour}")"
	[ -x "${runner}" ] || "$0" build
	"${runner}" lane "${S}/lanes/${flavour}.lane.yaml" --build "${build_dir}"
	;;
run)
	flavour="${2:?usage: scenarios.sh run <flavour> <scenario.yaml> [args]}"
	scenario="${3:?usage: scenarios.sh run <flavour> <scenario.yaml> [args]}"
	shift 3
	settle=()
	# A GPU window drawn by a software renderer on a loaded machine takes
	# longer than the runner's default 5 s to stop changing after an input,
	# and so does Electron at a 1-minute load above 100 (each lane says so too).
	case "${flavour}" in
	gpui) settle=(--settle-timeout 30000) ;;
	electron) settle=(--settle-timeout 15000) ;;
	esac
	"$(runner_of "${flavour}")" run "${scenario}" --pack "${S}/pack/codetracer.pack.yaml" \
		--backend "$(backend_of "${flavour}")" --build "${build_dir}" "${settle[@]}" "$@"
	;;
*)
	sed -n '2,23p' "$0"
	exit 64
	;;
esac
