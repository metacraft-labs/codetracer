#!/usr/bin/env bash
# ci/test/scenarios.sh — CodeTracer's scenario pack: build its tools, lint its
# scenarios, run its lanes.
#
#   ci/test/scenarios.sh build [part…]      the runner and the bindings' programs
#   ci/test/scenarios.sh lint               the scenario linter over every scenario
#   ci/test/scenarios.sh lane <flavour>     one lane: terminal | gpui | zgui | electron | firefox
#                                           (SCENARIO_LANE_SHARD=i/n: one shard of it)
#   ci/test/scenarios.sh run <flavour> <scenario.yaml> [dvs run args…]
#   ci/test/scenarios.sh binding-test       the bindings' own tests (bindings/*/*.test.ts)
#   ci/test/scenarios.sh stage-test         the stage tool's own tests (stages/*_test.nim)
#
# The pack, its scenarios and its lanes are under src/tests/scenarios
# (README.md there). The general-purpose runner and backends are siblings of
# this checkout, at the revisions the TEST lock pins: ci/test/siblings/repro.lock,
# a project of its own nested here (its repro.nim says why it is separate from
# the product's repro.lock). CI clones them from it. `build` refuses a sibling
# checkout at another revision, and `run` and `lane` rebuild a program built
# from one (CT_SCENARIOS_ALLOW_OFF_PIN=1: build against it anyway, on purpose).
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
ta_src="${TERM_ASSERT_SRC:-${ws}/TermAssert/src}"
dga_src="${DVS_GUIASSERT_SRC:-${ws}/DemoVideoScript-GuiAssert/src}"
ga_src="${GUIASSERT_SRC:-${ws}/GuiAssert/src}"
dpw_root="${DVS_PLAYWRIGHT_ROOT:-${ws}/DemoVideoScript-Playwright}"

require() {
	local what="$1" path="$2"
	if [ ! -e "${path}" ]; then
		echo "scenarios: ${what} is missing at ${path}" >&2
		echo "  (a sibling checkout at the revision ci/test/siblings/repro.lock pins)" >&2
		exit 2
	fi
}

# A sibling a program is built from must be the revision the test lock pins.
# A sibling checkout three commits behind its pin built a `dvs` whose orphan
# reaper killed rr's replay processes (DemoVideoScript 028ea4f, "leave a
# traced orphan to its tracer"), and every rr scenario that seeks lost its
# replay at random -- while the only sign was a warning in the build log. So
# a build refuses an off-pin sibling, and a program records the revisions it
# was built from (${bin}/.siblings-<part>), which `run` and `lane` check
# before using it. CT_SCENARIOS_ALLOW_OFF_PIN=1 builds against a sibling's
# work in progress on purpose, and says so.
test_lock="${root}/ci/test/siblings/repro.lock"
off_pin_allowed() { [ "${CT_SCENARIOS_ALLOW_OFF_PIN:-}" = 1 ]; }

# pin_of <name>: the revision the test lock pins <name> at; empty when it
# pins none.
pin_of() {
	[ -f "${test_lock}" ] || return 0
	grep -o "name = \"$1\", coord_kind = \"vcs\", url = \"[^\"]*\", revision = \"[0-9a-f]*\"" "${test_lock}" |
		sed 's/.*revision = "//; s/"$//' | head -n 1 || true
}

# head_of <dir>: the commit checked out at <dir>; "unknown" when it is not a
# git checkout.
head_of() { git -C "$1" rev-parse HEAD 2>/dev/null || echo unknown; }

# require_on_pin <name> <dir>: refuse a sibling checkout off its pin.
require_on_pin() {
	local name="$1" dir="$2" pinned head
	pinned="$(pin_of "${name}")"
	[ -n "${pinned}" ] || return 0
	head="$(head_of "${dir}")"
	[ "${head}" != "${pinned}" ] || return 0
	if off_pin_allowed; then
		echo "scenarios: warning: building against ${dir} at ${head:0:11}; the test lock pins ${name} at ${pinned:0:11} (CT_SCENARIOS_ALLOW_OFF_PIN=1)" >&2
		return 0
	fi
	echo "scenarios: ${dir} is at ${head:0:11}, but the test lock (ci/test/siblings/repro.lock) pins ${name} at ${pinned:0:11}" >&2
	echo "  check it out at the pin (git -C ${dir} checkout --detach ${pinned}), or set CT_SCENARIOS_ALLOW_OFF_PIN=1 to build against it on purpose" >&2
	exit 3
}

# The siblings each part is built from: "<name> <dir>" pairs.
siblings_of() {
	case "$1" in
	dvs) echo "DemoVideoScript $(dirname "${dvs_src}")" ;;
	terminal)
		echo "DemoVideoScript $(dirname "${dvs_src}")"
		echo "DemoVideoScript-TermAssert $(dirname "${dta_src}")"
		echo "TermAssert $(dirname "${ta_src}")"
		echo "TermAssertClient ${ws}/TermAssertClient"
		echo "nim-libvterm ${ws}/nim-libvterm"
		echo "nim-pty ${ws}/nim-pty"
		;;
	gpui | zgui)
		echo "DemoVideoScript $(dirname "${dvs_src}")"
		echo "DemoVideoScript-GuiAssert $(dirname "${dga_src}")"
		echo "GuiAssert $(dirname "${ga_src}")"
		;;
	playwright) echo "DemoVideoScript-Playwright ${dpw_root}" ;;
	esac
}

# check_siblings <part>: refuse to build <part> from an off-pin sibling.
check_siblings() {
	local name dir
	while read -r name dir; do
		[ -n "${name}" ] && require_on_pin "${name}" "${dir}"
	done < <(siblings_of "$1")
}

# stamp_siblings <part>: record the revisions <part> was just built from.
stamp_siblings() {
	local name dir
	mkdir -p "${bin}"
	while read -r name dir; do
		[ -n "${name}" ] && echo "${name} $(head_of "${dir}")"
	done < <(siblings_of "$1") >"${bin}/.siblings-$1"
}

# output_of <part>: what building <part> makes.
output_of() {
	case "$1" in
	dvs) echo "${bin}/dvs" ;;
	terminal) echo "${bin}/dvs-termassert-codetracer" ;;
	gpui) echo "${bin}/dvs-guiassert-codetracer" ;;
	zgui) echo "${bin}/dvs-guiassert-codetracer-zgui" ;;
	playwright) echo "${build_dir}/scenario-arm/src/main.ts" ;;
	esac
}

# built_on_pin <part>: <part> was built, from the revisions the test lock pins
# now (or off them, when that is allowed).
built_on_pin() {
	local stamp="${bin}/.siblings-$1" name rev pinned
	[ -e "$(output_of "$1")" ] && [ -f "${stamp}" ] || return 1
	while read -r name rev; do
		pinned="$(pin_of "${name}")"
		if [ -n "${pinned}" ] && [ "${rev}" != "${pinned}" ] && ! off_pin_allowed; then
			echo "scenarios: ${1} was built from ${name} ${rev:0:11}, the test lock pins ${pinned:0:11}: rebuilding it" >&2
			return 1
		fi
	done <"${stamp}"
}

# parts_of <flavour>: the parts a flavour's runs use.
parts_of() {
	case "$1" in
	terminal) echo "terminal" ;;
	gpui) echo "gpui" ;;
	zgui) echo "zgui" ;;
	electron | firefox) echo "dvs playwright" ;;
	esac
}

# ensure_built <flavour>: every part the flavour uses, built on its pins.
ensure_built() {
	local part
	for part in $(parts_of "$1"); do
		built_on_pin "${part}" || "$0" build "${part}"
	done
}

# Optimised, with assertions and runtime checks kept on by name (a tool's or
# a binding's `assert` must still fail it): the GPUI binding derives a
# surface from every capture, and unoptimised its pixel loops were most of a
# run's time (a call-trace scenario's surfaces 202 s of pixel work against
# 23 s optimised, the same captures).
nim_common=(--hints:off --warnings:off --threads:on -d:release --assertions:on --checks:on
	--path:src/frontend/viewmodel)

build_dvs() {
	require "DemoVideoScript" "${dvs_src}/dvs.nim"
	check_siblings dvs
	mkdir -p "${bin}"
	nim c --hints:off --path:"${dvs_src}" -d:release \
		--nimcache:"${nimcache}/scenario-dvs" -o:"${bin}/dvs" "${dvs_src}/dvs.nim"
	stamp_siblings dvs
}

build_stage() {
	nim c "${nim_common[@]}" --nimcache:"${nimcache}/scenario-stage" \
		-o:"${bin}/ct-scenario-stage" "${S}/stages/ct_scenario_stage.nim"
}

build_terminal() {
	require "DemoVideoScript-TermAssert" "${dta_src}/demo_video_script_termassert.nim"
	check_siblings terminal
	nim c "${nim_common[@]}" --path:"${ta_src}" --path:../TermAssertClient/src \
		--path:../nim-libvterm/src --path:../nim-pty/src --path:"${dvs_src}" --path:"${dta_src}" \
		--nimcache:"${nimcache}/scenario-termassert" \
		-o:"${bin}/dvs-termassert-codetracer" "${S}/bindings/termassert/dvs_termassert_codetracer.nim"
	stamp_siblings terminal
}

build_gpui() {
	require "DemoVideoScript-GuiAssert" "${dga_src}/demo_video_script_guiassert.nim"
	check_siblings gpui
	nim c "${nim_common[@]}" --path:"${ga_src}" --path:"${dvs_src}" --path:"${dga_src}" \
		--nimcache:"${nimcache}/scenario-guiassert" \
		-o:"${bin}/dvs-guiassert-codetracer" "${S}/bindings/guiassert/dvs_guiassert_codetracer.nim"
	# what the binding reads off saved frames (a run's stills), for working on it
	nim c "${nim_common[@]}" --path:"${ga_src}" --path:"${dvs_src}" --path:"${dga_src}" \
		--nimcache:"${nimcache}/scenario-guiassert-surface" \
		-o:"${bin}/ct-gui-surface" "${S}/bindings/guiassert/ct_gui_surface.nim"
	stamp_siblings gpui
}

build_zgui() {
	# The zgui window (`codetracer-zgui`, `just build-zgui`), read by the same
	# GuiAssert backend as the GPUI window, with the zgui binding.
	require "DemoVideoScript-GuiAssert" "${dga_src}/demo_video_script_guiassert.nim"
	check_siblings zgui
	nim c "${nim_common[@]}" --path:"${ga_src}" --path:"${dvs_src}" --path:"${dga_src}" \
		--nimcache:"${nimcache}/scenario-guiassert-zgui" \
		-o:"${bin}/dvs-guiassert-codetracer-zgui" "${S}/bindings/guiassert/dvs_guiassert_codetracer_zgui.nim"
	stamp_siblings zgui
}

build_playwright() {
	require "DemoVideoScript-Playwright" "${dpw_root}/src/main.ts"
	check_siblings playwright
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
	stamp_siblings playwright
}

backend_of() {
	case "$1" in
	terminal) echo "termassert" ;;
	gpui | zgui) echo "guiassert" ;;
	electron | firefox) echo "cmd:node ${build_dir}/scenario-arm/src/main.ts --binding ${root}/${S}/bindings/playwright/codetracer-binding.ts" ;;
	*)
		echo "scenarios: unknown flavour '$1' (terminal, gpui, zgui, electron, firefox)" >&2
		exit 64
		;;
	esac
}

runner_of() {
	case "$1" in
	terminal) echo "${bin}/dvs-termassert-codetracer" ;;
	gpui) echo "${bin}/dvs-guiassert-codetracer" ;;
	zgui) echo "${bin}/dvs-guiassert-codetracer-zgui" ;;
	electron | firefox) echo "${bin}/dvs" ;;
	esac
}

# browser_of <flavour>: the flavour's browser, for a scenario served to one
# (`deployment: web`). The firefox flavour is the electron flavour's arm and
# binding with the hosted page opened in Firefox (CT_SCENARIO_BROWSER, read
# by the binding); its lane lists the scenarios that serve a page.
browser_of() {
	case "$1" in
	firefox)
		local engines="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"
		if ! compgen -G "${engines}/firefox-*" >/dev/null; then
			echo "scenarios: the firefox flavour needs Playwright's Firefox, and ${engines} has none" >&2
			exit 1
		fi
		export CT_SCENARIO_BROWSER=firefox
		;;
	esac
}

case "${1:-}" in
build)
	# `build [dvs stage terminal gpui zgui playwright]`: all, or the named parts.
	shift
	parts=("$@")
	[ "${#parts[@]}" -gt 0 ] || parts=(dvs stage terminal gpui zgui playwright)
	for p in "${parts[@]}"; do "build_${p}"; done
	;;
lint)
	built_on_pin dvs || build_dvs
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
	# The desktop binding is TypeScript that Node loads as source when a run
	# starts: a syntax error in it (8e7d4ce79c8's stray `}`) fails every
	# desktop scenario at start-up, which the scenario lint above never sees.
	# Every Playwright binding file must parse; the Nim bindings are compiled
	# by `build`. The control: the binding with a stray `}` appended must not.
	parse_ts() {
		node -e '
			const src = require("fs").readFileSync(process.argv[1], "utf8");
			try { require("node:module").stripTypeScriptTypes(src); }
			catch (e) { console.error(process.argv[1] + ": " + e.message.split("\n")[0]); process.exit(1); }
		' "$1" 2>&1 | grep -v -e ExperimentalWarning -e 'node --trace-warnings'
		return "${PIPESTATUS[0]}"
	}
	for b in "${S}"/bindings/playwright/*.ts; do
		parse_ts "${b}" || {
			echo "scenarios: ${b} does not parse" >&2
			exit 1
		}
	done
	bad="$(mktemp --suffix=.ts)"
	{
		cat "${S}/bindings/playwright/codetracer-binding.ts"
		printf '\n}\n'
	} >"${bad}"
	if parse_ts "${bad}" >/dev/null 2>&1; then
		rm -f "${bad}"
		echo "scenarios: the binding parse check accepted a binding with a stray '}'" >&2
		exit 1
	fi
	rm -f "${bad}"
	echo "scenarios: the Playwright bindings parse; a stray '}' is rejected as it must be"
	;;
lane)
	flavour="${2:?usage: scenarios.sh lane <terminal|gpui|zgui|electron|firefox>}"
	runner="$(runner_of "${flavour}")"
	browser_of "${flavour}"
	[ -x "${runner}" ] || "$0" build
	ensure_built "${flavour}"
	# The desktop binding's own tests first: a reader that cannot read the
	# product's large panes in bounded time fails here, by name, rather than as
	# scenarios timing out.
	if [ "${flavour}" = electron ]; then "$0" binding-test || exit 1; fi
	"$0" stage-test || exit 1
	lane_file="${S}/lanes/${flavour}.lane.yaml"
	# SCENARIO_LANE_SHARD=i/n runs one shard of the lane: every n-th entry of
	# its `applicable:` list (ci/test/scenario-lane-shard.py), so a CI matrix
	# can split a lane that does not fit one job's time limit. The lane file
	# stays the one list; scenario-lane-shard-test.sh holds the shards to it.
	if [ -n "${SCENARIO_LANE_SHARD:-}" ]; then
		lane_file="$(python3 ci/test/scenario-lane-shard.py "${lane_file}" "${SCENARIO_LANE_SHARD}")"
		trap 'rm -f "${lane_file}"' EXIT
		echo "scenarios: shard ${SCENARIO_LANE_SHARD} of the ${flavour} lane:"
		sed -n '/^applicable:/,/^[^ ]/{s/^ *- /  /p}' "${lane_file}"
	fi
	"${runner}" lane "${lane_file}" --build "${build_dir}"
	;;
run)
	flavour="${2:?usage: scenarios.sh run <flavour> <scenario.yaml> [args]}"
	scenario="${3:?usage: scenarios.sh run <flavour> <scenario.yaml> [args]}"
	shift 3
	# One scenario runs with its lane's time limits, which the lane file says
	# why it needs (a software-rendered window settles slowly; a stage records
	# a program on a cold fixture cache). `run` once copied only the settle
	# limits, so a stage got dvs's default 120 s here and 300 s in the lane: a
	# fresh worktree's first `rr record` of pascal-sudoku took 121 s at load
	# 80 and failed. Arguments after the scenario come later and win.
	limits=()
	for key in settle-timeout stage-timeout; do
		value="$(sed -n "s/^${key}: *\([0-9][0-9]*\) *$/\1/p" "${S}/lanes/${flavour}.lane.yaml" 2>/dev/null | head -1)"
		if [ -n "${value}" ]; then limits+=("--${key}" "${value}"); fi
	done
	ensure_built "${flavour}"
	browser_of "${flavour}"
	"$(runner_of "${flavour}")" run "${scenario}" --pack "${S}/pack/codetracer.pack.yaml" \
		--backend "$(backend_of "${flavour}")" --build "${build_dir}" "${limits[@]}" "$@"
	;;
stage-test)
	# The stage tool's own tests (stages/*_test.nim): what a stage decides
	# without a product build (e.g. which fixture-cache entries are whole).
	rc=0
	for t in "${root}/${S}"/stages/*_test.nim; do
		echo "== ${t#"${root}/"}"
		nim c -r "${nim_common[@]}" --nimcache:"${nimcache}/stage-test-$(basename "${t}" .nim)" \
			-o:"${bin}/$(basename "${t}" .nim)" "${t}" || rc=1
	done
	exit "${rc}"
	;;
binding-test)
	# The bindings' own tests: what a binding reads from a real page, without a
	# product build (e.g. that a large pane is read in bounded time).
	rc=0
	while IFS= read -r t; do
		echo "== ${t#"${root}/"}"
		node "${t}" || rc=1
	done < <(find "${root}/${S}/bindings" -name '*.test.ts' | sort)
	exit "${rc}"
	;;
*)
	sed -n '2,24p' "$0"
	exit 64
	;;
esac
