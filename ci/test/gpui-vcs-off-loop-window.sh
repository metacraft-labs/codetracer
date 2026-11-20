#!/usr/bin/env bash
# THE GPUI WINDOW ANSWERS INPUT WHILE THE VCS PANE'S GIT HAS NOT RETURNED.
#
# A real `codetracer-gpui --edit` window on a headless sway (isonim-gpui's
# `wayland-run-test.sh`, the PLAT-37/38/44/68 lane) over a git repository
# (`scripts/plat47-vcs-fixture.sh`), with a FAKE `git` first on PATH that
# holds every `status` and `log` until a release file exists and runs the
# real git for everything else (the terminal's gate,
# `tui/tests/real_terminal/test_vcs_refresh_off_loop_pty.nim`). `wtype` types
# `x` while git is held; only then is the release file written; then the F12
# sentinel ends the loop.
#
# The window reads git on a background worker (`gpui_host.openGpuiVcs` /
# `refreshGpuiVcs` with `background = true`, polled by `vcsPollTick`), so the
# key reaches the edit arm (`edit-key x`) BEFORE the pane's first read is
# applied (`gesture vcs refreshed`), and that read is applied after the
# release. A window that read git on its loop's thread opens only after the
# release: the key typed before it reaches no window.
#
# Writes `build/gpui-vcs-off-loop/result.json`; `--record` copies it to
# `src/tests/visual/gpui-vcs-off-loop.json`, which
# `src/frontend/gpui/tests/test_gpui_vcs_off_loop_window.nim` asserts over.
# Re-taken by `ci/test/gpui-window-captures.sh vcsoffloop`.
#
# PREREQUISITES are refused by name: sway, wayland-info, wtype, git and a
# `codetracer-gpui` built against the WINDOWED shim (`CODETRACER_VCSOFF_BIN`).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${CODETRACER_VCSOFF_ISONIM_GPUI:-${WS}/isonim-gpui}"
OUT="${root}/build/gpui-vcs-off-loop"
BIN="${CODETRACER_VCSOFF_BIN:-${root}/build/bin/codetracer-gpui-window}"
SETTLE_S=14
HELD_S=4
AFTER_RELEASE_S=8
QUIT_AFTER_MS=90000
INSIDE=0
[ "${1:-}" = "--inside" ] && INSIDE=1
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${OUT}/fakegit"
	bash "${root}/scripts/plat47-vcs-fixture.sh" "${OUT}/repo" >/dev/null || fail "the repository fixture"
	local real_git release
	real_git="$(command -v git)"
	release="${OUT}/release"
	cat >"${OUT}/fakegit/git" <<SH
#!/usr/bin/env bash
case " \$* " in
*" status "* | *" log "*)
	echo "held \$(date +%s%3N) \$1" >>"${OUT}/git.log"
	while [ ! -e "${release}" ]; do sleep 0.05; done
	echo "released \$(date +%s%3N) \$1" >>"${OUT}/git.log"
	;;
esac
exec "${real_git}" "\$@"
SH
	chmod +x "${OUT}/fakegit/git"
	bash -c "sleep ${SETTLE_S}; bash '${root}/ci/test/wtype-keys.sh' x; echo \"typed \$(date +%s%3N)\" >>'${OUT}/typist.log'; \
             sleep ${HELD_S}; echo \"release \$(date +%s%3N)\" >>'${OUT}/typist.log'; touch '${release}'; \
             sleep ${AFTER_RELEASE_S}; bash '${root}/ci/test/wtype-keys.sh' -k F12" >>"${OUT}/typist.log" 2>&1 &
	local typist=$!
	local started ended rc
	started=$(date +%s%3N)
	PATH="${OUT}/fakegit:${PATH}" \
		CODETRACER_GPUI_PROBE_SENTINEL="f12" \
		CODETRACER_GPUI_EDIT_TRACE=1 \
		CODETRACER_GPUI_GESTURE_TRACE=1 \
		CODETRACER_TUI_LAYOUT_DIR="${OUT}/state" \
		LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" --edit "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--width=1440" "--height=900" "${OUT}/repo" \
		>"${OUT}/run.log" 2>&1
	rc=$?
	ended=$(date +%s%3N)
	touch "${release}"
	wait "${typist}" 2>/dev/null || true
	python3 - "${OUT}" "${rc}" "$((ended - started))" "${QUIT_AFTER_MS}" "${BIN}" \
		>"${OUT}/result.json" <<'PY'
import json, os, socket, sys, datetime
out, rc, elapsed, deadline, binary = sys.argv[1:6]
order = []          # the window's own trace, in the order it wrote it
for line in open(os.path.join(out, "run.log"), errors="replace"):
    if line.startswith("edit-key "):
        order.append({"event": "key", "name": line.split()[1]})
    elif line.startswith("gesture vcs refreshed"):
        order.append({"event": "vcs-applied"})
git = [l.split() for l in open(os.path.join(out, "git.log"))] if os.path.exists(os.path.join(out, "git.log")) else []
typist = dict(l.split()[:2] for l in open(os.path.join(out, "typist.log")) if l.split()[:1] in (["typed"], ["release"]))
print(json.dumps({
    "takenAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": socket.gethostname(),
    "binary": os.path.basename(binary),
    "rc": int(rc), "elapsedMs": int(elapsed),
    "endedOnDeadline": int(elapsed) >= int(deadline) - 500,
    "typedAtMs": int(typist.get("typed", 0)), "releasedAtMs": int(typist.get("release", 0)),
    "git": [{"what": g[0], "atMs": int(g[1]), "verb": g[2]} for g in git],
    "order": order,
}, indent=1))
PY
	cat "${OUT}/result.json"
	python3 - "${OUT}/result.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
kinds = [e["event"] for e in r["order"]]
ok = (r["rc"] == 0 and not r["endedOnDeadline"] and "key" in kinds and "vcs-applied" in kinds
      and kinds.index("key") < kinds.index("vcs-applied"))
print("VERDICT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi
if [ "${RECORD}" = "1" ]; then
	[ -f "${OUT}/result.json" ] || fail "no ${OUT}/result.json; run this lane first"
	cp "${OUT}/result.json" src/tests/visual/gpui-vcs-off-loop.json
	echo "recorded src/tests/visual/gpui-vcs-off-loop.json"
	exit 0
fi

[ -f "${ISONIM_GPUI}/scripts/wayland-run-test.sh" ] ||
	fail "${ISONIM_GPUI}/scripts/wayland-run-test.sh is missing"
[ -x "${BIN}" ] || fail "${BIN} is not built (a codetracer-gpui against the windowed shim)"
for tool in sway wayland-info wtype python3 git; do
	command -v "${tool}" >/dev/null 2>&1 ||
		fail "'${tool}' is not on PATH; this lane refuses rather than running without a real keyboard seat"
done
mkdir -p "${OUT}"
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/gpui-vcs-off-loop-window.sh" --inside
rc=$?
echo "gpui-vcs-off-loop-window: rc=${rc}"
exit "${rc}"
