#!/usr/bin/env python3
"""M71 (codetracer#838) — the State, Files and VCS panes' scrollbars in a REAL
GPUI window.

    python3 ci/test/m71_gpui_window.py capture   # inside a headless sway
    python3 ci/test/m71_gpui_window.py record    # frames -> committed JSON

`capture` (run by `ci/test/m71-gpui-window.sh`, which starts the headless
sway) opens the windowed `codetracer-gpui` on the `multi_root` recording, one
step in (`--replay-ops=next=1`), in a saved layout whose left column stacks a
short State pane, a short Files pane and the VCS pane (`LAYOUT` below) — each
holding fewer rows than it lists — with the working directory a git
repository of `plat47-vcs-fixture.sh` plus sixty untracked files, so the VCS
pane lists far more rows than it shows. It drives the window as a user does,
with a REAL pointer (isonim-gpui's `build/virtual-pointer`, a
`zwlr_virtual_pointer_v1` device whose `wheel` turns the vertical axis by
discrete notches), keeping a settled frame (two identical `grim` grabs) after
every step:

  base          at rest: every pane's scrollbar at its right edge, its thumb
                at the top
  vcs-wheel     the real wheel, three notches down, over the VCS pane
  files-wheel   the real wheel, one notch down, over the Files pane
  state-press   a press on the State pane's bar near its foot: the §3 press
                (Scrollbar-Scrubbers.md) centres the rows there

The window writes its geometry (`CODETRACER_GPUI_GEOMETRY_OUT`) — where to
AIM — and, under `CODETRACER_GPUI_GESTURE_TRACE=1`, one line per view move
(`vcs top=…`, `fileTree top=…`, `state scroll top=…`), carried under
`reportedByWindow`. The verdicts `record` writes are read from the frames'
PIXELS: in each pane's right-edge strip, the column holding the longest
vertical run of one colour set apart from the pane's ground — the thumb —
and where that run starts and ends.

`record` writes `src/tests/visual/m71-gpui-window.json`, asserted by
`src/frontend/gpui/tests/test_m71_gpui_window.nim` — the
measure-locally-commit-the-measurement arrangement PLAT-40..70 use.
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
OUT = os.path.join(ROOT, "build", "m71-gpui")
BIN = os.environ.get("CODETRACER_M71_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-gpui-window"))
VPOINTER = os.environ.get("CODETRACER_VIRTUAL_POINTER",
                          os.path.join(ISONIM_GPUI, "build", "virtual-pointer"))
RECORD = os.path.join(ROOT, "src", "tests", "visual", "m71-gpui-window.json")
FRAME_W, FRAME_H = 1920, 1080
POLL_S = 0.7
SETTLE_MAX_S = 150
EXTRA_FILES = 60
  # Untracked files added to the PLAT-47 fixture repository: the VCS pane
  # then lists 67 rows, far more than its body holds.
EDGE_PX = 32
  # The strip, in from a pane body's right edge, a scrollbar is looked for
  # in: the list track (`list_scrubber.listTrackRect`, at most its padding
  # and its width in) and the State box's 8 px bar both lie inside it.
CONTRAST = 6
  # How far (largest channel) a pixel must be from the pane's ground to be
  # read as drawn (Verification-Harness-Traps §68: probe contrast, not an
  # exact colour). The State box's thumb is the desktop's #333333 on the
  # pane's #282828 — eleven levels apart, measured 2026-10-21.
MIN_THUMB_COLS = 3
CORNER_PX = 3
  # How far a rounded thumb's edge column may stop short of its middle's.
  # A thumb is a rectangle several pixels wide (6 to 12 here); a line a pane
  # is framed or hovered in is one or two, and a glyph's stem is not the
  # same run in three columns side by side.
STATE_ROWS_TOP_PX = 78
  # The State pane's rows box below its body's top (`leaves.StateRowsTopPx`),
  # where its vertical bar's track starts.
STATE_BAR_PX = 8
  # The State box's vertical bar's width (`leaves.StateScrollbarPx`).
LAYOUT = {"version": 5, "docked": [], "layout": {
    "kind": "row", "weight": 1.0, "children": [
        {"kind": "column", "weight": 1.0, "children": [
            {"kind": "pane", "pane": "state", "weight": 0.5},
            {"kind": "pane", "pane": "fileTree", "weight": 0.4},
            {"kind": "pane", "pane": "vcs", "weight": 1.2}]},
        {"kind": "pane", "pane": "editor", "weight": 2.0}]}}
  # Measured with the window plan (`--report-window-plan`) at 1920x1080 on
  # `multi_root` one step in: all three panes overflow — the State box's bar
  # a 122 px track, the Files pane eight rows, the VCS pane 67.
PANES = ("state", "fileTree", "vcs")


def fixture():
    cache = os.path.join(ROOT, "test-logs", "tui-fixtures")
    hits = sorted(e for e in os.listdir(cache) if e.startswith("multi_root-")) \
        if os.path.isdir(cache) else []
    if not hits:
        sys.exit("M71: refusing to capture — the multi_root recording is not "
                 "in test-logs/tui-fixtures/ (ci/test/gpui-window-captures.sh "
                 "records it)")
    return os.path.join(cache, hits[-1])


def vcs_repo(where):
    """The PLAT-47 fixture repository, with `EXTRA_FILES` untracked files."""
    repo = os.path.join(where, "repo")
    subprocess.run(["bash", os.path.join(ROOT, "scripts", "plat47-vcs-fixture.sh"),
                    repo], check=True, stdout=subprocess.DEVNULL)
    for i in range(EXTRA_FILES):
        with open(os.path.join(repo, f"untracked_{i:02d}.txt"), "w") as f:
            f.write(f"{i}\n")
    return repo


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
    def __init__(self, trace, layout, cwd):
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
        # The VCS pane reads the window's working directory (`attachVcs`).
        self.proc = subprocess.Popen(
            [BIN, "--quit-after-ms=900000", f"--width={FRAME_W}",
             f"--height={FRAME_H}", f"--layout={layout}",
             "--replay-ops=next=1", trace],
            cwd=cwd, env=env, stdout=self.log, stderr=subprocess.STDOUT)

    def geom(self):
        for _ in range(40):
            try:
                with open(self.geometry) as f:
                    return json.load(f)
            except (OSError, ValueError):
                time.sleep(0.3)
        raise SystemExit("M71: the window wrote no geometry")

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

    def send(self, *cmds):
        for c in cmds:
            self.proc.stdin.write(c + "\n")
        self.proc.stdin.flush()

    def jump(self, x, y):
        self.send(f"abs {x} {y}", "sleep 150")

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
    """Wait for a NEW trace line naming `needle` (one other than `after`).
    The trace is evidence beside the pixels, not the step's verdict: a
    window that never moves (the defect) times out here and the frames say
    so."""
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
                       (VPOINTER, "isonim-gpui's build/virtual-pointer")):
        if not os.path.exists(path):
            sys.exit(f"M71: refusing to capture — {what} is missing at {path}")
    if shutil.which("grim") is None:
        sys.exit("M71: refusing to capture — 'grim' is not on PATH")
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    layout = os.path.join(OUT, "layout.json")
    with open(layout, "w") as f:
        json.dump(LAYOUT, f)
    repo = vcs_repo(OUT)
    steps, window = {}, {}
    win = Window(trace, layout, repo)
    ptr = Pointer()
    try:
        settle("base")
        g = win.geom()
        bodies = {}
        for pane in PANES:
            n = node_of(g, pane)
            if n is None:
                sys.exit(f"M71: no {pane} pane in the window's geometry")
            bodies[pane] = n["body"]
        shutil.copy(win.geometry, os.path.join(OUT, "base.geometry.json"))
        # The pointer parked over the editor: nothing it hovers changes a
        # pane's scrollbar.
        ex, ey, ew, eh = node_of(g, "editor")["body"]
        ptr.jump(ex + ew // 2, ey + eh // 2)
        steps["base"] = settle("base")
        # The real wheel over the VCS pane's rows (not focused first:
        # CodeTracer-TUI.md §4.4's rule, which the window follows).
        vx, vy, vw, vh = bodies["vcs"]
        before = win.traced("vcs top=")
        ptr.jump(vx + vw // 3, vy + vh // 2)
        ptr.send("wheel 3", "sleep 400")
        window["vcs-wheel"] = wait_trace(win, "vcs top=", before)
        steps["vcs-wheel"] = settle("vcs-wheel")
        # The real wheel over the Files pane's rows.
        fx, fy, fw, fh = bodies["fileTree"]
        before = win.traced("fileTree top=")
        ptr.jump(fx + fw // 3, fy + fh // 2)
        ptr.send("wheel 1", "sleep 400")
        window["files-wheel"] = wait_trace(win, "fileTree top=", before)
        steps["files-wheel"] = settle("files-wheel")
        # A press on the State box's bar, 90% of the way down its track.
        sx, sy, sw, sh = bodies["state"]
        track = sh - STATE_ROWS_TOP_PX
        before = win.traced("state scroll top=")
        ptr.click(sx + sw - STATE_BAR_PX // 2,
                  sy + STATE_ROWS_TOP_PX + int(track * 0.9))
        window["state-press"] = wait_trace(win, "state scroll top=", before)
        steps["state-press"] = settle("state-press")
    finally:
        ptr.close()
        win.close()
    with open(os.path.join(OUT, "capture.json"), "w") as f:
        json.dump({"steps": steps, "window": window, "bodies": bodies}, f,
                  indent=1)
    print("captured:", json.dumps(steps))
    return 0 if all(steps.values()) else 1


def ground_of(frame, x0, x1, y0, y1):
    """The pane's ground: the most common colour in its right-edge strip."""
    counts = {}
    for y in range(y0, y1, 2):
        for x in range(x0, x1):
            c = px(frame, x, y)
            counts[c] = counts.get(c, 0) + 1
    return max(counts, key=counts.get)


def drawn(c, ground):
    return max(abs(a - b) for a, b in zip(c, ground)) > CONTRAST


def thumb_in(frame, body, top_px=0):
    """The scrollbar's thumb in the right-edge strip of a pane body
    `[x, y, w, h]`, from `top_px` below its top: the column holding the
    longest vertical run of pixels set apart from the ground and alike one
    another (a glyph is short and many-coloured; the thumb is a long
    single-colour rectangle) that the `MIN_THUMB_COLS - 1` columns to its
    right repeat exactly. A run from the strip's top to its foot is a line
    the pane is framed in, never a thumb (a thumb as long as its track is
    not drawn: the rows would fit). `x` is the thumb's leftmost column.
    {x, first, last, fromRight} or None."""
    bx, by, bw, bh = body
    x0, x1 = bx + bw - EDGE_PX, bx + bw
    y0, y1 = by + top_px, by + bh
    ground = ground_of(frame, x0, x1, y0, y1)
    by_col = {}
    for x in range(x0, x1):
        runs, run = [], None
        for y in range(y0, y1):
            c = px(frame, x, y)
            if not drawn(c, ground):
                run = None
            elif run and max(abs(a - b) for a, b in zip(c, run[2])) <= 6:
                run[1] = y
            else:
                run = [y, y, c]
                runs.append(run)
        by_col[x] = {(first, last) for first, last, _c in runs
                     if not (first == y0 and last == y1 - 1)}
    def match(x, first, last):
        """Column `x`'s run that is this one's, give or take a rounded
        corner (`rounded: 3px` shortens a thumb's edge columns)."""
        for f, l in by_col.get(x, ()):
            if abs(f - first) <= CORNER_PX and abs(l - last) <= CORNER_PX:
                return (f, l)
        return None
    best = None
    for x in range(x0, x1):
        for first, last in by_col[x]:
            if match(x - 1, first, last):
                continue        # not the leftmost column of this rectangle
            cols = [(first, last)]
            while match(x + len(cols), first, last):
                cols.append(match(x + len(cols), first, last))
            if len(cols) < MIN_THUMB_COLS:
                continue
            top = min(f for f, _l in cols)
            foot = max(l for _f, l in cols)
            if best is None or foot - top > best[2] - best[1]:
                best = (x, top, foot)
    if best is None or best[2] - best[1] < 6:
        return None
    return {"x": best[0], "first": best[1], "last": best[2],
            "fromRight": bx + bw - best[0]}


def record():
    cap = json.load(open(os.path.join(OUT, "capture.json")))
    bodies = cap["bodies"]
    out = {"_comment": [
        "M71 (codetracer#838) — the GPUI window's State, Files and VCS panes",
        "keep an ordinary scrollbar, moved by a REAL wheel and a REAL press.",
        "Produced by `ci/test/m71-gpui-window.sh` then `python3 ci/test/",
        "m71_gpui_window.py record`; asserted by",
        "src/frontend/gpui/tests/test_m71_gpui_window.nim.",
    ], "frame": [FRAME_W, FRAME_H], "steps": cap["steps"],
        "bodies": bodies, "thumbs": {}, "reportedByWindow": {}}
    for step in ("base", "vcs-wheel", "files-wheel", "state-press"):
        f = read_ppm(os.path.join(OUT, step + ".ppm"))
        out["thumbs"][step] = {
            "vcs": thumb_in(f, bodies["vcs"]),
            "fileTree": thumb_in(f, bodies["fileTree"]),
            "state": thumb_in(f, bodies["state"], STATE_ROWS_TOP_PX),
        }
    for k, line in cap["window"].items():
        m = re.search(r"top=(\d+)", line or "")
        out["reportedByWindow"][k] = {"line": line,
                                      "top": int(m.group(1)) if m else -1}
    with open(RECORD, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("recorded", RECORD)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("capture", "record"):
        sys.exit("usage: m71_gpui_window.py capture|record")
    sys.exit(capture() if sys.argv[1] == "capture" else record())
