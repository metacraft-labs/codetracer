#!/usr/bin/env python3
"""PLAT-42 — record the GPUI editor's four debugger surfaces from the SHIPPED binary.

Runs `codetracer-gpui --report-plan` (headless: no window, no compositor) once
per pinned scenario against the real `calc` recording, reads the Rust-side
shadow tree the plan describes, and writes what the four surfaces showed to
`src/tests/visual/plat42-surfaces.json`.

WHY A RECORD. The plan needs the built binary, the db-backend replay server and
a recorded trace — none of which the CI floors lane has. So this follows the
arrangement PLAT-37/38/39 already use: MEASURE LOCALLY, COMMIT THE MEASUREMENT,
and let a portable suite assert the record in CI. The record carries `takenAt`,
`host` and a digest of each plan so a stale record is attributable.

WHAT MADE THIS POSSIBLE. Until the render plan serialised element attributes,
the surfaces were invisible to it: the editor writes `data-ct-pointer`,
`data-ct-mark`, `data-ct-values` and `data-ct-flow` on every row, and not one of
them appeared in any captured plan.

It REFUSES to write a record when the binary, the shim or the trace is missing,
or when any plan fails — a record of failures would look like an answer.

    python3 ci/test/plat42_surfaces_record.py
"""
import hashlib, json, os, socket, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(ROOT, "build/bin/codetracer-gpui")
SHIM = os.path.abspath(os.path.join(ROOT, "..", "isonim-gpui/rust/target/debug"))
TRACE = os.environ.get("CODETRACER_PLAT42_TRACE",
                       os.path.join(ROOT, "test-logs/tui-fixtures/calc-2f0db4f45192"))
OUT = os.path.join(ROOT, "src/tests/visual/plat42-surfaces.json")
# The FLOW scenario needs a program with a branch the run declines, which `calc`
# deliberately has none of (its operator dispatch is a table, not an `if`).
# `noir_space_ship`'s `shield.nr` has one: `stepIn=15` stops inside its loop
# with the arm on lines 11-13 not taken — found by probing step counts on
# 2026-09-23, not chosen for the answer.
FLOW_TRACE = os.environ.get("CODETRACER_PLAT42_FLOW_TRACE",
                            os.path.join(ROOT, "test-logs/tui-fixtures/noir_space_ship-f9f31b01a0d2"))
FLOW_SCENARIOS = [
    {"id": "noir-declined-arm", "replayOps": "stepIn=15"},
]
SCEN = os.path.join(ROOT, "src/tests/visual/scenarios.json")


def ops_for(sc):
    # Same spelling as ci/test/plat37-window-frame.sh — one grammar, read here.
    terms = []
    for op in sc.get("operations") or []:
        if op["kind"] == "setBreakpoint":
            terms.append(f"setBreakpoint@{op['line']}")
        else:
            terms.append(f"{op['kind']}={op.get('times', 1)}")
    return ",".join(terms)


def text(n):
    return (n.get("text") or "") + "".join(text(c) for c in n.get("children", []))


def read_surfaces(plan):
    rows = []
    def walk(n):
        a = n.get("attributes", {})
        if "data-ct-row" in a and "data-ct-pointer" in a:
            rows.append({
                "row": int(a["data-ct-row"]),
                "pointer": a.get("data-ct-pointer"),
                "mark": a.get("data-ct-mark"),
                "values": a.get("data-ct-values", ""),
                "flow": a.get("data-ct-flow"),
                # What GPUI will actually PAINT for the flow overlay: the code
                # span's opacity in the plan, "" when unset (fully opaque).
                "codeOpacity": next(
                    (c.get("styles", {}).get("opacity", "")
                     for c in n.get("children", [])
                     if c.get("attributes", {}).get("data-ct-text-role") == "editor-code"),
                    ""),
                "text": text(n).strip()[:80],
            })
        for c in n.get("children", []):
            walk(c)
    walk(plan)
    return rows


def main():
    for p, what in ((BIN, "build/bin/codetracer-gpui (just build-gpui)"),
                    (os.path.join(SHIM, "libgpui_nim_shim.so"), "the isonim-gpui shim"),
                    (TRACE, "the calc recording"),
                    (FLOW_TRACE, "the noir_space_ship recording")):
        if not os.path.exists(p):
            sys.exit(f"PLAT-42: refusing to record — {what} is missing at {p}")
    scen = json.load(open(SCEN))
    env = dict(os.environ, LD_LIBRARY_PATH=SHIM)
    record = {
        "_comment": [
            "PLAT-42 — the GPUI editor's four debugger surfaces, read from the",
            "SHIPPED binary's render plan (Rust-side shadow tree), per scenario.",
            "Regenerate with `just plat42-surfaces-record`. Asserted by",
            "src/frontend/gpui/tests/test_plat42_surfaces.nim, which reads no binary.",
        ],
        "takenAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": socket.gethostname(),
        "scenarios": {},
    }
    def measure(sid, ops, trace):
        argv = [BIN, "--report-plan", "--width=1920", "--height=1080"]
        if ops:
            argv.append(f"--replay-ops={ops}")
        argv.append(trace)
        p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"PLAT-42: refusing to record — {sid} exited {p.returncode}: "
                     f"{p.stderr.strip()[:200]}")
        plan = json.loads(p.stdout)
        rows = read_surfaces(plan)
        if not rows:
            sys.exit(f"PLAT-42: refusing to record — {sid}'s plan has no editor rows "
                     "carrying surface attributes (is the shim current?)")
        print(f"  {sid:22s} rows={len(rows)}")
        return {
            "replayOps": ops,
            "planSha256": hashlib.sha256(p.stdout.encode()).hexdigest(),
            "rowCount": len(rows),
            "rows": rows,
        }

    for sc in scen["scenarios"]:
        record["scenarios"][sc["id"]] = measure(sc["id"], ops_for(sc), TRACE)
    record["flowTrace"] = os.path.basename(FLOW_TRACE)
    record["flowScenarios"] = {}
    for sc in FLOW_SCENARIOS:
        record["flowScenarios"][sc["id"]] = measure(sc["id"], sc["replayOps"],
                                                   FLOW_TRACE)
    with open(OUT, "w") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
