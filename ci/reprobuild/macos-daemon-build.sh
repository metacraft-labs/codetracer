#!/usr/bin/env bash
set -euo pipefail

fail() {
	echo "Error: $1" >&2
	exit 1
}

if [ "$(uname -s)" != "Darwin" ]; then
	fail "reprobuild macOS daemon e2e must run on Darwin; got $(uname -s)"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_target="${CODETRACER_REPROBUILD_TARGET:-${CODETRACER_REPROBUILD_E2E_TARGET:-.#dmg}}"
check_dmg=0
if [[ ${build_target} == *dmg* ]]; then
	check_dmg=1
fi

# Prefer a locally-built reprobuild over the devshell's flake-pinned copy.
prepend_local_reprobuild_bin() {
	local candidate=""
	if [ -n "${CODETRACER_REPROBUILD_REPO_PATH:-}" ] &&
		[ -x "${CODETRACER_REPROBUILD_REPO_PATH}/build/bin/repro" ]; then
		candidate="${CODETRACER_REPROBUILD_REPO_PATH}/build/bin"
	elif [ -x "${repo_root}/../reprobuild/build/bin/repro" ]; then
		candidate="$(cd "${repo_root}/../reprobuild/build/bin" && pwd)"
	fi
	if [ -n "$candidate" ]; then
		case ":$PATH:" in
		*":$candidate:"*) ;;
		*)
			export PATH="$candidate:$PATH"
			echo "using local reprobuild binaries from: $candidate"
			;;
		esac
	fi
}

prepend_local_reprobuild_bin

command -v repro >/dev/null || {
	fail "repro is not on PATH"
}

command -v runquotad >/dev/null || {
	fail "runquotad is not on PATH"
}

echo "host: $(uname -s)-$(uname -m)"
echo "repro: $(command -v repro)"
echo "runquotad: $(command -v runquotad)"
echo "build target: ${build_target}"

# De-poison the runner before we start, and do not poison it on the way out.
#
# This is the SAME hazard ci/reprobuild/macos-smoke.sh documents at length, and
# this script is the other half of it: a556399c0 named two victims of a stale
# daemon's dangling cwd but only guarded the smoke script, while THIS script is
# the one that deliberately runs `repro build --daemon=auto` (below) and so is
# the most likely thing on the runner to LEAVE a daemon behind.
#
# The repro user daemon is PERSISTENT and its endpoint is deliberately stable
# across nix-develop sessions, so one daemon serves every job on a runner
# indefinitely. On macOS it is started via launchd, and when that fails it falls
# back to a plain fork+setsid -- `launchWithFork` in reprobuild's
# repro_daemon_core/runtime.nim calls `setsid()` and then `execve` with NO
# `chdir` between them, and no launchd plist this project writes sets
# `WorkingDirectory`. So the daemon inherits, and keeps, the cwd of whichever
# `repro build` first spawned it. Once that directory is gone -- a re-cloned
# workspace, a deleted temp root, a cleaned checkout -- every later
# `repro build` on this runner dies in `getCurrentDir()` with
#
#     daemon-hosted build failed: No such file or directory
#
# which names no path and no owner, which is what made it expensive.
#
# So: stop any daemon inherited from an earlier job (otherwise this run dies on
# someone else's dangling cwd), and stop ours on the way out (otherwise the next
# job dies on ours). `|| true` because "no daemon running" is the normal case,
# not an error.
#
# The durable fix is upstream in reprobuild -- add the missing `chdir("/")` to
# the fork path and let the daemon tolerate a vanished cwd. This only stops
# codetracer's jobs being both the cause and the victim.
#
# Checked by: ci/verdict/reprobuild-daemon-guard.sh
# Contract suite: ci/test/reprobuild-daemon-guard-test.sh
repro daemon stop >/dev/null 2>&1 || true

# One EXIT trap for the whole script, installed HERE rather than inside
# `start_runquotad` as it was before. Two reasons: a second `trap ... EXIT`
# REPLACES the first rather than composing with it, and the old trap was
# installed inside a function that returns early when `RUNQUOTA_SOCKET` is
# already set -- so on that path the script had no EXIT handler at all.
cleanup() {
	# MUST run on every exit path, including failure: a daemon this script
	# spawned outlives it and holds this checkout as its cwd.
	repro daemon stop >/dev/null 2>&1 || true
	if [ -n "${runquotad_pid:-}" ]; then
		kill "$runquotad_pid" 2>/dev/null || true
		wait "$runquotad_pid" 2>/dev/null || true
	fi
	rm -rf "${runquota_dir:-}"
}
trap cleanup EXIT

capabilities_json="$(repro capabilities --format=json)"
if ! printf '%s\n' "${capabilities_json}" |
	grep -Eq '"runQuota"[[:space:]]*:[[:space:]]*"supported"'; then
	fail "repro capabilities does not report runQuota support"
fi

start_runquotad() {
	if [ -n "${RUNQUOTA_SOCKET:-}" ]; then
		return
	fi

	runquotad_bin="${RUNQUOTAD_BIN:-}"
	if [ -z "$runquotad_bin" ]; then
		runquotad_bin="$(command -v runquotad || true)"
	fi
	if [ -z "$runquotad_bin" ]; then
		fail "runquotad is required for e2e test; set RUNQUOTAD_BIN or RUNQUOTA_SOCKET"
	fi

	# A directory of its own, not a socket dropped into a shared /tmp --
	# see the long note in scripts/build-once.sh. runquotad verifies the
	# socket's parent directory before binding and refuses a root-owned
	# 1777 /tmp; a directory that does not exist yet it creates itself,
	# with the mode it requires.
	runquota_dir="/tmp/reprobuild-e2e.$$.$RANDOM"
	runquota_socket="$runquota_dir/runquota.sock"
	runquota_log=".repro/runquota/macos-daemon-build-runquotad.log"
	mkdir -p .repro/runquota
	rm -rf "$runquota_dir"

	"$runquotad_bin" \
		--socket "$runquota_socket" \
		--cpu-milli "${CODETRACER_RUNQUOTA_CPU_MILLI:-8000}" \
		--memory-bytes "${CODETRACER_RUNQUOTA_MEMORY_BYTES:-17179869184}" \
		--pool console=1 \
		>"$runquota_log" 2>&1 &
	runquotad_pid="$!"
	# No `trap` here. The single EXIT handler installed at the top of this
	# script already reaps ${runquotad_pid} and ${runquota_dir}; re-arming
	# the trap from inside this function would REPLACE that handler and so
	# silently drop the `repro daemon stop`, which is the whole point of it.

	for _ in {1..300}; do
		if grep -q "runquotad listening" "$runquota_log" 2>/dev/null; then
			export RUNQUOTA_SOCKET="$runquota_socket"
			return
		fi
		if ! kill -0 "$runquotad_pid" 2>/dev/null; then
			sed 's/^/  runquotad: /' "$runquota_log" >&2 2>/dev/null || true
			fail "runquotad exited before becoming ready. See $runquota_log"
		fi
		sleep 0.05
	done

	sed 's/^/  runquotad: /' "$runquota_log" >&2 2>/dev/null || true
	fail "runquotad did not become ready. See $runquota_log"
}

run_reprobuild() {
	local mode="$1"
	local step="$2"
	echo "[${step}] repro build with --daemon=${mode} --tool-provisioning=nix target=${build_target}"

	(
		cd "${repo_root}"
		repro build "${build_target}" \
			--daemon="${mode}" \
			--tool-provisioning=nix \
			--progress=none \
			--log=quiet
	)
}

verify_artifacts() {
	local mode="$1"
	echo "verifying artifacts for --daemon=${mode} target=${build_target}"
	if [ ! -x "${repo_root}/src/build-debug/bin/ct" ] &&
		[ ! -x "${repo_root}/src/build-debug-repro/bin/ct" ]; then
		fail "expected artifact missing: src/build-debug/bin/ct or src/build-debug-repro/bin/ct"
	fi
	if [ "$check_dmg" -eq 1 ] && [ ! -f "${repo_root}/non-nix-build/CodeTracer.dmg" ]; then
		fail "expected artifact missing: non-nix-build/CodeTracer.dmg"
	fi
}

start_runquotad
run_reprobuild auto "1/2"
verify_artifacts auto
run_reprobuild off "2/2"
verify_artifacts off

echo "macOS daemon e2e completed successfully"
