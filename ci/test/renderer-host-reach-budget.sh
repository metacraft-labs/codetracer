#!/usr/bin/env bash
#
# renderer-host-reach-budget.sh — NS1's residual 1, as a ratchet.
#
# NS1 put every host-facing capability behind a facade and left the call-site
# migration for later; every milestone since has deferred it. It is now the
# thing standing between the web bundle and a rendered pane
# (Noir-Studio.milestones.org NS2), so it needs to be measurable and it needs
# to be unable to grow.
#
# THIS SCRIPT IS THE COUNTING RULE. The rule used to live in prose in the
# milestone file, and prose is not enforcement: a looser grep over the same
# region returns nearly half again as many hits, and the extra ones are not
# host access at all. Someone re-deriving the number from a plausible grep
# chases modules that are already fine. So the rule lives here, where it runs,
# and the milestone file points at this file rather than restating it.
#
# ## The rule
#
# REGION: src/frontend/, minus four directories, each excluded for a reason:
#   index/                 the Electron MAIN process. It *is* the desktop
#                          instantiation's host side; the web has no
#                          counterpart to migrate. NS1's survey excludes it
#                          for the same reason and says so.
#   viewmodel/host/        the host modules. They exist to touch the host.
#   tests/, viewmodel/tests/  test code.
#
# COUNTED: a require() of a NODE BUILT-IN or of Electron (fs, child_process,
# os, path, electron, and the ./helpers node shim), and the Electron renderer
# APIs (ipcRenderer, dialog, app, clipboard, shell). Comment lines do not
# count.
#
# NOT COUNTED, and this is the half that matters:
#   * a require() of a BUNDLED JAVASCRIPT LIBRARY. `require("tippy.js")` in
#     ui/flow.nim and `require("js-yaml")` in lib/misc_lib.nim are npm packages
#     a bundler resolves; they run in a browser today and are not host access.
#     A rule that counted every `require(` would report them as work to do.
#   * `globalThis.process` reads that are already guarded, as in hmr_runtime.
#   * path ARITHMETIC (parentDir, joinPath, splitFile). NS1's poison list
#     declares those three exclusions too; they are not host capabilities.
#
# ## Why a ratchet and not a target
#
# The budget below is the measured present, not a goal. The gate fails when a
# module goes UP, which is the property that keeps the number honest while the
# migration proceeds module by module — and it fails when a module goes DOWN
# without the budget being lowered, so a completed migration cannot be left
# uncredited and silently re-grown later.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

failures=0
ok() { printf '  [OK]     %s\n' "$*"; }
bad() {
	printf '  [FAILED] %s\n' "$*"
	failures=$((failures + 1))
}
note() { printf '  %s\n' "$*"; }

# The pattern IS the rule. Kept as one string so there is exactly one place to
# change it, and so the controls below test the same string the count uses.
HOST_PATTERN="require\\((['\"])(fs|child_process|os|path|electron|\\./helpers)\\1\\)|electron\\.(ipcRenderer|dialog|app|clipboard|shell)|\\bipcRenderer\\b|app\\.getPath|dialog\\.show"

# Requires that are NOT host access. Listed by name so the exclusion is a
# decision rather than an accident of the pattern.
LIBRARY_REQUIRES='tippy\.js|js-yaml'

renderer_region() {
	find src/frontend -name '*.nim' \
		-not -path 'src/frontend/index/*' \
		-not -path 'src/frontend/viewmodel/host/*' \
		-not -path 'src/frontend/tests/*' \
		-not -path 'src/frontend/viewmodel/tests/*' | sort
}

count_in() {
	# Comment lines are dropped BEFORE counting: this file's own prose quotes
	# `require('fs')` several times, and a rule that counted its own
	# documentation would grow every time someone explained it.
	grep -nE "${HOST_PATTERN}" "$1" 2>/dev/null | grep -cvE "^[0-9]+: *##?"
}

# ---------------------------------------------------------------------------
# THE BUDGET. One line per module that still reaches the host, with what it
# needs. Lowering a number here is how a migration is recorded.
#
# `facade`  — a consumer reaching past its platform. The facade already has the
#             operation; the call site should be `ctPlatform()`. These are the
#             ones that make the renderer buildable for a browser.
# `exclude` — a module that SHOULD NOT be migrated. Either it exists to wrap
#             the host (lib/electron_lib.nim), or it is desktop-test machinery
#             (ui/agentic_worktree_test_hooks.nim), or it implements a
#             capability the web profile does not have at all
#             (subwindow.nim and ui/panel_transfer.nim are multi-window IPC,
#             and `capMultiWindow` is absent on web). The right treatment is a
#             `when` that keeps them out of a web build, not a facade arm that
#             would promise what a tab cannot do.
# ---------------------------------------------------------------------------
budget_for() {
	case "$1" in
	src/frontend/lib/electron_lib.nim) echo "5 exclude" ;;
	# 3 -> 1. `readFileUtf8` now goes through `ctPlatform().fs.readText` and the
	# dead `loadFileDialog` is gone. What remains is `ipc = electron.ipcRenderer`
	# inside `if inElectron:` — the IPC transport to the Electron main process,
	# which the web has no counterpart to and must not pretend to have.
	src/frontend/renderer.nim) echo "1 exclude" ;;
	src/frontend/subwindow.nim) echo "1 exclude" ;;
	# STILL `facade`, and deliberately not migrated in the same pass:
	# `ui_js.nim` does not compile standalone in the dev shell (it needs the tup
	# build's generated sources; on `dev` it fails at `resolvePendingDapResponse`
	# before any of this), so an edit here could not be verified. Both sites are
	# already written as `(typeof require === 'function') && ...`, so they are
	# runtime-safe in a browser and merely emit `require` into a bundle — the
	# least urgent two of the set. They want `fs.exists` / `fs.readText` through
	# `ctAwaitSync`, since both callers are synchronous.
	src/frontend/ui_js.nim) echo "2 facade" ;;
	src/frontend/ui/agentic_worktree_test_hooks.nim) echo "3 exclude" ;;
	src/frontend/ui/panel_transfer.nim) echo "7 exclude" ;;
	*) echo "0 none" ;;
	esac
}

echo "=== renderer host-reach budget (NS1 residual 1) ==="
echo

# ---------------------------------------------------------------------------
echo "Step 1: the rule can see a host reach, and does not see a library"
# Both directions. Without the first, a pattern that matched nothing would
# report a clean tree; without the second, the exclusion is untested and the
# next person to widen the pattern silently adds phantom work.
if [ "$(count_in src/frontend/subwindow.nim)" -ge 1 ]; then
	ok "positive control: the pattern finds the known electron.ipcRenderer in subwindow.nim"
else
	bad "positive control FAILED: the pattern no longer matches a reach that is present — every count below is meaningless"
fi

# shellcheck disable=SC2126 # -o emits one line PER OCCURRENCE, which is what is
# being counted here; `grep -c` counts matching LINES and would undercount two
# library requires on one line.
lib_hits="$(grep -rhoE "require\\((['\"])(${LIBRARY_REQUIRES})\\1\\)" src/frontend --include='*.nim' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${lib_hits}" -ge 2 ]; then
	ok "the excluded library requires still exist (${lib_hits} found), so the exclusion is doing work"
else
	bad "the library requires this rule deliberately excludes are gone (${lib_hits} found); the exclusion is now vacuous and should be removed rather than left looking meaningful"
fi

lib_counted="$(grep -rhE "require\\((['\"])(${LIBRARY_REQUIRES})\\1\\)" src/frontend --include='*.nim' 2>/dev/null | grep -cE "${HOST_PATTERN}")"
if [ "${lib_counted}" = "0" ]; then
	ok "and none of them is counted as host access"
else
	bad "${lib_counted} bundled-library require(s) are being counted as host access; the rule has drifted"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: no module reaches the host more than its budget"
total=0
budget_total=0
while IFS= read -r file; do
	n="$(count_in "${file}")"
	[ "${n}" = "0" ] && continue
	read -r allowed kind <<<"$(budget_for "${file}")"
	total=$((total + n))
	budget_total=$((budget_total + allowed))
	if [ "${n}" -gt "${allowed}" ]; then
		bad "${file}: ${n} reaches, budget ${allowed} (${kind}) — a new one was added"
		grep -nE "${HOST_PATTERN}" "${file}" | grep -vE "^[0-9]+: *##?" | sed 's/^/        /' | head -12
	elif [ "${n}" -lt "${allowed}" ]; then
		bad "${file}: ${n} reaches, budget ${allowed} (${kind}) — MIGRATED but the budget was not lowered. Lower it in budget_for(), so the work is recorded and cannot be silently undone."
	else
		note "${file}: ${n} (${kind})"
	fi
done < <(renderer_region)

if [ "${total}" = "${budget_total}" ]; then
	ok "total ${total}, matching the budget exactly"
else
	bad "total ${total} against a budget of ${budget_total}"
fi
echo

if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — ${total} host reaches in the renderer region, none new"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
