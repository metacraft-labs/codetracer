#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
cd "${ROOT_DIR}"

echo '###############################################################################'
echo "Building Codetracer CLI for smoke test"
echo '###############################################################################'

nix develop .#devShells.x86_64-linux.default --command ./ci/build/dev.sh

CT_BIN="${ROOT_DIR}/src/bin/ct"
if [[ ! -x "${CT_BIN}" ]]; then
  echo "error: ${CT_BIN} not found after build"
  exit 1
fi

VENV_DIR=$(mktemp -d -t codetracer-python-recorder-smoke-venv-XXXXXX)
TRACE_DIR=$(mktemp -d -t codetracer-python-recorder-smoke-trace-XXXXXX)
MISSING_VENV_DIR=""
MISSING_TRACE_DIR=""
MISSING_INTERP_TRACE_DIR=""

cleanup() {
  if type deactivate >/dev/null 2>&1; then
    deactivate || true
  fi
  rm -rf "${VENV_DIR}" "${TRACE_DIR}"
  if [[ -n "${MISSING_VENV_DIR}" ]]; then
    rm -rf "${MISSING_VENV_DIR}"
  fi
  if [[ -n "${MISSING_TRACE_DIR}" ]]; then
    rm -rf "${MISSING_TRACE_DIR}"
  fi
  if [[ -n "${MISSING_INTERP_TRACE_DIR}" ]]; then
    rm -rf "${MISSING_INTERP_TRACE_DIR}"
  fi
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
export TRACE_DIR

CODETRACER_CT_PATHS=$(pwd)/ct_paths.json
export CODETRACER_CT_PATHS

"${CT_BIN}" record -o="${TRACE_DIR}" "${TRACE_PROGRAM}"

if [[ ! -f "${TRACE_DIR}/trace.json" ]]; then
  echo "error: trace.json not produced at ${TRACE_DIR}"
  exit 1
fi

if [[ ! -f "${TRACE_DIR}/trace_metadata.json" ]]; then
  echo "error: trace_metadata.json not produced at ${TRACE_DIR}"
  exit 1
fi

python - <<'PY'
import json
import os
from pathlib import Path

trace_dir = Path(os.environ["TRACE_DIR"])
metadata = json.loads((trace_dir / "trace_metadata.json").read_text(encoding="utf-8"))

recorder = metadata.get("recorder", {})
assert recorder.get("name") == "codetracer_python_recorder", recorder
assert recorder.get("target_script"), "missing target_script in recorder metadata"
PY

echo '###############################################################################'
echo "Verifying failure mode when recorder module is missing"
echo '###############################################################################'

deactivate

MISSING_VENV_DIR=$(mktemp -d -t codetracer-python-recorder-missing-venv-XXXXXX)
python3 -m venv "${MISSING_VENV_DIR}"

MISSING_TRACE_DIR=$(mktemp -d -t codetracer-python-recorder-missing-trace-XXXXXX)

set +e
MISSING_OUTPUT=$(CODETRACER_PYTHON_INTERPRETER="${MISSING_VENV_DIR}/bin/python" "${CT_BIN}" record -o="${MISSING_TRACE_DIR}" "${TRACE_PROGRAM}" 2>&1)
STATUS=$?
set -e

if [[ ${STATUS} -eq 0 ]]; then
  echo "error: ct record unexpectedly succeeded without codetracer_python_recorder"
  echo "${MISSING_OUTPUT}"
  exit 1
fi

if ! grep -q "codetracer_python_recorder" <<<"${MISSING_OUTPUT}"; then
  echo "error: failure output did not mention codetracer_python_recorder"
  echo "${MISSING_OUTPUT}"
  exit 1
fi

if ! grep -q "pip install codetracer_python_recorder" <<<"${MISSING_OUTPUT}"; then
  echo "error: failure output did not include installation guidance"
  echo "${MISSING_OUTPUT}"
  exit 1
fi

echo '###############################################################################'
echo "Verifying failure mode when interpreter cannot be located"
echo '###############################################################################'

MISSING_INTERP_TRACE_DIR=$(mktemp -d -t codetracer-python-recorder-missing-interp-trace-XXXXXX)

set +e
MISSING_INTERP_OUTPUT=$(CODETRACER_PYTHON_INTERPRETER="${ROOT_DIR}/nonexistent/python" "${CT_BIN}" record -o="${MISSING_INTERP_TRACE_DIR}" "${TRACE_PROGRAM}" 2>&1)
INTERP_STATUS=$?
set -e

if [[ ${INTERP_STATUS} -eq 0 ]]; then
  echo "error: ct record unexpectedly succeeded with a missing interpreter"
  echo "${MISSING_INTERP_OUTPUT}"
  exit 1
fi

if ! grep -q "CODETRACER_PYTHON_INTERPRETER is set" <<<"${MISSING_INTERP_OUTPUT}"; then
  echo "error: missing interpreter output did not explain which override failed"
  echo "${MISSING_INTERP_OUTPUT}"
  exit 1
fi

if ! grep -q "does not resolve to a Python interpreter" <<<"${MISSING_INTERP_OUTPUT}"; then
  echo "error: missing interpreter output did not describe the resolution failure"
  echo "${MISSING_INTERP_OUTPUT}"
  exit 1
fi

echo "Smoke test succeeded; artifacts stored in ${TRACE_DIR}"
