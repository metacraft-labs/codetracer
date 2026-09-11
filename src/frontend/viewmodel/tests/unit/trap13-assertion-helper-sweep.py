#!/usr/bin/env python3
"""Trap-13 sweep, wrapper-aware, with a planted control.

Verification-Harness-Traps §13: `unittest.check` inside a plain `proc`
resolves to the module-level `testStatusIMPL` fallback, so the assertion
cannot fail the test that called it and the case reports `[OK]` with the
failed comparison printed directly above it.

The naive sweep is `grep -n 'check ' inside proc bodies`. It misses the shape
that actually recurs: a `proc` that calls a `template` that calls `check`.
The template expands INSIDE THE PROC, so `testStatusIMPL` resolves to the
module global exactly as a direct `check` would.

So this sweep is a fixed point:

  1. seed:      `check`, `require`, `expect`, `fail`  (unittest's own)
  2. templates: any `template` whose body mentions a name in the set joins it
     — iterated to a fixed point, so a wrapper of a wrapper is caught
  3. findings:  any `proc`/`func`/`method`/`iterator` whose body mentions a
     name in the set

Normalisation, both halves of §4d:

  * comments are removed — `# check this` is prose;
  * string literals are BLANKED — `"check the thing"` is prose;
  * for a one-line routine (`proc p() = check a == b`) the body is the text
    AFTER the first top-level `=`, so the signature's own default values and
    the routine name cannot be mistaken for a body.

THE PLANTED CONTROL. A scanner that finds nothing satisfies every
"must not contain" check (§4). So this script writes a synthetic file
carrying all four shapes — a direct `check` in a proc, a proc calling a
one-level wrapper template, a proc calling a two-level wrapper, and a proc
whose ONLY mention of `check` is inside a comment and a string literal — and
requires the first three to be found and the fourth not to be.

WHY IT LIVES HERE. Beside the mutation harnesses, which are the other analysis
tools in this campaign that are run by hand rather than by a lane. It is NOT
under `ci/`, deliberately: `ci/test/shell-gate-coverage.sh` scans `ci` and
`scripts` for `.sh`, `.mjs` and `.py` gates and reports any that no workflow or
recipe runs, so putting a hand-run tool there would add a dark gate to that
guard's tally.

Usage, from the repository root:
  # this pass's files
  python3 src/frontend/viewmodel/tests/unit/trap13-assertion-helper-sweep.py \
      src/common/plugin_distribution_test.nim ...

  # every suite in four lanes
  source ci/lib/test-lane-files.sh
  { test_lane_files vm-unit; test_lane_files common-units;
    test_lane_files ct-cli-units; test_lane_files tui; } | sort -u |
    xargs python3 src/frontend/viewmodel/tests/unit/trap13-assertion-helper-sweep.py

The planted control runs FIRST on every invocation and the sweep refuses to
report when it fails, so a scanner that has stopped reading Nim cannot produce
a clean sweep (Verification-Harness-Traps §4).
"""

from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

SEED = {"check", "require", "expect", "fail"}

ROUTINE = re.compile(r"^(\s*)(proc|func|method|iterator)\s+([`\w]+)")
TEMPLATE = re.compile(r"^(\s*)(template)\s+([`\w]+)")


def strip_line(raw: str) -> str:
    """Remove a trailing comment and blank every string/char literal."""
    out = []
    i = 0
    in_str = False
    quote = ""
    while i < len(raw):
        c = raw[i]
        if in_str:
            if c == "\\":
                out.append(" ")
                if i + 1 < len(raw):
                    out.append(" ")
                i += 2
                continue
            if c == quote:
                in_str = False
                out.append(" ")
            else:
                out.append(" ")
        elif c in ('"', "'"):
            in_str = True
            quote = c
            out.append(" ")
        elif c == "#":
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def blocks(path: Path):
    """Yield (kind, name, lineno, body_text) for every routine and template."""
    lines = path.read_text(errors="replace").splitlines()
    clean = [strip_line(l) for l in lines]
    found = []
    for idx, line in enumerate(clean):
        m = ROUTINE.match(line) or TEMPLATE.match(line)
        if not m:
            continue
        indent = len(m.group(1))
        kind = m.group(2)
        name = m.group(3)
        # The body: text after the first top-level `=` on the declaration
        # line, plus every following line indented deeper than the header.
        body = []
        eq = line.find("=")
        if eq >= 0:
            body.append(line[eq + 1:])
        j = idx + 1
        while j < len(clean):
            nxt = clean[j]
            if nxt.strip() == "":
                j += 1
                continue
            nindent = len(nxt) - len(nxt.lstrip())
            if nindent <= indent:
                break
            body.append(nxt)
            j += 1
        found.append((kind, name, idx + 1, "\n".join(body)))
    return found


def mentions(body: str, names: set[str]) -> set[str]:
    """Which of `names` this body CALLS.

    A token preceded by `.` is a QUALIFIED call and is not unittest's. That
    exclusion is load-bearing rather than tidy: `MockBackendService.expect` is
    a method in this repository's own test doubles, and without it every
    helper that primes a mock is reported as a trap-13 defect. unittest's own
    `expect` is a command-call (`expect ValueError: ...`) and never has a
    receiver, so nothing real is lost.
    """
    hit = set()
    for m in re.finditer(r"(\.?)\b([A-Za-z_][A-Za-z0-9_]*)", body):
        if m.group(1) == ".":
            continue
        if m.group(2) in names:
            hit.add(m.group(2))
    return hit


def sweep(paths: list[Path]):
    """Return (findings, asserting_names). A finding is a §13 defect.

    THE FIXED POINT IS PER FILE, and that is a correction rather than a
    simplification. Merging every file into one namespace reported five false
    positives on this repository's first sweep: three test files define a
    `template pending(what: string)` that calls `check`, and three OTHER files
    use `pending` as an ordinary local variable. These suites do not import
    one another, so a template in one is not in scope in the next; scoping the
    propagation to the file is both correct and what removes the collision.

    The seeds stay global because they are `std/unittest`'s and every suite
    imports it.
    """
    findings = []
    asserting_all = set(SEED)
    for p in paths:
        file_blocks = list(blocks(p))
        asserting = set(SEED)
        changed = True
        while changed:
            changed = False
            for kind, name, _ln, body in file_blocks:
                if kind != "template":
                    continue
                if name in asserting:
                    continue
                if mentions(body, asserting):
                    asserting.add(name)
                    changed = True
        asserting_all |= asserting
        for kind, name, ln, body in file_blocks:
            if kind == "template":
                continue
            hits = mentions(body, asserting)
            if hits:
                findings.append((p, kind, name, ln, sorted(hits)))
    return findings, asserting_all


CONTROL = '''\
import std/unittest

template ck(condition: untyped) =
  check condition

template ckTwice(condition: untyped) =
  ck condition

proc plantedDirect(a, b: int) =
  check a == b

proc plantedOneLevel(a, b: int) =
  ck a == b

proc plantedTwoLevels(a, b: int) =
  ckTwice a == b

proc plantedInnocent(a, b: int) =
  # check a == b  -- this is a comment, not an assertion
  echo "check a == b"
  discard a + b

type Mock = object
proc expect(m: Mock; what: string) = discard

proc plantedQualified(m: Mock) =
  ## A mock being primed, not an assertion. `unittest.expect` is a
  ## command-call and never has a receiver.
  m.expect("initialize")

proc plantedLocalName() =
  ## `pending` is a template that asserts IN A DIFFERENT FILE. Here it is an
  ## ordinary local, and a sweep that merged both files' namespaces reported
  ## this shape five times on the real tree.
  var pending = @["a"]
  while pending.len > 0: discard pending.pop()

suite "the control":
  test "one":
    plantedDirect(1, 1)
'''


def run_control() -> int:
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "trap13_control.nim"
        p.write_text(CONTROL)
        findings, asserting = sweep([p])
        names = {f[2] for f in findings}
        problems = []
        for want in ("plantedDirect", "plantedOneLevel", "plantedTwoLevels"):
            if want not in names:
                problems.append(f"the scan MISSED the planted {want}")
        for unwanted, why in (("plantedInnocent", "prose"),
                              ("plantedQualified", "a qualified method call"),
                              ("plantedLocalName", "a local variable name")):
            if unwanted in names:
                problems.append(f"the scan matched {why}: {unwanted}")
        for want in ("ck", "ckTwice"):
            if want not in asserting:
                problems.append(f"the wrapper {want} was not recognised")
        print("planted control:")
        print(f"  asserting names reached: {sorted(asserting)}")
        print(f"  routines flagged:        {sorted(names)}")
        for line in problems:
            print(f"  PROBLEM: {line}")
        if problems:
            return 1
        print("  control OK — three planted shapes found, prose not matched")
        return 0


def main() -> int:
    rc = run_control()
    if rc:
        print("THE SCANNER'S OWN CONTROL FAILED; the sweep below means nothing")
        return rc
    targets: list[Path] = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        if p.is_dir():
            targets.extend(sorted(p.rglob("*.nim")))
        else:
            targets.append(p)
    if not targets:
        print("no files given")
        return 2
    findings, _ = sweep(targets)
    print(f"\nswept {len(targets)} file(s)")
    if not findings:
        print("0 findings")
        return 0
    print(f"{len(findings)} finding(s):")
    for p, kind, name, ln, hits in findings:
        print(f"  {p}:{ln}: {kind} {name} reaches {hits}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
