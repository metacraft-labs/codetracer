#!/usr/bin/env bash
#
# detect-siblings-recorder-artifacts-test.sh -- contract suite for the compiled
# recorder probes in scripts/detect-siblings.sh.
#
# WHAT IS BEING PINNED, AND WHY IT IS NOT "the sibling repo is present"
# --------------------------------------------------------------------
# `detect-siblings.sh` is advisory: it tells a developer, on every dev-shell
# entry, which recorders this workspace can actually use. That makes a FALSE
# POSITIVE its worst possible output -- worse than saying nothing -- because the
# failure then surfaces much later, somewhere else, in a message that names an
# artefact the user has never heard of.
#
# Two of its probes were false positives by construction:
#
#   * ruby   -- probed `-x gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder`,
#               which is a nine-line shim CHECKED INTO GIT at mode 100755. It is
#               present in every fresh clone, so the test could not fail, and the
#               "not built" warning beside it was unreachable code. The real
#               failure came later in `CodeTracer::Native.load_extension!`.
#   * python -- probed for the SOURCE DIRECTORY and a venv interpreter, neither
#               of which says anything about whether the maturin/pyo3 extension
#               was ever installed into that venv.
#
# Both were reproduced on a developer machine before being fixed: the extension
# was absent, `import codetracer_python_recorder` raised ModuleNotFoundError,
# and the script printed "detected" for both.
#
# So the invariant asserted here is: THE PROBE MUST TRACK THE ARTEFACT THE
# LOADER NEEDS. Every case therefore comes in pairs -- artefact absent must
# WARN, artefact present must not -- because a probe that only ever says one
# thing is the defect, whichever thing it says.
#
# Fixtures are built under mktemp with the real directory layout and sourced in
# a subshell. Pure bash; no nix, no network, no ruby, no python, no real
# siblings -- the probes are filesystem tests, so nothing needs to be compiled
# to check that they look in the right place.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DETECT="$REPO_ROOT/scripts/detect-siblings.sh"

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

if [ ! -f "$DETECT" ]; then
	printf 'FAIL: %s is missing\n' "$DETECT"
	exit 1
fi

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# The DLEXT the probe should be looking for on THIS host. The point of the
# macOS case is that `.so` is the wrong name there, so the suite must not
# hard-code either spelling.
case "$(uname -s)" in
Darwin) host_dlext="bundle" ;;
*) host_dlext="so" ;;
esac

# Build a workspace: <ws>/codetracer plus the two recorder siblings. The
# recorder trees carry only what the probes look at.
#
# `with_ruby_ext`  -- "" | "<filename>" placed in ext/native_tracer/target/release
# `with_py_pkg`    -- "" | "1" to install a codetracer_python_recorder into site-packages
build_ws() {
	local ws="$1" with_ruby_ext="$2" with_py_pkg="$3"
	rm -rf "$ws"
	local root="$ws/codetracer"
	mkdir -p "$root"

	# --- ruby sibling ---
	local gem="$ws/codetracer-ruby-recorder/gems/codetracer-ruby-recorder"
	mkdir -p "$gem/bin" "$gem/ext/native_tracer/target/release"
	# The wrapper is ALWAYS present and executable: that is the whole point.
	printf '#!/usr/bin/env ruby\nrequire "codetracer_ruby_recorder"\n' >"$gem/bin/codetracer-ruby-recorder"
	chmod +x "$gem/bin/codetracer-ruby-recorder"
	if [ -n "$with_ruby_ext" ]; then
		printf 'not really a cdylib\n' >"$gem/ext/native_tracer/target/release/$with_ruby_ext"
	fi

	# --- python sibling ---
	mkdir -p "$ws/codetracer-python-recorder/codetracer-python-recorder"
	mkdir -p "$ws/codetracer-python-recorder/codetracer-pure-python-recorder"
	local venv="$root/.python-recorder-venv"
	mkdir -p "$venv/bin" "$venv/lib/python3.13/site-packages"
	printf '#!/bin/sh\nexit 0\n' >"$venv/bin/python"
	chmod +x "$venv/bin/python"
	if [ -n "$with_py_pkg" ]; then
		mkdir -p "$venv/lib/python3.13/site-packages/codetracer_python_recorder"
	fi
}

# Source the detector against a fixture in a clean subshell.
#
# Sets two globals: `out`, the warnings and summary, and `ruby_on_path`, whether
# the ruby wrapper's directory ended up on PATH. The PATH itself is deliberately
# NOT folded into `out`: it is ~2 KB of nix store paths, and a failing assertion
# that prints it buries its own explanation.
out=""
ruby_on_path=""
run_detect() {
	local ws="$1" raw
	# shellcheck disable=SC2016  # $1/$2/$PATH belong to the INNER shell; they
	# are supplied as positional arguments after `_` precisely so the detector
	# is sourced with a clean environment rather than an interpolated string.
	raw="$(env -u CODETRACER_REPO_ROOT_PATH -u CODETRACER_PYTHON_INTERPRETER \
		-u RUBY_RECORDER_ROOT -u DETECT_SIBLINGS_QUIET \
		bash -c '
			source "$1" "$2/codetracer" 2>&1
			echo "PATH_IS=$PATH"
		' _ "$DETECT" "$ws")"
	out="$(printf '%s\n' "$raw" | grep -v '^PATH_IS=')"
	if printf '%s\n' "$raw" | grep '^PATH_IS=' |
		grep -q "$ws/codetracer-ruby-recorder/gems"; then
		ruby_on_path="yes"
	else
		ruby_on_path="no"
	fi
}

printf 'the recorder-artefact probes in detect-siblings.sh\n'

# ===========================================================================
# RUBY
# ===========================================================================

# --- Case 1: THE HISTORICAL DEFECT -- wrapper present, extension absent -----
# The exact state of a fresh clone. This MUST warn. Before the fix it reported
# "(native)".
ws="$tmp_root/ruby-unbuilt"
build_ws "$ws" "" ""
run_detect "$ws"

if printf '%s' "$out" | grep -q "codetracer-ruby-recorder native extension is NOT built"; then
	ok "a checked-in wrapper with no compiled extension WARNS"
else
	fail "a checked-in wrapper with no compiled extension WARNS" \
		"The wrapper is tracked at mode 100755, so this is every fresh clone." \
		"$out"
fi

if printf '%s' "$out" | grep -q "gems present, extension NOT built"; then
	ok "the summary says NOT built rather than (native)"
else
	fail "the summary says NOT built rather than (native)" "$out"
fi

if [ "$ruby_on_path" = "no" ]; then
	ok "an unbuilt recorder is kept OFF PATH"
else
	fail "an unbuilt recorder is kept OFF PATH" \
		"A wrapper on PATH that dies inside load_extension! is worse than no" \
		"wrapper: ct reports a require error instead of 'no recorder found'."
fi

# --- Case 2: the probe names the HOST's extension, not always .so -----------
# `scripts/build-siblings.sh` hard-codes `.so` (deliberately -- its gate is
# Linux-only). A detector that copied that would be wrong on every Mac.
if printf '%s' "$out" | grep -q "codetracer_ruby_recorder.$host_dlext"; then
	ok "the warning names this host's DLEXT (.$host_dlext)"
else
	fail "the warning names this host's DLEXT (.$host_dlext)" \
		"On macOS the loader wants .bundle; looking for .so finds nothing, always." \
		"$out"
fi

# --- Case 3: the built extension is accepted -------------------------------
# The mirror of case 1. Without this the probe could be green-by-refusal.
ws="$tmp_root/ruby-built"
build_ws "$ws" "codetracer_ruby_recorder.$host_dlext" ""
run_detect "$ws"

if printf '%s' "$out" | grep -q "codetracer-ruby-recorder (native)"; then
	ok "a built extension is reported as (native)"
else
	fail "a built extension is reported as (native)" "$out"
fi

if printf '%s' "$out" | grep -q "NOT built"; then
	fail "a built extension produces no 'not built' warning" "$out"
else
	ok "a built extension produces no 'not built' warning"
fi

if [ "$ruby_on_path" = "yes" ]; then
	ok "a built recorder IS put on PATH"
else
	fail "a built recorder IS put on PATH" "$out"
fi

# --- Case 4: the cargo-named cdylib also counts ----------------------------
# `load_extension!` accepts `libcodetracer_ruby_recorder.{so,bundle,dylib,dll}`
# and links it to the name `require` wants. A probe stricter than the loader
# would report "not built" for a tree that works.
ws="$tmp_root/ruby-libname"
build_ws "$ws" "libcodetracer_ruby_recorder.$host_dlext" ""
run_detect "$ws"
if printf '%s' "$out" | grep -q "codetracer-ruby-recorder (native)"; then
	ok "the cargo-named lib*.$host_dlext is accepted, as load_extension! accepts it"
else
	fail "the cargo-named lib*.$host_dlext is accepted, as load_extension! accepts it" \
		"$out"
fi

# --- Case 5: an unrelated file in the target dir is NOT the extension -------
# Guards against relaxing the probe into "something exists in target/release",
# which cargo populates with build artefacts on every build.
ws="$tmp_root/ruby-junk"
build_ws "$ws" "libsomething_else.$host_dlext" ""
run_detect "$ws"
if printf '%s' "$out" | grep -q "NOT built"; then
	ok "an unrelated artefact in target/release does not count as the extension"
else
	fail "an unrelated artefact in target/release does not count as the extension" \
		"$out"
fi

# ===========================================================================
# PYTHON -- the identical gap, in its own spelling
# ===========================================================================

# --- Case 6: sources + venv, package NOT installed -> WARN -----------------
ws="$tmp_root/py-uninstalled"
build_ws "$ws" "codetracer_ruby_recorder.$host_dlext" ""
run_detect "$ws"
if printf '%s' "$out" | grep -q "codetracer-python-recorder is NOT installed"; then
	ok "a venv without the recorder installed WARNS"
else
	fail "a venv without the recorder installed WARNS" \
		"The source tree and the venv both exist in a fresh clone; neither means" \
		"'import codetracer_python_recorder' will work." \
		"$out"
fi

if printf '%s' "$out" | grep -q "sources present, NOT installed"; then
	ok "the python summary distinguishes sources from an installed recorder"
else
	fail "the python summary distinguishes sources from an installed recorder" "$out"
fi

# --- Case 7: installed -> no warning ---------------------------------------
ws="$tmp_root/py-installed"
build_ws "$ws" "codetracer_ruby_recorder.$host_dlext" "1"
run_detect "$ws"
if printf '%s' "$out" | grep -q "codetracer-python-recorder (installed)"; then
	ok "an installed recorder is reported as installed"
else
	fail "an installed recorder is reported as installed" "$out"
fi

if printf '%s' "$out" | grep -q "NOT installed"; then
	fail "an installed recorder produces no warning" "$out"
else
	ok "an installed recorder produces no warning"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
