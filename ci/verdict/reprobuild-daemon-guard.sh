#!/usr/bin/env bash
#
# reprobuild-daemon-guard.sh -- assert that every macOS reprobuild driver stops
# the repro user daemon both BEFORE it builds and ON THE WAY OUT.
#
#   exit 0  -> every driver carries both guards
#   exit 1  -> at least one does not; each violation is named on stderr
#
# Usage: ci/verdict/reprobuild-daemon-guard.sh [DIR]
#        DIR defaults to ci/reprobuild relative to the repo root.
#
# WHY THIS CHECK EXISTS
# ---------------------
# The repro user daemon is PERSISTENT and its endpoint is deliberately stable
# across nix-develop sessions, so ONE daemon serves every job on a self-hosted
# runner indefinitely. On macOS it is started via launchd, and when that fails
# it falls back to a plain fork+setsid: `launchWithFork` in reprobuild's
# `libs/repro_daemon_core/src/repro_daemon_core/runtime.nim` calls `setsid()`
# and then `execve` with NO `chdir` between them. `chdir`/`setCurrentDir`
# appears nowhere in that library, and no launchd plist this project writes
# sets `WorkingDirectory`. So the daemon inherits -- and keeps -- the current
# working directory of whichever `repro build` first spawned it.
#
# Once that directory is gone (a re-cloned workspace, a deleted temp root, a
# cleaned checkout), every later `repro build` on that runner dies in the first
# statement of the daemon-side build executor, `getCurrentDir()`, as:
#
#     daemon-hosted build failed: No such file or directory
#
# The message names no path and no owner, which is what made it expensive: it
# is reported by the VICTIM job, which is usually not the job that caused it.
#
# a556399c0 identified this and named two victims, but guarded only ONE of them
# (ci/reprobuild/macos-smoke.sh). ci/reprobuild/macos-daemon-build.sh -- the
# script that deliberately runs `repro build --daemon=auto`, and therefore the
# likeliest thing on the runner to LEAVE a daemon behind -- had no stop at all,
# including in its trap. A one-site mitigation for a runner-wide hazard is why
# this is a checker over a directory rather than a line in one script.
#
# The durable fix is upstream in reprobuild (add the missing `chdir("/")` to the
# fork path, and let the daemon tolerate a vanished cwd). This only stops
# codetracer's own jobs being both the cause and the victim.
#
# WHAT IS ASSERTED, AND WHY EACH CLAUSE IS HERE
# ---------------------------------------------
# For every `macos-*.sh` driver in the directory that invokes `repro build`:
#
#   (1) a `repro daemon stop` occurs BEFORE the first `repro build`
#       -- otherwise the run dies on an EARLIER job's dangling cwd;
#   (2) the script arms exactly ONE `trap ... EXIT`, at top level
#       -- `trap ... EXIT` REPLACES rather than composes, so a second one
#          silently discards the first, and a trap armed inside a function is
#          not armed at all on any path that returns before reaching it.
#          Both shapes were live in this directory;
#   (3) the function that trap names contains a `repro daemon stop`
#       -- otherwise WE poison the next job.
#
# Comments are excluded from every match: this file and the scripts it checks
# discuss `repro daemon stop` at length in prose, and a checker satisfied by its
# own explanation would be exactly the "detector probing the wrong artefact"
# defect it was written in response to.
#
# Contract suite: ci/test/reprobuild-daemon-guard-test.sh
set -euo pipefail

target_dir="${1:-}"
if [ -z "$target_dir" ]; then
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	target_dir="$repo_root/ci/reprobuild"
fi

if [ ! -d "$target_dir" ]; then
	echo "reprobuild-daemon-guard: not a directory: $target_dir" >&2
	exit 2
fi

violations=0
checked=0

note() { echo "reprobuild-daemon-guard: $*" >&2; }

violation() {
	violations=$((violations + 1))
	echo "reprobuild-daemon-guard: VIOLATION in $1" >&2
	shift
	for line in "$@"; do echo "    $line" >&2; done
}

# Strip comments and blank lines, preserving line numbers as "N<TAB>text".
# `sed 's/#.*//'` would corrupt `${VAR#prefix}` and `$#`, so only lines whose
# first non-blank character is `#` are dropped -- which is the shape every
# comment in these scripts actually has.
code_lines() {
	grep -n '' "$1" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v '^[0-9]*:[[:space:]]*$'
}

for file in "$target_dir"/macos-*.sh; do
	[ -e "$file" ] || continue
	rel="${file#"$target_dir"/}"

	code="$(code_lines "$file")"

	# Only drivers that actually build are in scope; a helper that never runs
	# `repro build` cannot spawn a daemon.
	first_build="$(printf '%s\n' "$code" | grep -m1 'repro build' | cut -d: -f1 || true)"
	if [ -z "$first_build" ]; then
		continue
	fi
	checked=$((checked + 1))

	# --- (1) a stop before the first build ---------------------------------
	stop_before=""
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		lineno="${entry%%:*}"
		if [ "$lineno" -lt "$first_build" ]; then
			stop_before="$lineno"
			break
		fi
	done < <(printf '%s\n' "$code" | grep 'repro daemon stop' || true)

	if [ -z "$stop_before" ]; then
		violation "$rel" \
			"no 'repro daemon stop' before the first 'repro build' (line $first_build)." \
			"This run will die on a daemon inherited from an EARLIER job that is" \
			"holding a deleted working directory:" \
			"    daemon-hosted build failed: No such file or directory"
	fi

	# --- (2) exactly one EXIT trap, armed at top level ----------------------
	trap_lines="$(printf '%s\n' "$code" | grep 'trap .*EXIT' || true)"
	trap_count="$(printf '%s' "$trap_lines" | grep -c . || true)"

	if [ "$trap_count" -eq 0 ]; then
		violation "$rel" \
			"no 'trap ... EXIT': nothing stops the daemon this script spawns," \
			"so it outlives the job holding this checkout as its cwd."
		continue
	fi

	if [ "$trap_count" -gt 1 ]; then
		violation "$rel" \
			"$trap_count 'trap ... EXIT' statements. 'trap' REPLACES rather than" \
			"composes, so all but the last are silently discarded:" \
			"$(printf '%s' "$trap_lines" | tr '\n' ' ')"
	fi

	# The surviving trap is the last one armed.
	last_trap="$(printf '%s\n' "$trap_lines" | tail -1)"
	trap_text="${last_trap#*:}"

	# Indented => armed inside a function => not armed on any path that
	# returns early. This is exactly how macos-daemon-build.sh lost its
	# handler whenever RUNQUOTA_SOCKET was already set in the environment.
	case "$trap_text" in
	trap*) ;;
	*)
		violation "$rel" \
			"the EXIT trap is armed inside a function, not at top level:" \
			"   ${trap_text# }" \
			"Any path that returns before reaching it leaves the script with NO" \
			"exit handler, and the daemon is then left running."
		;;
	esac

	# --- (3) the cleanup the trap names must stop the daemon ---------------
	# Two spellings are accepted: `trap <fn> EXIT` and an inline `trap '...'`.
	handler="$(printf '%s' "$trap_text" | sed -E "s/^[[:space:]]*trap[[:space:]]+//; s/[[:space:]]+EXIT[[:space:]]*$//")"

	case "$handler" in
	\'*|\"*)
		# Inline handler: the body is the quoted string itself.
		body="$handler"
		;;
	*)
		# Named function: extract from `<name>() {` to the closing `}` at
		# column 0, which is the shape every function in these scripts has.
		body="$(awk -v fn="$handler" '
			$0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { inside = 1; next }
			inside && /^\}/ { inside = 0 }
			inside { print }
		' "$file")"
		;;
	esac

	if ! printf '%s\n' "$body" | grep -v '^[[:space:]]*#' | grep -q 'repro daemon stop'; then
		violation "$rel" \
			"the EXIT handler ('$handler') does not run 'repro daemon stop'." \
			"A daemon spawned by this script outlives it, holding this checkout" \
			"as its cwd, and poisons every later build on this runner."
	fi
done

if [ "$checked" -eq 0 ]; then
	# A checker that examined nothing must not report success: that is the
	# "the recount that proved the sweep worked was itself a no-op" failure.
	note "ERROR: examined 0 driver scripts in $target_dir."
	note "  Either the directory moved or the glob stopped matching. Refusing to"
	note "  report a pass on an empty set."
	exit 2
fi

if [ "$violations" -ne 0 ]; then
	note "$violations violation(s) across $checked driver script(s) in $target_dir."
	exit 1
fi

note "ok: $checked driver script(s) in $target_dir stop the daemon before and after building."
