#!/usr/bin/env bash
# =============================================================================
# Build cross-repo dependencies that CodeTracer's GUI/E2E tests need.
#
# For each sibling repo that exists in the workspace, this script invokes the
# repo's own dev-shell-built `just` target (via `direnv exec`) to produce the
# binary that `scripts/detect-siblings.sh` looks for. Without this step a
# significant slice of the GUI test suite silently skips (blockchain language
# program_specific_tests, ct-mcr-based browser-mcr-replay, noir-space-ship,
# etc.) because the binaries simply aren't on PATH.
#
# Usage:
#   bash scripts/build-siblings.sh                # build everything available
#   bash scripts/build-siblings.sh --only ruby    # build only matching siblings
#   bash scripts/build-siblings.sh --skip noir    # skip matching siblings
#   bash scripts/build-siblings.sh --check        # report what's missing, build nothing
#
# Environment:
#   BUILD_SIBLINGS_VERBOSE=1  — stream child build output to stderr instead of
#                               capturing it into a per-repo log file.
#
# Conventions:
#   - All builds are run via `direnv exec <repo> <cmd>` so each repo's flake
#     pins the toolchain. This matches what end users do interactively.
#   - Each entry knows the output artifact path and skips if it's already
#     present (`--force` overrides). Builds are idempotent: re-running is cheap.
#   - Failures in one repo do NOT abort the rest — the script reports a
#     per-repo PASS/SKIP/FAIL summary and exits non-zero only if any FAILs.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WS_ROOT="$(cd "$CT_ROOT/.." && pwd)"

# Parse arguments.
FORCE=0
CHECK_ONLY=0
ONLY_PATTERN=""
SKIP_PATTERN=""
while [ $# -gt 0 ]; do
	case "$1" in
	--force)
		FORCE=1
		shift
		;;
	--check)
		CHECK_ONLY=1
		shift
		;;
	--only)
		ONLY_PATTERN="$2"
		shift 2
		;;
	--skip)
		SKIP_PATTERN="$2"
		shift 2
		;;
	-h | --help)
		sed -n '/^# Usage:/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		echo "build-siblings.sh: unknown option '$1'" >&2
		exit 2
		;;
	esac
done

# direnv must be on PATH so each sibling's flake provides its own toolchain.
if ! command -v direnv >/dev/null 2>&1; then
	echo "build-siblings.sh: ERROR: direnv not found on PATH." >&2
	echo "  Run this script from inside the codetracer dev shell (just/justfile, direnv exec, etc.)." >&2
	exit 1
fi

# Resolve nim/nimble from the codetracer dev shell so blockchain recorders
# can transitively build `codetracer_trace_writer_nim` (a Rust crate whose
# build.rs shells out to nimble).  The blockchain recorder flakes don't
# include Nim, so without this injection their builds fail with
# `failed to run nimble`.  Pinning nim+nimble paths via the codetracer flake
# also keeps the toolchain consistent across recorders.
# shellcheck disable=SC2016
# Single quotes are intentional: $(command -v ...) must be expanded by the
# child shell that direnv spawns, not by this parent shell.
NIM_TOOLCHAIN_BIN="$(
	direnv exec "$CT_ROOT" bash -c 'dirname "$(command -v nim)"' 2>/dev/null
)"
# shellcheck disable=SC2016
NIMBLE_TOOLCHAIN_BIN="$(
	direnv exec "$CT_ROOT" bash -c 'dirname "$(command -v nimble)"' 2>/dev/null
)"
if [ -z "$NIM_TOOLCHAIN_BIN" ] || [ -z "$NIMBLE_TOOLCHAIN_BIN" ]; then
	echo "build-siblings.sh: WARNING: could not resolve nim/nimble from codetracer dev shell." >&2
	echo "  Blockchain recorder builds that depend on codetracer_trace_writer_nim will fail." >&2
fi
EXTRA_NIM_PATH=""
if [ -n "$NIM_TOOLCHAIN_BIN" ]; then
	EXTRA_NIM_PATH="$NIM_TOOLCHAIN_BIN"
fi
if [ -n "$NIMBLE_TOOLCHAIN_BIN" ] && [ "$NIMBLE_TOOLCHAIN_BIN" != "$NIM_TOOLCHAIN_BIN" ]; then
	EXTRA_NIM_PATH="${EXTRA_NIM_PATH:+$EXTRA_NIM_PATH:}$NIMBLE_TOOLCHAIN_BIN"
fi
export EXTRA_NIM_PATH

# codetracer-trace-format-nim needs libzstd headers and library paths while
# building its Nim FFI library. Resolve them from the codetracer dev shell,
# which already pins zstd for the main workspace.
ZSTD_CFLAGS="$(
	direnv exec "$CT_ROOT" bash -c 'pkg-config --cflags libzstd 2>/dev/null || pkg-config --cflags zstd 2>/dev/null' 2>/dev/null
)"
ZSTD_LIBS="$(
	direnv exec "$CT_ROOT" bash -c 'pkg-config --libs libzstd 2>/dev/null || pkg-config --libs zstd 2>/dev/null' 2>/dev/null
)"
if [ -z "$ZSTD_CFLAGS" ] || [ -z "$ZSTD_LIBS" ]; then
	echo "build-siblings.sh: WARNING: could not resolve zstd from codetracer dev shell." >&2
	echo "  codetracer-trace-format-nim may fail to compile zstd bindings." >&2
fi

# Per-repo results.
declare -A RESULT_STATE  # repo -> PASS|SKIP|FAIL|MISSING
declare -A RESULT_DETAIL # repo -> human-readable detail

LOG_DIR="${CT_ROOT}/.tools/build-siblings-logs"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Helper: should we run this repo?
# ---------------------------------------------------------------------------
should_skip() {
	local repo="$1"
	if [ -n "$ONLY_PATTERN" ]; then
		[[ $repo != *"$ONLY_PATTERN"* ]] && return 0
	fi
	if [ -n "$SKIP_PATTERN" ]; then
		[[ $repo == *"$SKIP_PATTERN"* ]] && return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Helper: run a build step for one repo.
#   $1 — repo directory name (under WS_ROOT)
#   $2 — artifact path (relative to repo) used to short-circuit if present
#   $3 — build command (executed under `direnv exec <repo>`)
#   $4 — optional logical key (defaults to $1).  Use this when a single repo
#        produces multiple artifacts (e.g. flow recorder = Rust crate + Go
#        helper) so each step gets its own result row.
#   $5 — optional direnv repo (defaults to $1).  Use this when a sibling has no
#        usable direnv shell but can be built from another pinned dev shell.
# ---------------------------------------------------------------------------
build_sibling() {
	local repo="$1"
	local artifact="$2"
	local cmd="$3"
	local key="${4:-$1}"
	local env_repo="${5:-$repo}"

	if should_skip "$key"; then return 0; fi

	local repo_dir="$WS_ROOT/$repo"
	if [ ! -d "$repo_dir" ]; then
		RESULT_STATE[$key]="MISSING"
		RESULT_DETAIL[$key]="repo not checked out at $repo_dir"
		return 0
	fi

	local env_dir="$WS_ROOT/$env_repo"
	if [ ! -d "$env_dir" ]; then
		RESULT_STATE[$key]="MISSING"
		RESULT_DETAIL[$key]="direnv repo not checked out at $env_dir"
		return 0
	fi

	local artifact_path="$repo_dir/$artifact"
	if [ "$FORCE" -eq 0 ] && [ -e "$artifact_path" ]; then
		RESULT_STATE[$key]="SKIP"
		RESULT_DETAIL[$key]="already built ($artifact)"
		return 0
	fi

	if [ "$CHECK_ONLY" -eq 1 ]; then
		RESULT_STATE[$key]="MISSING"
		RESULT_DETAIL[$key]="would build → $artifact"
		return 0
	fi

	# Sanitize key for log filename (no slashes).
	local log_name="${key//\//__}"
	local log="$LOG_DIR/${log_name}.log"
	echo "[build-siblings] $key: building → $artifact (log: $log)" >&2

	# Prepend codetracer's nim/nimble paths so transitive Nim builds work in
	# sibling dev shells that don't bundle Nim (every blockchain recorder).
	local wrapped_cmd="$cmd"
	if [ -n "${EXTRA_NIM_PATH:-}" ]; then
		wrapped_cmd="export PATH=\"$EXTRA_NIM_PATH:\$PATH\"; $cmd"
	fi

	local rc=0
	if [ "${BUILD_SIBLINGS_VERBOSE:-0}" = "1" ]; then
		(cd "$repo_dir" && direnv exec "$env_dir" bash -c "$wrapped_cmd") || rc=$?
	else
		(cd "$repo_dir" && direnv exec "$env_dir" bash -c "$wrapped_cmd") >"$log" 2>&1 || rc=$?
	fi

	if [ "$rc" -ne 0 ]; then
		RESULT_STATE[$key]="FAIL"
		RESULT_DETAIL[$key]="build exited $rc — see $log"
		return 0
	fi

	if [ ! -e "$artifact_path" ]; then
		RESULT_STATE[$key]="FAIL"
		RESULT_DETAIL[$key]="build succeeded but $artifact still missing — see $log"
		return 0
	fi

	RESULT_STATE[$key]="PASS"
	RESULT_DETAIL[$key]="built $artifact"
}

ensure_submodules() {
	local repo="$1"
	shift

	local repo_dir="$WS_ROOT/$repo"
	if [ ! -d "$repo_dir" ]; then
		return 0
	fi

	local needs_update=0
	local path
	for path in "$@"; do
		if [ ! -e "$repo_dir/$path/.git" ]; then
			needs_update=1
		fi
	done

	if [ "$needs_update" -eq 1 ]; then
		echo "[build-siblings] $repo: initializing git submodules: $*" >&2
		git -C "$repo_dir" submodule update --init --recursive -- "$@"
	fi
}

# ---------------------------------------------------------------------------
# Build steps — one per sibling repo.  Order matters where there are deps:
# trace-format / trace-format-nim provide FFI libs that wazero loads, so
# build them first.
# ---------------------------------------------------------------------------

# Rust FFI for trace format (provides libcodetracer_trace_writer_ffi.so).
build_sibling \
	codetracer-trace-format \
	target/release/libcodetracer_trace_writer_ffi.so \
	"cargo build --release"

# Nim FFI shared lib (libcodetracer_trace_writer.so, used by wazero with CGO).
trace_format_nim_cmd="nimble buildSharedLib"
if [ -n "$ZSTD_CFLAGS" ] && [ -n "$ZSTD_LIBS" ]; then
	trace_format_nim_cmd="export NIX_CFLAGS_COMPILE=\"\${NIX_CFLAGS_COMPILE:-} $ZSTD_CFLAGS\"; export NIX_LDFLAGS=\"\${NIX_LDFLAGS:-} $ZSTD_LIBS\"; nimble buildSharedLib"
fi
build_sibling \
	codetracer-trace-format-nim \
	libcodetracer_trace_writer.so \
	"$trace_format_nim_cmd"

# Native backend (ct-native-replay). Its own direnv/flake can reject freshly
# initialized submodules in repo-managed checkouts, so build it the same way
# the local justfile does: borrow codetracer's dev shell and compile in-place.
if ! should_skip codetracer-native-backend; then
	ensure_submodules codetracer-native-backend libs/rr libs/delve
fi
# shellcheck disable=SC2016
native_backend_cmd='if [ -z "${LLVM_CONFIG:-}" ]; then llvm_dev="$(nix build --no-link --print-out-paths nixpkgs#llvm.dev)"; export LLVM_CONFIG="$llvm_dev/bin/llvm-config"; fi; if [ -z "${LLDB_LIB_PATH:-}" ]; then lldb_out="$(nix build --no-link --print-out-paths nixpkgs#lldb)"; export LLDB_LIB_PATH="$lldb_out/lib"; fi; if [ -z "${LLDB_ADDITIONAL_INCLUDE_DIRS:-}" ]; then lldb_dev="$(nix build --no-link --print-out-paths nixpkgs#lldb.dev)"; export LLDB_ADDITIONAL_INCLUDE_DIRS="$lldb_dev/include"; fi; export LIBRARY_PATH="$LLDB_LIB_PATH${LIBRARY_PATH:+:$LIBRARY_PATH}"; export LD_LIBRARY_PATH="$LLDB_LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; cargo build --bin ct-native-replay'
build_sibling \
	codetracer-native-backend \
	target/debug/ct-native-replay \
	"$native_backend_cmd" \
	codetracer-native-backend \
	codetracer

# MCR / native recorder (ct_cli aka ct-mcr).
build_sibling \
	codetracer-native-recorder \
	ct_cli/ct_cli \
	"just build-ct-mcr"

# Ruby native extension.  The build target installs into the gem dir; the
# detect-siblings check is for the wrapper binary at
# gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder.
build_sibling \
	codetracer-ruby-recorder \
	gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder \
	"just build-extension"

# wazero (Go binary; lives at the repo root, not target/release).
build_sibling \
	codetracer-wasm-recorder \
	wazero \
	"go build -o wazero ./cmd/wazero" \
	codetracer-wasm-recorder \
	codetracer

# noir / nargo.
build_sibling \
	noir \
	target/release/nargo \
	"cargo build --release --package nargo_cli --bin nargo" \
	noir \
	codetracer

# Cadence Go helper used by the flow recorder.  Distinct logical key so its
# result row doesn't collide with the codetracer-flow-recorder Rust crate
# build below.
build_sibling \
	codetracer-flow-recorder \
	target/debug/cadence-trace-helper \
	"mkdir -p target/debug && cd go-helper && go build -o ../target/debug/cadence-trace-helper ." \
	codetracer-flow-recorder/cadence-trace-helper

# Blockchain / VM recorders.  Each produces target/release/codetracer-<name>-recorder.
#
# wasmi is intentionally excluded: it is an upstream-wasmi fork on the
# `wasm-tracing` branch (no Justfile, no flake, no `codetracer-wasmi-recorder`
# binary — wasmi_cli is what gets built).  ct doesn't reference it by binary
# name in src/, so it's effectively a research repo, not a recorder
# produced via this script.
for name in cairo cardano circom evm flow fuel leo miden move polkavm solana ton; do
	build_sibling \
		"codetracer-${name}-recorder" \
		"target/release/codetracer-${name}-recorder" \
		"just build-release"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" >&2
echo "==== build-siblings summary ====" >&2
fail_count=0
pass_count=0
skip_count=0
missing_count=0
for repo in $(printf '%s\n' "${!RESULT_STATE[@]}" | sort); do
	state="${RESULT_STATE[$repo]}"
	detail="${RESULT_DETAIL[$repo]}"
	case "$state" in
	PASS) pass_count=$((pass_count + 1)) ;;
	SKIP) skip_count=$((skip_count + 1)) ;;
	FAIL) fail_count=$((fail_count + 1)) ;;
	MISSING) missing_count=$((missing_count + 1)) ;;
	esac
	printf "  %-7s %-40s %s\n" "$state" "$repo" "$detail" >&2
done
echo "  ---" >&2
printf "  %d pass, %d already built, %d missing, %d failed\n" \
	"$pass_count" "$skip_count" "$missing_count" "$fail_count" >&2

if [ "$fail_count" -gt 0 ]; then
	exit 1
fi
exit 0
