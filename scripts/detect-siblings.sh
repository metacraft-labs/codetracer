#!/usr/bin/env bash
# =============================================================================
# Unified sibling repo detection for CodeTracer workspaces.
#
# Detects sibling repos checked out alongside the main codetracer repo (in a
# workspace layout) and exports CODETRACER_*_PATH environment variables for
# each detected sibling. Also derives backward-compatible CODETRACER_*_PRESENT=1
# variables from the _PATH vars.
#
# Usage:
#   source scripts/detect-siblings.sh [ROOT_DIR]
#
# Arguments:
#   ROOT_DIR  (optional) — absolute path to the codetracer repo root.
#             Defaults to $CODETRACER_REPO_ROOT_PATH, then falls back to
#             `git rev-parse --show-toplevel`.
#
# Environment:
#   DETECT_SIBLINGS_QUIET=1  — suppress summary output to stderr.
#
# See: codetracer-specs/Working-with-the-CodeTracer-Repos.md
# =============================================================================

# Resolve the codetracer repo root directory.
_CT_ROOT_DIR="${1:-${CODETRACER_REPO_ROOT_PATH:-}}"
if [ -z "$_CT_ROOT_DIR" ]; then
	_CT_ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || true
fi
if [ -z "$_CT_ROOT_DIR" ]; then
	echo "detect-siblings.sh: ERROR: cannot determine repo root." >&2
	# shellcheck disable=SC2016  # $1 is literal here (user guidance, not expansion)
	echo '  Pass ROOT_DIR as $1 or set CODETRACER_REPO_ROOT_PATH.' >&2
	# shellcheck disable=SC2317  # exit is reachable when script is executed (not sourced)
	return 1 2>/dev/null || exit 1
fi

# Export CODETRACER_REPO_ROOT_PATH if not already set (needed by Justfile
# recipes like test-e2e that reference it).
export CODETRACER_REPO_ROOT_PATH="${CODETRACER_REPO_ROOT_PATH:-$_CT_ROOT_DIR}"

# ---------------------------------------------------------------------------
# Determine workspace root (parent directory containing sibling repos).
#
# Standard layout:        metacraft/codetracer/  → WORKSPACE_ROOT = metacraft/
# Worktree sub-workspace: metacraft/ws/codetracer/ → try two levels up if the
#                         immediate parent has no sibling repos.
# ---------------------------------------------------------------------------
_CT_WORKSPACE_ROOT=""

_ct_try_workspace_root() {
	local candidate="$1"
	# A valid workspace root should contain at least one known sibling directory.
	if [ -d "$candidate/codetracer-rr-backend" ] ||
		[ -d "$candidate/codetracer-python-recorder" ] ||
		[ -d "$candidate/codetracer-ruby-recorder" ] ||
		[ -d "$candidate/codetracer-js-recorder" ] ||
		[ -d "$candidate/codetracer-shell-recorders" ] ||
		[ -d "$candidate/codetracer-wasm-recorder" ] ||
		[ -d "$candidate/noir" ]; then
		_CT_WORKSPACE_ROOT="$candidate"
		return 0
	fi
	return 1
}

# Try parent first (standard layout), then grandparent (worktree layout).
_ct_parent="$(cd "$_CT_ROOT_DIR/.." 2>/dev/null && pwd)"
if [ -n "$_ct_parent" ]; then
	if ! _ct_try_workspace_root "$_ct_parent"; then
		_ct_grandparent="$(cd "$_CT_ROOT_DIR/../.." 2>/dev/null && pwd)"
		if [ -n "$_ct_grandparent" ]; then
			_ct_try_workspace_root "$_ct_grandparent" || true
		fi
	fi
fi

# Collector for summary output.
_CT_DETECTED_SIBLINGS=""

_ct_detect_summary() {
	if [ -z "${DETECT_SIBLINGS_QUIET:-}" ]; then
		_CT_DETECTED_SIBLINGS="${_CT_DETECTED_SIBLINGS}  sibling: $1 detected"$'\n'
	fi
}

# ---------------------------------------------------------------------------
# Sibling detection
# ---------------------------------------------------------------------------

# --- codetracer-rr-backend ---
# Exports: CODETRACER_RR_BACKEND_PATH, prepends to PATH
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -x "$_CT_WORKSPACE_ROOT/codetracer-rr-backend/target/debug/ct-rr-support" ]; then
	export CODETRACER_RR_BACKEND_PATH="$_CT_WORKSPACE_ROOT/codetracer-rr-backend"
	export PATH="$_CT_WORKSPACE_ROOT/codetracer-rr-backend/target/debug:$PATH"
	_ct_detect_summary "codetracer-rr-backend (ct-rr-support available)"
fi

# --- codetracer-python-recorder ---
# Exports: CODETRACER_PYTHON_RECORDER_PATH
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-python-recorder" ]; then
	export CODETRACER_PYTHON_RECORDER_PATH="$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-pure-python-recorder/src/trace.py"
	# Also export the source directory for venv setup (used by nix shell hook).
	export CODETRACER_PYTHON_RECORDER_SRC="$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-python-recorder"
	_ct_detect_summary "codetracer-python-recorder"
fi

# --- codetracer-ruby-recorder ---
# Exports: CODETRACER_RUBY_RECORDER_PATH, RUBY_RECORDER_ROOT
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-ruby-recorder/gems" ]; then
	export CODETRACER_RUBY_RECORDER_PATH="$_CT_WORKSPACE_ROOT/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder"
	export RUBY_RECORDER_ROOT="$_CT_WORKSPACE_ROOT/codetracer-ruby-recorder"
	_ct_detect_summary "codetracer-ruby-recorder"
fi

# --- codetracer-js-recorder ---
# Exports: CODETRACER_JS_RECORDER_PATH
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-js-recorder/packages/cli" ]; then
	export CODETRACER_JS_RECORDER_PATH="$_CT_WORKSPACE_ROOT/codetracer-js-recorder/packages/cli/dist/index.js"
	_ct_detect_summary "codetracer-js-recorder"
fi

# --- codetracer-shell-recorders ---
# Exports: CODETRACER_BASH_RECORDER_PATH, CODETRACER_ZSH_RECORDER_PATH
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-shell-recorders/bash-recorder" ]; then
	export CODETRACER_BASH_RECORDER_PATH="$_CT_WORKSPACE_ROOT/codetracer-shell-recorders/bash-recorder/launcher.sh"
	export CODETRACER_ZSH_RECORDER_PATH="$_CT_WORKSPACE_ROOT/codetracer-shell-recorders/zsh-recorder/launcher.zsh"
	_ct_detect_summary "codetracer-shell-recorders"
fi

# --- noir (metacraft-labs fork, provides nargo) ---
# Exports: CODETRACER_NARGO_PATH, prepends to PATH
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/noir" ]; then
	# Prefer a pre-built nargo binary (release or debug).
	if [ -x "$_CT_WORKSPACE_ROOT/noir/target/release/nargo" ]; then
		export CODETRACER_NARGO_PATH="$_CT_WORKSPACE_ROOT/noir/target/release/nargo"
		export PATH="$_CT_WORKSPACE_ROOT/noir/target/release:$PATH"
		_ct_detect_summary "noir (nargo release build)"
	elif [ -x "$_CT_WORKSPACE_ROOT/noir/target/debug/nargo" ]; then
		export CODETRACER_NARGO_PATH="$_CT_WORKSPACE_ROOT/noir/target/debug/nargo"
		export PATH="$_CT_WORKSPACE_ROOT/noir/target/debug:$PATH"
		_ct_detect_summary "noir (nargo debug build)"
	else
		_ct_detect_summary "noir (repo present, nargo not built)"
	fi
fi

# --- codetracer-wasm-recorder ---
# Exports: CODETRACER_WASM_RECORDER_PRESENT, CODETRACER_WASM_VM_PATH, prepends to PATH
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-wasm-recorder" ]; then
	export CODETRACER_WASM_RECORDER_PRESENT=1
	if [ -x "$_CT_WORKSPACE_ROOT/codetracer-wasm-recorder/wazero" ]; then
		export CODETRACER_WASM_VM_PATH="$_CT_WORKSPACE_ROOT/codetracer-wasm-recorder/wazero"
		_ct_detect_summary "codetracer-wasm-recorder (wazero binary available)"
	else
		_ct_detect_summary "codetracer-wasm-recorder (repo present, wazero not built)"
	fi
fi

# --- codetracer-trace-format ---
# Exports: LD_LIBRARY_PATH addition for libcodetracer_trace_writer_ffi.so (needed by wazero)
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-trace-format/target/release" ]; then
	export LD_LIBRARY_PATH="$_CT_WORKSPACE_ROOT/codetracer-trace-format/target/release:${LD_LIBRARY_PATH:-}"
	_ct_detect_summary "codetracer-trace-format (FFI library available)"
fi

# ---------------------------------------------------------------------------
# Backward compatibility: derive _PRESENT=1 from non-empty _PATH vars.
# Consumers should migrate to checking _PATH directly.
# ---------------------------------------------------------------------------
if [ -n "${CODETRACER_RR_BACKEND_PATH:-}" ]; then
	export CODETRACER_RR_BACKEND_PRESENT=1
fi
if [ -n "${CODETRACER_PYTHON_RECORDER_PATH:-}" ]; then
	export CODETRACER_PYTHON_RECORDER_PRESENT=1
fi
if [ -n "${CODETRACER_RUBY_RECORDER_PATH:-}" ]; then
	export CODETRACER_RUBY_RECORDER_PRESENT=1
fi
if [ -n "${CODETRACER_JS_RECORDER_PATH:-}" ]; then
	export CODETRACER_JS_RECORDER_PRESENT=1
fi
if [ -n "${CODETRACER_BASH_RECORDER_PATH:-}" ]; then
	export CODETRACER_SHELL_RECORDERS_PRESENT=1
fi
# CODETRACER_WASM_RECORDER_PRESENT is set directly above (no _PATH var).

# ---------------------------------------------------------------------------
# Python interpreter detection
#
# The pure-Python recorder needs Python 3.10+ (PEP 604 syntax); the
# Rust-backed recorder needs 3.12+. Try versioned brew binaries first,
# then the generic python3/python.
# ---------------------------------------------------------------------------
if [ -z "${CODETRACER_PYTHON_CMD:-}" ] && [ -n "${CODETRACER_PYTHON_RECORDER_PATH:-}" ]; then
	for _ct_py in python3.13 python3.12 python3.11 python3.10 python3; do
		if command -v "$_ct_py" &>/dev/null; then
			_ct_py_ver="$("$_ct_py" -c 'import sys; print(sys.version_info[:2])' 2>/dev/null || true)"
			if [ -n "$_ct_py_ver" ] && [[ $_ct_py_ver > "(3, 9)" ]]; then
				export CODETRACER_PYTHON_CMD="$_ct_py"
				break
			fi
		fi
	done
	unset _ct_py _ct_py_ver

	if [ -z "${CODETRACER_PYTHON_CMD:-}" ] && [ -z "${DETECT_SIBLINGS_QUIET:-}" ]; then
		echo "  NOTE: Python 3.10+ not found. Python flow tests will skip." >&2
		echo "  Install via: brew install python@3.12" >&2
		echo "  Or use nix:  nix develop ../codetracer-python-recorder#python-recorder" >&2
	fi
fi

# ---------------------------------------------------------------------------
# Print summary to stderr (unless DETECT_SIBLINGS_QUIET=1)
# ---------------------------------------------------------------------------
if [ -z "${DETECT_SIBLINGS_QUIET:-}" ] && [ -n "$_CT_DETECTED_SIBLINGS" ]; then
	echo "$_CT_DETECTED_SIBLINGS" >&2
fi

# Clean up temporary variables (don't pollute the caller's namespace).
unset _CT_ROOT_DIR _CT_WORKSPACE_ROOT _CT_DETECTED_SIBLINGS
unset _ct_parent _ct_grandparent
unset -f _ct_try_workspace_root _ct_detect_summary
