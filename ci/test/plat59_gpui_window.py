#!/usr/bin/env python3
"""The Video Player's frames in a REAL GPUI window.

    python3 ci/test/plat59_gpui_window.py capture   # inside a headless sway
    python3 ci/test/plat59_gpui_window.py record    # frames -> committed JSON

`capture` (run by `ci/test/plat59-gpui-window.sh`, which starts the headless
sway) opens the windowed `codetracer-gpui` on the `gl_scene` visual recording
and drives it as a user does: a REAL pointer (isonim-gpui's
`build/virtual-pointer`) presses the Video Player's tab and the frame scrubber's
track at frame 30, and REAL keys (`wtype`) step a frame by the Right arrow and go
to the last frame by End, keeping a settled frame (two identical `grim` grabs)
after each.

The window writes its geometry (`CODETRACER_GPUI_GEOMETRY_OUT`), which says where
to AIM, and, under `CODETRACER_GPUI_GESTURE_TRACE=1`, one line per draw of the
image (`visual: image x,y,w,h`) and of the frame scrubber's track
(`visual: track x,y,w,h`), which say where the frame and the scrubber are, and one
per key the window got and per Video Player action. `record` reads the
colours at the centres of the image's four quarters from the frames' PIXELS and
writes `src/tests/visual/plat59-gpui-window.json`, asserted by
`src/frontend/gpui/tests/test_plat59_gpui_window.nim`. Prerequisites are refused
BY NAME, never skipped.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WS = os.path.dirname(ROOT)
ISONIM_GPUI = os.environ.get("ISONIM_GPUI_DIR", os.path.join(WS, "isonim-gpui"))
OUT = os.path.join(ROOT, "build", "plat59-gpui")
BIN = os.environ.get("CODETRACER_PLAT59_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-gpui-window"))
VPOINTER = os.environ.get("CODETRACER_VIRTUAL_POINTER",
                          os.path.join(ISONIM_GPUI, "build", "virtual-pointer"))
RECORD = os.path.join(ROOT, "src", "tests", "visual", "plat59-gpui-window.json")
FIXTURE = os.environ.get(
    "CODETRACER_VISUAL_REPLAY_FIXTURE",
    os.path.join(ROOT, "test-logs", "tui-fixtures", "visual-gl-scene"))
FRAME_W, FRAME_H = 1920, 1080
POLL_S = 0.7
SETTLE_MAX_S = 150
MIDDLE = 30
STEPS = (("frame-0", 0), ("frame-30", MIDDLE), ("frame-59", 59))
ARROW_STEPS = 3


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    return w, h, parts[3]


def settle(name, differs_from=None):
    """Keep a frame once two grabs in a row are identical. With `differs_from` (a
    frame kept earlier) only once the screen differs from it: on a loaded host a
    gesture can take longer to show than two grabs take, and the frame before it
    would be kept as the frame after it."""
    before = None
    if differs_from:
        with open(os.path.join(OUT, differs_from + ".ppm"), "rb") as f:
            before = f.read()
    prev = os.path.join(OUT, name + ".prev.ppm")
    cur = os.path.join(OUT, name + ".cur.ppm")
    same = 0
    waited = 0.0
    while waited < SETTLE_MAX_S:
        time.sleep(POLL_S)
        waited += POLL_S
        try:
            subprocess.run(["grim", "-t", "ppm", cur], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            continue
        if os.path.exists(prev) and open(prev, "rb").read() == open(cur, "rb").read():
            same += 1
        else:
            same = 0
        os.replace(cur, prev)
        if before is not None and open(prev, "rb").read() == before:
            same = 0
            continue
        if same >= 2 and max(read_ppm(prev)[2][::97]) > 40:
            os.replace(prev, os.path.join(OUT, name + ".ppm"))
            print(f"  {name}: settled after {waited:.1f}s", flush=True)
            return True
    print(f"  {name}: DID NOT SETTLE in {SETTLE_MAX_S}s", flush=True)
    return False


def keys(*names, gap_ms=150):
    """One `wtype`, for all of them: each process is a new virtual keyboard, and a
    press in the moment it is announced to the window can be lost."""
    args = ["wtype", "-d", str(gap_ms), "-s", "500"]
    for name in names:
        args += ["-k", name]
    subprocess.run(args, check=True)


def capture():
    if not os.path.isfile(os.path.join(FIXTURE, "gfx_stream", "gfx_frames.idx")):
        sys.exit("PLAT-59: refusing to capture — no visual recording at " + FIXTURE +
                 " (scripts/record-visual-replay-fixture.sh records it)")
    for path, what in ((BIN, "the windowed codetracer-gpui (-d:gpuiShimPath=<windowed shim>)"),
                       (VPOINTER, "isonim-gpui's build/virtual-pointer")):
        if not os.path.exists(path):
            sys.exit(f"PLAT-59: refusing to capture — {what} is missing at {path}")
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    state = os.path.join(OUT, "state")
    os.makedirs(state)
    geometry = os.path.join(OUT, "window.geometry.json")
    env = dict(os.environ)
    env.update({
        "XDG_STATE_HOME": state,
        "CODETRACER_TUI_LAYOUT_DIR": state,
        "CODETRACER_HOME": os.path.join(state, "ct-home"),
        "CODETRACER_GPUI_GEOMETRY_OUT": geometry,
        "CODETRACER_GPUI_GESTURE_TRACE": "1",
    })
    logpath = os.path.join(OUT, "window.run.log")
    log = open(logpath, "w")
    win = subprocess.Popen([BIN, "--quit-after-ms=600000", f"--width={FRAME_W}",
                            f"--height={FRAME_H}", FIXTURE],
                           env=env, stdout=log, stderr=subprocess.STDOUT)
    ptr = subprocess.Popen([VPOINTER, str(FRAME_W), str(FRAME_H)],
                           stdin=subprocess.PIPE, text=True)

    def send(*cmds):
        for c in cmds:
            ptr.stdin.write(c + "\n")
        ptr.stdin.flush()

    def traced(what):
        """The last gesture-trace line's four numbers after `visual: <what> `."""
        log.flush()
        found = None
        with open(logpath) as f:
            for line in f:
                m = re.search(r"visual: " + what + r" (\d+),\s*(\d+),\s*(\d+),\s*(\d+)", line)
                if m:
                    found = [int(v) for v in m.groups()]
        return found

    def trace_count(needle):
        with open(logpath) as f:
            return sum(needle in line for line in f)

    def box_now():
        return traced("image")

    results = {}
    try:
        settle("opened")
        g = None
        for _ in range(60):
            try:
                with open(geometry) as f:
                    g = json.load(f)
                break
            except (OSError, ValueError):
                time.sleep(0.5)
        if g is None:
            sys.exit("PLAT-59: the window wrote no geometry")
        node = next((n for n in g["nodes"]
                     if n.get("kind") == "tabs" and "videoPlayer" in n["panes"]), None)
        if node is None:
            sys.exit("PLAT-59: no Video Player tab in the window's geometry")
        x, y, w, h = node["tabs"][node["panes"].index("videoPlayer")]
        send(f"abs {x + w // 2} {y + h // 2}", "sleep 150", "down", "sleep 120", "up", "sleep 300")
        ok = settle("frame-0")
        results["frame-0"] = {"settled": ok, "box": box_now()}
        # The real arrow: a frame forward per press, while the pane has focus.
        keys(*["Right"] * ARROW_STEPS)
        settle("arrows", differs_from="frame-0")
        # The real pointer on the scrubber's track: a press and a release at
        # the column of frame 30.
        track = traced("track")
        if track is None:
            sys.exit("PLAT-59: the window traced no frame scrubber")
        tx, ty, tw, th = track
        at = tx + round((tw - 1) * MIDDLE / 59)
        send(f"abs {at} {ty + th // 2}", "sleep 150", "down", "sleep 120", "up", "sleep 300")
        ok = settle("frame-30", differs_from="arrows")
        results["frame-30"] = {"settled": ok, "box": box_now()}
        keys("End")
        ok = settle("frame-59", differs_from="frame-30")
        results["frame-59"] = {"settled": ok, "box": box_now()}
    finally:
        send("quit")
        ptr.stdin.close()
        ptr.wait(timeout=20)
        win.terminate()
        try:
            win.wait(timeout=20)
        except subprocess.TimeoutExpired:
            win.kill()
        log.close()
    # Counted once the window has exited, which is when its trace is all written.
    results["arrow-keys"] = {"pressed": ARROW_STEPS,
                             "stepped": trace_count("visual: key VpaStepFrameForward")}
    with open(os.path.join(OUT, "capture.json"), "w") as f:
        json.dump(results, f, indent=1)
    print(json.dumps(results))


def record():
    with open(os.path.join(OUT, "capture.json")) as f:
        results = json.load(f)
    if results["arrow-keys"]["stepped"] != results["arrow-keys"]["pressed"]:
        sys.exit(f"PLAT-59: the arrow keys did not step the frame: {results['arrow-keys']}")
    frames = []
    for name, frame in STEPS:
        step = results[name]
        if not step["settled"] or not step["box"]:
            sys.exit(f"PLAT-59: {name} did not settle on an image: {step}")
        w, _, raster = read_ppm(os.path.join(OUT, name + ".ppm"))
        bx, by, bw, bh = step["box"]
        quads = []
        for fx, fy in ((1, 1), (3, 1), (1, 3), (3, 3)):
            px, py = bx + bw * fx // 4, by + bh * fy // 4
            i = (py * w + px) * 3
            quads.append("#%02x%02x%02x" % tuple(raster[i:i + 3]))
        frames.append({"frame": frame, "box": step["box"], "imageQuads": quads})
    with open(RECORD, "w") as f:
        json.dump({
            "_comment": [
                "The Video Player's frames, read from a real GPUI window's pixels on a headless sway.",
                "Produced by ci/test/plat59-gpui-window.sh and ci/test/plat59_gpui_window.py.",
                "imageQuads: the centres of the image's quarters: top left, top right, bottom left, bottom right.",
            ],
            "frames": frames}, f, indent=1)
        f.write("\n")
    print("wrote", RECORD)


if __name__ == "__main__":
    {"capture": capture, "record": record}[sys.argv[1]]()
