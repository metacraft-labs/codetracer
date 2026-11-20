#!/usr/bin/env bash
# THE GPUI WINDOW IS ON SCREEN BEFORE THE FIRST STOP'S FLOW ANSWERS.
#
# A real `codetracer-gpui` window on a headless sway (isonim-gpui's
# `wayland-run-test.sh`, the PLAT-37/38/44/68 lane), opened on the `calc`
# recording through a FAKE `replay-server` (`REPLAY_SERVER_BIN`): a proxy that
# runs the real one and passes every message through, except that it holds
# the answer to `ct/load-flow` until a release file exists. While the answer
# is held, `swaymsg -t get_tree` is asked whether a window titled CodeTracer
# is mapped; then the release file is written; then the F12 sentinel ends the
# loop. F12 is sent again every 2 s until the window has exited: a key a fresh
# virtual keyboard sends to a window busy with its startup work can be lost
# (`wtype-keys.sh`'s header), and it is the only key this capture types.
#
# The window opens on the stop's code, values and call trace, and asks for the
# flow once it has drawn (`main.runOpen`, `flowAfterWindowTick`), so the
# window is mapped while the flow is held, its first frame has no flow rows,
# and the flow is applied (its rows drawn) after the release. A window that
# asked for the flow before mapping would map only after the release.
#
# The hold is shorter than the window's 30 s per-message clock (ui-selection.md
# §8b), so the held read does not end the run.
#
# Writes `build/gpui-flow-first/result.json`; `--record` copies it to
# `src/tests/visual/gpui-flow-first.json`, which
# `src/frontend/gpui/tests/test_gpui_flow_first_window.nim` asserts over.
# Re-taken by `ci/test/gpui-window-captures.sh flowfirst`.
#
# PREREQUISITES are refused by name: sway, swaymsg, wayland-info, wtype,
# python3, `REPLAY_SERVER_BIN`, the `calc` recording (the capture lane's
# fixture step records it) and a `codetracer-gpui` built against the WINDOWED
# shim (`CODETRACER_FLOWFIRST_BIN`).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${CODETRACER_FLOWFIRST_ISONIM_GPUI:-${WS}/isonim-gpui}"
OUT="${root}/build/gpui-flow-first"
BIN="${CODETRACER_FLOWFIRST_BIN:-${root}/build/bin/codetracer-gpui-window}"
HOLD_S=6
AFTER_RELEASE_S=6
QUIT_AFTER_MS=120000
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
	mkdir -p "${OUT}"
	local traces trace release
	traces=(test-logs/tui-fixtures/calc-*)
	trace="${traces[0]}"
	[ -d "${trace}" ] || fail "no calc recording in test-logs/tui-fixtures/"
	release="${OUT}/release"
	# Only the DAP server is proxied: anything else (`--build-revision`, the
	# window's check of the binary) is the real one's answer.
	cat >"${OUT}/fake-replay-server" <<SH
#!/usr/bin/env bash
case " \$* " in
*" dap-server "*) exec python3 -I '${OUT}/hold-flow.py' '${REPLAY_SERVER_BIN}' "\$@" ;;
*) exec '${REPLAY_SERVER_BIN}' "\$@" ;;
esac
SH
	chmod +x "${OUT}/fake-replay-server"
	cat >"${OUT}/hold-flow.py" <<PY
# The real replay-server, with its answer to ct/load-flow held until
# ${release} exists. Every other message passes as it comes.
import os, subprocess, sys, threading, time
child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
log = open("${OUT}/proxy.log", "a", buffering=1)

def up():
    while True:
        data = sys.stdin.buffer.read1(65536)
        if not data:
            child.stdin.close()
            return
        child.stdin.write(data)
        child.stdin.flush()

threading.Thread(target=up, daemon=True).start()
out = child.stdout
while True:
    headers = b""
    while not headers.endswith(b"\r\n\r\n"):
        c = out.read(1)
        if not c:
            sys.exit(child.wait())
        headers += c
    length = 0
    for line in headers.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    body = out.read(length)
    if b'"type":"response"' in body.replace(b" ", b"") and b'"ct/load-flow"' in body:
        log.write("held %d\n" % int(time.time() * 1000))
        while not os.path.exists("${release}"):
            time.sleep(0.05)
        log.write("released %d\n" % int(time.time() * 1000))
    sys.stdout.buffer.write(headers + body)
    sys.stdout.buffer.flush()
PY
	# The watcher: when the flow's answer is held, ask sway whether the window
	# is mapped, hold for HOLD_S, release, and end the run with F12.
	bash -c "
		until grep -q '^held' '${OUT}/proxy.log' 2>/dev/null; do sleep 0.1; done
		sleep 1
		swaymsg -t get_tree >'${OUT}/tree-while-held.json' 2>/dev/null
		echo \"asked \$(date +%s%3N)\" >>'${OUT}/watcher.log'
		sleep ${HOLD_S}
		echo \"release \$(date +%s%3N)\" >>'${OUT}/watcher.log'
		touch '${release}'
		sleep ${AFTER_RELEASE_S}
		for _ in \$(seq 1 20); do
			[ -e '${OUT}/ended' ] && break
			bash '${root}/ci/test/wtype-keys.sh' -k F12
			echo \"F12 \$(date +%s%3N)\" >>'${OUT}/watcher.log'
			sleep 2
		done" >>"${OUT}/watcher.log" 2>&1 &
	local watcher=$!
	local started ended rc
	started=$(date +%s%3N)
	REPLAY_SERVER_BIN="${OUT}/fake-replay-server" \
		CODETRACER_GPUI_PROBE_SENTINEL="f12" \
		CODETRACER_GPUI_GESTURE_TRACE=1 \
		CODETRACER_TUI_LAYOUT_DIR="${OUT}/state" \
		LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--width=1440" "--height=900" "${trace}" \
		>"${OUT}/run.log" 2>&1
	rc=$?
	ended=$(date +%s%3N)
	touch "${release}" "${OUT}/ended"
	wait "${watcher}" 2>/dev/null || true
	python3 - "${OUT}" "${rc}" "$((ended - started))" "${QUIT_AFTER_MS}" "${BIN}" \
		>"${OUT}/result.json" <<'PY'
import json, os, re, socket, sys, datetime
out, rc, elapsed, deadline, binary = sys.argv[1:6]
order = []          # the window's own trace, in the order it wrote it
for line in open(os.path.join(out, "run.log"), errors="replace"):
    m = re.match(r"gesture flow (deferred|requested|applied)\b.*?(?:flow rows (\d+))?\s*$", line)
    if m:
        e = {"event": m.group(1)}
        if m.group(2) is not None:
            e["flowRows"] = int(m.group(2))
        order.append(e)
proxy = [l.split() for l in open(os.path.join(out, "proxy.log"))] \
    if os.path.exists(os.path.join(out, "proxy.log")) else []

def titles(node, acc):
    if node.get("name"):
        acc.append(node["name"])
    for k in ("nodes", "floating_nodes"):
        for c in node.get(k, []):
            titles(c, acc)
    return acc

held_titles = []
tree = os.path.join(out, "tree-while-held.json")
if os.path.exists(tree):
    try:
        held_titles = titles(json.load(open(tree)), [])
    except ValueError:
        pass
print(json.dumps({
    "takenAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": socket.gethostname(),
    "binary": os.path.basename(binary),
    "rc": int(rc), "elapsedMs": int(elapsed),
    "endedOnDeadline": int(elapsed) >= int(deadline) - 500,
    "proxy": [{"what": p[0], "atMs": int(p[1])} for p in proxy],
    "windowMappedWhileHeld": any("CodeTracer" in t for t in held_titles),
    "titlesWhileHeld": held_titles,
    "order": order,
}, indent=1))
PY
	cat "${OUT}/result.json"
	python3 - "${OUT}/result.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
kinds = [e["event"] for e in r["order"]]
rows = {e["event"]: e.get("flowRows") for e in r["order"]}
ok = (r["rc"] == 0 and not r["endedOnDeadline"] and r["windowMappedWhileHeld"]
      and kinds[:3] == ["deferred", "requested", "applied"]
      and rows.get("requested") == 0 and (rows.get("applied") or 0) > 0
      and [p["what"] for p in r["proxy"]][:2] == ["held", "released"])
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
	cp "${OUT}/result.json" src/tests/visual/gpui-flow-first.json
	echo "recorded src/tests/visual/gpui-flow-first.json"
	exit 0
fi

[ -f "${ISONIM_GPUI}/scripts/wayland-run-test.sh" ] ||
	fail "${ISONIM_GPUI}/scripts/wayland-run-test.sh is missing"
[ -x "${BIN}" ] || fail "${BIN} is not built (a codetracer-gpui against the windowed shim)"
[ -n "${REPLAY_SERVER_BIN:-}" ] && [ -x "${REPLAY_SERVER_BIN}" ] ||
	fail "REPLAY_SERVER_BIN is not set to a replay-server"
for tool in sway swaymsg wayland-info wtype python3; do
	command -v "${tool}" >/dev/null 2>&1 ||
		fail "'${tool}' is not on PATH; this lane refuses rather than running without a compositor"
done
mkdir -p "${OUT}"
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/gpui-flow-first-window.sh" --inside
rc=$?
echo "gpui-flow-first-window: rc=${rc}"
exit "${rc}"
