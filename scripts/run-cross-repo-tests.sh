#!/usr/bin/env bash
#
# run-cross-repo-tests.sh — Run codetracer flow integration tests against
# a built ct-rr-support binary from the rr-backend repo.
#
# Usage:
#   ./scripts/run-cross-repo-tests.sh [OPTIONS] [SELECTOR...]
#
# Selectors (db-backend tests, need ct-rr-support):
#   nim-flow    Run Nim flow integration tests
#   rust-flow   Run Rust flow integration tests
#   go-flow     Run Go flow integration tests
#   lean-flow   Run Lean build/record/replay tests
#
# Selectors (rr-backend tests, need db-backend):
#   c-flow      Run C flow tests (in rr-backend repo)
#   cpp-flow    Run C++ flow tests (in rr-backend repo)
#   d-flow      Run D flow tests (in rr-backend repo)
#   pascal-flow Run Pascal flow tests (in rr-backend repo)
#
#   all         Run all flow integration tests (default)
#
# Options:
#   --soft, --soft-mode   Set CODETRACER_RR_SOFT_MODE=1
#   --help, -h            Show this help message
#
# Environment variables (optional overrides):
#   CT_RR_SUPPORT_PATH           Path to a pre-built ct-rr-support binary
#   METACRAFT_WORKSPACE_ROOT     Workspace root containing codetracer-rr-backend
#   RR_BACKEND_REF               Git ref to clone (CI only, default: from pin file)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIN_FILE="$REPO_ROOT/.github/rr-backend-pin.txt"
LOG_DIR="$REPO_ROOT/target/cross-test-logs"
CLONE_DIR="$REPO_ROOT/target/rr-backend-clone"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die() {
	echo "ERROR: $*" >&2
	exit 1
}

usage() {
	sed -n '2,/^$/{ s/^#//; s/^ //; p }' "$0"
	exit 0
}

timestamp() { date '+%Y%m%d-%H%M%S'; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SOFT_MODE=""
SELECTORS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--soft | --soft-mode)
		SOFT_MODE=1
		shift
		;;
	--help | -h)
		usage
		;;
	-*)
		die "Unknown option: $1 (try --help)"
		;;
	*)
		SELECTORS+=("$1")
		shift
		;;
	esac
done

# Default selector
if [[ ${#SELECTORS[@]} -eq 0 ]]; then
	SELECTORS=("all")
fi

# Expand "all" selector
expand_selectors() {
	local expanded=()
	for sel in "${SELECTORS[@]}"; do
		case "$sel" in
		all)
			expanded+=(nim-flow rust-flow go-flow lean-flow c-flow cpp-flow d-flow pascal-flow)
			;;
		nim-flow | rust-flow | go-flow | lean-flow | c-flow | cpp-flow | d-flow | pascal-flow)
			expanded+=("$sel")
			;;
		*)
			die "Unknown selector: $sel (valid: nim-flow, rust-flow, go-flow, lean-flow, c-flow, cpp-flow, d-flow, pascal-flow, all)"
			;;
		esac
	done
	SELECTORS=("${expanded[@]}")
}

expand_selectors

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------
check_prerequisites() {
	local missing=()

	command -v cargo >/dev/null 2>&1 || missing+=("cargo")
	command -v rustc >/dev/null 2>&1 || missing+=("rustc")
	command -v rr >/dev/null 2>&1 || missing+=("rr")

	if [[ ${#missing[@]} -gt 0 ]]; then
		die "Missing required tools: ${missing[*]}"
	fi

	# Warn about optional tools per selector
	for sel in "${SELECTORS[@]}"; do
		case "$sel" in
		nim-flow)
			command -v nim >/dev/null 2>&1 || warn "nim not found — nim-flow tests may fail"
			;;
		go-flow)
			command -v go >/dev/null 2>&1 || warn "go not found — go-flow tests may fail"
			command -v dlv >/dev/null 2>&1 || warn "dlv not found — go-flow tests may fail"
			;;
		c-flow)
			command -v gcc >/dev/null 2>&1 || warn "gcc not found — c-flow tests may fail"
			;;
		cpp-flow)
			command -v g++ >/dev/null 2>&1 || warn "g++ not found — cpp-flow tests may fail"
			;;
		d-flow)
			command -v ldc2 >/dev/null 2>&1 || warn "ldc2 not found — d-flow tests may fail"
			;;
		pascal-flow)
			command -v fpc >/dev/null 2>&1 || warn "fpc not found — pascal-flow tests may fail"
			;;
		lean-flow)
			command -v lake >/dev/null 2>&1 || warn "lake not found — lean-flow tests may fail"
			command -v lean >/dev/null 2>&1 || warn "lean not found — lean-flow tests may fail"
			;;
		esac
	done
}

check_prerequisites

# ---------------------------------------------------------------------------
# Resolve pinned rr-backend ref (for CI cloning)
# ---------------------------------------------------------------------------
resolve_pin_ref() {
	if [[ -n ${RR_BACKEND_REF:-} ]]; then
		echo "$RR_BACKEND_REF"
		return
	fi
	if [[ -f $PIN_FILE ]]; then
		local ref
		ref="$(head -1 "$PIN_FILE" | tr -d '[:space:]')"
		if [[ -n $ref ]]; then
			echo "$ref"
			return
		fi
	fi
	echo "main"
}

# ---------------------------------------------------------------------------
# Find or build ct-rr-support
# ---------------------------------------------------------------------------
find_rr_backend_repo() {
	# 1. METACRAFT_WORKSPACE_ROOT
	if [[ -n ${METACRAFT_WORKSPACE_ROOT:-} ]]; then
		local candidate="$METACRAFT_WORKSPACE_ROOT/codetracer-rr-backend"
		if [[ -d $candidate ]]; then
			echo "$candidate"
			return 0
		fi
	fi

	# 2. Sibling directory
	local sibling="$REPO_ROOT/../codetracer-rr-backend"
	if [[ -d $sibling ]]; then
		(cd "$sibling" && pwd)
		return 0
	fi

	return 1
}

find_binary_in_repo() {
	local repo_dir="$1"
	# Prefer release, then debug
	for profile in release debug; do
		local bin="$repo_dir/target/$profile/ct-rr-support"
		if [[ -x $bin ]]; then
			echo "$bin"
			return 0
		fi
	done
	return 1
}

resolve_ct_rr_support() {
	# 1. Explicit env var
	if [[ -n ${CT_RR_SUPPORT_PATH:-} ]]; then
		if [[ -x $CT_RR_SUPPORT_PATH ]]; then
			log "Using CT_RR_SUPPORT_PATH=$CT_RR_SUPPORT_PATH"
			return 0
		else
			warn "CT_RR_SUPPORT_PATH='$CT_RR_SUPPORT_PATH' is not executable; searching further"
		fi
	fi

	# 2. Find rr-backend repo locally
	local rr_repo
	if rr_repo="$(find_rr_backend_repo)"; then
		log "Found rr-backend repo at $rr_repo"
		local bin
		if bin="$(find_binary_in_repo "$rr_repo")"; then
			export CT_RR_SUPPORT_PATH="$bin"
			log "Using ct-rr-support: $CT_RR_SUPPORT_PATH"
			return 0
		fi

		# In CI, build it
		if [[ ${CI:-} == "true" ]]; then
			log "CI mode: building ct-rr-support in $rr_repo ..."
			(cd "$rr_repo" && cargo build)
			if bin="$(find_binary_in_repo "$rr_repo")"; then
				export CT_RR_SUPPORT_PATH="$bin"
				log "Built ct-rr-support: $CT_RR_SUPPORT_PATH"
				return 0
			fi
			die "cargo build succeeded but ct-rr-support binary not found in $rr_repo/target/"
		fi

		die "ct-rr-support binary not found in $rr_repo/target/{debug,release}/. Please build it first:
  cd $rr_repo && cargo build"
	fi

	# 3. CI: clone and build
	if [[ ${CI:-} == "true" ]]; then
		local ref
		ref="$(resolve_pin_ref)"
		log "CI mode: cloning codetracer-rr-backend at ref '$ref' into $CLONE_DIR ..."

		if [[ -d "$CLONE_DIR/.git" ]]; then
			log "Reusing existing clone, fetching and checking out $ref ..."
			(cd "$CLONE_DIR" && git fetch origin && git checkout "$ref" && git submodule update --init --recursive)
		else
			rm -rf "$CLONE_DIR"
			git clone --recursive \
				"https://github.com/metacraft-labs/codetracer-rr-backend.git" \
				"$CLONE_DIR"
			(cd "$CLONE_DIR" && git checkout "$ref" && git submodule update --init --recursive)
		fi

		log "Building ct-rr-support ..."
		(cd "$CLONE_DIR" && cargo build)

		local bin
		if bin="$(find_binary_in_repo "$CLONE_DIR")"; then
			export CT_RR_SUPPORT_PATH="$bin"
			log "Built ct-rr-support: $CT_RR_SUPPORT_PATH"
			return 0
		fi
		die "Build succeeded but ct-rr-support binary not found"
	fi

	# 4. Local: error
	die "Could not find codetracer-rr-backend repository.
Please either:
  - Set CT_RR_SUPPORT_PATH to a pre-built ct-rr-support binary
  - Clone codetracer-rr-backend next to this repo and build it:
      cd .. && git clone <rr-backend-url> codetracer-rr-backend
      cd codetracer-rr-backend && cargo build
  - Set METACRAFT_WORKSPACE_ROOT to the parent of both repos"
}

resolve_ct_rr_support

# ---------------------------------------------------------------------------
# Resolve LD_LIBRARY_PATH for ct-rr-support
# ---------------------------------------------------------------------------
# ct-rr-support is typically built inside the rr-backend's nix shell, which
# provides shared libraries (e.g. liblldb, libstdc++) that are not present in
# the codetracer nix shell. We need to capture those library paths and export
# them so the binary can run.
resolve_rr_backend_lib_path() {
	# If CT_RR_SUPPORT_LD_LIBRARY_PATH is already set explicitly, use it.
	if [[ -n ${CT_RR_SUPPORT_LD_LIBRARY_PATH:-} ]]; then
		log "Using explicit CT_RR_SUPPORT_LD_LIBRARY_PATH"
		export LD_LIBRARY_PATH="${CT_RR_SUPPORT_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
		return 0
	fi

	# Try to find the rr-backend repo to query its nix shell
	local rr_repo=""
	if rr_repo="$(find_rr_backend_repo)" || [[ -d "$CLONE_DIR/flake.nix" ]]; then
		rr_repo="${rr_repo:-$CLONE_DIR}"
	fi

	if [[ -n $rr_repo ]] && [[ -f "$rr_repo/flake.nix" ]]; then
		log "Querying rr-backend nix shell for LD_LIBRARY_PATH..."
		local rr_raw rr_ld
		# Use a unique marker to extract the value from potentially noisy output
		# (nix develop may print banners/warnings to stdout)
		# shellcheck disable=SC2016
		rr_raw="$(cd "$rr_repo" && nix develop --command bash -c \
			'echo "___LD_PATH_START___"; echo "$LD_LIBRARY_PATH"; echo "___LD_PATH_END___"' \
			2>/dev/null)" || true
		rr_ld="$(echo "$rr_raw" | sed -n '/___LD_PATH_START___/{n;p;}')"
		if [[ -n $rr_ld ]]; then
			log "Resolved rr-backend LD_LIBRARY_PATH: $rr_ld"
			export LD_LIBRARY_PATH="${rr_ld}:${LD_LIBRARY_PATH:-}"
			return 0
		fi
		warn "Could not resolve LD_LIBRARY_PATH from rr-backend nix shell"
	fi

	# Quick check: can the binary actually run?
	if "$CT_RR_SUPPORT_PATH" --version >/dev/null 2>&1; then
		return 0
	fi

	# Try to find missing libs via ldd
	local missing
	missing="$(ldd "$CT_RR_SUPPORT_PATH" 2>/dev/null | grep 'not found' || true)"
	if [[ -n $missing ]]; then
		warn "ct-rr-support has missing shared libraries:"
		warn "$missing"
		warn "Set CT_RR_SUPPORT_LD_LIBRARY_PATH to provide them, or run from the rr-backend nix shell"
	fi
}

resolve_rr_backend_lib_path

# ---------------------------------------------------------------------------
# Test execution
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

# Returns "db-backend" or "rr-backend" depending on where the test lives
selector_test_location() {
	case "$1" in
	nim-flow | rust-flow | go-flow | lean-flow) echo "db-backend" ;;
	c-flow | cpp-flow | d-flow | pascal-flow) echo "rr-backend" ;;
	*) die "Unknown selector: $1" ;;
	esac
}

# For db-backend tests: cargo test filter string
selector_to_test_name() {
	case "$1" in
	nim-flow) echo "test_nim_flow" ;;
	rust-flow) echo "test_rust_flow" ;;
	go-flow) echo "test_go_flow" ;;
	lean-flow) echo "test_lean" ;;
	*) die "Unknown db-backend selector: $1" ;;
	esac
}

# For rr-backend tests: integration test file name (without .rs)
selector_to_rr_test_file() {
	case "$1" in
	c-flow) echo "c_flow_test" ;;
	cpp-flow) echo "cpp_flow_test" ;;
	d-flow) echo "d_flow_test" ;;
	pascal-flow) echo "pascal_flow_test" ;;
	*) die "Unknown rr-backend selector: $1" ;;
	esac
}

OVERALL_EXIT=0
PASSED=()
FAILED=()
SKIPPED=()

run_test() {
	local selector="$1"
	local location
	location="$(selector_test_location "$selector")"
	local ts
	ts="$(timestamp)"
	local log_file="$LOG_DIR/${selector}-${ts}.log"

	# Build environment (common)
	local -a env_vars=()

	if [[ -n $SOFT_MODE ]]; then
		env_vars+=("CODETRACER_RR_SOFT_MODE=1")
	fi

	if [[ -n ${_RR_TRACE_DIR:-} ]]; then
		env_vars+=("_RR_TRACE_DIR=$_RR_TRACE_DIR")
	fi

	if [[ -n ${RUST_LOG:-} ]]; then
		env_vars+=("RUST_LOG=$RUST_LOG")
	fi

	local exit_code=0

	if [[ $location == "db-backend" ]]; then
		local test_name
		test_name="$(selector_to_test_name "$selector")"
		log "Running: $selector (db-backend test: $test_name)"

		env_vars+=("CT_RR_SUPPORT_PATH=$CT_RR_SUPPORT_PATH")

		(
			cd "$REPO_ROOT/src/db-backend"
			env "${env_vars[@]}" cargo test "$test_name" -- --nocapture
		) >"$log_file" 2>&1 || exit_code=$?
	else
		local test_file
		test_file="$(selector_to_rr_test_file "$selector")"
		log "Running: $selector (rr-backend test: $test_file)"

		# rr-backend tests need to find db-backend
		local db_backend_bin="$REPO_ROOT/src/build-debug/bin/db-backend"
		if [[ -x $db_backend_bin ]]; then
			env_vars+=("DB_BACKEND_BIN=$db_backend_bin")
		fi

		local rr_repo
		if ! rr_repo="$(find_rr_backend_repo)"; then
			log "SKIPPED: $selector (rr-backend repo not found)"
			SKIPPED+=("$selector")
			return
		fi

		# rr-backend tests must be compiled in the rr-backend's nix shell
		# (needs lldb-sys, llvm, etc. that aren't in the codetracer shell)
		local env_prefix=""
		for ev in "${env_vars[@]}"; do
			env_prefix+="export ${ev}; "
		done

		(
			cd "$rr_repo"
			if [[ -f flake.nix ]]; then
				nix develop --command bash -c "${env_prefix}cargo test --test $test_file -- --nocapture"
			else
				env "${env_vars[@]}" cargo test --test "$test_file" -- --nocapture
			fi
		) >"$log_file" 2>&1 || exit_code=$?
	fi

	if [[ $exit_code -eq 0 ]]; then
		log "PASSED: $selector"
		PASSED+=("$selector")
	else
		log "FAILED: $selector (exit code $exit_code)"
		log "Log file: $log_file"
		log "--- last 20 lines ---"
		tail -20 "$log_file" >&2 || true
		log "--- end of log ---"
		FAILED+=("$selector")
		OVERALL_EXIT=1
	fi
}

for selector in "${SELECTORS[@]}"; do
	run_test "$selector"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log "=============================="
log "Cross-repo test summary"
log "=============================="
[[ ${#PASSED[@]} -gt 0 ]] && log "  PASSED:  ${PASSED[*]}"
[[ ${#FAILED[@]} -gt 0 ]] && log "  FAILED:  ${FAILED[*]}"
[[ ${#SKIPPED[@]} -gt 0 ]] && log "  SKIPPED: ${SKIPPED[*]}"
log "=============================="

exit "$OVERALL_EXIT"
