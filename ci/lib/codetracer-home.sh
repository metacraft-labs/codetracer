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
	#
	# A directory the per-run sandbox below covers is left out: no test can
	# write it, and reading it would only report the OTHER processes on the
	# host that wrote it meanwhile.
	local state config data cache
	{
		read -r state
		read -r config
		read -r data
		read -r cache
	} < <(ct_user_state_guard_dirs)
	ct_user_state_sandbox_covers "${state}" && state=""
	ct_user_state_sandbox_covers "${config}" && config=""
	ct_user_state_sandbox_covers "${data}" && data=""
	ct_user_state_sandbox_covers "${cache}" && cache=""
	local _dir
	for _dir in "${state}" "${config}"; do
		if [ -n "${_dir}" ] && [ -d "${_dir}" ]; then
			find "${_dir}" -type f -print0 2>/dev/null | sort -z |
				xargs -0 -r cksum 2>/dev/null
		fi
	done
	if [ -n "${data}" ] && [ -d "${data}" ]; then
		find "${data}" -maxdepth 1 -type f -name 'trace_index.db*' \
			-print0 2>/dev/null | sort -z | xargs -0 -r cksum 2>/dev/null
		find "${data}" -mindepth 1 -maxdepth 1 ! -name 'trace_index.db*' \
			-print 2>/dev/null | sort | sed 's/^/- - /'
	fi
	if [ -n "${cache}" ] && [ -d "${cache}" ]; then
		find "${cache}" -type f -print 2>/dev/null | sort | sed 's/^/- - /'
	fi
}

# THE PER-RUN SANDBOX (Linux): run a test where it can READ the user's state
# but every write lands in a private copy-on-write layer.
#
# The snapshot comparison above reads directories every process on the host
# shares. A test file is blamed for whatever changed there while it ran, so a
# `ct-mcr record` started by another checkout's tests (or by hand) on the same
# host failed whichever file happened to be running: on 2026-11-04 two GPUI
# suites that never start a recorder were reported for library-family lists
# another process wrote to `~/.cache/codetracer/sync-families`. CI runs lanes
# side by side on one runner too, so the comparison could not say which lane
# wrote.
#
# So each run gets its own mount namespace with an overlay on every guarded
# directory: the real directory is the read-only lower layer, a scratch
# directory is the upper one. The test sees the user's real files; what it
# creates, rewrites or deletes lands in ITS upper layer and never reaches the
# real directory; and the finding is read from that layer, which no other
# process can touch. The run keeps the user's uid (a second user namespace
# maps it back), so the nix daemon, rr and file ownership behave as outside.
#
# A guarded directory that does not exist yet is covered through its parent
# (an overlay needs an existing mount point), and only its `codetracer`
# entry is read back. One with no parent either, and every directory on a
# host without unprivileged user namespaces or overlayfs (macOS; a kernel or
# AppArmor policy that refuses them), stays with the snapshot comparison.
# `ct_user_state_sandbox_enable` proves the mechanism on a scratch tree before
# it is trusted, so a host where it silently does nothing is never taken for
# one where it works.

_ct_uss_enabled=""
_ct_uss_guarded=()
_ct_uss_mounts=()
_ct_uss_subs=()
_ct_uss_layer=()

ct_user_state_sandbox_covers() {
	# 0 when the sandbox covers guarded directory `$1`: this shell's own, or
	# the stage sandbox this shell runs inside (`ct_user_state_stage_sandbox`,
	# which names its directories in CT_USS_STAGE_COVERED, one per line).
	local d
	if [ -n "${CT_USS_STAGE_COVERED:-}" ]; then
		while IFS= read -r d; do
			[ "${d}" = "$1" ] && return 0
		done <<<"${CT_USS_STAGE_COVERED}"
	fi
	[ -n "${_ct_uss_enabled}" ] || return 1
	for d in "${_ct_uss_guarded[@]}"; do
		[ "${d}" = "$1" ] && return 0
	done
	return 1
}

# The namespace entry, as one `bash -c` program: mount each overlay given as
# `<lower> <upper> <work>` triples up to `--`, then re-enter as the caller's
# own uid and gid and exec the command.
# shellcheck disable=SC2016 # expanded by the inner shell, not here
_ct_uss_entry='set -e
while [ "$1" != -- ]; do
	mount -t overlay overlay -o "lowerdir=$1,upperdir=$2,workdir=$3" "$1"
	shift 3
done
shift
exec unshare --user --map-user="${CT_USS_UID}" --map-group="${CT_USS_GID}" -- "$@"'

ct_user_state_sandbox_enable() {
	# Decide, once per lane, whether runs are sandboxed. Opt out with
	# CT_USER_STATE_SANDBOX=0. Returns 0 when the sandbox is on.
	_ct_uss_enabled=""
	_ct_uss_guarded=()
	_ct_uss_mounts=()
	_ct_uss_subs=()
	[ "${CT_USER_STATE_SANDBOX:-1}" != 0 ] || return 1
	[ "$(uname -s)" = Linux ] || return 1
	command -v unshare >/dev/null 2>&1 || return 1
	local probe
	probe="$(mktemp -d "${TMPDIR:-/tmp}/ct-uss-probe.XXXXXX")" || return 1
	mkdir -p "${probe}/lower" "${probe}/up/0" "${probe}/work/0"
	echo user >"${probe}/lower/kept"
	local uid gid
	uid="$(id -u)"
	gid="$(id -g)"
	# The probe is the real thing: read a file through the overlay, write
	# one, and report the uid it ran as. It works only when the write reached
	# the upper layer, not the lower one, and the uid is the caller's.
	local seen
	# shellcheck disable=SC2016 # $1 is the probe program's own argument
	seen="$(CT_USS_UID="${uid}" CT_USS_GID="${gid}" unshare --user \
		--map-root-user --mount bash -c "${_ct_uss_entry}" ct-user-state-sandbox \
		"${probe}/lower" "${probe}/up/0" "${probe}/work/0" -- \
		sh -c 'cat "$1/kept" && echo x >"$1/new" && id -u' sh "${probe}/lower" \
		2>/dev/null)" || seen=""
	local ok=""
	if [ "${seen}" = "user
${uid}" ] && [ -f "${probe}/up/0/new" ] && [ ! -e "${probe}/lower/new" ]; then
		ok=1
	fi
	chmod -R u+rwx "${probe}" 2>/dev/null
	rm -rf "${probe}"
	[ -n "${ok}" ] || return 1
	local d parent
	while IFS= read -r d; do
		parent="$(dirname "${d}")"
		if [ -d "${d}" ]; then
			_ct_uss_guarded+=("${d}")
			_ct_uss_mounts+=("${d}")
			_ct_uss_subs+=("")
		elif [ -d "${parent}" ]; then
			_ct_uss_guarded+=("${d}")
			_ct_uss_mounts+=("${parent}")
			_ct_uss_subs+=("$(basename "${d}")")
		fi
	done < <(ct_user_state_guard_dirs)
	export CT_USS_UID="${uid}" CT_USS_GID="${gid}"
	_ct_uss_enabled=1
}

ct_user_state_sandbox_prefix() {
	# Set `ct_uss_cmd` to the command prefix that runs a program in a fresh
	# sandbox whose layers live under directory `$1`; empty when the sandbox
	# is off, so `${ct_uss_cmd[@]+"${ct_uss_cmd[@]}"} prog` degrades to
	# running `prog`. Two guarded directories under one parent share that
	# parent's overlay (`_ct_uss_layer` maps each to its layer).
	ct_uss_cmd=()
	_ct_uss_layer=()
	[ -n "${_ct_uss_enabled}" ] || return 0
	local root="$1" i k found args=() layers=()
	for i in "${!_ct_uss_mounts[@]}"; do
		found=""
		for k in "${!layers[@]}"; do
			if [ "${layers[$k]}" = "${_ct_uss_mounts[$i]}" ]; then
				found="${k}"
				break
			fi
		done
		if [ -z "${found}" ]; then
			found="${#layers[@]}"
			layers+=("${_ct_uss_mounts[$i]}")
			mkdir -p "${root}/up/${found}" "${root}/work/${found}"
			args+=("${_ct_uss_mounts[$i]}" "${root}/up/${found}" "${root}/work/${found}")
		fi
		_ct_uss_layer+=("${found}")
	done
	ct_uss_cmd=(unshare --user --map-root-user --mount bash -c "${_ct_uss_entry}"
		ct-user-state-sandbox ${args[@]+"${args[@]}"} --)
}

ct_user_state_sandbox_findings() {
	# Print what a run left in the upper layers under `$1` as the real paths
	# it would have changed, one `wrote <path>` or `removed <path>` per line,
	# compared the way the snapshot compares each directory: state and config
	# by content, the trace index by content and share's other entries by
	# top-level name, the cache by name. Then remove the layers.
	local root="$1" i dir upper rel real top
	[ -n "${_ct_uss_enabled}" ] || return 0
	for i in "${!_ct_uss_guarded[@]}"; do
		dir="${_ct_uss_guarded[$i]}"
		upper="${root}/up/${_ct_uss_layer[$i]}"
		[ -n "${_ct_uss_subs[$i]}" ] && upper="${upper}/${_ct_uss_subs[$i]}"
		[ -d "${upper}" ] || continue
		while IFS= read -r -d '' rel; do
			rel="${rel#"${upper}"}"
			real="${dir}${rel}"
			top="${rel#/}"
			top="${top%%/*}"
			case "${dir}" in
			*/.local/share/codetracer)
				case "${top}" in
				trace_index.db*) ;;
				*)
					# By top-level name: a new or deleted recording, not
					# what changed inside an existing one.
					if [ -c "${upper}${rel}" ] && [ "/${top}" = "${rel}" ]; then
						echo "removed ${real}"
					elif [ ! -e "${dir}/${top}" ]; then
						echo "wrote ${dir}/${top}"
					fi
					continue
					;;
				esac
				;;
			*/.cache/codetracer)
				# By name: an entry rewritten in place is not a finding.
				if [ -f "${upper}${rel}" ] && [ -e "${real}" ]; then
					continue
				fi
				;;
			esac
			if [ -c "${upper}${rel}" ]; then
				# An overlay whiteout: the run deleted the real entry.
				echo "removed ${real}"
			elif [ -f "${real}" ] && cmp -s "${real}" "${upper}${rel}"; then
				# A copy-up of a file opened for writing and left unchanged.
				continue
			else
				echo "wrote ${real}"
			fi
		done < <(find "${upper}" -mindepth 1 \( -type f -o -type c \) -print0 2>/dev/null | sort -z)
	done | sort -u
	chmod -R u+rwx "${root}" 2>/dev/null
	rm -rf "${root}"
}

# THE STAGE SANDBOX: the same overlay around a whole entry point instead of one
# test file.
#
# A lint stage is not split into files the way a lane is, so it compared the
# user's directories once, around everything it ran, and a writer elsewhere on
# the host failed it: on 2026-11-05 `ci/lint/nim.sh` on nixos-ci-bare-003
# reported ten `~/.cache/codetracer/{sync-families,go-sync-families}` entries
# while an strace of every process the stage started showed none of them
# writing there. Another checkout's `ct-mcr record` tests had.
#
# Called near the top of an entry point as
#   ct_user_state_stage_sandbox <label> bash "$0" "$@"
# it runs that command (the entry point again) in one sandbox and exits with
# its status, or with 1 when the sandbox caught a write to the user's state,
# named. The inner run sees CT_USS_STAGE set, so the call returns 1 there and
# the entry point goes on as before; CT_USS_STAGE_COVERED tells its snapshot
# guard which directories the sandbox covers, so that guard still checks only
# what the sandbox cannot. It returns 1 without running anything on a host
# with no sandbox, and there the entry point's own comparison is the guard.
ct_user_state_stage_sandbox() {
	local label="$1"
	shift
	[ -z "${CT_USS_STAGE:-}" ] || return 1
	ct_user_state_sandbox_enable || return 1
	local root rc found covered
	root="$(mktemp -d "${TMPDIR:-/tmp}/ct-uss-${label}.XXXXXX")" || return 1
	ct_user_state_sandbox_prefix "${root}"
	covered="$(printf '%s\n' "${_ct_uss_guarded[@]}")"
	echo "${label}: running in a sandbox over the user's CodeTracer state ($(ct_user_state_guard_dirs_text))"
	CT_USS_STAGE="${label}" CT_USS_STAGE_COVERED="${covered}" \
		"${ct_uss_cmd[@]}" "$@" && rc=0 || rc=$?
	found="$(ct_user_state_sandbox_findings "${root}")"
	if [ -n "${found}" ]; then
		{
			echo "ERROR: ${label} WROTE the user's own CodeTracer state" \
				"($(ct_user_state_guard_dirs_text)). It ran in a sandbox, so these" \
				"changes were this stage's own (or a binary it spawned) and were" \
				"kept out of the real directories:"
			printf '%s\n' "${found}" | sed 's/^/    /'
		} >&2
		exit 1
	fi
	echo "${label}: the sandbox caught no write to the user's CodeTracer state"
	exit "${rc}"
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
