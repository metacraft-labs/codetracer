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
  echo "  Pass ROOT_DIR as \$1 or set CODETRACER_REPO_ROOT_PATH." >&2
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
     [ -d "$candidate/codetracer-wasm-recorder" ]; then
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

# --- codetracer-wasm-recorder ---
# Exports: CODETRACER_WASM_RECORDER_PRESENT (no single path for this one)
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-wasm-recorder" ]; then
  export CODETRACER_WASM_RECORDER_PRESENT=1
  _ct_detect_summary "codetracer-wasm-recorder"
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
# Print summary to stderr (unless DETECT_SIBLINGS_QUIET=1)
# ---------------------------------------------------------------------------
if [ -z "${DETECT_SIBLINGS_QUIET:-}" ] && [ -n "$_CT_DETECTED_SIBLINGS" ]; then
  echo "$_CT_DETECTED_SIBLINGS" >&2
fi

# Clean up temporary variables (don't pollute the caller's namespace).
unset _CT_ROOT_DIR _CT_WORKSPACE_ROOT _CT_DETECTED_SIBLINGS
unset _ct_parent _ct_grandparent
unset -f _ct_try_workspace_root _ct_detect_summary
