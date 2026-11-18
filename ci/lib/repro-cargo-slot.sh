#!/usr/bin/env bash
# shellcheck shell=bash
#
# repro-cargo-slot.sh — the Cargo target directory a Reprobuild build of THIS
# checkout uses, created or reopened only when it is provably this checkout's
# and this compiler's.
#
# Usage (executed, never sourced, so it leaks nothing into an env script):
#
#   ci/lib/repro-cargo-slot.sh [--rustc-probe <probe binary>] <checkout>
#
# It prints the slot path, `<checkout>/build/repro-cargo-targets/active`, and
# exits 0; on any refusal it prints the reason to stderr, prints nothing on
# stdout, and exits 1.
#
# WHY A SLOT. `repro.nim`'s Cargo actions need a target directory that is a
# CONSTANT of the build graph: reprobuild reuses the provider snapshot and the
# lowered-graph cache across invocations that differ only in the ambient
# environment (reprobuild docs/user-guide/idiomatic-reprobuild.md §4.4), so a
# compiler probed while the graph is evaluated would be frozen at the first
# build. The graph therefore names
# `<checkout>/build/repro-cargo-targets/active/<crate>_target`, and this script,
# run by an uncacheable action ordered before both Cargo actions, keeps `active`
# bound to the compiler that is about to run:
#
#   * `active` carries an owner marker (the checkout and the compiler's
#     identity) and passes the refusals below;
#   * when its marker names a DIFFERENT compiler, it is retired by rename to
#     `rustc-<release>-<digest of that compiler>` beside it, and a retired
#     directory for the current compiler (if one passes the refusals) is
#     renamed back into `active`; otherwise a fresh `active` is created.
#     Renames keep every absolute path a target directory records valid,
#     because each one is only ever used under the name it was built at
#     (`active`).
#
# WHICH COMPILER. The Cargo actions do not run the PATH `rustc` this script
# would find: the engine provisions its own toolchain onto the Cargo edge's PATH
# as a sub-tool, and a shell action is not given it. So repro.nim first builds
# `ci/lib/repro-cargo-probe` with the SAME cargo action machinery; its build
# script records the absolute path of the rustc Cargo resolved, and
# `--rustc-probe <its binary>` takes the compiler from there instead of PATH.
# The digest is a POSIX `cksum` of the resolved rustc's real path, its
# `rustc -vV` output and its sysroot.
#
# WHY INSIDE THE CHECKOUT. Another checkout's build cannot reach it, no other
# account owns it, no /tmp cleanup empties it, and the checkout's own `/build/`
# .gitignore entry already covers it. The rules used to build into host-global
# roots under /tmp/codetracer; measured consequences, all from the shared root:
#
#   * E0514 — `libdb_backend.rlib` built by rustc 1.96 in the shared target
#     was read by a checkout whose compiler is 1.89;
#   * one checkout ran ANOTHER checkout's build script, whose fingerprint was
#     fresh by mtime, and the emulator library it should have deployed was
#     missing;
#   * a `/tmp/codetracer` owned by another account made `.cargo-lock`
#     unopenable;
#   * macOS's periodic /tmp cleanup emptied an `out/` directory a produced
#     binary still loaded from.
#
# WHAT IS REFUSED, before any Cargo command runs:
#
#   * a symlink, a non-directory, or a directory owned by another user at any
#     of `build/`, the root or the slot itself;
#   * a slot whose owner marker is missing, is not a regular file, or names a
#     different checkout;
#   * any entry in the slot other than the marker and the three target
#     directories (cargo's transient `<target><random>` included), and any of
#     those that is a link.
#
# REAPING. A slot per compiler would otherwise grow by one cold target (~12 GB
# for db-backend) per toolchain change, forever. After the slot has passed every
# check, the other directories in the SAME root are removed when each one,
# individually:
#
#   * is a real directory (not a link) owned by this user, named like a
#     retired slot;
#   * carries this file's marker naming THIS checkout;
#   * passes the same entry checks as the slot;
#   * has an older marker than the slot's (`-ot`);
#   * has no target directory whose Cargo lock is held, where `flock` exists
#     to ask (util-linux; macOS has none and skips this check).
#
# Anything that fails a check is LEFT, with a note on stderr, and the build
# goes on. The marker is removed last, so an interrupted removal leaves a
# directory that is still recognisably ours and is finished on the next run.

set -uo pipefail

CT_CARGO_MARKER_NAME=".ct-cargo-owner"
CT_CARGO_MARKER_HEADER="codetracer cargo target base v1"

ct_cargo_refuse() {
	printf 'repro-cargo-slot: %s\n' "$1" >&2
	shift
	local line
	for line in "$@"; do printf '  %s\n' "${line}" >&2; done
	exit 1
}

ct_cargo_note() {
	printf 'repro-cargo-slot: %s\n' "$*" >&2
}

# A directory this run may write into: absent (then created), or a real
# directory owned by this user. `-L` first, because `-d` follows links.
ct_cargo_own_dir() {
	local dir="$1"
	if [ -L "${dir}" ]; then
		ct_cargo_refuse "${dir} is a symbolic link; refusing to build through it." \
			"Remove the link; the build creates this directory itself."
	fi
	if [ -e "${dir}" ]; then
		[ -d "${dir}" ] || ct_cargo_refuse "${dir} exists and is not a directory."
		[ -O "${dir}" ] || ct_cargo_refuse "${dir} is owned by another user." \
			"A Cargo target must belong to the account that builds into it."
		return 0
	fi
	mkdir "${dir}" || ct_cargo_refuse "cannot create ${dir}."
}

# Every entry of a base must be the marker or a plain target directory. Prints
# the reason and returns 1 otherwise, so the selected base can refuse and the
# reaper can leave the directory alone.
ct_cargo_entries_ok() {
	local base="$1" entry name
	for entry in "${base}"/* "${base}"/.[!.]* "${base}"/..?*; do
		[ -e "${entry}" ] || [ -L "${entry}" ] || continue
		name="${entry##*/}"
		[ "${name}" = "${CT_CARGO_MARKER_NAME}" ] && continue
		if [[ ! ${name} =~ ^(backend_manager|db_backend|virtualization_layers)_target[A-Za-z0-9]*$ ]]; then
			printf 'unexpected entry %s in the Cargo target base' "${entry}"
			return 1
		fi
		if [ -L "${entry}" ] || [ ! -d "${entry}" ]; then
			printf '%s is not a plain directory' "${entry}"
			return 1
		fi
	done
	return 0
}

# A base this run may use or reap: a real directory owned by this user whose
# marker is a regular file. Prints the reason and returns 1 otherwise.
ct_cargo_base_shape_ok() {
	local base="$1" marker="$1/${CT_CARGO_MARKER_NAME}"
	if [ -L "${base}" ]; then
		printf '%s is a symbolic link' "${base}"
		return 1
	fi
	if [ ! -d "${base}" ]; then
		printf '%s is not a directory' "${base}"
		return 1
	fi
	if [ ! -O "${base}" ]; then
		printf '%s is owned by another user' "${base}"
		return 1
	fi
	if [ -L "${marker}" ] || [ ! -f "${marker}" ]; then
		printf '%s has no owner marker, so nothing says whose it is' "${base}"
		return 1
	fi
	return 0
}

# Write the marker beside, then rename, so a reader never sees half of one.
ct_cargo_write_marker() {
	local marker="$1" text="$2"
	if ! printf '%s' "${text}" >"${marker}.tmp.$$" ||
		! mv "${marker}.tmp.$$" "${marker}"; then
		ct_cargo_refuse "cannot write the owner marker ${marker}."
	fi
}

# The identity part of a marker (everything after the header and checkout
# lines) and the base name it implies, so a retired repro slot is named
# by the same rule that names every base here.
ct_cargo_name_for_identity() {
	local identity="$1" release digest
	release="$(printf '%s\n' "${identity}" | sed -n 's/^release: //p')"
	digest="$(printf '%s' "${identity}" | cksum | awk '{print $1}')"
	[ -n "${release}" ] || return 1
	printf 'rustc-%s-%s' "${release}" "${digest}"
}

# Is any Cargo lock in this base held right now? Only asked where `flock`
# exists; elsewhere the answer is "not known to be held".
ct_cargo_in_use() {
	local base="$1" lock
	command -v flock >/dev/null 2>&1 || return 1
	for lock in "${base}"/*_target*/*/.cargo-lock; do
		[ -f "${lock}" ] || continue
		if ! flock -n "${lock}" true 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

# Remove the other bases in `root` that are provably this checkout's and older
# than `keep`. See REAPING above for the rules; every check is repeated per
# candidate, immediately before its removal.
ct_cargo_reap() {
	local root="$1" keep="$2" checkout="$3" candidate name why first second entry
	for candidate in "${root}"/*; do
		[ -e "${candidate}" ] || [ -L "${candidate}" ] || continue
		[ "${candidate}" = "${keep}" ] && continue
		name="${candidate##*/}"
		[[ ${name} =~ ^rustc-[0-9A-Za-z.+-]+-[0-9]+$ ]] || continue
		if ! why="$(ct_cargo_base_shape_ok "${candidate}")"; then
			ct_cargo_note "left ${candidate}: ${why}."
			continue
		fi
		first="$(sed -n 1p "${candidate}/${CT_CARGO_MARKER_NAME}")"
		second="$(sed -n 2p "${candidate}/${CT_CARGO_MARKER_NAME}")"
		if [ "${first}" != "${CT_CARGO_MARKER_HEADER}" ] || [ "${second}" != "checkout=${checkout}" ]; then
			ct_cargo_note "left ${candidate}: its marker is not this checkout's."
			continue
		fi
		if ! why="$(ct_cargo_entries_ok "${candidate}")"; then
			ct_cargo_note "left ${candidate}: ${why}."
			continue
		fi
		if [ ! "${candidate}/${CT_CARGO_MARKER_NAME}" -ot "${keep}/${CT_CARGO_MARKER_NAME}" ]; then
			continue
		fi
		if ct_cargo_in_use "${candidate}"; then
			ct_cargo_note "left ${candidate}: a Cargo build holds its lock."
			continue
		fi
		ct_cargo_note "removing ${candidate} (an older compiler's base for this checkout)."
		for entry in "${candidate}"/*_target*; do
			[ -e "${entry}" ] || continue
			rm -rf -- "${entry}" || {
				ct_cargo_note "could not finish removing ${candidate}; it is kept and retried next time."
				continue 2
			}
		done
		rm -f -- "${candidate}/${CT_CARGO_MARKER_NAME}"
		rmdir -- "${candidate}" ||
			ct_cargo_note "could not remove the emptied ${candidate}."
	done
}

# The repro slot: `<checkout>/build/repro-cargo-targets/active`, bound to the
# current compiler by renames (see THE REPRO FORM above).
ct_cargo_repro_slot() {
	local checkout="$1" name="$2" expected="$3"
	local root="${checkout}/build/repro-cargo-targets"
	local slot="${root}/active" retired="${root}/${name}" why
	ct_cargo_own_dir "${checkout}/build"
	ct_cargo_own_dir "${root}"

	if [ -e "${slot}" ] || [ -L "${slot}" ]; then
		if ! why="$(ct_cargo_base_shape_ok "${slot}")"; then
			ct_cargo_refuse "${why}; refusing to build into it." \
				"If nothing else builds here:  rm -r ${slot}"
		fi
		if ! why="$(ct_cargo_entries_ok "${slot}")"; then
			ct_cargo_refuse "${why}; refusing to build into it."
		fi
		local recorded
		recorded="$(cat "${slot}/${CT_CARGO_MARKER_NAME}")"
		if [ "${recorded}" != "${expected}" ]; then
			# Ours, for another compiler: retire it under that compiler's name.
			local rec_header rec_checkout rec_identity rec_name
			rec_header="$(printf '%s\n' "${recorded}" | sed -n 1p)"
			rec_checkout="$(printf '%s\n' "${recorded}" | sed -n 2p)"
			if [ "${rec_header}" != "${CT_CARGO_MARKER_HEADER}" ] ||
				[ "${rec_checkout}" != "checkout=${checkout}" ]; then
				ct_cargo_refuse "${slot} belongs to a different checkout." \
					"Its marker does not name ${checkout}; it may have been copied here." \
					"Remove it to start a fresh slot:  rm -r ${slot}"
			fi
			rec_identity="$(printf '%s\n' "${recorded}" | sed '1,2d')"
			rec_name="$(ct_cargo_name_for_identity "${rec_identity}")" ||
				ct_cargo_refuse "${slot}'s marker names no compiler release."
			if [ -e "${root}/${rec_name}" ] || [ -L "${root}/${rec_name}" ]; then
				ct_cargo_refuse "cannot retire ${slot}: ${root}/${rec_name} already exists."
			fi
			mv -- "${slot}" "${root}/${rec_name}" ||
				ct_cargo_refuse "cannot retire ${slot} to ${root}/${rec_name}."
			ct_cargo_note "retired the repro Cargo slot of another compiler to ${rec_name}."
		fi
	fi

	if [ ! -e "${slot}" ]; then
		if [ -e "${retired}" ] || [ -L "${retired}" ]; then
			if ! why="$(ct_cargo_base_shape_ok "${retired}")"; then
				ct_cargo_refuse "${why}; cannot bring it back as the repro slot."
			fi
			[ "$(cat "${retired}/${CT_CARGO_MARKER_NAME}")" = "${expected}" ] ||
				ct_cargo_refuse "${retired} does not carry this checkout's and compiler's marker."
			if ! why="$(ct_cargo_entries_ok "${retired}")"; then
				ct_cargo_refuse "${why}; cannot bring it back as the repro slot."
			fi
			mv -- "${retired}" "${slot}" || ct_cargo_refuse "cannot restore ${retired}."
			ct_cargo_note "restored this compiler's repro Cargo slot from ${name}."
		else
			mkdir "${slot}" || ct_cargo_refuse "cannot create ${slot}."
			ct_cargo_write_marker "${slot}/${CT_CARGO_MARKER_NAME}" "${expected}"
		fi
	fi

	ct_cargo_reap "${root}" "${slot}" "${checkout}"
	printf '%s\n' "${slot}"
}

ct_cargo_slot() {
	local probe=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--rustc-probe)
			[ $# -ge 2 ] || ct_cargo_refuse "--rustc-probe needs the probe binary."
			probe="$2"
			shift
			;;
		*) break ;;
		esac
		shift
	done
	local checkout_arg="${1:-}"
	[ -n "${checkout_arg}" ] ||
		ct_cargo_refuse "usage: repro-cargo-slot.sh [--rustc-probe <binary>] <checkout>"
	[ -d "${checkout_arg}/src" ] ||
		ct_cargo_refuse "${checkout_arg} is not a CodeTracer checkout (no src/)."
	local checkout
	checkout="$(cd "${checkout_arg}" && pwd -P)" ||
		ct_cargo_refuse "cannot resolve ${checkout_arg}."

	# The compiler Cargo will run, and its identity.
	local rustc rustc_path rustc_real vv sysroot release
	rustc="${RUSTC:-rustc}"
	if [ -n "${probe}" ]; then
		[ -x "${probe}" ] || [ -x "${probe}.exe" ] ||
			ct_cargo_refuse "the compiler probe ${probe} has not been built." \
				"repro.nim builds it before this step; build the slot target, not this action alone."
		rustc="$("${probe}")" || ct_cargo_refuse "the compiler probe ${probe} failed."
		rustc="${rustc%$'\r'}"
		if command -v cygpath >/dev/null 2>&1; then
			rustc="$(cygpath -u "${rustc}")" || ct_cargo_refuse "cygpath failed on ${rustc}."
		fi
		[ -n "${rustc}" ] || ct_cargo_refuse "the compiler probe ${probe} printed no compiler."
	fi
	rustc_path="$(command -v "${rustc}")" ||
		ct_cargo_refuse "no Rust compiler '${rustc}' on PATH; the Cargo rules cannot run." \
			"Enter the dev shell (nix develop), or source env.sh / non-nix-build/env.sh."
	rustc_real="${rustc_path}"
	if command -v realpath >/dev/null 2>&1; then
		rustc_real="$(realpath "${rustc_path}")" || rustc_real="${rustc_path}"
	fi
	vv="$(cd "${checkout}/src" && "${rustc_path}" -vV)" ||
		ct_cargo_refuse "'${rustc_path} -vV' failed; cannot identify the compiler."
	sysroot="$(cd "${checkout}/src" && "${rustc_path}" --print sysroot)" ||
		ct_cargo_refuse "'${rustc_path} --print sysroot' failed; cannot identify the compiler."
	release="$(printf '%s\n' "${vv}" | sed -n 's/^release: //p')"
	[ -n "${release}" ] || ct_cargo_refuse "'rustc -vV' printed no release line."

	local identity name expected
	identity="compiler=${rustc_real}
${vv}
sysroot=${sysroot}"
	name="$(ct_cargo_name_for_identity "${identity}")"
	expected="${CT_CARGO_MARKER_HEADER}
checkout=${checkout}
${identity}"

	ct_cargo_repro_slot "${checkout}" "${name}" "${expected}"
}

ct_cargo_slot "$@"
