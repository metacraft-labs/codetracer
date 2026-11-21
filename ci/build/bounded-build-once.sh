#!/usr/bin/env bash
# ci/build/bounded-build-once.sh DIAG_DIR FIRST_MINUTES SECOND_MINUTES
#
# `just build-once` for CI, bounded, and on a stall: evidence, then one retry
# without the repro daemon.
#
# In run 44577379303 ct-build's build-once ran 157 minutes under repro 0.2.27
# and was cancelled at the job's limit at `checked=35/42 running=8`, with
# nothing in the log to say which actions were stuck or why; under repro
# 0.2.25 the same step finished in 32 minutes (run 44444132651). A local
# build-once under 0.2.27 hung in the user repro-daemon, whose worker's
# reprobuild-nix child was a zombie (reprobuild-pm 4c263eed).
#
#  1. build-once with the daemon (the default), killed after FIRST_MINUTES;
#  2. if it was killed: the daemon's status, sessions and log, the process
#     tree and any zombies, into DIAG_DIR (the workflow uploads it);
#  3. then build-once again with REPRO_DAEMON=off, killed after
#     SECOND_MINUTES -- the candidate workaround, measured in the same run.
#
# FIRST_MINUTES=0 skips step 1 and builds without the daemon straight away.
#
# Each attempt's duration and outcome is printed as `bounded-build-once:`
# lines, so the two modes can be compared from the log. Exits with the last
# attempt's status (124 when it was killed).
set -uo pipefail

diag="${1:?usage: bounded-build-once.sh DIAG_DIR FIRST_MINUTES SECOND_MINUTES}"
first="${2:?usage: bounded-build-once.sh DIAG_DIR FIRST_MINUTES SECOND_MINUTES}"
second="${3:?usage: bounded-build-once.sh DIAG_DIR FIRST_MINUTES SECOND_MINUTES}"
mkdir -p "$diag"

attempt() { # attempt LABEL MINUTES [ENV=VALUE...]
	# The build runs in a process group of its own, and at the bound its state
	# is dumped WHILE IT IS STILL ALIVE, then the group is terminated. (With
	# `timeout`, the dump ran after the kill and showed none of the stalled
	# build: run 44648381899's dump held the host's processes and not one of
	# build-once's.)
	local label="$1" minutes="$2"
	shift 2
	local start deadline pid rc
	start=$(date +%s)
	deadline=$((start + $(awk -v m="$minutes" 'BEGIN { printf "%d", m * 60 }')))
	echo "bounded-build-once: ${label}: start ($*; bound ${minutes}m)"
	setsid env "$@" just build-once &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$(date +%s)" -ge "$deadline" ]; then
			dump "${label}-stall" "$pid"
			kill -TERM -- "-$pid" 2>/dev/null
			local grace=$(($(date +%s) + 60))
			while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$grace" ]; do sleep 1; done
			kill -KILL -- "-$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			echo "bounded-build-once: ${label}: exit 124 after $((($(date +%s) - start) / 60))m (bound reached)"
			return 124
		fi
		sleep 2
	done
	wait "$pid"
	rc=$?
	echo "bounded-build-once: ${label}: exit ${rc} after $((($(date +%s) - start) / 60))m"
	return "$rc"
}

dump() { # dump LABEL [BUILD_PID]
	local out="$diag/$1" build="${2:-}"
	mkdir -p "$out"
	echo "bounded-build-once: dumping the stall's state into $out"
	ps -ef --forest >"$out/ps-forest.txt" 2>&1
	# The stalled build's own subtree, so the evidence is not lost in a shared
	# host's process table.
	if [ -n "$build" ]; then
		ps -o pid,ppid,stat,etimes,pcpu,cmd -g "$build" >"$out/build-tree.txt" 2>&1
	fi
	ps -eo pid,ppid,stat,etimes,cmd | awk 'NR == 1 || $3 ~ /Z/' >"$out/zombies.txt" 2>&1
	{
		repro daemon status
		echo "--- sessions"
		repro daemon sessions
	} >"$out/repro-daemon.txt" 2>&1
	repro daemon logs >"$out/repro-daemon-log.txt" 2>&1
	echo "bounded-build-once: zombies: $(($(wc -l <"$out/zombies.txt") - 1))"
	sed -n '1,20p' "$out/zombies.txt"
}

# FIRST_MINUTES=0 skips the daemon attempt: build without the daemon at once.
if [ "$first" != 0 ]; then
	attempt daemon "$first"
	rc=$?
	if [ "$rc" -ne 124 ]; then
		exit "$rc"
	fi
	# The stalled daemon's sessions must not hold the retry's locks.
	repro daemon stop >/dev/null 2>&1 || true
fi
attempt no-daemon "$second" REPRO_DAEMON=off
exit $?
