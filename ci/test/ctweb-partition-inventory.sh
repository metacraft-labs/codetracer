#!/usr/bin/env bash
# THE `-d:ctWeb` PARTITION IS AN INVENTORY, AND IT MUST NOT GROW — WD1c §7.5.
#
# ## Why this gate exists
#
# `UI-Bundle-And-Endpoints.md` §7.5 wants one bundle across all three
# deployments, which means `-d:ctWeb` stops being a compile-time partition. It
# also says that item is "most likely to be deferred, because the two arms
# currently compile against different modules rather than merely behaving
# differently", and on 2026-10-01 the owner decided to defer it with the
# measurement attached rather than reverse three `{.error.}` refusals and the
# web bundle gate.
#
# A deferral with no gate is how an inventory becomes a habit. The thing that
# must not happen is a FOURTEENTH-plus branch appearing because `when
# defined(ctWeb)` was the quickest way past a problem — each one makes the
# convergence larger, and nothing would report it.
#
# So this is not a style check. It is the deferral's own boundary: the set is
# allowed to shrink freely and may only grow by editing this file, which puts
# the decision in a diff somebody reads.
#
# ## Why it counts BRANCHES and not mentions
#
# Three places in `ui_js.nim` name `defined(ctWeb)` inside a comment, explaining
# the partition. A grep for the string alone would count those, so the count
# would move whenever somebody reworded a comment — a gate that fires on prose
# teaches people to stop reading it. Only `when` and `elif` lines count.
#
# ## What the per-file expectation buys over a total
#
# A total alone passes when one site is removed from `platform_host.nim` and
# another is added to `ui/`. The direction matters: a new branch under `ui/`
# means a PANEL can tell which deployment it is in, which is the property
# `test_the_panels_cannot_tell_which_deployment_they_are_in` is about and the one
# this campaign is least willing to lose.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The inventory as measured at codetracer 29b37c032. Shrinking is free; growing
# means editing this table, deliberately.
#
#   frontend/ui_js.nim                        5  the renderer entry: the
#                                                socket.io arm (§7.5's own
#                                                example) and four siblings
#   frontend/platform_host.nim                2  the host-module switch and the
#                                                bootstrap that matches it
#   frontend/ui/layout.nim                    2  the `panel_transfer` import and
#                                                its one call site
#   frontend/ui/shortcuts.nim                 1  ctrl+b re-record, which needs
#                                                capProcessArbitraryPrograms
#   frontend/ui/panel_transfer.nim            1  {.error.}: capMultiWindow is
#                                                absent on the web, so a facade
#                                                arm could only ever refuse
#   frontend/ui/agentic_worktree_test_hooks.nim 1 {.error.}: a desktop TEST
#                                                bridge, not product surface
#   frontend/subwindow.nim                    1  {.error.}: a second window
#   frontend/lib/electron_lib.nim             1  {.error.}: Electron itself
expected="frontend/lib/electron_lib.nim 1
frontend/platform_host.nim 2
frontend/subwindow.nim 1
frontend/ui/agentic_worktree_test_hooks.nim 1
frontend/ui/layout.nim 2
frontend/ui/panel_transfer.nim 1
frontend/ui/shortcuts.nim 1
frontend/ui_js.nim 5"

actual="$(
	grep -rn 'defined(ctWeb)' src/ |
		grep -v '/tests/' |
		grep -E ':[[:space:]]*(when|elif)' |
		sed 's|^src/||' |
		awk -F: '{print $1}' |
		sort | uniq -c |
		awk '{print $2, $1}' |
		LC_ALL=C sort
)"
expected_sorted="$(printf '%s\n' "${expected}" | LC_ALL=C sort)"

if [ "${actual}" = "${expected_sorted}" ]; then
	total="$(printf '%s\n' "${actual}" | awk '{s += $2} END {print s}')"
	echo "ok: the ctWeb partition is ${total} branches across $(printf '%s\n' "${actual}" | wc -l) files, as recorded"
	exit 0
fi

echo "the -d:ctWeb partition has changed." >&2
echo >&2
diff <(printf '%s\n' "${expected_sorted}") <(printf '%s\n' "${actual}") >&2 || true
echo >&2
echo "If a branch was REMOVED, that is convergence: delete its row above and say so." >&2
echo "If one was ADDED, it is a new compile-time fork between the web deployment" >&2
echo "and the other two, and §7.5 wants fewer of those rather than more. A panel" >&2
echo "that can tell which deployment it is in is the property" >&2
echo "test_the_panels_cannot_tell_which_deployment_they_are_in exists for; prefer" >&2
echo "a capability query (ctPlatform().can(...)) over a define." >&2
exit 1
