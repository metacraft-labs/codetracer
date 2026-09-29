#!/usr/bin/env python3
"""PLAT-46 — the mutation harness for the terminal painted from the design system.

Each arm plants ONE defect in the role→token binding, the generator, the
shell's surface fills, the start-up probe or the tier derivation, runs the
suite or gate that must catch it, and requires it to go RED **with the failure
it went red with the first time** (the `because`, derived from a run and
committed in `plat46-design-mutation-because.json`). The verification gate's
five named classes are all here:

  * pointing a role at a different token      — T1, T2, T3
  * hand-writing a hex / an ANSI name          — H1, H2 (the source gate)
  * dropping a surface fill                    — S1, S3 (Tier 1), S4 (Tier 2:
                                                 the SHIPPED binary, rebuilt,
                                                 read back through libvterm)
  * ignoring a positive probe                  — P1–P4
  * `:theme` not re-pinning the mode           — P5 (Tier 2, the shipped
                                                 binary, typed at live)
  * deriving a rung from a stale table         — D1–D3
  * and the generator itself                   — G1, G2 (the freshness gate)

THE DISCIPLINE, inherited from the harnesses before it (run-plat43-…):

  * CONTROL DIGESTS ARE COMMITTED (`plat46-design-mutation-control.sha256`) and
    cover the SUBJECTS **and** the SUITES the arms are graded by (§16c).
  * THE NEEDLE SCAN GATES RE-RECORDING (§39a).
  * `because` IS DERIVED FROM A RUN (`--derive`), never typed from intent. For
    a SHELL gate the `because` is its first `FAIL`/`STALE` line.
  * rc 124 IS A HANG, NOT A KILL (§1).
  * RESTORE IS VERIFIED PER ARM; a failed restore aborts the run. An arm graded
    against the binary REBUILDS it after the restore too, so the next arm and
    the next lane see the product, not the mutant.
  * ONE DECLARED SURVIVOR, behaviour-preserving (N1).

Run it with REPLAY_SERVER_BIN exported (the Tier-2 arm spawns the shipped
binary on a real recording).

Usage:
    run-plat46-design-mutations.py                  # grade every arm
    run-plat46-design-mutations.py --only T1,S4
    run-plat46-design-mutations.py --needle-scan
    run-plat46-design-mutations.py --derive
    run-plat46-design-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat46-design-mutation-control.sha256"
BECAUSE = HERE / "plat46-design-mutation-because.json"
NIMCACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "plat46-mutations"
TIMEOUT = 3600

ROLES = "src/frontend/tui/app/theme/roles.nim"
PALETTE = "src/frontend/tui/app/theme/palette.nim"
CAPS = "src/frontend/tui/app/theme/capabilities.nim"
MATH = "src/frontend/tui/app/theme/colour_math.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
GUTTER = "src/frontend/tui/app/views/gutter.nim"
SOURCE = "src/frontend/tui/app/views/source_pane.nim"
PROBE = "src/frontend/tui/host/terminal_probe.nim"
GENERATOR = "scripts/tokens-to-styl.sh"

TABLES = "src/frontend/tui/app/tests/test_degraded_style_tables.nim"
RESOLUTION = "src/frontend/tui/app/tests/test_capability_resolution.nim"
PROBE_SUITE = "src/frontend/tui/tests/test_plat46_terminal_probe.nim"
TIER2 = "src/frontend/tui/tests/real_terminal/test_plat46_design_tokens.nim"
SOURCE_GATE = "ci/test/tui-design-tokens-boundary.sh"
FRESH_GATE = "ci/test/design-tokens-fresh.sh"

SUBJECTS = [ROLES, PALETTE, CAPS, MATH, SHELL, GUTTER, SOURCE, PROBE, GENERATOR]
SUITES = [TABLES, RESOLUTION, PROBE_SUITE, TIER2, SOURCE_GATE, FRESH_GATE]
BINARY_SUITES = {TIER2}
TIER2_FILTER = "token fidelity and surfaces, read back, in the dark mode"
  # The one Tier-2 case a binary arm is graded by, so the arm costs one
  # screen rather than the whole suite…
TIER2_FILTERS = {"P5": ":theme switches the design-system mode on a live session",
                 # S4: the editor's fill is visible in the LIGHT mode, where the
                 # editor's measured ground (the desktop's) is not the panel.
                 "S4": "token fidelity and surfaces, read back, in the light mode"}
  # …unless the arm names its own.

# (id, subject, find, replace, suite, what it breaks)
ARMS = [
    ("T1", ROLES,
     "    srSyntaxKeyword: fgOnly(dgSyntax, tokenClassToken(tcKeyword),",
     "    srSyntaxKeyword: fgOnly(dgSyntax, tokenClassToken(tcString),",
     TABLES, "the keyword role points at the string token"),
    ("T2", ROLES,
     "    srBorderPane: fgOnly(dgBorder, dtColorsUiBorderSecondary),",
     "    srBorderPane: fgOnly(dgBorder, dtColorsUiBorderPrimary),",
     TABLES, "the pane border points at another border tier"),
    ("T3", ROLES,
     "                      dtColorsUiSurfaceBasePanel, attrs = {raBold},",
     "                      dtColorsUiSurfacePrimaryDefault, attrs = {raBold},",
     TABLES, "the active tab is no longer lifted onto the pane's surface"),
    ("H1", GUTTER,
     "  BreakpointStyle* = CellStyle(role: srGutterBreakpoint)",
     "  BreakpointStyle* = CellStyle(fg: \"#ff5555\")",
     SOURCE_GATE, "a view hand-writes a hex instead of naming a role"),
    ("H2", SOURCE,
     "    tcKeyword: CellStyle(role: srSyntaxKeyword),",
     "    tcKeyword: CellStyle(fg: \"magenta\", bold: true),",
     SOURCE_GATE, "a view paints an ANSI name again"),
    ("S1", SHELL,
     "  g.fillSurface(full.row, full.col, full.width, full.height, srSurfacePanel)",
     "  discard", TABLES, "panes are no longer filled with the panel surface"),
    ("S3", SHELL,
     "    g.restyleRole(row, start, w, srTabBar, tabRole)",
     "    discard", TABLES, "tabs lose their active/inactive roles"),
    ("S4", SHELL,
     "    g.fillSurface(a.row + 1, a.col, inner, a.height - 1, srSurfaceEditor)",
     "    discard", TIER2,
     "the editor body is no longer filled with the editor surface (read back "
     "off the shipped binary)"),
    ("P1", CAPS, "    if probe.truecolor:", "    if false:", RESOLUTION,
     "a positive 24-bit answer is ignored"),
    ("P2", CAPS, "  if probe.hasBackground:", "  if false:", RESOLUTION,
     "the terminal's OSC 11 background is ignored"),
    ("P3", PROBE,
     "       (token.contains(\":1:2:3\") or token.contains(\";1;2;3\")):",
     "       false:", PROBE_SUITE,
     "a DECRQSS answer that kept the 24-bit colour is not recognised"),
    ("P4", PROBE, "      probe.hasBackground = true", "      discard",
     PROBE_SUITE, "an OSC 11 answer is parsed and dropped"),
    ("P5", PROBE, "  n.flags.themePinned = true", "  discard", TIER2,
     "`:theme` on a live session does not pin the mode it names (read back "
     "off the shipped binary)"),
    ("D1", PALETTE,
     "    result.fg256 = indexedSpelling(nearestXterm256(c))",
     "    result.fg256 = indexedSpelling(212)", TABLES,
     "the 256-colour rung is a fixed table rather than derived from the token"),
    ("D2", PALETTE,
     "    result.fg16 = AnsiNames[nearestAnsi16Family(c)]",
     "    result.fg16 = \"white\"", TABLES,
     "the 16-colour rung is a fixed answer rather than derived"),
    ("D3", PALETTE,
     "    result.bgTerm = if s.baseSurface: \"\" else: AnsiNames[nearestAnsi16Family(c)]",
     "    result.bgTerm = AnsiNames[nearestAnsi16Family(c)]", TABLES,
     "--palette=terminal paints region surfaces instead of the terminal's own"),
    ("G1", GENERATOR, "        return value.strip().lower()",
     "        return value.strip().upper()", FRESH_GATE,
     "the Nim emitter's output drifts from what is committed"),
    ("G2", GENERATOR, "    lines.append(f\"// Source layer: {title}\")",
     "    lines.append(f\"// Layer: {title}\")", FRESH_GATE,
     "the stylus emitter's output drifts from what is committed"),
    ("N1", MATH, "  (max(a, b) + 0.05) / (min(a, b) + 0.05)",
     "  (max(b, a) + 0.05) / (min(b, a) + 0.05)", TABLES,
     "behaviour-preserving: the DECLARED SURVIVOR"),
]

UNGRADED: set = set()
DECLARED_SURVIVORS = {"N1"}
  # S4 is NOT a survivor. In the dark mode the editor's ground and text ARE
  # the pane's surface and body text (#282828 / #f3f3f3 both), so dropping the
  # editor fill changes no dark cell — but the light mode's editor is the
  # desktop's measured light editor, on #282828, which the light panel is
  # not. S4 is therefore graded by the light case (`TIER2_FILTERS`).


def sha(rel):
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def graded():
    return [a for a in ARMS if a[0] not in UNGRADED]


def lane_flags(lane):
    out = subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout
    return out.split()


def needle_scan():
    ok = True
    for arm_id, rel, find, _, _, _ in graded():
        text = (REPO / rel).read_text()
        n = text.count(find)
        if n != 1:
            print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
            ok = False
            continue
        end = text.index(find) + len(find)
        if end < len(text) and text[end] not in "\r\n":
            print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
            ok = False
    print(f"needle scan: {len(graded())} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat46-design-mutations.py —\n"
                "# the subjects AND the suites the arms are graded by (§16c).\n"
                "# Refreshed with --record-control-hashes, gated by the needle\n"
                "# scan (§39a).\n")
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


def build_binary():
    p = subprocess.run(["just", "build-tui"], cwd=REPO, capture_output=True,
                       text=True, timeout=TIMEOUT)
    return p.returncode == 0, (p.stdout or "") + (p.stderr or "")


def run_suite(suite, arm_id=""):
    if suite.endswith(".sh"):
        try:
            p = subprocess.run(["bash", suite], cwd=REPO, capture_output=True,
                               text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return "HUNG", []
        out = (p.stdout or "") + (p.stderr or "")
        failures = [ln.strip() for ln in out.splitlines()
                    if ln.startswith("FAIL") or ln.startswith("STALE")]
        return ("GREEN" if p.returncode == 0 else "RED"), failures
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    lane = "tui-real-terminal" if "/real_terminal/" in suite else "tui"
    cmd = ["nim", "c", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}", f"-o:{NIMCACHE}/{stem}.out"] + \
        lane_flags(lane) + [suite]
    try:
        c = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT)
        if c.returncode != 0:
            return "DID-NOT-COMPILE", []
        args = [str(NIMCACHE / f"{stem}.out")]
        if suite in BINARY_SUITES:
            args += ["the binary and the fixture exist",
                     TIER2_FILTERS.get(arm_id, TIER2_FILTER)]
        p = subprocess.run(args, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [ln.strip().split("Check failed: ", 1)[1]
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        return "GREEN", failures
    return "RED", failures


def apply(rel, find, replace):
    path = REPO / rel
    backup = path.with_suffix(path.suffix + ".plat46bak")
    shutil.copy2(path, backup)
    path.write_text(path.read_text().replace(find, replace, 1))
    return backup


def restore(rel, backup, digest):
    shutil.move(backup, REPO / rel)
    return sha(rel) == digest


def main():
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
    arms = [x for x in graded() if not only or x[0] in only]
    needed = {x[4] for x in arms}
    if needed & BINARY_SUITES:
        built, log = build_binary()
        if not built:
            print("ABORT: the product binary does not build:\n" + log[-2000:])
            return 1
    for suite in SUITES:
        if suite not in needed:
            continue
        verdict, fails = run_suite(suite)
        if verdict != "GREEN":
            print(f"ABORT: baseline {suite} is {verdict}: {fails[:3]}")
            return 1
    print(f"baseline GREEN ({len(needed)} suite(s)/gate(s))")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, rel, find, replace, suite, what in arms:
        backup = apply(rel, find, replace)
        try:
            if suite in BINARY_SUITES:
                built, _ = build_binary()
                verdict, failures = (run_suite(suite, arm_id) if built
                                     else ("DID-NOT-COMPILE", []))
            else:
                verdict, failures = run_suite(suite)
        finally:
            restored = restore(rel, backup, digests[rel])
            if suite in BINARY_SUITES:
                rebuilt, _ = build_binary()
                restored = restored and rebuilt
            if not restored:
                print(f"ABORT: restore of {rel} failed after {arm_id}.")
                return 1
        first = failures[0] if failures else ""
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
        print(f"  {arm_id:<4} {mark:<30} {what}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s) into {BECAUSE.name}")
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
