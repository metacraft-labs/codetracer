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
	if [ -d "$candidate/codetracer-native-backend" ] ||
		[ -d "$candidate/codetracer-rr-backend" ] ||
		[ -d "$candidate/codetracer-python-recorder" ] ||
		[ -d "$candidate/codetracer-ruby-recorder" ] ||
		[ -d "$candidate/codetracer-js-recorder" ] ||
		[ -d "$candidate/codetracer-beam-recorder" ] ||
		[ -d "$candidate/codetracer-elixir-recorder" ] ||
		[ -d "$candidate/codetracer-shell-recorders" ] ||
		[ -d "$candidate/codetracer-wasm-recorder" ] ||
		[ -d "$candidate/codetracer-native-test-programs" ] ||
		[ -d "$candidate/codetracer-cairo-recorder" ] ||
		[ -d "$candidate/codetracer-cardano-recorder" ] ||
		[ -d "$candidate/codetracer-circom-recorder" ] ||
		[ -d "$candidate/codetracer-evm-recorder" ] ||
		[ -d "$candidate/codetracer-flow-recorder" ] ||
		[ -d "$candidate/codetracer-fuel-recorder" ] ||
		[ -d "$candidate/codetracer-leo-recorder" ] ||
		[ -d "$candidate/codetracer-miden-recorder" ] ||
		[ -d "$candidate/codetracer-move-recorder" ] ||
		[ -d "$candidate/codetracer-polkavm-recorder" ] ||
		[ -d "$candidate/codetracer-solana-recorder" ] ||
		[ -d "$candidate/codetracer-ton-recorder" ] ||
		[ -d "$candidate/codetracer-native-recorder" ] ||
		[ -d "$candidate/codetracer-wasmi-recorder" ] ||
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

# --- codetracer-native-backend (formerly codetracer-rr-backend) ---
# Prepends to PATH so `ct` finds ct-native-replay via the same PATH search as end users.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -x "$_CT_WORKSPACE_ROOT/codetracer-native-backend/target/debug/ct-native-replay" ]; then
	export PATH="$_CT_WORKSPACE_ROOT/codetracer-native-backend/target/debug:$PATH"
	_ct_detect_summary "codetracer-native-backend (ct-native-replay available)"
elif [ -n "$_CT_WORKSPACE_ROOT" ] && [ -x "$_CT_WORKSPACE_ROOT/codetracer-rr-backend/target/debug/ct-rr-support" ]; then
	export PATH="$_CT_WORKSPACE_ROOT/codetracer-rr-backend/target/debug:$PATH"
	_ct_detect_summary "codetracer-rr-backend (ct-rr-support available, legacy)"
fi

# --- codetracer-native-test-programs ---
# Exports: CODETRACER_NATIVE_TEST_PROGRAMS_PATH
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-native-test-programs" ]; then
	export CODETRACER_NATIVE_TEST_PROGRAMS_PATH="$_CT_WORKSPACE_ROOT/codetracer-native-test-programs"
	_ct_detect_summary "codetracer-native-test-programs"
fi

# --- codetracer-python-recorder ---
# The Python recorder is a pip-installable module. The nix shell hook uses
# the _SRC vars to set up a venv with the recorder installed; the resulting
# `codetracer-python-recorder` console script ends up on PATH via the venv.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-python-recorder" ]; then
	export CODETRACER_PYTHON_RECORDER_SRC="$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-python-recorder"
	export CODETRACER_PYTHON_PURE_RECORDER_SRC="$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-pure-python-recorder"
	_ct_detect_summary "codetracer-python-recorder"
fi

# --- codetracer-ruby-recorder ---
# Prepends to PATH so `ct` finds recorders via findTool (same as end users).
# Prefer the native recorder (supports binary CTFS format); fall back to pure-Ruby.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-ruby-recorder/gems" ]; then
	export RUBY_RECORDER_ROOT="$_CT_WORKSPACE_ROOT/codetracer-ruby-recorder"
	if [ -x "$_CT_WORKSPACE_ROOT/codetracer-ruby-recorder/gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder" ]; then
		export PATH="$_CT_WORKSPACE_ROOT/codetracer-ruby-recorder/gems/codetracer-ruby-recorder/bin:$PATH"
		_ct_detect_summary "codetracer-ruby-recorder (native)"
	else
		echo "  WARNING: codetracer-ruby-recorder native extension not built." >&2
		echo "    Run: cd $_CT_WORKSPACE_ROOT/codetracer-ruby-recorder && just build-extension" >&2
		_ct_detect_summary "codetracer-ruby-recorder (gems present, not built)"
	fi
fi

# --- codetracer-js-recorder ---
# The JS recorder is a Node CLI (packages/cli/dist/index.js). After `npm install`
# it creates a bin symlink. We add the workspace node_modules/.bin to PATH so that
# `codetracer-js-recorder` is available as a command.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-js-recorder/packages/cli" ]; then
	if [ -x "$_CT_WORKSPACE_ROOT/codetracer-js-recorder/node_modules/.bin/codetracer-js-recorder" ]; then
		export PATH="$_CT_WORKSPACE_ROOT/codetracer-js-recorder/node_modules/.bin:$PATH"
	fi
	_ct_detect_summary "codetracer-js-recorder"
fi

# --- codetracer-beam-recorder (Erlang + Elixir; legacy alias: codetracer-elixir-recorder) ---
# Resolve the BEAM recorder repo. Prefer the explicit BEAM env var, then the
# legacy ELIXIR alias, then a workspace sibling scan that prefers
# codetracer-beam-recorder when both directories exist.
_ct_beam_recorder_path="${CODETRACER_BEAM_RECORDER_PATH:-${CODETRACER_ELIXIR_RECORDER_PATH:-}}"
if [ -z "$_ct_beam_recorder_path" ] && [ -n "$_CT_WORKSPACE_ROOT" ]; then
	if [ -d "$_CT_WORKSPACE_ROOT/codetracer-beam-recorder" ]; then
		_ct_beam_recorder_path="$_CT_WORKSPACE_ROOT/codetracer-beam-recorder"
	elif [ -d "$_CT_WORKSPACE_ROOT/codetracer-elixir-recorder" ]; then
		_ct_beam_recorder_path="$_CT_WORKSPACE_ROOT/codetracer-elixir-recorder"
	fi
fi
if [ -n "$_ct_beam_recorder_path" ] && [ -d "$_ct_beam_recorder_path" ]; then
	export CODETRACER_BEAM_RECORDER_PATH="$_ct_beam_recorder_path"
	# Keep the legacy alias populated for one release while downstream tooling
	# migrates to the BEAM-prefixed names.
	export CODETRACER_ELIXIR_RECORDER_PATH="$_ct_beam_recorder_path"
	for _ct_beam_profile in debug release; do
		# Prefer the BEAM binary name; fall back to the legacy elixir name.
		for _ct_beam_binary_name in codetracer-beam-recorder codetracer-elixir-recorder; do
			_ct_beam_bin="$_ct_beam_recorder_path/target/$_ct_beam_profile/$_ct_beam_binary_name"
			if [ -x "$_ct_beam_bin" ]; then
				export CODETRACER_BEAM_RECORDER_BIN="$_ct_beam_bin"
				export CODETRACER_ELIXIR_RECORDER_BIN="$_ct_beam_bin"
				export PATH="$_ct_beam_recorder_path/target/$_ct_beam_profile:$PATH"
				_ct_detect_summary "codetracer-beam-recorder ($_ct_beam_profile build, $_ct_beam_binary_name)"
				break 2
			fi
		done
	done
	if [ -z "${CODETRACER_BEAM_RECORDER_BIN:-}" ]; then
		_ct_detect_summary "codetracer-beam-recorder (repo present, binary not built)"
	fi
	unset _ct_beam_profile _ct_beam_bin _ct_beam_binary_name
fi
unset _ct_beam_recorder_path

# --- codetracer-shell-recorders ---
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-shell-recorders/bash-recorder" ]; then
	export PATH="$_CT_WORKSPACE_ROOT/codetracer-shell-recorders/bash-recorder:$_CT_WORKSPACE_ROOT/codetracer-shell-recorders/zsh-recorder:$PATH"
	_ct_detect_summary "codetracer-shell-recorders"
fi

# --- noir (metacraft-labs fork, provides nargo) ---
# Prepends to PATH so `ct` finds nargo via the same PATH search as end users.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/noir" ]; then
	if [ -x "$_CT_WORKSPACE_ROOT/noir/target/release/nargo" ]; then
		export PATH="$_CT_WORKSPACE_ROOT/noir/target/release:$PATH"
		_ct_detect_summary "noir (nargo release build)"
	elif [ -x "$_CT_WORKSPACE_ROOT/noir/target/debug/nargo" ]; then
		export PATH="$_CT_WORKSPACE_ROOT/noir/target/debug:$PATH"
		_ct_detect_summary "noir (nargo debug build)"
	else
		_ct_detect_summary "noir (repo present, nargo not built)"
	fi
fi

# --- codetracer-wasm-recorder ---
# The wazero binary lives in the repo root (not target/release/).
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-wasm-recorder" ]; then
	if [ -x "$_CT_WORKSPACE_ROOT/codetracer-wasm-recorder/wazero" ]; then
		export PATH="$_CT_WORKSPACE_ROOT/codetracer-wasm-recorder:$PATH"
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

# --- codetracer-trace-format-nim ---
# The wazero binary built with CGO links dynamically against
# `libcodetracer_trace_writer.so` (the Nim-built FFI surface from
# codetracer-trace-format-nim, distinct from the Rust trace-format crate
# above). The Nix builder bakes an RPATH into wazero pointing at the
# build-time output path, but once the build's nix-store output is
# garbage-collected (or in dev shells that swap that output for a sibling
# checkout) the binary fails with `libcodetracer_trace_writer.so: cannot
# open shared object file`. Export the sibling repo's library directory so
# the dynamic loader can resolve it. The Nim build drops the artefact at
# the repo root next to the .nimble manifest (`nim c --app:lib -o:...`).
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -f "$_CT_WORKSPACE_ROOT/codetracer-trace-format-nim/libcodetracer_trace_writer.so" ]; then
	export LD_LIBRARY_PATH="$_CT_WORKSPACE_ROOT/codetracer-trace-format-nim:${LD_LIBRARY_PATH:-}"
	_ct_detect_summary "codetracer-trace-format-nim (Nim FFI library available for wazero)"
fi

# --- Blockchain / VM recorder siblings ---
# Each blockchain recorder builds a binary at target/release/codetracer-<name>-recorder.
# We only prepend to PATH — no env var overrides — so `ct` uses the same findTool
# PATH search in development as it does on end-user machines.
for _ct_bc_name in cairo cardano circom evm flow fuel leo miden move polkavm solana ton native wasmi; do
	_ct_bc_repo="codetracer-${_ct_bc_name}-recorder"
	_ct_bc_bin="target/release/codetracer-${_ct_bc_name}-recorder"
	if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -x "$_CT_WORKSPACE_ROOT/$_ct_bc_repo/$_ct_bc_bin" ]; then
		export PATH="$_CT_WORKSPACE_ROOT/$_ct_bc_repo/target/release:$PATH"
		_ct_detect_summary "$_ct_bc_repo (release build)"
	fi
done
unset _ct_bc_name _ct_bc_repo _ct_bc_bin

# --- Cadence Go helper ---
# The Cadence/Flow recorder needs the cadence-trace-helper Go binary.
# Build it if the source exists and the binary is missing or outdated.
_ct_flow_repo="$_CT_WORKSPACE_ROOT/codetracer-flow-recorder"
if [ -d "$_ct_flow_repo/go-helper" ] && [ -n "${CODETRACER_FLOW_RECORDER_PATH:-}" ]; then
	_ct_cadence_helper="$_ct_flow_repo/target/debug/cadence-trace-helper"
	if [ ! -x "$_ct_cadence_helper" ] || [ "$_ct_flow_repo/go-helper/main.go" -nt "$_ct_cadence_helper" ]; then
		mkdir -p "$_ct_flow_repo/target/debug"
		if command -v go >/dev/null 2>&1; then
			(cd "$_ct_flow_repo/go-helper" && go build -o "$_ct_cadence_helper" . 2>/dev/null) &&
				_ct_detect_summary "cadence-trace-helper (built)" || true
		fi
	fi
	if [ -x "$_ct_cadence_helper" ]; then
		export CADENCE_HELPER_BIN="$_ct_cadence_helper"
		export PATH="$_ct_flow_repo/target/debug:$PATH"
	fi
fi
unset _ct_flow_repo _ct_cadence_helper

# ---------------------------------------------------------------------------
# Backward compatibility: derive _PRESENT=1 from `command -v` on PATH.
# These are used by tests that conditionally skip when a recorder isn't available.
# ---------------------------------------------------------------------------
command -v ct-native-replay &>/dev/null && export CODETRACER_RR_BACKEND_PRESENT=1
command -v wazero &>/dev/null && export CODETRACER_WASM_RECORDER_PRESENT=1

# Note: Python interpreter detection was removed. The Python recorder is now
# invoked as a standalone binary (codetracer-python-recorder) found via PATH,
# just like every other recorder. The venv setup in the nix shell hook handles
# installing the module and placing the binary on PATH.

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
