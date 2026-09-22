#!/usr/bin/env python3
"""run-plat38-input-mutations.py — PLAT-38's mutation harness: key delivery,
the attribute round trip, and element focus.

## THE MACHINERY IS PLAT-35's AND PLAT-37's, REUSED RATHER THAN RE-DERIVED

The lock, the needle scan, the digest gate, the derived `because`, the
verdicts and the behaviour-preserving control per arm are
`run-plat37-window-mutations.py`'s, unchanged in shape. A second harness
IMPLEMENTATION is Verification-Harness-Traps §14 one level up, and §14a is the
entry about what re-derivation costs. What is new here is the SUBJECTS and the
ARMS; the engine is the campaign's one engine.

**IT CARRIES `CONTROL_HASHES` AND `plat38-input-mutation-control.sha256` FROM
ITS FIRST COMMIT.** §39 is open because three harnesses never had one, and a
new harness joining them is a deliberate act. This one does not join them.

## WHAT THE ARMS ARE AIMED AT, AND THE THREE FAMILIES

  **ARMS OVER THE RECORD** (`R1`..`R4`) corrupt the compositor evidence in the
  exact shapes a broken delivery produces: a scenario that delivered nothing
  reported as delivered, a modifier dropped on the wire, a negative twin that
  received the key it was supposed to be refused, and a vision witness whose
  blank control clears the threshold it exists to fail. These are aimed at the
  GATE'S READERS, which is where §4 lives.

  **ARMS OVER THE BINDING** (`B1`..`B4`) corrupt the key transport, the
  keystroke vocabulary, the focus declaration and the modal's focus trap.
  These are the code PLAT-38 wrote, and every one of them is a repair that
  could silently un-happen.

  **ARMS OVER THE REGISTER AND THE SCAN** (`G1`..`G3`) corrupt the retirement
  bookkeeping and the `vockey:` scan's own instruments: a retired gap put back
  in the filed register, the scan's subject set emptied, and the needle it
  derives made empty. An absence check whose scan matches nothing satisfies
  every claim written over it (§4), so the scan's own controls are armed.

**EVERY ARM IS GRADED WITH `PLAT38_CORPUS` PINNED.** Without it the harness
would grade against whichever record happened to be on the disk — the live one
on a workstation that has just captured, the recorded one in CI — and an arm
that corrupted the recorded file would SURVIVE on the workstation for a reason
that has nothing to do with the gate. §18's second corollary arriving through
an environment variable.

## §10.3 — NO MUTATION ARM MAY QUOTE A COUNT

Inherited from PLAT-35 and PLAT-37 unchanged, and applied to the PUBLISHED
rule rather than to PLAT-36's narrowing of it. `Editor-Model-Conformance-
Suite.md` §10.3 forbids a needle containing `ExpectedAssertions`, `CHECKS:`,
"or any of their values"; PLAT-36 narrowed the VALUE half in its own harness
and the published rule still reads unnarrowed. This harness follows the
published rule: no arm's `find` carries a digit sequence that also appears in
a declared count constant. No collision was measured while writing it, so
there was nothing to weigh the narrowing against.

Usage:
    run-plat38-input-mutations.py                      # grade every arm
    run-plat38-input-mutations.py --only B1,G3
    run-plat38-input-mutations.py --needle-scan
    run-plat38-input-mutations.py --derive
    run-plat38-input-mutations.py --record-control-hashes
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HARNESS_DIR = Path(__file__).resolve().parent

# --- subjects ---------------------------------------------------------------
RECORD = "src/tests/visual/plat38-keystrokes.json"
BINDING = "src/frontend/view_vocabulary/gpui_binding.nim"
GAPS = "src/common/view_vocabulary/gpui_gaps.nim"
KEYS = "src/frontend/gpui/tests/plat38_keys.nim"

# --- the suite the arms are graded against ----------------------------------
# §16c: this is NOT a mutation subject and it is in TOUCHED anyway, because a
# change that touches only the suite invalidates every arm graded against it
# while producing no overlap signal at all in a harness whose TOUCHED names
# subjects only.
SUITE = "src/frontend/gpui/tests/test_gpui_key_delivery.nim"

TOUCHED = [RECORD, BINDING, GAPS, KEYS, SUITE]

CONTROL_HASHES = HARNESS_DIR / "plat38-input-mutation-control.sha256"
BECAUSE_FILE = HARNESS_DIR / "plat38-input-mutation-because.json"
LOCK_FILE = REPO / "build" / "plat38-input-mutations.lock"
NIMCACHE = REPO / "build" / "plat38mut"

# The `gpui-shell` lane's flags, from `ci/lib/test-lane-files.sh`.
SUITE_CMD = {SUITE: ["--path:src/frontend/viewmodel",
                     "--path:../GuiAssert/src"]}


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
    corpus: str = "recorded"
    because: str = ""
    extra_kills: list = field(default_factory=list)


# ONE control fragment per subject, appended to rather than invented per arm: a
# behaviour-preserving control is a second quotation of the same file, and one
# shared spelling per file is one thing to keep aimed instead of eleven. Each
# ends AT A LINE END, which the needle scan enforces.
CTL = {
    RECORD: ('"scenarios": [', '"_ctl": 0,\n "scenarios": ['),
    BINDING: ("func gpuiKeystroke*(k: Key; ch: string = \"\"): GpuiKeystroke =",
              "func gpuiKeystroke*(k: Key; ch: string = \"\"): GpuiKeystroke =  ## ctl"),
    GAPS: ("func gapsFor*(k: ViewKind): seq[GpuiGap] =",
           "func gapsFor*(k: ViewKind): seq[GpuiGap] =  ## ctl"),
    KEYS: ("proc bindingDirectory*(): string =",
           "proc bindingDirectory*(): string =  ## ctl"),
}


ARMS = [
    # ------------------------------------------------------------------
    # THE RECORD — the shapes a broken compositor delivery produces
    # ------------------------------------------------------------------
    Arm("R1", RECORD,
        '"arrivals": [',
        '"_mutatedArrivals": [',
        SUITE,
        "scenario 0: a wl_seat key reached the store",
        CTL[RECORD][0], CTL[RECORD][1],
        "THE FIRST SCENARIO RECORDS NO ARRIVALS AT ALL. A reader that "
        "invented an empty list for a missing key would make every assertion "
        "written over `arrivals` true for free — §4 arriving through a "
        "parser's default. The needle is the FIRST `\"arrivals\": [` in the "
        "record, which is `entry-shell`'s, so the arm lands on one scenario "
        "rather than all six; an arm that emptied every row would be killed "
        "by whichever case ran first and would say nothing about which."),

    Arm("R2", RECORD,
        '"modifiers": [\n      "shift"\n     ]',
        '"modifiers": []',
        SUITE,
        "scenario 1: a wl_seat key reached the store",
        CTL[RECORD][0], CTL[RECORD][1],
        "THE MODIFIER IS DROPPED ON THE WIRE. §25 performed rather than "
        "cited: an input helper that silently drops a modifier it cannot "
        "spell hands you a test about a DIFFERENT KEY, and this workspace "
        "has already paid for that once (`TermAssert.sendKey` consumed "
        "`shift+` and forgot it). The scenario that sends `Shift+F10` is the "
        "one this lands on, and it lands because the assertion is on the "
        "modifier BY NAME rather than on the key alone."),

    Arm("R3", RECORD,
        '"deliverySeq": 0,\n  "deliveryCount": 0\n }',
        '"deliverySeq": 7,\n  "deliveryCount": 1\n }',
        SUITE,
        "THE NEGATIVE TWIN — the same key with the window unfocused changes nothing",
        CTL[RECORD][0], CTL[RECORD][1],
        "THE NEGATIVE TWIN RECEIVES THE KEY IT WAS SUPPOSED TO BE REFUSED. "
        "*'The key arrived' is true of a binding that dispatches to "
        "everything*, and the twin is the only thing in this record that can "
        "tell routing from broadcasting. An arm that could not kill it would "
        "mean the twin was decoration."),

    Arm("R4", RECORD,
        '"blankNonBlank": false',
        '"blankNonBlank": true',
        SUITE,
        "THE BLANK CONTROL — a control that has never failed is not a control",
        CTL[RECORD][0], CTL[RECORD][1],
        "THE BLANK CONTROL IS NOT BLANK. §7b: an unfalsified negative "
        "control is a self-comparison wearing a negation. If the frame the "
        "vision witness compares against were itself painted, 'the screen "
        "changed' would be a claim about two pictures of the same thing."),

    # ------------------------------------------------------------------
    # THE BINDING — the repairs, un-happening
    # ------------------------------------------------------------------
    Arm("B1", BINDING,
        "b.renderer.addEventListener(el, KeyDownEventName, b.keyHandler(v.id))",
        "b.renderer.addEventListener(el, KeyDownEventName, proc() = discard)",
        SUITE,
        "a key reaches Button and the RUST store says which key",
        CTL[BINDING][0], CTL[BINDING][1],
        "THE LISTENER STOPS TAKING THE PAYLOAD. This is `PLAT21-VG1` "
        "reinstated at the one place it can be: a handler that takes no "
        "argument is exactly what the renderer's ABI used to offer, and a "
        "binding wired to one cannot tell which key arrived. The ELEMENT "
        "STORE still records the delivery — the shim writes it before the "
        "callback — so this arm also proves the store and the handler are "
        "two independent readings rather than one."),

    Arm("B2", BINDING,
        'of kEscape: GpuiKeystroke(name: "escape")',
        'of kEscape: GpuiKeystroke(name: "esc")',
        SUITE,
        "THE KEY IDENTITY — the binding's spellings are the COMPOSITOR's",
        CTL[BINDING][0], CTL[BINDING][1],
        "THE VOCABULARY SPELLS A KEY THE RENDERER NEVER SENDS. `gpui::"
        "Keystroke.key` is `escape`; `esc` is isonim-tui's spelling and the "
        "DOM's is `Escape`, so the mutation is the shape a binding that "
        "borrowed a neighbouring medium's vocabulary would have — and the "
        "consequence is silent, because an unknown name decodes to `kNone` "
        "and an entry declining a key it does not recognise looks exactly "
        "like an entry declining a key it was not sent.\n\n"
        "**THE CASE IT KILLS IS THE ONE THIS ARM CAUSED TO BE WRITTEN, AND "
        "THAT IS THE ARM'S REAL VALUE.** It was first aimed at the case that "
        "DISMISSES the modal, and it SURVIVED — because `gpuiKeystroke` and "
        "`keyFromGpuiKeystroke` are each other's INVERSE BY CONSTRUCTION, so "
        "every case driven by `sendKey` agrees with itself about what a key "
        "is called and a wrong spelling is invisible to all of them. §36's "
        "rule applied: the repair is to the ASSERTION, never to the killer. "
        "The suite gained a case that compares the binding's spellings "
        "against names a real `wl_seat` produced — the SENTINEL the capture "
        "read back out of the element store — which is a name this side did "
        "not choose, and the arm lands on it.\n\n"
        "**RE-AIMED, AND THE FIRST AIM IS WORTH KEEPING** (§32a: a re-aimed "
        "arm must be re-run, and it was). It dropped the back-tab's `gmShift` "
        "instead — §25 in the binding rather than on the wire — and the "
        "harness REFUSED the pair: `B1` and `B2` derived the same killer, "
        "because the back-tab is only observable in the second half of the "
        "per-entry delivery case that `B1` already breaks. Two arms testing "
        "one predicate through two doors is a harness with a hole it cannot "
        "see; the guard saw it. The back-tab's modifier is still asserted "
        "there, and by `test_gpui_vocabulary_binding.nim`'s own case."),

    Arm("B3", BINDING,
        "  setFocusable(el)",
        "  discard el",
        SUITE,
        "focus is held, exclusively, by a Tabs pane",
        CTL[BINDING][0], CTL[BINDING][1],
        "NOTHING IS DECLARED FOCUSABLE. `PLAT21-VG3` reinstated from the "
        "consumer's side: the renderer still has element focus and the "
        "binding stops asking for it, so every focus request is REFUSED and "
        "the focus order is empty. This is the arm that makes 'the renderer "
        "grew a capability' and 'the binding uses it' two different claims — "
        "the risk PLAT-38's own mitigation names."),

    Arm("B4", BINDING,
        "    discard setFocusTrap(el, v.open)",
        "    discard setFocusTrap(el, false)",
        SUITE,
        "PLAT21-VG3 is RETIRED, and the retirement is conditioned on a trap",
        CTL[BINDING][0], CTL[BINDING][1],
        "AN OPEN MODAL TRAPS NOTHING. `Modal`'s specified behaviour is *a "
        "region that takes exclusive input until dismissed*, and a trap that "
        "is never set is the PRESENCE-only rendering PLAT-21 recorded as "
        "strictly less than the entry specifies. The retirement case is "
        "conditioned on the trap existing, which is what this arm removes."),

    # ------------------------------------------------------------------
    # THE REGISTER AND THE SCAN — the bookkeeping, and its own controls
    # ------------------------------------------------------------------
    Arm("G1", GAPS,
        "  FiledGpuiGaps*: seq[GpuiGap] = @[\n    GpuiGap(",
        "  FiledGpuiGaps*: seq[GpuiGap] = @[\n    GpuiGap(\n      id: \"PLAT21-VG3\",\n      entries: @[pkModal],\n      subject: gsRenderer,\n      what: \"a repaired gap put back in the register by a mutation arm, which is what this arm is for and is long enough to pass the field checks\",\n      measured: \"a repaired gap put back in the register by a mutation arm, which is what this arm is for and is long enough to pass the field checks\",\n      remedy: \"a repaired gap put back in the register by a mutation arm, which is what this arm is for and is long enough to pass the field checks\"),\n    GpuiGap(",
        SUITE,
        "THE CENSUS — escapes taken on a run EQUAL the filed register",
        CTL[GAPS][0], CTL[GAPS][1],
        "A REPAIRED GAP IS LEFT IN THE REGISTER. PLAT-35's rule, inherited: "
        "*a filed gap is retired when its divergence is repaired*, asserted, "
        "so a repaired gap left in the register reddens. The census is taken "
        "in BOTH directions — a filed gap nothing takes is a register that "
        "has stopped describing the code — and this is the direction that is "
        "usually left unarmed."),

    Arm("G2", KEYS,
        'repoRoot() / "src" / "frontend" / "view_vocabulary"',
        'repoRoot() / "src" / "frontend" / "view_vocabulary_no_such_dir"',
        SUITE,
        "THE SCAN'S SUBJECT SET is derived from the directory, and is non-empty",
        CTL[KEYS][0], CTL[KEYS][1],
        "THE SCAN'S SUBJECT SET GOES EMPTY. §35: a source scan is only as "
        "wide as its subject set, and §4: a scanner that finds nothing "
        "passes every 'must not contain' check written over it. The arm "
        "points the DERIVED subject at a directory that does not exist, "
        "which is the failure a hardcoded list makes invisible — and the "
        "positive controls (the directory listed files, the read produced "
        "bytes, the bytes carry a spelling that IS there) are what catch it."),

    Arm("G3", KEYS,
        'const marker = "EVENT NAME ("',
        'const marker = "NO SUCH MARKER ("',
        SUITE,
        "THE NEEDLE is derived from the retired gap, and `vockey:` is GONE",
        CTL[KEYS][0], CTL[KEYS][1],
        "THE DERIVED NEEDLE CANNOT BE DERIVED. The needle is taken from the "
        "retired gap's OWN recorded text rather than written as a literal "
        "(§35's fifth-file route, walked four times in this campaign), and "
        "the price of deriving it is that the derivation can break. It "
        "raises rather than answering an empty string, because an empty "
        "needle is `contains(\"\")` and is true of every file — the most "
        "expensive false green a scan can produce."),
]


COUNT_SPELLINGS = [
    "ExpectedAssertions",
    "CHECKS:",
    "expectedScenarios",
    "expectedViewports",
    "expectedCanaries",
    "expectedOperationKinds",
    "MinNeedleLength",
    "MaxNeedles",
]


# ---------------------------------------------------------------------------
# machinery
# ---------------------------------------------------------------------------

def take_lock():
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("ANOTHER RUN HOLDS THE LOCK. Two harnesses mutating one tree "
              "produce verdicts about a tree neither of them wrote (§16).")
        sys.exit(4)
    return fh


def digest(rel: str) -> str:
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def _ends_at_line_end(text: str, needle: str) -> tuple[bool, str]:
    """Does `needle` end where its line ends in `text`?

    PLAT-21's second needle check, adopted. Every control here works by
    APPENDING a comment marker (or a JSON member) to a matched fragment, so a
    needle that is a PREFIX of a longer line comments out the rest of that
    line and the behaviour-preserving control stops being behaviour-preserving.
    """
    at = text.find(needle)
    if at < 0:
        return False, ""
    nl = text.find("\n", at + len(needle))
    end = at + len(needle)
    rest = text[end:nl if nl >= 0 else len(text)]
    return rest.strip() == "", rest


def needle_scan() -> list[str]:
    bad: list[str] = []
    # A MISSING SUBJECT FAILS BY NAME, not with a traceback. The recorded
    # keystroke record is produced by `ci/test/plat38-keystroke.sh` from a real
    # capture; a tree without it cannot grade the `R*` arms, and saying so is
    # the difference between a harness that refuses and one that crashes.
    for rel in sorted({a.path for a in ARMS} | {SUITE}):
        if not (REPO / rel).exists():
            bad.append(
                f"subject {rel} is not in the tree. If it is "
                f"{RECORD}, take a capture and commit it:\n"
                f"      just plat38-capture\n"
                f"      cp build/plat38/manifest.json {RECORD}")
    if bad:
        return bad
    for arm in ARMS:
        text = (REPO / arm.path).read_text()
        # `find` is allowed to occur more than once ONLY where the arm says
        # so in its own note. `R1` and `B2` do: the record holds one
        # `"arrivals": [` per scenario and the per-entry delivery cases each
        # send a back-tab, so those arms land on the FIRST match deliberately
        # and say so. Everywhere else a needle that matched several would
        # mutate whichever `str.replace(..., 1)` reached first and the arm
        # would be about a row nobody chose.
        for label, needle in (("find", arm.find),
                              ("control_find", arm.control_find)):
            n = text.count(needle)
            expected = 1
            if label == "find" and arm.name in FIRST_MATCH_ARMS:
                # DECLARED, not tolerated. These arms target the FIRST
                # occurrence of a repeated key in a generated record, and the
                # count of occurrences is data — so the scan asserts the
                # needle matches AT LEAST once and the arm's `kills` names the
                # scenario the first occurrence belongs to.
                if n < 1:
                    bad.append(f"{arm.name}.{label}: occurs 0 times in "
                               f"{arm.path}")
                continue
            if n != expected:
                bad.append(f"{arm.name}.{label}: occurs {n} time(s) in "
                           f"{arm.path}, expected exactly {expected}")
                continue
            for spelling in COUNT_SPELLINGS:
                if spelling in needle:
                    bad.append(f"{arm.name}.{label}: quotes the count "
                               f"spelling '{spelling}' — §10.3 REJECTS this, "
                               f"it does not warn about it")
            if label == "control_find":
                ok, rest = _ends_at_line_end(text, needle)
                if not ok:
                    bad.append(f"{arm.name}.control_find: does not end at a "
                               f"line end in {arm.path}; the rest of the line "
                               f"is {rest!r} and the control would comment it "
                               f"out")
    names = [a.name for a in ARMS]
    if len(set(names)) != len(names):
        bad.append("two arms share a name")
    kills = [a.kills for a in ARMS]
    if len(set(kills)) != len(kills):
        bad.append("two arms name the same killer case; an arm must be "
                   "attributable to the case it broke (§17a)")
    return bad


# The arms whose `find` deliberately targets the FIRST occurrence of a key that
# the generated record repeats once per run. Declared here rather than handled
# by a lenient default, so an arm that started matching several times by
# ACCIDENT is still refused.
FIRST_MATCH_ARMS = {"R1", "R2", "R3", "R4"}


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN FAILED:")
        for b in bad:
            print("  " + b)
        return 2
    print(f"needle scan: {len(ARMS)} arm(s), every `find` and `control_find` "
          f"matches, ends at a line end, and quotes no count")
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
    subjects = set(TOUCHED)
    ok = True
    for rel in sorted(set(recorded) | subjects):
        if rel not in recorded:
            print(f"CONTROL DIGEST ABSENT: {rel} is compared by this harness "
                  f"but has no recorded digest — run --needle-scan, review, "
                  f"then --record-control-hashes (§16)")
            ok = False
            continue
        if rel not in subjects:
            print(f"CONTROL DIGEST STALE: {rel} is recorded but not compared "
                  f"by this harness — re-run --record-control-hashes (§16)")
            ok = False
            continue
        have = digest(rel)
        if have != recorded[rel]:
            print("CONTROL DIGEST MOVED — the tree is not at the control "
                  "bytes; nothing was mutated.")
            print(f"  {rel}\n      recorded {recorded[rel][:8]}…   "
                  f"on disk {have[:8]}…")
            ok = False
    return ok


CONTROL_HEADER = """\
# Control digests for run-plat38-input-mutations.py.
#
# The bytes every arm restores to, and the bytes every arm's verdict was taken
# against. BOTH HALVES OF `TOUCHED` are here — the six mutation subjects AND
# the suite the arms are graded by — which is Verification-Harness-Traps §16c's
# gap paid rather than inherited: a change that touches only the suite
# invalidates every arm graded against it while producing no overlap signal at
# all in a harness whose TOUCHED names subjects only.
#
# THIS FILE EXISTS FROM THE HARNESS'S FIRST COMMIT. §39 is open because three
# harnesses never had one; a new harness joining them is a deliberate act, and
# this one does not join them.
#
# Refreshed with --record-control-hashes, which the needle scan GATES (§16):
# re-recording from a tree whose arms have stopped matching certifies the arms
# along with the bytes.
"""


def write_control_hashes():
    lines = [f"{digest(rel)}  {rel}" for rel in TOUCHED]
    CONTROL_HASHES.write_text(CONTROL_HEADER + "\n".join(lines) + "\n")
    print(f"recorded {len(lines)} control digest(s) to "
          f"{CONTROL_HASHES.relative_to(REPO)}")


def run_suite(suite: str, corpus: str) -> tuple[int, str]:
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + SUITE_CMD[suite] + [suite]
    env = dict(os.environ)
    # **PINNED, NEVER INHERITED.** Without this the harness would grade an arm
    # against whichever corpus happened to be on the disk, and an arm that
    # corrupted the recorded record would SURVIVE on a workstation that had
    # just captured — for a reason with nothing to do with the gate.
    env["PLAT38_CORPUS"] = corpus
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       timeout=7200, env=env)
    return p.returncode, p.stdout + p.stderr


def require_live_corpus(selected) -> int:
    """A live-corpus arm needs the frames. Absent, it FAILS BY NAME."""
    if not any(a.corpus == "live" for a in selected):
        return 0
    if (REPO / "build/plat38/manifest.json").exists():
        return 0
    print("REFUSED: an arm in this selection is graded against the LIVE "
          "corpus and build/plat38/manifest.json is not here.")
    print("  Take a capture first:  bash ci/test/plat38-keystroke.sh")
    print("  This is NOT skipped. An arm that cannot be graded and is "
          "counted as passed is the defect the whole campaign is about; "
          "--only can exclude it deliberately, which is a different act.")
    return 3


def failure_lines_for(out: str, case: str) -> list[str]:
    block: list[str] = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK]") or s.startswith("[FAILED]"):
            name = s.split("] ", 1)[-1]
            if name == case:
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
    assert text.count(find) >= 1, f"needle not found in {rel}"
    path.write_text(text.replace(find, replace, 1))


def restore(rel: str, original: str):
    (REPO / rel).write_text(original)


def load_because() -> dict:
    if BECAUSE_FILE.exists():
        return json.loads(BECAUSE_FILE.read_text())
    return {}


def derive(selected: list[Arm]) -> int:
    derived = {}
    for arm in selected:
        original = (REPO / arm.path).read_text()
        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite, arm.corpus)
        finally:
            restore(arm.path, original)
        lines = failure_lines_for(out, arm.kills)
        checks = [ln[ln.index("Check failed:"):] for ln in lines
                  if "Check failed:" in ln]
        if not checks:
            # **NOT EVERY FAILURE `std/unittest` REPORTS IS A `Check failed:`
            # LINE**, and an arm aimed at one that is not would otherwise be
            # refused as underivable rather than graded. `expect` prints its
            # own form — this repository's parser suite is full of them — so
            # the fallback is the first non-empty line of the failing case's
            # block, which is that message. The fallback is deliberately
            # SECOND: a `Check failed:` line is a more specific attribution
            # and is preferred wherever there is one.
            checks = [ln for ln in lines if ln.strip()]
        if not checks:
            print(f"{arm.name}: NO `Check failed:` line for '{arm.kills}' — "
                  f"cannot derive a `because`.")
            print("   verdict was:", verdict_for(out, arm.kills))
            continue
        text = re.sub(r"\s+", " ", checks[0]).strip()
        for spelling in COUNT_SPELLINGS:
            if spelling in text:
                print(f"{arm.name}: the derived `because` quotes "
                      f"'{spelling}'; aim the arm at a case that does not "
                      f"assert a count.")
                return 2
        derived[arm.name] = text
        print(f"{arm.name}: because = {text}")
    seen: dict[str, str] = {}
    clash = False
    for name, text in derived.items():
        if text in seen:
            print(f"REFUSED: {name} and {seen[text]} derived the same "
                  f"`because`; an arm must not be attributable to a case it "
                  f"did not break.")
            clash = True
        seen[text] = name
    if clash:
        return 2
    existing = load_because()
    existing.update(derived)
    BECAUSE_FILE.write_text(json.dumps(existing, indent=2, sort_keys=True)
                            + "\n")
    print(f"wrote {len(derived)} derived `because` string(s) to "
          f"{BECAUSE_FILE.relative_to(REPO)}")
    return 0


def grade(selected: list[Arm]) -> int:
    because = load_because()
    missing = [a.name for a in selected if a.name not in because]
    if missing:
        print(f"REFUSED: no derived `because` for {', '.join(missing)}. "
              f"Run --derive first; a typed one is a second copy of the code "
              f"(§17a).")
        return 2

    results = []
    for arm in selected:
        original = (REPO / arm.path).read_text()
        before = hashlib.sha256(original.encode()).hexdigest()

        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite, arm.corpus)
        finally:
            restore(arm.path, original)
        after = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if after != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the revert did not restore the bytes"))
            continue

        if "Error: " in out and "[OK]" not in out and "[FAILED]" not in out:
            results.append((arm, "DID-NOT-COMPILE", ""))
            continue

        v = verdict_for(out, arm.kills)
        if v is None:
            results.append((arm, "NO-VERDICT-FOR-KILLER",
                            "the run told you nothing"))
            continue
        if v == "OK":
            results.append((arm, "SURVIVED", ""))
            continue

        raw = failure_lines_for(out, arm.kills)
        lines = " ".join(ln[ln.index("Check failed:"):] if "Check failed:" in ln
                         else ln for ln in raw)
        lines = re.sub(r"\s+", " ", lines)
        if because[arm.name] not in lines:
            results.append((arm, "MIS-ATTRIBUTED",
                            f"expected: {because[arm.name]}"))
            continue

        try:
            apply_patch(arm.path, arm.control_find, arm.control_replace)
            crc, cout = run_suite(arm.suite, arm.corpus)
        finally:
            restore(arm.path, original)
        cafter = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if cafter != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the control revert did not restore the bytes"))
            continue
        if verdict_for(cout, arm.kills) != "OK":
            results.append((arm, "CONTROL-HARNESS-FAILURE",
                            "the behaviour-preserving control reddened the "
                            "killer case"))
            continue

        results.append((arm, "KILLED", ""))

    print()
    print("| arm | subject | corpus | verdict | note |")
    print("|-----|---------|--------|---------|------|")
    for arm, verdict, note in results:
        print(f"| {arm.name} | {Path(arm.path).name} | {arm.corpus} | "
              f"**{verdict}** | {note} |")
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

    fh = take_lock()  # BEFORE any digest.
    assert fh is not None

    if args.needle_scan:
        return report_needle_scan()

    if args.record_control_hashes:
        # §16: the scan GATES the recording. Recording first would certify a
        # tree in which an arm describes nothing.
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

    rc = require_live_corpus(selected)
    if rc:
        return rc

    if args.derive:
        return derive(selected)
    return grade(selected)


if __name__ == "__main__":
    sys.exit(main())
