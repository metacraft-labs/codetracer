#!/usr/bin/env bash
#
# job-pool.sh — how many test files a runner may build and run at once.
#
# Sourced by ci/lib/run-nim-test-lane.sh and ci/test/vm-unit-wasm-parity.sh.
#
# ct_pool_size MB_PER_JOB prints the pool size: the CPUs, bounded by the
# memory available at MB_PER_JOB per job, and at least 1. CT_LANE_JOBS sets it
# outright (CT_LANE_JOBS=1 is the old one-file-at-a-time behaviour). A pool of
# more than one needs `wait -n`, which bash has from 4.3; the /bin/bash macOS
# ships is 3.2, so there the answer is 1 whatever the host offers.
#
# ct_pool_parallel_build POOL prints the value for Nim's `--parallelBuild`
# that shares the CPUs between POOL compiles: each `nim c` otherwise starts
# one C compiler per CPU, and POOL of them would start POOL times as many.

ct_pool_cpus() {
	local n=""
	n="$(nproc 2>/dev/null)" ||
		n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" ||
		n="$(sysctl -n hw.ncpu 2>/dev/null)" || n=1
	case "${n}" in '' | *[!0-9]*) n=1 ;; esac
	[ "${n}" -ge 1 ] || n=1
	echo "${n}"
}

ct_pool_size() {
	local per_job_mb="${1:-2048}" n cpus avail_kb by_mem
	if [ -n "${CT_LANE_JOBS:-}" ]; then
		case "${CT_LANE_JOBS}" in
		'' | *[!0-9]* | 0)
			echo "job-pool: CT_LANE_JOBS must be a positive integer, got '${CT_LANE_JOBS}'" >&2
			return 2
			;;
		esac
		n="${CT_LANE_JOBS}"
	else
		cpus="$(ct_pool_cpus)"
		n="${cpus}"
		avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)"
		if [ -n "${avail_kb}" ]; then
			by_mem=$((avail_kb / (per_job_mb * 1024)))
			[ "${by_mem}" -lt "${n}" ] && n="${by_mem}"
		fi
	fi
	[ "${n}" -ge 1 ] || n=1
	if [ "${n}" -gt 1 ] && { [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
		{ [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; }; then
		n=1
	fi
	echo "${n}"
}

ct_pool_parallel_build() {
	local pool="${1:-1}" cpus
	cpus="$(ct_pool_cpus)"
	if [ "${pool}" -le 1 ]; then
		echo 0 # Nim's default: one C compiler per CPU
	elif [ "${cpus}" -le "${pool}" ]; then
		echo 1
	else
		echo $(((cpus + pool - 1) / pool))
	fi
}

# ct_pool_wait_for_slot POOL PIDS waits until fewer than POOL of the pool's
# own jobs (PIDS, space-separated) are still running. `wait -n` alone is not
# enough: it also returns for any other child of the shell, such as a process
# substitution that has already finished, and counting its returns then lets
# one job too many start (measured in ci/test/lane-pool-test.sh: four files at
# once in a pool of three).
ct_pool_wait_for_slot() {
	local pool="$1" pids=" $2 " live p
	while :; do
		live=0
		for p in $(jobs -rp); do
			case "${pids}" in *" ${p} "*) live=$((live + 1)) ;; esac
		done
		[ "${live}" -lt "${pool}" ] && return 0
		wait -n 2>/dev/null || true
	done
}
