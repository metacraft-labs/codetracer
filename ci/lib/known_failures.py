#!/usr/bin/env python3
"""Reconcile one suite's output against the known-failure ledger.

WHY THIS EXISTS
---------------
`MockBackendService` was made strict, which turned eleven silently-wrong
dispatches into honest reds. There was nowhere to put them: grepping `src/`,
`ci/` and the `justfile` for `known.?failure`, `xfail`, `expected.fail` and
every neighbouring spelling returns nothing. "Registered as a known failure"
meant a row in a Markdown table, so `just test-vm` exited 1 on every push --
and a permanently red suite is not a suite anybody reads. That is the condition
this campaign keeps finding at the bottom of its worst defects.

WHAT A REGISTRATION MEANS, AND WHAT IT DOES NOT
-----------------------------------------------
The product owner's constraint, quoted because it is the whole design:

    "We need to introduce a new category in the test suite for known failures
     which would be tests that would signal when they go green. Don't write
     tests that assert on the wrong behavior because this is confusing for
     future maintainers."

So a registered test still asserts the CORRECT behaviour and still fails. What
changes is only who is surprised. Two directions, and the second is the half
that makes this a mechanism rather than a mute button:

  * a registered test that FAILS as registered does not fail the lane;
  * a registered test that PASSES **fails the lane, by name**, and the fix is
    to delete its entry.

A ledger that could only ever suppress is indistinguishable from one that
suppresses everything, so `ci/test/known-failures-gate.sh` drives both
directions over fixtures and asserts the exit codes.

THE TRAP THIS CLOSES
--------------------
An entry keyed only on a test's *identity* silently absorbs a DIFFERENT
failure. It has already happened in this workspace: a journey threw on its
first line because a manifest schema had bumped, and its ledger entry went on
swallowing the exit code -- so the entry was green-lighting a failure nobody
had reviewed.

So an entry pins WHAT it expects, not merely which test may fail:

  * the test's exact name, and
  * a `signature` substring that must appear in THAT test's own failure output.

The signature is matched against the lines attributed to that single case, not
against the whole file, because `unittest` interleaves several cases' output
and a file-wide match would let any case's message satisfy any entry.

Attribution rule: `unittest` prints a case's diagnostics BEFORE its
`[OK]`/`[FAILED]`/`[SKIPPED]` line, so the lines belonging to a case are those
since the previous status line. Measured against real lane output; see the
gate's fixtures.

Three further ways a ledger can lie, each refused here:

  * A suite that never ran. A compile error or a crash before the first case
    produces no `[FAILED]` lines at all, so the registered set cannot match and
    the lane fails. Registrations can never turn "it did not run" into a pass.
  * An unregistered failure alongside registered ones. The failing set must
    equal the registered set EXACTLY; a new red is never absorbed by its
    neighbours.
  * An entry for a file the lane no longer runs. Reported by
    `--audit`, which the lane calls once at the end.

Usage:
  known_failures.py reconcile <lane> <file>   # suite output on stdin
      exit 0  nothing registered for this file, and nothing to say
      exit 3  registered, and every entry failed for its registered reason
      exit 1  the lane must fail; reasons on stdout

  The caller must only consult this for a suite that RAN — `ok` or `partial`
  in `classify_test_run`'s vocabulary. A `crashed`, `no-results` or
  `silent-failure` verdict is never offered to the ledger, so no registration
  can excuse a suite that died: that is enforced at the call site in
  run-nim-test-lane.sh rather than here, because only the caller knows the
  process's exit status.
  known_failures.py audit <lane> <file>...    # files the lane actually ran
      exit 1 if the ledger names a file this lane did not run
"""

import os
import sys

LEDGER = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "known-test-failures.tsv")

STATUS_PREFIXES = ("[OK]", "[FAILED]", "[SKIPPED]")


def load_ledger(path=LEDGER):
    """Rows of (lane, file, test, signature). Malformed lines are fatal.

    A ledger that silently drops a row it could not parse would under-register
    and redden the lane, which is the safe direction -- but it would do it
    without saying why, and a mechanism nobody can debug gets deleted.
    """
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                raise SystemExit(
                    "%s:%d: expected 4 tab-separated fields "
                    "(lane, file, test, signature), got %d" % (path, n, len(parts)))
            lane, f, test, sig = (p.strip() for p in parts)
            if not (lane and f and test and sig):
                raise SystemExit(
                    "%s:%d: every field must be non-empty; an entry without a "
                    "signature pins nothing and would absorb any failure of "
                    "that test" % (path, n))
            rows.append((lane, f, test, sig))
    return rows


def cases(output):
    """[(status, name, body)] in order, body = the lines printed before it."""
    out = []
    pending = []
    for line in output.splitlines():
        s = line.strip()
        for p in STATUS_PREFIXES:
            if s.startswith(p):
                out.append((p[1:-1], s[len(p):].strip(), "\n".join(pending)))
                pending = []
                break
        else:
            pending.append(line)
    return out


def reconcile(lane, path, output):
    registered = {t: sig for (ln, f, t, sig) in load_ledger()
                  if ln == lane and f == path}
    seen = cases(output)
    failed = {name: body for (st, name, body) in seen if st == "FAILED"}
    passed = {name for (st, name, _) in seen if st == "OK"}

    problems = []

    # (1) A registered test that PASSES fails the lane. This is the direction
    #     the product owner asked for by name: the entry has outlived its
    #     defect and must go, and nothing else in the system would ever say so.
    for test in sorted(registered):
        if test in passed:
            problems.append(
                "  '%s'\n"
                "      is registered as a known failure but PASSED.\n"
                "      Delete its row from ci/lib/known-test-failures.tsv — a "
                "stale entry\n"
                "      launders the next real regression as an expected one."
                % test)

    # (2) A registered test that is neither failing nor passing did not run.
    for test in sorted(registered):
        if test not in failed and test not in passed:
            problems.append(
                "  '%s'\n"
                "      is registered, but this run produced no verdict for it "
                "at all.\n"
                "      A suite that did not reach its cases cannot have its "
                "reds excused."
                % test)

    # (3) An unregistered failure is never absorbed by its neighbours.
    #
    # ONLY WHEN SOMETHING IS BEING EXCUSED. A file with no entries is not this
    # mechanism's business: its reds are already failing the lane through the
    # ordinary path, and reporting them here too would make every failing file
    # in the repo look like a ledger problem. Caught by the gate's arm F, which
    # is why that arm is written.
    if registered:
        for test in sorted(failed):
            if test not in registered:
                problems.append(
                    "  '%s'\n"
                    "      FAILED beside registered known failures in this "
                    "file, and is not\n"
                    "      registered itself. A new red is never excused by "
                    "its neighbours."
                    % test)

    # (4) The signature must appear in THAT case's own output. This is what
    #     stops an entry from absorbing a different failure of the same test.
    for test, sig in sorted(registered.items()):
        if test not in failed:
            continue
        if sig not in failed[test]:
            body = failed[test].strip().splitlines()
            excerpt = "\n".join("        " + b.strip() for b in body[-6:]) \
                or "        (the case printed nothing)"
            problems.append(
                "  '%s'\n"
                "      FAILED, but not for the registered reason.\n"
                "      expected to find: %s\n"
                "      in what it printed:\n%s\n"
                "      Either it broke a second way, or the entry is stale. "
                "Re-triage it;\n"
                "      do not widen the signature to make this pass."
                % (test, sig, excerpt))

    if problems:
        print("known-failure ledger disagrees with %s:" % path)
        for p in problems:
            print(p)
        return 1

    if registered:
        print("%d registered known failure(s), each failing for its "
              "registered reason" % len(registered))
        return 3
    return 0


def audit(lane, ran):
    ran = set(ran)
    stale = sorted({f for (ln, f, _t, _s) in load_ledger()
                    if ln == lane and f not in ran})
    if stale:
        print("known-failure ledger names file(s) the '%s' lane did not run:"
              % lane)
        for f in stale:
            print("  %s" % f)
        print("An entry against a file nobody runs is a registration that can "
              "never be retired.")
        return 1
    return 0


def main(argv):
    if len(argv) >= 4 and argv[1] == "reconcile":
        return reconcile(argv[2], argv[3], sys.stdin.read())
    if len(argv) >= 3 and argv[1] == "audit":
        return audit(argv[2], argv[3:])
    print(__doc__.strip().split("Usage:")[-1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
