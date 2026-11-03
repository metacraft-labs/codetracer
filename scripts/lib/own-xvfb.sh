# shellcheck shell=bash
# own-xvfb.sh — start a headless X server and hand its display to the caller
# only once the server accepts connections. Source it; it defines two
# functions and runs nothing.
#
#   trap 'own_xvfb_stop' EXIT          # first: a signal during the wait is covered
#   own_xvfb_start -screen 0 2560x1440x24 -dpi 96 -nolisten tcp || exit 1
#   ... DISPLAY is exported, OWN_XVFB_PID is the server ...
#
# Every script and recipe that starts its own Xvfb goes through here
# (`scripts/test-own-xvfb.sh` refuses one that does not). They used to pick a
# display by probing `/tmp/.X<n>-lock`, start the server and `sleep 1`; on a
# loaded host the clients started before the server accepted connections and
# failed with "Missing X server". A fixed sleep is either too short on a
# loaded host or wasted on an idle one, so readiness is the server's own
# signal instead: with `-displayfd <fd>` Xvfb picks a free display itself and
# writes its number and a newline to <fd> once it is ready to accept
# connections (Xserver(1), "-displayfd":
# https://www.x.org/releases/current/doc/man/man1/Xserver.1.xhtml). That also
# removes the race between two runs probing the same lock file.
#
# `CODETRACER_XVFB_WAIT_SECONDS` bounds the wait (default 60).

# own_xvfb_start <Xvfb arguments...>
#
# Starts `Xvfb -displayfd 3 <arguments...>` (the arguments must not name a
# display), waits until its display answers, exports `DISPLAY` and sets
# `OWN_XVFB_PID`. If the server exits first or the bound passes, it prints a
# message naming Xvfb with the server's own output, stops the server and
# returns 1, so a caller under `set -e` ends there and none of its clients
# starts. The server's output goes to a private log, shown only on failure.
own_xvfb_start() {
	local wait_seconds="${CODETRACER_XVFB_WAIT_SECONDS:-60}"
	case "$wait_seconds" in
	'' | *[!0-9]*)
		echo "FAIL: CODETRACER_XVFB_WAIT_SECONDS must be a whole number of seconds, not '$wait_seconds'" >&2
		return 1
		;;
	esac
	# Base 10 explicitly: bash arithmetic reads `08` as a bad octal number
	# and `010` as eight.
	wait_seconds=$((10#$wait_seconds))
	OWN_XVFB_STATE="$(mktemp -d "${TMPDIR:-/tmp}/own-xvfb.XXXXXX")" || {
		echo "FAIL: could not create a directory for Xvfb's display and log under ${TMPDIR:-/tmp}" >&2
		OWN_XVFB_STATE=""
		return 1
	}
	local display_file="$OWN_XVFB_STATE/display" log="$OWN_XVFB_STATE/xvfb.log"
	: >"$display_file"
	Xvfb -displayfd 3 "$@" 3>"$display_file" >"$log" 2>&1 &
	OWN_XVFB_PID=$!
	local deadline=$((SECONDS + wait_seconds)) display_num=""
	# `read` succeeds only on a complete line, so a number caught half
	# written is never taken.
	until IFS= read -r display_num <"$display_file" && [ -n "$display_num" ]; do
		if ! kill -0 "$OWN_XVFB_PID" 2>/dev/null; then
			echo "FAIL: Xvfb exited before its display answered; its output:" >&2
			cat "$log" >&2
			own_xvfb_stop
			return 1
		fi
		if [ "$SECONDS" -ge "$deadline" ]; then
			echo "FAIL: Xvfb's display did not answer within ${wait_seconds}s" \
				"(CODETRACER_XVFB_WAIT_SECONDS); its output:" >&2
			cat "$log" >&2
			own_xvfb_stop
			return 1
		fi
		sleep 0.1
	done
	export DISPLAY=":${display_num}"
}

# own_xvfb_stop
#
# Stops the server `own_xvfb_start` started and removes its log. Safe to call
# when none was started, and more than once, so an EXIT trap can call it
# unconditionally.
own_xvfb_stop() {
	if [ -n "${OWN_XVFB_PID:-}" ]; then
		kill "$OWN_XVFB_PID" 2>/dev/null || true
		OWN_XVFB_PID=""
	fi
	if [ -n "${OWN_XVFB_STATE:-}" ]; then
		rm -rf "$OWN_XVFB_STATE"
		OWN_XVFB_STATE=""
	fi
}
