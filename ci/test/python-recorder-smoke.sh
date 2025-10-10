#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
cd "${ROOT_DIR}"

echo '###############################################################################'
echo "Building Codetracer CLI for smoke test"
echo '###############################################################################'

./ci/build/dev.sh

CT_BIN="${ROOT_DIR}/src/build-debug/bin/ct"
if [[ ! -x "${CT_BIN}" ]]; then
  echo "error: ${CT_BIN} not found after build"
  exit 1
fi

VENV_DIR=$(mktemp -d -t codetracer-python-recorder-smoke-venv-XXXXXX)
TRACE_DIR=$(mktemp -d -t codetracer-python-recorder-smoke-trace-XXXXXX)

cleanup() {
  if type deactivate >/dev/null 2>&1; then
    deactivate || true
  fi
  rm -rf "${VENV_DIR}" "${TRACE_DIR}"
}
trap cleanup EXIT

echo '###############################################################################'
echo "Preparing virtual environment with codetracer-python-recorder"
echo '###############################################################################'

python3 -m venv "${VENV_DIR}"
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip
python -m pip install "${ROOT_DIR}/libs/codetracer-python-recorder/codetracer-python-recorder"

echo '###############################################################################'
echo "Running python recorder smoke test via ct record"
echo '###############################################################################'

TRACE_PROGRAM="${ROOT_DIR}/examples/python_script.py"

"${CT_BIN}" record -o "${TRACE_DIR}" "${TRACE_PROGRAM}"

if [[ ! -f "${TRACE_DIR}/trace.json" ]]; then
  echo "error: trace.json not produced at ${TRACE_DIR}"
  exit 1
fi

if [[ ! -f "${TRACE_DIR}/trace_metadata.json" ]]; then
  echo "error: trace_metadata.json not produced at ${TRACE_DIR}"
  exit 1
fi

echo "Smoke test succeeded; artifacts stored in ${TRACE_DIR}"
