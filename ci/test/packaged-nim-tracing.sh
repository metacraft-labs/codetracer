#!/usr/bin/env bash
# =============================================================================
# Nim tracing from a packaged CodeTracer, outside the dev shell.
#
#   ci/test/packaged-nim-tracing.sh --nix         the Nix package's `ct` wrapper
#   ci/test/packaged-nim-tracing.sh --appimage    the AppImage's AppRun and its
#                                                 bundled language server and
#                                                 nimsuggest
#
# The desktop traces a Nim static block by asking its Nim language server
# (`CODETRACER_NIM_LS_COMMAND`, else `nimlangserver` on PATH) for
# `nim/traceStaticBlock`, and the server asks the nimsuggest
# `CODETRACER_NIMSUGGEST` names. The dev shell sets the second and puts the
# first on PATH; a packaged CodeTracer has to supply both itself.
#
# Each mode takes the environment the package gives `ct` -- the Nix wrapper's
# (`ci/test/packaged-nim-tracing.nix` runs it over a stub `ct`), or AppRun's
# (the AppRun text from build_appimage.sh, run over a staged AppDir that
# `appimage-scripts/bundle_nim_tracing.sh` filled) -- and starts the language
# server it names, the way the desktop's LSP bridge does, with a PATH that
# holds only what any host has (bash and a few coreutils): no nimsuggest, no
# nim, no nimble. The client
# (`ci/test/lib/nim_lsp_trace_client.py`) answers workspace/configuration with
# nothing for `nim`, as the desktop does, and asks for a static block's trace.
# The test passes only when the answer names a recording that exists.
#
# Nothing is mocked: the real language server and the real nimsuggest the
# package ships, on a real Nim program (test-programs/nim_static_block).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:---nix}"
SYSTEM=$(nix eval --impure --raw --expr 'builtins.currentSystem')
PYTHON=$(command -v python3)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/packaged-nim-tracing.XXXXXX")
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/home" "${WORK}/hostbin" "${WORK}/program"
# The host's PATH: a shell and the coreutils AppRun and the loader wrappers
# use, and nothing else.
for tool in bash env readlink dirname; do
	ln -s "$(command -v "${tool}")" "${WORK}/hostbin/${tool}"
done

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

case "${MODE}" in
--nix)
	slice=$(nix build --no-link --print-out-paths --impure --expr \
		"import ${ROOT_DIR}/ci/test/packaged-nim-tracing.nix { repo = \"${ROOT_DIR}\"; }")
	pkg_env=$(env -i HOME="${WORK}/home" PATH="${WORK}/hostbin" "${slice}/bin/ct")
	;;
--appimage)
	app_dir="${WORK}/AppDir"
	nim_fork=$(nix build --no-link --print-out-paths "${ROOT_DIR}#packages.${SYSTEM}.nim-fork")
	nimlangserver=$(nix build --no-link --print-out-paths "${ROOT_DIR}#packages.${SYSTEM}.nimlangserver")
	bash "${ROOT_DIR}/appimage-scripts/bundle_nim_tracing.sh" "${app_dir}" "${nim_fork}" "${nimlangserver}"
	# AppRun exactly as build_appimage.sh writes it, ending in `env` instead
	# of `ct`.
	env_bin=$(command -v env)
	awk '/^cat <<.EOF. >"\$\{APP_DIR\}\/AppRun"$/ {on=1; next} on && /^EOF$/ {exit} on' \
		"${ROOT_DIR}/appimage-scripts/build_appimage.sh" |
		sed "s|^exec \${HERE}/bin/ct \"\$@\"$|exec ${env_bin}|" >"${app_dir}/AppRun"
	grep -qx "exec ${env_bin}" "${app_dir}/AppRun" || fail "could not read AppRun out of build_appimage.sh"
	pkg_env=$(env -i HOME="${WORK}/home" PATH="${WORK}/hostbin" "$(command -v bash)" "${app_dir}/AppRun")
	;;
*)
	fail "usage: $0 --nix | --appimage"
	;;
esac

value_of() { printf '%s\n' "${pkg_env}" | sed -n "s/^$1=//p" | head -1; }
ls_command=$(value_of CODETRACER_NIM_LS_COMMAND)
nimsuggest=$(value_of CODETRACER_NIMSUGGEST)
echo "language server: ${ls_command:-<unset>}"
echo "nimsuggest:      ${nimsuggest:-<unset>}"
[ -n "${nimsuggest}" ] || fail "the package does not set CODETRACER_NIMSUGGEST"
[ -x "${nimsuggest}" ] || fail "CODETRACER_NIMSUGGEST names no executable: ${nimsuggest}"
[ -n "${ls_command}" ] || fail "the package does not set CODETRACER_NIM_LS_COMMAND"
[ -x "${ls_command}" ] || fail "CODETRACER_NIM_LS_COMMAND names no executable: ${ls_command}"

# Outside the repository: nimsuggest refuses codetracer's root config.nims.
cp "${ROOT_DIR}/test-programs/nim_static_block/main.nim" "${WORK}/program/main.nim"
# `t["alpha"] = "1"`'s statement inside the `static:` block, 0-based.
answer=$(env -i HOME="${WORK}/home" XDG_CACHE_HOME="${WORK}/cache" \
	PATH="${WORK}/hostbin" \
	CODETRACER_NIMSUGGEST="${nimsuggest}" \
	CT_NIM_LSP_STDERR="${WORK}/language-server.stderr" \
	"${PYTHON}" -I "${ROOT_DIR}/ci/test/lib/nim_lsp_trace_client.py" \
	"${ls_command}" "${WORK}/program/main.nim" 10 2) || {
	echo "answer: ${answer:-<none>}" >&2
	tail -20 "${WORK}/language-server.stderr" >&2 || true
	fail "no recording from the packaged language server and nimsuggest (${MODE})"
}
echo "answer: ${answer}"
echo "PASS: ${MODE} traces a Nim static block with only what it ships"
