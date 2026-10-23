#!/usr/bin/env bash
# =============================================================================
# Build cross-repo dependencies that CodeTracer's GUI/E2E tests need.
#
# For each sibling repo that exists in the workspace, this script invokes the
# repo's own dev-shell-built `just` target (via `repro exec`) to produce the
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
#   BUILD_SIBLINGS_FAIL_TAIL_LINES=N — how many trailing lines of each FAILED
#                               repo's log the summary prints, and of the
#                               toolchain lookup's log when that fails
#                               (default 60; 0 prints none).
#
# Conventions:
#   - All builds are run via `repro exec <repo> -- <cmd>` so each repo's flake
#     pins the toolchain. This matches what end users do interactively.
#   - Each entry knows its output artifact path, and reuses an existing artifact
#     ONLY when its BUILD STAMP matches: a record, written after the last
#     successful build, of the inputs it was built from — the sibling's HEAD
#     and tracked modifications, the same for the sibling repos it compiles
#     against (codetracer-trace-format / -nim by default), the build command,
#     and the artifact's own sha256. An absent, unreadable or mismatching stamp
#     means REBUILD, and the script says why. Stamps live under
#     .tools/build-siblings-stamps/ in THIS checkout, never in the siblings.
#     `--force` rebuilds unconditionally; `--check` reports a stale artifact as
#     "would build" and writes nothing. Builds are incremental, so a rebuild of
#     an artifact that turns out to be current is cheap.
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

# repro must be on PATH so each sibling's flake provides its own toolchain.
if ! command -v repro >/dev/null 2>&1; then
	echo "build-siblings.sh: ERROR: repro not found on PATH." >&2
	echo "  Run this script from inside the codetracer dev shell (just/justfile, repro exec, etc.)." >&2
	exit 1
fi

LOG_DIR="${CT_ROOT}/.tools/build-siblings-logs"
mkdir -p "$LOG_DIR"

# How many trailing lines of a failed step's log reach stderr. See the summary
# below for why the tail is printed at all: on a CI runner the log itself is
# gone when the job ends.
fail_tail_lines="${BUILD_SIBLINGS_FAIL_TAIL_LINES:-60}"
case "$fail_tail_lines" in
'' | *[!0-9]*) fail_tail_lines=60 ;;
esac

# print_log_tail <label> <log>: the last $fail_tail_lines lines of <log>,
# prefixed so they stand apart from this script's own messages. Diagnostics
# only; callers decide the exit status.
print_log_tail() {
	local label="$1" log="$2"
	[ "$fail_tail_lines" -gt 0 ] || return 0
	if [ ! -s "$log" ]; then
		echo "  $label: the log $log is empty or missing" >&2
		return 0
	fi
	echo "---- $label: last $fail_tail_lines lines of $log ----" >&2
	tail -n "$fail_tail_lines" "$log" | sed 's/^/  | /' >&2
	echo "---- end of $label log ----" >&2
}

# Resolve the pinned compiler and zstd flags in one environment entry. Keep
# errors per invocation: suppressing them hides activation failures, and four
# independent entries repeat expensive provisioning before any build starts.
EXTRA_NIM_PATH=""
ZSTD_CFLAGS=""
ZSTD_LIBS=""
if [ "$CHECK_ONLY" -eq 0 ]; then
	toolchain_output="$(mktemp "$LOG_DIR/toolchain.XXXXXX")" || exit 1
	toolchain_log="${toolchain_output}.log"
	# NUL-separated values preserve spaces and shell metacharacters as data.
	# shellcheck disable=SC2016
	if ! repro exec "$CT_ROOT" -- bash -e -c '
		nim_path=$(command -v nim)
		nimble_path=$(command -v nimble)
		zstd_cflags=$(pkg-config --cflags libzstd 2>/dev/null || pkg-config --cflags zstd)
		zstd_libs=$(pkg-config --libs libzstd 2>/dev/null || pkg-config --libs zstd)
		printf "%s\0" "$(dirname "$nim_path")" "$(dirname "$nimble_path")" "$zstd_cflags" "$zstd_libs"
	' >"$toolchain_output" 2>"$toolchain_log"; then
		echo "build-siblings.sh: ERROR: required toolchain lookup failed; see $toolchain_log" >&2
		# Naming the log is not enough: the beam arm of desktop-edge run
		# 36407231861 ended on exactly the line above, on an ephemeral runner
		# whose log was gone with it, so why `repro exec` failed was never seen.
		print_log_tail "toolchain lookup" "$toolchain_log"
		rm -f "$toolchain_output"
		exit 1
	fi
	if ! {
		IFS= read -r -d '' NIM_TOOLCHAIN_BIN &&
			IFS= read -r -d '' NIMBLE_TOOLCHAIN_BIN &&
			IFS= read -r -d '' ZSTD_CFLAGS &&
			IFS= read -r -d '' ZSTD_LIBS
	} <"$toolchain_output"; then
		echo "build-siblings.sh: ERROR: incomplete toolchain lookup; see $toolchain_log" >&2
		print_log_tail "toolchain lookup" "$toolchain_log"
		rm -f "$toolchain_output"
		exit 1
	fi
	rm -f "$toolchain_output"
	EXTRA_NIM_PATH="$NIM_TOOLCHAIN_BIN"
	if [ "$NIMBLE_TOOLCHAIN_BIN" != "$NIM_TOOLCHAIN_BIN" ]; then
		EXTRA_NIM_PATH="$EXTRA_NIM_PATH:$NIMBLE_TOOLCHAIN_BIN"
	fi
fi
export EXTRA_NIM_PATH ZSTD_CFLAGS ZSTD_LIBS

# Per-repo results.
declare -A RESULT_STATE  # repo -> PASS|SKIP|FAIL|MISSING
declare -A RESULT_DETAIL # repo -> human-readable detail
declare -A RESULT_LOG    # repo -> captured build log (only when not VERBOSE)

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
# Build stamps: what an artifact was built FROM.
#
# A stamp is a few lines of text, written after a successful build (and its
# smoke check), that identify every input the artifact depends on:
#
#   format build-siblings-stamp/1
#   command <sha256 of the repro repo, the artifact path and the build command>
#   artifact <sha256 of the artifact's bytes>
#   input <repo> head=<full sha> tracked=<clean | sha256 of `git diff HEAD`>
#   input <dependency repo> head=… tracked=…     (one line per dependency)
#   input <dependency repo> absent               (not checked out)
#
# The next run recomputes the same lines and reuses the artifact only when they
# are IDENTICAL. Any other outcome — no stamp, a stamp that cannot be read, one
# in another format, one whose lines differ — is a rebuild, with the first
# difference named. The stamp is one more thing that can be missing, and a
# missing stamp must never mean "assume fresh".
#
# WHY THE STAMP LIVES HERE AND NOT BESIDE THE ARTIFACT. The artifact sits inside
# the sibling's tree, and a file written there is an untracked file in someone
# else's repository: it shows in their `git status`, and the workspace pre-push
# gate counts it. `.tools/` in this checkout is gitignored and already holds the
# build logs, and the stamp is about THIS checkout's use of the sibling anyway.
# A sibling built by hand, or from another workspace, therefore has no stamp
# here and is rebuilt once — the right direction to err in.
#
# The artifact's own hash is in the stamp so that an artifact replaced after
# the build — copied in from another worktree, rebuilt by hand from other
# inputs — is not vouched for by a stamp that was written about different
# bytes.
#
# What the stamp does NOT identify: the toolchain the repro repo's dev shell
# provides. That is pinned by the repro repo's flake lock, not recorded here;
# the smoke check in `build_sibling` is what catches the one toolchain failure
# seen so far (a binary that cannot start).
# ---------------------------------------------------------------------------
STAMP_DIR="${CT_ROOT}/.tools/build-siblings-stamps"
STAMP_FORMAT="format build-siblings-stamp/1"

# The sibling repos an entry compiles against, beyond its own. Every recorder
# reaches the trace format through the workspace checkout — Cargo
# `path = "../codetracer-trace-format/…"` dependencies, nim
# `--path:../codetracer-trace-format-nim/src`, cgo `-L…/codetracer-trace-format-nim`
# — and THAT is the move the recorder's own HEAD cannot see: the meta.dat v3
# recorders that ct refused were sitting on an unchanged HEAD while the trace
# format they had been compiled against had moved on. So both trace-format
# repos are the default for every entry (minus the entry's own repo).
#
# Overrides, each checked against the sibling's manifests. Listing a repo that
# is not really an input costs a needless incremental rebuild; omitting one that
# is costs a stale artifact reported as built, so an override must be EVIDENCE
# that the default is wrong, not a guess that it is unnecessary:
#   noir — its root Cargo.toml reaches codetracer-trace-format by git `rev=`,
#     and the trace-format-nim sources its writer compiles come from
#     `.codetracer-deps/`, which the entry's own `just trace-format-nim`
#     fetches at revisions pinned in noir's scripts/fetch-trace-format-nim.sh.
#     Both pins are in noir's HEAD, so a pin move changes the stamp and the
#     rebuild it triggers re-fetches. (`.codetracer-deps/` itself is
#     gitignored and not stamped: it is an output of the build command.)
#   codetracer-flow-recorder/cadence-trace-helper — go-helper/go.mod requires
#     only onflow/cadence and its transitive modules; no cgo, no trace format.
#   codetracer-wasm-instrumenter — every `path =` dependency in its Cargo.toml
#     files names a crate of its own workspace (crates/*), and it has no git
#     dependencies; it rewrites wasm modules and writes no trace itself.
DEFAULT_SIBLING_DEPS="codetracer-trace-format codetracer-trace-format-nim"
declare -A SIBLING_DEPS=(
	["noir"]=""
	["codetracer-flow-recorder/cadence-trace-helper"]=""
	["codetracer-wasm-instrumenter"]=""
)

# sha256sum on Linux, shasum on macOS. Neither is an error only for stamping:
# with no hasher every stamp check fails, so every entry rebuilds and says why.
SHA256_TOOL=()
if command -v sha256sum >/dev/null 2>&1; then
	SHA256_TOOL=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
	SHA256_TOOL=(shasum -a 256)
fi

# sha256_stdin: the hex digest of stdin.
sha256_stdin() {
	[ "${#SHA256_TOOL[@]}" -gt 0 ] || return 1
	local out
	out="$("${SHA256_TOOL[@]}")" || return 1
	printf '%s' "${out%% *}"
}

# describe_input <repo>: sets INPUT_LINE to the stamp line identifying the
# workspace checkout <repo>, or sets INPUT_ERROR and returns 1 when it cannot
# be identified. Globals rather than stdout so the caller needs no subshell.
describe_input() {
	local name="$1"
	local dir="$WS_ROOT/$1"
	INPUT_LINE=""
	INPUT_ERROR=""
	if [ ! -e "$dir" ]; then
		INPUT_LINE="input $name absent"
		return 0
	fi
	# The checkout must be a repository OF ITS OWN. A directory that merely
	# sits inside some other repository would report that repository's HEAD,
	# which says nothing about these sources.
	local top real
	top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
	real="$(cd "$dir" 2>/dev/null && pwd -P)" || real=""
	if [ -z "$top" ] || [ "$top" != "$real" ]; then
		INPUT_ERROR="$name is not a git checkout, so the sources the artifact is built from cannot be identified"
		return 1
	fi
	local head
	if ! head="$(git -C "$dir" rev-parse --verify -q HEAD 2>/dev/null)"; then
		INPUT_ERROR="$name has no commit at HEAD, so its sources cannot be identified"
		return 1
	fi
	# TRACKED modifications only, and the reason is not style. The artifact
	# itself usually lives INSIDE the sibling (target/release/…), so counting
	# untracked files would count the build output as a modification and every
	# run would rebuild forever — which ci/test/sibling-artifact-freshness-test.sh
	# caught on the first draft of the previous version of this check. Real
	# repos gitignore their build directories, so the bug hid behind that;
	# depending on every sibling's .gitignore for correctness is not a
	# dependency worth having.
	#
	# The CONTENT of the modifications is recorded, not just their presence:
	# a sibling with local edits, built once, is reused until the edits change,
	# instead of being rebuilt on every run because it is "dirty".
	local status tracked="clean"
	if ! status="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)"; then
		INPUT_ERROR="\`git status\` failed in $name"
		return 1
	fi
	if [ -n "$status" ]; then
		if ! tracked="$(git -C "$dir" diff HEAD --binary --no-ext-diff --no-textconv --no-color 2>/dev/null | sha256_stdin)"; then
			INPUT_ERROR="cannot hash the tracked modifications in $name"
			return 1
		fi
	fi
	INPUT_LINE="input $name head=$head tracked=$tracked"
}

# compute_stamp <repo> <artifact> <artifact_path> <cmd> <env_repo> <deps>:
# sets STAMP_TEXT to the stamp the artifact would carry if it were built from
# the inputs as they are NOW, or sets STAMP_ERROR and returns 1.
compute_stamp() {
	local repo="$1" artifact="$2" artifact_path="$3" cmd="$4" env_repo="$5" deps="$6"
	STAMP_TEXT=""
	STAMP_ERROR=""
	if [ "${#SHA256_TOOL[@]}" -eq 0 ]; then
		STAMP_ERROR="neither sha256sum nor shasum is on PATH, so no build stamp can be computed"
		return 1
	fi
	local cmd_hash art_hash
	# NUL-separated so no two different (repo, artifact, command) triples can
	# serialise to the same bytes.
	cmd_hash="$(printf '%s\0%s\0%s' "$env_repo" "$artifact" "$cmd" | sha256_stdin)" || {
		STAMP_ERROR="cannot hash the build command"
		return 1
	}
	art_hash="$(sha256_stdin <"$artifact_path" 2>/dev/null)" || {
		STAMP_ERROR="cannot read $artifact to hash it"
		return 1
	}
	local text="$STAMP_FORMAT"$'\n'"command $cmd_hash"$'\n'"artifact $art_hash"
	local input
	# $deps is a space-separated list of repo names; splitting it is the intent.
	# shellcheck disable=SC2086
	for input in "$repo" $deps; do
		if ! describe_input "$input"; then
			STAMP_ERROR="$INPUT_ERROR"
			return 1
		fi
		text+=$'\n'"$INPUT_LINE"
	done
	STAMP_TEXT="$text"
}

# stamp_line_key <line>: "input <repo>" for an input line, else the first word.
# Stamp lines are matched by this key to name WHICH input differs.
stamp_line_key() {
	local first second _rest
	read -r first second _rest <<<"$1"
	if [ "$first" = "input" ]; then
		printf 'input %s' "$second"
	else
		printf '%s' "$first"
	fi
}

# stamp_stale_reason <stamp> <repo> <compute_stamp args…>: sets STALE_REASON to
# "" when the stamp matches the inputs as they are now, else to the reason it
# does not. Sets STALE_ARTIFACT_REPLACED=1 when the artifact's bytes are not
# the ones stamped, so the caller can delete it before rebuilding.
stamp_stale_reason() {
	local stamp="$1" repo="$2"
	shift
	STALE_REASON=""
	STALE_ARTIFACT_REPLACED=0
	if [ ! -e "$stamp" ]; then
		STALE_REASON="no build stamp at $stamp (built before stamps existed, by hand, or by a build that did not finish)"
		return 0
	fi
	local recorded
	if ! recorded="$(cat -- "$stamp" 2>/dev/null)"; then
		STALE_REASON="the build stamp $stamp cannot be read"
		return 0
	fi
	if [ "${recorded%%$'\n'*}" != "$STAMP_FORMAT" ]; then
		STALE_REASON="the build stamp $stamp is not a '$STAMP_FORMAT' stamp"
		return 0
	fi
	if ! compute_stamp "$@"; then
		STALE_REASON="$STAMP_ERROR"
		return 0
	fi
	[ "$recorded" = "$STAMP_TEXT" ] && return 0

	# Name the first input that differs. Any difference at all is already a
	# rebuild; this only decides what the message says.
	local line key old found
	while IFS= read -r line; do
		key="$(stamp_line_key "$line")"
		found=""
		while IFS= read -r old; do
			if [ "$(stamp_line_key "$old")" = "$key" ]; then
				found="$old"
				break
			fi
		done <<<"$recorded"
		[ "$found" = "$line" ] && continue
		if [ "$key" = "artifact" ]; then STALE_ARTIFACT_REPLACED=1; fi
		[ -n "$STALE_REASON" ] && continue
		if [ -z "$found" ]; then
			STALE_REASON="the build stamp records no '$key'"
			continue
		fi
		case "$key" in
		command)
			STALE_REASON="the build command changed since the stamped build"
			;;
		artifact)
			STALE_REASON="the artifact is not the file the stamp was written for (replaced after the build?)"
			;;
		input\ *)
			local name="${key#input }" who="dependency"
			[ "$name" = "$repo" ] && who="sibling"
			local _i _n old_head new_head
			read -r _i _n old_head _ <<<"$found"
			read -r _i _n new_head _ <<<"$line"
			if [ "$old_head" = "absent" ]; then
				STALE_REASON="$who $name was not checked out at the stamped build"
			elif [ "$new_head" = "absent" ]; then
				STALE_REASON="$who $name is no longer checked out"
			elif [ "$old_head" != "$new_head" ]; then
				old_head="${old_head#head=}"
				new_head="${new_head#head=}"
				STALE_REASON="$who $name moved since the stamped build (built at ${old_head:0:12}, now at ${new_head:0:12})"
			else
				STALE_REASON="$who $name has different tracked modifications than at the stamped build"
			fi
			;;
		*)
			STALE_REASON="the build stamp differs at '$key'"
			;;
		esac
	done <<<"$STAMP_TEXT"
	if [ -z "$STALE_REASON" ]; then
		STALE_REASON="the build stamp records inputs this entry no longer has"
	fi
}

# write_stamp <stamp>: writes $STAMP_TEXT atomically, so an interrupted write
# can never leave a partial stamp that a later comparison reads.
write_stamp() {
	local stamp="$1"
	local tmp="$stamp.tmp.$$"
	mkdir -p "$(dirname -- "$stamp")" &&
		printf '%s\n' "$STAMP_TEXT" >"$tmp" &&
		mv -f -- "$tmp" "$stamp" && return 0
	rm -f -- "$tmp"
	return 1
}

# ---------------------------------------------------------------------------
# Helper: run a build step for one repo.
#   $1 — repo directory name (under WS_ROOT)
#   $2 — artifact path (relative to repo); reused only when its build stamp
#        matches (see "Build stamps" above)
#   $3 — build command (executed under `repro exec <repo>`)
#   $4 — optional logical key (defaults to $1).  Use this when a single repo
#        produces multiple artifacts (e.g. flow recorder = Rust crate + Go
#        helper) so each step gets its own result row.
#   $5 — optional repro repo (defaults to $1).  Use this when a sibling has no
#        usable repro shell but can be built from another pinned dev shell.
#   $6 — optional smoke argument.  When given, the built artifact is run with
#        it in an empty environment and must exit 0 before the row is PASS.
# ---------------------------------------------------------------------------
build_sibling() {
	local repo="$1"
	local artifact="$2"
	local cmd="$3"
	local key="${4:-$1}"
	local env_repo="${5:-$repo}"
	local smoke_arg="${6:-}"

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
		RESULT_DETAIL[$key]="repro repo not checked out at $env_dir"
		return 0
	fi

	local artifact_path="$repo_dir/$artifact"
	# One stamp per logical key, named like its log (no slashes).
	local stamp="$STAMP_DIR/${key//\//__}.stamp"
	local deps=""
	if [ -n "${SIBLING_DEPS[$key]+set}" ]; then
		deps="${SIBLING_DEPS[$key]}"
	else
		local dep
		for dep in $DEFAULT_SIBLING_DEPS; do
			[ "$dep" = "$repo" ] || deps="${deps:+$deps }$dep"
		done
	fi

	local stale_reason=""
	if [ "$FORCE" -eq 0 ] && [ -e "$artifact_path" ]; then
		# EXISTENCE IS NOT FRESHNESS, and treating it as freshness cost a whole
		# investigation.  This arm used to be `[ -e "$artifact_path" ]` alone, so
		# a sibling built against an older dependency reported
		# `SKIP … already built` forever: a codetracer-js-recorder emitting
		# meta.dat v3 while ct accepted only v4/v5 was skipped on every run, and
		# every recording spec died inside importTraceFolder naming THE TRACE
		# rather than the stale recorder.  The only workaround was to know to
		# pass `--force --only <sibling>`, which means knowing the answer first.
		#
		# The rule: an artifact is reused only when its build stamp (see "Build
		# stamps" above) records EXACTLY the inputs as they are now — the
		# sibling's HEAD and tracked modifications, the same for the
		# trace-format repos it compiles against, the build command, and the
		# artifact's own bytes.  Anything else is a rebuild, and the reason is
		# printed.
		#
		# NOT MTIME, which is what the previous version of this check compared
		# (artifact older than HEAD's commit time, or a dirty tree).  It missed
		# the very case above: the recorder's HEAD had not moved, the trace
		# format it compiled against had, and nothing about the recorder's own
		# timestamps changed.  It also skipped a stale artifact after checking
		# out an OLDER commit (the artifact is then newer than HEAD), and a
		# checkout CI materialises or copies has timestamps that say nothing
		# about content — a gate in this repository has refused itself over
		# byte-identical copied sources for exactly that reason.  A stamp of
		# content identities has none of these failure modes.
		#
		# Erring toward a rebuild is deliberate: a commit that touched only
		# documentation still rebuilds, and the build tools' own incremental
		# logic makes that cheap.  A stale artifact reported as built costs a
		# false defect and the session spent chasing it.
		stamp_stale_reason "$stamp" "$repo" "$artifact" "$artifact_path" "$cmd" "$env_repo" "$deps"
		stale_reason="$STALE_REASON"
		# An artifact whose bytes are not the stamped ones was replaced after
		# the build.  Remove it, for the reason given at the smoke check below:
		# a build tool that sees its own products current may not re-copy over
		# a file someone replaced.  Not under --check, which promises to build
		# (and so to change) nothing.
		if [ "$STALE_ARTIFACT_REPLACED" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
			rm -f "$artifact_path"
		fi
		# Nor is a current artifact one that runs (see the smoke check after
		# the build): a fresh-stamped binary that cannot start is rebuilt, not
		# skipped.
		if [ -z "$stale_reason" ] && [ -n "$smoke_arg" ] &&
			! env -i PATH=/usr/bin:/bin "$artifact_path" "$smoke_arg" >/dev/null 2>&1; then
			stale_reason="\`$artifact $smoke_arg\` does not run"
			# Remove it, or the rebuild may leave it in place: cargo, for one,
			# sees its own build products current and does not re-copy over a
			# file someone replaced, but does restore one that is missing.
			if [ "$CHECK_ONLY" -eq 0 ]; then rm -f "$artifact_path"; fi
		fi
		if [ -z "$stale_reason" ]; then
			RESULT_STATE[$key]="SKIP"
			RESULT_DETAIL[$key]="already built ($artifact; build stamp matches)"
			return 0
		fi
		# Say WHY it is rebuilding.  A rebuild with no stated reason is
		# indistinguishable from the script ignoring its own short-circuit.
		if [ "$CHECK_ONLY" -eq 1 ]; then
			echo "  $key: would rebuild — $stale_reason" >&2
		else
			echo "  $key: rebuilding — $stale_reason" >&2
		fi
	fi

	if [ "$CHECK_ONLY" -eq 1 ]; then
		RESULT_STATE[$key]="MISSING"
		RESULT_DETAIL[$key]="would build → $artifact${stale_reason:+ ($stale_reason)}"
		return 0
	fi

	# Drop the old stamp BEFORE building, so a build that fails or is killed
	# half-way cannot leave behind a stamp that still matches: the previous
	# stamp describes the previous inputs, and an input change that is later
	# undone would make it match again over whatever the failed build left in
	# place.  No stamp means the next run rebuilds — the safe answer.
	rm -f "$stamp"

	# Sanitize key for log filename (no slashes).
	local log_name="${key//\//__}"
	local log="$LOG_DIR/${log_name}.log"
	echo "[build-siblings] $key: building → $artifact (log: $log)" >&2

	# Prepend codetracer's nim/nimble paths so transitive Nim builds work in
	# sibling dev shells that don't bundle Nim (every blockchain recorder).
	local wrapped_cmd="$cmd"
	if [ -n "${EXTRA_NIM_PATH:-}" ]; then
		# shellcheck disable=SC2016
		wrapped_cmd='export PATH="$EXTRA_NIM_PATH:$PATH"; '"$cmd"
	fi

	local rc=0
	# Where this build's output can be read.  In verbose mode no log is
	# written, so naming $log would point at whatever an EARLIER run left
	# there -- and ci/lib/sibling-build-failure.sh tails the file the FAIL row
	# names.
	local see="see $log"
	if [ "${BUILD_SIBLINGS_VERBOSE:-0}" = "1" ]; then
		see="output streamed above"
		# Expand positional arguments in the activated child shell.
		# shellcheck disable=SC2016
		repro exec "$env_dir" -- bash -c 'cd "$1" && eval "$2"' build-sibling "$repo_dir" "$wrapped_cmd" || rc=$?
	else
		# Expand positional arguments in the activated child shell.
		# shellcheck disable=SC2016
		repro exec "$env_dir" -- bash -c 'cd "$1" && eval "$2"' build-sibling "$repo_dir" "$wrapped_cmd" >"$log" 2>&1 || rc=$?
		RESULT_LOG[$key]="$log"
	fi

	if [ "$rc" -ne 0 ]; then
		RESULT_STATE[$key]="FAIL"
		RESULT_DETAIL[$key]="build exited $rc — $see"
		return 0
	fi

	if [ ! -e "$artifact_path" ]; then
		RESULT_STATE[$key]="FAIL"
		RESULT_DETAIL[$key]="build succeeded but $artifact still missing — $see"
		return 0
	fi

	# An artifact that exists is not one that runs. Where the entry names a
	# smoke argument, run the artifact with it in an EMPTY environment (no dev
	# shell, no LD_LIBRARY_PATH): what it loads must come from its own
	# interpreter and runpath, as it will when ct spawns it. A ct-native-replay
	# linked against two nixpkgs once reported PASS here and died before main.
	if [ -n "$smoke_arg" ]; then
		local smoke_out
		if ! smoke_out="$(env -i PATH=/usr/bin:/bin "$artifact_path" "$smoke_arg" 2>&1)"; then
			RESULT_STATE[$key]="FAIL"
			RESULT_DETAIL[$key]="built $artifact, but \`$artifact $smoke_arg\` does not run: $(printf '%s' "$smoke_out" | head -1)"
			return 0
		fi
	fi

	# Stamp it — LAST, after the build and the smoke check have both passed,
	# for two reasons.  Only an artifact known to be good may be vouched for.
	# And some builds rewrite their own tracked inputs (`npm install` updates
	# package-lock.json), so the inputs are read as the build LEFT them: that
	# is the state the next run compares against, and reading them before the
	# build would make every following run see a "modification" and rebuild.
	RESULT_STATE[$key]="PASS"
	if ! compute_stamp "$repo" "$artifact" "$artifact_path" "$cmd" "$env_repo" "$deps"; then
		# Not a failure of the build.  The artifact is good, but nothing can
		# vouch for it later, so the next run rebuilds it — and says so now.
		RESULT_DETAIL[$key]="built $artifact (not stamped, will rebuild next run: $STAMP_ERROR)"
		return 0
	fi
	if ! write_stamp "$stamp"; then
		RESULT_DETAIL[$key]="built $artifact (could not write the build stamp $stamp; will rebuild next run)"
		return 0
	fi
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
#
# One spelling, whatever the toolchain lookup found.  This used to drop the
# zstd exports when either value was empty; the command string is part of the
# build stamp, and `--check` skips the lookup (so both are empty there), which
# made `--check` report this entry stale on every run.  Appending an empty
# value to NIX_CFLAGS_COMPILE / NIX_LDFLAGS adds a space and nothing else.
# shellcheck disable=SC2016
trace_format_nim_cmd='export NIX_CFLAGS_COMPILE="${NIX_CFLAGS_COMPILE:-} $ZSTD_CFLAGS"; export NIX_LDFLAGS="${NIX_LDFLAGS:-} $ZSTD_LIBS"; nimble buildSharedLib'
build_sibling \
	codetracer-trace-format-nim \
	libcodetracer_trace_writer.so \
	"$trace_format_nim_cmd"

# `ct-print` — the canonical CTFS decoder, and the trace-validation oracle for
# ci/test/launcher-recorder-e2e.sh (Launcher-Recorder-Compatibility-Tests.md
# §5.4).  Same repo as the shared lib above but a separate artifact and a
# separate recipe, so it gets its own logical key (the cadence-trace-helper
# precedent below).  The repo builds it at its own root on purpose:
# "downstream recorder tests resolve it at the fixed sibling path
# ../codetracer-trace-format-nim/ct-print" (that repo's Justfile).
build_sibling \
	codetracer-trace-format-nim \
	ct-print \
	"nimble buildCtPrint" \
	codetracer-trace-format-nim/ct-print

# Native backend (ct-native-replay). Built by codetracer's own
# `just ensure-ct-native-replay`, the one recipe that knows how: it compiles
# inside the backend's Nix dev shell, so the binary's glibc, LLDB and
# libstdc++ come from one pinned nixpkgs, and that shell's hook exports the
# `CT_NATIVE_REPLAY_RPATH` its build.rs bakes in. The recipe header has the
# per-platform detail and its fallbacks.
#
# This used to be a second, hand-written build: `cargo build` in codetracer's
# dev shell, with LLVM/LLDB fetched by `nix build nixpkgs#lldb` (and
# `#lldb.dev`, `#llvm.dev`). A bare `nixpkgs#` resolves the machine's FLAKE
# REGISTRY, not any lock, so it linked whatever LLDB that machine had against
# codetracer's pinned glibc. Measured 2026-10-21 on a Linux host: LLDB
# 21.1.8 from a glibc-2.42 nixpkgs, interpreter glibc 2.40, and the reported
# `PASS … built target/debug/ct-native-replay` could not start:
#   ct-native-replay: …/glibc-2.40-224/lib/libc.so.6: version `GLIBC_2.42'
#   not found (required by …/lldb-21.1.8/lib/liblldb.so.21.1)
# so every GUI spec that records a native trace failed in `ct record`.
# ci/test/build-siblings-native-backend-runs-test.sh holds the binary to
# starting with an empty environment.
# Not under --check: initializing submodules clones into the sibling, and
# --check promises to build (and so to change) nothing.
if ! should_skip codetracer-native-backend && [ "$CHECK_ONLY" -eq 0 ]; then
	ensure_submodules codetracer-native-backend libs/rr libs/delve
fi
native_backend_cmd="CT_CODETRACER_NATIVE_BACKEND_SIBLING=\"\$PWD\" just --justfile '$CT_ROOT/justfile' --working-directory '$CT_ROOT' ensure-ct-native-replay"
build_sibling \
	codetracer-native-backend \
	target/debug/ct-native-replay \
	"$native_backend_cmd" \
	codetracer-native-backend \
	codetracer \
	--help

# MCR / native recorder (ct_cli aka ct-mcr).
build_sibling \
	codetracer-native-recorder \
	ct_cli/ct_cli \
	"just build-ct-mcr"

# The native edge's E2E sample: a compiled, EXTENSION-LESS binary.
#
# A separate key rather than a step inside `just build-ct-mcr`, because the two
# are wanted independently: every consumer of the recorder wants ct_cli, and
# only `ci/test/launcher-recorder-e2e.sh` wants the sample.  It is named by
# that edge's contract fixture
# (codetracer-native-recorder/cross-repo/launcher-compat.yml, `build.also`),
# which is what makes the driver build it before any scenario runs.
#
# It cannot be checked in: the routing key the scenario exercises is the
# ABSENCE of an extension, so the sample has to be a real executable, and a
# committed binary would be unreviewable and host-specific.
build_sibling \
	codetracer-native-recorder \
	cross-repo/samples/launcher_compat_sample \
	"just build-launcher-compat-sample" \
	codetracer-native-recorder/launcher-compat-sample

# JavaScript recorder (Node CLI + napi-rs native addon).
#
# The canonical build is the recorder repo's own `just build` recipe, which
# runs `just build-native` (`npx napi build --release` for the
# crates/recorder_native addon) followed by `npm run build` (TypeScript ->
# dist for every npm workspace).  Both steps need the workspace's
# node_modules, so prime them with `npm install` first; npm install is cheap
# and idempotent on re-runs.  The artifact `scripts/detect-siblings.sh` and
# `ci/test/ct-providers.sh` look for is the compiled CLI entrypoint at
# packages/cli/dist/index.js (the JS recorder surfaced on PATH as
# codetracer-js-recorder).  Without this entry `build-siblings.sh --only
# codetracer-js-recorder` matched nothing, so CI never built the JS recorder
# and all JS-gated ViewModel / node:test recording assertions silently
# skipped.
#
# The TRAILING `npm install` is not redundant, and dropping it breaks recorder
# DISCOVERY on a clean checkout.  npm links a workspace package's `bin` entries
# into node_modules/.bin only when the target file exists at install time; here
# the target is packages/cli/dist/index.js, which `just build` produces AFTER
# `just install` has already run.  So on a fresh clone the first install links
# nothing, `node_modules/.bin/codetracer-js-recorder` never appears, and
# scripts/detect-siblings.sh -- which looks for exactly that shim -- reports
# "codetracer-js-recorder CLI not on PATH" even though the build succeeded.
# Re-running install once the dist exists creates the link (verified: the shim
# appears only after the second install).  `npm install` is idempotent, so the
# cost of the extra call is a no-op resolve.
build_sibling \
	codetracer-js-recorder \
	packages/cli/dist/index.js \
	"npm install && just build && npm install"

# Python recorder (PyO3 extension + `codetracer-python-recorder` console
# script).  Unlike the other recorders this one is a Python package rather than
# a standalone binary: the desktop core resolves it with
# `findTool("codetracer-python-recorder")` (src/common/paths.nim), i.e. a plain
# PATH search for the console script.  `just dev` is the recorder repo's own
# canonical dev build (`uv run ... maturin develop`), and it drops that console
# script into the repo's `.venv/bin`, which is the artifact
# ci/test/launcher-recorder-e2e.sh puts on PATH via the recorder's
# cross-repo/launcher-compat.yml `discovery.path-prepend`.
#
# NOTE: `.venv/bin` is deliberately NOT added to PATH by
# scripts/detect-siblings.sh.  It carries a `python` of its own, and prepending
# it globally would shadow the dev shell's interpreter for every other tool in
# the workspace; only the launcher/recorder E2E needs it, and only for the
# duration of that run.
build_sibling \
	codetracer-python-recorder \
	.venv/bin/codetracer-python-recorder \
	"just dev"

# Ruby native extension.
#
# The artifact below is the COMPILED EXTENSION, not the CLI wrapper.  The
# wrapper (gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder, which is
# what scripts/detect-siblings.sh puts on PATH) is CHECKED IN, so naming it here
# made this entry's "already built" short-circuit fire on a clean checkout and
# skip the build entirely — the recorder would then be on PATH but die at run
# time in `load_extension!` (`require`: cannot load such file …
# codetracer_ruby_recorder.so).  The `.so` is what `just build-extension`
# actually produces, and it is absent from a fresh clone.
#
# `just build-extension` normalises the cdylib name to
# `codetracer_ruby_recorder.<RbConfig DLEXT>` -- `.so` on Linux, `.bundle` on
# macOS.  This entry used to name the Linux spelling unconditionally, with a
# comment saying the gate was Linux-only and portability would be pretending.
# That stopped being true when the macOS `test-non-gui` and `test-ui-tests` jobs
# grew a ruby-recorder build step: on macOS the build SUCCEEDS and then
# `build_sibling`'s post-build check reports
#
#     build succeeded but …/codetracer_ruby_recorder.so still missing
#
# because `.so` is not the name macOS produced.  A hard-coded extension is the
# same defect as a detector probing the wrong artefact -- it just fails loudly
# instead of quietly.  So resolve DLEXT the way the loader does.
_ruby_dlext=""
if command -v ruby >/dev/null 2>&1; then
	_ruby_dlext="$(ruby -e 'print RbConfig::CONFIG["DLEXT"]' 2>/dev/null || true)"
fi
if [ -z "$_ruby_dlext" ]; then
	case "$(uname -s)" in
	Darwin) _ruby_dlext="bundle" ;;
	*) _ruby_dlext="so" ;;
	esac
fi
build_sibling \
	codetracer-ruby-recorder \
	"gems/codetracer-ruby-recorder/ext/native_tracer/target/release/codetracer_ruby_recorder.$_ruby_dlext" \
	"just build-extension"

# BEAM recorder (Erlang + Elixir) — one Rust CLI (`codetracer-beam-recorder`)
# that wraps the command which starts the BEAM program.  Added for the LRC-4
# beam edge of ci/test/launcher-recorder-e2e.sh: this script had no entry at
# all, so `build-siblings.sh --only codetracer-beam-recorder` matched nothing
# and the driver's "the recorder build produced no <artifact>" hard failure was
# the only thing that could happen.
#
# `just build` in that repo re-enters `nix develop` when cargo is absent, which
# would nest a second dev shell inside the `repro exec` one; `build-native` is
# the same recipe without that fallback (`cargo build --locked` plus the
# rebar3 provider compile), and `repro exec` has already supplied the
# toolchain.  The binary lands in target/debug — the profile
# scripts/detect-siblings.sh probes first.
build_sibling \
	codetracer-beam-recorder \
	target/debug/codetracer-beam-recorder \
	"just build-native"

# wazero (Go binary; lives at the repo root, not target/release).
build_sibling \
	codetracer-wasm-recorder \
	wazero \
	"export CGO_LDFLAGS=\"-L$WS_ROOT/codetracer-trace-format-nim\"; go build -o wazero ./cmd/wazero" \
	codetracer-wasm-recorder \
	codetracer

# WebAssembly instrumenter (`ct-instrument`).  scripts/materialize-recording.sh
# instruments the `cross-process-three-trace` demo's wasm module with it and
# refuses to record without it, so every suite that replays that recording —
# `just test-frontend-units` (cross_process_origin_vm_test), the db-backend
# three-trace DAP tests, `just test-cross-process` — needs this binary.  This
# script had no entry for it, so `--only codetracer-wasm-instrumenter` matched
# nothing and nothing outside the CI workflow could produce it
# (codetracer-pm issues/2026-10-21-test-frontend-units-does-not-provision-the-
# three-trace-recording-its-cross-process-suite-needs.md).
#
# CARGO_TARGET_DIR is pinned to the sibling's own target/ for the reason the
# test-non-gui "Build ct-instrument" step gives: a runner- or user-wide
# CARGO_TARGET_DIR would put the binary somewhere this entry's artifact path
# does not name, and the build would be reported as "succeeded but missing".
# The materialiser searches the sibling's target/ first.  `--locked` because
# the instrumenter commits its Cargo.lock (its own `just build-rust` uses it).
# `$PWD` is expanded by the build wrapper inside the sibling, not here.
# shellcheck disable=SC2016
build_sibling \
	codetracer-wasm-instrumenter \
	target/release/ct-instrument \
	'CARGO_TARGET_DIR="$PWD/target" cargo build --release --locked -p ct-instrument-cli' \
	codetracer-wasm-instrumenter \
	codetracer-wasm-instrumenter \
	--help

# noir / nargo.
#
# `just trace-format-nim` first, because cargo alone cannot build nargo from a
# checkout nobody has prepared. nargo links `codetracer_trace_writer_nim`, whose
# build script compiles the Nim CTFS writer from `codetracer-trace-format-nim`
# sources; noir's .cargo/config.toml points it at `.codetracer-deps/`, and
# noir's justfile fills that directory with this recipe
# (scripts/fetch-trace-format-nim.sh, at the revisions it pins) — "needed once
# before building `nargo`, and again after the pins move". The entry used to
# run the bare `cargo build`, so a fresh or CI clone failed in that build
# script with "Nim FFI entry point not found at …/.codetracer-deps/…"
# (codetracer-pm issues/2026-10-22-build-siblings-builds-noir-without-fetching-
# the-trace-format-nim-sources-its-build-reads.md). The recipe leaves a
# checkout already at its pin alone (no fetch, no network), so running it on
# every build is cheap, and it is what moves the checkouts when a noir bump
# moves the pins. It runs in codetracer's shell, like the cargo build: that
# shell carries the `just`, `git` and `nim` the recipe and build script need.
# ci/test/build-siblings-noir-fresh-checkout-test.sh holds the entry to
# building from a checkout with no `.codetracer-deps/`.
build_sibling \
	noir \
	target/release/nargo \
	"just trace-format-nim && cargo build --release --package nargo_cli --bin nargo" \
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

# The tail of every FAILED repo's log, in the summary itself.
#
# The per-repo log lives under .tools/build-siblings-logs on whatever machine
# ran this. On a CI runner that path is gone when the job ends and no step
# uploads it, so a summary that only NAMES the log ("build exited 101 — see
# …") hides the one line that says why: the launcher<->recorder ruby arm of
# run 36013311965 failed with exactly that and nothing else in the Actions
# log. A compiler or cargo failure almost always ends with its cause, so the
# last lines are the useful ones. This is diagnostics only; the exit status
# below is unchanged. `fail_tail_lines` and `print_log_tail` are defined at
# the top, where the toolchain lookup uses them too.
if [ "$fail_count" -gt 0 ] && [ "$fail_tail_lines" -gt 0 ]; then
	for repo in $(printf '%s\n' "${!RESULT_STATE[@]}" | sort); do
		[ "${RESULT_STATE[$repo]}" = "FAIL" ] || continue
		log="${RESULT_LOG[$repo]:-}"
		echo "" >&2
		if [ -z "$log" ]; then
			# BUILD_SIBLINGS_VERBOSE=1: the output was streamed above and no log
			# was written, so there is nothing (and nothing stale) to tail.
			echo "  $repo: build output was streamed above (BUILD_SIBLINGS_VERBOSE=1)" >&2
			continue
		fi
		print_log_tail "$repo" "$log"
	done
fi

if [ "$fail_count" -gt 0 ]; then
	exit 1
fi
exit 0
