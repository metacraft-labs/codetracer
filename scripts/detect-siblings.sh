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
#
# The binary's build-time RPATH points at the production Nix derivation
# output dir (`codetracer-native-recorder/outputs/out/lib`) which only
# exists when the recorder ships through a `nix build`.  In a dev-shell
# `cargo build`, that dir is empty and the dynamic loader can't find
# liblldb / libstdc++, so `ct-native-replay --help` aborts with
# `error while loading shared libraries`.  Patch the RPATH on first
# detection so subsequent invocations through PATH (including from
# language-recorder bench harnesses) work without LD_LIBRARY_PATH
# wrangling.  Idempotent: skips when patchelf is missing or the binary
# already points at a valid liblldb / libstdc++.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -x "$_CT_WORKSPACE_ROOT/codetracer-native-backend/target/debug/ct-native-replay" ]; then
	export PATH="$_CT_WORKSPACE_ROOT/codetracer-native-backend/target/debug:$PATH"
	if command -v patchelf >/dev/null 2>&1 && command -v ldd >/dev/null 2>&1; then
		if ldd "$_CT_WORKSPACE_ROOT/codetracer-native-backend/target/debug/ct-native-replay" 2>/dev/null | grep -qE "liblldb.*not found|libstdc\+\+.*not found"; then
			_ct_lldb_dir=""
			if command -v nix >/dev/null 2>&1; then
				_ct_lldb_dir="$(nix build --no-link --print-out-paths nixpkgs#lldb 2>/dev/null)/lib"
			fi
			_ct_stdcpp_dir=""
			if command -v g++ >/dev/null 2>&1; then
				_ct_stdcpp_dir="$(g++ -print-file-name=libstdc++.so 2>/dev/null | xargs -r dirname || true)"
			fi
			if [ -n "$_ct_lldb_dir" ] && [ -d "$_ct_lldb_dir" ] && [ -n "$_ct_stdcpp_dir" ] && [ -d "$_ct_stdcpp_dir" ]; then
				patchelf --set-rpath "$_ct_lldb_dir:$_ct_stdcpp_dir" "$_CT_WORKSPACE_ROOT/codetracer-native-backend/target/debug/ct-native-replay" 2>/dev/null || true
			fi
			unset _ct_lldb_dir _ct_stdcpp_dir
		fi
	fi
	_ct_detect_summary "codetracer-native-backend (ct-native-replay available)"
elif [ -n "$_CT_WORKSPACE_ROOT" ] && [ -x "$_CT_WORKSPACE_ROOT/codetracer-rr-backend/target/debug/ct-rr-support" ]; then
	export PATH="$_CT_WORKSPACE_ROOT/codetracer-rr-backend/target/debug:$PATH"
	_ct_detect_summary "codetracer-rr-backend (ct-rr-support available, legacy)"
fi

# --- codetracer-native-recorder (ct-mcr / Multi-Core Recorder) ---
# Exports CODETRACER_CT_MCR_CMD pointing at the built `ct_cli` binary, which is
# the same binary that ships as `ct-mcr` in production builds (the user-facing
# command name).  The recorder repo's Justfile builds the binary in-place at
# `ct_cli/ct_cli` (see codetracer-native-recorder/Justfile: `build-ct-mcr`).
#
# Why this matters: ct-native-replay (codetracer-native-backend) spawns the
# MCR debugserver via `ct-mcr` for `.ct` traces, and `ct host` invokes
# `ct-mcr export --portable` when importing MCR portable traces.  Both code
# paths look up the binary in this order:
#   1. $CODETRACER_CT_MCR_CMD (env var, exported here)
#   2. sibling-to-binary (`ct-mcr` next to the calling executable)
#   3. PATH search (`ct-mcr` or `ct_cli`)
# Without this block, the only path that resolves in a dev shell is (3) via
# PATH — but the binary is named `ct_cli`, not `ct-mcr`, so the Nim caller
# in `src/ct/online_sharing/mcr_enrichment.nim` (which only searches for
# `ct-mcr`) misses it.  Exporting the env var sidesteps both naming and
# location concerns.
#
# Also prepend the binary's directory to PATH so the Rust `find_ct_mcr` in
# codetracer-native-backend (which accepts either `ct-mcr` or `ct_cli`)
# always finds it via the same PATH lookup end users get.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -x "$_CT_WORKSPACE_ROOT/codetracer-native-recorder/ct_cli/ct_cli" ]; then
	export CODETRACER_CT_MCR_CMD="$_CT_WORKSPACE_ROOT/codetracer-native-recorder/ct_cli/ct_cli"
	export PATH="$_CT_WORKSPACE_ROOT/codetracer-native-recorder/ct_cli:$PATH"
	_ct_detect_summary "codetracer-native-recorder (ct-mcr available as ct_cli)"
elif [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-native-recorder" ]; then
	# Repo is present but ct_cli has not been built yet.  Surface a hint
	# rather than failing silently — tests that need ct-mcr (browser
	# MCR replay, three-trace-types, mcr_enrichment portable traces) will
	# otherwise fail with a confusing "ct-mcr binary not found" deep
	# inside the replay worker.
	echo "  WARNING: codetracer-native-recorder present but ct_cli not built." >&2
	echo "    Run: cd $_CT_WORKSPACE_ROOT/codetracer-native-recorder && just build-ct-mcr" >&2
	_ct_detect_summary "codetracer-native-recorder (repo present, ct_cli not built)"
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
#
# Additionally, when the codetracer dev-shell's
# `.python-recorder-venv/bin/python` interpreter has already been
# materialised by a previous `nix develop`, surface it via
# `CODETRACER_PYTHON_INTERPRETER`. The campaign's P1/P2/P3/P4 harness
# uses this var (vs. the `codetracer-python-recorder` console script on
# PATH) so the bench / e2e test can invoke `python -m codetracer_python_recorder`
# with `PYTHONPATH=$CODETRACER_PYTHON_RECORDER_SRC` directly — this is
# the route that works from sibling repos (e.g. codetracer-ci) whose
# own dev shell does not run the codetracer venv hook.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-python-recorder" ]; then
	export CODETRACER_PYTHON_RECORDER_SRC="$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-python-recorder"
	export CODETRACER_PYTHON_PURE_RECORDER_SRC="$_CT_WORKSPACE_ROOT/codetracer-python-recorder/codetracer-pure-python-recorder"
	if [ -x "$_CT_ROOT_DIR/.python-recorder-venv/bin/python" ]; then
		export CODETRACER_PYTHON_INTERPRETER="$_CT_ROOT_DIR/.python-recorder-venv/bin/python"
	elif [ -x "$_CT_WORKSPACE_ROOT/codetracer/.python-recorder-venv/bin/python" ]; then
		# Sibling repos that source this script (codetracer-ci,
		# codetracer-specs) won't find the venv under their own repo
		# root; fall back to the codetracer sibling's venv so the P1
		# E2E test harness picks up the recorder.
		export CODETRACER_PYTHON_INTERPRETER="$_CT_WORKSPACE_ROOT/codetracer/.python-recorder-venv/bin/python"
	fi
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
# it normally creates a bin symlink at node_modules/.bin/codetracer-js-recorder,
# but when the workspace's node_modules is provisioned by Nix (read-only
# derivation output) the bin symlink is not materialised — npm's workspace
# bin-installation step doesn't run inside the Nix builder.  Materialise a
# user-writable shim under <repo>/.bin/ that points at the built
# packages/cli/dist/index.js and prepend it to PATH; the operator just needs
# `direnv exec ../codetracer-js-recorder just build` to have run first so the
# napi addon (crates/recorder_native/index.node) + TypeScript dist are in
# place.  No silent skip — if the dist isn't built, the bench surfaces the
# recorder's stderr loudly.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-js-recorder/packages/cli" ]; then
	_ct_js_root="$_CT_WORKSPACE_ROOT/codetracer-js-recorder"
	# Preference order:
	#   1. The repo's `node_modules/.bin/` — present when `just build` ran
	#      in a writable workspace.
	#   2. `.install-shadow/node_modules/.bin/` — a user-writable shadow
	#      tree (hardlink mirror of packages/ + crates/) that operators
	#      bootstrap with `(cp -al packages crates .install-shadow/ &&
	#      cp package.json package-lock.json .install-shadow/ && cd
	#      .install-shadow && npm install --include=dev)` when the
	#      workspace's primary node_modules is Nix-managed read-only
	#      (the production case — the Nix derivation pre-bakes runtime
	#      deps but doesn't symlink the workspace `@codetracer/*`
	#      packages or expose the dev tooling).
	if [ -x "$_ct_js_root/node_modules/.bin/codetracer-js-recorder" ]; then
		export PATH="$_ct_js_root/node_modules/.bin:$PATH"
		_ct_detect_summary "codetracer-js-recorder (node_modules bin)"
	elif [ -x "$_ct_js_root/.install-shadow/node_modules/.bin/codetracer-js-recorder" ]; then
		export PATH="$_ct_js_root/.install-shadow/node_modules/.bin:$PATH"
		_ct_detect_summary "codetracer-js-recorder (install-shadow bin)"
	else
		echo "  WARNING: codetracer-js-recorder CLI not on PATH." >&2
		echo "    Run: cd $_ct_js_root && just build" >&2
		echo "    or:  cd $_ct_js_root && cp -al packages crates .install-shadow/ \\" >&2
		echo '              && cp package.json package-lock.json .install-shadow/ \' >&2
		echo "              && cd .install-shadow && npm install --include=dev" >&2
		_ct_detect_summary "codetracer-js-recorder (packages/cli present, not installed)"
	fi
	unset _ct_js_root
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
# Exports: library path for libcodetracer_trace_writer_ffi.so (needed by wazero)
#
# We export both LD_LIBRARY_PATH (for tools the user runs directly from the
# dev shell, e.g. wazero or a sibling recorder) and
# CODETRACER_RECORDER_LD_LIBRARY_PATH (for the chain that goes through `ct`).
# The latter exists because `ct` runs with Linux file capabilities
# (cap_bpf+cap_perfmon+cap_dac_read_search — applied by build-once.sh), and
# glibc's secure-execution mode unconditionally strips LD_LIBRARY_PATH from
# environ before ct's code runs.  CODETRACER_RECORDER_LD_LIBRARY_PATH carries
# the recorder-only entries through that scrub; ct's startup re-composition
# in src/ct/codetracer.nim then splices them back onto LD_LIBRARY_PATH for
# its subprocesses (db-backend-record → wazero etc.).
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/codetracer-trace-format/target/release" ]; then
	export LD_LIBRARY_PATH="$_CT_WORKSPACE_ROOT/codetracer-trace-format/target/release:${LD_LIBRARY_PATH:-}"
	export CODETRACER_RECORDER_LD_LIBRARY_PATH="$_CT_WORKSPACE_ROOT/codetracer-trace-format/target/release${CODETRACER_RECORDER_LD_LIBRARY_PATH:+:$CODETRACER_RECORDER_LD_LIBRARY_PATH}"
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
#
# See the comment above (codetracer-trace-format block) for why this is
# duplicated into CODETRACER_RECORDER_LD_LIBRARY_PATH — ct's file
# capabilities cause glibc to scrub LD_LIBRARY_PATH at exec time, so we
# carry the path through a non-LD_-prefixed env var that survives the
# scrub and is re-spliced onto LD_LIBRARY_PATH by ct's startup hook in
# src/ct/codetracer.nim.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -f "$_CT_WORKSPACE_ROOT/codetracer-trace-format-nim/libcodetracer_trace_writer.so" ]; then
	export LD_LIBRARY_PATH="$_CT_WORKSPACE_ROOT/codetracer-trace-format-nim:${LD_LIBRARY_PATH:-}"
	export CODETRACER_RECORDER_LD_LIBRARY_PATH="$_CT_WORKSPACE_ROOT/codetracer-trace-format-nim${CODETRACER_RECORDER_LD_LIBRARY_PATH:+:$CODETRACER_RECORDER_LD_LIBRARY_PATH}"
	_ct_detect_summary "codetracer-trace-format-nim (Nim FFI library available for wazero)"
fi

# --- Solana SBF SDK + platform-tools ---
# The codetracer-solana-recorder consumes an SBF `.so` ELF produced
# by `cargo-build-sbf` (Solana SBF toolchain).  The Nix-packaged
# `cargo-build-sbf` is missing its bundled `platform-tools-sdk/sbf`
# layout (a packaging gap in nix-blockchain-development) so the
# operator vendors the SDK as two sibling checkouts:
#
#   solana-platform-tools/  (download from
#       github.com/anza-xyz/platform-tools/releases/v1.52)
#   solana-sbf-sdk/
#       dependencies/platform-tools -> ../solana-platform-tools
#       scripts/{dump.sh,objcopy.sh,strip.sh}  (from agave v3.1.11
#       platform-tools-sdk/sbf/scripts/)
#
# We export SBF_SDK_PATH so cargo-build-sbf finds the SDK layout,
# RUSTC so it uses the platform-tools rustc (the Solana-patched one
# with the `sbpf-solana-solana` target), and prepend the
# platform-tools rust+llvm bin dirs to PATH so the helper scripts
# resolve.  The dynamic binaries the SDK ships are patchelf'd on
# first detection to use the Nix glibc interpreter + bundled
# zlib/libstdc++ (idempotent — skips when the interpreter is already
# /nix/store/...glibc...).
if [ -n "$_CT_WORKSPACE_ROOT" ] &&
	[ -d "$_CT_WORKSPACE_ROOT/solana-sbf-sdk/dependencies/platform-tools/rust/bin" ] &&
	[ -d "$_CT_WORKSPACE_ROOT/solana-sbf-sdk/scripts" ]; then
	_ct_sbf_pt="$_CT_WORKSPACE_ROOT/solana-sbf-sdk/dependencies/platform-tools"
	# patchelf pass — only when the rustc binary still points at the
	# generic-Linux interpreter (i.e. has never been patched).
	if command -v patchelf >/dev/null 2>&1 && command -v file >/dev/null 2>&1 &&
		file "$_ct_sbf_pt/rust/bin/rustc" 2>/dev/null | grep -q "/lib64/ld-linux"; then
		_ct_sbf_glibc=""
		if command -v nix >/dev/null 2>&1; then
			_ct_sbf_glibc="$(nix build --no-link --print-out-paths nixpkgs#glibc.out 2>/dev/null)"
			_ct_sbf_zlib="$(nix build --no-link --print-out-paths nixpkgs#zlib.out 2>/dev/null)"
		fi
		_ct_sbf_gcc=""
		if command -v g++ >/dev/null 2>&1; then
			_ct_sbf_gcc="$(g++ -print-file-name=libstdc++.so 2>/dev/null | xargs -r dirname || true)"
		fi
		if [ -n "$_ct_sbf_glibc" ] && [ -d "$_ct_sbf_glibc" ] && [ -n "$_ct_sbf_gcc" ]; then
			_ct_sbf_rpath="$_ct_sbf_pt/rust/lib:$_ct_sbf_pt/llvm/lib:$_ct_sbf_zlib/lib:$_ct_sbf_gcc:$_ct_sbf_glibc/lib"
			_ct_sbf_ld="$_ct_sbf_glibc/lib/ld-linux-x86-64.so.2"
			find "$_ct_sbf_pt" -type f \( -executable -o -name '*.so*' \) 2>/dev/null | while read -r _ct_sbf_f; do
				if file "$_ct_sbf_f" 2>/dev/null | grep -q 'dynamically linked\|ELF.*shared object'; then
					if file "$_ct_sbf_f" 2>/dev/null | grep -q 'pie executable\|executable'; then
						patchelf --set-interpreter "$_ct_sbf_ld" --set-rpath "$_ct_sbf_rpath" "$_ct_sbf_f" 2>/dev/null || true
					else
						patchelf --set-rpath "$_ct_sbf_rpath" "$_ct_sbf_f" 2>/dev/null || true
					fi
				fi
			done
		fi
		unset _ct_sbf_glibc _ct_sbf_zlib _ct_sbf_gcc _ct_sbf_rpath _ct_sbf_ld _ct_sbf_f
	fi
	export SBF_SDK_PATH="$_CT_WORKSPACE_ROOT/solana-sbf-sdk"
	export RUSTC="$_ct_sbf_pt/rust/bin/rustc"
	export PATH="$_ct_sbf_pt/rust/bin:$_ct_sbf_pt/llvm/bin:$PATH"
	_ct_detect_summary "solana-sbf-sdk (SBF_SDK_PATH + platform-tools)"
	unset _ct_sbf_pt
fi

# --- Cairo corelib vendoring ---
# The codetracer-cairo-recorder shells out to cairo-lang-compiler which
# needs the Cairo stdlib (`corelib`) at compile time.  The corelib is
# distributed separately from the recorder; we vendor it as a sibling
# checkout (`cairo-corelib-vendor`) pinned to the Cairo release matching
# the recorder's `cairo-lang-compiler = "2.17.0-rc.4"` dependency.  The
# corelib lives at `<sibling>/corelib/src` per the upstream layout.
if [ -n "$_CT_WORKSPACE_ROOT" ] && [ -d "$_CT_WORKSPACE_ROOT/cairo-corelib-vendor/corelib/src" ]; then
	export CAIRO_CORELIB_DIR="$_CT_WORKSPACE_ROOT/cairo-corelib-vendor/corelib/src"
	_ct_detect_summary "cairo-corelib-vendor (CAIRO_CORELIB_DIR exported)"
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
