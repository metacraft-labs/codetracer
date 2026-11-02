#!/usr/bin/env bash
# plat68-desktop-keys.sh starts its specs only once the Xvfb it started
# answers, and fails naming Xvfb when it never does.
#
# Without a DISPLAY the script starts an Xvfb. It used to sleep one second and
# then start Playwright, so on a loaded host the specs could start before the
# server accepted connections and fail with "Missing X server"
# (codetracer-pm issue 2026-10-31-plat68-desktop-keys-script-races-its-own-
# xvfb-start).
#
# The real plat68-desktop-keys.sh runs, with no DISPLAY, from a copy of this
# repository's layout. Three stand-ins replace what is not under test, each
# because the real thing needs a built desktop variant and minutes:
# `scripts/plat45-desktop-prefix.sh` (an empty prefix), `stylus` (writes
# nothing) and `npx` (the Playwright run: it probes the display with
# `xdotool getdisplaygeometry`, the X request the specs' Electron makes first,
# and fails as Playwright does when nothing answers). `Xvfb` on PATH is the
# REAL Xvfb behind a wrapper that can delay its start — the loaded host made
# reproducible — or stand in for a server that dies or never comes up.
#
# Asserted:
#   1. a real Xvfb that takes 3 s to start: the specs run once the display
#      answers, the script succeeds, and the Xvfb is gone afterwards;
#   2. an Xvfb that exits at once: the script fails at once, not when the
#      default 60 s bound passes, naming Xvfb, with the server's own output,
#      and never starts the specs;
#   3. an Xvfb that never answers: with PLAT68_XVFB_WAIT_SECONDS=3 the script
#      fails naming Xvfb within that bound, never starts the specs, and kills
#      the server.
#
# Linux only: elsewhere the script does not start an Xvfb. Needs Xvfb and
# xdotool, which the dev shell provides:
#
#   repro exec . -- bash scripts/test-plat68-desktop-keys-xvfb-start.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] ||
	fail "this test covers the Xvfb start, which plat68-desktop-keys.sh does on Linux only"
real_xvfb="$(command -v Xvfb)" || fail "no Xvfb on PATH — run inside the dev shell"
real_xdotool="$(command -v xdotool)" || fail "no xdotool on PATH — run inside the dev shell"

WORK="$(mktemp -d)"
cleanup() {
	# A server a failed case left behind is killed here, never someone else's:
	# the wrapper records the pid it became.
	if [ -f "$WORK/xvfb.pid" ]; then
		kill "$(cat "$WORK/xvfb.pid")" 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT

CT="$WORK/codetracer"
mkdir -p "$CT/scripts" "$CT/src/config" "$CT/src/tests/gui" \
	"$CT/node_modules/.bin" "$WORK/bin" "$WORK/built/styles" "$WORK/fixtures/calc-0"
cp "$REPO/scripts/plat68-desktop-keys.sh" "$CT/scripts/"
cat >"$CT/scripts/plat45-desktop-prefix.sh" <<SH
mkdir -p "\$1"
ln -s "$WORK/built" "\$1/frontend"
SH
printf '#!/bin/sh\nexit 0\n' >"$CT/node_modules/.bin/stylus"
chmod +x "$CT/node_modules/.bin/stylus"

# The Playwright stand-in: did a display answer when the specs started?
cat >"$WORK/bin/npx" <<SH
#!/usr/bin/env bash
echo "\${DISPLAY:-}" >"$WORK/specs-started"
"$real_xdotool" getdisplaygeometry >/dev/null 2>&1 || {
	echo "Missing X server or \\\$DISPLAY" >&2
	exit 1
}
SH
# The Xvfb wrapper. XVFB_MODE: delay (start the real server after
# XVFB_DELAY s), die (exit at once) or hang (never answer). It execs, so the
# pid the script holds is the server's. A hang lasts 60 s, not forever: a
# script that ignored its bound then sees the server exit, and fails the 15 s
# check below instead of hanging the test.
cat >"$WORK/bin/Xvfb" <<SH
#!/usr/bin/env bash
echo \$\$ >"$WORK/xvfb.pid"
case "\$XVFB_MODE" in
delay) sleep "\$XVFB_DELAY"; exec "$real_xvfb" "\$@" ;;
die) echo "stand-in Xvfb: cannot open the display" >&2; exit 1 ;;
hang) exec sleep 60 ;;
esac
SH
chmod +x "$WORK/bin/npx" "$WORK/bin/Xvfb"

# run_case <mode> [VAR=value...] — runs the script, leaving its exit status in
# `status` and its stderr in $WORK/stderr.
run_case() {
	local mode="$1"
	shift
	rm -f "$WORK/specs-started" "$WORK/xvfb.pid"
	status=0
	env -u DISPLAY -u PLAT68_XVFB_WAIT_SECONDS PATH="$WORK/bin:$PATH" XVFB_MODE="$mode" \
		PLAT68_FIXTURES_DIR="$WORK/fixtures" "$@" \
		bash "$CT/scripts/plat68-desktop-keys.sh" >"$WORK/stdout" 2>"$WORK/stderr" ||
		status=$?
}

# A server is gone once its pid is gone, or is a zombie (state Z in
# /proc/<pid>/stat, proc(5)) its new parent has not reaped yet: `kill -0`
# succeeds on a zombie, which has nonetheless stopped serving.
assert_server_gone() {
	local pid state
	pid="$(cat "$WORK/xvfb.pid")"
	for _ in $(seq 50); do
		kill -0 "$pid" 2>/dev/null || return 0
		state="$(sed -n "s/^[0-9]* (.*) \([A-Za-z]\) .*/\1/p" "/proc/$pid/stat" 2>/dev/null || true)"
		[ "$state" != Z ] || return 0
		sleep 0.1
	done
	fail "$1: the Xvfb (pid $pid) outlived the script"
}

# 1. A slow but working server.
run_case delay XVFB_DELAY=3
[ -f "$WORK/specs-started" ] || fail "slow Xvfb: the specs never started: $(cat "$WORK/stderr")"
[ "$status" -eq 0 ] ||
	fail "slow Xvfb: the specs started before the display answered (exit $status): $(cat "$WORK/stderr")"
assert_server_gone "slow Xvfb"

# 2. A server that dies: the script notices at once, not when the default
# 60 s bound passes.
started=$SECONDS
run_case die
took=$((SECONDS - started))
[ "$status" -ne 0 ] || fail "dead Xvfb: the script succeeded"
[ ! -f "$WORK/specs-started" ] || fail "dead Xvfb: the specs started without a display"
grep -q "Xvfb" "$WORK/stderr" || fail "dead Xvfb: the failure does not name Xvfb: $(cat "$WORK/stderr")"
grep -q "cannot open the display" "$WORK/stderr" ||
	fail "dead Xvfb: the failure does not carry the server's output: $(cat "$WORK/stderr")"
[ "$took" -le 15 ] ||
	fail "dead Xvfb: the script took ${took}s to notice the server had exited"

# 3. A server that never answers.
started=$SECONDS
run_case hang PLAT68_XVFB_WAIT_SECONDS=3
took=$((SECONDS - started))
[ "$status" -ne 0 ] || fail "silent Xvfb: the script succeeded"
[ ! -f "$WORK/specs-started" ] || fail "silent Xvfb: the specs started without a display"
grep -q "Xvfb" "$WORK/stderr" || fail "silent Xvfb: the failure does not name Xvfb: $(cat "$WORK/stderr")"
[ "$took" -le 15 ] || fail "silent Xvfb: the script took ${took}s against a 3s bound"
assert_server_gone "silent Xvfb"

echo "PASS: plat68-desktop-keys.sh waits for its Xvfb to answer and names it when it never does"
