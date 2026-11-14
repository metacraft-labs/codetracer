#!/usr/bin/env bash
# shellcheck shell=bash
#
# tup-cargo-target.sh — the Cargo target base the tup build of THIS checkout
# uses, created or reopened only when it is provably this checkout's and this
# compiler's.
#
# Usage (executed, never sourced, so it leaks nothing into an env script):
#
#   ci/lib/tup-cargo-target.sh <checkout>
#   ci/lib/tup-cargo-target.sh --export <checkout>
#
# The second form prints the two `export` statements instead, for
#
#   ct_tup_cargo="$(bash ci/lib/tup-cargo-target.sh --export "$PWD")" &&
#     eval "${ct_tup_cargo}"
#
# which is also the documented setup for running `tup` by hand. The values are
# validated to contain no single quote, so single-quoting them is exact.
#
# On success it prints two lines and exits 0:
#
#   <absolute Cargo target base, native spelling>
#   <the base as a Tup output-ignore regex prefix, ending in a separator>
#
# which the callers export as CT_TUP_CARGO_TARGET_BASE and
# CT_TUP_CARGO_TARGET_IGNORE for `src/Tuprules.tup` to `import`. On any refusal
# it prints the reason to stderr, prints nothing on stdout, and exits 1.
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
#     unopenable (2026-10-27);
#   * macOS's periodic /tmp cleanup emptied an `out/` directory a produced
#     binary still loaded from (2026-10-12).
#
# WHERE. `<checkout>/build/tup-cargo-targets/rustc-<release>-<digest>/`:
#
#   * inside the checkout that owns it, so another checkout's build cannot
#     reach it and no other account owns it;
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
#     of `build/`, `build/tup-cargo-targets/` or the base itself;
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
# There is no fallback root, and in particular no host-global one: a refusal
# names its remedy and the build stops. The environment scripts that PREPARE a
# shell (non-nix-build/env.sh, setup-codetracer-runtime-env.sh, the dev shell)
# call this with both variables unset, because preparing is their job; the
# build scripts pass their environment through, so a stale shell is caught.

set -uo pipefail

ct_tup_cargo_refuse() {
	printf 'tup-cargo-target: %s\n' "$1" >&2
	shift
	local line
	for line in "$@"; do printf '  %s\n' "${line}" >&2; done
	exit 1
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

ct_tup_cargo_target() {
	local mode="lines"
	if [ "${1:-}" = "--export" ]; then
		mode="export"
		shift
	fi
	local checkout_arg="${1:-}"
	[ -n "${checkout_arg}" ] || ct_tup_cargo_refuse "usage: tup-cargo-target.sh [--export] <checkout>"
	[ -d "${checkout_arg}/src" ] ||
		ct_tup_cargo_refuse "${checkout_arg} is not a CodeTracer checkout (no src/)."
	local checkout
	checkout="$(cd "${checkout_arg}" && pwd -P)" ||
		ct_tup_cargo_refuse "cannot resolve ${checkout_arg}."

	# The compiler Cargo will run, and its identity.
	local rustc rustc_path rustc_real vv sysroot release
	rustc="${RUSTC:-rustc}"
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

	local identity digest root base
	identity="compiler=${rustc_real}
${vv}
sysroot=${sysroot}"
	digest="$(printf '%s' "${identity}" | cksum | awk '{print $1}')"
	root="${checkout}/build/tup-cargo-targets"
	base="${root}/rustc-${release}-${digest}"

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

	ct_tup_cargo_own_dir "${checkout}/build"
	ct_tup_cargo_own_dir "${root}"

	local marker="${base}/.ct-tup-cargo-owner" expected
	expected="codetracer tup cargo target base v1
checkout=${checkout}
${identity}"

	if [ -L "${base}" ]; then
		ct_tup_cargo_refuse "${base} is a symbolic link; refusing to build through it."
	fi
	if [ -e "${base}" ]; then
		[ -d "${base}" ] || ct_tup_cargo_refuse "${base} exists and is not a directory."
		[ -O "${base}" ] || ct_tup_cargo_refuse "${base} is owned by another user."
		if [ -L "${marker}" ] || [ ! -f "${marker}" ]; then
			ct_tup_cargo_refuse "${base} has no owner marker, so nothing says whose it is." \
				"An interrupted first build leaves this. If nothing else builds here:" \
				"  rm -r ${base}"
		fi
		if [ "$(cat "${marker}")" != "${expected}" ]; then
			ct_tup_cargo_refuse "${base} belongs to a different checkout or compiler." \
				"Its marker (${marker}) does not describe this one. It may have been" \
				"copied or moved here. Remove it to start a fresh base:" "  rm -r ${base}"
		fi
		local entry name
		for entry in "${base}"/* "${base}"/.[!.]* "${base}"/..?*; do
			[ -e "${entry}" ] || [ -L "${entry}" ] || continue
			name="${entry##*/}"
			[ "${name}" = ".ct-tup-cargo-owner" ] && continue
			case "${name}" in
			backend_manager_target* | db_backend_target* | virtualization_layers_target*)
				if [[ ! ${name} =~ ^(backend_manager|db_backend|virtualization_layers)_target[A-Za-z0-9]*$ ]]; then
					ct_tup_cargo_refuse "unexpected entry ${entry} in the Cargo target base."
				fi
				if [ -L "${entry}" ] || [ ! -d "${entry}" ]; then
					ct_tup_cargo_refuse "${entry} is not a plain directory; refusing to build into it."
				fi
				;;
			*)
				ct_tup_cargo_refuse "unexpected entry ${entry} in the Cargo target base." \
					"The base holds only the owner marker and the Cargo target directories;" \
					"anything else was not put there by this build."
				;;
			esac
		done
	else
		mkdir "${base}" || ct_tup_cargo_refuse "cannot create ${base}."
		# Written beside, then renamed, so a reader never sees half a marker.
		if ! printf '%s' "${expected}" >"${marker}.tmp.$$" ||
			! mv "${marker}.tmp.$$" "${marker}"; then
			ct_tup_cargo_refuse "cannot write the owner marker ${marker}."
		fi
	fi

	if [ "${mode}" = "export" ]; then
		printf "export CT_TUP_CARGO_TARGET_BASE='%s'\nexport CT_TUP_CARGO_TARGET_IGNORE='%s'\n" \
			"${base_native}" "${ignore}"
	else
		printf '%s\n%s\n' "${base_native}" "${ignore}"
	fi
}

ct_tup_cargo_target "$@"
