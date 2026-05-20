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

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/reprobuild-macos-smoke.XXXXXX")"
cleanup() {
	status=$?
	if [ "${status}" -ne 0 ] && [ "${REPROBUILD_MACOS_SMOKE_KEEP_TMP:-0}" = "1" ]; then
		echo "keeping smoke temp dir after failure: ${tmp_root}" >&2
		return
	fi
	rm -rf "${tmp_root}"
}
trap cleanup EXIT

project_root="${tmp_root}/project"
mkdir -p "${project_root}"
cp -R "${fixture_root}/." "${project_root}/"

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

echo "project: ${project_root}"
(
	cd "${project_root}"
	repro build . \
		--tool-provisioning=path \
		--progress=none \
		--log=actions
)

actual_output="$(cat "${project_root}/build/hello-output.txt")"
if [ "${actual_output}" != "${expected_output}" ]; then
	echo "unexpected smoke output" >&2
	echo "expected: ${expected_output}" >&2
	echo "actual:   ${actual_output}" >&2
	exit 1
fi

echo "smoke output: ${actual_output}"
