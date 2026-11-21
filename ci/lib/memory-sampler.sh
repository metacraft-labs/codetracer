#!/usr/bin/env bash
# memory-sampler.sh LOG [INTERVAL] -- every INTERVAL seconds (15), append to LOG
# the job's memory use and its top processes by resident memory, until killed.
#
# Started in the background by the TUI and GPUI shard jobs. A runner VM that
# reaches its 20 GiB cap has the kernel OOM-kill processes in it, and the runner
# memory guard's annotation names none of them (TUI shard 5/8 of run
# 43996043232). The last samples before such a kill name what held the memory;
# the job uploads LOG when it does not succeed.
#
# Best effort: it never fails the job. It ends with the job: when the job's
# Runner.Worker is gone (ci/lib/job-lifetime.sh), since a persistent runner
# does not end it.
set -u
# shellcheck source=ci/lib/job-lifetime.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/job-lifetime.sh"
log="${1:?usage: memory-sampler.sh LOG [INTERVAL]}"
interval="${2:-15}"
top="${MEMORY_SAMPLER_TOP:-15}"

total() {
	local f
	for f in /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory/memory.usage_in_bytes; do
		if [ -r "$f" ]; then
			echo "cgroup $(($(cat "$f") / 1048576)) MiB ($f)"
			return
		fi
	done
	awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "host used %d MiB of %d MiB\n", (t-a)/1024, t/1024}' /proc/meminfo
}

while job_still_running; do
	{
		echo "=== $(date -u +%FT%TZ) $(total 2>/dev/null)"
		# rss in KiB; args truncated so one line stays one line.
		ps -eo pid,ppid,rss,etimes,comm,args --sort=-rss 2>/dev/null |
			awk -v n="$((top + 1))" 'NR <= n { line = $0; if (length(line) > 240) line = substr(line, 1, 240) "..."; print line }'
	} >>"$log" 2>/dev/null
	sleep "$interval"
done
