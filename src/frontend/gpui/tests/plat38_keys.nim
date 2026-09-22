## plat38_keys.nim — PLAT-38's keystroke RECORD, and the two places it can
## come from.
##
## `ci/test/plat38-keystroke.sh` drives a real `codetracer-gpui` window under
## headless sway, sends keys through the compositor's own `wl_seat` with
## `wtype`, and writes what the RUST-SIDE ELEMENT STORE held afterwards into
## `build/plat38/manifest.json`. `test_gpui_key_delivery.nim` reads that record
## and asserts over it.
##
## ## WHY THE SPLIT, AND WHY IT IS PLAT-37's SPLIT
##
## PLAT-35's Electron arm is a recorded Playwright capture read back as JSON,
## because there is nothing for a Nim binary to link on that side. PLAT-37's
## frames are a recorded capture for a different reason — the compositor — and
## this is that reason again: the assertions are Nim, and a suite that had to
## run *inside* a nested sway to make them would be a suite nobody can run from
## an editor and nothing can run on a machine with no display.
##
## **ONE FUNCTION BUILDS THE RECORD FROM EITHER SOURCE.** A recorded corpus and
## a live corpus that were different SHAPES would let a field the recorder
## never wrote be asserted for free (`Verification-Harness-Traps.md` §4), so
## both go through `parseRecord` and the source is a field of the result rather
## than a branch around it.
##
## **NEITHER SOURCE IS A SKIP.** A missing record is a named failure. A check
## that detects a missing prerequisite, returns early and is counted as passed
## is the defect (`Silent-Self-Pass-Audit-2026-08-23.md`).

import std/[json, os, strutils]

import ../../../common/view_vocabulary/gpui_gaps

const PinnedScenarioCount* = 6
  ## The six come from `src/tests/visual/scenarios.json` — the SAME six
  ## PLAT-35 pinned and PLAT-37 captured frames for. **A seventh invented for
  ## this milestone would be a corpus that grew to fit its instrument**, and
  ## the capture script reads them from that file rather than listing them.

type
  KeyArrival* = object
    ## One key, as the shim's element store recorded it arriving.
    key*: string
      ## GPUI's own keystroke spelling, passed through the shim verbatim.
    modifiers*: seq[string]
      ## `control` / `alt` / `shift` / `platform` / `function`. A LIST rather
      ## than a rendered `"shift-f10"`: §25 — a helper that silently drops a
      ## modifier hands you a test about a different key, and a name cannot
      ## lose a member of a list without the list changing.
    kind*: string
      ## `keydown` / `keyup` / `other`.
    seq*: int
      ## The process-wide delivery sequence. 0 means nothing arrived.

  ScenarioKeys* = object
    name*: string
    outcome*: string
      ## `delivered` / `refused` / `timedout`. Written from the capture
      ## script's own control flow, never inferred from whether a file exists
      ## — a run that silently produced nothing must be indistinguishable from
      ## NEITHER of the other two.
    arrivals*: seq[KeyArrival]
    deliverySeq*: int
    deliveryCount*: int
    windowFocused*: bool
    expectModifier*: string
      ## The modifier this scenario's key carries, or "" when it carries none.
      ## Declared by the capture so the assertion is two-sided: the scenarios
      ## that send no modifier assert they received none.

  NegativeTwin* = object
    attempted*: bool
    outcome*: string
    key*: string
    deliverySeq*: int
    deliveryCount*: int

  VisionWitness* = object
    attempted*: bool
    beforeNonBlank*: bool
    afterNonBlank*: bool
    beforeVsBlank*: float
    afterVsBlank*: float
      ## How much each frame differs from the BLANK control. This is the
      ## claim the vision tier can make here — *there is a window and its
      ## pixels are not the pixels of a blank screen* — measured on both
      ## sides of the key.
    changedFraction*: float
      ## What the KEY did to the picture. **It is 0.0 on this product and
      ## that is not a capture defect**: `codetracer-gpui` has no binding
      ## from a key to a replay operation (PLAT-23's `--ui=gui` contract), so
      ## a delivered key changes the element store and not the screen. The
      ## field is carried and PRINTED rather than asserted, and PLAT-38's
      ## status records the deliverable worded as *"a key changed the
      ## screen"* as NOT met for that reason.
    threshold*: float
    blankPresent*: bool
    blankNonBlank*: bool
    blankChangedFraction*: float

  KeystrokeRecord* = object
    source*: string           ## `live` or `recorded`
    takenAt*: string
    host*: string
    sentinelKey*: string
      ## **THE LAST KEY A REAL `wl_seat` DELIVERED**, read out of the capture
      ## rather than declared by it. It is what lets the gate compare the
      ## binding's own spelling for a key against a name the COMPOSITOR
      ## produced — the only oracle that can see a binding whose encoder and
      ## decoder are each other's inverse by construction (§30a).
    scenarios*: seq[ScenarioKeys]
    negativeTwin*: NegativeTwin
    vision*: VisionWitness

const
  LiveManifest = "build/plat38/manifest.json"
  RecordedManifest = "src/tests/visual/plat38-keystrokes.json"

proc parseArrival(n: JsonNode): KeyArrival =
  result.key = n{"key"}.getStr
  result.kind = n{"kind"}.getStr
  result.seq = n{"seq"}.getInt
  for m in n{"modifiers"}.getElems:
    result.modifiers.add m.getStr

proc parseRecord*(root: JsonNode; source: string): KeystrokeRecord =
  ## **ONE PARSER, BOTH SOURCES.** See the header.
  result.source = source
  result.takenAt = root{"takenAt"}.getStr
  result.host = root{"host"}.getStr
  result.sentinelKey = root{"sentinelKey"}.getStr
  for s in root{"scenarios"}.getElems:
    var sc = ScenarioKeys(
      name: s{"name"}.getStr,
      outcome: s{"outcome"}.getStr,
      deliverySeq: s{"deliverySeq"}.getInt,
      deliveryCount: s{"deliveryCount"}.getInt,
      windowFocused: s{"windowFocused"}.getBool,
      expectModifier: s{"expectModifier"}.getStr)
    for a in s{"arrivals"}.getElems:
      sc.arrivals.add parseArrival(a)
    result.scenarios.add sc
  let t = root{"negativeTwin"}
  result.negativeTwin = NegativeTwin(
    attempted: t{"attempted"}.getBool,
    outcome: t{"outcome"}.getStr,
    key: t{"key"}.getStr,
    deliverySeq: t{"deliverySeq"}.getInt,
    deliveryCount: t{"deliveryCount"}.getInt)
  let v = root{"vision"}
  result.vision = VisionWitness(
    attempted: v{"attempted"}.getBool,
    beforeNonBlank: v{"beforeNonBlank"}.getBool,
    afterNonBlank: v{"afterNonBlank"}.getBool,
    beforeVsBlank: v{"beforeVsBlank"}.getFloat,
    afterVsBlank: v{"afterVsBlank"}.getFloat,
    changedFraction: v{"changedFraction"}.getFloat,
    threshold: v{"threshold"}.getFloat,
    blankPresent: v{"blankPresent"}.getBool,
    blankNonBlank: v{"blankNonBlank"}.getBool,
    blankChangedFraction: v{"blankChangedFraction"}.getFloat)

proc repoRoot(): string =
  ## This file is `src/frontend/gpui/tests/`; the root is four up. Derived
  ## rather than taken from the working directory, so the suite answers the
  ## same thing whether it is run from the repo root or from an editor.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

proc keystrokeRecord*(): KeystrokeRecord =
  ## The record, from whichever source is on this disk. **A missing record is
  ## a named failure**: the `raise` below is what stops a machine with no
  ## capture from reporting a green suite.
  ##
  ## `PLAT38_CORPUS` PINS THE SOURCE, and a mutation harness sets it. Without
  ## a pin an arm that corrupted the RECORDED file would SURVIVE on a
  ## workstation that had just captured — for a reason with nothing to do with
  ## the gate. That is `Verification-Harness-Traps.md` §18's second corollary
  ## (*pin the image, or the manifest measures whichever build ran last*)
  ## arriving through an environment variable. An unrecognised value is
  ## refused rather than ignored, because a pin that silently did nothing is
  ## worse than no pin.
  let root = repoRoot()
  let live = root / LiveManifest
  let recorded = root / RecordedManifest
  let pin = getEnv("PLAT38_CORPUS", "")
  case pin
  of "live":
    if not fileExists(live):
      raise newException(IOError,
        "PLAT-38: PLAT38_CORPUS=live and " & live & " is not here.")
    return parseRecord(parseJson(readFile(live)), "live")
  of "recorded":
    if not fileExists(recorded):
      raise newException(IOError,
        "PLAT-38: PLAT38_CORPUS=recorded and " & recorded & " is not here.")
    return parseRecord(parseJson(readFile(recorded)), "recorded")
  of "":
    discard
  else:
    raise newException(ValueError,
      "PLAT-38: PLAT38_CORPUS=" & pin & " is not a source. Use `live`, " &
      "`recorded`, or leave it unset.")
  if fileExists(live):
    return parseRecord(parseJson(readFile(live)), "live")
  if fileExists(recorded):
    return parseRecord(parseJson(readFile(recorded)), "recorded")
  raise newException(IOError,
    "PLAT-38: no keystroke record. Neither " & live & " nor " & recorded &
    " is on this disk. Take one with `just plat38-capture`. This is a " &
    "FAILURE and not a skip: a check that detects a missing prerequisite, " &
    "returns early and is counted as PASSED is the defect " &
    "(Silent-Self-Pass-Audit-2026-08-23.md).")

# ---------------------------------------------------------------------------
# The source scan's subject and needle
# ---------------------------------------------------------------------------

proc bindingDirectory*(): string =
  ## The directory the `vockey:` scan covers, DERIVED rather than listed — a
  ## hardcoded subject list cannot see a new file in the directory it claims
  ## to cover (§35), and that route has been walked seven times in this
  ## campaign.
  repoRoot() / "src" / "frontend" / "view_vocabulary"

proc codeOnly*(src: string): string =
  ## `src` with comment lines removed, so prose about the retired spelling
  ## cannot satisfy — or defeat — a scan for it (§4d). Line comments only:
  ## Nim has no block comment that survives this file's own subjects, and a
  ## stripper that tried to handle `#[ ]#` would be a second grammar.
  for line in src.splitLines():
    let t = line.strip()
    if t.startsWith("#"): continue
    # A trailing comment on a code line is dropped from the first `#` that is
    # not inside a string literal. Tracking the literal state matters here
    # because the needle this scan looks for would itself appear inside one.
    var inStr = false
    var cut = -1
    for i, c in line:
      if c == '"' and (i == 0 or line[i - 1] != '\\'): inStr = not inStr
      elif c == '#' and not inStr:
        cut = i
        break
    result.add (if cut >= 0: line[0 ..< cut] else: line)
    result.add "\n"

proc retiredKeyEventPrefix*(): string =
  ## **THE NEEDLE, DERIVED FROM THE RETIRED GAP'S OWN TEXT** rather than
  ## written here as a literal (§35's fifth-file route, walked four times in
  ## this campaign). `gpui_gaps.RetiredGpuiGaps` records what `PLAT21-VG1`'s
  ## escape WAS, in the sentence *"The binding encoded the key in the EVENT
  ## NAME (`vockey:Down`)"*, so a milestone that reinstated the spelling under
  ## a different constant name is still caught — and a milestone that deleted
  ## the retired row would make this function raise rather than answer an
  ## empty needle, which is what an empty needle would cost (§4).
  const marker = "EVENT NAME ("
  let what = retiredGapById("PLAT21-VG1").what
  let at = what.find(marker)
  if at < 0:
    raise newException(ValueError,
      "PLAT-38: PLAT21-VG1's retired row no longer records the spelling its " &
      "escape used, so the scan below has no needle to derive. An empty " &
      "needle satisfies every 'must not contain' written over it (§4).")
  let rest = what[at + marker.len .. ^1]
  let close = rest.find(')')
  if close < 0:
    raise newException(ValueError, "PLAT-38: the recorded spelling is unclosed")
  let spelling = rest[0 ..< close].strip(chars = {'`'})
  let colon = spelling.find(':')
  if colon < 0:
    raise newException(ValueError,
      "PLAT-38: the recorded spelling carries no prefix separator")
  spelling[0 .. colon]
