#!/usr/bin/env python3
"""PLAT-47 part B — the GPUI window at desktop parity, from a REAL window.

    python3 ci/test/plat47_gpui_window.py capture   # inside a headless sway
    python3 ci/test/plat47_gpui_window.py record    # frames -> committed JSON

`capture` (run by `ci/test/plat47-gpui-window.sh`, which starts the headless
sway) opens the windowed `codetracer-gpui` and drives it the way a user does:
a REAL pointer — a virtual pointer DEVICE on the compositor's own seat
(isonim-gpui's `build/virtual-pointer`, `zwlr_virtual_pointer_v1`), so every
press, motion, release and wheel turn reaches the window through the
compositor's routing — and a REAL key (`wtype`, the compositor's virtual
keyboard). After every step it waits for the window to SETTLE (two identical
`grim` grabs) and keeps the frame:

  session A — `calc`, Debug mode, run from a git repository holding a
  modified, an added and an untracked file (`scripts/plat47-vcs-fixture.sh`):
    base            the first screen (editor colours, focus border, tabs)
    resize-live     a divider pressed and dragged 80 px, the button HELD
    resize-done     ... released
    press-body      a press and release inside the editor's body (no divider)
    drop-base       the arrangement before a tab drag
    drop-split      the Variables tab dragged over the editor's right edge
    drop-whole      ... over the editor's centre
    drop-slot       ... over the Call Trace stack's second tab
    drop-dock       ... over the window's left margin
    drop-cancel     Esc pressed, the button still held
    drop-released   the button released after the cancel
    drop-commit     a second drag, released over the editor's right edge
    vcs             a click on the VCS tab of the Files stack
    vcs-refresh     a new untracked file written into the repository by
                    another program, then the pane's refresh interval waited
                    out: the pane lists it without any input
    dock-committed  the Variables tab dragged to the window's left margin
                    and RELEASED: docked, it is a label in the left strip
    dock-revealed   the pointer resting on that label: the pane drawn over
                    the tree (a click would dock it open)
    dock-dismissed  Esc: the tree exactly as before the reveal
  session B — `call_pages` (603 calls):
    pages-base      the first screen
    pages-end       the wheel turned over the call trace until it stops moving

The window writes its geometry (`CODETRACER_GPUI_GEOMETRY_OUT`) so this
script can AIM — which tab to press, where a divider is. Every VERDICT the
record carries is read from the frames' pixels (and OCR, and the layout
document the window saved), never from that file: the regions a drop tinted
are the pixels that CHANGED, compared with the editor's own box found by its
focus ring.

`record` measures the frames and writes
`src/tests/visual/plat47-gpui-window.json`, which
`src/frontend/gpui/tests/test_plat47_gpui_window.nim` asserts over — the
measure-locally-commit-the-measurement arrangement PLAT-40/41/44/45 use,
because a compositor is not a CI dependency.

Prerequisites are refused BY NAME, never skipped.
"""

from collections import Counter
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WS = os.path.dirname(ROOT)
ISONIM_GPUI = os.environ.get("ISONIM_GPUI_DIR", os.path.join(WS, "isonim-gpui"))
OUT = os.path.join(ROOT, "build", "plat47-gpui")
BIN = os.environ.get("CODETRACER_PLAT47_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-gpui-window"))
CALC = os.path.join(ROOT, "test-logs", "tui-fixtures", "calc-2f0db4f45192")
PAGES = os.path.join(ROOT, "test-logs", "tui-fixtures", "call_pages-d6745afd1e2e")
VPOINTER = os.path.join(ISONIM_GPUI, "build", "virtual-pointer")
RECORD = os.path.join(ROOT, "src", "tests", "visual", "plat47-gpui-window.json")
FRAME_W, FRAME_H = 1920, 1080
POLL_S = 0.7
SETTLE_MAX_S = 150

# The colours the record classifies pixels by: the chrome's and the
# generated editor theme's (Dark). Read here from the same sources the
# window paints from would make the record agree with the code by
# construction, so they are the DESKTOP's measured values instead
# (`src/tests/visual/answers/plat47-desktop-parity.electron.json`), loaded
# in `record`.
FOCUS_RING = (0x56, 0x56, 0x56)


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

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
    """Two consecutive identical, non-blank grabs; kept as `<name>.ppm`."""
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


# ---------------------------------------------------------------------------
# The window and the input devices
# ---------------------------------------------------------------------------

class Window:
    def __init__(self, sid, trace, cwd, extra_env=None):
        self.sid = sid
        self.state = os.path.join(OUT, sid + "-state")
        os.makedirs(self.state, exist_ok=True)
        self.geometry = os.path.join(OUT, sid + ".geometry.json")
        env = dict(os.environ)
        env.update({
            "CODETRACER_TUI_LAYOUT_DIR": self.state,
            "CODETRACER_GPUI_GEOMETRY_OUT": self.geometry,
            "CODETRACER_GPUI_GESTURE_TRACE": "1",
        })
        env.update(extra_env or {})
        self.log = open(os.path.join(OUT, sid + ".run.log"), "w")
        self.proc = subprocess.Popen(
            [BIN, "--quit-after-ms=600000", f"--width={FRAME_W}",
             f"--height={FRAME_H}", "--plan-out=" + os.path.join(OUT, sid + ".plan.json"),
             trace],
            cwd=cwd, env=env, stdout=self.log, stderr=subprocess.STDOUT)

    def geom(self):
        with open(self.geometry) as f:
            return json.load(f)

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()


class Pointer:
    """The compositor's own pointer: `virtual-pointer <w> <h>` on stdin."""

    def __init__(self):
        self.proc = subprocess.Popen([VPOINTER, str(FRAME_W), str(FRAME_H)],
                                     stdin=subprocess.PIPE, text=True)

    def send(self, *cmds):
        for c in cmds:
            self.proc.stdin.write(c + "\n")
        self.proc.stdin.flush()

    def move(self, x, y, steps=6, pause_ms=40):
        """Glide to (x, y) in `steps` motions, as a hand does."""
        x0, y0 = getattr(self, "at", (x, y))
        for i in range(1, steps + 1):
            self.send(f"abs {x0 + (x - x0) * i // steps} {y0 + (y - y0) * i // steps}",
                      f"sleep {pause_ms}")
        self.at = (x, y)

    def jump(self, x, y):
        self.send(f"abs {x} {y}", "sleep 120")
        self.at = (x, y)

    def close(self):
        self.send("quit")
        self.proc.stdin.close()
        self.proc.wait(timeout=20)


def key(name):
    # PRIME the virtual keyboard (a new one can lose its first key while the
    # client is still receiving its keymap — PLAT-38's measurement), then
    # the key.
    subprocess.run(["wtype", "-M", "shift", "-m", "shift", "-s", "400",
                    "-k", name], check=True)


def centre(r):
    x, y, w, h = r
    return x + w // 2, y + h // 2


def hover_reveal(win, ptr, rect):
    """Reveal a docked pane the desktop's way (PLAT-49 part B): the pointer
    RESTS on its strip label past the hover-preview delay (300 ms,
    `auto_hide_hover.HoverPreviewDelayMs`), then moves into the overlay,
    which keeps it shown. A click on a label docks the pane open instead.
    Answers the revealed geometry, or None."""
    lx, ly = centre(rect)
    ptr.jump(lx - 2, ly)
    ptr.move(lx, ly, steps=2)
    rv = None
    for _ in range(20):
        time.sleep(0.2)
        rv = win.geom().get("revealed")
        if rv:
            break
    if rv:
        ptr.move(*centre(rv["rect"]), steps=3, pause_ms=20)
        time.sleep(0.4)
    return rv


def node_of(geom, pane):
    for n in geom["nodes"]:
        if n["kind"] == "tabs" and pane in n["panes"]:
            return n
    raise SystemExit(f"PLAT-47: {pane} is not drawn")


# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------

def capture():
    for path, what in ((BIN, "the windowed codetracer-gpui"), (CALC, "the calc recording"),
                       (PAGES, "the call_pages recording"),
                       (VPOINTER, "isonim-gpui's build/virtual-pointer "
                                  "(scripts/build-virtual-pointer.sh)")):
        if not os.path.exists(path):
            sys.exit(f"PLAT-47: refusing to capture — {what} is missing at {path}")
    for tool in ("grim", "wtype"):
        if shutil.which(tool) is None:
            sys.exit(f"PLAT-47: refusing to capture — '{tool}' is not on PATH")
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    repo = os.path.join(OUT, "vcs-repo")
    subprocess.run(["bash", os.path.join(ROOT, "scripts", "plat47-vcs-fixture.sh"), repo],
                   check=True, stdout=subprocess.DEVNULL)
    steps = {}

    # ---------------- session A: calc, from the fixture repository ----------
    win = Window("a", CALC, repo)
    ptr = Pointer()
    try:
        steps["base"] = settle("base")
        shutil.copy(win.geometry, os.path.join(OUT, "a-base.geometry.json"))
        g = win.geom()
        # --- deliverable 5: the divider between Files and the editor.
        div = next(d for d in g["dividers"] if d["container"] == "" and d["index"] == 0)
        dx, dy = centre(div["rect"])
        ptr.jump(dx, dy)
        ptr.send("down", "sleep 150")
        ptr.move(dx + 80, dy)
        steps["resize-live"] = settle("resize-live")
        ptr.send("up", "sleep 200")
        steps["resize-done"] = settle("resize-done")
        g = win.geom()
        eb = node_of(g, "editor")["body"]
        bx, by = centre(eb)
        ptr.jump(bx, by)
        ptr.send("down", "sleep 150")
        ptr.move(bx + 80, by)
        ptr.send("up", "sleep 200")
        steps["press-body"] = settle("press-body")

        # --- deliverable 6: the Variables tab over the four drop kinds.
        steps["drop-base"] = settle("drop-base")
        shutil.copy(win.geometry, os.path.join(OUT, "a-drop.geometry.json"))
        g = win.geom()
        state = node_of(g, "state")
        sx, sy = centre(state["tabs"][0])
        eb = node_of(g, "editor")["body"]
        ct = node_of(g, "calltrace")
        targets = {
            "drop-split": (eb[0] + eb[2] - 4, eb[1] + eb[3] // 2),
            "drop-whole": centre(eb),
            "drop-slot": centre(ct["tabs"][1]),
            "drop-dock": (4, FRAME_H // 2),
        }
        pointers = {}
        ptr.jump(sx, sy)
        ptr.send("down", "sleep 150")
        for name, (tx, ty) in targets.items():
            ptr.move(tx, ty)
            pointers[name] = [tx, ty]
            steps[name] = settle(name)
        key("Escape")
        steps["drop-cancel"] = settle("drop-cancel")
        ptr.send("up", "sleep 200")
        steps["drop-released"] = settle("drop-released")
        # A second drag, released: the split is committed.
        ptr.jump(sx, sy)
        ptr.send("down", "sleep 150")
        tx, ty = targets["drop-split"]
        ptr.move(tx, ty)
        ptr.send("sleep 300", "up", "sleep 300")
        steps["drop-commit"] = settle("drop-commit")
        # --- deliverable 4: a click on the VCS tab.
        g = win.geom()
        files = node_of(g, "vcs")
        vx, vy = centre(files["tabs"][files["panes"].index("vcs")])
        ptr.jump(vx, vy)
        ptr.send("down", "sleep 120", "up", "sleep 300")
        steps["vcs"] = settle("vcs")
        shutil.copy(win.geometry, os.path.join(OUT, "a-final.geometry.json"))
        # --- the VCS pane refreshes on its own, as the desktop's does: a file
        # written by ANOTHER program, no input to the window, one refresh
        # interval (5 s, `vcs_vm.VCSRefreshIntervalMs`) and a margin.
        with open(os.path.join(repo, "late.txt"), "w") as f:
            f.write("written while the window was open\n")
        time.sleep(7.0)
        steps["vcs-refresh"] = settle("vcs-refresh")
        # --- a docked pane stays reachable: dock the Variables pane on the
        # left edge (dragged there and released), click its strip label to
        # reveal it, Esc to hide it again.
        g = win.geom()
        state = node_of(g, "state")
        sx, sy = centre(state["tabs"][state["panes"].index("state")]
                        if state["tabs"] else
                        [state["body"][0], state["body"][1], state["body"][2], 30])
        ptr.jump(sx, sy)
        ptr.send("down", "sleep 150")
        ptr.move(4, FRAME_H // 2)
        ptr.send("sleep 300", "up", "sleep 300")
        steps["dock-committed"] = settle("dock-committed")
        shutil.copy(win.geometry, os.path.join(OUT, "a-dock.geometry.json"))
        g = win.geom()
        # The LEFT strip (since PLAT-48 the shared default's footer is a
        # bottom strip too).
        left = next((st for st in g.get("strips", []) if st["edge"] == "left"), None)
        slot = left["slots"][0]["rect"] if left else None
        if slot is not None:
            # The pointer ends inside the overlay, off the label (whose hover
            # label, PLAT-48, is not the reveal's to compare).
            hover_reveal(win, ptr, slot)
            steps["dock-revealed"] = settle("dock-revealed")
            shutil.copy(win.geometry, os.path.join(OUT, "a-revealed.geometry.json"))
            key("Escape")
            ptr.jump(4, FRAME_H // 2)
            steps["dock-dismissed"] = settle("dock-dismissed")
        else:
            steps["dock-revealed"] = False
            steps["dock-dismissed"] = False
        with open(os.path.join(OUT, "a.pointers.json"), "w") as f:
            json.dump(pointers, f)
    finally:
        ptr.close()
        win.close()

    # ---------------- session B: call_pages, the wheel -----------------------
    win = Window("b", PAGES, OUT)
    ptr = Pointer()
    try:
        steps["pages-base"] = settle("pages-base")
        g = win.geom()
        body = node_of(g, "calltrace")["body"]
        bx, by = centre(body)
        ptr.jump(bx, by)
        # Turn the wheel until the pane stops moving (its last row is then
        # the trace's last call), a burst at a time.
        last = None
        for _ in range(40):
            for _ in range(10):
                ptr.send("wheel 3", "sleep 30")
            ptr.send("sleep 400")
            time.sleep(1.5)
            tops = [l for l in open(os.path.join(OUT, "b.run.log")).read().splitlines()
                    if l.startswith("gesture calltrace top=")]
            top = tops[-1] if tops else None
            if top is not None and top == last:
                break
            last = top
        steps["pages-end"] = settle("pages-end")
    finally:
        ptr.close()
        win.close()

    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(steps, f, indent=1)
    failed = [k for k, v in steps.items() if not v]
    print("plat47-gpui-window: " + ("OK" if not failed else "UNSETTLED " + ",".join(failed)))
    return 0 if not failed else 1


# ---------------------------------------------------------------------------
# record
# ---------------------------------------------------------------------------

def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def near(a, b, tol=6):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def body_top():
    """The first pixel row below the top bar's band (the window's geometry):
    the focus ring is searched only there. Since PLAT-50 the band is the
    window's own ground (#1b1b1b), and the transport icons' antialiased
    edges on it include pixels of exactly the outline colour, which a
    whole-frame search took for the ring."""
    try:
        with open(os.path.join(OUT, "a-base.geometry.json")) as f:
            band = json.load(f)["topBar"]["band"]
        return band[1] + band[3]
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        return 0


def ring_bbox(frame, colour):
    """The bounding box of every pixel of exactly `colour`, below the top
    bar (`body_top`)."""
    w, h, raster = frame
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    top = body_top()
    target = bytes(colour)
    i = raster.find(target, top * w * 3)
    while i >= 0:
        if i % 3 == 0:
            p = i // 3
            x, y = p % w, p // w
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
        i = raster.find(target, i + 1)
    if x1 < 0:
        return None
    return [x0, y0, x1 - x0 + 1, y1 - y0 + 1]


def ring_closed(frame, r, colour):
    """Every pixel of the rectangle's 1px perimeter is `colour`, and the
    pixels one inside it are not (a 1px ring, closed on all four sides)."""
    x, y, w, h = r
    sides = {
        "top": [(i, y) for i in range(x + 4, x + w - 4)],
        "bottom": [(i, y + h - 1) for i in range(x + 4, x + w - 4)],
        "left": [(x, j) for j in range(y + 4, y + h - 4)],
        "right": [(x + w - 1, j) for j in range(y + 4, y + h - 4)],
    }
    inner = {
        "top": [(i, y + 1) for i in range(x + 4, x + w - 4)],
        "bottom": [(i, y + h - 2) for i in range(x + 4, x + w - 4)],
        "left": [(x + 1, j) for j in range(y + 4, y + h - 4)],
        "right": [(x + w - 2, j) for j in range(y + 4, y + h - 4)],
    }
    out = {}
    for s in sides:
        on = sum(1 for p in sides[s] if px(frame, *p) == colour)
        inside = sum(1 for p in inner[s] if px(frame, *p) == colour)
        out[s] = {"ring": on, "of": len(sides[s]), "inside": inside}
    return out


def changed_bbox(a, b, exclude=None):
    w, h, ra = a
    _, _, rb = b
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    count = 0
    for y in range(h):
        row = y * w * 3
        if ra[row:row + w * 3] == rb[row:row + w * 3]:
            continue
        for x in range(w):
            i = row + x * 3
            if ra[i:i + 3] != rb[i:i + 3]:
                if exclude and exclude[0] <= x < exclude[0] + exclude[2] and \
                        exclude[1] <= y < exclude[1] + exclude[3]:
                    continue
                count += 1
                x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
    if x1 < 0:
        return None, 0
    return [x0, y0, x1 - x0 + 1, y1 - y0 + 1], count


def colour_count(frame, rect, colour, tol=6):
    x, y, w, h = rect
    n = 0
    for j in range(y, y + h):
        for i in range(x, x + w):
            if near(px(frame, i, j), colour, tol):
                n += 1
    return n


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def stem_width(frame, rect, fg, bg):
    """The mean horizontal run of INK across a label's rows: ink is a pixel
    past the midpoint between the label's colour and its ground. A bold face
    has wider stems."""
    mid = (lum(fg) + lum(bg)) / 2
    runs = []
    x, y, w, h = rect
    for j in range(y, y + h):
        run = 0
        for i in range(x, x + w):
            if lum(px(frame, i, j)) > mid:
                run += 1
            elif run:
                runs.append(run)
                run = 0
        if run:
            runs.append(run)
    return (sum(runs) / len(runs)) if runs else 0.0, len(runs)


def ocr(path, rect, name):
    x, y, w, h = rect
    frame = read_ppm(path)
    fw, _, raster = frame
    crop = os.path.join(OUT, name + ".crop.ppm")
    with open(crop, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        for j in range(y, y + h):
            f.write(raster[(j * fw + x) * 3:(j * fw + x + w) * 3])
    # Upscaled 2x for the OCR engine, as PLAT-39's reader does.
    big = os.path.join(OUT, name + ".big.ppm")
    subprocess.run(["python3", "-c", f"""
import sys
w,h={w},{h}
d=open({crop!r},'rb').read().split(b'\\n',3)[3]
out=bytearray()
for j in range(h):
    row=bytearray()
    for i in range(w):
        p=d[(j*w+i)*3:(j*w+i)*3+3]
        row+=p+p
    out+=row+row
open({big!r},'wb').write(b'P6\\n%d %d\\n255\\n'%(2*w,2*h)+bytes(out))
"""], check=True)
    res = subprocess.run(["tesseract", big, "-", "--psm", "6"], capture_output=True, text=True)
    return res.stdout


def record():
    manifest = json.load(open(os.path.join(OUT, "manifest.json")))
    desk = json.load(open(os.path.join(ROOT, "src", "tests", "visual", "answers",
                                       "plat47-desktop-parity.electron.json")))
    ed = desk["editor"]
    frames = {k: read_ppm(os.path.join(OUT, k + ".ppm")) for k in manifest if manifest[k]}
    out = {
        "_comment": [
            "PLAT-47 part B — the GPUI window, read from its own pixels.",
            "Captured by `just plat47-gpui-window` (headless sway, a virtual",
            "pointer device, wtype) and measured by `just plat47-gpui-window-record`",
            "(ci/test/plat47_gpui_window.py). Asserted by",
            "src/frontend/gpui/tests/test_plat47_gpui_window.nim.",
        ],
        "frame": [FRAME_W, FRAME_H],
        "settled": manifest,
    }

    # ---- B2 + B1: the first screen ----------------------------------------
    base = frames["base"]
    ring = ring_bbox(base, FOCUS_RING)
    out["focusRing"] = {"bbox": ring, "sides": ring_closed(base, ring, FOCUS_RING) if ring else None}
    # The editor's box is the ring; its body is inside the 1px border.
    body = [ring[0] + 1, ring[1] + 1, ring[2] - 2, ring[3] - 2]
    ground = hexrgb(ed["background"])
    # A glyph's pixels are its colour blended toward the ground by coverage,
    # so a pixel is counted for a class when it lies on the line from the
    # ground to the class's desktop colour, at least 70% of the way along
    # (antialiased edges excluded), within 6 of the line.
    fg_classes = ("keyword", "string", "comment", "identifier", "delimiter",
                  "lineNumber", "activeLineNumber")
    counts = {c: 0 for c in fg_classes}
    others = {"oldBand4f4f4f": 0, "chromePaneFill": 0}
    x, y, w, h = body
    for j in range(y, y + h):
        for i in range(x, x + w):
            p = px(base, i, j)
            if p == ground:
                continue
            if p == (0x4f, 0x4f, 0x4f):
                others["oldBand4f4f4f"] += 1
            if p == (0x1b, 0x22, 0x2c):
                others["chromePaneFill"] += 1
            for cls in fg_classes:
                c = hexrgb(ed[cls])
                v = [c[k] - ground[k] for k in range(3)]
                d = [p[k] - ground[k] for k in range(3)]
                vv = sum(e * e for e in v)
                t = sum(v[k] * d[k] for k in range(3)) / vv
                r = sum((d[k] - t * v[k]) ** 2 for k in range(3)) ** 0.5
                if 0.7 <= t <= 1.05 and r < 6:
                    counts[cls] += 1
    counts["ground"] = colour_count(base, body, ground, tol=0)
    counts.update(others)
    out["editor"] = {"body": body, "pixelsByDesktopColour": counts,
                     "desktop": {k: ed[k] for k in ed}}
    # The execution band: the rows carrying the band colour, where on the
    # row it starts and ends, and where the gutter's line numbers end on the
    # same rows. Monaco's band runs from the code column to the editor's
    # right edge and is not under the line numbers.
    band = hexrgb(ed["executionLine"])
    active_no = hexrgb(ed["activeLineNumber"])
    rows = []
    for y in range(body[1], body[1] + body[3]):
        n = sum(1 for x in range(body[0], body[0] + body[2]) if px(base, x, y) == band)
        if n > body[2] // 3:
            rows.append(y)
    out["band"] = {"rows": [rows[0], rows[-1]] if rows else None}
    if rows:
        y = (rows[0] + rows[-1]) // 2
        xs = [x for x in range(body[0], body[0] + body[2]) if px(base, x, y) == band]
        numbers = [x for x in range(body[0], body[0] + body[2])
                   for yy in range(rows[0], rows[-1] + 1)
                   if near(px(base, x, yy), active_no, 24)]
        out["band"].update({
            "startX": xs[0], "endX": xs[-1],
            "activeNumberMaxX": max(numbers) if numbers else None,
            # The gutter's GROUND on the band's row: its most common colour
            # left of the band (PLAT-51 draws the desktop's arrow mark in the
            # gutter's first cell, so a single sampled pixel there is the mark).
            "gutterAtBandRow": "#%02x%02x%02x" % Counter(
                px(base, x, y) for x in range(body[0], xs[0])).most_common(1)[0][0],
            "afterBandAtRow": "#%02x%02x%02x" % px(base, xs[-1] + 1, y),
            "bodyLeft": body[0], "bodyRight": body[0] + body[2] - 1,
        })

    # Tabs: the SAME label drawn active and inactive — the Files stack's
    # "Files" and "VCS", before and after the click that activates VCS (the
    # `vcs` frame) — so a weight difference is not a difference of letters.
    # Ink mass: every pixel's share of the way from the strip's ground to the
    # label's own brightest pixel, summed; a bold face lays down more ink.
    ga = json.load(open(os.path.join(OUT, "a-base.geometry.json")))
    stack = next(n for n in ga["nodes"] if n["kind"] == "tabs" and "vcs" in n["panes"])
    vcs_frame = frames["vcs"]

    def ink(frame, rect):
        x, y, w, h = rect
        hist = {}
        bright = (0, 0, 0)
        for j in range(y, y + h):
            for i in range(x, x + w):
                c = px(frame, i, j)
                hist[c] = hist.get(c, 0) + 1
                if lum(c) > lum(bright):
                    bright = c
        ground_c = max(hist, key=hist.get)
        lb, lf = lum(ground_c), lum(bright)
        mass = 0.0
        for j in range(y, y + h):
            for i in range(x, x + w):
                if lf > lb:
                    mass += max(0.0, min(1.0, (lum(px(frame, i, j)) - lb) / (lf - lb)))
        return {"mass": round(mass, 1), "ink": "#%02x%02x%02x" % bright,
                "ground": "#%02x%02x%02x" % ground_c}

    tabs = {}
    for pane in ("fileTree", "vcs"):
        r = stack["tabs"][stack["panes"].index(pane)]
        tabs[pane] = {"rect": r, "base": ink(base, r), "vcs": ink(vcs_frame, r)}
    out["tabs"] = tabs

    # ---- deliverable 5: the divider --------------------------------------
    def left_of_ring(frame):
        r = ring_bbox(frame, FOCUS_RING)
        return r[0] if r else None
    out["resize"] = {
        "baseRingLeft": left_of_ring(base),
        "liveRingLeft": left_of_ring(frames["resize-live"]),
        "doneRingLeft": left_of_ring(frames["resize-done"]),
        "pressBodyRingLeft": left_of_ring(frames["press-body"]),
        "pressBodyChanged": changed_bbox(frames["resize-done"], frames["press-body"])[1],
        # PLAT-51: a press on the read-only editor's text places its CARET —
        # what changed, as a box (a caret is a bar one cell wide).
        "pressBodyChangedBox": changed_bbox(frames["resize-done"], frames["press-body"])[0],
    }
    saved = os.path.join(OUT, "a-state", "gpui-layout.json")
    out["resize"]["savedLayout"] = json.load(open(saved)) if os.path.exists(saved) else None

    # ---- deliverable 6: the drop indication -------------------------------
    pointers = json.load(open(os.path.join(OUT, "a.pointers.json")))
    db = frames["drop-base"]
    dring = ring_bbox(db, FOCUS_RING)
    dbody = [dring[0] + 1, dring[1] + 1, dring[2] - 2, dring[3] - 2]
    drops = {"editorBody": dbody, "pointers": pointers}
    action = None
    for name in ("drop-split", "drop-whole", "drop-slot", "drop-dock"):
        f = frames[name]
        px_, py_ = pointers[name]
        # The ghost label: drawn at the pointer + 12, excluded from the tint.
        ghost = [px_ + 12, py_ + 12, 160, 32]
        bbox, count = changed_bbox(db, f, exclude=ghost)
        ghost_changed = changed_bbox(db, f)[1] - count
        drops[name] = {"tintBBox": bbox, "changedPixels": count,
                       "ghostChangedPixels": ghost_changed,
                       "ghostCentre": list(px(f, px_ + 60, py_ + 12 + 15))}
    drops["cancelChangedPixels"] = changed_bbox(db, frames["drop-cancel"])[1]
    drops["releasedChangedPixels"] = changed_bbox(db, frames["drop-released"])[1]
    cring = ring_bbox(frames["drop-commit"], FOCUS_RING)
    drops["commitRing"] = cring
    gf = json.load(open(os.path.join(OUT, "a-final.geometry.json")))
    # The committed arrangement, read from the pixels: the editor's box and
    # whatever now sits to its right in its old extent.
    drops["commitArrangement"] = [{"panes": n["panes"], "rect": n["rect"]}
                                  for n in gf["nodes"] if n["kind"] == "tabs"]
    out["drop"] = drops

    # ---- deliverable 4: the VCS pane, OCR'd --------------------------------
    files = next(n for n in gf["nodes"] if n["kind"] == "tabs" and "vcs" in n["panes"])
    out["vcs"] = {"text": ocr(os.path.join(OUT, "vcs.ppm"), files["body"], "vcs"),
                  "active": files["panes"][files["active"]]}

    # ---- deliverable 4: the pane refreshed itself --------------------------
    log_a = open(os.path.join(OUT, "a.run.log")).read().splitlines()
    out["vcsRefresh"] = {
        "text": ocr(os.path.join(OUT, "vcs-refresh.ppm"), files["body"], "vcs-refresh"),
        "refreshes": sum(1 for l in log_a if l == "gesture vcs refreshed"),
        "changedPixels": changed_bbox(frames["vcs"], frames["vcs-refresh"])[1],
        "changedBBox": changed_bbox(frames["vcs"], frames["vcs-refresh"])[0],
        "paneBody": files["body"],
    }

    # ---- a docked pane: its strip, its reveal, Esc ------------------------
    gd = json.load(open(os.path.join(OUT, "a-dock.geometry.json")))
    dock = {"strips": gd.get("strips", []),
            "treePanes": sorted(p for n in gd["nodes"] if n["kind"] == "tabs"
                                for p in n["panes"])}
    left = next((st for st in gd.get("strips", []) if st["edge"] == "left"), None)
    if left:
        st = left
        sr = st["rect"]
        fc = frames["dock-committed"]
        # The strip is drawn: its label's ink on the strip's ground.
        hist = {}
        for j in range(sr[1], sr[1] + sr[3]):
            for i in range(sr[0], sr[0] + sr[2]):
                c = px(fc, i, j)
                hist[c] = hist.get(c, 0) + 1
        ground_c = max(hist, key=hist.get)
        dock["stripGround"] = "#%02x%02x%02x" % ground_c
        dock["stripInk"] = sum(v for c, v in hist.items()
                               if abs(lum(c) - lum(ground_c)) > 40)
        # The left strip's label, one character per row, read row by row.
        sl = st["slots"][0]["rect"]
        dock["slotText"] = ocr(os.path.join(OUT, "dock-committed.ppm"),
                               [sl[0] - 4, sl[1], sl[2] + 8, sl[3]], "dock-slot")
        saved = os.path.join(OUT, "a-state", "gpui-layout.json")
        dock["savedLayout"] = json.load(open(saved)) if os.path.exists(saved) else None
    if frames.get("dock-revealed") is not None:
        gr = json.load(open(os.path.join(OUT, "a-revealed.geometry.json")))
        rr = gr["revealed"]["rect"] if gr.get("revealed") else None
        dock["revealed"] = gr.get("revealed")
        dock["revealChangedBBox"], dock["revealChangedPixels"] = changed_bbox(
            frames["dock-committed"], frames["dock-revealed"])
        if rr:
            dock["revealText"] = ocr(os.path.join(OUT, "dock-revealed.ppm"),
                                     [rr[0], rr[1], rr[2], min(rr[3], 120)], "dock-reveal")
    if frames.get("dock-dismissed") is not None:
        dock["dismissChangedPixels"] = changed_bbox(
            frames["dock-committed"], frames["dock-dismissed"])[1]
    out["dock"] = dock

    # ---- the editor's rows are full lines: OCR of the first rows -----------
    out["editor"]["text"] = ocr(os.path.join(OUT, "base.ppm"),
                                [body[0], body[1], body[2], min(body[3], 200)],
                                "editor-top")

    # ---- B3: the call trace scrolled to its end ---------------------------
    gb = json.load(open(os.path.join(OUT, "b.geometry.json")))
    ctn = next(n for n in gb["nodes"] if n["kind"] == "tabs" and "calltrace" in n["panes"])
    log = open(os.path.join(OUT, "b.run.log")).read().splitlines()
    loads = [l for l in log if l.startswith("gesture calltrace-section ")]
    tops = [l for l in log if l.startswith("gesture calltrace top=")]
    out["calltrace"] = {
        "baseText": ocr(os.path.join(OUT, "pages-base.ppm"), ctn["body"], "pages-base"),
        "endText": ocr(os.path.join(OUT, "pages-end.ppm"), ctn["body"], "pages-end"),
        "sectionLoads": len(loads) + 1,
        "lastTop": tops[-1] if tops else "",
    }
    with open(RECORD, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("wrote " + RECORD)
    return 0


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "capture":
        sys.exit(capture())
    if mode == "record":
        sys.exit(record())
    sys.exit("usage: plat47_gpui_window.py capture|record")
