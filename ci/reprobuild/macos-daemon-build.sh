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

	runquota_socket="/tmp/reprobuild-e2e.$$.$RANDOM.sock"
	runquota_log=".repro/runquota/macos-daemon-build-runquotad.log"
	mkdir -p .repro/runquota
	rm -f "$runquota_socket"

	"$runquotad_bin" \
		--socket "$runquota_socket" \
		--cpu-milli "${CODETRACER_RUNQUOTA_CPU_MILLI:-8000}" \
		--memory-bytes "${CODETRACER_RUNQUOTA_MEMORY_BYTES:-17179869184}" \
		--pool console=1 \
		>"$runquota_log" 2>&1 &
	runquotad_pid="$!"
	trap 'if [ -n "${runquotad_pid:-}" ]; then kill "$runquotad_pid" 2>/dev/null || true; wait "$runquotad_pid" 2>/dev/null || true; fi' EXIT

	for _ in {1..300}; do
		if grep -q "runquotad listening" "$runquota_log" 2>/dev/null; then
			export RUNQUOTA_SOCKET="$runquota_socket"
			return
		fi
		if ! kill -0 "$runquotad_pid" 2>/dev/null; then
			fail "runquotad exited before becoming ready. See $runquota_log"
		fi
		sleep 0.05
	done

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
