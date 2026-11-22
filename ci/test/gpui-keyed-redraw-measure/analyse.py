"""Summarise run.sh's frame reports: per run and per mode, the shim's work per
step frame and the front-end's redraw per step.

A STEP FRAME is a frame after the window's first three that rebuilt any plan
(`frameWork[i].plansRebuilt > 0`): the frames a step's redraw reached the shim
in. A frame with no change rebuilds nothing and is not one.
"""
import json
import os
import statistics as st
import sys

base = sys.argv[1] if len(sys.argv) > 1 else "build/gpui-keyed-redraw-measure"


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))] if xs else None


def step_frames(r):
    work, ns = r["frameWork"], r["renderPathNs"]
    return [(w, ns[i] / 1e6) for i, w in enumerate(work)
            if i >= 3 and w["plansRebuilt"] > 0 and i < len(ns)]


def runs(mode):
    for d in sorted(os.listdir(base)):
        f = os.path.join(base, d, "frames.json")
        if d.startswith(mode + "-") and os.path.exists(f):
            yield d, json.load(open(f))


for mode in ("keyed", "full"):
    for d, r in runs(mode):
        sf = step_frames(r)
        refresh = [x["ms"] for x in r.get("refreshes", [])][1:]
        keys = sum(1 for line in open(os.path.join(base, d, "keys.log"))
                   if line.startswith("n "))
        print(f"{d}: fullRedraw={r.get('fullRedraw')} frames={len(r['frameWork'])} "
              f"stepFrames={len(sf)} keys={keys} refreshes={len(r.get('refreshes', []))} "
              f"load={r['loadAverageStart']}..{r['loadAverageEnd']} "
              f"endedOnDeadline={r['endedOnDeadline']}")
        if sf:
            vis = [w["nodesVisited"] for w, _ in sf]
            rp = [ms for _, ms in sf]
            print(f"  nodesVisited median {st.median(vis)} p90 {pct(vis, 90)}; "
                  f"render path ms median {st.median(rp):.1f} p90 {pct(rp, 90):.1f}")
        if refresh:
            print(f"  refresh ms median {st.median(refresh):.1f} p90 {pct(refresh, 90):.1f}")

print("\nper mode, every run pooled:")
for mode in ("keyed", "full"):
    vis, rp, refresh, built, reused, loads = [], [], [], [], [], []
    for d, r in runs(mode):
        for w, ms in step_frames(r):
            vis.append(w["nodesVisited"])
            rp.append(ms)
        for x in r.get("refreshes", [])[1:]:
            refresh.append(x["ms"])
            built.append(x["built"])
            reused.append(x["reused"])
        loads += [float(str(r[k]).split()[0]) for k in ("loadAverageStart",
                                                         "loadAverageEnd")
                  if str(r[k]).strip()]
    if not vis:
        print(f"{mode}: no step frames")
        continue
    print(f"{mode}: step frames {len(vis)}, nodesVisited median {st.median(vis)} "
          f"p90 {pct(vis, 90)}; render path ms median {st.median(rp):.1f} "
          f"p90 {pct(rp, 90):.1f}; refreshes {len(refresh)}, refresh ms median "
          f"{st.median(refresh) if refresh else 0:.1f} p90 {pct(refresh, 90) or 0:.1f}; "
          f"pieces built median {st.median(built) if built else 0} reused median "
          f"{st.median(reused) if reused else 0}; load "
          f"{min(loads) if loads else '?'}..{max(loads) if loads else '?'}")
