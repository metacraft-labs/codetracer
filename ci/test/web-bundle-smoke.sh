#!/usr/bin/env bash
#
# web-bundle-smoke.sh — the web build, built and booted.
#
# NS2 (Noir-Studio.milestones.org) asks for a second build of one codebase, and
# recorded its absence as the milestone's largest unfinished item: "no CI
# recipe produces a web bundle, so `test_one_codebase_two_platforms` is
# unasserted, and nothing calls the web instantiation's boot()".
#
# This is the recipe. It builds `src/frontend/web_main.nim` with `nim js`,
# checks the property that makes it a WEB bundle rather than a desktop one that
# happens to compile, and then RUNS it — which is the only way to find out
# whether the boot sequence §4.2 and §4.5 specify actually completes.
#
# WHAT THIS DOES NOT CLAIM. `test_one_codebase_two_platforms` also asks that a
# pane added to one platform appear in the other. That needs the renderer, and
# the renderer imports `platform_host`, which imports `host/desktop_electron`
# under `when defined(js)` — so a browser build of the current renderer links
# `require('child_process')`. Splitting that import is separate work. This
# gate covers the boot sequence and the linkage property, and says so.
#
# WHY IT RUNS UNDER NODE AND NOT A BROWSER. Every browser binding `boot()`
# reaches is guarded (`typeof navigator`, `typeof document`, try/catch), so
# under node OPFS is absent and the boot takes §4.2's third row: the in-memory
# volume, and a session that announces it will lose work on close. That is a
# real product state — the one a user with storage disabled gets — and
# asserting it here costs no browser. A Chromium run belongs with the OPFS
# path, which `test_opfs_volume.nim` already drives under a fake global.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

out_dir="${CT_WEB_BUNDLE_DIR:-${repo_root}/src/build-debug/web}"
bundle="${out_dir}/web.js"
cache="$(ct_nim_cache_root "${repo_root}")/web-bundle"

failures=0
note() { printf '  %s\n' "$*"; }
ok() { printf '  [OK]     %s\n' "$*"; }
bad() {
	printf '  [FAILED] %s\n' "$*"
	failures=$((failures + 1))
}

echo "=== web bundle smoke (NS2: the second build) ==="
echo

command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH" >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}
command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH" >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}

mkdir -p "${out_dir}" "${cache}"

echo "Step 1: the web entry point builds with nim js -d:ctWeb"
echo "    -d:ctWeb selects platform_host's third arm. Without it this is an"
echo "    ELECTRON build of the same sources and step 2 below fails, which is"
echo "    how the define earns its place rather than being a spelling."
build_log="$(nim js -d:nodejs -d:ctWeb --hints:off --warnings:off \
	--path:src/frontend/viewmodel \
	--nimcache:"${cache}" -o:"${bundle}" src/frontend/web_main.nim 2>&1)"
build_status=$?
if [ "${build_status}" -ne 0 ] || [ ! -f "${bundle}" ]; then
	bad "the bundle did not build"
	printf '%s\n' "${build_log}" | grep -E 'Error:' | head -5 | sed 's/^/      /'
	echo
	echo "RESULT: FAILED — the web bundle does not build"
	exit 1
fi
bundle_bytes="$(wc -c <"${bundle}" | tr -d ' ')"
ok "built ${bundle} (${bundle_bytes} bytes)"
echo

# ---------------------------------------------------------------------------
echo "Step 2: the bundle links NO host bindings"
echo "    web_main.nim DOES import platform_host, like every other module in"
echo "    src/frontend/. That is the point of the three-way switch: under"
echo "    -d:ctWeb its arm imports no host module, so the front end's own"
echo "    platform accessor is usable from a web build. This step is the check"
echo "    on the SWITCH -- before it, the same import put 43 require() calls in."
# The positive control FIRST. Without it every negative grep below would also
# pass over a truncated or empty file, and "found nothing" would mean "looked at
# nothing" — the shape of check this repository keeps finding.
#
# The marker is the entry point's own SYMBOL, not one of its string literals.
# The first version of this check grepped for `codetracer-web-boot`, the boot
# line's prefix, and went red against a perfectly good bundle: Nim's JS backend
# does not guarantee that a source string literal survives as literal text in
# the output, and that `const` does not. A symbol the module exports does.
if grep -q "startWebSession" "${bundle}"; then
	ok "positive control: the bundle contains the entry point's own symbol, so the greps below are looking at real content"
else
	bad "positive control FAILED: 'startWebSession' is not in the bundle — the negative checks below would be vacuous"
fi

requires="$(grep -ao 'require(' "${bundle}" | wc -l | tr -d ' ')"
if [ "${requires}" = "0" ]; then
	ok "no require() in the bundle (0 occurrences)"
else
	bad "the bundle contains ${requires} require() calls — a browser has no module loader; something pulled a node-hosted module in"
fi

for forbidden in child_process ipcRenderer; do
	hits="$(grep -c "${forbidden}" "${bundle}")"
	if [ "${hits}" = "0" ]; then
		ok "no ${forbidden} in the bundle"
	else
		bad "the bundle mentions ${forbidden} ${hits} time(s)"
	fi
done
note "measured against the two-arm platform_host that preceded the three-way"
note "switch: the same sources built with -d:ctWeb produced 43 require() calls"
note "and 4 child_process mentions, so these checks fail on the real previous"
note "state rather than on a synthetic mutation."
echo

# ---------------------------------------------------------------------------
echo "Step 3: the bundle boots"
run_output="$(node "${bundle}" 2>&1)"
run_status=$?
boot_line="$(printf '%s\n' "${run_output}" | grep -a 'codetracer-web-boot:' | head -1)"

if [ "${run_status}" -ne 0 ]; then
	bad "node exited ${run_status}"
	printf '%s\n' "${run_output}" | head -10 | sed 's/^/      /'
fi

if [ -z "${boot_line}" ]; then
	bad "the bundle produced no boot line at all"
	printf '%s\n' "${run_output}" | head -10 | sed 's/^/      /'
else
	note "${boot_line}"
	case "${boot_line}" in
	*"codetracer-web-boot: ok "*)
		ok "boot() completed and installed a platform"
		;;
	*)
		bad "boot() did not complete: ${boot_line}"
		;;
	esac

	# THE FRONT END'S OWN ACCESSOR, not the boot result. `web_main.nim` reports
	# `ctPlatform()`, which is what every pane in `src/frontend/` uses; reading
	# `boot.web.platform` instead would say `pkWeb` even on a build where the
	# rest of the front end could not see it.
	#
	# NOTE THAT THIS CHECK AND THE require() CHECK CATCH DIFFERENT FAILURES, and
	# neither substitutes for the other. Measured against the two-arm
	# `platform_host` that preceded the switch: built with -d:ctWeb it produced
	# 43 require() calls AND `platform=pkWeb`, because the bootstrap fix already
	# stops `ctPlatform()` overwriting the installed web platform. So the
	# behaviour was right while the bundle linked Electron. Keeping only this
	# assertion would have shipped that bundle.
	case "${boot_line}" in
	*"platform=pkWeb"*)
		ok "ctPlatform() hands back the WEB platform, so the front end at large is on it"
		;;
	*)
		bad "the front end's own accessor did not return the web platform: ${boot_line}"
		;;
	esac

	# The capability the desktop has and the web must not: if the Electron
	# platform had been installed, this would be true.
	case "${boot_line}" in
	*"spawn=false"*)
		ok "and it does not claim capProcessSpawn, which an Electron platform would"
		;;
	*)
		bad "the running platform claims capProcessSpawn; a tab with no wasm module registry must not: ${boot_line}"
		;;
	esac

	# §4.2, and the reason this is asserted rather than just "it booted": with
	# no OPFS the session is volatile, and the specification requires that to be
	# stated BEFORE the first keystroke rather than discovered on close. The
	# announcement is that statement, so an empty one is a product defect even
	# though the boot succeeded.
	case "${boot_line}" in
	*"condition=scVolatile"*)
		ok "took the in-memory path, which is what a host without OPFS must do"
		case "${boot_line}" in
		*"announcement=(none)"*)
			bad "a volatile session announced nothing — §4.2 requires the loss to be stated before editing"
			;;
		*)
			ok "and it announces the loss before editing is possible"
			;;
		esac
		;;
	*)
		note "condition is not scVolatile; this host apparently has OPFS, which is fine"
		;;
	esac
fi
echo

if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the web bundle builds, links no host bindings, and boots"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
