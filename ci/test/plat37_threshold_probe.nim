## plat37_threshold_probe.nim — PLAT-37's thresholds, as a PROGRAM.
##
##   nim c -r --path:src/frontend/viewmodel --path:../GuiAssert/src \
##       ci/test/plat37_threshold_probe.nim
##
## ## Why the rejected values are a program and not a comment
##
## [[Verification-Harness-Traps §36b]]: *"the winner is gated, the losers are
## prose."* When a harness picks one parameter out of several and records
## "I measured the others and they were vacuous", the winner's consequence
## gets asserted and the losers' figures get written in a comment — and the
## comment is never re-taken by anything, so it is free to be wrong or to
## have been made up. PLAT-30's display sweep published a three-row table in
## THREE documents and every figure about a pair that was not committed was
## wrong, and had been since the day it was written.
##
## So the sweep is this file. `src/tests/visual/plat37-thresholds.json` holds
## the winners with their history; the losers are re-derivable in the time it
## takes to run this, against whatever frames are in `build/plat37`.
##
## ## What "vacuous" means here, precisely
##
## A candidate threshold is admitted only if it is TWO-SIDED on this corpus:
##
##   POSITIVE  every windowed capture clears it, so the gate is not simply
##             red;
##   NEGATIVE  the BLANK CONTROL captured in the same run does NOT clear it.
##
## The negative is the half that is usually missing, and it is the half §7b
## is about: a control you have never made fail is not a control. A candidate
## that both sides clear is not a weak threshold, it is not a threshold — it
## is an expression that is true for free.
##
## ## This probe adds NO GATE of its own, deliberately
##
## §36b's third rule: do not assert in the suite that the rejected values ARE
## vacuous. That would pin a property of the corpus nothing depends on and
## make a future improvement to the frames fail a check about roads not
## taken. The remedy for a stale figure is to re-take it, which is what this
## file is for.

import std/[json, os, sequtils, strformat, tables]

import ../../src/frontend/gpui/tests/plat37_vision

const
  ManifestRel = "build/plat37/manifest.json"
  OutRel = "build/plat37/threshold-probe.json"

  SsimCandidates = [0.10, 0.20, 0.30, 0.50, 0.80, 0.95, 0.99]
    ## The frame's SSIM against the blank control must be BELOW the chosen
    ## value. 0.99 and 0.95 are here because they are the values somebody
    ## reaches for when they think of SSIM as "how similar", and the sweep is
    ## what shows whether they discriminate.
  EcrCandidates = [0.0005, 0.001, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20]
    ## The edge-change ratio against the blank control must be ABOVE it.

  NeedleWindows = [(8, 16), (8, 24), (8, 32), (12, 24), (12, 40), (8, 64),
                   (8, 1000)]
    ## **THE OCR JOIN'S NEEDLE-LENGTH WINDOW, WHICH IS THE PARAMETER THIS
    ## MILESTONE GOT WRONG FIRST AND THEN MEASURED.** `(8, 1000)` is the
    ## original — "the K longest strings", with no ceiling — and it is kept in
    ## the sweep rather than deleted, because a rejected candidate that is not
    ## re-derivable is a claim nothing keeps honest (§36b).
    ##
    ## Two numbers per window and both matter: the hits a scenario scores on
    ## ITS OWN frame, and the best it scores on ANOTHER scenario's. A window
    ## is admitted only if every scenario clears the floor at home AND scores
    ## strictly lower away. Shorter needles raise both, which is exactly why
    ## the away number has to be in the table.

proc main() =
  if not fileExists(ManifestRel):
    quit("plat37 threshold probe: " & ManifestRel & " is not here.\n" &
         "  Run `bash ci/test/plat37-window-frame.sh` first. This probe " &
         "measures REAL captures;\n  a probe over a constructed image would " &
         "be measuring its own fixture.", 1)
  let manifest = parseJson(readFile(ManifestRel))
  let windowed = runsByScenario(manifest, "windowed")

  var metrics = initOrderedTable[string, VisionMetrics]()
  var blankMetrics = initOrderedTable[string, VisionMetrics]()
  var joins = initOrderedTable[string, OcrJoin]()
  var crossJoins = initOrderedTable[string, int]()

  for id, run in windowed:
    if run.outcome != "captured": continue
    metrics[id] = measureFrame(run.frame, run.blank)
    # THE CONTROL, MEASURED THROUGH THE SAME FUNCTION. `measureFrame(blank,
    # blank)` is the blank control scored against itself — SSIM 1.0, edge
    # change 0.0 — and it is what every candidate below has to FAIL on.
    blankMetrics[id] = measureFrame(run.blank, run.blank)

  echo "=== the corpus ==="
  echo &"{\"scenario\":<24} {\"ssim\":>8} {\"ecr\":>8} {\"nonBlack\":>10}"
  for id, m in metrics:
    echo &"{id:<24} {m.ssimVsBlank:>8.4f} {m.edgeChangeRatioVsBlank:>8.4f} " &
         &"{m.nonBlackFraction:>10.4f}"
  echo &"{\"(blank control)\":<24} " &
       &"{blankMetrics[toSeq(blankMetrics.keys)[0]].ssimVsBlank:>8.4f} " &
       &"{blankMetrics[toSeq(blankMetrics.keys)[0]].edgeChangeRatioVsBlank:>8.4f}"

  var report = %*{"corpus": newJObject(), "ssim": newJArray(),
                  "ecr": newJArray(), "needleWindows": newJArray(),
                  "ocr": newJObject()}
  for id, m in metrics:
    report["corpus"][id] = %*{
      "ssimVsBlank": m.ssimVsBlank,
      "edgeChangeRatioVsBlank": m.edgeChangeRatioVsBlank,
      "nonBlackFraction": m.nonBlackFraction}

  echo ""
  echo "=== candidate: frame SSIM against the blank control must be BELOW ==="
  for cand in SsimCandidates:
    var positives = 0
    var negatives = 0
    for id, m in metrics:
      if m.ssimVsBlank < cand: inc positives
      if blankMetrics[id].ssimVsBlank < cand: inc negatives
    let admitted = positives == metrics.len and negatives == 0
    echo &"  {cand:>6.2f}  frames clearing it {positives}/{metrics.len}, " &
         &"blank controls clearing it {negatives}/{metrics.len}  -> " &
         (if admitted: "ADMITTED"
          elif negatives > 0: "REJECTED: the blank control clears it too"
          else: "REJECTED: a real frame does not clear it")
    report["ssim"].add %*{"candidate": cand, "positives": positives,
                          "negatives": negatives, "admitted": admitted}

  echo ""
  echo "=== candidate: edge-change ratio against the control must be ABOVE ==="
  for cand in EcrCandidates:
    var positives = 0
    var negatives = 0
    for id, m in metrics:
      if m.edgeChangeRatioVsBlank > cand: inc positives
      if blankMetrics[id].edgeChangeRatioVsBlank > cand: inc negatives
    let admitted = positives == metrics.len and negatives == 0
    echo &"  {cand:>8.4f}  frames clearing it {positives}/{metrics.len}, " &
         &"blank controls clearing it {negatives}/{metrics.len}  -> " &
         (if admitted: "ADMITTED"
          elif negatives > 0: "REJECTED: the blank control clears it too"
          else: "REJECTED: a real frame does not clear it")
    report["ecr"].add %*{"candidate": cand, "positives": positives,
                         "negatives": negatives, "admitted": admitted}

  # THE OCR TEXT IS TAKEN ONCE PER FRAME. Every window below scores every
  # scenario's needles against every scenario's frame, which is O(n²)
  # comparisons over O(n) OCR runs; tesseract on a 1920x1080 frame is seconds
  # rather than milliseconds, so re-reading inside the sweep would make the
  # sweep something nobody runs, which is how a "runnable probe" becomes a
  # table in a comment after all (§36b).
  var ocrText = initOrderedTable[string, string]()
  for id, run in windowed:
    if run.outcome != "captured": continue
    ocrText[id] = frameOcrText(run.frame)

  # THE EDIT-MODE FRAME, which is the ONE frame in this run that draws
  # different TEXT. `ct edit --ui=gpui src/frontend/gpui` opens the
  # front-end's own working tree rather than the `calc` recording, so its
  # screen shares the pane chrome with the six and shares none of the source.
  # Same binary, same compositor, same run.
  var editText = ""
  var editFrame = ""
  for run in runsInOrder(manifest, "productModes", "windowed"):
    if run.outcome == "captured" and run.frame.len > 0:
      editFrame = run.frame
      editText = frameOcrText(run.frame)
  if editText.len == 0:
    echo "NOTE: no edit-mode frame in this manifest; the different-content " &
         "control cannot be measured."

  # The other scenarios' plans, per scenario: what `distinctiveNeedles`
  # subtracts. Read once.
  var otherPlans = initOrderedTable[string, seq[string]]()
  for id, run in windowed:
    if run.outcome != "captured": continue
    var others: seq[string] = @[]
    for otherId, otherRun in windowed:
      if otherId == id or otherRun.outcome != "captured": continue
      others.add readFile(otherRun.plan)
    otherPlans[id] = others

  echo ""
  echo "=== candidate: the NEEDLE-LENGTH WINDOW, and the SELECTOR ==="
  echo "    (own = its own frame; away = best on another SCENARIO's;"
  echo "     edit = the edit-mode frame, the one screen drawing other text)"
  echo "    selector `longest`     : the K longest strings in the window"
  echo "    selector `distinctive` : the K longest strings NO OTHER scenario draws"
  for selector in ["longest", "distinctive"]:
   for window in NeedleWindows:
    let (lo, hi) = window
    var worstOwnRatio = 1.0
    var worstMargin = 999
    var worstEditMargin = 999
    var kMin = 9999
    var line = ""
    for id, run in windowed:
      if run.outcome != "captured": continue
      let needles =
        if selector == "longest": planNeedles(readFile(run.plan), lo, hi)
        else: distinctiveNeedles(readFile(run.plan), otherPlans[id], lo, hi)
      let own = ocrHits(needles, ocrText[id]).hits
      var away = -1
      for otherId, _ in ocrText:
        if otherId == id: continue
        let h = ocrHits(needles, ocrText[otherId]).hits
        if h > away: away = h
      # THE DIFFERENT-CONTENT CONTROL: the same needles on the edit-mode
      # frame, which draws this front-end's own source instead of the `calc`
      # recording.
      let edit = (if editText.len == 0: -1
                  else: ocrHits(needles, editText).hits)
      if needles.len < kMin: kMin = needles.len
      let ratio = (if needles.len == 0: 0.0
                   else: own.float / needles.len.float)
      if ratio < worstOwnRatio: worstOwnRatio = ratio
      if own - away < worstMargin: worstMargin = own - away
      if own - edit < worstEditMargin: worstEditMargin = own - edit
      line.add &"{own}/{needles.len}:{away}:{edit} "
    # ADMITTED only if EVERY scenario clears a floor at home AND scores
    # strictly lower away. A window that raised the numerator by making the
    # needles findable anywhere is a widening that empties the claim (§6a),
    # and the `away` column is the only thing that can see it.
    let admitted = kMin > 0 and worstOwnRatio > 0.0 and worstMargin > 0
    echo &"  {selector:<12} [{lo:>2},{hi:>4}]  minK={kMin} " &
         &"worstOwnRatio={worstOwnRatio:.3f} worstMargin={worstMargin}  -> " &
         (if admitted: "ADMITTED"
          elif kMin == 0: "REJECTED: some scenario has NO needles in this window"
          elif worstOwnRatio == 0.0: "REJECTED: some scenario scores zero at home"
          else: "REJECTED: some scenario scores no better at home than away")
    echo &"            worstEditMargin={worstEditMargin}"
    echo &"            per scenario own/K:away:edit  {line}"
    report["needleWindows"].add %*{
      "selector": selector, "minLen": lo, "maxLen": hi, "minK": kMin,
      "worstOwnRatio": worstOwnRatio, "worstMargin": worstMargin,
      "worstEditMargin": worstEditMargin, "admitted": admitted}

  echo ""
  echo "=== the OCR join at the COMMITTED selector and window, per scenario ==="
  # **`planNeedles` AND NOT `distinctiveNeedles`, AND THIS LINE HAD THE WRONG
  # ONE.** `plat37-thresholds.json` commits `"selector": "longest-in-window"`,
  # which is `planNeedles`; this section called `distinctiveNeedles` while
  # its heading said COMMITTED. The numbers it printed were therefore the
  # REJECTED selector's — `K=0` for four of the six scenarios — and the
  # derived floor below came out `0.000`, flatly contradicting the committed
  # `minHitRatio: 0.3` in a diagnostic that file sends readers to. Nothing
  # caught it because this probe deliberately gates nothing: §36b's rule
  # moves the losers out of a comment and into a program, and a program whose
  # SUMMARY is unchecked prose has carried the same hazard one level down.
  # Found and fixed at verification, 2026-09-22. With the committed selector
  # the floor below derives as 0.300, which is the committed value.
  for id, run in windowed:
    if run.outcome != "captured": continue
    let needles = planNeedles(readFile(run.plan))
    let join = ocrHits(needles, ocrText[id])
    joins[id] = join
    # THE CROSS TERM, which is the join's second negative control: this
    # scenario's needles scored against ANOTHER scenario's frame. A
    # normalisation loose enough to match anything scores the same here as
    # at home, and the gate requires strictly less.
    var worstOther = -1
    for otherId, _ in ocrText:
      if otherId == id: continue
      let h = ocrHits(needles, ocrText[otherId]).hits
      if h > worstOther: worstOther = h
    crossJoins[id] = worstOther
    echo &"  {id:<24} K={join.k} hits={join.hits} " &
         &"best-on-another-frame={worstOther}"
    report["ocr"][id] = %*{"k": join.k, "hits": join.hits,
                           "bestOnAnotherFrame": worstOther,
                           "needles": needles, "found": join.found}

  echo ""
  echo "=== candidate: M, the join's floor, as a fraction of K ==="
  # M is DERIVED rather than chosen: it is the largest floor every scenario
  # clears, minus nothing. Publishing the largest admissible value rather
  # than a round number is what keeps the join from being loosened later
  # without anybody noticing — a floor lowered twice is a defect in the
  # capture, not in the floor.
  var minRatio = 1.0
  for id, join in joins:
    if join.k == 0:
      echo &"  {id}: K IS ZERO — a join with no needles is satisfied by any frame"
      minRatio = 0.0
    else:
      let ratio = join.hits.float / join.k.float
      if ratio < minRatio: minRatio = ratio
  echo &"  the tightest scenario scores {minRatio:.3f} of its own K"
  report["ocr"]["minHitRatio"] = %minRatio

  createDir(OutRel.parentDir)
  writeFile(OutRel, report.pretty)
  echo ""
  echo "wrote ", OutRel

when isMainModule:
  main()
