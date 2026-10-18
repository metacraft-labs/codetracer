#!/usr/bin/env python3
"""PLAT-70 Part A — text panes scroll sideways in a REAL GPUI window.

    python3 ci/test/plat70a_gpui_window.py capture   # inside a headless sway
    python3 ci/test/plat70a_gpui_window.py record    # frames -> committed JSON

`capture` (run by `ci/test/plat70a-gpui-window.sh`, which starts the headless
sway) opens the windowed `codetracer-gpui` on the `wide_lines` recording (a
source line and an output line far wider than any pane) and drives it as a
user does — a REAL pointer (isonim-gpui's `build/virtual-pointer`, a
`zwlr_virtual_pointer_v1` device; its `hwheel` turns the HORIZONTAL axis, a
tilt wheel's or a sideways swipe's discrete steps) and REAL keys (`wtype`) —
keeping a settled frame (two identical `grim` grabs) after every step:

  base          the editor at rest: the overflow-only bar under its rows
  hwheel        the real horizontal wheel, one notch right, over the editor
  shift-wheel   Shift held on the virtual keyboard, the VERTICAL wheel turned
                one notch toward the user: a horizontal scroll (§4.3)
  track         a press on the bar's track near its right end: the column
                under it centred (§4.2)
  terminal      the Terminal Output tab pressed: its line view, its own bar
  term-hwheel   the real horizontal wheel over it

The window writes its geometry (`CODETRACER_GPUI_GEOMETRY_OUT`) — where to
AIM — and, under `CODETRACER_GPUI_GESTURE_TRACE=1`, one line per view move
(`editor-hscroll leftCols=…`, `editor-hbar …`, `terminal-hscroll leftCol=…`),
carried under `reportedByWindow`. The verdicts `record` writes are read from
the frames' PIXELS: the bar's thumb found on the bar's own row, where it
starts and ends.

`record` writes `src/tests/visual/plat70a-gpui-window.json`, asserted by
`src/frontend/gpui/tests/test_plat70a_gpui_window.nim` — the
measure-locally-commit-the-measurement arrangement PLAT-40..48 use.
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
OUT = os.path.join(ROOT, "build", "plat70a-gpui")
BIN = os.environ.get("CODETRACER_PLAT70A_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-gpui-window"))
VPOINTER = os.environ.get("CODETRACER_VIRTUAL_POINTER",
                          os.path.join(ISONIM_GPUI, "build", "virtual-pointer"))
RECORD = os.path.join(ROOT, "src", "tests", "visual", "plat70a-gpui-window.json")
FRAME_W, FRAME_H = 1920, 1080
POLL_S = 0.7
SETTLE_MAX_S = 150
BAR_PX = 12
THUMB = (0x79, 0x79, 0x79)
THUMB_ALPHA = 0x66 / 255.0


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


def px(frame, x, y):
    w, _, raster = frame
    i = (y * w + x) * 3
    return raster[i], raster[i + 1], raster[i + 2]


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
        with open(self.logpath) as f:
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
        self.at = (FRAME_W // 2, FRAME_H // 2)

    def send(self, *cmds):
        for c in cmds:
            self.proc.stdin.write(c + "\n")
        self.proc.stdin.flush()

    def jump(self, x, y):
        self.send(f"abs {x} {y}", "sleep 150")
        self.at = (x, y)

    def click(self, x, y):
        self.jump(x, y)
        self.send("down", "sleep 120", "up", "sleep 300")

    def close(self):
        self.send("quit")
        self.proc.stdin.close()
        self.proc.wait(timeout=20)


def node_of(g, pane):
    for n in g["nodes"]:
        if n.get("kind") == "tabs" and pane in n["panes"]:
            return n
    return None


def wait_trace(win, needle, after, timeout=20.0):
    """Wait for a NEW trace line naming `needle` (one other than `after`)."""
    end = time.time() + timeout
    line = after
    while time.time() < end:
        line = win.traced(needle)
        if line and line != after:
            return line
        time.sleep(0.3)
    return line


def capture():
    trace = fixture()
    for path, what in ((BIN, "the windowed codetracer-gpui (-d:gpuiShimPath=<windowed shim>)"),
                       (VPOINTER, "isonim-gpui's build/virtual-pointer (with `hwheel`)")):
        if not os.path.exists(path):
            sys.exit(f"PLAT-70: refusing to capture — {what} is missing at {path}")
    for tool in ("grim", "wtype"):
        if shutil.which(tool) is None:
            sys.exit(f"PLAT-70: refusing to capture — '{tool}' is not on PATH")
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    steps, window = {}, {}
    win = Window(trace)
    ptr = Pointer()
    try:
        settle("base")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "base.geometry.json"))
        ed = node_of(g, "editor")
        if ed is None:
            sys.exit("PLAT-70: no editor pane in the window's geometry")
        bx, by, bw, bh = ed["body"]
        # The editor's scrollbar FADES at rest and shows while the pointer is
        # over the editor (Monaco's; the window's `editorScrollbarShown`), so
        # the rest frame is taken with the pointer there.
        ptr.jump(bx + bw // 2, by + bh // 3)
        steps["base"] = settle("base")
        # The real horizontal wheel, one notch right, over the editor.
        before = win.traced("editor-hscroll")
        ptr.send("hwheel 1", "sleep 400")
        window["hwheel"] = wait_trace(win, "editor-hscroll", before)
        steps["hwheel"] = settle("hwheel")
        # Shift + the vertical wheel: Shift held on the compositor's virtual
        # keyboard while the wheel turns.
        before = win.traced("editor-hscroll")
        held = subprocess.Popen(["wtype", "-M", "shift", "-s", "2500", "-m", "shift"])
        time.sleep(0.8)
        ptr.send("wheel 1", "sleep 400")
        held.wait(timeout=20)
        window["shift-wheel"] = wait_trace(win, "editor-hscroll", before)
        steps["shift-wheel"] = settle("shift-wheel")
        # A press on the bar's track near its right end.
        before = win.traced("editor-hbar")
        ptr.click(bx + int(bw * 0.9), by + bh - BAR_PX // 2 - 1)
        window["track"] = wait_trace(win, "editor-hbar", before)
        steps["track"] = settle("track")
        # The Terminal Output tab, then the wheel over its line view.
        g = win.geom()
        term = node_of(g, "terminalOutput")
        if term is None:
            sys.exit("PLAT-70: no Terminal Output pane in the window's geometry")
        tab = term["tabs"][term["panes"].index("terminalOutput")]
        ptr.click(tab[0] + tab[2] // 2, tab[1] + tab[3] // 2)
        steps["terminal"] = settle("terminal")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "terminal.geometry.json"))
        tx, ty, tw, th = node_of(g, "terminalOutput")["body"]
        ptr.jump(tx + tw // 2, ty + 20)
        before = win.traced("terminal-hscroll")
        ptr.send("hwheel 1", "sleep 400")
        window["term-hwheel"] = wait_trace(win, "terminal-hscroll", before)
        steps["term-hwheel"] = settle("term-hwheel")
    finally:
        ptr.close()
        win.close()
    with open(os.path.join(OUT, "capture.json"), "w") as f:
        json.dump({"steps": steps, "window": window}, f, indent=1)
    print("captured:", json.dumps(steps))
    return 0 if all(steps.values()) else 1


def blend(fg, alpha, ground):
    return tuple(round(f * alpha + g * (1 - alpha)) for f, g in zip(fg, ground))


def thumb_run(frame, x0, w, y):
    """The thumb's pixels on row `y` of a bar spanning `[x0, x0 + w)`: the
    longest run whose colour is the thumb's (#797979 at 40%) over the ground
    under it — the ground read at the bar's far end, which the thumb does
    not reach at rest. (first, last) x, or None."""
    best, run = None, None
    ground = px(frame, x0 + w - 2, y)
    want = blend(THUMB, THUMB_ALPHA, ground)
    for x in range(x0, x0 + w):
        c = px(frame, x, y)
        hit = all(abs(a - b) <= 6 for a, b in zip(c, want)) and c != ground
        if hit:
            run = (run[0], x) if run else (x, x)
            if best is None or run[1] - run[0] > best[1] - best[0]:
                best = run
        else:
            run = None
    return best


def bar_row(frame, x0, w, y_from, y_to):
    """The row in `[y_from, y_to)` where the longest thumb run lies."""
    best = None
    for y in range(y_from, y_to):
        r = thumb_run(frame, x0, w, y)
        if r and (best is None or r[1] - r[0] > best[1][1] - best[1][0]):
            best = (y, r)
    return best


def record():
    cap = json.load(open(os.path.join(OUT, "capture.json")))
    g0 = json.load(open(os.path.join(OUT, "base.geometry.json")))
    gt = json.load(open(os.path.join(OUT, "terminal.geometry.json")))
    ed = node_of(g0, "editor")
    bx, by, bw, bh = ed["body"]
    tx, ty, tw, th = node_of(gt, "terminalOutput")["body"]
    out = {"_comment": [
        "PLAT-70 Part A — the GPUI window's text panes scrolled sideways by a",
        "REAL horizontal wheel, Shift + wheel and a bar press. Produced by",
        "`ci/test/plat70a-gpui-window.sh` then `python3 ci/test/",
        "plat70a_gpui_window.py record`; asserted by",
        "src/frontend/gpui/tests/test_plat70a_gpui_window.nim.",
    ], "frame": [FRAME_W, FRAME_H], "steps": cap["steps"],
        "editorBody": [bx, by, bw, bh], "terminalBody": [tx, ty, tw, th],
        "thumbs": {}, "reportedByWindow": cap["window"]}
    for step in ("base", "hwheel", "shift-wheel", "track"):
        f = read_ppm(os.path.join(OUT, step + ".ppm"))
        found = bar_row(f, bx, bw, by + bh - 2 * BAR_PX, by + bh)
        out["thumbs"][step] = None if found is None else \
            {"y": found[0], "first": found[1][0], "last": found[1][1]}
    for step in ("terminal", "term-hwheel"):
        f = read_ppm(os.path.join(OUT, step + ".ppm"))
        found = bar_row(f, tx, tw, ty + th - 4 * BAR_PX, ty + th)
        out["thumbs"][step] = None if found is None else \
            {"y": found[0], "first": found[1][0], "last": found[1][1]}
    for k, line in cap["window"].items():
        m = re.search(r"leftCols?=(\d+) of (\d+)", line or "")
        out["reportedByWindow"][k] = {"line": line,
                                      "left": int(m.group(1)) if m else -1,
                                      "max": int(m.group(2)) if m else -1}
    with open(RECORD, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("recorded", RECORD)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("capture", "record"):
        sys.exit("usage: plat70a_gpui_window.py capture|record")
    sys.exit(capture() if sys.argv[1] == "capture" else record())
