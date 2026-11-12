#!/usr/bin/env python3
"""The mutation harness for CodeTracer's scenario pack (src/tests/scenarios):
its bindings (the desktop's DOM reader, the terminal's screen reader, the GPUI
window's vision reader), the binding resolver, the pack's sync conditions and
the lint gate that keeps code out of a scenario's steps.

Each arm plants ONE defect of a kind the pack exists to rule out —

  * a binding reading a stale or wrong property (the page object answers from
    a screen that is not the current one, or misreads the stop or the caret);
  * a sync condition that fires early (`replay-idle` before the window shows
    the stop);
  * a binding resolver that does not ask the application's router as the
    application builds it (the user's keybindings ignored, a chord respelled);
  * a stage call smuggled into a scenario's steps;

— REBUILDS the program the defect is compiled into (the terminal's and the GPUI
window's `dvs-*-codetracer`; the desktop's binding is loaded as source), runs
the scenarios that must catch it on the real front-end against a real
recording and replay server, and requires RED with the failure the first run
recorded (`plat66-pack-mutation-because.json`, written with `--derive`).

The discipline is the other harnesses' (`run-plat65-nim-tracing-mutations.py`):
committed control digests over the subjects AND the scenarios they are graded
by, a needle scan that gates re-recording, rc 124 is a hang, per-arm restore
verification, and `ci/lib/harness_guard.py`'s argument rule first.

Environment: run inside the dev shell, with `just build-tui`, `just build-once`
and the windowed GPUI front-end built, `ci/test/scenarios.sh build` done, and
GuiAssert's helpers (`GUI_ASSERT_HELPER_DIR`). The desktop arms start their own
Xvfb (2560x1440x24, 96 dpi); the GPUI ones run on the adapter's private display.

Usage:
    run-plat66-pack-mutations.py [--only T1,P1] [--derive]
    run-plat66-pack-mutations.py --needle-scan
    run-plat66-pack-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat66-pack-mutation-control.sha256"
BECAUSE = HERE / "plat66-pack-mutation-because.json"
RESULTS = HERE / "plat66-pack-mutation-results.txt"
TIMEOUT = 1800

S = "src/tests/scenarios"
# Subjects.
TUI_SCREEN = f"{S}/bindings/termassert/ct_tui_screen.nim"
TERM_BIND = f"{S}/bindings/termassert/ct_term_binding.nim"
PW_BIND = f"{S}/bindings/playwright/codetracer-binding.ts"
GUI_BIND = f"{S}/bindings/guiassert/ct_gui_binding.nim"
RESOLVER = f"{S}/resolver/ct_resolver.nim"
EXAMPLE = f"{S}/tracing/trace-macro-at-caret.yaml"

# The scenarios the arms are graded by.
REBOUND = f"{S}/tracing/trace-macro-rebound.yaml"
IDLE = f"{S}/tests/replay-idle-means-the-stop-is-shown.yaml"

SUBJECTS = [TUI_SCREEN, TERM_BIND, PW_BIND, GUI_BIND, RESOLVER, EXAMPLE]
SUITES = [REBOUND, IDLE, "ci/test/scenarios.sh"]

IN_TERMINAL = {TUI_SCREEN, TERM_BIND, RESOLVER}
IN_GPUI = {GUI_BIND, RESOLVER}

# (id, [(subject, find, replace), ...], [kill, ...], what it breaks)
# A kill is ("terminal"|"electron"|"gpui", scenario) or ("lint", "").
ARMS = [
    ("T1", [(TUI_SCREEN,
             '    let isCurrent = marker == "▸"',
             '    let isCurrent = marker == "▹"')],
     [("terminal", EXAMPLE)],
     "the terminal binding misreads the line the replay is stopped on"),
    ("T2", [(TUI_SCREEN,
             "    if reversed >= 1 and reversed <= 2:",
             "    if reversed >= 3:")],
     [("terminal", EXAMPLE)],
     "the terminal binding never sees the read-only editor's caret"),
    ("T3", [(TERM_BIND,
             "proc grid*(ctx: TermContext): ScreenGrid =\n"
             "  ## The screen as cells.",
             "var staleGrid: ScreenGrid\n"
             "proc grid*(ctx: TermContext): ScreenGrid =\n"
             "  ## The screen as cells.\n"
             "  if staleGrid.width > 0: return staleGrid\n"
             "  defer: staleGrid = result")],
     [("terminal", EXAMPLE)],
     "the terminal binding reads every property off the first screen it saw"),
    ("T4", [(TERM_BIND,
             '        some(top.contains("[ct]") and top.contains("tick: ") and top.contains("[PAUSED]") and',
             "        some(true or")],
     # at launch the terminal front-end draws the stop with its first frame;
     # a new session opened by the trace is where an early `replay-idle` shows
     [("terminal", IDLE), ("terminal", EXAMPLE)],
     "the terminal's replay-idle fires before the window shows the stop"),
    ("P1", [(PW_BIND,
             "        const current = highlightTops.some((t) => Math.abs(t - r.g.getBoundingClientRect().top) < 3);",
             "        const current = false;")],
     [("electron", EXAMPLE)],
     "the desktop binding never reads the line the replay is stopped on"),
    ("P2", [(PW_BIND,
             "        return !busy && loc.trim().length > 0;",
             "        return true;")],
     [("electron", IDLE)],
     "the desktop's replay-idle fires before the window shows the stop"),
    ("G1", [(GUI_BIND,
             "        if cr > 180 and cg > 120 and cb < 90 and cr - cb > 120:",
             "        if false:")],
     [("gpui", EXAMPLE)],
     "the GPUI binding never sees the execution pointer"),
    ("R1", [(RESOLVER,
             "    result.applyUserKeymap(parseUserKeymap(readFile(keybindingsJson)))",
             "    discard keybindingsJson")],
     [("terminal", REBOUND)],
     "the binding resolver ignores the user's keybindings.json"),
    ("R2", [(RESOLVER,
             "      keys[^1] = $last[0].toLowerAscii",
             "      keys[^1] = last")],
     [("terminal", EXAMPLE)],
     "the binding resolver sends the display form's capital (Shift+t)"),
    ("S1", [(EXAMPLE,
             "      - capture: { name: macro-trace-tab }",
             "      - use: plant-config\n"
             "        with: { file: keybindings.json, content: \"[]\" }\n"
             "      - capture: { name: macro-trace-tab }")],
     [("lint", "")],
     "a stage call smuggled into the user's example's steps"),
]

DECLARED_SURVIVORS = set()


def path_of(rel):
    return REPO / rel


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(path_of(rel))


def needle_scan():
    ok = True
    for arm_id, edits, _kills, _what in ARMS:
        for rel, find, _replace in edits:
            text = path_of(rel).read_text()
            n = text.count(find)
            if n != 1:
                print(f"  NEEDLE FAIL {arm_id}: found {n} times in {rel}")
                ok = False
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm.")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat66-pack-mutations.py — the subjects\n"
                "# AND the scenarios they are graded by. Refreshed with\n"
                "# --record-control-hashes, gated by the needle scan.\n")
        for rel in SUBJECTS + SUITES:
            f.write(f"{sha(rel)}  {rel}\n")
    print(f"recorded {len(SUBJECTS) + len(SUITES)} control digests")
    return 0


def controls_match():
    if not CONTROL.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        digest, rel = line.split("  ", 1)
        if sha(rel) != digest:
            print(f"CONTROL DIGEST MOVED: {rel}")
            ok = False
    return ok


def run(argv, env=None, timeout=TIMEOUT):
    try:
        p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                           timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, ""
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def build(part):
    rc, out = run(["bash", "ci/test/scenarios.sh", "build", part])
    if rc != 0:
        print(out[-2000:])
    return rc == 0


class Display:
    """A private Xvfb for the desktop's runs (2560x1440, 96 dpi)."""

    def __init__(self):
        self.proc = None
        self.name = ""

    def ensure(self):
        if self.proc is not None and self.proc.poll() is None:
            return self.name
        for n in range(150, 260):
            if not os.path.exists(f"/tmp/.X11-unix/X{n}") and \
                    not os.path.exists(f"/tmp/.X{n}-lock"):
                self.proc = subprocess.Popen(
                    ["Xvfb", f":{n}", "-screen", "0", "2560x1440x24", "-dpi", "96",
                     "-nolisten", "tcp"], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL)
                for _ in range(100):
                    if os.path.exists(f"/tmp/.X11-unix/X{n}"):
                        self.name = f":{n}"
                        return self.name
                    time.sleep(0.1)
                self.proc.kill()
        raise RuntimeError("no free display for Xvfb")

    def stop(self):
        if self.proc is not None:
            self.proc.kill()
            self.proc.wait()


DISPLAY = Display()


def run_scenario(flavour, scenario):
    """A scenario on a flavour: GREEN on exit 0; RED with the failed step."""
    env = dict(os.environ)
    if flavour == "electron":
        env["DISPLAY"] = DISPLAY.ensure()
    rc, out = run(["bash", "ci/test/scenarios.sh", "run", flavour, scenario], env=env)
    if rc == 124:
        return "HUNG", ""
    if rc == 0:
        return ("GREEN", "") if "\npassed" in "\n" + out else ("RAN-NOTHING", "")
    m = re.search(r"^failed: (step \S+) \(\w+\) failed: (.*)$", out, re.M)
    if m:
        # the step and the first clause of its message: stable across runs
        return "RED", f"{m.group(1)}: {m.group(2).split(';')[0].split(' (')[0][:160]}"
    if rc == 2:
        return "ERROR", out.strip().splitlines()[-1][:200] if out.strip() else ""
    return "RED", ""


def run_lint():
    rc, out = run(["bash", "ci/test/scenarios.sh", "lint"])
    if rc == 0:
        return "GREEN", ""
    m = re.search(r"error\[(L\d+)\]", out)
    return "RED", f"lint {m.group(1)}" if m else "lint failed"


def grade(kills):
    for flavour, scenario in kills:
        v, f = run_lint() if flavour == "lint" else run_scenario(flavour, scenario)
        if v != "GREEN":
            return v, f
    return "GREEN", ""


sys.path.insert(0, str(REPO / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main():
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    a = ap.parse_args()
    os.chdir(REPO)
    if a.needle_scan:
        return 0 if needle_scan() else 1
    if a.record_control_hashes:
        return record_controls()
    if not needle_scan() or not controls_match():
        print("the tree is not at the control bytes; nothing was mutated.")
        return 3
    only = set(filter(None, a.only.split(",")))
    selected = [arm for arm in ARMS if not only or arm[0] in only]
    try:
        for part in ("dvs", "stage", "terminal", "gpui", "playwright"):
            if not build(part):
                print(f"ABORT: the unmutated {part} does not build.")
                return 1
        kills = sorted({k for arm in selected for k in arm[2]})
        for k in kills:
            v, f = run_lint() if k[0] == "lint" else run_scenario(*k)
            if v != "GREEN":
                print(f"ABORT: the baseline {k} is {v}: {f}")
                return 1
        print(f"baseline GREEN ({len(kills)} run(s))", flush=True)
        because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
        digests = {rel: sha(rel) for rel in SUBJECTS}
        derived, bad, lines = {}, [], []
        for arm_id, edits, arm_kills, what in selected:
            files = sorted({rel for rel, _, _ in edits})
            backups = {}
            for rel in files:
                p = path_of(rel)
                backups[rel] = p.with_name(p.name + ".plat66bak")
                shutil.copy2(p, backups[rel])
            try:
                for rel, find, replace in edits:
                    p = path_of(rel)
                    p.write_text(p.read_text().replace(find, replace, 1))
                built = True
                if any(r in IN_TERMINAL for r in files):
                    built = build("terminal")
                if built and any(r in IN_GPUI for r in files):
                    built = build("gpui")
                verdict, first = grade(arm_kills) if built else ("DID-NOT-COMPILE", "")
            finally:
                for rel in files:
                    shutil.move(backups[rel], path_of(rel))
                    if sha(rel) != digests[rel]:
                        print(f"ABORT: restore of {rel} failed after {arm_id}.")
                        return 1
                if any(r in IN_TERMINAL for r in files):
                    build("terminal")
                if any(r in IN_GPUI for r in files):
                    build("gpui")
            derived[arm_id] = first
            if arm_id in DECLARED_SURVIVORS:
                ok = verdict == "GREEN"
                mark = "SURVIVED (declared)" if ok else f"MISDIRECTED ({verdict})"
            elif verdict == "RED":
                want = because.get(arm_id)
                ok = a.derive or want is None or want == first
                mark = "KILLED" if ok else f"KILLED BY THE WRONG CHECK: {first!r}"
            else:
                ok = False
                mark = verdict if verdict != "GREEN" else "SURVIVED — NOT ENFORCED"
            line = f"{arm_id:<4} {mark:<30} {what}\n       | {first}"
            print("  " + line, flush=True)
            lines.append(line)
            if not ok:
                bad.append(arm_id)
        if a.derive:
            merged = dict(because)
            merged.update(derived)
            BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
            print(f"derived {len(derived)} cause(s) into {BECAUSE.name}")
        if not only:
            head = subprocess.run(["git", "rev-parse", "--short=11", "HEAD"], cwd=REPO,
                                  capture_output=True, text=True).stdout.strip()
            RESULTS.write_text(
                f"# plat66 pack mutation results — {time.strftime('%Y-%m-%d %H:%M:%S %z')}\n"
                f"# measured against {head} (the subjects at the control digests)\n\n" +
                "\n".join(lines) + "\n")
        print(f"{len(selected) - len(bad)} of {len(selected)} arm(s) as required"
              + (f"; NOT: {', '.join(bad)}" if bad else ""))
        return 1 if bad else 0
    finally:
        DISPLAY.stop()


if __name__ == "__main__":
    sys.exit(main())
