#!/usr/bin/env bash
# Read a browser recording (`record-web`'s single-file `.ct`) for a fixture
# check, through the canonical CTFS decoder rather than a second one.
#
# Source this file, then:
#
#   resolve_ct_print            # sets CT_PRINT, or adds to the caller's `missing`
#   recording_full_json <ct>    # `ct-print --full <ct>`: every step, value,
#                               # call and event, with values decoded
#
# `ct-print` is the decoder the db-backend and every recorder's golden tests
# are held to, so a fixture check that reads through it is checking the same
# bytes the debugger will open.

# shellcheck disable=SC2034 # CT_PRINT is consumed by the sourcing script
resolve_ct_print() {
	CT_PRINT="${CODETRACER_CT_PRINT:-}"
	if [ -z "$CT_PRINT" ]; then
		local candidate
		for candidate in \
			"$WORKSPACE_ROOT/codetracer-trace-format-nim/ct-print" \
			"$(command -v ct-print 2>/dev/null || true)"; do
			if [ -n "$candidate" ] && [ -x "$candidate" ]; then
				CT_PRINT="$candidate"
				break
			fi
		done
	fi
	if [ -z "$CT_PRINT" ]; then
		missing+=("- ct-print is not built (just build in $WORKSPACE_ROOT/codetracer-trace-format-nim, or set CODETRACER_CT_PRINT)")
	fi
}

recording_full_json() {
	"$CT_PRINT" --full "$1"
}
