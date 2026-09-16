#!/usr/bin/env bash
#
# run-cross-repo-tests.sh — Run codetracer flow integration tests against
# a built ct-native-replay binary from the native-backend repo.
#
# Usage:
#   ./scripts/run-cross-repo-tests.sh [OPTIONS] [SELECTOR...]
#
# Selectors (db-backend tests, need ct-native-replay):
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
#   CT_NATIVE_REPLAY_PATH        Path to a pre-built ct-native-replay binary
#                                (CT_RR_SUPPORT_PATH also accepted on input:
#                                 codetracer-native-backend's docs and its
#                                 own scripts/run-cross-repo-tests.sh still
#                                 use that spelling)
#   METACRAFT_WORKSPACE_ROOT     Workspace root containing codetracer-native-backend
#   RR_BACKEND_REF               Git ref to clone (explicit manual override).
#                                When unset, the rr-backend revision is resolved
#                                from the repo-workspaces workspace lock via
#                                scripts/resolve-sibling-rev.sh (a missing lock
#                                fails loudly; there is no "main" fallback).
#   CT_MANIFEST_DIR/CT_LOCK_SHA  CI-only: address the shallow manifest checkout
#                                and locked commit for the resolver. Unset
#                                locally, where the resolver auto-discovers
#                                .repo/manifests and walks from HEAD.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/target/cross-test-logs"
CLONE_DIR="$REPO_ROOT/target/rr-backend-clone"

# The repository's one spelling of "this artefact must be current with respect
# to its sources"; see the library's own header for why a cross-repo test
# runner shares a file with the doc captures.
# Read by the library; every diagnostic is prefixed with it.
# shellcheck disable=SC2034
CTDR_LABEL="run-cross-repo-tests"
# shellcheck source=scripts/docs/deep-review-capture-lib.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/docs/deep-review-capture-lib.sh"

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
# Resolve a sibling repo's workspace-locked revision via the single approved
# resolver. In CI, $CT_MANIFEST_DIR + $CT_LOCK_SHA address the shallow manifest
# checkout; locally, both are unset and the resolver auto-discovers
# .repo/manifests and walks from HEAD.
resolve_sibling_rev() { # $1 = sibling repo name
	local args=(--repo codetracer --sibling "$1")
	[ -n "${CT_MANIFEST_DIR:-}" ] && args+=(--manifest-dir "$CT_MANIFEST_DIR")
	[ -n "${CT_LOCK_SHA:-}" ] && args+=(--sha "$CT_LOCK_SHA" --no-walk)
	"$REPO_ROOT/scripts/resolve-sibling-rev.sh" "${args[@]}"
}

resolve_pin_ref() {
	# Explicit manual override (dispatch-style), if set.
	if [[ -n ${RR_BACKEND_REF:-} ]]; then
		echo "$RR_BACKEND_REF"
		return
	fi
	# Otherwise resolve from the workspace lock (fails loudly if unlocked).
	resolve_sibling_rev codetracer-native-backend
}

# ---------------------------------------------------------------------------
# Find or build ct-native-replay
# ---------------------------------------------------------------------------
find_rr_backend_repo() {
	# Only one name is searched: `codetracer-native-backend`, as declared by
	# the workspace manifest. This used to also try a `codetracer-rr-backend`
	# fallback for the repo's pre-rename name, but no such repository exists
	# — the slug redirects on GitHub and nothing ever checks out under it —
	# so the fallback could never match.

	# 1. METACRAFT_WORKSPACE_ROOT
	if [[ -n ${METACRAFT_WORKSPACE_ROOT:-} ]]; then
		local candidate="$METACRAFT_WORKSPACE_ROOT/codetracer-native-backend"
		if [[ -d $candidate ]]; then
			echo "$candidate"
			return 0
		fi
	fi

	# 2. Sibling directory
	local sibling="$REPO_ROOT/../codetracer-native-backend"
	if [[ -d $sibling ]]; then
		(cd "$sibling" && pwd)
		return 0
	fi

	return 1
}

# PRESENCE IS NOT THE LOCKED REVISION — THE TWIN OF `ci/setup-rr-backend.sh`.
#
# `resolve_pin_ref` above computes the workspace-locked revision of
# codetracer-native-backend, and until now this script used that value on ONE
# path only: the CI clone. When a sibling checkout was found on disk (the local
# path, and the CI path whenever `setup-dev-env` has pre-cloned one) the ref was
# never resolved and never compared — the one value that could have said whether
# the checkout is the pinned one was simply not computed. That is the exact
# defect `ci/setup-rr-backend.sh` carried, described at length in its
# `require_locked_checkout`, and this is the same refusal for the same sibling.
#
# It matters more here than it looks: what this script decides is which
# `ct-native-replay` the nim/rust/go/lean flow suites replay against, so a
# checkout at last month's revision produces a green cross-repo run that names
# no revision and measured the wrong backend.
#
# IT REFUSES RATHER THAN RE-CHECKING-OUT, for `require_locked_checkout`'s
# reason: a developer's sibling checkout with work in it and a reused CI
# workspace are the same directory to this script, and `git checkout` in the
# first is destructive. `RR_BACKEND_REF` states a different revision on purpose.
#
# A LOCK THAT CANNOT BE RESOLVED IS SAID OUT LOUD, not passed over. Unlike
# `ci/setup-rr-backend.sh`, this script is run by hand on workstations, where a
# commit with no workspace lock is ordinary; dying there would make the guard
# something people route around. So an unresolvable pin degrades to a spoken
# "this could not be asked" — and the mtime comparison below, which needs no
# lock at all, still runs.
require_locked_sibling_checkout() {
	local dir="$1" ref head want is_sha=0

	[[ -d "$dir/.git" ]] || {
		warn "cannot check which revision '$dir' is at — it is not a git checkout, so the workspace lock cannot be compared against it."
		return 0
	}
	if ! ref="$(resolve_pin_ref 2>/dev/null)" || [[ -z $ref ]]; then
		warn "cannot check whether '$dir' is at the workspace-locked revision of codetracer-native-backend — no lock resolved for this commit and RR_BACKEND_REF is unset. Set RR_BACKEND_REF to the revision you mean to have this checked."
		return 0
	fi

	head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" ||
		die "'$dir' has a .git but no resolvable HEAD; it is not a usable checkout of codetracer-native-backend."

	# A FULL SHA CAN BE ANSWERED LOCALLY; A BRANCH CANNOT. A reused checkout's
	# local `dev` is exactly as stale as the checkout sitting on it, so
	# resolving a moving ref locally would answer "is this the `dev` it was at
	# last week", which is not a freshness question. Same rule, same wording, as
	# `ci/setup-rr-backend.sh`.
	[[ $ref =~ ^[0-9a-f]{40}$ ]] && is_sha=1
	want=""
	if [[ $is_sha -eq 1 ]]; then
		want="$(git -C "$dir" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" || want=""
	fi
	if [[ -z $want ]]; then
		if [[ $is_sha -eq 0 ]]; then
			log "Ref '$ref' is a moving ref; re-fetching it so the comparison is against what it points at NOW."
		else
			log "Ref '$ref' is not known to the existing checkout; fetching it."
		fi
		if git -C "$dir" fetch --quiet origin "$ref" 2>/dev/null; then
			want="$(git -C "$dir" rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null)" || want=""
		fi
	fi

	if [[ -z $want ]]; then
		die "cannot tell whether the codetracer-native-backend at '$dir' is the revision this run is pinned to.
  it is at:      $head
  it must be at: $ref  (which this checkout could not resolve and could not fetch)
Fetch it there, re-provision the sibling, or set RR_BACKEND_REF to the revision you mean."
	fi

	if [[ $head != "$want" ]]; then
		die "stale codetracer-native-backend checkout at '$dir'.
  it is at:      $head
  it must be at: $want  (from ref '$ref')
This decides which ct-native-replay the flow suites replay against, so it is
refused rather than silently reused. Fix it with:
  git -C '$dir' checkout $want && git -C '$dir' submodule update --init --recursive
or set RR_BACKEND_REF to the revision you actually mean."
	fi

	log "codetracer-native-backend at '$dir' verified at $head"
}

# THE NEWEST BUILD, NOT THE FIRST ONE THAT EXISTS.
#
# This loop used to return `target/release/ct-native-replay` whenever it was
# executable, so a release binary from an arbitrarily old revision outranked a
# `target/debug` one built ten minutes ago — the two profiles are separate
# directories and neither build removes the other. "Prefer release" was a
# preference between two CURRENT builds; applied to whatever is on disk it is a
# preference for whichever happens to be older.
#
# The freshness question is asked of the winner separately, by
# `require_fresh_native_replay`; this only stops the choice itself from being
# made by existence.
find_binary_in_repo() {
	local repo_dir="$1" best="" profile bin
	# Release first, so that it still wins a tie between two builds of the same
	# revision — `-nt` is false for equal mtimes.
	for profile in release debug; do
		bin="$repo_dir/target/$profile/ct-native-replay"
		[[ -x $bin ]] || continue
		if [[ -z $best || $bin -nt $best ]]; then
			best="$bin"
		fi
	done
	[[ -n $best ]] || return 1
	echo "$best"
}

# EXECUTABILITY IS NOT CURRENCY, ASKED OF THE SIBLING'S OWN SOURCES.
#
# The revision check above answers "is this checkout the pinned one"; it says
# nothing about whether the binary in `target/` was built FROM that checkout.
# A `git checkout` of the locked revision leaves the previous revision's
# `ct-native-replay` sitting in `target/`, correctly pinned and completely
# stale, and the flow suites would replay against it.
#
# `git ls-files` in the sibling is used rather than a source pattern guessed
# from here, because this repository does not know and must not assume how
# codetracer-native-backend lays its sources out.
require_fresh_native_replay() {
	local bin="$1" repo_dir="$2"
	ctdr_require_sibling_binary_not_stale "ct-native-replay" "$bin" "$repo_dir" \
		"Build it with: cd '$repo_dir' && cargo build"
}

resolve_ct_native_replay() {
	# 1. Explicit env var (new name first, then legacy)
	for var_name in CT_NATIVE_REPLAY_PATH CT_RR_SUPPORT_PATH; do
		local val="${!var_name:-}"
		if [[ -n $val ]]; then
			if [[ -x $val ]]; then
				log "Using $var_name=$val"
				export CT_NATIVE_REPLAY_PATH="$val"
				return 0
			else
				warn "$var_name='$val' is not executable; searching further"
			fi
		fi
	done

	# 2. Find native-backend repo locally
	local rr_repo
	if rr_repo="$(find_rr_backend_repo)"; then
		log "Found native-backend repo at $rr_repo"
		require_locked_sibling_checkout "$rr_repo"

		# IN CI, BUILD FIRST — the build used to be conditional on no binary
		# being there, which is the same existence-as-freshness mistake one
		# level up: a `ct-native-replay` from a previous job on a reused
		# workspace suppressed the build entirely. `cargo build` is incremental,
		# so running it when the tree is already current costs a dependency scan
		# and nothing else, and it is the remedy the refusal below would name
		# anyway.
		if [[ ${CI:-} == "true" ]]; then
			log "CI mode: building ct-native-replay in $rr_repo ..."
			(cd "$rr_repo" && cargo build)
		fi

		local bin
		if bin="$(find_binary_in_repo "$rr_repo")"; then
			require_fresh_native_replay "$bin" "$rr_repo"
			export CT_NATIVE_REPLAY_PATH="$bin"
			log "Using ct-native-replay: $CT_NATIVE_REPLAY_PATH"
			return 0
		fi

		if [[ ${CI:-} == "true" ]]; then
			die "cargo build succeeded but ct-native-replay binary not found in $rr_repo/target/"
		fi

		die "ct-native-replay binary not found in $rr_repo/target/{debug,release}/. Please build it first:
  cd $rr_repo && cargo build"
	fi

	# 3. CI: clone and build
	if [[ ${CI:-} == "true" ]]; then
		local ref
		ref="$(resolve_pin_ref)"
		log "CI mode: cloning codetracer-native-backend at ref '$ref' into $CLONE_DIR ..."

		if [[ -d "$CLONE_DIR/.git" ]]; then
			log "Reusing existing clone, fetching and checking out $ref ..."
			(cd "$CLONE_DIR" && git fetch origin && git checkout "$ref" && git submodule update --init --recursive)
		else
			rm -rf "$CLONE_DIR"
			git clone --recursive \
				"https://github.com/metacraft-labs/codetracer-native-backend.git" \
				"$CLONE_DIR"
			(cd "$CLONE_DIR" && git checkout "$ref" && git submodule update --init --recursive)
		fi

		log "Building ct-native-replay ..."
		(cd "$CLONE_DIR" && cargo build)

		local bin
		if bin="$(find_binary_in_repo "$CLONE_DIR")"; then
			export CT_NATIVE_REPLAY_PATH="$bin"
			log "Built ct-native-replay: $CT_NATIVE_REPLAY_PATH"
			return 0
		fi
		die "Build succeeded but ct-native-replay binary not found"
	fi

	# 4. Local: error
	die "Could not find codetracer-native-backend repository.
Please either:
  - Set CT_NATIVE_REPLAY_PATH to a pre-built ct-native-replay binary
  - Clone codetracer-native-backend next to this repo and build it:
      cd .. && git clone <native-backend-url> codetracer-native-backend
      cd codetracer-native-backend && cargo build
  - Set METACRAFT_WORKSPACE_ROOT to the parent of both repos"
}

resolve_ct_native_replay

# ---------------------------------------------------------------------------
# Resolve LD_LIBRARY_PATH for ct-native-replay
# ---------------------------------------------------------------------------
# ct-native-replay is typically built inside the native-backend's nix shell, which
# provides shared libraries (e.g. liblldb, libstdc++) that are not present in
# the codetracer nix shell. We need to capture those library paths and export
# them so the binary can run.
resolve_rr_backend_lib_path() {
	# If CT_NATIVE_REPLAY_LD_LIBRARY_PATH is set, use it.
	local explicit_ld="${CT_NATIVE_REPLAY_LD_LIBRARY_PATH:-}"
	if [[ -n $explicit_ld ]]; then
		log "Using explicit LD_LIBRARY_PATH override"
		export LD_LIBRARY_PATH="${explicit_ld}:${LD_LIBRARY_PATH:-}"
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
	if "$CT_NATIVE_REPLAY_PATH" --version >/dev/null 2>&1; then
		return 0
	fi

	# Try to find missing libs via ldd
	local missing
	missing="$(ldd "$CT_NATIVE_REPLAY_PATH" 2>/dev/null | grep 'not found' || true)"
	if [[ -n $missing ]]; then
		warn "ct-native-replay has missing shared libraries:"
		warn "$missing"
		warn "Set CT_NATIVE_REPLAY_LD_LIBRARY_PATH to provide them, or run from the native-backend nix shell"
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

		env_vars+=("CT_NATIVE_REPLAY_PATH=$CT_NATIVE_REPLAY_PATH")

		(
			cd "$REPO_ROOT/src/db-backend"
			env "${env_vars[@]}" cargo test "$test_name" -- --nocapture
		) >"$log_file" 2>&1 || exit_code=$?
	else
		local test_file
		test_file="$(selector_to_rr_test_file "$selector")"
		log "Running: $selector (rr-backend test: $test_file)"

		# rr-backend tests need to find db-backend.
		#
		# EXECUTABILITY DECIDED THIS ONE TOO. The C/C++/D/Pascal flow suites
		# replay through whatever `DB_BACKEND_BIN` names, and `-x` says only
		# that a build happened at some point — `src/build-debug/bin/db-backend`
		# is never deleted. Handing an old replay engine to four suites that
		# then go green is the whole defect, so it is refused here instead.
		local db_backend_bin="$REPO_ROOT/src/build-debug/bin/db-backend"
		if [[ -x $db_backend_bin ]]; then
			ctdr_require_tracked_sources_not_newer "build" "db-backend" \
				"$db_backend_bin" \
				"The $selector suite replays through that binary, so it would report green over an out-of-date replay engine. Rebuild with: just build-once" \
				"$REPO_ROOT" 'src/db-backend/src/*.rs' 'src/db-backend/build.rs' \
				'src/db-backend/Cargo.toml' 'src/db-backend/Cargo.lock'
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
