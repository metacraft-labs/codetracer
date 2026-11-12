## origin_side_panel_confidence_test.nim
##
## THE ORIGIN SIDE PANEL SHOWS EACH HOP'S CONFIDENCE AS TEXT
## (Value-Origin-Tracking.md §3.2.2 "Side panel", §13.0).
##
## `ui/isonim_origin_chain.renderPanelDom` drew each hop's kind (in its
## accessible name), its `path:line` and its operands, and never its
## `confidence`: the cross-thread hop the RR backend tags with 0.6 (§6.3
## "Cross-thread guard") read the same as a 1.0 hop. Each hop row now carries
## `confidence <n>`, and a hop below 0.7 also the `!` glyph with the visible
## label `low confidence`.
##
## ## What is real
##
## `renderPanelDom` itself, drawing into a real DOM (jsdom), over an
## `OriginChainVM` whose `activeChain` holds the chain. The VM is built with
## only the two signals the renderer reads; no backend is involved, because
## the subject is what the panel draws from a chain it already holds. Nothing
## is mocked.
##
## Lane: `renderer-dom` — the browser target (`nim js -d:ctRenderer`, no
## `-d:nodejs`), run by `jsdom-run.mjs`. Without `-d:nodejs` `std/unittest`
## cannot set the exit status, so this suite sets it.

import std/[dom, options, strutils]

import isonim/core/signals
import ../viewmodel/viewmodels/[origin_chain_types, origin_chain_vm]
import ../ui/isonim_origin_chain

var failedChecks = 0
var checks = 0

template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
    echo "[FAILED] ", astToStr(cond)

proc hop(kind: OriginKind; line: int; confidence: float): OriginHop =
  OriginHop(kind: kind, targetExpr: "local", sourceExpr: "shared",
            location: OriginLocation(path: "main.c", line: line),
            stepId: int64(10 + line), confidence: confidence)

proc drawnHops(chain: OriginChain): seq[Element] =
  let vm = OriginChainVM(
    activeChain: createSignal(some(chain)),
    breadcrumbStack: createSignal(newSeq[BreadcrumbEntry]()))
  var panel = newOriginChainPanel()
  let host = document.createElement("div")
  renderPanelDom(host, vm, panel)
  for node in host.querySelectorAll("li.ct-origin-hop"):
    result.add node

proc text(e: Element): string = $e.textContent

block labels:
  ck hopConfidenceLabel(0.6) == "0.6"
  # The f32 the wire carries for 0.6.
  ck hopConfidenceLabel(0.6000000238418579) == "0.6"
  ck hopConfidenceLabel(0.75) == "0.75"
  ck hopConfidenceLabel(1.0) == "1.0"
  ck hopConfidenceLabel(0.0) == "0.0"
  ck isLowConfidence(0.6)
  ck isLowConfidence(0.0)
  # 0.7 is not low, including the f32 that reads 0.69999998….
  ck not isLowConfidence(0.7)
  ck not isLowConfidence(0.699999988079071)
  ck not isLowConfidence(1.0)

block sidePanel:
  let chain = OriginChain(
    queryVariable: "local",
    queryStepId: 40,
    hops: @[hop(okTrivialCopy, 9, 1.0),
            hop(okCrossThreadCopy, 5, 0.6000000238418579),
            hop(okTrivialCopy, 4, 0.9)],
    terminator: Terminator(kind: tkwLiteral, expression: "99"))
  let rows = drawnHops(chain)
  ck rows.len == 3
  if rows.len == 3:
    ck "confidence 1.0" in rows[0].text
    ck "confidence 0.6" in rows[1].text
    ck "confidence 0.9" in rows[2].text
    # Only the 0.6 hop is low-confidence, and says so in words.
    ck rows[0].querySelectorAll(".ct-origin-low-confidence").len == 0
    ck rows[1].querySelectorAll(".ct-origin-low-confidence").len == 1
    ck "! low confidence" in rows[1].text
    ck rows[2].querySelectorAll(".ct-origin-low-confidence").len == 0
    # The accessible name still says what the hop is.
    ck $rows[1].getAttribute("aria-label") == "hop 2: cross-thread copy at step 15"

echo "CHECKS: ", checks
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
