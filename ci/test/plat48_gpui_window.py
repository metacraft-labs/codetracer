#!/usr/bin/env python3
"""PLAT-48 — the top bar and the auto-hide panels in a REAL GPUI window.

    python3 ci/test/plat48_gpui_window.py capture   # inside a headless sway
    python3 ci/test/plat48_gpui_window.py record    # frames -> committed JSON

`capture` (run by `ci/test/plat48-gpui-window.sh`, which starts the headless
sway) opens the windowed `codetracer-gpui` on `calc` and drives it as a user
does — a REAL pointer (isonim-gpui's `build/virtual-pointer`, a
`zwlr_virtual_pointer_v1` device on the compositor's seat) and REAL keys
(`wtype`, the compositor's virtual keyboard) — keeping a settled frame
(two identical `grim` grabs) after every step:

  base            the first screen: the top bar (the menu's ONE root button
                  — PLAT-49 — the desktop's debugger marks, the omnibar), the
                  footer strip
  menu-root       a click on the root button: the first level's popover
  menu-open       a click on its Debug row: Debug's popover, beside it
  menu-hover      the pointer over Step In: the highlight moves to it
  menu-key        `Down`: the highlight moves on (the keyboard's route)
  menu-choose     a click on Step Over: the debugger moves, the popover goes
  ctl-<id>        a click on each debugger control
  hover-control   the pointer resting on the Next control: its tooltip + key
  omni-tick       `Ctrl+P`, `#42`, `Enter`: the debugger at tick 42
  omni-sym        `Ctrl+P`, `:sym add`: the results
  reveal-base     (after `Esc`) the arrangement before a reveal
  reveal-bottom   the pointer resting on the BUILD label: the pane over the
                  tree (PLAT-49: a click docks it open instead)
  reveal-esc      `Esc`: every pixel as before
  key-reveal      `Ctrl+O`: the first footer pane revealed by key
  hover-slot      the pointer on a strip label: its hover label
  pinned          a click on the State stack's pin button: docked
  unpinned        its label hovered, then Unpin: placed again
  top-docked      the Variables tab dragged to the margin above the layout
                  and released: a TOP strip
  top-revealed    the pointer resting on the top label: the pane over the
                  tree, from the
                  top
  top-esc         `Esc`: every pixel as before
  top-back        the top label dragged back into the tree: placed
  session B, a layout document with a TOP-docked pane WRITTEN BY THE
  TERMINAL — `codetracer-tui` on `calc` in a pty, `1` (its call-trace pane),
  `:dock top`, `q`; its own layout store saves the document — opened with
  `--layout`:
  doc-top         the window opens with that pane in its top strip

The window writes its geometry (`CODETRACER_GPUI_GEOMETRY_OUT`), which this
script reads to AIM. The verdicts `record` writes are read from the frames'
pixels and OCR; what only the window can report (the tick its session is at,
the ViewModel's highlight index, which stack a placed pane joined) is carried
under `reportedByWindow`, labelled as such, beside the pixel evidence for the
same step.

`record` writes `src/tests/visual/plat48-gpui-window.json`, asserted by
`src/frontend/gpui/tests/test_plat48_gpui_window.nim` — the
measure-locally-commit-the-measurement arrangement PLAT-40..47 use.
Prerequisites are refused BY NAME, never skipped.
"""

import fcntl
import json
import os
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WS = os.path.dirname(ROOT)
ISONIM_GPUI = os.environ.get("ISONIM_GPUI_DIR", os.path.join(WS, "isonim-gpui"))
OUT = os.path.join(ROOT, "build", "plat48-gpui")
BIN = os.environ.get("CODETRACER_PLAT48_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-gpui-window"))
CALC = os.path.join(ROOT, "test-logs", "tui-fixtures", "calc-2f0db4f45192")
VPOINTER = os.path.join(ISONIM_GPUI, "build", "virtual-pointer")
TUI = os.environ.get("CODETRACER_TUI_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-tui"))
RECORD = os.path.join(ROOT, "src", "tests", "visual", "plat48-gpui-window.json")
FRAME_W, FRAME_H = 1920, 1080
POLL_S = 0.7
SETTLE_MAX_S = 150
CONTROLS = ["reverse-next", "next", "reverse-step-in", "step-in",
            "reverse-step-out", "step-out", "reverse-continue", "continue",
            "run-to-entry"]


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
    def __init__(self, sid, trace, extra=None):
        self.sid = sid
        self.state = os.path.join(OUT, sid + "-state")
        os.makedirs(self.state, exist_ok=True)
        self.geometry = os.path.join(OUT, sid + ".geometry.json")
        env = dict(os.environ)
        env.update({
            "XDG_STATE_HOME": self.state,
            "CODETRACER_TUI_LAYOUT_DIR": self.state,
            "CODETRACER_GPUI_GEOMETRY_OUT": self.geometry,
            "CODETRACER_GPUI_GESTURE_TRACE": "1",
        })
        self.log = open(os.path.join(OUT, sid + ".run.log"), "w")
        self.proc = subprocess.Popen(
            [BIN, "--quit-after-ms=900000", f"--width={FRAME_W}",
             f"--height={FRAME_H}"] + (extra or []) + [trace],
            cwd=OUT, env=env, stdout=self.log, stderr=subprocess.STDOUT)

    def geom(self):
        for _ in range(20):
            try:
                with open(self.geometry) as f:
                    return json.load(f)
            except (OSError, ValueError):
                time.sleep(0.3)
        raise SystemExit("PLAT-48: the window wrote no geometry")

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

    def move(self, x, y, steps=6, pause_ms=40):
        x0, y0 = getattr(self, "at", (x, y))
        for i in range(1, steps + 1):
            self.send(f"abs {x0 + (x - x0) * i // steps} {y0 + (y - y0) * i // steps}",
                      f"sleep {pause_ms}")
        self.at = (x, y)

    def jump(self, x, y):
        self.send(f"abs {x} {y}", "sleep 120")
        self.at = (x, y)

    def click(self, x, y):
        self.jump(x, y)
        self.send("down", "sleep 120", "up", "sleep 300")

    def close(self):
        self.send("quit")
        self.proc.stdin.close()
        self.proc.wait(timeout=20)


def wt(*args):
    # PRIME the virtual keyboard first (a new one can lose its first key while
    # the client is still receiving its keymap — PLAT-38's measurement).
    subprocess.run(["wtype", "-M", "shift", "-m", "shift", "-s", "400"] + list(args),
                   check=True)


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


def seg(g, part, label=None):
    for s in g["topBar"]["segs"]:
        if s["part"] == part and (label is None or s["label"] == label):
            return s
    raise SystemExit(f"PLAT-48: no top-bar {part} {label or ''} in the geometry")


def node_of(g, pane):
    for n in g["nodes"]:
        if n["kind"] == "tabs" and pane in n["panes"]:
            return n
    return None


def wait_tick(win, pred, timeout=240):
    end = time.time() + timeout
    t = None
    while time.time() < end:
        t = win.geom()["topBar"].get("tick")
        if t is not None and pred(t):
            return t
        time.sleep(0.5)
    return t


def wait_geom(win, pred, timeout=15.0):
    """Poll the window's geometry until `pred(topBar)` holds; the last
    `topBar` read either way."""
    end = time.time() + timeout
    tb = {}
    while time.time() < end:
        tb = win.geom()["topBar"]
        if pred(tb):
            return tb
        time.sleep(0.3)
    return tb


def omnibar_query(win, text, attempts=3):
    """Ctrl+P, then `text`, until the window's omnibar holds exactly `text`.

    A fresh virtual keyboard (`wtype`) uploads its own keymap, and a burst
    typed while the client is still taking it can be lost whole — seen once
    on a loaded host, after the first query of the session had gone through.
    What was lost is the INPUT, not the window's answer to it, so the
    attempt is repeated (Esc, Ctrl+P, retype) and the number it took is
    recorded beside the verdict rather than hidden."""
    for attempt in range(1, attempts + 1):
        wt("-M", "ctrl", "-k", "p", "-m", "ctrl")
        wait_geom(win, lambda tb: tb.get("omnibarOpen"), 10.0)
        wt(text)
        tb = wait_geom(win, lambda tb: tb.get("query") == text, 15.0)
        if tb.get("query") == text:
            return attempt
        wt("-k", "Escape")
        time.sleep(0.5)
    return 0


def terminal_top_docked_document():
    """`codetracer-tui` on `calc` in a pseudo-terminal: `1` focuses its call
    trace, `:dock top` docks it to the top edge, `q` quits. The terminal's
    own layout store writes the document (`tui-layout.json` under
    `CODETRACER_TUI_LAYOUT_DIR`); its path is returned."""
    store = os.path.join(OUT, "tui-layout")
    os.makedirs(store, exist_ok=True)
    doc = os.path.join(store, "tui-layout.json")
    env = {k: v for k, v in os.environ.items()
           if k not in ("TMUX", "STY", "TERM_PROGRAM", "NO_COLOR", "NERD_FONT")}
    env.update({"TERM": "xterm-256color", "COLORTERM": "truecolor",
                "LANG": "en_US.UTF-8", "XDG_STATE_HOME": store,
                "CODETRACER_TUI_LAYOUT_DIR": store})
    log = open(os.path.join(OUT, "tui.transcript"), "wb")
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execve(TUI, [TUI, CALC], env)
        finally:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))

    def pump(seconds):
        end = time.time() + seconds
        got = b""
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                got += chunk
                log.write(chunk)
        return got

    def settle(limit):
        # Quiet for 3 s after it has drawn a status line with the tick.
        seen = b""
        end = time.time() + limit
        quiet = 0.0
        while time.time() < end:
            chunk = pump(1.0)
            seen += chunk
            quiet = 0.0 if chunk else quiet + 1.0
            if b"tick" in seen and quiet >= 3.0:
                return True
        return False

    try:
        if not settle(240):
            sys.exit("PLAT-48: the terminal never settled on calc (see tui.transcript)")
        for keys in (b"1", b":dock top\r"):
            os.write(fd, keys)
            pump(2.0)
        end = time.time() + 60
        while time.time() < end:
            if os.path.exists(doc) and '"top"' in open(doc).read():
                break
            pump(0.5)
        else:
            sys.exit("PLAT-48: the terminal saved no top-docked layout at " + doc)
        os.write(fd, b"q")
        pump(3.0)
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        log.close()
    shutil.copy(doc, os.path.join(OUT, "top-docked-layout.json"))
    return os.path.join(OUT, "top-docked-layout.json")


def capture():
    for path, what in ((BIN, "the windowed codetracer-gpui"), (CALC, "the calc recording"),
                       (TUI, "the terminal front-end (just build-tui)"),
                       (VPOINTER, "isonim-gpui's build/virtual-pointer")):
        if not os.path.exists(path):
            sys.exit(f"PLAT-48: refusing to capture — {what} is missing at {path}")
    for tool in ("grim", "wtype"):
        if shutil.which(tool) is None:
            sys.exit(f"PLAT-48: refusing to capture — '{tool}' is not on PATH")
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    steps = {}
    facts = {"ticks": {}}

    win = Window("a", CALC)
    ptr = Pointer()
    try:
        steps["base"] = settle("base")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "a-base.geometry.json"))
        facts["ticks"]["base"] = g["topBar"]["tick"]
        # ---- the menu: click, hover, key, choose ------------------------
        # PLAT-49: the desktop's menu — one root button, its first level a
        # popover, a folder's items a popover beside it.
        ptr.click(*centre(seg(g, "menu")["rect"]))
        steps["menu-root"] = settle("menu-root")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "a-menu-root.geometry.json"))
        first = {r["label"]: r for r in g["topBar"]["popovers"][0]["rows"]}
        ptr.click(*centre(first["Debug"]["rect"]))
        steps["menu-open"] = settle("menu-open")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "a-menu.geometry.json"))
        pop = g["topBar"]["popovers"][1]
        rows = {r["label"]: r for r in pop["rows"]}
        ptr.move(*centre(rows["Step In"]["rect"]))
        steps["menu-hover"] = settle("menu-hover")
        facts["menuHover"] = win.geom()["topBar"]["highlight"]
        wt("-k", "Down")
        steps["menu-key"] = settle("menu-key")
        facts["menuKey"] = win.geom()["topBar"]["highlight"]
        before = win.geom()["topBar"]["tick"]
        ptr.click(*centre(rows["Step Over"]["rect"]))
        facts["ticks"]["menu-choose"] = wait_tick(win, lambda t: t != before)
        steps["menu-choose"] = settle("menu-choose")
        facts["menuClosed"] = not win.geom()["topBar"]["menuOpen"]
        # ---- every debugger control -----------------------------------------
        # An order in which every control has somewhere to go: forward and
        # back inside the program first, then to the entry, the end, and back.
        order = ["next", "step-in", "next", "reverse-next", "reverse-step-in",
                 "step-out", "reverse-step-out", "run-to-entry", "continue",
                 "reverse-continue"]
        facts["controls"] = []
        for i, cid in enumerate(order):
            g = win.geom()
            before = g["topBar"]["tick"]
            ptr.click(*centre(seg(g, "control", cid)["rect"]))
            after = wait_tick(win, lambda t: t != before, timeout=240)
            facts["controls"].append({"id": cid, "before": before, "after": after})
        steps["ctl-last"] = settle("ctl-last")
        # ---- hover on a control ---------------------------------------------
        g = win.geom()
        nx, ny = centre(seg(g, "control", "next")["rect"])
        ptr.jump(nx, ny)
        ptr.move(nx + 2, ny + 1, steps=2)
        steps["hover-control"] = settle("hover-control")
        shutil.copy(win.geometry, os.path.join(OUT, "a-hover.geometry.json"))
        # ---- the omnibar ------------------------------------------------------
        ptr.jump(FRAME_W // 2, FRAME_H // 2 + 200)
        facts["omnibarAttempts"] = {"#42": omnibar_query(win, "#42")}
        steps["omni-typed"] = settle("omni-typed")
        wt("-k", "Return")
        facts["ticks"]["omni-tick"] = wait_tick(win, lambda t: t == 42)
        steps["omni-tick"] = settle("omni-tick")
        facts["omnibarAttempts"][":sym add"] = omnibar_query(win, ":sym add")
        steps["omni-sym"] = settle("omni-sym")
        shutil.copy(win.geometry, os.path.join(OUT, "a-omni.geometry.json"))
        wt("-k", "Escape")
        # ---- the footer: click reveal, Esc, key reveal, hover label -------
        # The pointer rests in the window's corner padding between steps, so
        # no hover label is in a frame a reveal is compared with.
        ptr.jump(FRAME_W - 6, 4)
        steps["reveal-base"] = settle("reveal-base")
        g = win.geom()
        bottom = next(s for s in g["strips"] if s["edge"] == "bottom")
        build = next(s for s in bottom["slots"] if s["pane"] == "buildOutput")
        hover_reveal(win, ptr, build["rect"])
        steps["reveal-bottom"] = settle("reveal-bottom")
        shutil.copy(win.geometry, os.path.join(OUT, "a-reveal.geometry.json"))
        wt("-k", "Escape")
        ptr.jump(FRAME_W - 6, 4)
        steps["reveal-esc"] = settle("reveal-esc")
        wt("-M", "ctrl", "-k", "o", "-m", "ctrl")
        steps["key-reveal"] = settle("key-reveal")
        shutil.copy(win.geometry, os.path.join(OUT, "a-keyreveal.geometry.json"))
        wt("-k", "Escape")
        g = win.geom()
        probs = next(s for s in bottom["slots"] if s["pane"] == "problems")
        px_, py_ = centre(probs["rect"])
        ptr.jump(px_ - 4, py_)
        ptr.move(px_, py_, steps=2)
        steps["hover-slot"] = settle("hover-slot")
        ptr.jump(FRAME_W // 2, 300)
        # Off the label, the preview it opened is dismissed after its delay.
        time.sleep(0.8)
        # ---- pin / unpin ------------------------------------------------------
        g = win.geom()
        state = node_of(g, "state")
        pin = [state["rect"][0] + state["rect"][2] - 26, state["strip"][1] + 3, 24, 24]
        ptr.click(*centre(pin))
        steps["pinned"] = settle("pinned")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "a-pinned.geometry.json"))
        bottom = next(s for s in g["strips"] if s["edge"] == "bottom")
        st = next((s for s in bottom["slots"] if s["pane"] == "state"), None)
        facts["pinnedDocked"] = st is not None
        if st is not None:
            rv = hover_reveal(win, ptr, st["rect"])
            if rv:
                rr = rv["rect"]
                ptr.click(rr[0] + rr[2] - 40, rr[1] + 15)
        steps["unpinned"] = settle("unpinned")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "a-unpinned.geometry.json"))
        facts["unpinnedPlaced"] = node_of(g, "state") is not None
        # WHERE it went: the stack it was pinned from (`DockedPane.beside`).
        un = node_of(g, "state")
        facts["unpinnedStack"] = un["panes"] if un else []
        # ---- the TOP edge: drag there, reveal, Esc, drag back ---------------
        steps["top-base"] = settle("top-base")
        g = win.geom()
        state = node_of(g, "state")
        if state["tabs"]:
            sx, sy = centre(state["tabs"][state["panes"].index("state")])
        else:
            # A bare pane: its heading row is its one tab (`tabAt`).
            sx, sy = state["body"][0] + 40, state["body"][1] + 12
        area = g["area"]
        ptr.jump(sx, sy)
        ptr.send("down", "sleep 150")
        ptr.move(FRAME_W // 2, area[1] - 3)
        ptr.send("sleep 300", "up", "sleep 400")
        ptr.jump(FRAME_W - 6, 4)
        steps["top-docked"] = settle("top-docked")
        g = win.geom()
        shutil.copy(win.geometry, os.path.join(OUT, "a-top.geometry.json"))
        top = next((s for s in g["strips"] if s["edge"] == "top"), None)
        facts["topDocked"] = top is not None and any(s["pane"] == "state" for s in top["slots"])
        if top is not None:
            lbl = top["slots"][0]["rect"]
            hover_reveal(win, ptr, lbl)
            steps["top-revealed"] = settle("top-revealed")
            shutil.copy(win.geometry, os.path.join(OUT, "a-toprev.geometry.json"))
            wt("-k", "Escape")
            ptr.jump(FRAME_W - 6, 4)
            steps["top-esc"] = settle("top-esc")
            g = win.geom()
            ed = node_of(g, "editor")
            lx, ly = centre(lbl)
            ptr.jump(lx, ly)
            ptr.send("down", "sleep 150")
            ptr.move(ed["body"][0] + ed["body"][2] - 6, ed["body"][1] + ed["body"][3] // 2)
            ptr.send("sleep 300", "up", "sleep 400")
            steps["top-back"] = settle("top-back")
            g = win.geom()
            facts["topBackPlaced"] = node_of(g, "state") is not None and \
                not any(s["edge"] == "top" for s in g["strips"])
    finally:
        ptr.close()
        win.close()

    # ---- session B: a layout document with a TOP-docked pane ---------------
    # Written by the TERMINAL, not by this script: the spec's case is "a
    # layout the terminal saved opens in GPUI".
    docpath = terminal_top_docked_document()
    win = Window("b", CALC, extra=["--layout=" + docpath])
    try:
        steps["doc-top"] = settle("doc-top")
    finally:
        win.close()

    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(steps, f, indent=1)
    with open(os.path.join(OUT, "facts.json"), "w") as f:
        json.dump(facts, f, indent=1)
    failed = [k for k, v in steps.items() if not v]
    print("plat48-gpui-window: " + ("OK" if not failed else "UNSETTLED " + ",".join(failed)))
    return 0 if not failed else 1


# ---------------------------------------------------------------------------
# record
# ---------------------------------------------------------------------------

def changed(a, b, rect=None):
    """Pixels that differ between two frames, and their bounding box —
    within `rect` when given, else anywhere."""
    w, h, ra = a
    _, _, rb = b
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    n = 0
    rx, ry, rw, rh = rect if rect else (0, 0, w, h)
    for y in range(ry, min(h, ry + rh)):
        row = y * w * 3
        if ra[row + rx * 3:row + (rx + rw) * 3] == rb[row + rx * 3:row + (rx + rw) * 3]:
            continue
        for x in range(rx, min(w, rx + rw)):
            i = row + x * 3
            if ra[i:i + 3] != rb[i:i + 3]:
                n += 1
                x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
    return n, ([x0, y0, x1 - x0 + 1, y1 - y0 + 1] if x1 >= 0 else None)


def inked(frame, rect):
    """How many pixels of `rect` differ from its own corner pixel (the
    ground): a mark or a glyph drawn there."""
    x, y, w, h = rect
    ground = px(frame, x + 1, y + 1)
    n = 0
    for j in range(y, y + h):
        for i in range(x, x + w):
            p = px(frame, i, j)
            if abs(p[0] - ground[0]) + abs(p[1] - ground[1]) + abs(p[2] - ground[2]) > 30:
                n += 1
    return n


STRIP_GROUNDS = ["#1b1b1b", "#333333", "#282828"]
# PLAT-50: the window's colours are the desktop's tokens — the strip on
# ui/surface/primary/default (#1b1b1b), the selected tab on
# ui/surface/primary/tertiary (#333333), a pane on ui/surface/base/panel
# (#282828); they were #262626 / #333333 / #1b222c.
# PLAT-49: a tab strip's labels stand on SEVERAL grounds — the strip's own
# (`crTabStripBackground`), the selected tab's (`crTabActiveBackground`) and,
# under a strip, the pane's (`crPaneBackground`). Tesseract binarises a line
# with one threshold, which drops the dim labels on the dark ground beside a
# bright one; `ocr(..., grounds=STRIP_GROUNDS)` paints every ground pixel white
# and every other pixel black first.


def _rgb(hexs):
    return tuple(int(hexs[i:i + 2], 16) for i in (1, 3, 5))


def ocr(frame_path, rect, name, grounds=None):
    x, y, w, h = rect
    fw, _, raster = read_ppm(frame_path)
    big = os.path.join(OUT, name + ".big.ppm")
    gs = [_rgb(g) for g in (grounds or [])]
    out = bytearray()
    for j in range(y, y + h):
        row = bytearray()
        for i in range(x, x + w):
            p = raster[(j * fw + i) * 3:(j * fw + i) * 3 + 3]
            if gs:
                on = any(all(abs(p[k] - g[k]) <= 6 for k in range(3)) for g in gs)
                p = b"\xff\xff\xff" if on else b"\x00\x00\x00"
            row += p + p
        out += row + row
    with open(big, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (2 * w, 2 * h) + bytes(out))
    res = subprocess.run(["tesseract", big, "-", "--psm", "6"],
                         capture_output=True, text=True)
    return res.stdout


def jload(name):
    return json.load(open(os.path.join(OUT, name)))


def record():
    manifest = jload("manifest.json")
    facts = jload("facts.json")
    fr = {k: read_ppm(os.path.join(OUT, k + ".ppm")) for k in manifest if manifest[k]}
    path = lambda k: os.path.join(OUT, k + ".ppm")
    out = {
        "_comment": [
            "PLAT-48 — the top bar and the auto-hide panels in a real GPUI window,",
            "read from its own pixels (and OCR). Captured by",
            "`just plat48-gpui-window` (headless sway, a virtual pointer, wtype) and",
            "measured by `just plat48-gpui-window-record` (ci/test/plat48_gpui_window.py).",
            "`ticksReportedByWindow` and `reportedByWindow` are the window's own",
            "report (its session's tick, the ViewModel's highlight, the stack a",
            "placed pane joined), carried labelled beside the pixel/OCR evidence",
            "for the same step; every other field is read from the frames.",
            "Asserted by src/frontend/gpui/tests/test_plat48_gpui_window.nim.",
        ],
        "frame": [FRAME_W, FRAME_H],
        "settled": manifest,
        "ticksReportedByWindow": facts["ticks"],
        "controlClicks": facts["controls"],
    }
    reported = {}
    base = fr["base"]
    g = jload("a-base.geometry.json")
    # ---- the top bar ---------------------------------------------------------
    marks = {}
    for s in g["topBar"]["segs"]:
        if s["part"] == "control":
            marks[s["label"]] = inked(base, s["rect"])
    out["controlMarkInk"] = marks
    # PLAT-49: the band holds ONE root button and no folder title; the first
    # level is the root popover's rows.
    out["menuBandOcr"] = ocr(path("base"), [g["topBar"]["band"][0],
                                            g["topBar"]["band"][1], 330,
                                            g["topBar"]["band"][3]],
                             "band").strip()
    gr = jload("a-menu-root.geometry.json")
    root = gr["topBar"]["popovers"][0]
    out["menuTitlesOcr"] = ocr(path("menu-root"), root["rect"], "titles").strip()
    out["menuRoot"] = {"popover": root["rect"],
                       "button": seg(g, "menu")["rect"]}
    bottom = next(s for s in g["strips"] if s["edge"] == "bottom")
    out["footerOcr"] = ocr(path("base"), bottom["rect"], "footer").strip()
    # ---- the menu ------------------------------------------------------------
    gm = jload("a-menu.geometry.json")
    pop = gm["topBar"]["popovers"][1]
    n, box = changed(fr["menu-root"], fr["menu-open"])
    out["menuOpen"] = {"popover": pop["rect"], "changedBox": box, "changed": n,
                       "rootPopover": gm["topBar"]["popovers"][0]["rect"]}
    rows = {r["label"]: r for r in pop["rows"]}
    so = rows["Step Over"]["rect"]
    out["menuStepOverOcr"] = ocr(path("menu-open"), so, "stepover").strip()
    out["menuStepOverShortcut"] = rows["Step Over"]["shortcut"]
    si = rows["Step In"]["rect"]
    n1, _ = changed(fr["menu-open"], fr["menu-hover"], si)
    out["menuHover"] = {"stepInRowChanged": n1}
    reported["menuHoverHighlight"] = facts["menuHover"]
    n2, _ = changed(fr["menu-hover"], fr["menu-key"], rows["Step Out"]["rect"])
    out["menuKey"] = {"stepOutRowChanged": n2}
    reported["menuKeyHighlight"] = facts["menuKey"]
    n3, _ = changed(fr["menu-open"], fr["menu-choose"], pop["rect"])
    out["menuChoose"] = {"popoverPixelsChanged": n3}
    reported["menuClosed"] = facts["menuClosed"]
    # ---- hover label on a control --------------------------------------------
    gh = jload("a-hover.geometry.json")
    nxt = next(s for s in gh["topBar"]["segs"] if s["label"] == "next")["rect"]
    lbl = [nxt[0], nxt[1] + nxt[3], 320, 30]
    out["controlHoverOcr"] = ocr(path("hover-control"), lbl, "hovernext").strip()
    # ---- the omnibar ---------------------------------------------------------
    go = jload("a-omni.geometry.json")
    reported["omnibarQuery"] = go["topBar"]["query"]
    field = next(s for s in go["topBar"]["segs"] if s["part"] == "omnibar")["rect"]
    out["omnibarQueryOcr"] = ocr(path("omni-sym"), field, "omniquery").strip()
    out["omnibarAttempts"] = facts.get("omnibarAttempts", {})
    reported["omnibarSymResults"] = [r["label"] for r in go["topBar"]["results"]]
    if go["topBar"]["results"]:
        rr = go["topBar"]["results"][0]["rect"]
        out["omnibarSymOcr"] = ocr(path("omni-sym"), [rr[0], rr[1], 400, rr[3]], "omnisym").strip()
    # ---- the footer reveal ---------------------------------------------------
    gr = jload("a-reveal.geometry.json")
    rect = gr["revealed"]["rect"]
    n, box = changed(fr["reveal-base"], fr["reveal-bottom"])
    out["revealBottom"] = {"rect": rect, "changedBox": box,
                           "changedOutside": changed_outside(fr["reveal-base"], fr["reveal-bottom"], rect, gr),
                           "ocr": ocr(path("reveal-bottom"), [rect[0], rect[1], rect[2], 80], "reveal",
                                      STRIP_GROUNDS).strip()}
    n, _ = changed(fr["reveal-base"], fr["reveal-esc"])
    out["revealEscChanged"] = n
    gk = jload("a-keyreveal.geometry.json")
    reported["keyReveal"] = gk["revealed"]["pane"] if gk["revealed"] else None
    if gk["revealed"]:
        kr = gk["revealed"]["rect"]
        out["keyRevealOcr"] = ocr(path("key-reveal"), [kr[0], kr[1], kr[2], 80],
                                  "keyreveal", STRIP_GROUNDS).strip()
    # ---- pin / unpin ---------------------------------------------------------
    reported["pinnedDocked"] = facts["pinnedDocked"]
    reported["unpinnedPlaced"] = facts["unpinnedPlaced"]
    reported["unpinnedStack"] = facts.get("unpinnedStack", [])
    gp = jload("a-pinned.geometry.json")
    pb = next(s for s in gp["strips"] if s["edge"] == "bottom")
    out["pinnedFooterOcr"] = ocr(path("pinned"), pb["rect"], "pinnedfooter").strip()
    gu = jload("a-unpinned.geometry.json")
    ub = next(s for s in gu["strips"] if s["edge"] == "bottom")
    out["unpinnedFooterOcr"] = ocr(path("unpinned"), ub["rect"], "unpinnedfooter").strip()
    un = next((n for n in gu["nodes"] if n["kind"] == "tabs" and "state" in n["panes"]), None)
    out["unpinnedTabsOcr"] = (ocr(path("unpinned"), un["strip"], "unpinnedtabs",
                                  STRIP_GROUNDS).strip()
                              if un and un["strip"][2] > 0 else "")
    # ---- the top edge --------------------------------------------------------
    gt = jload("a-top.geometry.json")
    top = next((s for s in gt["strips"] if s["edge"] == "top"), None)
    reported["topDocked"] = facts.get("topDocked", False)
    if top:
        out["topStrip"] = {"rect": top["rect"],
                           "ocr": ocr(path("top-docked"), top["rect"], "topstrip").strip()}
        gtr = jload("a-toprev.geometry.json")
        rr = gtr["revealed"]["rect"]
        out["topReveal"] = {"rect": rr,
                            "changedOutside": changed_outside(fr["top-docked"], fr["top-revealed"], rr, gtr),
                            "ocr": ocr(path("top-revealed"), [rr[0], rr[1], rr[2], 80],
                                       "toprev", STRIP_GROUNDS).strip()}
        reported["topRevealPane"] = gtr["revealed"]["pane"]
        n, _ = changed(fr["top-docked"], fr["top-esc"])
        out["topEscChanged"] = n
        reported["topBackPlaced"] = facts.get("topBackPlaced", False)
    gb = jload("b.geometry.json")
    btop = next((s for s in gb["strips"] if s["edge"] == "top"), None)
    doc = jload("top-docked-layout.json")
    out["docTop"] = {"strip": btop["rect"] if btop else None,
                     # What the TERMINAL wrote: the panes its saved document
                     # docks at the top edge.
                     "terminalTopDocked": [d["pane"] for d in doc.get("docked", [])
                                           if d.get("edge") == "top"],
                     "ocr": ocr(path("doc-top"), btop["rect"], "doctop").strip() if btop else ""}
    reported["docTopSlots"] = [s["pane"] for s in btop["slots"]] if btop else []
    out["reportedByWindow"] = reported
    with open(RECORD, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("plat48-gpui-window: recorded " + RECORD)
    return 0


def changed_outside(a, b, rect, geom):
    """Pixels changed OUTSIDE `rect`, ignoring the top bar's band (whose
    hover and highlight states are not the reveal's) and the auto-hide
    strips (whose label for the revealed pane is drawn active — the one
    change outside the overlay a reveal is meant to make)."""
    w, h, ra = a
    _, _, rb = b
    skip = [rect] + [s["rect"] for s in geom["strips"]]
    band = geom["topBar"]["band"]
    top = band[1] + band[3]
    n = 0
    for j in range(top, h):
        row = j * w * 3
        if ra[row:row + w * 3] == rb[row:row + w * 3]:
            continue
        for i in range(w):
            if any(x <= i < x + rw and y <= j < y + rh for x, y, rw, rh in skip):
                continue
            k = row + i * 3
            if ra[k:k + 3] != rb[k:k + 3]:
                n += 1
    return n


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("capture", "record"):
        sys.exit("usage: plat48_gpui_window.py capture|record")
    sys.exit(capture() if sys.argv[1] == "capture" else record())
