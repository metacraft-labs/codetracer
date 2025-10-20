#!/usr/bin/env bash
set -euo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/tools/build/build_codetracer.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

run_and_assert() {
  local description="$1"
  local expected="$2"
  shift 2
  local output
  if ! output="$("$BUILD_SCRIPT" "$@" --dry-run)"; then
    echo "Command failed during ${description}" >&2
    exit 1
  fi

  if ! grep -q -- "${expected}" <<<"${output}"; then
    echo "Assertion failed during ${description}" >&2
    echo "Expected to find: ${expected}" >&2
    echo "Actual output:" >&2
    echo "${output}" >&2
    exit 1
  fi
}

run_and_assert \
  "ct dry-run" \
  "-d:ctEntrypoint" \
  --target ct \
  --profile debug \
  --output-dir "${tmp_dir}/bin"

run_and_assert \
  "ct dry-run includes -d:withTup" \
  "-d:withTup" \
  --target ct \
  --profile debug \
  --output-dir "${tmp_dir}/bin"

run_and_assert \
  "explicit output path respected" \
  "--out:${tmp_dir}/custom/bin/codetracer" \
  --target ct \
  --output "${tmp_dir}/custom/bin/codetracer"

run_and_assert \
  "index.js dry-run" \
  "js ${PROJECT_ROOT}/src/frontend/index.nim" \
  --target js:index

echo "All dry-run checks passed."
