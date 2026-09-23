#!/usr/bin/env python3
"""PLAT-44 — the sequence window run as a committed record.

Reads `build/plat44-sequences/runs.jsonl` (written by
`ci/test/plat44-sequences-window.sh`) and the plan it typed, and writes
`src/tests/visual/plat44-sequences-window.json`, which
`src/frontend/gpui/tests/test_plat44_sequences_window.nim` asserts over — the
measure-locally-commit-the-measurement arrangement PLAT-37/38/39/42 use, so
the assertion runs in CI where no compositor exists.

Refuses to write from an absent or partial run: every sequence in the plan
must have a run, and the negative twin must be present.
"""
import datetime
import json
import os
import socket
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RUN = os.path.join(ROOT, "build/plat44-sequences")
OUT = os.path.join(ROOT, "src/tests/visual/plat44-sequences-window.json")


def main():
    plan = json.load(open(os.path.join(RUN, "plan.json")))
    runs = [json.loads(l) for l in open(os.path.join(RUN, "runs.jsonl"))
            if l.strip()]
    typed = [r for r in runs if r["dropped"] == 0]
    twins = [r for r in runs if r["dropped"] > 0]
    want = [s["id"] for s in plan["sequences"]]
    got = [r["id"] for r in typed]
    if got != want or not twins:
        sys.exit("refusing to record: the run covers %s, the plan %s, twins %d"
                 % (got, want, len(twins)))
    record = {
        "_comment": [
            "PLAT-44 — PLAT-34's sequences typed into a real codetracer-gpui",
            "window. Regenerate: `just plat44-sequences-plan`, then",
            "`just plat44-sequences-window`, then `just plat44-sequences-record`.",
            "Asserted by test_plat44_sequences_window.nim.",
        ],
        "takenAt": datetime.datetime.now(datetime.timezone.utc)
                   .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": socket.gethostname(),
        "corpus": plan["corpus"],
        "unreachable": plan["unreachable"],
        "sequences": typed,
        "negativeTwin": twins[0],
    }
    with open(OUT, "w") as f:
        json.dump(record, f, indent=1)
        f.write("\n")
    def exact(r):
        return (r["onDisk"] == r["expected"]
                and r["caretLine"] == r["expectedCaretLine"]
                and r["caretColumn"] == r["expectedCaretColumn"])
    ok = sum(1 for r in typed if exact(r))
    print("wrote %s: %d of %d typed sequences reproduced (file and caret); "
          "negative twin %s" % (OUT, ok, len(typed),
                                "differs" if not exact(twins[0]) else "MATCHES"))


main()
