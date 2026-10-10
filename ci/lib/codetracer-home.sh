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
# `Architecture/Build-Outputs-And-Path-Resolution.md` (CODETRACER_HOME).
#
# Usage (source it, then call):
#   source ci/lib/codetracer-home.sh
#   ct_export_scratch_codetracer_home <label>
#
# A caller that already exported a SCRATCH `CODETRACER_HOME` (inside the temp
# directory, or marked with a `.codetracer-test-home` file — the rule every
# test program applies) keeps it, so a lane started by another lane shares its root. The
# directory it CREATES is named in `ct_scratch_home_created` (empty when an
# inherited one was kept), so a lane removes only what it made:
#   trap 'rm -rf ${ct_scratch_home_created:+"$ct_scratch_home_created"}' EXIT
#
# Deliberately NOT a `.cargo/config.toml` `[env]` entry: that would apply to a
# developer's own `cargo run` of `replay-server` too, and quietly move their
# real state into a temporary directory.

# shellcheck disable=SC2034 # ct_scratch_home_created is read by the caller's EXIT trap
ct_export_scratch_codetracer_home() {
	local label="${1:-lane}"
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
	CODETRACER_HOME="$(mktemp -d "${tmp}/ct-home-${label}.XXXXXX")" || return 1
	ct_scratch_home_created="${CODETRACER_HOME}"
	export CODETRACER_HOME
}
