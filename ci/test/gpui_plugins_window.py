#!/usr/bin/env python3
"""Installed plugins in a REAL GPUI window (Extensibility-Model.md §11).

    python3 ci/test/gpui_plugins_window.py capture   # inside a headless sway
    python3 ci/test/gpui_plugins_window.py record    # result -> committed JSON

`capture` (run by `ci/test/gpui-plugins-window.sh`, which starts the headless
sway) opens the windowed `codetracer-gpui` over the real `calc` recording with
the `acme-tools` test package (`viewmodel/tests/unit/plugin_packages/`)
INSTALLED AS A COMPONENT (`plugin_process_fixture.installPackage`, through
`src/frontend/gpui/tests/gpui_plugins_install.nim`), and drives it the way a
user does: REAL keys through the compositor's virtual keyboard
(`ci/test/wtype-keys.sh`), the omnibar opened with F1 and a line
typed into it. Six windows; the sixth installs the `ct-lens` package
(`src/plugins/ct-lens/`, `ct_lens_fixture.installLens`) instead:

  consent-and-run   no plugin process before consent; `:plugins review` shows
                    the grant screen; both plugins granted and running in ONE
                    process; *Show pane: Metrics* docks the pane, which draws
                    the mirrored debugger line; *Metrics: Step forward* steps
                    the primary; SIGKILL -> a new process with both plugins
                    running, and F10 still steps the debugger.
  no-extensions     `--no-extensions` over the layout the first window
                    remembered: no plugin process at any sample, the docked
                    pane's slot is the "extension that is not loaded" report,
                    and *Plugins: Show status* says why.
  recovery-chord    `flame` in `swallow-input` mode (a window layer over every
                    printable key and Escape, never acknowledged; its
                    manifest declares `capturesWindowInput`): the footer names
                    it; three Escapes pop its layer and open RECOVER INPUT
                    naming it.
  swallowed-key     the same plugin: `j` goes to it and is dropped with the
                    status sentence, and the plugin loses the keyboard (its
                    layer is transparent: the footer no longer names it);
                    `k` and `l` reach the window, and the third key opens
                    the plugin's breaker.
  pane-key-and-decoration
                    both plugins granted: `metrics`'s decoration and its
                    `hotspot` marker are on the execution line (the window's
                    `plugin marks` trace), the footer repeats the decoration
                    and a frame's OCR reads it in the editor; *Show pane:
                    Flame* docks and focuses `flame`'s list, whose Down and
                    Enter go to its view (`plugin view key`), and the plugin's
                    answer marks the activated row; a REAL press on the other
                    row (a virtual pointer at the row the frame's OCR found)
                    activates that one (`plugin view click`).
  ct-lens           the three ct-lens plugins granted from the omnibar:
                    history and watch in one process, jump in its own;
                    *Show pane: Line history* draws the history of the
                    function the debugger is in, and its status item reaches
                    the footer; steps until the watch plugin's status item
                    names one changed value, then F7 goes to the plugin and
                    watches it (the command then says why it is off);
                    Shift+F7's mode is named on the footer, a digit jumps
                    through the calltrace (the history pane follows to
                    another function) and closes it; opened again, three
                    Escapes take the keyboard back and RECOVER INPUT names
                    it.

What each window did is read from the window's OWN output — its gesture trace
(`CODETRACER_GPUI_GESTURE_TRACE=1`, the lines `main.nim`'s plugin pump writes:
the status report on a line, the footer's note, what a contributed pane's
element tree holds read back from the shim) — and from outside it: the process
table (`pgrep`), sway's window tree, and the OCR of a `grim` frame of the
docked pane. Nothing in the window is a stand-in: the binary, the
replay-server, the recording and the plugin process are the real ones.

`record` copies the result to `src/tests/visual/gpui-plugins-window.json`,
which `src/frontend/gpui/tests/test_gpui_plugins_window.nim` asserts over.

Prerequisites are refused BY NAME, never skipped.
"""

import datetime
import glob
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "build", "gpui-plugins")
RECORD = os.path.join(ROOT, "src", "tests", "visual", "gpui-plugins-window.json")
WTYPE_KEYS = os.path.join(HERE, "wtype-keys.sh")
BIN = os.environ.get("CODETRACER_GPUI_PLUGINS_BIN",
                     os.path.join(ROOT, "build", "bin", "codetracer-gpui-window"))
INSTALLER = os.environ.get("CODETRACER_GPUI_PLUGINS_INSTALLER",
                           os.path.join(OUT, "gpui_plugins_install"))
PLUGIN_EXE = "acme-tools@1.0.0/bin/acme-tools-plugins"
LENS_EXE = "ct-lens@0.1.0/bin/ct-lens-plugins"
QUIT_AFTER_MS = 300000
VPOINTER = os.environ.get("CODETRACER_VIRTUAL_POINTER", os.path.join(
    os.path.dirname(ROOT), "isonim-gpui", "build", "virtual-pointer"))
FRAME_W, FRAME_H = 1920, 1080  # wayland-run-test.sh's headless output


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


_HOLDER = None


def hold_keyboard():
    """Keep ONE virtual keyboard on the seat for the whole capture.

    The headless sway has no keyboard of its own, so every `wtype` call
    HOT-PLUGS the seat's only keyboard: the seat gains the keyboard
    capability, the window's client must answer with `wl_seat.get_keyboard`,
    and only then does the compositor have a `wl_keyboard` to send keys to.
    A key `wtype` sends before a busy window has done that goes to no one —
    the compositor drops it, `wtype` exits 0 — and when `wtype` exits the
    capability goes again, so the next call starts over. Measured 2026-11-22
    with WAYLAND_DEBUG=client on a real window over calc: 2 of 16 lone F10s
    lost, each time with the seat's capabilities(2) and capabilities(0)
    dispatched together after the call had finished; a window SIGSTOPped
    across one `wtype` call lost its key 3 times of 3 without a held keyboard
    and received it 3 times of 3 with one (`wtype-keys.sh`'s header).

    A user's keyboard stays plugged in, so the window's `wl_keyboard` exists
    before any key and a key sent while the window is busy waits in its
    socket: this is the injection's artefact, not the window's. Holding a
    keyboard (`wtype -s`, which creates its virtual keyboard and sleeps) gives
    the capture the same seat. wtype's sleep is `usleep(ms * 1000)` in 32
    bits, so an hour is the longest one call holds; it is restarted when it
    has ended.

    A window that opens while the seat has a keyboard but no ACTIVE one —
    every time after a `wtype` call has exited, until the next key — is told
    `no_keymap`. Before isonim-gpui f766d25 such a window aborted (its
    vendored gpui's `wayland/client.rs` unwrapped the missing keymap;
    measured: three windows of four ended SIGABRT), as it would have for a
    user who unplugged a keyboard; it now ignores that keyboard until a
    keymap arrives, which the next call's key brings."""
    global _HOLDER
    if _HOLDER is not None and _HOLDER.poll() is None:
        return
    _HOLDER = subprocess.Popen(["wtype", "-s", "3600000"])
    time.sleep(1.0)


def no_key_repeat():
    """Turn the compositor's key repeat off for every keyboard on the seat.

    A key `wtype` holds down past the repeat delay — on a loaded host the
    gap between its press and release can be that long — repeats in the
    window as if a user held it: measured 2026-11-24 at load about 140, the
    omnibar's query read `:plugins  grant` (one space typed, two arrived) and
    the line was refused. A user's typing does not repeat, so the window must
    not see repeats the injection made. Rate 0 is the protocol's "no
    repeat" (`wl_keyboard.repeat_info`)."""
    subprocess.run(["swaymsg", "input type:keyboard repeat_rate 0"],
                   capture_output=True, text=True, check=False)


def release_keyboard():
    if _HOLDER is not None and _HOLDER.poll() is None:
        _HOLDER.kill()
        _HOLDER.wait()


def keys(*args, lead_ms=500):
    """Real keys through the compositor (`wtype-keys.sh`), with the seat's
    keyboard held (`hold_keyboard`)."""
    hold_keyboard()
    env = dict(os.environ, WTYPE_LEAD_MS=str(lead_ms))
    subprocess.run(["bash", WTYPE_KEYS, *args], env=env, check=False)


class Pointer:
    """A REAL pointer device on the headless compositor (isonim-gpui's
    `virtual-pointer`, wlroots' virtual-pointer protocol): absolute motion
    over the output and button presses, as a mouse sends them."""

    def __init__(self):
        self.proc = subprocess.Popen([VPOINTER, str(FRAME_W), str(FRAME_H)],
                                     stdin=subprocess.PIPE, text=True)

    def send(self, *cmds):
        for c in cmds:
            self.proc.stdin.write(c + "\n")
        self.proc.stdin.flush()

    def click(self, x, y):
        self.send(f"abs {x} {y}", "sleep 150", "down left", "sleep 120", "up left", "sleep 300")

    def close(self):
        if self.proc.poll() is None:
            self.send("quit")
            self.proc.stdin.close()
            self.proc.wait(timeout=20)


def ocr_word_at(png, word):
    """The centre of the first word `word` in a frame (tesseract's word
    boxes, in the output's pixels), or None."""
    r = subprocess.run(["tesseract", png, "-", "--psm", "11", "tsv"],
                       capture_output=True, text=True)
    for row in r.stdout.splitlines()[1:]:
        f = row.split("\t")
        if len(f) >= 12 and f[11].strip() == word:
            x, y, w, h = (int(v) for v in f[6:10])
            return x + w // 2, y + h // 2
    return None


def plugin_pids(home, exe=PLUGIN_EXE):
    # The installed package's executable, under THIS window's components root.
    out = subprocess.run(["pgrep", "-f", os.path.join(home, "components", exe)],
                         capture_output=True, text=True).stdout
    return sorted(int(x) for x in out.split())


class Window:
    def __init__(self, name, home, extra=(), state=None, exe=PLUGIN_EXE,
                 quit_after_ms=QUIT_AFTER_MS):
        self.name = name
        self.home = home
        self.exe = exe
        self.quit_after_ms = quit_after_ms
        self.dir = os.path.join(OUT, name)
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.log = os.path.join(self.dir, "run.log")
        traces = sorted(glob.glob(os.path.join(ROOT, "test-logs/tui-fixtures/calc-*")))
        if not traces:
            fail("no calc recording in test-logs/tui-fixtures/")
        env = dict(os.environ)
        env.update({
            "CODETRACER_GPUI_GESTURE_TRACE": "1",
            "CODETRACER_GPUI_PROBE_SENTINEL": "f12",
            "XDG_STATE_HOME": os.path.join(home, "state"),
            "XDG_DATA_HOME": os.path.join(home, "data"),
            "XDG_CONFIG_HOME": os.path.join(home, "config"),
            "CODETRACER_HOME": os.path.join(home, "ct-home"),
            "CODETRACER_USER_ROOT": os.path.join(home, "user-root"),
            "CODETRACER_COMPONENTS_ROOT": os.path.join(home, "components"),
            "CODETRACER_TUI_LAYOUT_DIR": state or os.path.join(home, "layout"),
        })
        env.pop("CODETRACER_NO_EXTENSIONS", None)
        # The windowed shim's X/Wayland libraries (the dev shell's list, as the
        # other window lanes pass it).
        env["LD_LIBRARY_PATH"] = os.environ.get("CODETRACER_GPUI_RUNTIME_LIB_PATH", "") + \
            ":" + os.environ.get("LD_LIBRARY_PATH", "")
        self.started = time.time()
        self.proc = subprocess.Popen(
            [BIN, "--quit-after-ms=%d" % quit_after_ms, "--width=1440",
             "--height=900", *extra, traces[0]],
            stdout=open(self.log, "w"), stderr=subprocess.STDOUT, env=env)
        self.pos = 0
        self.samples = []

    def text(self):
        with open(self.log, errors="replace") as f:
            return f.read()

    def lines(self):
        return [l[len("gesture "):] for l in self.text().splitlines()
                if l.startswith("gesture ")]

    def wait(self, pattern, timeout=90, since=0):
        """The first gesture line from index `since` matching `pattern`."""
        rx = re.compile(pattern)
        end = time.time() + timeout
        while time.time() < end:
            ls = self.lines()
            for i in range(since, len(ls)):
                if rx.search(ls[i]):
                    return i, ls[i]
            if self.proc.poll() is not None:
                break
            time.sleep(0.2)
        return -1, ""

    def mark(self):
        return len(self.lines())

    def omnibar(self, line):
        """Open the omnibar, type `line`, check the window holds exactly that
        query (its own `topbar … query=` trace), then Enter, and check the
        omnibar closed. No retries: with the seat's keyboard held every key
        arrives, so a wrong query is a defect to report, not to retype."""
        m = self.mark()
        keys("-k", "F1")
        if self.wait(r"^topbar .* omnibar=true ", 20, m)[0] < 0:
            return False
        m = self.mark()
        keys("-d", "60", line, lead_ms=300)
        want = "omnibar=true query=" + line + " results="
        end = time.time() + 30
        while not any(want in l for l in self.lines()[m:]):
            if time.time() > end:
                return False
            time.sleep(0.2)
        m = self.mark()
        keys("-k", "Return", lead_ms=300)
        ok = self.wait(r"^topbar .* omnibar=false ", 20, m)[0] >= 0
        time.sleep(0.5)
        return ok

    def mapped(self, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            tree = subprocess.run(["swaymsg", "-t", "get_tree"], capture_output=True,
                                  text=True).stdout
            if "CodeTracer" in tree:
                return True
            time.sleep(0.5)
        return False

    def grab(self, name):
        png = os.path.join(self.dir, name + ".png")
        subprocess.run(["grim", png], check=False)
        txt = ""
        if os.path.exists(png):
            r = subprocess.run(["tesseract", png, "-", "--psm", "11"],
                               capture_output=True, text=True)
            txt = r.stdout
        return txt

    def grab_showing(self, name, needle, timeout=30):
        """`grab` until the frame's OCR shows `needle`, or `timeout` seconds.
        A frame `grim` takes can be older than the window's state on a loaded
        host (the compositor still holds the frame drawn before the change),
        so one grab that misses says nothing yet; the last grab is returned
        either way and the suite asserts on it."""
        end = time.time() + timeout
        txt = self.grab(name)
        while needle not in txt and time.time() < end:
            time.sleep(2)
            txt = self.grab(name)
        return txt

    def finish(self):
        for _ in range(15):
            if self.proc.poll() is not None:
                break
            # A text shown over the window takes every key: `q` closes it.
            keys("-k", "q", "-s", "300", "-k", "F12")
            time.sleep(2)
        try:
            rc = self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            rc = -9
        elapsed = int((time.time() - self.started) * 1000)
        time.sleep(1)
        return {"rc": rc, "elapsedMs": elapsed,
                "endedOnDeadline": elapsed >= self.quit_after_ms - 500,
                "pluginPidsAfterExit": plugin_pids(self.home, self.exe)}


def new_home(name, capture=False, settings=None, package="acme-tools"):
    home = os.path.join(OUT, name + "-home")
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(os.path.join(home, "components"))
    mode = ["capture"] if capture else (["ct-lens"] if package == "ct-lens" else [])
    args = [INSTALLER, os.path.join(home, "components")] + mode
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        fail("installing " + package + " failed: " + r.stdout + r.stderr)
    if settings is not None:
        os.makedirs(os.path.join(home, "user-root"))
        with open(os.path.join(home, "user-root", "plugin-settings.json"), "w") as f:
            json.dump(settings, f)
    return home


def state_pid(line):
    m = re.search(r"running pid (\d+)", line)
    return int(m.group(1)) if m else None


def run_consent_and_run():
    home = new_home("consent")
    w = Window("consent-and-run", home)
    r = {"mapped": w.mapped()}
    _, awaiting = w.wait(r"^plugins awaiting consent acme-tools\.metrics$", 60)
    r["awaitingConsent"] = awaiting != ""
    time.sleep(2)
    r["pidsBeforeConsent"] = plugin_pids(home)
    m = w.mark()
    w.omnibar(":plugins review acme-tools.metrics")
    _, review = w.wait(r"^plugins review acme-tools\.metrics -> GRANT", 30, m)
    r["grantScreen"] = review
    r["grantScreenSaysNative"] = w.wait(r"^plugins report .*runs the native program", 5, m)[0] >= 0
    keys("-k", "q")
    time.sleep(0.5)
    m = w.mark()
    w.omnibar(":plugins grant acme-tools.metrics")
    w.omnibar(":plugins grant acme-tools.flame")
    _, running = w.wait(r"^plugins state .*acme-tools\.metrics  running.*acme-tools\.flame  running"
                        r"|^plugins state .*acme-tools\.flame  running.*acme-tools\.metrics  running",
                        90, m)
    r["bothRunningState"] = running
    r["statePid"] = state_pid(running)
    time.sleep(1)
    r["pidsRunning"] = plugin_pids(home)
    # The pane, docked from the omnibar entry, drawing the mirrored debugger line.
    m = w.mark()
    w.omnibar(":Show pane: Metrics")
    _, drew = w.wait(r"^plugin pane acme-tools\.metrics/overview drew: .*line \S+:\d+.*position \d+", 60, m)
    r["paneDrew"] = drew
    r["paneDocked"] = w.wait(r"^applied addContributedPane\(acme-tools\.metrics/overview", 5, m)[0] >= 0
    time.sleep(1.5)
    r["paneOcr"] = w.grab_showing("pane-docked", "position")
    # A plugin command from the omnibar steps the primary.
    m = w.mark()
    w.omnibar(":Metrics: Step forward")
    _, move = w.wait(r"^plugin move next$", 60, m)
    r["pluginMove"] = move
    _, control = w.wait(r"^control next tick=\d+", 30, m)
    r["controlAfterMove"] = control
    # The pane is drawn again at once from the tree it holds, and once more
    # when the plugin pushed its reading of the new stop: wait for that one,
    # the first drawing at a position other than the one before the step.
    before = re.search(r"position (\d+)", r["paneDrew"] or "")
    other = r"(?!" + before.group(1) + r"\b)" if before else ""
    _, drew2 = w.wait(r"^plugin pane acme-tools\.metrics/overview drew: .*position " +
                      other + r"\d+", 60, max(m, w.wait(r"^control next tick=", 1, m)[0]))
    r["paneDrewAfterStep"] = drew2
    # SIGKILL: a new process with both plugins, and the debugger still answers.
    pids = plugin_pids(home)
    r["killedPid"] = pids[0] if pids else None
    m = w.mark()
    if pids:
        os.kill(pids[0], signal.SIGKILL)
    new = []
    end = time.time() + 90
    while time.time() < end:
        now = plugin_pids(home)
        if len(now) == 1 and now[0] != r["killedPid"]:
            new = now
            break
        time.sleep(0.2)
    r["pidsAfterKill"] = new
    restarted = ""
    since = m
    end = time.time() + 90
    while time.time() < end and not restarted:
        i, line = w.wait(r"^plugins state .*acme-tools\.metrics  running.*acme-tools\.flame  running",
                         5, since)
        if i >= 0:
            since = i + 1
            if state_pid(line) not in (None, r["killedPid"]):
                restarted = line
    r["restartedState"] = restarted
    m = w.mark()
    keys("-k", "F10")
    _, stepped = w.wait(r"^control next tick=\d+", 30, m)
    r["keyStepAfterRestart"] = stepped
    r.update(w.finish())
    return r


def run_no_extensions():
    home = new_home("noext")
    w = Window("no-extensions", home, ["--no-extensions"],
               state=os.path.join(OUT, "consent-home", "layout"))
    r = {"mapped": w.mapped()}
    _, unloaded = w.wait(r"^leaf acme-tools\.metrics/overview unloaded-extension$", 30)
    r["unloadedLeaf"] = unloaded
    samples = []
    for _ in range(10):
        samples.append(len(plugin_pids(home)))
        time.sleep(0.5)
    m = w.mark()
    w.omnibar(":plugins")
    _, status = w.wait(r"^plugins report Extensions are off for this session \(--no-extensions\)", 30, m)
    r["statusReport"] = status
    keys("-k", "q")
    for _ in range(4):
        samples.append(len(plugin_pids(home)))
        time.sleep(0.5)
    r["pidSamples"] = samples
    r["unloadedOcr"] = w.grab_showing("unloaded", "not loaded")
    r.update(w.finish())
    return r


def swallow_home(name):
    return new_home(name, capture=True, settings={"plugins": {"acme-tools.flame": {
        "settings": {"mode": "swallow-input"}}}})


def grant_both(w):
    w.omnibar(":plugins grant acme-tools.metrics")
    w.omnibar(":plugins grant acme-tools.flame")


def run_recovery_chord():
    home = swallow_home("chord")
    w = Window("recovery-chord", home)
    r = {"mapped": w.mapped()}
    w.wait(r"^plugins awaiting consent acme-tools\.flame$", 60)
    time.sleep(1)
    m = w.mark()
    grant_both(w)
    _, layer = w.wait(r"^plugins footer FLAME MODE \(acme-tools\.flame\)", 90, m)
    r["footerWithLayer"] = layer
    time.sleep(1.5)
    r["pidsRunning"] = plugin_pids(home)
    m = w.mark()
    # One virtual keyboard, three Escapes 200 ms apart: inside the chord's second.
    keys("-k", "Escape", "-s", "200", "-k", "Escape", "-s", "200", "-k", "Escape")
    _, dialog = w.wait(r"^plugins dialog RECOVER INPUT: ", 30, m)
    r["dialog"] = dialog
    _, after = w.wait(r"^plugins footer (?!.*FLAME MODE)", 30, m)
    r["footerAfterChord"] = after
    keys("-k", "q")
    r.update(w.finish())
    return r


def run_swallowed_key():
    home = swallow_home("swallow")
    w = Window("swallowed-key", home)
    r = {"mapped": w.mapped()}
    w.wait(r"^plugins awaiting consent acme-tools\.flame$", 60)
    time.sleep(1)
    m = w.mark()
    grant_both(w)
    _, layer = w.wait(r"^plugins footer FLAME MODE \(acme-tools\.flame\)", 90, m)
    r["footerWithLayer"] = layer
    time.sleep(1.5)
    m = w.mark()
    keys("j")
    _, routed = w.wait(r"^plugin key j$", 20, m)
    r["keyRouted"] = routed
    _, dropped = w.wait(r"^status: `j` went to acme-tools\.flame, which did not answer", 30, m)
    r["droppedSentence"] = dropped
    _, lost = w.wait(r"^plugins footer (?!.*FLAME MODE)", 30, m)
    r["footerAfterDrop"] = lost
    m = w.mark()
    keys("k")
    _, through = w.wait(r"^key k at ", 20, m)
    r["nextKeyReachedRouter"] = through
    r["nextKeyToPlugin"] = w.wait(r"^plugin key k$", 2, m)[0] >= 0
    # `k` passed the silent plugin's layer and struck it (§11.7.4); the third
    # key is its third strike, which opens its breaker.
    m = w.mark()
    keys("l")
    _, third = w.wait(r"^key l at ", 20, m)
    r["thirdKeyReachedRouter"] = third
    _, opened = w.wait(r"^plugins state .*acme-tools\.flame  [^|]*breaker open", 30, m)
    r["breakerOpen"] = opened
    r.update(w.finish())
    return r


def run_pane_key_and_decoration():
    home = new_home("panekey")
    w = Window("pane-key-and-decoration", home)
    r = {"mapped": w.mapped()}
    w.wait(r"^plugins awaiting consent acme-tools\.", 60)
    time.sleep(1)
    m = w.mark()
    grant_both(w)
    _, running = w.wait(r"^plugins state .*acme-tools\.metrics  running.*acme-tools\.flame  running"
                        r"|^plugins state .*acme-tools\.flame  running.*acme-tools\.metrics  running",
                        90, m)
    r["bothRunningState"] = running
    # The execution line carries metrics's decoration and its hotspot marker.
    _, marks = w.wait(r"^plugin marks \S+: (?=.*decoration (\d+) ◆ metrics: line \1 \(acme-tools\.metrics\))"
                      r"(?=.*marker \d+ ★ )", 90, m)
    r["marks"] = marks
    _, foot = w.wait(r"^plugins footer .*◆ metrics: line \d+", 30, m)
    r["footerDecoration"] = foot
    time.sleep(1.5)
    r["decorationOcr"] = w.grab_showing("decoration", "metrics: line")
    # flame's list, docked and focused from the omnibar, takes its own keys.
    m = w.mark()
    w.omnibar(":Show pane: Flame")
    _, drew = w.wait(r"^plugin pane acme-tools\.flame/flame drew: .*work 40%", 60, m)
    r["flameDrew"] = drew
    m = w.mark()
    keys("-k", "Down")
    r["downKey"] = w.wait(r"^plugin view key (Down|ArrowDown) on acme-tools\.flame/flame$", 20, m)[1]
    m2 = w.mark()
    keys("-k", "Return")
    r["enterKey"] = w.wait(r"^plugin view key (Enter|Return) on acme-tools\.flame/flame$", 20, m2)[1]
    _, answered = w.wait(r"^plugin pane acme-tools\.flame/flame drew: .*work 40% \(activated\)", 60, m)
    r["flameAnswered"] = answered
    time.sleep(1.5)
    r["flameOcr"] = w.grab_showing("flame-activated", "activated")
    # A REAL press on the other row: the pane's row is found in the frame by
    # its label, and clicking it activates it (`plugin view click`).
    at = None
    end = time.time() + 30
    while at is None and time.time() < end:
        w.grab("flame-before-click")
        at = ocr_word_at(os.path.join(w.dir, "flame-before-click.png"), "main")
        if at is None:
            time.sleep(2)
    r["clickAt"] = list(at) if at else None
    m = w.mark()
    if at:
        ptr = Pointer()
        try:
            time.sleep(0.5)
            ptr.click(*at)
        finally:
            ptr.close()
    r["clickRouted"] = w.wait(r"^plugin view click flame\.list#0 on acme-tools\.flame/flame$", 20, m)[1]
    r["clickAnswered"] = w.wait(r"^plugin pane acme-tools\.flame/flame drew: .*main 60% \(activated\)", 60, m)[1]
    r.update(w.finish())
    return r


LENS_RUNNING = (r"^plugins state (?=.*ct-lens\.history  running)(?=.*ct-lens\.watch  running)"
                r"(?=.*ct-lens\.jump  running)")


def open_jump_mode(w, tries=3):
    """Shift+F7 until the footer names the jump mode: each press waits for
    `ct-lens.jump` to be running (not held as not responding)."""
    for _ in range(tries):
        end = time.time() + 60
        while time.time() < end:
            states = [l for l in w.lines() if l.startswith("plugins state ")]
            if states and "ct-lens.jump  running" in states[-1]:
                break
            time.sleep(0.5)
        m = w.mark()
        keys("-M", "shift", "-k", "F7", "-m", "shift")
        _, mode = w.wait(r"^plugins footer JUMP MODE \(ct-lens\.jump\).* 2 \S", 60, m)
        if mode:
            return mode
    return ""


def run_ct_lens():
    home = new_home("ct-lens", package="ct-lens")
    # Three plugins, two processes and a dozen omnibar lines take longer than
    # the other windows on a loaded host.
    w = Window("ct-lens", home, exe=LENS_EXE, quit_after_ms=900000)
    r = {"mapped": w.mapped()}
    _, awaiting = w.wait(r"^plugins awaiting consent ct-lens\.", 60)
    r["awaitingConsent"] = awaiting
    time.sleep(2)
    r["pidsBeforeConsent"] = plugin_pids(home, LENS_EXE)
    m = w.mark()
    for pid in ("ct-lens.history", "ct-lens.watch", "ct-lens.jump"):
        w.omnibar(":plugins grant " + pid)
    _, running = w.wait(LENS_RUNNING, 120, m)
    r["allRunningState"] = running
    time.sleep(1.5)
    r["pidsRunning"] = plugin_pids(home, LENS_EXE)
    # The history pane, docked from its omnibar entry, follows the debugger.
    m = w.mark()
    w.omnibar(":Show pane: Line history")
    _, drew = w.wait(r"^plugin pane ct-lens\.history/history drew: .*History of ", 90, m)
    r["historyDrew"] = drew
    r["historyDocked"] = w.wait(r"^applied addContributedPane\(ct-lens\.history/history", 5, m)[0] >= 0
    # Its status item may have reached the footer before the pane was shown.
    _, footer = w.wait(r"^plugins footer .*history: ", 60, 0)
    r["historyFooter"] = footer
    # Step until the watch plugin's status item names ONE changed value, then
    # F7: the binding is the plugin's while something is left to watch.
    changed = ""
    steps = 0
    while not changed and steps < 40:
        m = w.mark()
        keys("-k", "F10")
        steps += 1
        if w.wait(r"^control next tick=\d+", 30, m)[0] < 0:
            continue
        i, line = w.wait(r"^plugins footer .*changed: (?!none|…)[^,]+?(  |$)", 15, m)
        if i >= 0:
            changed = re.search(r"changed: ([^ ,]+)", line).group(1)
            r["changedFooter"] = line
    r["changed"] = changed
    r["stepsToChange"] = steps
    m = w.mark()
    keys("-k", "F7")
    _, routed = w.wait(r"^plugin key (?i:f7)$", 20, m)
    r["f7Routed"] = routed
    # Everything the step changed is watched now: the command says why it is off.
    refused = ""
    end = time.time() + 60
    while time.time() < end and not refused:
        m = w.mark()
        w.omnibar(":plugins run ct-lens.watch watch.add-changed")
        _, refused = w.wait(r"^plugins run ct-lens\.watch watch\.add-changed -> "
                            r".*every changed value is already watched", 10, m)
        if refused:
            break
        keys("-k", "q")
        time.sleep(2)
    r["watchRefused"] = refused
    keys("-k", "q")
    time.sleep(0.5)
    # The jump pane, docked too: it says where a jump went.
    m = w.mark()
    w.omnibar(":Show pane: Jump to call")
    r["jumpPaneDrew"] = w.wait(r"^plugin pane ct-lens\.jump/calls drew: .*Jump to call", 60, m)[1]
    # Shift+F7: the jump mode, named on the footer with the numbered calls; a
    # digit jumps through the calltrace and closes it, and the jump pane says
    # where. A key the plugin is slow to acknowledge is still delivered (the
    # mode opens late); a plugin the host then holds as not responding gets
    # no keys until it answers a probe, so each press waits for it to run.
    r["modeFooter"] = open_jump_mode(w)
    pick = re.search(r" 2 (\S+)", r["modeFooter"])
    r["picked"] = pick.group(1) if pick else ""
    ticks = [l for l in w.lines() if l.startswith("control next tick=")]
    r["tickBeforeJump"] = ticks[-1] if ticks else ""
    m = w.mark()
    keys("2")
    r["digitRouted"] = w.wait(r"^plugin key 2$", 20, m)[1]
    _, closed = w.wait(r"^plugins footer (?!JUMP MODE)", 30, m)
    r["modeClosedFooter"] = closed
    _, jumped = w.wait(r"^plugin pane ct-lens\.jump/calls drew: .*jumped to ", 60, m)
    r["jumpedPane"] = jumped
    # Whether the window shows the relayed jump at once (the history pane
    # follows the stop), and what the next step starts from: a step after
    # the jump starts inside the call it jumped to.
    r["historyAtOnce"] = w.wait(r"^plugin pane ct-lens\.history/history drew: .*History of " +
                                re.escape(r["picked"] or "\0") + r" ", 20, m)[1]
    m = w.mark()
    keys("-k", "F10")
    r["tickAfterJump"] = w.wait(r"^control next tick=\d+", 30, m)[1]
    r["historyAfterStep"] = w.wait(r"^plugin pane ct-lens\.history/history drew: .*History of "
                                   r"(?!<__main__>)", 60, m)[1]
    # Opened again: three Escapes take the keyboard back from it.
    r["modeAgain"] = open_jump_mode(w)
    m = w.mark()
    keys("-k", "Escape", "-s", "200", "-k", "Escape", "-s", "200", "-k", "Escape")
    _, dialog = w.wait(r"^plugins dialog RECOVER INPUT: ", 30, m)
    r["dialog"] = dialog
    _, after = w.wait(r"^plugins footer (?!JUMP MODE)", 30, m)
    r["footerAfterChord"] = after
    keys("-k", "q")
    r.update(w.finish())
    return r


def capture():
    # The installer and the package build live in OUT too: only this
    # capture's own outputs are replaced.
    os.makedirs(OUT, exist_ok=True)
    for stale in ["result.json"]:
        if os.path.exists(os.path.join(OUT, stale)):
            os.remove(os.path.join(OUT, stale))
    if not os.access(BIN, os.X_OK):
        fail(BIN + " is not built (a codetracer-gpui against the windowed shim)")
    if not os.access(VPOINTER, os.X_OK):
        fail(VPOINTER + " is not built (isonim-gpui's scripts/build-virtual-pointer.sh)")
    if not os.access(INSTALLER, os.X_OK):
        fail(INSTALLER + " is not built (gpui-plugins-window.sh builds it)")
    result = {
        "takenAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host": socket.gethostname(),
        "binary": os.path.basename(BIN),
        "commit": subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"],
                                 capture_output=True, text=True).stdout.strip(),
        "dirty": subprocess.run(["git", "-C", ROOT, "status", "--porcelain",
                                 "--untracked-files=no"],
                                capture_output=True, text=True).stdout.strip() != "",
        "windows": {},
    }
    no_key_repeat()
    hold_keyboard()
    try:
        for name, fn in [("consentAndRun", run_consent_and_run),
                         ("noExtensions", run_no_extensions),
                         ("recoveryChord", run_recovery_chord),
                         ("swallowedKey", run_swallowed_key),
                         ("paneKeyAndDecoration", run_pane_key_and_decoration),
                         ("ctLens", run_ct_lens)]:
            result["windows"][name] = fn()
            with open(os.path.join(OUT, "result.json"), "w") as f:
                json.dump(result, f, indent=1)
    finally:
        release_keyboard()
    print(json.dumps(result, indent=1))


def record():
    src = os.path.join(OUT, "result.json")
    if not os.path.exists(src):
        fail("no " + src + "; run the capture first")
    shutil.copy(src, RECORD)
    print("recorded " + RECORD)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("capture", "record"):
        fail("usage: gpui_plugins_window.py capture|record")
    capture() if sys.argv[1] == "capture" else record()
