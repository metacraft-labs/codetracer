#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
	echo "reprobuild macOS smoke must run on Darwin; got $(uname -s)" >&2
	exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="${repo_root}/tests/fixtures/reprobuild-macos-smoke"
expected_output="reprobuild macos smoke: hello"

command -v repro >/dev/null || {
	echo "repro is not on PATH" >&2
	exit 1
}

command -v runquota >/dev/null || {
	echo "runquota is not on PATH" >&2
	exit 1
}

echo "host: $(uname -s)-$(uname -m)"
echo "repro: $(command -v repro)"
echo "runquota: $(command -v runquota)"

capabilities_json="$(repro capabilities --format=json)"
printf '%s\n' "${capabilities_json}" >"${TMPDIR:-/tmp}/reprobuild-macos-smoke-capabilities.json"
if ! printf '%s\n' "${capabilities_json}" |
	grep -Eq '"runQuota"[[:space:]]*:[[:space:]]*"supported"'; then
	echo "repro capabilities does not report runQuota support" >&2
	printf '%s\n' "${capabilities_json}" >&2
	exit 1
fi

# De-poison the runner before we start, and make sure we do not poison it on
# the way out.
#
# The repro user daemon is PERSISTENT and its endpoint is deliberately stable
# across nix-develop sessions, so a single daemon serves every job on a runner
# indefinitely. On macOS it is started via launchd, and when that fails it
# falls back to a plain fork+setsid that never performs the `chdir("/")` step
# of daemonising -- so it inherits the cwd of whichever `repro build` first
# spawned it. This script builds from `${tmp_root}/project-*` and then deletes
# `${tmp_root}`, so a daemon left running here is left holding a DELETED
# directory, and every later `repro build` on this runner -- in this job or any
# other, this project or any other -- dies in `getCurrentDir()` with
#
#     daemon-hosted build failed: No such file or directory
#
# Reproduced locally: spawn the daemon from dir A through the fork path,
# `rm -rf A`, then build from dir B and it fails exactly so.
#
# So: stop any daemon inherited from an earlier job (otherwise this run dies on
# someone else's dangling cwd), and stop ours before `rm -rf "${tmp_root}"`
# below (otherwise we are the ones who poison the next job). `|| true` because
# "no daemon running" is the normal case, not an error.
#
# The durable fix is upstream in reprobuild -- add the missing `chdir("/")` to
# the fork path and let the daemon tolerate a vanished cwd. This only stops
# codetracer's jobs being both the cause and the victim.
repro daemon stop >/dev/null 2>&1 || true

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/reprobuild-macos-smoke.XXXXXX")"
cleanup() {
	status=$?
	if [ "${status}" -ne 0 ] && [ "${REPROBUILD_MACOS_SMOKE_KEEP_TMP:-0}" = "1" ]; then
		echo "keeping smoke temp dir after failure: ${tmp_root}" >&2
		return
	fi
	# MUST precede the rm: see the note above. A daemon still holding
	# ${tmp_root} as its cwd outlives this script and breaks the next job.
	repro daemon stop >/dev/null 2>&1 || true
	rm -rf "${tmp_root}"
}
trap cleanup EXIT

if [ -n "${REPROBUILD_SOURCE_ROOT:-}" ]; then
	if [ ! -d "${REPROBUILD_SOURCE_ROOT}/libs/repro_project_dsl/src" ]; then
		echo "REPROBUILD_SOURCE_ROOT does not look like a reprobuild source tree: ${REPROBUILD_SOURCE_ROOT}" >&2
		exit 1
	fi

	reprobuild_work_source="${tmp_root}/reprobuild-source"
	cp -R "${REPROBUILD_SOURCE_ROOT}" "${reprobuild_work_source}"
	chmod -R u+w "${reprobuild_work_source}"
	export REPROBUILD_SOURCE_ROOT="${reprobuild_work_source}"
	echo "reprobuild source: ${REPROBUILD_SOURCE_ROOT}"
fi

run_smoke_build() {
	local label="$1"
	local daemon_mode="$2"
	local project_root="${tmp_root}/project-${label}"
	mkdir -p "${project_root}"
	cp -R "${fixture_root}/." "${project_root}/"

	echo "project (${label}): ${project_root}"
	(
		cd "${project_root}"
		repro build . \
			--daemon="${daemon_mode}" \
			--tool-provisioning=path \
			--progress=none \
			--log=actions
	)

	local actual_output
	actual_output="$(cat "${project_root}/build/hello-output.txt")"
	if [ "${actual_output}" != "${expected_output}" ]; then
		echo "unexpected smoke output for ${label}" >&2
		echo "expected: ${expected_output}" >&2
		echo "actual:   ${actual_output}" >&2
		exit 1
	fi

	echo "smoke output (${label}): ${actual_output}"
}

run_smoke_build "daemon" "auto"
run_smoke_build "direct" "off"
