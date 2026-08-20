#!/usr/bin/env bash
# =============================================================================
# Assemble the `codetracer-desktop` launcher component bundle.
#
# The `ct` launcher (codetracer-launcher) never talks to the desktop core
# directly: it discovers components on disk as
#
#     <components-root>/<name>@<version>/
#         capabilities        # routing contract, see CodeTracer-Launcher.md §2.3
#         bin/<bin-name>      # the binary the launcher execv()s
#
# and routes `ct <cmd> <file.ext>` purely from the `capabilities` file
# (CodeTracer-Launcher.md §2.2/§2.3; `codetracer-launcher/src/caps.nim`,
# `src/launcher.nim` `collectLevels`).
#
# The capability file the product ships is checked in at
# `resources/codetracer-desktop-capabilities`, but until now nothing copied
# it into a component bundle and the core was only ever emitted as
# `src/build-debug/bin/ct`. This script is that missing producer
# (codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.md §5.1,
# deliverable D1 / milestone LRC-0).
#
# Guarantees:
#   * `capabilities` is copied BYTE-FOR-BYTE from the checked-in resource.
#     No templating, no substitution — the launcher's contract is with the
#     file the product actually ships, so a bundle carrying a "fixed up"
#     capability file would test nothing.
#   * The component directory name and the binary filename are both derived
#     FROM that file (`name` / `bin` lines), so the `bin` line and the
#     produced filename can never drift apart.
#   * Idempotent: re-running with the same arguments replaces the bundle
#     in place and yields byte-identical content.
#
# Usage:
#   scripts/build-desktop-component.sh [options]
#
# Options:
#   --out-root DIR   Directory that will CONTAIN `<name>@<version>/`.
#                    This is exactly the path you hand the launcher as
#                    CODETRACER_COMPONENTS_ROOT.
#                    Default: $CODETRACER_COMPONENT_OUT_ROOT, else
#                    <repo>/build-desktop-component (gitignored via `build-*/`).
#   --core-bin PATH  The built core binary to publish as `bin/<bin-name>`.
#                    Default: $CODETRACER_CORE_BIN, else $CODETRACER_E2E_CT_PATH,
#                    else <build-dir>/bin/ct for the known build dirs.
#   --link           Publish the core as a symlink (default). Keeps the
#                    binary's own directory layout reachable through
#                    /proc/self/exe, so a dev build still finds its sibling
#                    helpers (db-backend, db-backend-record, ...).
#   --copy           Publish the core as a real file copy. Use for packaging
#                    where the bundle must stand on its own.
#   --print-path     Print only the resulting bundle directory to stdout.
#   -h | --help      Show this help.
#
# Exits non-zero with a diagnostic if the core binary has not been built —
# it never silently produces a bundle with a missing or dangling binary.
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPS_SRC="$ROOT_DIR/resources/codetracer-desktop-capabilities"

OUT_ROOT="${CODETRACER_COMPONENT_OUT_ROOT:-$ROOT_DIR/build-desktop-component}"
CORE_BIN="${CODETRACER_CORE_BIN:-${CODETRACER_E2E_CT_PATH:-}}"
PUBLISH_MODE="link"
PRINT_PATH_ONLY=0

usage() {
	sed -n '3,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
	--core-bin)
		[[ $# -ge 2 ]] || {
			echo "error: --core-bin requires a path" >&2
			exit 2
		}
		CORE_BIN="$2"
		shift 2
		;;
	--core-bin=*)
		CORE_BIN="${1#*=}"
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
# Host executable suffix. The launcher's POSIX branch execv()s
# `<dir>/bin/<bin-name>` verbatim; on Windows the same name needs the `.exe`
# the loader requires. Everything else about the layout is identical.
# ---------------------------------------------------------------------------
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT*) EXE_SUFFIX=".exe" ;;
*) EXE_SUFFIX="" ;;
esac

# ---------------------------------------------------------------------------
# Read `name` and `bin` out of the checked-in capability file. Deriving both
# from the file is what makes the "bin line agrees with the binary filename"
# invariant structural rather than something a reviewer has to remember.
# ---------------------------------------------------------------------------
if [[ ! -f $CAPS_SRC ]]; then
	echo "error: capability file not found: $CAPS_SRC" >&2
	exit 1
fi

# Grammar note (codetracer-launcher/src/caps.nim): lines are whitespace
# separated tokens; a line whose first non-space byte is '#' is a comment;
# the first matching keyword line wins.
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
# Version. The single source of truth is `src/ct/version.nim`
# (`CodeTracerVersionStr`, calendar versioning YY.0M.MICRO). We re-derive it
# here with the same zero-padding rule rather than inventing a scheme, so the
# bundle directory matches what the core reports at runtime and what
# CodeTracer-Launcher.md §2.2 shows (`codetracer-desktop@25.11.1`).
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
			# ``CodeTracerYear* = 25``  ->  ``25``
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

# `($CodeTracerMonth).align(2, '0')` in version.nim.
COMPONENT_VERSION="$(printf '%s.%02d.%s' "$CT_YEAR" "$((10#$CT_MONTH))" "$CT_BUILD")"

# ---------------------------------------------------------------------------
# Locate the built core.
# ---------------------------------------------------------------------------
if [[ -z $CORE_BIN ]]; then
	for candidate in \
		"${CODETRACER_BUILD_DIR:-$ROOT_DIR/src/build-debug}/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-debug/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-debug-repro/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-release/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-release-repro/bin/ct$EXE_SUFFIX"; do
		if [[ -x $candidate ]]; then
			CORE_BIN="$candidate"
			break
		fi
	done
fi

if [[ -z $CORE_BIN || ! -x $CORE_BIN ]]; then
	{
		echo "error: the CodeTracer core binary has not been built."
		echo "  looked for: ${CORE_BIN:-<build-dir>/bin/ct$EXE_SUFFIX}"
		echo "  Build it with:  just build-once"
		echo "  Or point at an existing binary:  --core-bin <path>  (or \$CODETRACER_CORE_BIN)"
	} >&2
	exit 1
fi
CORE_BIN="$(cd "$(dirname "$CORE_BIN")" && pwd)/$(basename "$CORE_BIN")"

# ---------------------------------------------------------------------------
# Assemble.
# ---------------------------------------------------------------------------
BUNDLE_DIR="$OUT_ROOT/$COMPONENT_NAME@$COMPONENT_VERSION"
BIN_FILE="$BUNDLE_DIR/bin/$BIN_NAME$EXE_SUFFIX"

# Idempotency: tear the bundle down and rebuild it, so a rerun after the
# capability file or the core binary changed cannot leave stale content
# behind. Only this one directory is removed — sibling bundles under the
# same out-root are untouched.
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin"

# Verbatim copy — `cp` with no transformation. Deliberately NOT a
# generated/templated file (design §5.1, "Normative").
cp "$CAPS_SRC" "$BUNDLE_DIR/capabilities"
chmod u+w "$BUNDLE_DIR/capabilities"

case "$PUBLISH_MODE" in
link)
	ln -sfn "$CORE_BIN" "$BIN_FILE"
	;;
copy)
	cp "$CORE_BIN" "$BIN_FILE"
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

log "codetracer-desktop component bundle ready:"
log "  bundle:       $BUNDLE_DIR"
log "  capabilities: $BUNDLE_DIR/capabilities  (verbatim copy of resources/codetracer-desktop-capabilities)"
log "  binary:       $BIN_FILE  ($PUBLISH_MODE -> $CORE_BIN)"
log ""
log "Point the launcher at it with:"
log "  export CODETRACER_COMPONENTS_ROOT=$OUT_ROOT"
