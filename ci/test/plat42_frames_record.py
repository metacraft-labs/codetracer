#!/usr/bin/env python3
"""PLAT-42 — summarise the frame-budget window run into a committed record.

Reads build/plat42-frames/<viewport>.json (written by `codetracer-gpui
--frame-report`, driven by ci/test/plat42-frame-budget.sh) and writes
src/tests/visual/plat42-frame-budget.json: per viewport, the render-path time
per frame and the key-to-frame latency as count / p50 / p95 / p99 / max in
milliseconds, with the host's load average at start and end, its CPU count,
the document size, the keys applied and whether the run ended on its sentinel.

REPORTED, NEVER ASSERTED AGAINST A CONSTANT (§28a). Refuses to write from an
absent run: a record of nothing would have the shape of an answer.
"""
import json
import os
import socket
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RUN = os.path.join(ROOT, "build", "plat42-frames")
OUT = os.path.join(ROOT, "src", "tests", "visual", "plat42-frame-budget.json")
VIEWPORTS = ["1440x900", "2560x1440"]


def stats(ns):
    if not ns:
        return {"count": 0}
    s = sorted(ns)

    def pct(p):
        return round(s[min(len(s) - 1, int(p * (len(s) - 1)))] / 1e6, 3)
    return {"count": len(s), "p50Ms": pct(0.50), "p95Ms": pct(0.95),
            "p99Ms": pct(0.99), "maxMs": round(s[-1] / 1e6, 3)}


def main():
    record = {
        "_comment": [
            "PLAT-42 — the frame budget, measured in a real window. Render-path",
            "time EXCLUDES GPUI's own layout and paint. Reported, never asserted",
            "against a constant (§28a). Regenerate: `just plat42-frame-budget`",
            "then `just plat42-frames-record`.",
        ],
        "takenAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": socket.gethostname(),
        "binary": os.path.basename(os.environ.get(
            "CODETRACER_PLAT42_BIN", "codetracer-gpui")),
        "notMeasured": "stepping: the GPUI replay window binds no key to a "
                       "replay operation, so the large file is scrolled and "
                       "edited instead",
        "viewports": {},
    }
    for vp in VIEWPORTS:
        path = os.path.join(RUN, vp + ".json")
        if not os.path.exists(path):
            sys.exit(f"PLAT-42: refusing to record — no frame report at {path}")
        d = json.load(open(path))
        record["viewports"][vp] = {
            "renderPath": stats(d.get("renderPathNs", [])),
            "keyToFrame": stats(d.get("keyToFrameNs", [])),
            # The key's HANDLER (decode, the editing core's applyKey, the
            # redraw) — the part `keyToFrame` starts AFTER. A keystroke's cost
            # before paint is the two added.
            "keyHandler": stats([int(ms * 1e6) for ms in d.get("keyHandlerMs", [])]),
            "loadAverageStart": d.get("loadAverageStart", ""),
            "loadAverageEnd": d.get("loadAverageEnd", ""),
            "cpus": d.get("cpus", 0),
            "documentLines": d.get("documentLines", 0),
            "keysApplied": d.get("keysApplied", 0),
            "finalViewportTop": d.get("finalViewportTop", 0),
            "elapsedMs": d.get("elapsedMs", 0),
            "endedOnDeadline": d.get("endedOnDeadline", True),
        }
    with open(OUT, "w") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    print("wrote", OUT)
    for vp, v in record["viewports"].items():
        print(f"  {vp}: render p50={v['renderPath'].get('p50Ms')}ms "
              f"p95={v['renderPath'].get('p95Ms')}ms "
              f"handler p50={v['keyHandler'].get('p50Ms')}ms "
              f"p95={v['keyHandler'].get('p95Ms')}ms "
              f"key->frame p50={v['keyToFrame'].get('p50Ms')}ms "
              f"p95={v['keyToFrame'].get('p95Ms')}ms "
              f"load {v['loadAverageStart']} / {v['cpus']} cpus")


if __name__ == "__main__":
    main()
