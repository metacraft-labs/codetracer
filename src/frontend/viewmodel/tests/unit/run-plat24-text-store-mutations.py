#!/usr/bin/env python3
"""PLAT-24's mutation harness — proof that the text-store suite can go red.

`test_editor_text_store.nim` claims that each of its cases detects something.
This script proves it one case at a time: it patches a single passage of a
SUBJECT — the rope, the store interface, the incumbent, or the suite's own
non-vacuity machinery — and requires the **named** case to fail. A mutation
killed only by some other case is MISDIRECTED and is a failure of this
harness, not a pass.

WHY IT REACHES THE SUITE ITSELF
-------------------------------
Three arms mutate the suite rather than the product, and that is deliberate.
PLAT-24's recurring defect is a gate that cannot fail — a test list that
silently dropped entries, a scanner whose sweep found nothing, a population
assertion over a generator that produced none. Those are properties of the
HARNESS, so the only way to show they are armed is to break the harness and
require it to notice: U1 empties the differential loop, U2 makes the
round-trip case examine one offset, U3 makes the interface scan match nothing.
Each must go red. A suite whose §4 floors are never exercised has floors
nobody has seen hold.

FOUR VERDICTS, NOT TWO (Verification-Harness-Traps.md §1). An arm that never
ran is not a kill:

  killed           the named case reported [FAILED]
  SURVIVED         the run produced result lines and the named case was [OK]
  MISDIRECTED      something else went red and the named case did not
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all

The last is the one this file exists to keep distinct: a run that prints
nothing looks exactly like a run in which every case passed, if the only
signal read is an exit status.

A DECLARED SURVIVOR IS A STATEMENT, NOT AN EXCUSE. `D1` disables the rope's
seam merge — a property no behavioural case can see, because a fragmented
rope answers every question correctly and only costs more. It is declared so
the gap is written down, and the harness fails if it ever STARTS being killed,
because that would mean a case is now grading something other than what it
says.

RESTORATION IS FROM A VERIFIED SNAPSHOT, never from `git checkout --`: the
original bytes are read into memory before the mutation and written back
after, and the SHA-256 of every touched file is compared against the control
digest before the next arm starts.

THE NEEDLE SCAN (§32). An arm whose `find` text a later repair moved is
silently unkillable: it reports HARNESS-FAILURE only when it is RUN, and
nothing runs it if the suite is green. `--needle-scan` checks every arm's
needle occurs exactly once WITHOUT compiling anything, in about a second, and
must be run BEFORE the control digests are re-recorded.

Usage (from the repository root):
  python3 src/frontend/viewmodel/tests/unit/run-plat24-text-store-mutations.py
  python3 .../run-plat24-text-store-mutations.py --needle-scan
  python3 .../run-plat24-text-store-mutations.py --enumerate-touched
  python3 .../run-plat24-text-store-mutations.py --record-control-hashes
  python3 .../run-plat24-text-store-mutations.py --only=R1,S5
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]            # .../codetracer

# -- subjects ---------------------------------------------------------------
ROPE = "src/frontend/viewmodel/editor/rope.nim"
STORE = "src/frontend/viewmodel/editor/text_store.nim"
SEQ = "src/frontend/viewmodel/editor/seq_line_store.nim"
SUITE = "src/frontend/viewmodel/tests/unit/test_editor_text_store.nim"

TOUCHED = [ROPE, STORE, SEQ, SUITE]

CONTROL_HASHES = HERE / "plat24-text-store-mutation-control.sha256"
BINARY = os.environ.get("CT_P24_BIN", "/tmp/plat24-mutation-suite")

# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
C_EMPTY = "rope: an empty document is one empty line"
C_TRAILING = "rope: a trailing newline means a final empty line"
C_FIRSTLAST = "rope: insert and delete at the first and the last line"
C_CLAMP = "rope: a position past the end of the document is clamped"
C_CRLF = "rope: CRLF is stored byte for byte and never normalised"
C_TABS = "rope: tabs are one byte and not a width"
C_ZWJ = "rope: a ZWJ family is one backspace"
C_MULTIBYTE = "rope: multi-byte text survives a slice at a cluster boundary"
C_SPAN = "rope: a replace spanning many lines removes exactly those"
C_ROUNDTRIP = "rope: offsetOf and posOf round-trip at every offset"
C_BIGINDEX = "rope: the line index answers the last line of a big document"

Q_FIRSTLAST = "seq[string]: insert and delete at the first and the last line"
Q_TABS = "seq[string]: tabs are one byte and not a width"
Q_SPAN = "seq[string]: a replace spanning many lines removes exactly those"
Q_ROUNDTRIP = "seq[string]: offsetOf and posOf round-trip at every offset"

C_DIFF = "the rope agrees with seq[string] and with a plain string, edit by edit"
C_INVARIANTS = "the rope's structural invariants hold after every kind of edit"
C_BALANCED = "the rope stays balanced under 20,000 line-splitting inserts at line 1"
C_UTF8 = "an offset inside a UTF-8 code point is refused, not silently moved"
C_SAMEFILE = "a rope and the incumbent answer the same on the same real file"
C_PRIMITIVES = "the PRIMITIVES section exports exactly the seven named operations"
C_DERIVED = "the DERIVED section adds no capability the seven do not have"
C_INTERCHANGE = "the two stores are interchangeable behind the seven operations"

NAMED_CASES = [
    C_EMPTY, C_TRAILING, C_FIRSTLAST, C_CLAMP, C_CRLF, C_TABS, C_ZWJ,
    C_MULTIBYTE, C_SPAN, C_ROUNDTRIP, C_BIGINDEX,
    Q_FIRSTLAST, Q_TABS, Q_SPAN, Q_ROUNDTRIP,
    C_DIFF, C_INVARIANTS, C_BALANCED, C_UTF8, C_SAMEFILE,
    C_PRIMITIVES, C_DERIVED, C_INTERCHANGE,
]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


ARMS = [
    # ---------------------------------------------------------------- rope --
    Arm(
        "R1", ROPE,
        "  var nl = 0\n  for ch in text:\n    if ch == '\\n': inc nl\n",
        "  var nl = 0\n",
        C_TRAILING,
        "the leaf's newline summary stops being computed, so every line index "
        "in the document is an index into one line",
    ),
    Arm(
        "R2", ROPE,
        "      let inner = offsetOfNewline(kid, rem)\n"
        "      return if inner < 0: -1 else: acc + inner\n",
        "      let inner = offsetOfNewline(kid, rem)\n"
        "      return if inner < 0: -1 else: inner\n",
        C_BIGINDEX,
        "the descent drops the bytes of the subtrees it walked past. Line 0 "
        "still answers 0, which is why the case that catches it is the one "
        "about the LAST line of a big document",
    ),
    Arm(
        "R3", ROPE,
        "  if offset >= n.bytes: return n.newlines\n",
        "  if offset >= n.bytes: return 0\n",
        C_ROUNDTRIP,
        "counting newlines before an offset past a subtree returns none of "
        "them, so `posOf` lands on the wrong line everywhere but the first "
        "chunk",
    ),
    Arm(
        "R4", ROPE,
        "    if a >= 0 and b <= n.bytes and n.bytes - (b - a) + s.len <= MaxLeafBytes:\n",
        "    if a >= 0 and b <= n.bytes and n.bytes - (b - a) + s.len <= MaxLeafBytes * 4:\n",
        C_INVARIANTS,
        "the leaf-local fast path accepts rewrites that overflow a chunk, so "
        "chunks grow without bound and the tree stops being chunked at all. "
        "Every ANSWER stays correct, which is the point: only the structural "
        "check can see it",
    ),
    Arm(
        "R5", ROPE,
        "proc splitOversized(kids: seq[RopeNode]): RopeNode =\n"
        "  if kids.len <= MaxChildren: return newBranch(kids)\n",
        "proc splitOversized(kids: seq[RopeNode]): RopeNode =\n"
        "  if true: return newBranch(kids)\n",
        C_BALANCED,
        "a node never splits on overflow, so fan-out grows without limit and "
        "the tree flattens toward the list PLAT-24 exists to leave behind. "
        "The 20,000-insert case is the one that drives fan-out past the bound",
    ),
    Arm(
        "R6", ROPE,
        "    dest.add n.text[max(a, 0) ..< min(b, n.text.len)]\n",
        "    dest.add n.text[max(a, 0) ..< n.text.len]\n",
        C_MULTIBYTE,
        "a slice that stops inside a chunk returns the rest of the chunk too. "
        "Rebuilding a real file line by line is what notices",
    ),

    # --------------------------------------------------------------- store --
    Arm(
        "S1", STORE,
        # The one-line spelling of this needle occurs TWICE in the file — the
        # same expression appears in `offsetOf` — and an arm whose needle has
        # two targets hits neither (§32). The preceding line disambiguates it
        # to `lineLen`, which is the routine this arm is about.
        "    if line == s.lineCount - 1: rope.len(s.doc)\n"
        "    else: rope.lineStartOffset(s.doc, line + 1) - 1\n",
        "    if line == s.lineCount - 1: rope.len(s.doc)\n"
        "    else: rope.lineStartOffset(s.doc, line + 1)\n",
        C_TABS,
        "a line's length grows to include its own newline, so every column "
        "clamp is one byte too generous",
    ),
    Arm(
        "S2", STORE,
        "  if pos.column <= 0: return start\n",
        "  if pos.column <= 1: return start\n",
        C_ROUNDTRIP,
        "column 1 collapses onto column 0. The short-circuit is an "
        "optimisation on the per-keystroke path, and an optimisation with an "
        "off-by-one in it is the commonest way a fast path goes wrong",
    ),
    Arm(
        "S3", STORE,
        "  if loByte >= 0 and (uint8(loByte) and 0xC0'u8) == 0x80'u8:\n",
        "  if loByte >= 0 and false:\n",
        C_UTF8,
        "the refusal of an offset inside a code point is removed, and the "
        "edit silently splits a rune instead. This is the arm on the one "
        "place the store is allowed to raise",
    ),
    Arm(
        "S4", STORE,
        "  TextPos(line: line, column: off - rope.lineStartOffset(s.doc, line))\n",
        "  TextPos(line: line, column: off)\n",
        C_CLAMP,
        "`posOf` returns a document offset where a column belongs. On line 0 "
        "the two agree, so only a position on a later line catches it",
    ),
    Arm(
        "S5", STORE,
        "# ===========================================================================\n"
        "# DERIVED",
        "proc lineSliceFrom*(s: TextStore; line, a, b: int): string =\n"
        "  ## An eighth primitive, added without widening the list.\n"
        "  s.slice(textPos(line, a), textPos(line, b))\n\n"
        "# ===========================================================================\n"
        "# DERIVED",
        C_PRIMITIVES,
        "AN EIGHTH PRIMITIVE. Editor-ViewModel.md §4 says anything wider than "
        "the seven is the decision leaking; the deliverable is checkable "
        "because it is a list, and this is the arm that shows the list is "
        "read rather than recited",
    ),
    Arm(
        "S6", STORE,
        "proc `$`*(s: TextStore): string =\n  s.text\n",
        "proc `$`*(s: TextStore): string =\n  s.text\n\n"
        "proc describeStore*(s: TextStore): string =\n"
        "  \"lines=\" & $s.lineCount\n",
        C_DERIVED,
        "a seventh derived helper appears without the list being updated. The "
        "derived section is allowed to grow, but not silently",
    ),

    # ----------------------------------------------------- the incumbent ----
    Arm(
        "Q1", SEQ,
        "      for _ in 0 ..< hi.line - lo.line:\n"
        "        s.lines.delete(lo.line + 1)\n",
        "      for _ in 0 ..< hi.line - lo.line - 1:\n"
        "        s.lines.delete(lo.line + 1)\n",
        Q_SPAN,
        "the incumbent's multi-line delete leaves one line behind. The oracle "
        "has to be right for the differential to mean anything, so it carries "
        "its own arms",
    ),
    Arm(
        "Q2", SEQ,
        "  for i in 0 ..< line:\n    result += s.lines[i].len + 1\n",
        "  for i in 0 ..< line:\n    result += s.lines[i].len\n",
        Q_ROUNDTRIP,
        "the incumbent stops charging a byte for each line terminator, so its "
        "line index drifts by one per line",
    ),
    Arm(
        "Q3", SEQ,
        "    s.lines[lo.line] = prefix & parts[0]\n",
        "    s.lines[lo.line] = prefix\n",
        C_DIFF,
        "the incumbent's line split drops the text before the break. The "
        "differential case is what notices, which is what says the "
        "differential case is comparing and not agreeing with itself",
    ),
    Arm(
        "Q4", SEQ,
        "  if line < 0 or line >= s.lines.len: 0 else: s.lines[line].len\n",
        "  if line < 0 or line >= s.lines.len: 0 else: s.lines[line].len + 1\n",
        Q_TABS,
        "the incumbent's line length grows by one — the same defect S1 plants "
        "in the rope, planted in the oracle, so neither side can be wrong "
        "without a case saying so",
    ),

    # ------------------------------------------- the suite's own floors -----
    Arm(
        "U1", SUITE,
        "    for step in 1 .. 3000:\n",
        "    for step in 1 .. 0:\n",
        C_DIFF,
        "THE DIFFERENTIAL LOOP RUNS ZERO TIMES. Every comparison inside it is "
        "then vacuously satisfied (§4). Only the population floors can "
        "notice, and this arm is the proof that they do",
    ),
    Arm(
        "U2", SUITE,
        "      off += 7\n",
        "      off += 10_000_000\n",
        C_ROUNDTRIP,
        "the round-trip case examines ONE offset. The case still passes every "
        "comparison it makes; `checkedOffsets > 1000` is the floor under it, "
        "and this arm is what has seen it hold",
    ),
    Arm(
        "U3", SUITE,
        "      if raw.startsWith(keyword):\n",
        "      if raw.startsWith(\"zzz\" & keyword):\n",
        C_PRIMITIVES,
        "THE INTERFACE SCAN MATCHES NOTHING. §4's canonical shape: a scanner "
        "that finds nothing satisfies every 'must be exactly these' written "
        "over it. The non-vacuity checks on the scan are what refuse it",
    ),
]

DECLARED_SURVIVORS = [
    Arm(
        "D1", ROPE,
        "    if b.height == 0 and kids[^1].height == 0 and\n"
        "       kids[^1].bytes + b.bytes <= MaxLeafBytes:\n",
        "    if false and b.height == 0 and kids[^1].height == 0 and\n"
        "       kids[^1].bytes + b.bytes <= MaxLeafBytes:\n",
        "(nothing — declared survivor)",
        "THE SEAM MERGE, DISABLED. Without it a long editing session "
        "fragments the leaves and the rope costs more per operation, and "
        "NOTHING in a behavioural suite can see that: a fragmented rope "
        "answers every question correctly, its leaves are still under "
        "MaxLeafBytes, its fan-out is still at least two, and its depth bound "
        "grows WITH the leaf count so the structural check is satisfied too. "
        "The only instrument for this property is "
        "`benchmarks/text_store_bench.nim`. Declared here so the gap is "
        "written down rather than discovered; if this ever starts being "
        "killed, a case has begun grading something other than what it says",
    ),
]

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def run_suite() -> RunResult:
    proc = subprocess.run(
        ["nim", "c", "-r", "--hints:off", "-o:" + BINARY, SUITE],
        cwd=ROOT, capture_output=True, text=True, timeout=3600,
        # `errors="replace"`: a mutated store can emit raw bytes from a random
        # edit, and a UnicodeDecodeError in the READER would abort the harness
        # mid-arm with a file still mutated on disk.
        encoding="utf-8", errors="replace",
    )
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode)
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print("      ---- no result lines; last 20 lines of output ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def needle_scan() -> int:
    """Every arm's needle occurs exactly once. No toolchain, about a second."""
    problems = 0
    for arm in ARMS + DECLARED_SURVIVORS:
        text = (ROOT / arm.path).read_text()
        n = text.count(arm.find)
        status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
        if n != 1:
            problems += 1
        print(f"{arm.id:<4} {status:<10} {n} occurrence(s) in {arm.path}")
    # The killers, too: a case renamed in the suite makes its arm unkillable
    # in exactly the same silent way a moved needle does.
    #
    # The contract's case names are COMPOSED at run time — `storeName & ": …"`
    # inside `storeContract` — so the full string is not in the source and a
    # literal search for it would report every one of them missing, which is a
    # scan that is wrong in the noisy direction. Check the two halves instead:
    # the store-name prefix must be one the suite actually instantiates, and
    # the remainder must appear literally.
    suite_text = (ROOT / SUITE).read_text()
    instantiated = [m for m in ("rope", "seq[string]")
                    if f'storeContract(toTextStore, "{m}")' in suite_text
                    or f'storeContract(toSeqLineStore, "{m}")' in suite_text]
    if len(instantiated) != 2:
        print(f"THE CONTRACT IS NOT INSTANTIATED TWICE: found {instantiated}")
        problems += 1
    for name in NAMED_CASES:
        prefix, sep, rest = name.partition(": ")
        if sep and prefix in ("rope", "seq[string]"):
            if prefix not in instantiated:
                print(f"KILLER PREFIX NOT INSTANTIATED: {name!r}")
                problems += 1
            elif f'": {rest}"' not in suite_text:
                print(f"KILLER BODY NOT IN SUITE: {rest!r}")
                problems += 1
        elif name not in suite_text:
            print(f"KILLER NAME NOT IN SUITE: {name!r}")
            problems += 1
    for arm in ARMS:
        if arm.killer not in NAMED_CASES:
            print(f"{arm.id}: killer {arm.killer!r} is not a declared case name")
            problems += 1
    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


def record_control_hashes() -> int:
    lines = [f"{digest(p)}  {p}" for p in TOUCHED]
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")
    print(f"recorded {len(lines)} digests in {CONTROL_HASHES}")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print(f"NOTE: {CONTROL_HASHES.name} is absent — run "
              f"--record-control-hashes after reviewing the tree")
        return True
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip():
            continue
        h, p = line.split(None, 1)
        recorded[p.strip()] = h
    ok = True
    for p in TOUCHED:
        if p in recorded and recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  f"--record-control-hashes (§32)")
            ok = False
    return ok


def main() -> int:
    only = None
    for arg in sys.argv[1:]:
        if arg == "--needle-scan":
            return needle_scan()
        if arg == "--enumerate-touched":
            for p in TOUCHED:
                print(p)
            return 0
        if arg == "--record-control-hashes":
            return record_control_hashes()
        if arg.startswith("--only="):
            only = set(arg[len("--only="):].split(","))
        else:
            print(f"unknown argument: {arg}")
            return 2

    if needle_scan() != 0:
        print("REFUSING TO RUN: a needle is lost or ambiguous (§32)")
        return 1
    check_control_hashes()

    baseline = {p: digest(p) for p in TOUCHED}

    print("\n== control ==")
    control = run_suite()
    if control.failed or not control.ran:
        print(f"CONTROL IS NOT GREEN: rc={control.rc} failed={control.failed}")
        return 1
    missing = [c for c in NAMED_CASES if c not in control.passed]
    if missing:
        print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES: {missing}")
        return 1
    print(f"control: {control.total} cases, all {len(NAMED_CASES)} named ones "
          f"ran, 0 failures\n")

    problems = 0
    for arm in ARMS + DECLARED_SURVIVORS:
        if only and arm.id not in only:
            continue
        path = ROOT / arm.path
        original = path.read_text()
        occurrences = original.count(arm.find)
        if occurrences != 1:
            print(f"{arm.id:<5} HARNESS-FAILURE      needle occurs "
                  f"{occurrences} times in {arm.path}, expected 1")
            problems += 1
            continue
        path.write_text(original.replace(arm.find, arm.replace))
        try:
            res = run_suite()
        finally:
            path.write_text(original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<5} HARNESS-FAILURE      {p} did not "
                          f"restore to its control bytes")
                    return 2
        declared = arm in DECLARED_SURVIVORS
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {res.failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", arm.why[:70] + "..."
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif arm.killer in res.failed:
            others = [f for f in res.failed if f != arm.killer]
            verdict = "killed"
            note = arm.killer + (f"  (+{len(others)} more)" if others else "")
        else:
            verdict = "MISDIRECTED"
            note = f"died in {res.failed}, not {arm.killer!r}"
            problems += 1
        print(f"{arm.id:<5} {verdict:<20} {note}")

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
