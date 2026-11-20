#!/usr/bin/env bash
# wtype-keys.sh <wtype arguments> — type REAL keys through the compositor's
# virtual keyboard, the one way every capture lane does it.
#
# Every `wtype` process is a NEW virtual keyboard, and a key it sends while the
# compositor is still handing the client that keyboard's keymap is LOST —
# silently, `wtype` exits 0. Measured three times:
#   * isonim-gpui `tests/test_gui_keyboard.nim`: an invocation with no leading
#     `-s` loses its keystroke (ci/test/plat38-keystroke.sh's header);
#   * plat44-sequences: about a third of the windows lost their first key until
#     a bare Shift press and release primed the keyboard;
#   * the VCS off-loop capture, 2026-11-18: in a window busy with its startup
#     work, two `wtype` calls' keys never reached the editor while an F12 sent
#     later did (the window existed and held the focus throughout).
# So each call PRIMES the new keyboard (Shift pressed and released: no text, no
# motion in any keymap) and then waits before the caller's keys.
#
#   WTYPE_LEAD_MS  the wait after the priming, before the keys (default 500)
#   WTYPE_PRIME=0  no Shift priming: for a lane whose oracle counts the
#                  modifier events themselves (plat38's delivery sequence)
#
# ci/test/wtype-keys-guard-test.sh refuses a lane that calls `wtype` directly.
set -euo pipefail

lead="${WTYPE_LEAD_MS:-500}"
if [ "${WTYPE_PRIME:-1}" = "1" ]; then
	exec wtype -M shift -m shift -s "${lead}" "$@"
fi
exec wtype -s "${lead}" "$@"
