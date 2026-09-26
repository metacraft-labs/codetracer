#!/usr/bin/env python3
"""run-plat3-vocabulary-mutations.py — PLAT-3's mutation harness: the view
vocabulary's cross-medium claim, on the terminal, on isonim's in-memory DOM
and in a real browser.

## WHY IT EXISTS NOW

PLAT-3 landed with fourteen mutations run BY HAND and recorded in prose. The
2026-09-26 completion pass added three things whose failure would be silent
without an arm aimed at each: the terminal binding's use of isonim-tui's new
`MenuWidget` and `TabsWidget(wraps = false)`, the web binding's browser
behaviour (the key handler, focus retention, `showModal()`, the guard against
the browser's own default actions), and the vocabulary's cluster-counted
`Input` caret with the web's Markdown renderer. Each is a repair that could
silently un-happen.

## THE MACHINERY IS PLAT-38's, REUSED

The lock, the needle scan (exactly one match per `find` and `control_find`,
controls ending at a line end, no quoted counts), the digest gate over every
subject AND every suite (§16c), the derived `because` (§17a), the verdicts and
the behaviour-preserving control per arm are `run-plat38-input-mutations.py`'s.
What is new is the THIRD SUITE KIND: `view_vocabulary_chromium_test.nim` is
compiled with `nim js` and run in headless Chromium by
`src/frontend/tests/chromium-run.mjs`, exactly as the `renderer-chromium` lane
runs it, and its `[OK]` / `[FAILED]` lines are read the same way.

Usage:
    run-plat3-vocabulary-mutations.py                      # grade every arm
    run-plat3-vocabulary-mutations.py --only W1,T2
    run-plat3-vocabulary-mutations.py --needle-scan
    run-plat3-vocabulary-mutations.py --derive
    run-plat3-vocabulary-mutations.py --record-control-hashes
"""

import argparse
import fcntl
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HARNESS_DIR = Path(__file__).resolve().parent

# --- subjects ---------------------------------------------------------------
TERMINAL = "src/frontend/view_vocabulary/terminal_binding.nim"
WEB = "src/frontend/view_vocabulary/web_binding.nim"
MARKDOWN = "src/common/view_vocabulary/markdown_blocks.nim"
BEHAVIOUR = "src/common/view_vocabulary/behaviour.nim"
MAPPINGS = "src/common/view_vocabulary/mappings.nim"

# --- the suites the arms are graded against ---------------------------------
CROSS = "src/frontend/tui/tests/test_view_vocabulary_cross_medium.nim"
VOCAB = "src/common/view_vocabulary_test.nim"
CHROME = "src/frontend/tests/view_vocabulary_chromium_test.nim"
# The shared script is not mutated and is in TOUCHED anyway: a change to the
# expectations invalidates every arm graded against them (§16c).
SCRIPT = "src/frontend/view_vocabulary/cross_medium_script.nim"

TOUCHED = [TERMINAL, WEB, MARKDOWN, BEHAVIOUR, MAPPINGS, CROSS, VOCAB, CHROME,
           SCRIPT]

CONTROL_HASHES = HARNESS_DIR / "plat3-vocabulary-mutation-control.sha256"
BECAUSE_FILE = HARNESS_DIR / "plat3-vocabulary-mutation-because.json"
LOCK_FILE = REPO / "build" / "plat3-vocabulary-mutations.lock"
NIMCACHE = REPO / "build" / "plat3mut"

COUNT_SPELLINGS = ["ExpectedAssertions", "ExpectedChecks", "CHECKS:"]


def lane_flags(lane: str) -> list[str]:
    """A lane's extra flags, read from `ci/lib/test-lane-files.sh` rather than
    copied — the `tui` lane's carry a grammar archive path per checkout."""
    out = subprocess.run(
        ["bash", "-c", f". ci/lib/test-lane-files.sh >/dev/null 2>&1; "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout
    return out.split()


SUITE_LANE = {CROSS: "tui", VOCAB: "common-units", CHROME: "renderer-chromium"}


@dataclass
class Arm:
    name: str
    path: str
    find: str
    replace: str
    suite: str
    kills: str
    control_find: str
    control_replace: str
    note: str


CTL = {
    TERMINAL: ("import isonim_tui/widgets/menu as w_menu",
               "import isonim_tui/widgets/menu as w_menu  # ctl"),
    WEB: ("import ./graphemes", "import ./graphemes  # ctl"),
    MARKDOWN: ("import std/strutils", "import std/strutils  # ctl"),
    BEHAVIOUR: ("import ./vocabulary", "import ./vocabulary  # ctl"),
    MAPPINGS: ("import ./vocabulary", "import ./vocabulary  # ctl"),
}

ARMS = [
    # ------------------------------------------------------------------
    # THE TERMINAL BINDING — isonim-tui's new parts, un-used
    # ------------------------------------------------------------------
    Arm("T1", TERMINAL,
        "activeIndex = max(v.selected, 0), wraps = false)",
        "activeIndex = max(v.selected, 0), wraps = true)",
        CROSS,
        "Tabs: both media stop at the ends — the divergence this suite found is closed",
        *CTL[TERMINAL],
        "THE DIVERGENCE COMES BACK. The library's default still wraps; the "
        "binding passing `wraps = false` is the whole repair."),
    Arm("T2", TERMINAL,
        "    if bw.menuW.isOpen:",
        "    if true:",
        CROSS,
        "Menu: Enter runs the command and closes, on both media",
        *CTL[TERMINAL],
        "A CLOSED MENU TAKES KEYS AGAIN. Its list is unmounted, so no "
        "reader's key can reach it; firing at it anyway moves a highlight "
        "the vocabulary (a closed Menu ignores every key) does not move."),
    Arm("T3", TERMINAL,
        '@[fact(bw.id, "text", bw.markdownW.source)]',
        '@[fact(bw.id, "text", "")]',
        CROSS,
        "Markdown: the two media make the same blocks of the same source",
        *CTL[TERMINAL],
        "THE MARKDOWN EXCLUSION COMES BACK. The widget keeps its source now; "
        "a binding that stopped reading it would report nothing."),
    # ------------------------------------------------------------------
    # THE VOCABULARY — the cluster caret and the web's Markdown parser
    # ------------------------------------------------------------------
    Arm("B1", BEHAVIOUR,
        "    v.cursor = clusterAtOrAfter(boundaries(v.text), at + ch.len)",
        "    v.cursor = v.cursor + 1",
        CROSS,
        "the shared script: every expected value, on both media, and agreement after every key",
        *CTL[BEHAVIOUR],
        "THE CARET ADVANCES PAST A COMBINING MARK. Typing U+0301 after `e` "
        "joins `e`'s cluster; a caret that moved on would sit inside one "
        "character on the web while isonim-tui's widget did not."),
    Arm("M1", MARKDOWN,
        "kind: (if need == 2: mskStrong else: mskEmphasis),",
        "kind: (if need == 2: mskEmphasis else: mskStrong),",
        VOCAB,
        "inline structure is spelled, not flattened away",
        *CTL[MARKDOWN],
        "STRONG AND EMPHASIS SWAP IN THE WEB'S PARSER. The parser's own case "
        "is the killer; the cross-medium Markdown case (T3's killer, so not "
        "this arm's, §17a) goes red on it too."),
    Arm("M2", MARKDOWN,
        "  (true, t[0], n, ind, info)",
        '  (true, t[0], n, ind, "")',
        VOCAB,
        "code, quotes and rules",
        *CTL[MARKDOWN],
        "THE FENCE'S INFO STRING IS DROPPED. The language of a code block is "
        "part of what the block IS; a parser that lost it would still render "
        "the code."),
    # ------------------------------------------------------------------
    # THE WEB BINDING, IN A REAL BROWSER
    # ------------------------------------------------------------------
    Arm("W1", WEB,
        "      elif b.guardsNative(id, name):",
        "      elif false and b.guardsNative(id, name):",
        CHROME,
        "scripted: Select: Escape does not commit what was passed over",
        *CTL[WEB],
        "THE BROWSER COMMITS BEHIND THE MODEL'S BACK. A closed <select> "
        "commits on Down; without the guard the page shows the second option "
        "while the model holds the first — the defect the browser suite "
        "found."),
    Arm("W2", WEB,
        "    focusEl[R, N](b.renderer, b.nodes[id])",
        "    discard",
        CHROME,
        "scripted: List: motion skips the unavailable member",
        *CTL[WEB],
        "FOCUS IS LOST ON EVERY RE-RENDER. A reader holding Down moves the "
        "list once and then presses keys at nothing."),
    Arm("W3", WEB,
        "          jsShowModal(el)",
        "          discard",
        CHROME,
        "an open Modal takes input until it is dismissed (showModal, inert page)",
        *CTL[WEB],
        "THE MODAL IS NOT MODAL. Without showModal() the page is not inert "
        "and a key aimed outside the dialog reaches its target."),
    Arm("W4", WEB,
        "      if ev.target != Node(el): return",
        "      discard",
        CHROME,
        "scripted: Tabs: Left and Right, stopping at both ends",
        *CTL[WEB],
        "A BUBBLED KEY IS ACTED ON BY AN ANCESTOR. Space on the tab strip "
        "reaches the Collapsible it sits in and collapses it."),
    Arm("W5", WEB,
        "  let o = applyKey(target, keyFromDom(keyName), graphemeBoundaries)",
        "  let o = applyKey(target, keyFromDom(keyName))",
        CHROME,
        "scripted: Input: a combining mark joins the character before it",
        *CTL[WEB],
        "THE WEB COUNTS RUNES AGAIN. The browser's caret moves over grapheme "
        "clusters; a model counting runes puts it inside one."),
    Arm("W6", WEB,
        '        of mskStrong: "strong"',
        '        of mskStrong: "em"',
        CHROME,
        "the binding renders into a real document, and the browser reads it the same way",
        *CTL[WEB],
        "STRONG IS DRAWN AS EMPHASIS. The parser is right and the rendering "
        "is not — only a reading of the ELEMENTS catches it."),
    Arm("W7", WEB,
        '    if v.checked: r.setAttribute(el, "checked", "")',
        "    discard",
        CHROME,
        "scripted: Checkbox and Toggle",
        *CTL[WEB],
        "THE DATA SAYS CHECKED AND THE CHECKBOX IS NOT. The `data-*` "
        "projection alone would agree with the twin; the browser's own "
        "`.checked` is what disagrees."),
    # ------------------------------------------------------------------
    # THE MAPPING TABLE — the grades the browser measured
    # ------------------------------------------------------------------
    Arm("G1", MAPPINGS,
        '  of pkCheckbox: m(msPartial, "<input type=\\"checkbox\\">",',
        '  of pkCheckbox: m(msComplete, "<input type=\\"checkbox\\">",',
        VOCAB,
        "the web is graded by what the browser does: seven complete, nine partial",
        *CTL[MAPPINGS],
        "THE OLD GRADE COMES BACK. A checkbox does not answer Enter in a "
        "browser; `msComplete` says it does."),
    Arm("G2", MAPPINGS,
        "  of pkTabs: m(msComplete,\n    \"isonim_tui.TabsWidget",
        "  of pkTabs: m(msPartial,\n    \"isonim_tui.TabsWidget",
        VOCAB,
        "the terminal is complete on all sixteen, and names what closed the two",
        *CTL[MAPPINGS],
        "A STATUS THAT OUTLIVES ITS MEASUREMENT. The divergence is closed; a "
        "table still calling the row partial would be this campaign's "
        "recorded defect."),
]


def take_lock():
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("ANOTHER RUN HOLDS THE LOCK (§16).")
        sys.exit(4)
    return fh


def digest(rel: str) -> str:
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def _ends_at_line_end(text: str, needle: str) -> tuple[bool, str]:
    at = text.find(needle)
    if at < 0:
        return False, ""
    nl = text.find("\n", at + len(needle))
    rest = text[at + len(needle):nl if nl >= 0 else len(text)]
    return rest.strip() == "", rest


def needle_scan() -> list[str]:
    bad: list[str] = []
    for rel in sorted({a.path for a in ARMS} | set(SUITE_LANE)):
        if not (REPO / rel).exists():
            bad.append(f"subject {rel} is not in the tree")
    if bad:
        return bad
    for arm in ARMS:
        text = (REPO / arm.path).read_text()
        for label, needle in (("find", arm.find),
                              ("control_find", arm.control_find)):
            n = text.count(needle)
            if n != 1:
                bad.append(f"{arm.name}.{label}: occurs {n} time(s) in "
                           f"{arm.path}, expected exactly 1")
                continue
            for spelling in COUNT_SPELLINGS:
                if spelling in needle:
                    bad.append(f"{arm.name}.{label}: quotes '{spelling}' "
                               f"(§10.3)")
            if label == "control_find":
                ok, rest = _ends_at_line_end(text, needle)
                if not ok:
                    bad.append(f"{arm.name}.control_find: does not end at a "
                               f"line end; the rest is {rest!r}")
        # The browser suite names its scripted cases "scripted: <name>", with
        # <name> from the shared script, so that is where those are looked up.
        suite_text = (REPO / arm.suite).read_text()
        if arm.kills.startswith("scripted: "):
            found = (f'name: "{arm.kills[len("scripted: "):]}"'
                     in (REPO / SCRIPT).read_text())
        else:
            found = arm.kills in suite_text
        if not found:
            bad.append(f"{arm.name}: its killer '{arm.kills}' is not a case "
                       f"name in {arm.suite}")
    names = [a.name for a in ARMS]
    if len(set(names)) != len(names):
        bad.append("two arms share a name")
    kills = [a.kills for a in ARMS]
    if len(set(kills)) != len(kills):
        bad.append("two arms name the same killer case (§17a)")
    return bad


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN FAILED:")
        for b in bad:
            print("  " + b)
        return 2
    print(f"needle scan: {len(ARMS)} arm(s), every `find` and `control_find` "
          f"matches once, controls end at a line end, no count is quoted, "
          f"and every killer is a case in its suite")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        want, rel = line.split(None, 1)
        recorded[rel.strip()] = want
    ok = True
    for rel in sorted(set(recorded) | set(TOUCHED)):
        if rel not in recorded:
            print(f"CONTROL DIGEST ABSENT: {rel}")
            ok = False
        elif rel not in TOUCHED:
            print(f"CONTROL DIGEST STALE: {rel}")
            ok = False
        elif digest(rel) != recorded[rel]:
            print(f"CONTROL DIGEST MOVED: {rel} — the tree is not at the "
                  f"control bytes; nothing was mutated.")
            ok = False
    return ok


CONTROL_HEADER = """\
# Control digests for run-plat3-vocabulary-mutations.py.
#
# The bytes every arm restores to and every verdict was taken against: the
# five mutation subjects, the three suites the arms are graded by, and the
# shared script whose expectations two of those suites replay (§16c).
# Refreshed with --record-control-hashes, which the needle scan GATES (§16).
"""


def write_control_hashes():
    lines = [f"{digest(rel)}  {rel}" for rel in TOUCHED]
    CONTROL_HASHES.write_text(CONTROL_HEADER + "\n".join(lines) + "\n")
    print(f"recorded {len(lines)} control digest(s)")


def run_suite(suite: str) -> tuple[int, str]:
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    flags = lane_flags(SUITE_LANE[suite])
    if suite == CHROME:
        js = f"{NIMCACHE}/{stem}.js"
        c = subprocess.run(["nim", "js", "--hints:off", "--warnings:off",
                            f"--nimcache:{NIMCACHE}/{stem}", f"-o:{js}"]
                           + flags + [suite],
                           cwd=REPO, capture_output=True, text=True,
                           timeout=3600)
        if c.returncode != 0:
            return c.returncode, c.stdout + c.stderr
        p = subprocess.run(["node", "src/frontend/tests/chromium-run.mjs", js],
                           cwd=REPO, capture_output=True, text=True,
                           timeout=1800)
        return p.returncode, c.stdout + c.stderr + p.stdout + p.stderr
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + flags + [suite]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       timeout=7200)
    return p.returncode, p.stdout + p.stderr


def failure_lines_for(out: str, case: str) -> list[str]:
    block: list[str] = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK]") or s.startswith("[FAILED]"):
            if s.split("] ", 1)[-1] == case:
                return block
            block = []
            continue
        block.append(s)
    return []


def verdict_for(out: str, case: str) -> str | None:
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK] ") and s[5:] == case:
            return "OK"
        if s.startswith("[FAILED] ") and s[9:] == case:
            return "FAILED"
    return None


def apply_patch(rel: str, find: str, replace: str):
    path = REPO / rel
    text = path.read_text()
    assert text.count(find) == 1, f"needle not unique in {rel}"
    path.write_text(text.replace(find, replace, 1))


def load_because() -> dict:
    if BECAUSE_FILE.exists():
        return json.loads(BECAUSE_FILE.read_text())
    return {}


def first_check(lines: list[str]) -> str:
    checks = [ln[ln.index("Check failed:"):] for ln in lines
              if "Check failed:" in ln]
    if not checks:
        checks = [ln for ln in lines if ln.strip()]
    return re.sub(r"\s+", " ", checks[0]).strip() if checks else ""


def derive(selected: list[Arm]) -> int:
    derived = {}
    for arm in selected:
        original = (REPO / arm.path).read_text()
        try:
            apply_patch(arm.path, arm.find, arm.replace)
            _, out = run_suite(arm.suite)
        finally:
            (REPO / arm.path).write_text(original)
        text = first_check(failure_lines_for(out, arm.kills))
        # A browser-suite check line carries the run's detail after `--`;
        # the `because` is the assertion, which is stable across runs.
        text = text.split("  -- ")[0].split(" -- ")[0]
        if not text:
            print(f"{arm.name}: no failure recorded for '{arm.kills}' "
                  f"(verdict {verdict_for(out, arm.kills)}) — cannot derive")
            continue
        for spelling in COUNT_SPELLINGS:
            if spelling in text:
                print(f"{arm.name}: derived `because` quotes '{spelling}'")
                return 2
        derived[arm.name] = text
        print(f"{arm.name}: because = {text}")
    existing = load_because()
    existing.update(derived)
    BECAUSE_FILE.write_text(json.dumps(existing, indent=2, sort_keys=True)
                            + "\n")
    print(f"wrote {len(derived)} derived `because` string(s)")
    return 0 if len(derived) == len(selected) else 1


def grade(selected: list[Arm]) -> int:
    because = load_because()
    missing = [a.name for a in selected if a.name not in because]
    if missing:
        print(f"REFUSED: no derived `because` for {', '.join(missing)}; "
              f"run --derive first (§17a).")
        return 2
    results = []
    for arm in selected:
        original = (REPO / arm.path).read_text()
        before = hashlib.sha256(original.encode()).hexdigest()
        try:
            apply_patch(arm.path, arm.find, arm.replace)
            _, out = run_suite(arm.suite)
        finally:
            (REPO / arm.path).write_text(original)
        if digest(arm.path) != before:
            results.append((arm, "HARNESS-FAILURE", "revert"))
            continue
        v = verdict_for(out, arm.kills)
        if v is None:
            results.append((arm, "NO-VERDICT-FOR-KILLER",
                            "did it compile?"))
            continue
        if v == "OK":
            results.append((arm, "SURVIVED", ""))
            continue
        lines = " ".join(ln[ln.index("Check failed:"):]
                         if "Check failed:" in ln else ln
                         for ln in failure_lines_for(out, arm.kills))
        if because[arm.name] not in re.sub(r"\s+", " ", lines):
            results.append((arm, "MIS-ATTRIBUTED",
                            f"expected: {because[arm.name]}"))
            continue
        try:
            apply_patch(arm.path, arm.control_find, arm.control_replace)
            _, cout = run_suite(arm.suite)
        finally:
            (REPO / arm.path).write_text(original)
        if digest(arm.path) != before:
            results.append((arm, "HARNESS-FAILURE", "control revert"))
            continue
        if verdict_for(cout, arm.kills) != "OK":
            results.append((arm, "CONTROL-HARNESS-FAILURE",
                            "the behaviour-preserving control reddened the "
                            "killer"))
            continue
        results.append((arm, "KILLED", ""))
    print()
    print("| arm | subject | suite | verdict | note |")
    print("|-----|---------|-------|---------|------|")
    for arm, verdict, note in results:
        print(f"| {arm.name} | {Path(arm.path).name} | "
              f"{Path(arm.suite).name} | **{verdict}** | {note} |")
    killed = sum(1 for _, v, _ in results if v == "KILLED")
    print()
    print(f"{killed} of {len(results)} KILLED")
    return 0 if killed == len(results) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    fh = take_lock()
    assert fh is not None
    if args.needle_scan:
        return report_needle_scan()
    if args.record_control_hashes:
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        return 0
    rc = report_needle_scan()
    if rc:
        return rc
    if not check_control_hashes():
        return 3
    selected = ARMS
    if args.only:
        want = {s.strip() for s in args.only.split(",")}
        selected = [a for a in ARMS if a.name in want]
        if not selected:
            print(f"no arm matches {args.only}")
            return 2
    if args.derive:
        return derive(selected)
    return grade(selected)


if __name__ == "__main__":
    sys.exit(main())
