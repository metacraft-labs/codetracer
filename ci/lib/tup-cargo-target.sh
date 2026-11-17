#!/usr/bin/env bash
# shellcheck shell=bash
#
# tup-cargo-target.sh — the Cargo target directory a build of THIS checkout
# uses, created or reopened only when it is provably this checkout's and this
# compiler's.
#
# Usage (executed, never sourced, so it leaks nothing into an env script):
#
#   ci/lib/tup-cargo-target.sh [--reap] <checkout>
#   ci/lib/tup-cargo-target.sh [--reap] --export <checkout>
#   ci/lib/tup-cargo-target.sh --repro-slot [--rustc-probe <probe binary>] <checkout>
#
# THE TUP FORMS. The first prints two lines and exits 0:
#
#   <absolute Cargo target base, native spelling>
#   <the base as a Tup output-ignore regex prefix, ending in a separator>
#
# `--export` prints `export` statements instead, for
#
#   ct_tup_env="$(bash ci/lib/tup-cargo-target.sh --export "$PWD")" &&
#     eval "${ct_tup_env}"
#
# which is also the documented setup for running `tup` by hand. It sets all
# three values `src/Tuprules.tup` imports and refuses to parse without:
# CT_TUP_CARGO_TARGET_BASE, CT_TUP_CARGO_TARGET_IGNORE, and CT_TUP_NIM_CACHE_ROOT
# (from `ci/lib/nim-cache-root.sh --tup`). One command, so a shell cannot end
# up with one root set and the other guessed. The values are validated to
# contain no single quote, so single-quoting them is exact.
#
# THE REPRO FORM (`--repro-slot`) serves `repro.nim`, whose Cargo actions need
# a target directory that is a CONSTANT of the build graph: reprobuild reuses
# the provider snapshot and the lowered-graph cache across invocations that
# differ only in the ambient environment (reprobuild
# docs/user-guide/idiomatic-reprobuild.md §4.4), so a compiler probed while the
# graph is evaluated would be frozen at the first build. The graph therefore
# names `<checkout>/build/repro-cargo-targets/active/<crate>_target`, and this
# form, run by an uncacheable action ordered before both Cargo actions, keeps
# `active` bound to the compiler that is about to run:
#
#   * `active` carries the same owner marker as a tup base and passes the same
#     refusals;
#   * when its marker names a DIFFERENT compiler, it is retired by rename to
#     `rustc-<release>-<digest of that compiler>` beside it, and a retired
#     directory for the current compiler (if one passes the refusals) is
#     renamed back into `active`; otherwise a fresh `active` is created.
#     Renames keep every absolute path a target directory records valid,
#     because each one is only ever used under the name it was built at
#     (`active`).
#
# WHICH COMPILER. The repro Cargo actions do not run the PATH `rustc` this
# script would find: the engine provisions its own toolchain onto the Cargo
# edge's PATH as a sub-tool, and a shell action is not given it. So repro.nim
# first builds `ci/lib/repro-cargo-probe` with the SAME cargo action machinery;
# its build script records the absolute path of the rustc Cargo resolved, and
# `--rustc-probe <its binary>` takes the compiler from there instead of PATH.
#
# It prints the slot path. The repro build never shares a directory with the
# tup build: tup bases live under `build/tup-cargo-targets/`, the repro slot
# under `build/repro-cargo-targets/`. Both use the marker format below, written
# and checked by this one file, so the two cannot disagree about it.
#
# On any refusal every form prints the reason to stderr, prints nothing on
# stdout, and exits 1.
#
# THE CONTRACT. codetracer-pm spec/Testing/UI-Cargo-Output-Ownership.md (the
# approved bounded design) and the issue it answers,
# issues/2026-10-05-ui-tup-cargo-targets-collide-across-workspaces-and-compilers.md.
# The rules used to build into four host-global roots under /tmp/codetracer.
# Measured consequences, all from the shared root:
#
#   * E0514 — `libdb_backend.rlib` built by rustc 1.96 in the shared target
#     was read by a checkout whose compiler is 1.89;
#   * one checkout ran ANOTHER checkout's build script, whose fingerprint was
#     fresh by mtime, and the emulator library it should have deployed was
#     missing (2026-11-05);
#   * `/tmp/codetracer` owned by another account made `.cargo-lock`
#     unopenable (2026-10-27, the repro.nim path);
#   * macOS's periodic /tmp cleanup emptied an `out/` directory a produced
#     binary still loaded from (2026-10-12, the repro.nim path).
#
# WHERE. `<checkout>/build/tup-cargo-targets/rustc-<release>-<digest>/`:
#
#   * inside the checkout that owns it, so another checkout's build cannot
#     reach it, no other account owns it, and no /tmp cleanup empties it;
#   * outside the tup root (`src/`, where `src/.tup` lives), so tup on Linux
#     does not track the writes through its FUSE mount, and the checkout's
#     own `/build/` .gitignore entry already covers it;
#   * keyed on the COMPILER, so a toolchain change opens a fresh base instead
#     of feeding an old compiler's metadata to a new one (the E0514 case).
#     The digest is a POSIX `cksum` of the resolved rustc's real path, its
#     `rustc -vV` output and its sysroot — the compiler Cargo will run, which
#     is `${RUSTC:-rustc}` from PATH: no crate here carries a rust-toolchain
#     file or a `build.rustc` override. It is asked from `src/`, so a rustup
#     directory override there would be honoured the way Cargo honours it.
#
# WHAT IS REFUSED, before any Cargo command runs:
#
#   * a symlink, a non-directory, or a directory owned by another user at any
#     of `build/`, the root or the base itself;
#   * a base whose owner marker is missing, is not a regular file, or names a
#     different checkout or compiler;
#   * any entry in the base other than the marker and the three target
#     directories (cargo's transient `<target><random>` included), and any of
#     those that is a link;
#   * a CT_TUP_CARGO_TARGET_BASE or CT_TUP_CARGO_TARGET_IGNORE already in the
#     environment that differs from what this checkout and compiler select —
#     a shell prepared for another checkout, or a hand-set value;
#   * a path with characters the Tup rules cannot carry (anything outside
#     `A-Za-z0-9._+:/-`; a space would split the unquoted `--target-dir`).
#
# REAPING (`--reap`, and always in `--repro-slot`). A base per compiler would
# otherwise grow by one cold target (~12 GB for db-backend) per toolchain
# change, forever. After the selected base has passed every check, the other
# directories in the SAME root are removed when each one, individually:
#
#   * is a real directory (not a link) owned by this user, named like a base;
#   * carries this file's marker naming THIS checkout;
#   * passes the same entry checks as a selected base;
#   * has an older marker than the selected base's (`-ot`): a base created
#     after the selected one is kept, so switching back to an older compiler
#     does not destroy the newer one in the same step;
#   * has no target directory whose Cargo lock is held, where `flock` exists
#     to ask (util-linux; macOS has none and skips this check).
#
# Anything that fails a check is LEFT, with a note on stderr, and the build
# goes on: a stray object in an old base is a reason not to delete it, not a
# reason to stop a build that does not use it. The selected base, an unmarked
# directory, and anything outside the root are never candidates. The marker is
# removed last, so an interrupted removal leaves a directory that is still
# recognisably ours and is finished on the next run. Only the BUILD entry
# points pass `--reap` (scripts/build-once.sh, scripts/build.sh,
# ci/build/dev.sh, build_for_extension.sh); the scripts that only PREPARE a
# shell do not, so entering a shell with another compiler cannot remove a base
# a build in the same checkout is using.
#
# There is no fallback root, and in particular no host-global one: a refusal
# names its remedy and the build stops. The environment scripts that PREPARE a
# shell (non-nix-build/env.sh, setup-codetracer-runtime-env.sh, the dev shell)
# call this with both Cargo variables unset, because preparing is their job;
# the build scripts pass their environment through, so a stale shell is caught.

set -uo pipefail

CT_CARGO_MARKER_NAME=".ct-tup-cargo-owner"
CT_CARGO_MARKER_HEADER="codetracer tup cargo target base v1"

ct_tup_cargo_refuse() {
	printf 'tup-cargo-target: %s\n' "$1" >&2
	shift
	local line
	for line in "$@"; do printf '  %s\n' "${line}" >&2; done
	exit 1
}

ct_tup_cargo_note() {
	printf 'tup-cargo-target: %s\n' "$*" >&2
}

# A directory this run may write into: absent (then created), or a real
# directory owned by this user. `-L` first, because `-d` follows links.
ct_tup_cargo_own_dir() {
	local dir="$1"
	if [ -L "${dir}" ]; then
		ct_tup_cargo_refuse "${dir} is a symbolic link; refusing to build through it." \
			"Remove the link; the build creates this directory itself."
	fi
	if [ -e "${dir}" ]; then
		[ -d "${dir}" ] || ct_tup_cargo_refuse "${dir} exists and is not a directory."
		[ -O "${dir}" ] || ct_tup_cargo_refuse "${dir} is owned by another user." \
			"A Cargo target must belong to the account that builds into it."
		return 0
	fi
	mkdir "${dir}" || ct_tup_cargo_refuse "cannot create ${dir}."
}

# The base as a regex prefix that matches it whichever separator tup reports.
# Bracket classes, not backslash escapes: tup 0.8 keeps `\\` in a variable
# verbatim, so `\\.` would mean "a backslash, then any character" — measured,
# along with `[.]` and `[/\\]` behaving identically whether the text is in the
# Tupfile or arrives through `import`. On Windows letters are matched in either
# case, since the filesystem is case-insensitive and the spelling tup reports
# need not be the one Cargo was given.
ct_tup_cargo_regex_prefix() {
	local path="$1" windows="$2" out="" ch i lower upper
	for ((i = 0; i < ${#path}; i++)); do
		ch="${path:i:1}"
		case "${ch}" in
		/) out="${out}[/\\\\]" ;;
		. | + | -) out="${out}[${ch}]" ;;
		[A-Za-z])
			if [ "${windows}" = 1 ]; then
				lower="$(printf '%s' "${ch}" | tr '[:upper:]' '[:lower:]')"
				upper="$(printf '%s' "${ch}" | tr '[:lower:]' '[:upper:]')"
				out="${out}[${upper}${lower}]"
			else
				out="${out}${ch}"
			fi
			;;
		*) out="${out}${ch}" ;;
		esac
	done
	printf '%s[/\\\\]' "${out}"
}

# Every entry of a base must be the marker or a plain target directory. Prints
# the reason and returns 1 otherwise, so the selected base can refuse and the
# reaper can leave the directory alone.
ct_tup_cargo_entries_ok() {
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
ct_tup_cargo_base_shape_ok() {
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
ct_tup_cargo_write_marker() {
	local marker="$1" text="$2"
	if ! printf '%s' "${text}" >"${marker}.tmp.$$" ||
		! mv "${marker}.tmp.$$" "${marker}"; then
		ct_tup_cargo_refuse "cannot write the owner marker ${marker}."
	fi
}

# The identity part of a marker (everything after the header and checkout
# lines) and the base name it implies, so a retired repro slot is named
# exactly as a tup base for the same compiler would be.
ct_tup_cargo_name_for_identity() {
	local identity="$1" release digest
	release="$(printf '%s\n' "${identity}" | sed -n 's/^release: //p')"
	digest="$(printf '%s' "${identity}" | cksum | awk '{print $1}')"
	[ -n "${release}" ] || return 1
	printf 'rustc-%s-%s' "${release}" "${digest}"
}

# Is any Cargo lock in this base held right now? Only asked where `flock`
# exists; elsewhere the answer is "not known to be held".
ct_tup_cargo_in_use() {
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
ct_tup_cargo_reap() {
	local root="$1" keep="$2" checkout="$3" candidate name why first second entry
	for candidate in "${root}"/*; do
		[ -e "${candidate}" ] || [ -L "${candidate}" ] || continue
		[ "${candidate}" = "${keep}" ] && continue
		name="${candidate##*/}"
		[[ ${name} =~ ^rustc-[0-9A-Za-z.+-]+-[0-9]+$ ]] || continue
		if ! why="$(ct_tup_cargo_base_shape_ok "${candidate}")"; then
			ct_tup_cargo_note "left ${candidate}: ${why}."
			continue
		fi
		first="$(sed -n 1p "${candidate}/${CT_CARGO_MARKER_NAME}")"
		second="$(sed -n 2p "${candidate}/${CT_CARGO_MARKER_NAME}")"
		if [ "${first}" != "${CT_CARGO_MARKER_HEADER}" ] || [ "${second}" != "checkout=${checkout}" ]; then
			ct_tup_cargo_note "left ${candidate}: its marker is not this checkout's."
			continue
		fi
		if ! why="$(ct_tup_cargo_entries_ok "${candidate}")"; then
			ct_tup_cargo_note "left ${candidate}: ${why}."
			continue
		fi
		if [ ! "${candidate}/${CT_CARGO_MARKER_NAME}" -ot "${keep}/${CT_CARGO_MARKER_NAME}" ]; then
			continue
		fi
		if ct_tup_cargo_in_use "${candidate}"; then
			ct_tup_cargo_note "left ${candidate}: a Cargo build holds its lock."
			continue
		fi
		ct_tup_cargo_note "removing ${candidate} (an older compiler's base for this checkout)."
		for entry in "${candidate}"/*_target*; do
			[ -e "${entry}" ] || continue
			rm -rf -- "${entry}" || {
				ct_tup_cargo_note "could not finish removing ${candidate}; it is kept and retried next time."
				continue 2
			}
		done
		rm -f -- "${candidate}/${CT_CARGO_MARKER_NAME}"
		rmdir -- "${candidate}" ||
			ct_tup_cargo_note "could not remove the emptied ${candidate}."
	done
}

ct_tup_cargo_target() {
	local mode="lines" reap=0 probe=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--export) mode="export" ;;
		--repro-slot) mode="repro" ;;
		--reap) reap=1 ;;
		--rustc-probe)
			[ $# -ge 2 ] || ct_tup_cargo_refuse "--rustc-probe needs the probe binary."
			probe="$2"
			shift
			;;
		*) break ;;
		esac
		shift
	done
	local checkout_arg="${1:-}"
	[ -n "${checkout_arg}" ] ||
		ct_tup_cargo_refuse "usage: tup-cargo-target.sh [--reap] [--export | --repro-slot [--rustc-probe <binary>]] <checkout>"
	[ -d "${checkout_arg}/src" ] ||
		ct_tup_cargo_refuse "${checkout_arg} is not a CodeTracer checkout (no src/)."
	local checkout
	checkout="$(cd "${checkout_arg}" && pwd -P)" ||
		ct_tup_cargo_refuse "cannot resolve ${checkout_arg}."

	# The compiler Cargo will run, and its identity.
	local rustc rustc_path rustc_real vv sysroot release
	rustc="${RUSTC:-rustc}"
	if [ -n "${probe}" ]; then
		[ -x "${probe}" ] || [ -x "${probe}.exe" ] ||
			ct_tup_cargo_refuse "the compiler probe ${probe} has not been built." \
				"repro.nim builds it before this step; build the slot target, not this action alone."
		rustc="$("${probe}")" || ct_tup_cargo_refuse "the compiler probe ${probe} failed."
		rustc="${rustc%$'\r'}"
		if command -v cygpath >/dev/null 2>&1; then
			rustc="$(cygpath -u "${rustc}")" || ct_tup_cargo_refuse "cygpath failed on ${rustc}."
		fi
		[ -n "${rustc}" ] || ct_tup_cargo_refuse "the compiler probe ${probe} printed no compiler."
	fi
	rustc_path="$(command -v "${rustc}")" ||
		ct_tup_cargo_refuse "no Rust compiler '${rustc}' on PATH; the Cargo rules cannot run." \
			"Enter the dev shell (nix develop), or source env.sh / non-nix-build/env.sh."
	rustc_real="${rustc_path}"
	if command -v realpath >/dev/null 2>&1; then
		rustc_real="$(realpath "${rustc_path}")" || rustc_real="${rustc_path}"
	fi
	vv="$(cd "${checkout}/src" && "${rustc_path}" -vV)" ||
		ct_tup_cargo_refuse "'${rustc_path} -vV' failed; cannot identify the compiler."
	sysroot="$(cd "${checkout}/src" && "${rustc_path}" --print sysroot)" ||
		ct_tup_cargo_refuse "'${rustc_path} --print sysroot' failed; cannot identify the compiler."
	release="$(printf '%s\n' "${vv}" | sed -n 's/^release: //p')"
	[ -n "${release}" ] || ct_tup_cargo_refuse "'rustc -vV' printed no release line."

	local identity name expected
	identity="compiler=${rustc_real}
${vv}
sysroot=${sysroot}"
	name="$(ct_tup_cargo_name_for_identity "${identity}")"
	expected="${CT_CARGO_MARKER_HEADER}
checkout=${checkout}
${identity}"

	if [ "${mode}" = "repro" ]; then
		ct_tup_cargo_repro_slot "${checkout}" "${name}" "${expected}"
		return 0
	fi

	local root base
	root="${checkout}/build/tup-cargo-targets"
	base="${root}/${name}"

	# Windows (Git Bash): Cargo and tup need the native spelling `C:/...`.
	local windows=0 base_native="${base}"
	if command -v cygpath >/dev/null 2>&1; then
		windows=1
		base_native="$(cygpath -m "${base}")" || ct_tup_cargo_refuse "cygpath failed on ${base}."
	fi
	case "${base_native}" in
	*[!A-Za-z0-9._+:/-]*)
		ct_tup_cargo_refuse "the target base '${base_native}' contains characters the Tup rules cannot carry." \
			"Allowed: A-Z a-z 0-9 . _ + : / - (the --target-dir argument is unquoted, and the" \
			"ignore regex is built from the path). Move the checkout to a plain path."
		;;
	esac
	local ignore
	ignore="$(ct_tup_cargo_regex_prefix "${base_native}" "${windows}")"

	# A value the caller supplied must be exactly this one.
	if [ -n "${CT_TUP_CARGO_TARGET_BASE:-}" ] && [ "${CT_TUP_CARGO_TARGET_BASE}" != "${base_native}" ]; then
		ct_tup_cargo_refuse "CT_TUP_CARGO_TARGET_BASE is already set to a different base." \
			"set:      ${CT_TUP_CARGO_TARGET_BASE}" \
			"selected: ${base_native}  (checkout ${checkout}, rustc ${release})" \
			"This shell was prepared for another checkout or compiler. Unset it, or re-enter" \
			"the dev shell / re-source the environment script in this checkout."
	fi
	if [ -n "${CT_TUP_CARGO_TARGET_IGNORE:-}" ] && [ "${CT_TUP_CARGO_TARGET_IGNORE}" != "${ignore}" ]; then
		ct_tup_cargo_refuse "CT_TUP_CARGO_TARGET_IGNORE is already set to a different expression." \
			"set:      ${CT_TUP_CARGO_TARGET_IGNORE}" "selected: ${ignore}"
	fi

	# The Nim cache root goes out with the Cargo values (see --export above).
	local nim_root=""
	if [ "${mode}" = "export" ]; then
		nim_root="$(bash "$(dirname "${BASH_SOURCE[0]}")/nim-cache-root.sh" --tup "${checkout}")" ||
			ct_tup_cargo_refuse "ci/lib/nim-cache-root.sh --tup failed for ${checkout}."
		case "${nim_root}" in
		*\'* | "") ct_tup_cargo_refuse "the Nim cache root '${nim_root}' cannot be exported." ;;
		esac
	fi

	ct_tup_cargo_own_dir "${checkout}/build"
	ct_tup_cargo_own_dir "${root}"
	ct_tup_cargo_open_base "${base}" "${expected}"
	[ "${reap}" = 1 ] && ct_tup_cargo_reap "${root}" "${base}" "${checkout}"

	if [ "${mode}" = "export" ]; then
		printf "export CT_TUP_CARGO_TARGET_BASE='%s'\nexport CT_TUP_CARGO_TARGET_IGNORE='%s'\nexport CT_TUP_NIM_CACHE_ROOT='%s'\n" \
			"${base_native}" "${ignore}" "${nim_root}"
	else
		printf '%s\n%s\n' "${base_native}" "${ignore}"
	fi
}

# Create `base` with its marker, or reopen it after every check; refuse
# otherwise.
ct_tup_cargo_open_base() {
	local base="$1" expected="$2" why marker="$1/${CT_CARGO_MARKER_NAME}"
	if [ -e "${base}" ] || [ -L "${base}" ]; then
		if ! why="$(ct_tup_cargo_base_shape_ok "${base}")"; then
			ct_tup_cargo_refuse "${why}; refusing to build into it." \
				"An interrupted first build leaves a base with no marker. If nothing else" \
				"builds here:  rm -r ${base}"
		fi
		if [ "$(cat "${marker}")" != "${expected}" ]; then
			ct_tup_cargo_refuse "${base} belongs to a different checkout or compiler." \
				"Its marker (${marker}) does not describe this one. It may have been" \
				"copied or moved here. Remove it to start a fresh base:" "  rm -r ${base}"
		fi
		if ! why="$(ct_tup_cargo_entries_ok "${base}")"; then
			ct_tup_cargo_refuse "${why}; refusing to build into it." \
				"The base holds only the owner marker and the Cargo target directories;" \
				"anything else was not put there by this build."
		fi
		return 0
	fi
	mkdir "${base}" || ct_tup_cargo_refuse "cannot create ${base}."
	ct_tup_cargo_write_marker "${marker}" "${expected}"
}

# The repro slot: `<checkout>/build/repro-cargo-targets/active`, bound to the
# current compiler by renames (see THE REPRO FORM above).
ct_tup_cargo_repro_slot() {
	local checkout="$1" name="$2" expected="$3"
	local root="${checkout}/build/repro-cargo-targets"
	local slot="${root}/active" retired="${root}/${name}" why
	ct_tup_cargo_own_dir "${checkout}/build"
	ct_tup_cargo_own_dir "${root}"

	if [ -e "${slot}" ] || [ -L "${slot}" ]; then
		if ! why="$(ct_tup_cargo_base_shape_ok "${slot}")"; then
			ct_tup_cargo_refuse "${why}; refusing to build into it." \
				"If nothing else builds here:  rm -r ${slot}"
		fi
		if ! why="$(ct_tup_cargo_entries_ok "${slot}")"; then
			ct_tup_cargo_refuse "${why}; refusing to build into it."
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
				ct_tup_cargo_refuse "${slot} belongs to a different checkout." \
					"Its marker does not name ${checkout}; it may have been copied here." \
					"Remove it to start a fresh slot:  rm -r ${slot}"
			fi
			rec_identity="$(printf '%s\n' "${recorded}" | sed '1,2d')"
			rec_name="$(ct_tup_cargo_name_for_identity "${rec_identity}")" ||
				ct_tup_cargo_refuse "${slot}'s marker names no compiler release."
			if [ -e "${root}/${rec_name}" ] || [ -L "${root}/${rec_name}" ]; then
				ct_tup_cargo_refuse "cannot retire ${slot}: ${root}/${rec_name} already exists."
			fi
			mv -- "${slot}" "${root}/${rec_name}" ||
				ct_tup_cargo_refuse "cannot retire ${slot} to ${root}/${rec_name}."
			ct_tup_cargo_note "retired the repro Cargo slot of another compiler to ${rec_name}."
		fi
	fi

	if [ ! -e "${slot}" ]; then
		if [ -e "${retired}" ] || [ -L "${retired}" ]; then
			if ! why="$(ct_tup_cargo_base_shape_ok "${retired}")"; then
				ct_tup_cargo_refuse "${why}; cannot bring it back as the repro slot."
			fi
			[ "$(cat "${retired}/${CT_CARGO_MARKER_NAME}")" = "${expected}" ] ||
				ct_tup_cargo_refuse "${retired} does not carry this checkout's and compiler's marker."
			if ! why="$(ct_tup_cargo_entries_ok "${retired}")"; then
				ct_tup_cargo_refuse "${why}; cannot bring it back as the repro slot."
			fi
			mv -- "${retired}" "${slot}" || ct_tup_cargo_refuse "cannot restore ${retired}."
			ct_tup_cargo_note "restored this compiler's repro Cargo slot from ${name}."
		else
			mkdir "${slot}" || ct_tup_cargo_refuse "cannot create ${slot}."
			ct_tup_cargo_write_marker "${slot}/${CT_CARGO_MARKER_NAME}" "${expected}"
		fi
	fi

	ct_tup_cargo_reap "${root}" "${slot}" "${checkout}"
	printf '%s\n' "${slot}"
}

ct_tup_cargo_target "$@"
