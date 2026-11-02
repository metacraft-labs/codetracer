#!/usr/bin/env python3
"""PLAT-70 Part B — table panes truncate, reveal and resize in a REAL GPUI window.

    python3 ci/test/plat70b_gpui_window.py capture   # inside a headless sway
    python3 ci/test/plat70b_gpui_window.py record    # frames -> committed JSON

`capture` (run by `ci/test/plat70b-gpui-window.sh`, which starts the headless
sway) opens the windowed `codetracer-gpui` on the `wide_lines` recording (an
output line far wider than the Event Log) and drives it as a user does — a
REAL pointer (isonim-gpui's `build/virtual-pointer`, a
`zwlr_virtual_pointer_v1` device) and REAL keys (`wtype`) — keeping a settled
frame (two identical `grim` grabs) after every step:

  base          three F10s in, the pointer parked over the file tree
  hover         the pointer resting on the wide output's cut cell (row 0 of
                the Event Log): its whole text in a tooltip after 500 ms
  fits-hover    the pointer resting on the same row's `#` cell, which fits:
                no tooltip
  detail        a press on the cut cell's `…`: the whole text under the row
  closed        the `…` pressed again: the detail gone
  drag          the `#` column's separator held and moved 40 px right

The window writes its geometry (`CODETRACER_GPUI_GEOMETRY_OUT`; its
`eventColumns` say where each Event Log column is drawn) and, under
`CODETRACER_GPUI_GESTURE_TRACE=1`, a line per gesture (`cell hover … cell=…
ellipsis=…` says where the paint put the cut cell's `…`; `cell tooltip`,
`detail open|closed`, `event log column # N cells`) — WHERE TO AIM, and
what the window says it did, carried under `reportedByWindow`. The verdicts
`record` writes are read from the frames' PIXELS: what changed between a
step's frame and the frame before it, and where.

`record` writes `src/tests/visual/plat70b-gpui-window.json`, asserted by
`src/frontend/gpui/tests/test_plat70b_gpui_window.nim` — the
measure-locally-commit-the-measurement arrangement PLAT-40..48 and 70a use.
Prerequisites are refused BY NAME, never skipped.
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
OUT = os.path.join(ROOT, "build", "plat70b-gpui")
BIN = os.environ.get("CODETRACER_PLAT70B_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-gpui-window"))
VPOINTER = os.environ.get("CODETRACER_VIRTUAL_POINTER",
                          os.path.join(ISONIM_GPUI, "build", "virtual-pointer"))
RECORD = os.path.join(ROOT, "src", "tests", "visual", "plat70b-gpui-window.json")
FRAME_W, FRAME_H = 1920, 1080
POLL_S = 0.7
SETTLE_MAX_S = 150
HEADER_PX = 25   # `leaves.EventHeaderPx`: the first row is under the header
DRAG_PX = 40


def fixture():
    cache = os.path.join(ROOT, "test-logs", "tui-fixtures")
    hits = sorted(e for e in os.listdir(cache) if e.startswith("wide_lines-")) \
        if os.path.isdir(cache) else []
    if not hits:
        sys.exit("PLAT-70: refusing to capture — the wide_lines recording is not "
                 "in test-logs/tui-fixtures/ (the tui-real-terminal lane records it)")
    return os.path.join(cache, hits[-1])


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    return w, h, parts[3]


def grab(path):
    subprocess.run(["grim", "-t", "ppm", path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def settle(name):
    prev = os.path.join(OUT, name + ".prev.ppm")
    cur = os.path.join(OUT, name + ".cur.ppm")
    same = 0
    waited = 0.0
    while waited < SETTLE_MAX_S:
        time.sleep(POLL_S)
        waited += POLL_S
        try:
            grab(cur)
        except subprocess.CalledProcessError:
            continue
        if os.path.exists(prev) and open(prev, "rb").read() == open(cur, "rb").read():
            same += 1
        else:
            same = 0
        os.replace(cur, prev)
        if same >= 2:
            raster = read_ppm(prev)[2]
            if max(raster[::97]) > 40:
                os.replace(prev, os.path.join(OUT, name + ".ppm"))
                print(f"  {name}: settled after {waited:.1f}s", flush=True)
                return True
    print(f"  {name}: DID NOT SETTLE in {SETTLE_MAX_S}s", flush=True)
    return False


class Window:
    def __init__(self, trace):
        self.state = os.path.join(OUT, "state")
        os.makedirs(self.state, exist_ok=True)
        self.geometry = os.path.join(OUT, "window.geometry.json")
        env = dict(os.environ)
        env.update({
            "XDG_STATE_HOME": self.state,
            "CODETRACER_TUI_LAYOUT_DIR": self.state,
            "CODETRACER_HOME": os.path.join(self.state, "ct-home"),
            "CODETRACER_GPUI_GEOMETRY_OUT": self.geometry,
            "CODETRACER_GPUI_GESTURE_TRACE": "1",
        })
        self.logpath = os.path.join(OUT, "window.run.log")
        self.log = open(self.logpath, "w")
        self.proc = subprocess.Popen(
            [BIN, "--quit-after-ms=900000", f"--width={FRAME_W}",
             f"--height={FRAME_H}", trace],
            cwd=OUT, env=env, stdout=self.log, stderr=subprocess.STDOUT)

    def geom(self):
        for _ in range(40):
            try:
                with open(self.geometry) as f:
                    return json.load(f)
            except (OSError, ValueError):
                time.sleep(0.3)
        raise SystemExit("PLAT-70: the window wrote no geometry")

    def traced(self, needle):
        """The last gesture-trace line naming `needle`."""
        self.log.flush()
        last = ""
        with open(self.logpath, errors="replace") as f:
            for line in f:
                if needle in line:
                    last = line.strip()
        return last

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()


class Pointer:
    def __init__(self):
        self.proc = subprocess.Popen([VPOINTER, str(FRAME_W), str(FRAME_H)],
                                     stdin=subprocess.PIPE, text=True)

    def send(self, *cmds):
        for c in cmds:
            self.proc.stdin.write(c + "\n")
        self.proc.stdin.flush()

    def jump(self, x, y):
        self.send(f"abs {x} {y}", "sleep 150")

    def click(self, x, y):
        self.jump(x, y)
        self.send("down", "sleep 120", "up", "sleep 300")

    def drag(self, x, y, dx):
        self.jump(x, y)
        self.send("down", "sleep 200")
        for k in range(1, 5):
            self.send(f"abs {x + dx * k // 4} {y}", "sleep 120")
        self.send("up", "sleep 300")

    def close(self):
        self.send("quit")
        self.proc.stdin.close()
        self.proc.wait(timeout=20)


def node_of(g, pane):
    for n in g["nodes"]:
        if n.get("kind") == "tabs" and pane in n["panes"]:
            return n
    return None


def wait_trace(win, needle, after, timeout=30.0):
    """Wait for a NEW trace line naming `needle` (one other than `after`)."""
    end = time.time() + timeout
    line = after
    while time.time() < end:
        line = win.traced(needle)
        if line and line != after:
            return line
        time.sleep(0.3)
    return line


def span(text, name):
    m = re.search(name + r"=(-?\d+)\.\.(-?\d+)", text or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def capture():
    trace = fixture()
    for path, what in ((BIN, "the windowed codetracer-gpui (-d:gpuiShimPath=<windowed shim>)"),
                       (VPOINTER, "isonim-gpui's build/virtual-pointer")):
        if not os.path.exists(path):
            sys.exit(f"PLAT-70: refusing to capture — {what} is missing at {path}")
    for tool in ("grim", "wtype"):
        if shutil.which(tool) is None:
            sys.exit(f"PLAT-70: refusing to capture — '{tool}' is not on PATH")
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    steps, window, aims = {}, {}, {}
    win = Window(trace)
    ptr = Pointer()
    try:
        settle("start")
        g = win.geom()
        tree = node_of(g, "fileTree")
        tx, ty, tw, th = tree["body"]
        ptr.jump(tx + tw // 2, ty + th - 20)
        # Three F10s, as the plan suite steps: past the module's first lines.
        # A fresh virtual keyboard can lose its first key while the client
        # takes its keymap (PLAT-38's measurement): each F10 is primed, and
        # repeated until the window reports the step; the tries are recorded.
        tries = []
        for _ in range(3):
            before = win.traced("control next tick=")
            for attempt in range(1, 4):
                subprocess.run(["wtype", "-M", "shift", "-m", "shift", "-s", "400",
                                "-k", "F10"], check=True)
                if wait_trace(win, "control next tick=", before, 15.0) != before:
                    break
            tries.append(attempt)
        window["f10Tries"] = tries
        window["tick"] = win.traced("control next tick=")
        steps["base"] = settle("base")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "base.geometry.json"))
        ev = node_of(g, "eventLog")
        if ev is None:
            sys.exit("PLAT-70: no Event Log pane in the window's geometry")
        ex, ey, ew, eh = ev["body"]
        cols = {c["column"]: c for c in g.get("eventColumns", [])}
        if "#" not in cols or "output" not in cols:
            sys.exit("PLAT-70: the window's geometry names no Event Log columns "
                     f"(eventColumns: {g.get('eventColumns')})")
        row_y = cols["#"]["headerY"] + HEADER_PX + 12
        aims["row0Y"] = row_y
        aims["columns"] = g["eventColumns"]
        # Hover: the cut output cell, at the pane's middle.
        before = win.traced("cell tooltip")
        ptr.jump(ex + ew // 2, row_y)
        window["hover"] = wait_trace(win, "cell hover", "")
        window["tooltip"] = wait_trace(win, "cell tooltip", before)
        steps["hover"] = settle("hover")
        cell, dots = span(window["hover"], "cell"), span(window["hover"], "ellipsis")
        rows = span(window["hover"], "row")
        if not (cell and dots and rows):
            sys.exit(f"PLAT-70: the hover named no cut cell: {window['hover']!r}")
        aims["cell"], aims["ellipsis"], aims["rows"] = cell, dots, rows
        # A cell that fits: the same row's `#`.
        tips = win.traced("cell tooltip")
        hc = cols["#"]
        ptr.jump(hc["x"] + hc["w"] // 2, row_y)
        time.sleep(1.5)
        window["fitsTooltip"] = win.traced("cell tooltip") != tips
        steps["fits-hover"] = settle("fits-hover")
        # The `…` pressed: the detail under the row; again: closed.
        dot_x = (dots[0] + dots[1]) // 2
        before = win.traced("detail ")
        ptr.click(dot_x, row_y)
        window["detail"] = wait_trace(win, "detail ", before)
        window["rowClick"] = win.traced("pane click event")
        window["tickAfterDetail"] = win.traced("control ")
        ptr.jump(tx + tw // 2, ty + th - 20)
        steps["detail"] = settle("detail")
        before = win.traced("detail ")
        ptr.click(dot_x, row_y)
        window["closed"] = wait_trace(win, "detail ", before)
        ptr.jump(tx + tw // 2, ty + th - 20)
        steps["closed"] = settle("closed")
        # The `#` separator dragged 40 px right.
        grip_x = hc["x"] + hc["w"] - 3
        grip_y = hc["headerY"] + HEADER_PX // 2
        aims["grip"] = [grip_x, grip_y]
        before = win.traced("event log column")
        held = win.traced("column separator")
        ptr.drag(grip_x, grip_y, DRAG_PX)
        window["separator"] = wait_trace(win, "column separator", held)
        window["drag"] = wait_trace(win, "event log column", before)
        window["headerPress"] = win.traced("pane click header")
        window["orderedBy"] = win.traced("event log order")
        ptr.jump(tx + tw // 2, ty + th - 20)
        steps["drag"] = settle("drag")
        doc = os.path.join(win.state, "table-columns")
        window["remembered"] = open(doc).read() if os.path.exists(doc) else ""
    finally:
        ptr.close()
        win.close()
    with open(os.path.join(OUT, "capture.json"), "w") as f:
        json.dump({"steps": steps, "window": window, "aims": aims}, f, indent=1)
    print("captured:", json.dumps(steps))
    return 0 if all(steps.values()) else 1


def changed_box(a, b):
    """The bounding box [x, y, w, h] of every pixel that differs between two
    frames, or None when they are identical."""
    w, h, ra = a
    rb = b[2]
    if ra == rb:
        return None
    stride = w * 3
    rows = [y for y in range(h) if ra[y * stride:(y + 1) * stride] != rb[y * stride:(y + 1) * stride]]
    x0, x1 = w, -1
    for y in rows:
        la, lb = ra[y * stride:(y + 1) * stride], rb[y * stride:(y + 1) * stride]
        i = 0
        while i < stride and la[i] == lb[i]:
            i += 1
        j = stride - 1
        while j >= 0 and la[j] == lb[j]:
            j -= 1
        x0, x1 = min(x0, i // 3), max(x1, j // 3)
    return [x0, rows[0], x1 - x0 + 1, rows[-1] - rows[0] + 1]


def ink(frame, x0, y0, x1, y1):
    """Pixels in the box unlike the box's first pixel: something drawn."""
    w, _, raster = frame
    ground = raster[(y0 * w + x0) * 3:(y0 * w + x0) * 3 + 3]
    n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            i = (y * w + x) * 3
            if raster[i:i + 3] != ground:
                n += 1
    return n


def record():
    cap = json.load(open(os.path.join(OUT, "capture.json")))
    g0 = json.load(open(os.path.join(OUT, "base.geometry.json")))
    ev = node_of(g0, "eventLog")["body"]
    frames = {s: read_ppm(os.path.join(OUT, s + ".ppm"))
              for s in ("base", "hover", "fits-hover", "detail", "closed", "drag")}
    aims = cap["aims"]
    dots, rows = aims["ellipsis"], aims["rows"]
    out = {"_comment": [
        "PLAT-70 Part B — the GPUI window's table panes: a cut cell hovered,",
        "a fitting cell hovered, the `…` pressed twice, a column separator",
        "dragged. Produced by `ci/test/plat70b-gpui-window.sh` then",
        "`python3 ci/test/plat70b_gpui_window.py record`; asserted by",
        "src/frontend/gpui/tests/test_plat70b_gpui_window.nim.",
    ], "frame": [FRAME_W, FRAME_H], "steps": cap["steps"],
        "eventLogBody": ev, "eventLogRect": node_of(g0, "eventLog")["rect"],
        "editorBody": node_of(g0, "editor")["body"], "aims": aims, "dragPx": DRAG_PX,
        "changed": {
            "hover": changed_box(frames["base"], frames["hover"]),
            "fits-hover": changed_box(frames["base"], frames["fits-hover"]),
            # The press focuses the Event Log (its strip and outline), so
            # the detail is read against the frame after it closed, which
            # differs from the detail's only by the detail.
            "detail": changed_box(frames["closed"], frames["detail"]),
            "closed": changed_box(frames["base"], frames["closed"]),
            "drag": changed_box(frames["closed"], frames["drag"]),
        },
        "ellipsisInk": ink(frames["base"], dots[0], rows[0], dots[1], rows[1]),
        "reportedByWindow": cap["window"]}
    m = re.search(r"event log column # (\d+) cells", cap["window"].get("drag") or "")
    out["reportedByWindow"]["dragCells"] = int(m.group(1)) if m else -1
    with open(RECORD, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("recorded", RECORD)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("capture", "record"):
        sys.exit("usage: plat70b_gpui_window.py capture|record")
    sys.exit(capture() if sys.argv[1] == "capture" else record())
