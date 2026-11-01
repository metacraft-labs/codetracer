#!/usr/bin/env bash
# Exercise the capture lane's actual process/shim teardown, without a GUI.
# The Python child stands in for the windowed app only: this suite tests the
# shell/process boundary, using real processes and a real atexit handler.
# ScreenCaptureKit and GPUI are covered by the host-conditional capture lane.
# --lane lets review run exactly these assertions against the unfixed script.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 - "${root}/ci/test/plat37-macos-window-capture.sh" "$@" <<'PYTEST'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

lane = Path(sys.argv[1])
# The real staging library, so that a case below stages as the lane does.
stage_lib = lane.parent.parent / "lib" / "gpui-shim-stage.sh"
if len(sys.argv) > 2:
    assert sys.argv[2] == "--lane" and len(sys.argv) == 4
    lane = Path(sys.argv[3])
source = lane.read_text()

def function(name):
    match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S)
    return match.group() if match else ""

# Extract executable source, rather than a copy of its teardown policy. Keep
# the capture command and its assertions out: they need the GUI grant, whereas
# these process-lifetime assertions must run in the ordinary lint lane.
shutdown = source.split('|| cap_rc=$?\n\n', 1)[1].split('\n\t# THE RECORD', 1)[0]
functions = "\n".join(function(n) for n in ("fail", "wait_capture_app", "quote_app_log", "restore_shim",
                                                 "capture_exit_trap"))
exit_trap = re.search(r"^trap .* EXIT$", source, re.M).group()
failures = []
# Reject a disabled auto-quit before any GUI or build prerequisite is tested.
for value in ("0", "-1", "garbage", "000000000000000000000", "4294967296", "999999999999999999999999999"):
    result = subprocess.run(["bash", str(lane)], env=dict(os.environ,
                            CODETRACER_PLAT37_WINDOW_MS=value),
                            capture_output=True, text=True)
    if result.returncode == 0 or "WINDOW_MS must be" not in result.stderr:
        failures.append("invalid auto-quit was not refused: " + value)
        print("FAIL:", failures[-1])
with tempfile.TemporaryDirectory(prefix="plat37-shutdown-") as temporary:
    scratch = Path(temporary)
    fixture = scratch / "capture_app.py"
    fixture.write_text('import atexit, pathlib, sys, time\nmarker, ready, live, delay, status = sys.argv[1:]\ndef cleanup():\n    pathlib.Path(marker).write_text(pathlib.Path(live).read_text())\natexit.register(cleanup)\npathlib.Path(ready).touch()\ntime.sleep(float(delay))\nsys.exit(int(status))\n')

    def run(name, body, status=0, expected=0):
        case = scratch / name
        case.mkdir()
        live = case / "live"
        arm = case / "windowed"
        live.write_text("original")
        arm.write_text("windowed")
        log = case / "app.log"
        log.write_text("the app's own last words\n")
        env = dict(os.environ, FIXTURE=str(fixture), PYTHON=sys.executable,
                   CASE=str(case), LIVE_SHIM=str(live), ARM=str(arm),
                   SHIM_BACKUP=str(live) + ".gpui-lane-backup",
                   STAGE_LIB=str(stage_lib), BIN=str(fixture), STATUS=str(status),
                   log=str(log))
        script = "set -uo pipefail\ngpid=\nview=fixture\nAPP_LOG_QUOTE_LINES=20\n" + \
            'source "$STAGE_LIB"\n' + functions + r'''
gpui_shim_stage "$LIVE_SHIM" "$ARM" || exit 99
"$PYTHON" "$FIXTURE" "$CASE/cleanup" "$CASE/ready" "$LIVE_SHIM" .3 "$STATUS" &
gpid=$!
while [ ! -f "$CASE/ready" ]; do sleep .01; done
''' + body
        result = subprocess.run(["bash", "-c", script], env=env,
                                capture_output=True, text=True)
        errors = []
        marker = case / "cleanup"
        if not marker.exists():
            errors.append("atexit cleanup did not run")
        elif marker.read_text() != "windowed":
            errors.append("shim restored before app cleanup")
        if result.returncode != expected:
            errors.append(f"exit {result.returncode}, expected {expected}")
        if name.startswith("trap") and live.read_text() != "original":
            errors.append("shim was not restored")
        if name == "scenario-error" and "the app's own last words" not in result.stderr:
            errors.append("a failed app's log was not quoted")
        if errors:
            failures.append(name + ": " + "; ".join(errors))
            print("FAIL:", failures[-1], result.stderr.strip())
        else:
            print("PASS:", name)

    run("scenario", shutdown)
    run("explicit-restore", shutdown + '\nrestore_shim\nprintf continued > "$CASE/continued"\n')
    if not (scratch / "explicit-restore" / "continued").exists():
        failures.append("explicit restore exited before the lane verdict")
        print("FAIL:", failures[-1])
    run("restore-filesystem-error", shutdown + '\nmv() { return 1; }\nrestore_shim\n', expected=1)
    if not (scratch / "restore-filesystem-error" / "live.gpui-lane-backup").exists():
        failures.append("failed restoration lost its backup")
        print("FAIL:", failures[-1])
    run("scenario-error", shutdown, status=7, expected=1)
    run("trap-capture-error", exit_trap + "\nexit 23\n", expected=23)
    run("trap-app-error-successful-lane", exit_trap + "\nexit 0\n", status=7, expected=7)
    run("trap-app-error", exit_trap + "\nexit 23\n", status=7, expected=23)
    # The signal is acted on after the `sleep`, which is shorter than the app's life,
    # so the EXIT trap still has to wait for the app before it restores.
    run("trap-sigterm", exit_trap + "\ngpui_shim_trap_signals\nkill -TERM $$\nsleep .01\nexit 0\n",
        expected=143)
    # A second signal, as a cancelled CI job sends, lands while the EXIT trap waits
    # for the app. It must not abandon the restore that the wait is there for.
    run("trap-second-signal", exit_trap + "\ngpui_shim_trap_signals\n(sleep .1; kill -TERM $$) &\nexit 0\n")

    # An unrelated session of precisely the same executable must survive the
    # EXIT trap. Wait it ourselves so a failing old pkill cannot leave children.
    case = scratch / "unrelated"
    case.mkdir()
    live = case / "live"
    live.write_text("windowed")
    child = subprocess.Popen([sys.executable, str(fixture), str(case / "cleanup"),
                              str(case / "ready"), str(live), ".5", "0"])
    while not (case / "ready").exists():
        import time
        time.sleep(.01)
    result = subprocess.run(["bash", "-c", "set -uo pipefail\ngpid=\n" +
                             'source "$STAGE_LIB"\n' + functions +
                             "\n" + exit_trap + "\nexit 0\n"],
                            env=dict(os.environ, BIN=str(fixture), SHIM_BACKUP="",
                                     STAGE_LIB=str(stage_lib)),
                            capture_output=True, text=True)
    child_status = child.wait()
    if result.returncode or child_status or not (case / "cleanup").exists():
        failures.append("EXIT trap terminated an unrelated app session")
        print("FAIL:", failures[-1])
    else:
        print("PASS: unrelated session survives")
if failures:
    sys.exit(1)
PYTEST
