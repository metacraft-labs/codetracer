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
# WHY THE KEY IS LOST (measured 2026-11-22, WAYLAND_DEBUG=client on a real GPUI
# window): the headless sway has no keyboard of its own, so a `wtype` call
# HOT-PLUGS the seat's only keyboard. The client has a `wl_keyboard` to receive
# keys on only after it has read the seat's new capability and answered with
# `wl_seat.get_keyboard`; a key sent before that reaches no one, and when
# `wtype` exits the capability goes and the next call starts over. A window too
# busy to read its socket for the lead therefore loses the call's keys whatever
# the priming: a window SIGSTOPped across one call lost its key 3 times of 3.
# A user's keyboard stays plugged in, so this is the injection's artefact, not
# the window's. The cure is to HOLD a keyboard for the whole run (`wtype -s
# 3600000` in the background, which creates its virtual keyboard and sleeps):
# with one held, the same stalled window received its key 3 times of 3, because
# the key waits in its socket. `ci/test/gpui_plugins_window.py` does that
# (`hold_keyboard`), through `--hold` below. Not done for every call: a
# per-call script cannot hold one across calls, and plat38's oracle counts the
# keyboard's own events.
#
#   --hold MS      hold the seat's keyboard for MS milliseconds and type
#                  nothing (`wtype -s MS`): run it in the background for the
#                  length of a capture; the process is that `wtype`, so killing
#                  it releases the keyboard
#   WTYPE_LEAD_MS  the wait after the priming, before the keys (default 500)
#   WTYPE_PRIME=0  no Shift priming: for a lane whose oracle counts the
#                  modifier events themselves (plat38's delivery sequence)
#
# ci/test/wtype-keys-guard-test.sh refuses a lane that calls `wtype` directly.
set -euo pipefail

if [ "${1:-}" = --hold ]; then
	ms="${2:?usage: wtype-keys.sh --hold <milliseconds>}"
	exec wtype -s "${ms}"
fi
lead="${WTYPE_LEAD_MS:-500}"
if [ "${WTYPE_PRIME:-1}" = "1" ]; then
	exec wtype -M shift -m shift -s "${lead}" "$@"
fi
exec wtype -s "${lead}" "$@"
