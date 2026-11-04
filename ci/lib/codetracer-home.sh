#!/usr/bin/env bash
#
# codetracer-home.sh — give a test lane (and everything it starts) a scratch
# `CODETRACER_HOME`.
#
# `CODETRACER_HOME` is the one variable every CodeTracer path resolver honours
# for EVERY per-user location — the trace index, recordings, config, state,
# caches and the tmp/socket directory — in Nim (`src/common/ct_home.nim`) and
# Rust (`libs/ct-home`), on every OS. Children inherit it, so a `cargo test`
# whose tests spawn `replay-server`, `ct-native-replay` or `ct` keeps all of
# them out of the developer's own profile. See codetracer-specs
# `spec/Architecture/Per-User-State-Locations.md`.
#
# Usage (source it, then call):
#   source ci/lib/codetracer-home.sh
#   ct_export_scratch_codetracer_home <label>
#   trap '_ct_rc=$?; rm -rf ${ct_scratch_home_created:+"$ct_scratch_home_created"}; ct_user_state_guard_exit <label> "$_ct_rc"' EXIT
#
# A caller that already exported a SCRATCH `CODETRACER_HOME` (inside the temp
# directory, or marked with a `.codetracer-test-home` file — the rule every
# test program applies) keeps it, so a lane started by another lane shares its root. The
# directory it CREATES is named in `ct_scratch_home_created` (empty when an
# inherited one was kept), so a lane removes only what it made.
#
# The export also STARTS the user-state guard below, and the trap's last
# command checks it: a lane whose tests all passed but which wrote the
# developer's real state (a resolver that ignores `CODETRACER_HOME`) fails.
#
# Deliberately NOT a `.cargo/config.toml` `[env]` entry: that would apply to a
# developer's own `cargo run` of `replay-server` too, and quietly move their
# real state into a temporary directory.

# shellcheck disable=SC2034 # ct_scratch_home_created is read by the caller's EXIT trap
ct_export_scratch_codetracer_home() {
	local label="${1:-lane}"
	# Before anything runs under the new home, so the "before" snapshot is the
	# developer's state as the lane found it.
	ct_user_state_guard_start
	local tmp="${TMPDIR:-/tmp}"
	tmp="${tmp%/}"
	ct_scratch_home_created=""
	case "${CODETRACER_HOME:-}" in
	"") ;;
	"${tmp}"/*)
		export CODETRACER_HOME
		return 0
		;;
	*)
		if [ -f "${CODETRACER_HOME}/.codetracer-test-home" ]; then
			export CODETRACER_HOME
			return 0
		fi
		;;
	esac
	ct_scratch_home_created="$(mktemp -d "${tmp}/ct-home-${label}.XXXXXX")" || return 1
	# The line that matters: ct_home_isolation_test pins it verbatim.
	export CODETRACER_HOME="${ct_scratch_home_created}"
}

# THE USER-STATE GUARD: read the developer's own CodeTracer state before a
# test lane and after it, and fail the lane when anything there changed.
#
# `CODETRACER_HOME` (the function above, src/common/ct_home.nim, libs/ct-home)
# keeps every resolver that honours it out of the developer's
# profile. This is the check that catches a resolver that does NOT honour it —
# in this repository, in a sibling's binary a test spawns, or in a CI script —
# by looking at the real directories instead of trusting the variable:
#
#   ~/.local/state/codetracer   every file, by checksum
#   ~/.config/codetracer        every file, by checksum
#   ~/.local/share/codetracer   the trace index (`trace_index.db*`) by
#                               checksum; every other entry (a recording can be
#                               gigabytes) by NAME
#   ~/.cache/codetracer         every file, by NAME: a cache entry that
#                               appears or disappears is the damage that
#                               matters, and its bytes are re-fetchable
#
# Only files are compared, never listings or directory times, which move
# without any file changing. A file that APPEARED, whose bytes CHANGED, or that
# DISAPPEARED fails the check: a deletion is damage too.
#
# WHY ~/.cache/codetracer IS HERE. On 2026-11-02 two lanes wrote it while
# every lane already ran under a scratch `CODETRACER_HOME`: `ct-mcr record`
# (codetracer-native-recorder) put eleven library-family lists into
# `~/.cache/codetracer/sync-families`, from the `test-rust` lane, and
# `ci/test/cua-keymap-extractor.sh` put the VS Code 1.105.0 sources into
# `~/.cache/codetracer/vscode-484fdf69`, from `ci/lint/nim.sh`. This guard
# covered neither the directory nor those two entry points, so both went
# unreported until a developer found the files.
#
# The directories are the DEFAULT, home-relative locations, read from `HOME` as
# it is when the guard starts. That is where an unisolated resolver writes on
# a developer's machine and on a CI runner alike; a lane that has already
# redirected `HOME` guards that home instead, which is the same check.
#
# Someone else changing CodeTracer state on this machine while a lane runs
# (using CodeTracer, clearing stale state by hand) trips it as well. The
# message says so; the remedy is to rerun on a quiet host.
#
# Usage (source this file, then):
#   ct_user_state_guard_start                  # take the "before" snapshot
#   ... run the lane ...
#   ct_user_state_guard_check <label>          # 0 unchanged, 1 changed (reported)
#
# or, in a script that ends through an EXIT trap, as the trap's LAST command
# (it keeps the script's own exit status when the guard passes):
#   trap '_ct_rc=$?; <cleanup>; ct_user_state_guard_exit <label> "$_ct_rc"' EXIT
#
# `ct_export_scratch_codetracer_home` starts the guard, so every entry point
# that exports a scratch home only has to check it.
# ci/test/lane-user-state-guard-test.sh holds both halves to account, and fails
# if an entry point exports a scratch home without checking the guard.

ct_user_state_guard_dirs() {
	# The four guarded directories, one per line, in a fixed order.
	local home="${_ct_usg_home:-${HOME:-/nonexistent}}"
	printf '%s\n' "${home}/.local/state/codetracer" "${home}/.config/codetracer" \
		"${home}/.local/share/codetracer" "${home}/.cache/codetracer"
}

ct_user_state_guard_dirs_text() {
	# The directories as one comma-separated phrase, for messages.
	local out="" d
	while IFS= read -r d; do
		out="${out:+${out}, }${d}"
	done < <(ct_user_state_guard_dirs)
	printf '%s' "${out}"
}

ct_user_state_snapshot() {
	# One line per file: `<cksum> <size> <path>`, or `- - <path>` for a file
	# compared by name only; sorted by path within each directory. `cksum`
	# rather than a GNU-only tool: this also runs on macOS.
	local state config data cache
	{
		read -r state
		read -r config
		read -r data
		read -r cache
	} < <(ct_user_state_guard_dirs)
	local _dir
	for _dir in "${state}" "${config}"; do
		if [ -d "${_dir}" ]; then
			find "${_dir}" -type f -print0 2>/dev/null | sort -z |
				xargs -0 -r cksum 2>/dev/null
		fi
	done
	if [ -d "${data}" ]; then
		find "${data}" -maxdepth 1 -type f -name 'trace_index.db*' \
			-print0 2>/dev/null | sort -z | xargs -0 -r cksum 2>/dev/null
		find "${data}" -mindepth 1 -maxdepth 1 ! -name 'trace_index.db*' \
			-print 2>/dev/null | sort | sed 's/^/- - /'
	fi
	if [ -d "${cache}" ]; then
		find "${cache}" -type f -print 2>/dev/null | sort | sed 's/^/- - /'
	fi
}

ct_user_state_guard_start() {
	# Pin the home the guard reads, so a lane that later points HOME at a
	# scratch directory still has its real one compared.
	_ct_usg_home="${HOME:-/nonexistent}"
	_ct_usg_before="$(ct_user_state_snapshot)"
	_ct_usg_started=1
}

ct_user_state_guard_check() {
	# Compare against the snapshot `ct_user_state_guard_start` took. Prints
	# what changed, naming `<label>`, and returns 1; returns 0 when nothing
	# did. Refuses (returns 2) when the guard was never started: a check with
	# nothing to compare against would pass by construction.
	local label="${1:-lane}"
	if [ -z "${_ct_usg_started:-}" ]; then
		echo "ERROR: ${label}: the user-state guard was checked but never started" \
			"(call ct_user_state_guard_start before the lane runs)" >&2
		return 2
	fi
	local after written removed where
	after="$(ct_user_state_snapshot)"
	[ "${after}" = "${_ct_usg_before}" ] && return 0
	where="$(ct_user_state_guard_dirs_text)"
	# Lines only AFTER has: files created, or rewritten (new checksum).
	written="$(comm -13 <(printf '%s\n' "${_ct_usg_before}" | sort) \
		<(printf '%s\n' "${after}" | sort) | sed '/^$/d')"
	# Paths BEFORE had and AFTER does not: files removed.
	removed="$(comm -23 \
		<(printf '%s\n' "${_ct_usg_before}" | awk 'NF {print $3}' | sort) \
		<(printf '%s\n' "${after}" | awk 'NF {print $3}' | sort) |
		sed '/^$/d')"
	if [ -n "${removed}" ]; then
		echo "ERROR: ${label}: these files LEFT the user's own CodeTracer" \
			"state (${where}) during the run — a test (or a binary it spawned)" \
			"deleted real per-user state. (If CodeTracer state was cleared on" \
			"this machine during the run, that is the other possible cause.)" >&2
		printf '%s\n' "${removed}" | sed 's/^/    /' >&2
	fi
	if [ -n "${written}" ]; then
		echo "ERROR: ${label} WROTE the user's own CodeTracer state" \
			"(${where}) — a test (or a binary it spawned) created or rewrote" \
			"real per-user state. (If CodeTracer was used on this machine" \
			"during the run, that is the other possible cause.)" >&2
		printf '%s\n' "${written}" | sed 's/^/    /' >&2
	fi
	[ -z "${written}" ] && [ -z "${removed}" ]
}

ct_user_state_guard_exit() {
	# For the last command of an EXIT trap: exit with the script's own status
	# `<status>` when the guard passes, with 1 when it fails (a lane that
	# passed every test and wrote the user's state is a failed lane).
	local label="${1:-lane}" status="${2:-0}"
	if ! ct_user_state_guard_check "${label}"; then
		exit 1
	fi
	exit "${status}"
}
