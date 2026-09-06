#!/usr/bin/env bash
# NOT-A-CI-GATE: a packaging step, not a check on one.
#
# It ASSEMBLES the component bundle; whether the bundle is correct IS a
# question worth gating, and it is gated -- by
# `src/tests/launcher/test_launcher_routes_tui.nim` (the `tui` lane) and
# `src/frontend/tui/tests/real_terminal/test_real_launcher_exec.nim` (the
# `tui-real-terminal` lane), both of which RUN this script and then route the
# real launcher through what it produced. The same split
# `scripts/build-tui-grammars.sh` records for itself, and the same one
# `scripts/build-desktop-component.sh` sits on the other side of.
#
# =============================================================================
# Assemble the `codetracer-tui` launcher component bundle -- CTUI-12.
#
# The `ct` launcher (codetracer-launcher) never talks to a front-end directly:
# it discovers components on disk as
#
#     <components-root>/<name>@<version>/
#         capabilities        # routing contract, CodeTracer-Launcher.md §2.3
#         bin/<bin-name>      # the binary the launcher execv()s
#
# and routes `ct <cmd> <arg>` purely from the `capabilities` file
# (codetracer-launcher/src/caps.nim, src/launcher.nim `fillCandPaths`).
#
# This is the TUI's producer, and it is a DELIBERATE COPY OF THE SHAPE of
# scripts/build-desktop-component.sh rather than a new invention: that script
# is the repository's existing pattern for "a component binary plus its
# capability file", CTUI-12 asks for the pattern to be followed, and the two
# bundles have to be interchangeable from the launcher's side because a real
# install carries both under one components root.
#
# Guarantees, each the same as the desktop script's:
#   * `capabilities` is copied BYTE-FOR-BYTE from packaging/codetracer-tui.caps.
#     No templating: the launcher's contract is with the file the product
#     ships, so a bundle carrying a "fixed up" capability file would test
#     nothing.  Both suites named at the top of this file compare the produced
#     `capabilities` with `packaging/codetracer-tui.caps` byte for byte before
#     routing anything through it.
#   * The component directory name and the binary filename are both DERIVED
#     from that file (`name` / `bin` lines), so the `bin` line and the produced
#     filename cannot drift apart.
#   * Idempotent: re-running with the same arguments replaces the bundle in
#     place and yields byte-identical content.
#
# THE `bin` LINE IS A BARE NAME, NOT A PATH, and this is where §6.1 is wrong in
# a way that would have shipped broken.  The specification's illustration reads
# `bin bin/codetracer-tui`; the launcher joins the component directory, the
# literal `/bin/` (S_BIN_SUB, codetracer-launcher/src/install.nim) and the
# token, so that spelling resolves to `<comp>/bin/bin/codetracer-tui` and
# execv() fails with ENOENT.  packaging/codetracer-tui.caps says
# `bin codetracer-tui`, and this script's layout is what makes that true.
#
# Usage:
#   scripts/build-tui-component.sh [options]
#
# Options:
#   --out-root DIR   Directory that will CONTAIN `<name>@<version>/`.  This is
#                    exactly the path you hand the launcher as
#                    CODETRACER_COMPONENTS_ROOT.
#                    Default: $CODETRACER_COMPONENT_OUT_ROOT, else
#                    <repo>/build-tui-component (gitignored via `build-*/`).
#   --tui-bin PATH   The built TUI binary to publish as `bin/<bin-name>`.
#                    Default: $CODETRACER_TUI_BIN, else <repo>/build/bin/
#                    codetracer-tui.
#   --link           Publish the binary as a symlink (default).
#   --copy           Publish it as a real file copy.  Use for packaging where
#                    the bundle must stand on its own.
#   --print-path     Print only the resulting bundle directory to stdout.
#   -h | --help      Show this help.
#
# Exits non-zero with a diagnostic if the TUI binary has not been built -- it
# never silently produces a bundle with a missing or dangling binary.
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPS_SRC="$ROOT_DIR/packaging/codetracer-tui.caps"

OUT_ROOT="${CODETRACER_COMPONENT_OUT_ROOT:-$ROOT_DIR/build-tui-component}"
TUI_BIN="${CODETRACER_TUI_BIN:-}"
PUBLISH_MODE="link"
PRINT_PATH_ONLY=0

usage() {
	sed -n '14,72p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out-root)
		[[ $# -ge 2 ]] || {
			echo "error: --out-root requires a directory" >&2
			exit 2
		}
		OUT_ROOT="$2"
		shift 2
		;;
	--out-root=*)
		OUT_ROOT="${1#*=}"
		shift
		;;
	--tui-bin)
		[[ $# -ge 2 ]] || {
			echo "error: --tui-bin requires a path" >&2
			exit 2
		}
		TUI_BIN="$2"
		shift 2
		;;
	--tui-bin=*)
		TUI_BIN="${1#*=}"
		shift
		;;
	--link)
		PUBLISH_MODE="link"
		shift
		;;
	--copy)
		PUBLISH_MODE="copy"
		shift
		;;
	--print-path)
		PRINT_PATH_ONLY=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown argument '$1' (try --help)" >&2
		exit 2
		;;
	esac
done

log() {
	if [[ $PRINT_PATH_ONLY -eq 0 ]]; then
		echo "$@"
	fi
}

# ---------------------------------------------------------------------------
# Host executable suffix.  The launcher's POSIX branch execv()s
# `<dir>/bin/<bin-name>` verbatim; on Windows the same name needs the `.exe`
# the loader requires.
# ---------------------------------------------------------------------------
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT*) EXE_SUFFIX=".exe" ;;
*) EXE_SUFFIX="" ;;
esac

# ---------------------------------------------------------------------------
# Read `name` and `bin` out of the checked-in capability file.
# Grammar note (codetracer-launcher/src/caps.nim): whitespace-separated
# tokens; a line whose first non-space byte is '#' is a comment; the first
# matching keyword line wins.
# ---------------------------------------------------------------------------
if [[ ! -f $CAPS_SRC ]]; then
	echo "error: capability file not found: $CAPS_SRC" >&2
	exit 1
fi

caps_token() {
	local keyword="$1"
	awk -v kw="$keyword" '
		{ sub(/\r$/, "") }
		/^[ \t]*#/ { next }
		{ if ($1 == kw && NF >= 2) { print $2; exit } }
	' "$CAPS_SRC"
}

COMPONENT_NAME="$(caps_token name)"
BIN_NAME="$(caps_token bin)"

if [[ -z $COMPONENT_NAME ]]; then
	echo "error: $CAPS_SRC declares no 'name' line" >&2
	exit 1
fi
if [[ -z $BIN_NAME ]]; then
	echo "error: $CAPS_SRC declares no 'bin' line" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Version.  The same source of truth and the same zero-padding rule as
# scripts/build-desktop-component.sh: `src/ct/version.nim`'s
# CodeTracerYear/Month/Build, which is also what `codetracer-tui --version`
# prints (app/cli.nim's TuiVersionText is CodeTracerVersionStr).  Deriving it
# here rather than inventing a scheme is what keeps the bundle directory,
# the desktop bundle beside it and the binary's own `--version` in agreement.
# ---------------------------------------------------------------------------
VERSION_NIM="$ROOT_DIR/src/ct/version.nim"
if [[ ! -f $VERSION_NIM ]]; then
	echo "error: version source not found: $VERSION_NIM" >&2
	exit 1
fi

version_const() {
	local name="$1"
	awk -v n="$name" '
		{ sub(/\r$/, "") }
		$0 ~ ("^[ \t]*" n "\\*?[ \t]*=") {
			sub(/^[^=]*=[ \t]*/, "")
			sub(/[ \t]*(#.*)?$/, "")
			print
			exit
		}
	' "$VERSION_NIM"
}

CT_YEAR="$(version_const CodeTracerYear)"
CT_MONTH="$(version_const CodeTracerMonth)"
CT_BUILD="$(version_const CodeTracerBuild)"

if [[ ! $CT_YEAR =~ ^[0-9]+$ || ! $CT_MONTH =~ ^[0-9]+$ || ! $CT_BUILD =~ ^[0-9]+$ ]]; then
	echo "error: could not parse CodeTracerYear/Month/Build from $VERSION_NIM" >&2
	echo "  parsed: year='$CT_YEAR' month='$CT_MONTH' build='$CT_BUILD'" >&2
	exit 1
fi

COMPONENT_VERSION="$(printf '%s.%02d.%s' "$CT_YEAR" "$((10#$CT_MONTH))" "$CT_BUILD")"

# ---------------------------------------------------------------------------
# Locate the built TUI.
# ---------------------------------------------------------------------------
if [[ -z $TUI_BIN ]]; then
	TUI_BIN="$ROOT_DIR/build/bin/codetracer-tui$EXE_SUFFIX"
fi

if [[ ! -x $TUI_BIN ]]; then
	{
		echo "error: the CodeTracer TUI binary has not been built."
		echo "  looked for: $TUI_BIN"
		echo "  Build it with:  just build-tui"
		# The env var is named WITHOUT a leading `$` on purpose: shfmt
		# rewrites "\$NAME" to '$NAME' and shellcheck then reports SC2016 on
		# the result, so a literal sigil here cannot satisfy both hooks.
		echo "  Or point at an existing binary:  --tui-bin <path>  (or the CODETRACER_TUI_BIN env var)"
	} >&2
	exit 1
fi
TUI_BIN="$(cd "$(dirname "$TUI_BIN")" && pwd)/$(basename "$TUI_BIN")"

# ---------------------------------------------------------------------------
# Assemble.
# ---------------------------------------------------------------------------
BUNDLE_DIR="$OUT_ROOT/$COMPONENT_NAME@$COMPONENT_VERSION"
BIN_FILE="$BUNDLE_DIR/bin/$BIN_NAME$EXE_SUFFIX"

# Idempotency: tear this one bundle down and rebuild it, so a rerun after the
# capability file or the binary changed cannot leave stale content behind.
# Sibling bundles under the same out-root (the desktop's, in particular) are
# untouched -- a components root holding both is the normal install.
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin"

cp "$CAPS_SRC" "$BUNDLE_DIR/capabilities"
chmod u+w "$BUNDLE_DIR/capabilities"

case "$PUBLISH_MODE" in
link)
	ln -sfn "$TUI_BIN" "$BIN_FILE"
	;;
copy)
	cp "$TUI_BIN" "$BIN_FILE"
	chmod +x "$BIN_FILE"
	;;
esac

if [[ ! -x $BIN_FILE ]]; then
	echo "error: produced $BIN_FILE is not executable" >&2
	exit 1
fi

if [[ $PRINT_PATH_ONLY -eq 1 ]]; then
	echo "$BUNDLE_DIR"
	exit 0
fi

log "codetracer-tui component bundle ready:"
log "  bundle:       $BUNDLE_DIR"
log "  capabilities: $BUNDLE_DIR/capabilities  (verbatim copy of packaging/codetracer-tui.caps)"
log "  binary:       $BIN_FILE  ($PUBLISH_MODE -> $TUI_BIN)"
log ""
log "Point the launcher at it with:"
log "  export CODETRACER_COMPONENTS_ROOT=$OUT_ROOT"
log "  ct tui <trace-folder>"
