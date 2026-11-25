#!/usr/bin/env bash
# NOT-A-CI-GATE: a command prefix the justfile's rq variables name, not a check; ci/test/runquota-bridge-test.sh is the gate over it.
# runquota-bridge.sh -- run a heavy command under a RunQuota lease when one is available.
#
#   runquota-bridge.sh run       [FLAGS] -- CMD [ARG...]   CMD takes a width flag (cargo nextest -j,
#                                                          playwright --workers, nim, nix, ...)
#   runquota-bridge.sh jobserver [FLAGS] -- CMD [ARG...]   CMD follows a GNU make jobserver
#                                                          (plain `cargo`, make, ninja)
#   runquota-bridge.sh active VERB                         exit 0 if VERB would take a lease
#
# It `exec`s either `runquota VERB FLAGS -- CMD` or plain `CMD`, so the command's standard output
# and exit status are untouched (a caller may capture the output with `$(...)`, or test `$?`), and
# where RunQuota is not installed the command runs exactly as it did before.
#
# WHY. Several checkouts, agent sessions and CI jobs on one machine each assume every core is
# theirs, so together they oversubscribe it. Under a lease the command takes its slots from the
# host's shared budget, waits its turn, and runs at the width it was granted. The recipes in the
# justfile reach this through the `rq`, `rq1` and `rqj` variables defined at its top.
#
# CONTROL (environment of whoever runs the recipe).
#   RQ unset     automatic: take a lease when the installed `runquota` has the verb
#   RQ=          (empty) off: run the command directly
#   RQ="PREFIX"  any other value replaces `runquota VERB FLAGS --`, for example
#                RQ="runquota run --width 2 --" to pin a width
#
# PROBE THE VERB, NOT THE BINARY. A `runquota` that predates a verb prints its usage and exits 0
# instead of rejecting the word, so a bridged recipe would "pass" without running anything. The
# probes below ask something only a build that has the verb answers, and neither takes a lease:
#   jobserver  with no command prints `runquota jobserver: missing command`
#   run        `--adapter list` prints a table that starts with `adapters`
#
# ONE BRIDGE PER COMMAND CHAIN, at the command that does the work and not around a whole script:
# a lease is held for the command's whole life. A `run` started inside a `jobserver` would queue
# behind the command that started it, so nest `jobserver` inside `run`, never the reverse.
#
# Documentation of the idiom: the "RunQuota in Justfiles" guide of the reprobuild project.
set -uo pipefail

_rq_verb_available() { # <verb>
	command -v runquota >/dev/null 2>&1 || return 1
	# Captured rather than piped into `grep -q`: under pipefail grep's early exit would
	# SIGPIPE the writer and read as "verb absent".
	local out
	case "$1" in
	jobserver)
		out="$(runquota jobserver 2>&1 </dev/null)" || true
		case "${out}" in *'runquota jobserver: missing command'*) return 0 ;; esac
		;;
	run)
		out="$(runquota run --adapter list 2>/dev/null </dev/null)" || true
		case "${out}" in adapters* | *$'\nadapters'*) return 0 ;; esac
		;;
	esac
	return 1
}

# 0 when VERB would take a lease under the current RQ setting.
_rq_active() { # <verb>
	if [ "${RQ+set}" = set ]; then
		[ -n "${RQ}" ]
	else
		_rq_verb_available "$1"
	fi
}

if [ "${1:-}" = active ]; then
	[ $# -eq 2 ] || {
		echo "usage: runquota-bridge.sh active VERB" >&2
		exit 2
	}
	_rq_active "$2"
	exit $?
fi

verb="${1:-}"
case "${verb}" in
jobserver | run) shift ;;
*)
	echo "usage: runquota-bridge.sh {run|jobserver} [FLAGS] -- CMD [ARG...]" >&2
	exit 2
	;;
esac

flags=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
	flags+=("$1")
	shift
done
[ "${1:-}" = "--" ] || {
	echo "runquota-bridge.sh: missing '--' before the command" >&2
	exit 2
}
shift
[ $# -gt 0 ] || {
	echo "runquota-bridge.sh: missing command" >&2
	exit 2
}

if [ "${RQ+set}" = set ]; then
	if [ -n "${RQ}" ]; then
		# shellcheck disable=SC2086 # the prefix is a command line on purpose
		exec ${RQ} "$@"
	fi
	exec "$@"
fi
if _rq_verb_available "${verb}"; then
	exec runquota "${verb}" ${flags[@]+"${flags[@]}"} -- "$@"
fi
exec "$@"
