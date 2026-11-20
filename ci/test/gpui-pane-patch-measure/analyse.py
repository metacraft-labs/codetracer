# Summarise run.sh's frame reports: shim work per change frame and pane-redraw costs, per run.
import json, os, re, statistics as st, sys
base = sys.argv[1] if len(sys.argv) > 1 else "build/gpui-pane-patch-measure"
def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs)-1, int(round(p/100*(len(xs)-1))))] if xs else None
for d in sorted(os.listdir(base)):
    f = os.path.join(base, d, "frames.json")
    if not os.path.exists(f): continue
    r = json.load(open(f))
    work = r["frameWork"]; ns = r["renderPathNs"]
    # step frames: frames that did plan work after the opening (skip first 5 frames = opening)
    nz = [(i, w) for i, w in enumerate(work) if w["plansRebuilt"] > 0]
    later = [w for i, w in nz if i >= 3]
    vis = [w["nodesVisited"] for w in later]; reb = [w["plansRebuilt"] for w in later]
    el = [w["elementsBuilt"] for w in later]
    rp = [ns[i]/1e6 for i, w in nz if i >= 3 and i < len(ns)]
    pr = r.get("paneRedraws", [])
    pj = [p["planJsonNs"]/1e6 for p in pr]; pa = [p["parseNs"]/1e6 for p in pr]
    ap = [p["applyNs"]/1e6 for p in pr]; tot = [p["totalNs"]/1e6 for p in pr]
    keys = sum(1 for l in open(os.path.join(base, d, "keys.log")) if l.startswith("n "))
    print(f"{d}: full={r.get('fullRedraw')} frames={len(work)} changeFrames={len(later)} keys={keys} "
          f"load={r['loadAverageStart']}..{r['loadAverageEnd']} ended-on-deadline={r['endedOnDeadline']}")
    if vis:
        print(f"  nodesVisited median {st.median(vis)} p90 {pct(vis,90)} max {max(vis)}; plansRebuilt median {st.median(reb)} p90 {pct(reb,90)}; elementsBuilt median {st.median(el)}")
        print(f"  renderPath ms median {st.median(rp):.1f} p90 {pct(rp,90):.1f} sum {sum(rp):.0f}")
    if pr:
        print(f"  paneRedraws {len(pr)}: total ms sum {sum(tot):.0f} median {st.median(tot):.2f}; planJson sum {sum(pj):.0f} parse sum {sum(pa):.0f} apply sum {sum(ap):.0f}; replaced sum {sum(p['replaced'] for p in pr)}; planBytes median {st.median([p['planBytes'] for p in pr])}")
        by = {}
        for p in pr: by.setdefault(p["pane"], []).append(p)
        for k, v in sorted(by.items(), key=lambda kv: -sum(p['totalNs'] for p in kv[1])):
            print(f"    {k}: n={len(v)} total {sum(p['totalNs'] for p in v)/1e6:.0f} ms, json+parse {sum(p['planJsonNs']+p['parseNs'] for p in v)/1e6:.0f} ms, apply {sum(p['applyNs'] for p in v)/1e6:.0f} ms, replaced {sum(p['replaced'] for p in v)}")
# Across runs, per mode: change-frame shim work and the front-end redraw cost.
for mode in ("patch", "full"):
    vis = []; rp = []; tot = []; jp = []; steps = 0
    for d in sorted(os.listdir(base)):
        f = os.path.join(base, d, "frames.json")
        if not d.startswith(mode + "-") or not os.path.exists(f): continue
        r = json.load(open(f))
        for i, x in enumerate(r["frameWork"]):
            if i >= 3 and x["plansRebuilt"] > 0:
                vis.append(x["nodesVisited"]); rp.append(r["renderPathNs"][i] / 1e6)
        pr = r.get("paneRedraws", [])
        steps += sum(1 for p in pr if p["pane"] == "eventLog")   # one per refresh
        tot.append(sum(p["totalNs"] for p in pr) / 1e6)
        jp.append(sum(p["planJsonNs"] + p["parseNs"] for p in pr) / 1e6)
    if vis:
        print(f"{mode}: change frames {len(vis)}, nodesVisited median {st.median(vis)} p90 {pct(vis, 90)}, "
              f"render path median {st.median(rp):.0f} ms; redraw ms per run {[round(t) for t in tot]}, "
              f"plan json+parse ms per run {[round(t) for t in jp]}, "
              f"refreshes {steps}, redraw ms per refresh {sum(tot) / max(1, steps):.0f}")
