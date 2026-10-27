#!/usr/bin/env python3
"""PLAT-70 Part H — the mutation harness for the scrollbars
(Scrollbar-Scrubbers.md §7).

Each arm plants ONE defect in the shared model (`scrollbar_interaction.nim`,
`layout_settings.nim`), the terminal's glyph table and painter
(`scrollbar_styles.nim`, `scrollbar_frame.nim`), the runtime's bar routing
(`runtime.nim`), or the GPUI window's grab (`list_scrubber.nim`); REBUILDS the
shipped `codetracer-tui` / `codetracer-gpui` when the defect is compiled into
a binary an arm is graded through; runs the suites that must catch it; and
requires RED — with the failure the first run recorded
(`plat70h-scrollbar-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-70 Part A's harness's (`run-plat70a-hscroll-
mutations.py`), clause for clause: committed control digests over subjects
AND suites, a needle scan that gates re-recording, `because` derived from a
run, rc 124 is a hang, per-arm restore verification, and
`ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT70H_BUILD_TUI` / `$PLAT70H_BUILD_GPUI` when set, else
the `just` recipes.

Usage:
    run-plat70h-scrollbar-mutations.py [--only G1,F1] [--derive]
    run-plat70h-scrollbar-mutations.py --needle-scan
    run-plat70h-scrollbar-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat70h-scrollbar-mutation-control.sha256"
BECAUSE = HERE / "plat70h-scrollbar-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70h-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
MODEL = "src/frontend/viewmodel/viewmodels/scrollbar_interaction.nim"
SETTINGS = "src/frontend/viewmodel/viewmodels/layout_settings.nim"
STYLES = "src/frontend/tui/app/views/scrollbar_styles.nim"
FRAME = "src/frontend/tui/app/views/scrollbar_frame.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
GPUI_LIST = "src/frontend/gpui/list_scrubber.nim"
SLIDERS = "src/frontend/tui/app/views/scrubber_track.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70h_scrollbar_model.nim"
TUI = "src/frontend/tui/tests/test_plat70h_scrollbars.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70h_scrollbars_pty.nim"
PLAN = "src/frontend/gpui/tests/test_m73_gpui_editor_scroll_plan.nim"

SUBJECTS = [MODEL, SETTINGS, STYLES, FRAME, RUNTIME, GPUI_LIST, SLIDERS]
SUITES = [VMU, TUI, PTY, PLAN]

EDITOR = "*::hover, grab, jump, page and hold on the editor's bar"
FADE = "*::SB-6: the bars fade out, then back in on a scroll, in steps"
EVERY = "*::SB-8: every pane with a bar answers hover and a paging press"
SWEEP = "*::glyphs, thumb cells, roles, the track and the ground, swept"
BYNAME = "*::§7.2 by name: each thickness's thumb and track"
PTY_FADE = "*::exact bytes: the fade goes out and back in through intermediate frames; never with fade off"
PTY_THICK = "*::`:set scrollbar-thickness thick` draws `▐` at rest and is remembered"
GRAB_PLAN = "*::PLAT-70 Part H: a held thumb keeps the point it was grabbed by"
SLIDER = "*::a slider's partial cells are foreground glyphs, not reversed cells"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared model ---------------------------------------------------
    ("G1", [(MODEL, "  m.dragTo(fraction - offset)",
             "  m.dragTo(fraction - m.thumbLength / 2.0)")],
     [(VMU, None), (TUI, EDITOR)],
     "SB-3: a held thumb re-centres itself on the pointer (the offset dropped)"),
    ("P1", [(MODEL, "  if dir == 0 or m.pageDirection(fraction) != dir:",
             "  if dir == 0:")],
     [(VMU, None)],
     "SB-4: a held page never stops at the pointer: it runs on to the end"),
    ("F1", [(MODEL, "    f.level = min(target, f.level + dt / float(FadeInMs))",
             "    f.level = target")],
     [(VMU, None), (PTY, PTY_FADE)],
     "SB-6: the fade-in is instant"),
    ("F3", [(MODEL, "    f.steppedMs = max(f.steppedMs, nowMs)",
             "    discard")],
     [(VMU, None), (TUI, FADE)],
     "SB-6: a pointer arriving between idle ticks is credited with the time since the last one: the fade-in is instant"),
    ("F2", [(MODEL, "    f.level = max(target, f.level - dt / float(FadeOutMs))",
             "    f.level = target")],
     [(VMU, None), (TUI, FADE)],
     "SB-6: the fade-out is instant"),
    ("D1", [(MODEL, "    thickness: btHairline, fade: true, track: false, click: tcJump,",
             "    thickness: btHairline, fade: true, track: false, click: tcPage,")],
     [(VMU, None), (TUI, EDITOR)],
     "§7.1: a left press on the track pages by default (the 2026-10-05 jump lost)"),
    ("K1", [(SETTINGS, "    result.add $which & \"=\" & s.valueText(which) & \"\\n\"",
             "    if which.isOnOff: result.add $which & \"=\" & s.valueText(which) & \"\\n\"")],
     [(VMU, None), (PTY, PTY_THICK)],
     "SB-7: a valued setting (the thickness) is forgotten when remembered"),
    # ---- the terminal's table and painter -----------------------------------
    ("B1", [(STYLES, "  let thumbStyle = CellStyle(role: o.thumbRole(state), faded: faded)",
             "  let thumbStyle = CellStyle(role: o.thumbRole(state), faded: faded,\n                              surface: srSurfaceSelection)")],
     [(TUI, SWEEP)],
     "SB-2: a thumb cell paints a ground of its own"),
    ("S1", [(STYLES, "        rest: look(AxisLook(thumb: halves(\"╹\", \"╻\", \"┃\", \"╿\", \"╽\"),",
             "        rest: look(AxisLook(thumb: halves(\"╹\", \"╻\", \"▐\", \"╿\", \"╽\"),")],
     [(TUI, BYNAME)],
     "§7.2: thin's thumb drawn as thick's"),
    ("S2", [(STYLES, "                              widened: look(FullClassicV, QuarterH)),",
             "                              widened: look(QuarterV, QuarterH)),")],
     [(TUI, BYNAME)],
     "§7.4: a thick thumb does not widen under the pointer"),
    ("U1", [(STYLES, "  if o.modernUnicode: gtModern else: gtClassic",
             "  gtClassic")],
     [(TUI, BYNAME)],
     "§7.2: modern-unicode ignored: thin stays `┃`"),
    ("U2", [(SLIDERS, "      elif modern:",
             "      elif false:")],
     [(TUI, SLIDER)],
     "§7.1: modern-unicode ignored by the position sliders (a reversed cell kept)"),
    ("H1", [(FRAME, "  if f.pointer.active and f.pointer.pane == pane and f.pointer.axis == axis:",
             "  if f.pointer.active and f.pointer.axis == axis:")],
     [(TUI, EVERY)],
     "SB-8: the hover is drawn on every pane's bar, not the one under the pointer"),
    # ---- the runtime ----------------------------------------------------------
    ("J1", [(RUNTIME, "                                   offset: bar.model.jumpGrabOffset)",
             "                                   offset: bar.model.jumpGrabOffset)\n      rt.scrollbars.grab.active = false")],
     [(TUI, EDITOR)],
     "§7.4: a jump does not continue as a grab of the thumb"),
    ("R1", [(RUNTIME, "    let rule = if event.button == mbLeft: o.click else: o.click.otherRule",
             "    let rule = o.click")],
     [(TUI, EDITOR)],
     "SB-4: the middle button does not do the other rule"),
    ("R2", [(RUNTIME, "      rt.scrollbars.paging.hold.start(f, dir, nowMs)",
             "      discard")],
     [(TUI, EDITOR)],
     "SB-4: a held paging press does not repeat"),
    ("W1", [(RUNTIME, "      rt.scrollbars.fades[b.pane].wake(rt.scrollbars.clockMs)",
             "      discard")],
     [(TUI, FADE)],
     "§7.5: a scroll does not wake its pane's faded bars"),
    # ---- GPUI -------------------------------------------------------------------
    ("G2", [(GPUI_LIST, "  fraction - (if barGrab.held: barGrab.offset else: sm.thumbLength / 2.0)",
             "  fraction - sm.thumbLength / 2.0")],
     [(PLAN, GRAB_PLAN)],
     "SB-3 (GPUI): a held thumb re-centres itself on the pointer"),
]

DECLARED_SURVIVORS = set()

IN_BINARY = {MODEL, SETTINGS, STYLES, FRAME, RUNTIME, SLIDERS}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {MODEL, SETTINGS, GPUI_LIST}
  # Subjects compiled into `codetracer-gpui`.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}


def path_of(rel):
    return REPO / rel


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(path_of(rel))


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    if suite == PTY:
        return lane_flags("tui-real-terminal")
    if suite.startswith("src/frontend/tui/"):
        return lane_flags("tui")
    if suite.startswith("src/frontend/gpui/"):
        return lane_flags("gpui-shell") + ["--path:src/frontend/viewmodel"]
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    for arm_id, edits, *_ in ARMS:
        for rel, find, _ in edits:
            text = path_of(rel).read_text()
            n = text.count(find)
            if n != 1:
                print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
                ok = False
                continue
            end = text.index(find) + len(find)
            if end < len(text) and text[end] not in "\r\n":
                print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
                ok = False
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat70h-hscroll-mutations.py — the\n"
                "# subjects AND the suites the arms are graded by (§16c).\n"
                "# Refreshed with --record-control-hashes, gated by the\n"
                "# needle scan (§39a).\n")
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


def build_with(env_var, recipe):
    cmd = os.environ.get(env_var)
    argv = ["bash", "-c", cmd] if cmd else ["just", recipe]
    p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                       timeout=TIMEOUT)
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-2000:])
    return p.returncode == 0


def build_binary():
    return build_with("PLAT70H_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70H_BUILD_GPUI", "build-gpui")


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the screen;
    the recorded cause keeps the condition and drops the snapshot."""
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def run_suite(suite, test_filter):
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + suite_flags(suite) + [suite]
    if test_filter:
        cmd.append(test_filter)
    try:
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [portable_cause(ln.strip().split("Check failed: ", 1)[1])
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        ran = out.count("[OK]")
        return ("GREEN", failures) if ran > 0 else ("RAN-NOTHING", [])
    # A base that does not hold together does not LOAD: the suite dies before
    # its first case, on the loader's own diagnostic — a kill by the
    # product's check, graded as one, on that line.
    refused = [ln.strip() for ln in out.splitlines()
               if "BaseRowError" in ln and "unhandled exception" in ln.lower()]
    if refused:
        return "RED", refused[:1]
    if not failures and "Error:" in out and "[FAILED]" not in out:
        return "DID-NOT-COMPILE", failures
    if not failures:
        failures = [portable_cause(ln.strip()) for ln in out.splitlines()
                    if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
    return "RED", failures


def grade(suites):
    first, verdict = "", "GREEN"
    for s, flt in suites:
        v, f = run_suite(s, flt)
        if v in ("HUNG", "DID-NOT-COMPILE", "RAN-NOTHING"):
            return v, ""
        if v == "RED":
            verdict = "RED"
            if not first and f:
                first = f[0]
    return verdict, first


sys.path.insert(0, str(REPO / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main():
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
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
    needs_binary = any(s in PTY_SUITES for arm in selected for s, _ in arm[2])
    needs_gpui = any(s in GPUI_SUITES for arm in selected for s, _ in arm[2])
    binary_digest = gpui_digest = None
    if needs_binary:
        if not build_binary():
            print("ABORT: the unmutated binary does not build.")
            return 1
        binary_digest = sha_path(BIN)
    if needs_gpui:
        if not build_gpui():
            print("ABORT: the unmutated GPUI binary does not build.")
            return 1
        gpui_digest = sha_path(GPUI_BIN)
    graded = sorted({(s, flt) for arm in selected for s, flt in arm[2]})
    for s, flt in graded:
        v, f = run_suite(s, flt)
        if v != "GREEN":
            print(f"ABORT: the baseline of {s} is {v}: {f[:1]}")
            return 1
    print(f"baseline GREEN ({len(graded)} suite run(s))")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, edits, suites, what in selected:
        files = sorted({rel for rel, _, _ in edits})
        backups = {}
        for rel in files:
            path = path_of(rel)
            backups[rel] = path.with_name(path.name + ".plat70hbak")
            shutil.copy2(path, backups[rel])
        try:
            for rel, find, replace in edits:
                path = path_of(rel)
                path.write_text(path.read_text().replace(find, replace, 1))
            built = True
            if any(s in PTY_SUITES for s, _ in suites) and \
                    any(r in IN_BINARY for r in files):
                built = build_binary()
            if built and any(s in GPUI_SUITES for s, _ in suites) and \
                    any(r in IN_GPUI for r in files):
                built = build_gpui()
            verdict, first = grade(suites) if built else ("DID-NOT-COMPILE", "")
        finally:
            for rel in files:
                shutil.move(backups[rel], path_of(rel))
                if sha(rel) != digests[rel]:
                    print(f"ABORT: restore of {rel} failed after {arm_id}.")
                    return 1
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
        print(f"  {arm_id:<4} {mark:<30} {what}", flush=True)
        if a.derive or not ok:
            print(f"       because: {first!r}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s)")
    if binary_digest is not None:
        if not build_binary() or sha_path(BIN) != binary_digest:
            print("FAIL: the binary rebuilt from the restored tree differs "
                  "from the one the run started with.")
            return 1
    if gpui_digest is not None:
        if not build_gpui() or sha_path(GPUI_BIN) != gpui_digest:
            print("FAIL: the GPUI binary rebuilt from the restored tree "
                  "differs from the one the run started with.")
            return 1
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
