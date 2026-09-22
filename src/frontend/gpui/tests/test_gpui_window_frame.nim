## test_gpui_window_frame.nim — PLAT-37. **The gate: a window opened, and the
## frame it painted is not the frame of a blank screen.**
##
## `ci/test/plat37-window-frame.sh` opens the windows and reads the pixels
## back; it asserts almost nothing. THIS file is the gate. The split is the one
## PLAT-35 already has between `just plat35-capture-electron` and
## `test_cross_renderer_visual_alignment.nim`, and the reason here is the
## compositor: the assertions are in Nim over GuiAssert, and a suite that had
## to run *inside* a nested sway to make them would be a suite nobody can run
## from an editor and nothing can run on a machine with no display.
##
## ## THE INSTRUMENT CONTRACT, AND WHICH TIER EACH CASE BELOW IS ON
##
## PLAT-37's own §"The two instruments" binds every case here, so it is
## restated rather than assumed:
##
##   INTROSPECTION carries STRUCTURE — which panes exist, in what order,
##   carrying what text. Exact, needs no baseline, cannot drift. It is
##   satisfied by a process that builds a tree and opens no window, which is
##   the state every milestone from PLAT-20 to PLAT-35 was measured in.
##
##   VISION carries ONE claim introspection structurally cannot make: **there
##   is a window and it has pixels in it, and they are not the pixels of a
##   blank screen** — plus the JOIN, that strings introspection says are on
##   screen are legible in the frame. It carries NO structural claim. A
##   GuiAssert assertion that a pane exists would be strictly weaker than the
##   introspection assertion beside it, and there is none here.
##
## **Fifteen pre-existing cases once reported `[OK]` against a shim with no
## renderer compiled in.** Every one of them was sound and every one of them
## read a shadow tree. That is what this suite is written against, and it is
## why `DIFF-6` below is two-sided in both tiers at once: the featureless build
## must go RED on the frame and GREEN on the tree. A suite that reddened
## everywhere could not say which tier failed.
##
## ## WHERE THE NUMBERS COME FROM, AND WHY THERE ARE TWO SOURCES
##
## Every case reads ONE record, built by `plat37_vision.corpusRecord`, and the
## record has two possible sources:
##
##   `source=live`      `build/plat37/manifest.json` and the frames it names
##                      are on this disk, so the record is measured HERE, in
##                      this process, through GuiAssert.
##   `source=recorded`  they are not, so the record is the committed
##                      `src/tests/visual/plat37-measurements.json`, which is
##                      the same function's output from the machine that had a
##                      compositor.
##
## **The source is PRINTED by the first case and is never silent**, and both
## sources go through `corpusRecord`, so the recorded and the live corpus
## cannot be different shapes — a field the recorder never wrote is a field
## this suite would assert for free (§4). Neither source is a skip: a missing
## record is a named failure, because *a green run over no capture is worth
## less than a red one*.
##
## ## No mocks
##
## There is no mock compositor, no fake frame and no synthetic PPM. The
## workspace policy requires a use of one to be justified here; there is none
## to justify. Every number below came from `grim -t ppm` over a real
## `zwlr_screencopy_manager_v1` output, or from `ffmpeg -f x11grab` over a real
## Xvfb display.
##
## ## Trap 13
##
## Every helper that calls `check` is a `template`. The ones that are `proc`s
## return values and call `check` nowhere.

import std/[algorithm, json, os, sequtils, sets, strutils, tables, unittest]

import ./plat37_vision
import ../chrome
import ../replay_ops

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
#
# **WHAT MOVES IT, SO THE NEXT PERSON TO SEE IT RED KNOWS WHETHER TO WORRY.**
# It is an EXACT equality against a runtime tally and not a floor, because a
# case that silently stops running is the failure this number exists to catch
# and a floor cannot see one. Three things move it legitimately, and all three
# are deliberate edits somebody makes and defends:
#
#   * a case added or removed here;
#   * a `.nim` file added under `src/frontend/gpui/` that is not a test — the
#     registry scan asserts once per file per subject name, so the count is
#     `files x (subjects + 1)` for that case alone;
#   * a `proc x*` added to or removed from `isonim-gpui`'s `window.nim`, for
#     the same reason from the other side.
#
# The second and third are the price of a DERIVED subject set (§35a), and it
# is the right price: a hand-typed list would hold the count still and would
# also be blind to the file or the function that was just added.
const ExpectedAssertions = 535

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# The inputs, all of them read and none of them transcribed
# ---------------------------------------------------------------------------

const
  ManifestRel = "build/plat37/manifest.json"
  MeasurementsRel = "src/tests/visual/plat37-measurements.json"
  ThresholdRel = "src/tests/visual/plat37-thresholds.json"
  ScenarioRel = "src/tests/visual/scenarios.json"
  GpuiSourceDir = "src/frontend/gpui"
  WindowModuleRel = "../isonim-gpui/src/isonim_gpui/window.nim"

proc requireFile(path, why: string): string =
  ## **A MISSING PREREQUISITE FAILS BY NAME. It does not skip.** The
  ## Silent-Self-Pass audit is the reason: a check that detects a missing
  ## prerequisite, returns early and is counted PASSED is the defect.
  if not fileExists(path) and not dirExists(path):
    raise newException(IOError, path & " is not here. " & why)
  path

proc requestedSource(): string =
  ## `PLAT37_CORPUS` — `auto` (the default), `live` or `recorded`.
  ##
  ## **AN ENVIRONMENT VARIABLE AND NOT A `-d:` DEFINE**, and the reason is
  ## Verification-Harness-Traps §37a: `nim c -r … file.nim -d:FLAG` hands the
  ## define to the PROGRAM, `std/unittest` reads it as a name filter, matches
  ## nothing and exits **0** — which is how a control once passed against a
  ## build that had a renderer. A variable the process reads at run time has
  ## none of that hazard.
  ##
  ## It exists so the recorded path can be exercised on a machine that also
  ## has the frames (which is the only machine where the two could ever be
  ## compared), and so the mutation harness can grade arms against a
  ## deterministic corpus rather than against whatever is in `build/`.
  let v = getEnv("PLAT37_CORPUS", "auto").strip.toLowerAscii
  if v.len == 0: "auto" else: v

proc loadCorpus(): (JsonNode, string) =
  ## The record, and the name of where it came from.
  let want = requestedSource()
  if want notin ["auto", "live", "recorded"]:
    raise newException(ValueError,
      "PLAT37_CORPUS='" & want & "' is not one of auto, live, recorded. " &
      "An unrecognised value is refused rather than defaulted: a typo that " &
      "silently selected the other corpus would make this suite report a " &
      "verdict about a body of evidence nobody asked for.")
  if want == "live" and not fileExists(ManifestRel):
    raise newException(IOError,
      "PLAT37_CORPUS=live and " & ManifestRel & " is not here. Asking for " &
      "the live corpus and getting the recorded one is exactly the " &
      "substitution this variable exists to prevent; run " &
      "`bash ci/test/plat37-window-frame.sh` first.")
  if want != "recorded" and fileExists(ManifestRel):
    let manifest = parseJson(readFile(ManifestRel))
    (corpusRecord(manifest), "live (" & ManifestRel & ")")
  else:
    (parseJson(readFile(requireFile(MeasurementsRel,
      "PLAT-37's measurements are recorded by `ci/test/plat37_measure.nim` " &
      "from a real capture and committed, exactly as PLAT-35 commits its " &
      "Electron answers, because the capture needs a compositor and this " &
      "gate must run where there is none. Take one with:\n" &
      "    bash ci/test/plat37-window-frame.sh\n" &
      "    nim c -r --path:src/frontend/viewmodel --path:../GuiAssert/src \\\n" &
      "        ci/test/plat37_measure.nim\n" &
      "This is NOT skipped: a green run over no capture is worth less than " &
      "a red one."))),
     "recorded (" & MeasurementsRel & ")")

let (corpus, corpusSource) = loadCorpus()

let thresholds = parseJson(readFile(requireFile(ThresholdRel,
  "PLAT-37's vision thresholds are declared with a direction, a reason and a " &
  "history, because a threshold loosened twice is a defect in the capture. " &
  "The REJECTED candidates are a runnable program: " &
  "ci/test/plat37_threshold_probe.nim (§36b).")))

let scenarioDoc = parseJson(readFile(requireFile(ScenarioRel,
  "The scenario set is PLAT-35's, unchanged and un-renamed, and is read " &
  "rather than listed. A seventh scenario invented for this milestone " &
  "would be a corpus that grew to fit its instrument.")))

# ---------------------------------------------------------------------------
# The scenario set — read, and its cardinality asserted before anything uses it
# ---------------------------------------------------------------------------

proc scenarioIds(): seq[string] =
  result = @[]
  for sc in scenarioDoc["scenarios"]:
    result.add sc["id"].getStr

let scenarios = scenarioIds()
let expectedScenarios = scenarioDoc["expectedScenarios"].getInt

# ---------------------------------------------------------------------------
# Readers over the record
# ---------------------------------------------------------------------------

proc runEntry(config, id: string): JsonNode =
  ## One run's measurements, or a null node. NEVER a fabricated default: a
  ## reader that invented an empty object for a missing row would make every
  ## case written over it true for free (§4), which is the exact defect that
  ## let a renamed question id be silently `continue`d away in PLAT-35.
  let perConfig = corpus{"runs"}{config}
  if perConfig.isNil: return nil
  perConfig{id}

proc modeEntry(config, id: string): JsonNode =
  let perConfig = corpus{"productModes"}{config}
  if perConfig.isNil: return nil
  perConfig{id}

proc configurationRow(id: string): JsonNode =
  let rows = corpus{"configurations"}
  if rows.isNil or rows.kind != JArray: return nil
  for row in rows:
    if row{"id"}.getStr == id: return row
  nil

proc shimReading(config: string): JsonNode =
  let shims = corpus{"shims"}
  if shims.isNil: return nil
  shims{config}

proc sonamesOf(config: string): HashSet[string] =
  result = initHashSet[string]()
  let reading = shimReading(config)
  if reading.isNil: return
  let names = reading{"sonames"}
  if names.isNil or names.kind != JArray: return
  for n in names:
    # The `ldd` line is `<soname> => <path> (<addr>)` or `<soname> (<addr>)`;
    # the lane already reduced it to the first field. Store paths are
    # deliberately NOT part of the comparison: they move with every nixpkgs
    # bump and the claim is about which LIBRARIES are linked, not where this
    # machine keeps them.
    result.incl n.getStr

proc gpuiSymbolsOf(config: string): HashSet[string] =
  result = initHashSet[string]()
  let reading = shimReading(config)
  if reading.isNil: return
  let syms = reading{"gpuiSymbols"}
  if syms.isNil or syms.kind != JArray: return
  for s in syms:
    result.incl s.getStr

let maxSsim = thresholds["maxSsimVsBlank"]["value"].getFloat
let minEcr = thresholds["minEdgeChangeRatioVsBlank"]["value"].getFloat
let minHitRatio = thresholds["ocrJoin"]["minHitRatio"]["value"].getFloat
let minK = thresholds["ocrJoin"]["minK"].getInt

# The three vision predicates, spelled ONCE. Every case that asserts one, and
# every case that asserts its NEGATION on the blank control, calls the same
# function — so the arming and the claim cannot be two different predicates,
# which is the shape where the control agrees with itself while the rule is
# broken (§30).
proc framePassesSsim(entry: JsonNode): bool =
  (not entry.isNil) and entry{"measured"}.getBool and
    entry{"ssimVsBlank"}.getFloat(2.0) < maxSsim

proc controlPassesSsim(entry: JsonNode): bool =
  (not entry.isNil) and entry{"measured"}.getBool and
    entry{"blankSelfSsim"}.getFloat(2.0) < maxSsim

proc framePassesEcr(entry: JsonNode): bool =
  (not entry.isNil) and entry{"measured"}.getBool and
    entry{"edgeChangeRatioVsBlank"}.getFloat(-1.0) > minEcr

proc controlPassesEcr(entry: JsonNode): bool =
  (not entry.isNil) and entry{"measured"}.getBool and
    entry{"blankSelfEdgeChangeRatio"}.getFloat(-1.0) > minEcr

proc joinHolds(entry: JsonNode): bool =
  if entry.isNil: return false
  let k = entry{"ocrK"}.getInt(0)
  if k < minK: return false
  entry{"ocrHits"}.getInt(0).float / k.float >= minHitRatio

# ===========================================================================
# THE CAPTURE PARTITION, and the source of every number below it
# ===========================================================================

suite "PLAT-37: the corpus, its source and its partition":

  test "the record names where it came from, and the scenario set is read":
    echo "  PLAT-37 corpus source=", corpusSource
    let provenance = corpus{"provenance"}
    if provenance.isNil:
      echo "  provenance: measured in this process"
    else:
      echo "  provenance: written ", provenance{"writtenAt"}.getStr,
           " from ", provenance{"manifest"}.getStr
    ck corpusSource.len > 0
    # AND THE REQUEST WAS HONOURED. `PLAT37_CORPUS=recorded` on a machine
    # that also has `build/plat37/` must NOT quietly read the live frames:
    # a verdict about a different body of evidence from the one asked for is
    # the substitution this assertion exists to catch.
    let want = requestedSource()
    echo "  PLAT37_CORPUS=", want
    ck (want != "recorded") or corpusSource.startsWith("recorded")
    ck (want != "live") or corpusSource.startsWith("live")
    # The scenario set is READ and its own declared cardinality is asserted
    # against the parsed length, so a parser that stopped early cannot pass.
    ck scenarios.len == expectedScenarios
    ck expectedScenarios == 6
    ck scenarios.toHashSet.len == scenarios.len
    # And the record agrees about how many there are, in the record's own
    # copy of that number rather than in this reader's.
    ck corpus{"expectedScenarios"}.getInt(0) == expectedScenarios

  test "every windowed run ended in exactly ONE of the three partition states":
    # **THE PARTITION IS AN EQUALITY AGAINST THE SCENARIO SET'S CARDINALITY,
    # not a count of rows that reported.** A capture that silently produced
    # nothing must be indistinguishable from NEITHER of the other two, which
    # is the Silent-Self-Pass rule applied to a compositor (§34: the
    # population, not the property — read off the runs that HAPPENED).
    const States = ["captured", "refused", "timedout"]
    var tally = initCountTable[string]()
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      let outcome = if entry.isNil: "<missing>" else: entry{"outcome"}.getStr
      ck outcome in States
      tally.inc outcome
    var total = 0
    for state in States:
      total += tally[state]
    echo "  windowed partition: ", $tally
    ck total == expectedScenarios

  test "the featureless arm ran the SAME scenario set, so DIFF-6 is a pair":
    # A differential measures only what its two sides compute differently
    # (§30a). If the featureless arm had run four scenarios and the windowed
    # arm six, the difference in frames would be partly a difference in
    # POPULATION, and the two would not be comparable at all.
    for id in scenarios:
      let entry = runEntry("featureless", id)
      ck not entry.isNil
      ck (entry.isNil or entry{"ops"}.getStr ==
          runEntry("windowed", id){"ops"}.getStr)

# ===========================================================================
# THE FOUR COMPOSITOR CONFIGURATIONS — each RUN, none quoted
# ===========================================================================
#
# PLAT-19 measured four and this milestone's floor counts them, so they are
# four MEASUREMENTS. A gate whose evidence for *"Xvfb paints nothing"* were a
# `grep` over a comment would be §35 — a scan is only as strong as its subject
# set, and the subject set of a prose scan is prose.

suite "PLAT-37: the four compositor configurations":

  const ExpectedConfigurations = ["sway-pixman", "sway-gles2", "weston", "xvfb"]

  test "the configuration set is exactly the four that were measured":
    let rows = corpus{"configurations"}
    ck (not rows.isNil) and rows.kind == JArray
    var ids: seq[string] = @[]
    if not rows.isNil and rows.kind == JArray:
      for row in rows: ids.add row{"id"}.getStr
    # Both directions and then the cardinality — the last line is the one
    # usually omitted, and without it the two differences are both satisfied
    # by two empty sets.
    let seen = ids.toHashSet
    let want = ExpectedConfigurations.toHashSet
    ck (seen - want).len == 0
    ck (want - seen).len == 0
    ck ids.len == ExpectedConfigurations.len

  # One predicate for "this configuration painted", so the three that ran are
  # compared on ONE quantity and each is TWO-SIDED against its own blank
  # control. Written once: three copies of a comparison is §30, and the arm
  # that matters — the control — is the one a copy drops.
  proc painted(row: JsonNode): bool =
    (not row.isNil) and row{"frame"}.getStr.len > 0 and
      row{"blank"}.getStr.len > 0 and
      row{"nonNulRatio"}.getFloat(-1.0) > 0.5 and
      row{"blankNonNulRatio"}.getFloat(1.0) < 0.01

  template configurationEcho(row: JsonNode) =
    echo "  ", row{"id"}.getStr, ": ran=", row{"ran"}.getBool,
         " frame=", row{"nonNulRatio"}.getFloat,
         " blank=", row{"blankNonNulRatio"}.getFloat

  test "sway with wlroots' PIXMAN renderer paints the window":
    # This is the configuration the capture passes themselves run under:
    # `wayland-run-test.sh` reads `WLR_RENDERER="${WLR_RENDERER:-pixman}"`, so
    # the default arm is the software one. Every published sentence about this
    # lane had called the default "gles2".
    let row = configurationRow("sway-pixman")
    ck not row.isNil
    ck (not row.isNil) and row{"ran"}.getBool
    configurationEcho(row)
    ck painted(row)

  test "sway with wlroots' GLES2 renderer paints the window too":
    let row = configurationRow("sway-gles2")
    ck not row.isNil
    ck (not row.isNil) and row{"ran"}.getBool
    configurationEcho(row)
    ck painted(row)

  test "weston is refused BY NAME, and the refusal was executed":
    # "We would refuse it" and "we refused it" are different claims and only
    # one of them is a measurement. The lane runs the refusal and records its
    # exit status and the reason it printed.
    let row = configurationRow("weston")
    ck not row.isNil
    ck (not row.isNil) and not row{"ran"}.getBool
    ck (not row.isNil) and row{"refusedByName"}.getBool
    ck (not row.isNil) and row{"rc"}.getInt(0) != 0
    # And it took no frame, which is what distinguishes "refused" from
    # "ran and produced nothing". Those are different states and the row
    # must not be readable as either.
    ck (not row.isNil) and row{"frame"}.getStr.len == 0

  test "Xvfb opens a window and PAINTS — the published answer was wrong":
    # **THIS CASE ASSERTS THE OPPOSITE OF WHAT FOUR MILESTONES PUBLISHED, AND
    # THAT IS THE POINT OF RE-TAKING IT.** PLAT-19's measurement, PLAT-37's
    # own deliverable, `wayland-run-test.sh`'s header and
    # `nix/shells/ci-base.nix` all say Xvfb *"opens a viewable window and
    # paints nothing"*, citing `libEGL warning: DRI3 error`. Re-measured
    # 2026-09-22 with the windowed shim: the X framebuffer goes from 3.7e-05
    # non-NUL with no client to 0.62 with `codetracer-gpui` running, and the
    # frame is the whole front-end. The EGL warning is still printed; the
    # conclusion drawn from it does not follow, because wgpu falls back to a
    # software Vulkan device.
    #
    # §36b: a figure no gate keeps is free to be wrong. This one was carried
    # across five documents for four milestones with nothing re-taking it,
    # and it is now a gated measurement rather than a quotation.
    #
    # **WHAT DOES NOT CHANGE IS THE LANE'S COMPOSITOR.** The capture path is
    # `grim`, which speaks `zwlr_screencopy_manager_v1` — a Wayland protocol
    # that does not exist on an X display. sway stays because of what READS
    # it, not because X paints nothing.
    let row = configurationRow("xvfb")
    ck not row.isNil
    ck (not row.isNil) and row{"ran"}.getBool
    configurationEcho(row)
    ck painted(row)
    # The same predicate as the two sway rows, so "it paints" means the same
    # thing in all three — and the X row's own blank control is what makes it
    # a measurement rather than a reading of a bright screen.
    ck (not row.isNil) and
       row{"nonNulRatio"}.getFloat(0.0) >
       row{"blankNonNulRatio"}.getFloat(1.0) * 100.0

# ===========================================================================
# THE TWO SHIM BUILDS — the feature's selection asserted from the ARTEFACT
# ===========================================================================

suite "PLAT-37: the shims, and DIFF-6":

  test "the WINDOWED shim links a Wayland/xkb stack":
    # PLAT-23 measured the feature's ABSENCE as an `ldd` closure of libgcc +
    # libc. This is the presence, read from the cdylib rather than from the
    # build file — `just build-gpui` only WARNS when the cdylib is missing, so
    # a build that silently linked the stub is the state this reading exists
    # against.
    let windowed = sonamesOf("windowed")
    let featureless = sonamesOf("featureless")
    echo "  windowed sonames: ", toSeq(windowed).sorted.join(" ")
    ck windowed.len > featureless.len
    let added = windowed - featureless
    echo "  added by --features gpui-backend: ", toSeq(added).sorted.join(" ")
    ck added.len == 4
    ck "libxkbcommon.so.0" in added
    ck "libxcb.so.1" in added

  test "the FEATURELESS shim links libgcc and libc and nothing else":
    let featureless = sonamesOf("featureless")
    echo "  featureless sonames: ", toSeq(featureless).sorted.join(" ")
    ck featureless.len == 4
    ck "libc.so.6" in featureless
    ck "libgcc_s.so.1" in featureless
    ck "libxkbcommon.so.0" notin featureless

  test "the two shims export the SAME gpui_ symbol set":
    # **SO THE DISCRIMINATOR CANNOT BE THE SYMBOL TABLE**, and that is not an
    # accident of this build: `isonim-gpui` keeps the exported symbol set
    # stable across feature selections on purpose, so a consumer does not
    # fail to LINK depending on how the shim was configured. It means an
    # artefact-level claim about the feature has to be about the `ldd`
    # closure, and it means the only instrument that can see `DIFF-6` at run
    # time is a picture — the shadow tree both builds produce is identical.
    let windowed = gpuiSymbolsOf("windowed")
    let featureless = gpuiSymbolsOf("featureless")
    let headless = gpuiSymbolsOf("headless")
    ck windowed.len > 0
    ck (windowed - featureless).len == 0
    ck (featureless - windowed).len == 0
    ck windowed.len == featureless.len
    ck windowed.len == headless.len

  test "DIFF-6: the windowed build produced frames and the featureless none":
    # **THE DIFFERENTIAL, AND IT IS THE ONLY ONE THIS MILESTONE HAS.** Same
    # binary, same compositor, same scenarios, same budget — and `use_shim`
    # selects the arm by putting the right bytes at the ABSOLUTE path
    # `bindings.nim` bakes into the `{.dynlib.}` pragma, because `dlopen` on
    # an absolute path does not consult `LD_LIBRARY_PATH` at all. A lane that
    # switched arms with an environment variable would have run both sides
    # against whichever shim was at that path, and would have compared a build
    # with itself.
    var windowedFrames = 0
    var featurelessFrames = 0
    for id in scenarios:
      if runEntry("windowed", id){"hasFrame"}.getBool: inc windowedFrames
      if runEntry("featureless", id){"hasFrame"}.getBool: inc featurelessFrames
    echo "  frames: windowed=", windowedFrames, " featureless=",
         featurelessFrames, " of ", scenarios.len
    ck windowedFrames == scenarios.len
    ck featurelessFrames == 0

# ===========================================================================
# THE TWO PIXEL PATHS, LABELLED — an off-screen buffer is not a window
# ===========================================================================

suite "PLAT-37: the two pixel paths, and which one carries G1":

  test "the windowed path needs a compositor and SATISFIES G1":
    let path = corpus{"pixelPaths"}{"windowed-grim"}
    ck not path.isNil
    ck (not path.isNil) and path{"needsCompositor"}.getBool
    ck (not path.isNil) and path{"satisfiesG1"}.getBool
    ck (not path.isNil) and path{"how"}.getStr.len > 40

  test "the windowed path PRODUCED a frame, on a named host":
    # PLAT-23's G1 threshold, unaltered: *"at least one codetracer-gpui window
    # opened on some host, and a frame observed. The host is named. A render
    # plan is not one."*
    let host = corpus{"host"}
    ck not host.isNil
    echo "  host: ", host{"uname"}.getStr, " / ", host{"compositor"}.getStr
    echo "  ffmpeg: ", host{"ffmpeg"}.getStr
    echo "  tesseract: ", host{"tesseract"}.getStr
    ck (not host.isNil) and host{"uname"}.getStr.len > 0
    ck (not host.isNil) and host{"compositor"}.getStr.contains("sway")
    # GuiAssert's flake pins nixpkgs `b6018f87` and names NO version string
    # for either binary, so an OCR or SSIM figure is only meaningful with
    # these beside it. Asserted present, never quoted from a document.
    ck (not host.isNil) and host{"ffmpeg"}.getStr.len > 0
    ck (not host.isNil) and host{"tesseract"}.getStr.len > 0

  test "the headless path needs NO compositor and does NOT satisfy G1":
    # **NOT A SUBSTITUTE, AND THE REASON IS PLAT-23'S OWN THRESHOLD.** G1 asks
    # that a window has been observed. An off-screen RGBA buffer is a frame;
    # it is not a window. Both values are asserted rather than either inferred
    # from the other, so a future reader cannot take one for the other.
    let path = corpus{"pixelPaths"}{"headless-render-to-pixels"}
    ck not path.isNil
    ck (not path.isNil) and not path{"needsCompositor"}.getBool
    ck (not path.isNil) and not path{"satisfiesG1"}.getBool
    ck (not path.isNil) and path{"why"}.getStr.len > 40

  test "the headless probe's answer is recorded whichever way it came out":
    # **A `RendererUnavailable` HERE IS A MEASUREMENT, NOT A FAILURE.** This
    # re-takes PLAT-19's residual — *"Linux headless pixel capture is
    # upstream's gap at 562a0e03"* — against the pinned `gpui-pre 0.3.5`
    # shim, and the gate asserts what the measurement SAYS rather than what
    # anyone hoped it would say. What it may NOT say is nothing: a probe that
    # produced no answer and a probe that answered "unavailable" are different
    # states, and the lane fails loudly on the first.
    let probe = corpus{"headlessProbe"}
    ck not probe.isNil
    echo "  gpui-headless: rc=", probe{"rc"}.getInt,
         " (", probe{"rcMeaning"}.getStr, ") bytes=", probe{"bytes"}.getInt,
         " nonZero=", probe{"nonZeroBytes"}.getInt,
         " producedAFrame=", probe{"producedAFrame"}.getBool
    ck (not probe.isNil) and probe{"rcMeaning"}.getStr.len > 0
    ck (not probe.isNil) and probe{"rcMeaning"}.getStr != "unknown-" &
       $probe{"rc"}.getInt
    ck (not probe.isNil) and not probe{"satisfiesG1"}.getBool
    # And the two claims are answered SEPARATELY: whether a frame came back,
    # and whether that would close G1. The second is `false` no matter what
    # the first is.
    ck (not probe.isNil) and
       (probe{"producedAFrame"}.getBool == (probe{"rc"}.getInt == 0 and
        probe{"nonZeroBytes"}.getInt > 0 and
        probe{"bytes"}.getInt == probe{"expectedBytes"}.getInt))

# ===========================================================================
# THE TWO PRODUCT MODES, each reaching a window through the shipped binary
# ===========================================================================

suite "PLAT-37: both product modes reach a window":

  test "ct replay --ui=gpui reaches a window":
    # PLAT-23 ran this and measured 0.11-0.14 s, no output, nothing opened,
    # exit 0. That transcript is the control this milestone inverts, and the
    # inversion is the frame plus the elapsed time: a run that opened a window
    # and held it cannot also take a tenth of a second.
    var reached = 0
    for id in scenarios:
      let entry = runEntry("windowed", id)
      if (not entry.isNil) and entry{"productMode"}.getStr == "debug" and
         entry{"hasFrame"}.getBool: inc reached
    echo "  pmDebug: ", reached, " of ", scenarios.len, " runs reached a frame"
    ck reached == scenarios.len

  test "ct edit --ui=gpui reaches a window, and it is a DIFFERENT subject":
    # `ProductMode` has two members and PLAT-16's whole point is that it is a
    # different axis from the front-end. Edit mode opens no recording at all
    # (`sourceContractFor(pmEdit)`: the origin is the WORKING TREE), so a lane
    # that only ever ran `ct replay --ui=gpui` would be asserting that ONE of
    # the two modes reaches a window and saying nothing about the other.
    let entry = modeEntry("windowed", "edit-mode")
    ck not entry.isNil
    ck (not entry.isNil) and entry{"productMode"}.getStr == "edit"
    ck (not entry.isNil) and entry{"outcome"}.getStr == "captured"
    ck (not entry.isNil) and entry{"hasFrame"}.getBool
    ck (not entry.isNil) and entry{"measured"}.getBool
    # The same vision predicate as every debug-mode frame, not a weaker one.
    ck framePassesSsim(entry)
    ck framePassesEcr(entry)
    # And the featureless arm produced no edit-mode frame either, so the
    # second product mode carries `DIFF-6` as well as the first.
    let control = modeEntry("featureless", "edit-mode")
    ck (not control.isNil) and not control{"hasFrame"}.getBool

# ===========================================================================
# THE SIX PINNED SCENARIOS, EACH CAPTURED
# ===========================================================================

suite "PLAT-37: the six pinned scenarios were each captured":

  for id in scenarios:
    test "'" & id & "' was captured, with a blank control and a plan":
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      ck (not entry.isNil) and entry{"outcome"}.getStr == "captured"
      ck (not entry.isNil) and entry{"hasFrame"}.getBool
      # **THE BLANK CONTROL IS PART OF BEING CAPTURED, not part of the
      # assertion.** Every vision case below is a comparison against it, and
      # a comparison with nothing on the other side is satisfied for free
      # (§4, §7b). A scenario with no control is `refused`, never `captured`.
      ck (not entry.isNil) and entry{"hasBlank"}.getBool
      # And the PLAN, which is the introspection reading of the very tree
      # that was painted — written by the same process in the same run, so
      # the OCR join below is between two readings of ONE tree rather than
      # two runs that can disagree.
      ck (not entry.isNil) and entry{"hasPlan"}.getBool
      ck (not entry.isNil) and entry{"measured"}.getBool

# ===========================================================================
# THE VISION TIER — three assertions, six scenarios, every one two-sided
# ===========================================================================

suite "PLAT-37: the frame is not the blank screen":

  for id in scenarios:
    test "'" & id & "': SSIM against the blank control is below the ceiling":
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      echo "  ", id, " ssim=", entry{"ssimVsBlank"}.getFloat,
           " (ceiling ", maxSsim, ", control ",
           entry{"blankSelfSsim"}.getFloat, ")"
      ck framePassesSsim(entry)
      # **THE CONTROL, THROUGH THE SAME PREDICATE, AND IT MUST FAIL.** A
      # window that opened and painted nothing scores 1.0 against the blank
      # control, which is exactly the pass-shaped failure this tier exists to
      # see. A control you have never made fail is not a control (§7b).
      ck not controlPassesSsim(entry)
      ck (not entry.isNil) and entry{"blankSelfSsim"}.getFloat(0.0) > 0.99

  for id in scenarios:
    test "'" & id & "': the frame has STRUCTURE, not merely luminance":
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      echo "  ", id, " edgeChangeRatio=",
           entry{"edgeChangeRatioVsBlank"}.getFloat,
           " (floor ", minEcr, ", control ",
           entry{"blankSelfEdgeChangeRatio"}.getFloat, ")"
      # **WHY TWO IMAGE METRICS AND NOT ONE.** SSIM alone can be moved by a
      # uniform luminance shift — a frame that is merely a different shade of
      # nothing would score low against a black screen while containing no
      # structure at all. This asks the second question. A flat fill clears
      # the first and fails this one, and only the pair can tell that from a
      # drawn screen.
      ck framePassesEcr(entry)
      ck not controlPassesEcr(entry)
      ck (not entry.isNil) and
         entry{"blankSelfEdgeChangeRatio"}.getFloat(1.0) < 0.000001

  for id in scenarios:
    test "'" & id & "': the OCR join holds, with a non-zero denominator":
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      let k = entry{"ocrK"}.getInt(0)
      let hits = entry{"ocrHits"}.getInt(0)
      echo "  ", id, " OCR ", hits, "/", k, " (floor ", minHitRatio,
           " of K, minK ", minK, ")"
      # **K IS DERIVED FROM THE PLAN AND NEVER FROM A LIST.** A hand-written
      # list of expected strings is a fixture, and a fixture is satisfied by
      # a front-end that draws the fixture. K is the count of the longest
      # distinct normalised strings the render plan carries for THIS
      # scenario.
      ck k >= minK
      # A join whose K is zero is satisfied by ANY frame — §4 arriving
      # through an empty numerator — so the denominator is asserted
      # separately from the ratio.
      ck k > 0
      ck joinHolds(entry)

suite "PLAT-37: the OCR join's two negative controls":

  test "the needles score ZERO on the blank control captured beside the frame":
    # The first control. If a scenario's needles were legible on a blank
    # screen, the join would be measuring the OCR normalisation rather than
    # the window.
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      let onBlank = entry{"ocrHitsOnBlank"}.getInt(-1)
      echo "  ", id, " needles on its own blank control: ", onBlank
      ck onBlank == 0

  test "the needles score STRICTLY LOWER on a DIFFERENT-CONTENT frame":
    # The second control, and it is what stops `ocrNormalise` from being a
    # widening that empties the claim (§6a): a normalisation loose enough to
    # match anything scores the same on any screen as at home.
    #
    # **PLAT-37 PUBLISHES THIS CONTROL AS *ANOTHER SCENARIO'S* FRAME AND THAT
    # CONTROL CANNOT LAND ON THIS CORPUS.** Measured by the threshold probe
    # over every needle window and two selectors: at the committed window the
    # per-scenario `own : away` pairs are `3:3 3:3 5:5 3:2 5:6 3:3`, and no
    # window has every scenario scoring strictly better at home. The cause is
    # the corpus, not the metric — all six open the SAME recording and draw
    # the SAME source, so the strings OCR can read are very largely shared
    # (§34, the population). §36's rule for a published control that cannot
    # land is that the repair goes to the ASSERTION or to the DESIGN, never to
    # the measurement.
    #
    # So the control that IS gated is the EDIT-MODE frame: the same binary,
    # the same compositor, the same run, the same pane chrome, drawing this
    # front-end's own working tree instead of the `calc` recording. It is the
    # one screen in the capture whose TEXT is different, and it scores zero
    # against every scenario's needles.
    #
    # The cross-scenario number is still COMPUTED AND PRINTED, because it is
    # the evidence for the paragraph above and a figure nothing re-takes is
    # free to be wrong (§36b). It is printed rather than asserted.
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      let own = entry{"ocrHits"}.getInt(0)
      let onEdit = entry{"ocrHitsOnEditMode"}.getInt(-1)
      let other = entry{"ocrBestOnAnotherFrame"}.getInt(-1)
      let scoredAgainst = entry{"ocrFramesScoredAgainst"}.getInt(0)
      echo "  ", id, " own=", own, " on-edit-mode=", onEdit,
           "  [recorded, not gated: best-on-another-scenario=", other,
           " over ", scoredAgainst, " frames]"
      # **THE CONTROL'S OWN POPULATION IS ASSERTED.** A control computed
      # against NO frame would be -1 and would compare less than this
      # scenario's hits for free — a control with an empty population is §34
      # arriving through a denominator.
      ck entry{"editModeFrame"}.getStr.len > 0
      ck onEdit >= 0
      ck onEdit < own
      # And the recorded cross-scenario figure is asserted to EXIST, so the
      # evidence for the paragraph above cannot quietly stop being taken.
      ck scoredAgainst == scenarios.len - 1

  test "THE POPULATION: how much of the corpus is text no other scenario draws":
    # **§34, AS A NUMBER RATHER THAN AS A WORRY.** `distinctiveNeedleCount` is
    # how many normalised strings a scenario's render plan carries that appear
    # inside NO other scenario's plan. It is what turns "six frames that paint
    # the same thing" from an impression into a measurement, and it is why the
    # cross-scenario control above is recorded rather than gated.
    #
    # The shape asserted is the CORPUS-LEVEL one — at least half the scenarios
    # carry text no other carries — and not a per-scenario floor, because two
    # of the six legitimately carry none: `stepped-editor` and
    # `breakpoint-editor` differ by a gutter MARK, and a mark is not text.
    # A per-scenario floor would demand a difference the scenario set does not
    # claim to have.
    var withDistinctiveText = 0
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      let n = entry{"distinctiveNeedleCount"}.getInt(-1)
      echo "  ", id, " draws ", n, " string(s) no other scenario draws"
      ck n >= 0
      if n > 0: inc withDistinctiveText
    echo "  scenarios carrying distinctive text: ", withDistinctiveText,
         " of ", scenarios.len
    ck withDistinctiveText * 2 >= scenarios.len

# ===========================================================================
# THE SHUTDOWN PATH — the loop ends, the lane terminates, rc 0
# ===========================================================================

suite "PLAT-37: the event loop ends and the lane terminates":

  test "gpui_launch RETURNED — every windowed run reached its own exit":
    # PLAT-19 measured that a windowed client ran past a 12 s and a 90 s cap
    # before `gpui_quit_after_ms` existed, because `gpui_launch` does not
    # return while the window does. A run that never returned would have no
    # row at all, so the assertion is that every scenario HAS one and that
    # each carries a positive elapsed time.
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      ck (not entry.isNil) and entry{"elapsedMs"}.getInt(0) > 0

  test "every windowed run terminated UNDER its cap plus a start-up margin":
    # The cap bounds the EVENT LOOP, not the process: the recording is opened
    # and the replay operations are performed before `gpui_launch` is called
    # at all, so a scenario's elapsed time is its start-up plus its cap. The
    # bound asserted here is therefore twice the cap, and the per-scenario
    # figures are printed so start-up creeping towards the cap is visible
    # before it becomes a timeout.
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      let elapsed = entry{"elapsedMs"}.getInt(0)
      let cap = entry{"quitAfterMs"}.getInt(0)
      echo "  ", id, " elapsed=", elapsed, "ms cap=", cap, "ms start-up=",
           elapsed - cap, "ms"
      ck cap > 0
      ck elapsed < 2 * cap

  test "every windowed run exited rc 0":
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      ck (not entry.isNil) and entry{"binaryRc"}.getInt(-1) == 0
    # AND SO DID THE FEATURELESS ARM. This is the half that makes `DIFF-6` a
    # difference in PIXELS rather than a difference in whether the binary
    # worked: a featureless run that crashed would produce no frame for a
    # reason that has nothing to do with the renderer.
    for id in scenarios:
      let entry = runEntry("featureless", id)
      ck (not entry.isNil) and entry{"binaryRc"}.getInt(-1) == 0

# ===========================================================================
# PLAT35-VG1, RETIRED
# ===========================================================================

suite "PLAT-37: PLAT35-VG1 is retired":

  test "the GPUI front-end's pixel half is no longer blocked":
    # `PLAT35-VG1` is *"no GPUI pixel capture exists"*, and PLAT-35's own
    # retirement rule — *a filed gap is retired when its divergence is
    # repaired* — is what forces this rather than a decision taken here. The
    # repair is demonstrated by the frames above, so the retirement is
    # asserted against THEM and not against a register entry.
    #
    # **PLAT-35's tier-1 and tier-2 cells are NOT re-counted here even though
    # this milestone unblocks them.** They are PLAT-35's floor. Counting a
    # cell twice because two milestones touch it is the padding §10.4 rule 2
    # forbids, and this milestone's claim is *a window opened*, not *the
    # alignment improved*.
    var canaries = 0
    for sc in scenarioDoc["scenarios"]:
      if sc{"tier1Canary"}.getBool: inc canaries
    ck canaries == scenarioDoc["expectedCanaries"].getInt
    # Every tier-1 canary now has a real frame behind it, which is exactly
    # what `PLAT35-VG1` said did not exist.
    for sc in scenarioDoc["scenarios"]:
      if not sc{"tier1Canary"}.getBool: continue
      let entry = runEntry("windowed", sc["id"].getStr)
      ck (not entry.isNil) and entry{"hasFrame"}.getBool

# ===========================================================================
# THE ARMING — everything above is a claim, and these are why it can fail
# ===========================================================================

suite "PLAT-37: the vision predicates can go red":

  test "all three predicates FAIL on the blank control, per scenario":
    # **§7b, executed rather than described.** The blank control is the same
    # output, the same compositor, the same run, with no client attached. If
    # the three predicates were true of it, they would be true of a window
    # that painted nothing, and the whole tier would be satisfied by the
    # state it exists to see.
    for id in scenarios:
      let entry = runEntry("windowed", id)
      ck not entry.isNil
      ck not controlPassesSsim(entry)
      ck not controlPassesEcr(entry)
      ck entry{"ocrHitsOnBlank"}.getInt(-1) == 0
      # And on the EDIT-MODE frame too, which is the second control the join
      # gates. Both are here so "the predicates can go red" covers every
      # negative the suite leans on rather than the two image metrics only.
      ck entry{"ocrHitsOnEditMode"}.getInt(-1) < entry{"ocrHits"}.getInt(0)

  test "the predicates SEPARATE the two builds, in both directions":
    # **THE FALSIFIER, AND IT IS TWO-SIDED ON PURPOSE.** The featureless build
    # must go RED on the frame and GREEN on the tree, and both halves are
    # asserted. A suite that reddened everywhere could not say which tier
    # failed — which is the tier confusion this campaign's sharpest defect is
    # made of.
    for id in scenarios:
      let windowed = runEntry("windowed", id)
      let featureless = runEntry("featureless", id)
      ck not featureless.isNil
      # RED ON THE FRAME: no frame at all, so none of the three predicates
      # can hold.
      ck not framePassesSsim(featureless)
      ck not framePassesEcr(featureless)
      ck not joinHolds(featureless)
      # GREEN ON THE TREE: the featureless build still answers the
      # introspection question. It wrote a render plan, and the plan carries
      # the same strings the windowed build's plan carries — because the
      # shadow tree is identical in the two builds, which is precisely why a
      # picture is the only instrument that can see the difference.
      ck (not featureless.isNil) and featureless{"hasPlan"}.getBool
      ck framePassesSsim(windowed)

  test "the featureless plan carries the SAME needles as the windowed plan":
    # The tree half of the falsifier, as an equality rather than as "the file
    # exists". If the featureless build's plan were EMPTY, "no frame" would
    # be explained by "nothing was built", and `DIFF-6` would be measuring a
    # broken run rather than a missing renderer.
    for id in scenarios:
      let windowed = runEntry("windowed", id)
      let featureless = runEntry("featureless", id)
      # Guarded rather than trusting: a missing row would already have
      # reddened a case above, and iterating a nil node here would ABORT the
      # process instead — which would turn one named failure into no verdict
      # at all for every case after it.
      var a, b: seq[string] = @[]
      let aNode = windowed{"needles"}
      let bNode = featureless{"needles"}
      if (not aNode.isNil) and aNode.kind == JArray:
        for n in aNode: a.add n.getStr
      if (not bNode.isNil) and bNode.kind == JArray:
        for n in bNode: b.add n.getStr
      ck a.len > 0
      ck b.len > 0
      ck a.sorted == b.sorted

# ===========================================================================
# THE VOCABULARY, THE THRESHOLDS AND THE PALETTE
# ===========================================================================

suite "PLAT-37: the replay vocabulary is scenarios.json's":

  test "the two spellings agree, in both directions, with the cardinality":
    # `--replay-ops` accepts a closed set and `scenarios.json` publishes one.
    # **Two spellings of one vocabulary is §30**, so the two are compared
    # here rather than transcribed — an operation the parser accepts and the
    # scenario file does not publish, or the reverse, fails by name.
    var published = initHashSet[string]()
    for k in scenarioDoc["operationKinds"]: published.incl k.getStr
    var accepted = initHashSet[string]()
    for k in ReplayOpKinds: accepted.incl k
    ck (published - accepted).len == 0
    ck (accepted - published).len == 0
    ck published.len == scenarioDoc["expectedOperationKinds"].getInt
    ck accepted.len == published.len

  test "every operation the scenario set USES is one the parser performs":
    # The vocabulary agreeing is not the same claim as the corpus using it:
    # a fifth member nothing performs is a member the set has for free.
    var used = initHashSet[string]()
    for sc in scenarioDoc["scenarios"]:
      for op in sc["operations"]:
        used.incl op["kind"].getStr
    echo "  operations the six scenarios use: ", toSeq(used).sorted.join(" ")
    ck used.len > 0
    for kind in used:
      ck isReplayOpKind(kind)

  test "the parser refuses what it should refuse, and names what it saw":
    # §4: a parse that matched nothing satisfies everything written over it.
    # A parser that silently skipped an unrecognised term would accept
    # `steppIn=6` and paint the entry point, and a frame taken at the wrong
    # state is worse than no frame.
    expect ReplayOpError: discard parseReplayOps("steppIn=6")
    expect ReplayOpError: discard parseReplayOps("stepIn=0")
    expect ReplayOpError: discard parseReplayOps("stepIn")
    expect ReplayOpError: discard parseReplayOps("setBreakpoint=1")
    expect ReplayOpError: discard parseReplayOps("setBreakpoint@-1")
    # And the positive twin, without which a parser that raised on
    # everything would pass the four above (§4a).
    let ops = parseReplayOps("stepIn=6,next=3,setBreakpoint@1")
    ck ops.len == 3
    ck declaredOperations(ops) == 9
    ck breakpointRow(ops) == 1

suite "PLAT-37: the thresholds are declared, directional and ratcheted":

  const Entries = ["maxSsimVsBlank", "minEdgeChangeRatioVsBlank"]

  for name in Entries:
    test "'" & name & "' carries a direction, a reason and a history":
      let entry = thresholds{name}
      ck not entry.isNil
      ck (not entry.isNil) and entry{"direction"}.getStr in ["ceiling", "floor"]
      # **THE DIRECTION IS PER ENTRY AND IS STATED ON THE ENTRY**, because two
      # of these are floors and one is a ceiling and a single spelling of
      # "raised" would be wrong for one of them.
      ck (not entry.isNil) and entry{"looseningIs"}.getStr.len > 0
      ck (not entry.isNil) and entry{"why"}.getStr.len > 60
      let history = entry{"history"}
      ck (not history.isNil) and history.kind == JArray and history.len >= 1
      # THE RATCHET: a threshold LOOSENED TWICE is a defect in the CAPTURE,
      # not in the threshold. Enforced rather than quoted.
      var loosenings = 0
      var previous = -1.0
      let ceiling = entry{"direction"}.getStr == "ceiling"
      if (not history.isNil) and history.kind == JArray:
        for h in history:
          let value = h{"value"}.getFloat
          if previous >= 0.0:
            if ceiling and value > previous: inc loosenings
            if (not ceiling) and value < previous: inc loosenings
          previous = value
      if loosenings >= 2:
        checkpoint("'" & name & "' has been loosened " & $loosenings &
                   " times; investigate what is non-deterministic in the " &
                   "capture instead of loosening it again")
      ck loosenings < 2

  test "the OCR join's floor carries the same declaration and the same ratchet":
    let entry = thresholds{"ocrJoin"}{"minHitRatio"}
    ck not entry.isNil
    ck (not entry.isNil) and entry{"direction"}.getStr == "floor"
    ck (not entry.isNil) and entry{"why"}.getStr.len > 60
    ck (not entry.isNil) and entry{"history"}.len >= 1
    ck minK > 0
    ck minHitRatio > 0.0

  test "the rejected candidates are a PROGRAM and not a table in a comment":
    # §36b: *the winner is gated, the losers are prose*. PLAT-30 published a
    # three-row table in three documents and every figure about a pair that
    # was not committed was wrong. The remedy is that the sweep is runnable,
    # so this asserts the program is IN THE TREE rather than asserting
    # anything about what it would print — a gate over the losers' values
    # would pin a property of the corpus nothing depends on.
    ck fileExists("ci/test/plat37_threshold_probe.nim")
    let probe = readFile("ci/test/plat37_threshold_probe.nim")
    ck probe.contains("SsimCandidates")
    ck probe.contains("EcrCandidates")
    # And it measures the SAME quantities this gate asserts, through the same
    # module, rather than computing its own.
    ck probe.contains("plat37_vision")

suite "PLAT-37: the window's chrome is legible":

  test "every foreground/background pair clears the contrast floor":
    # **A CHROME WHOSE FOREGROUND AND BACKGROUND ARE CLOSE TOGETHER IS A
    # WINDOW THAT OPENS, PAINTS, AND PHOTOGRAPHS AS A BLANK SCREEN** — the
    # exact failure this milestone exists to make impossible, arriving
    # through the palette instead of through the renderer. So contrast is
    # COMPUTED from the WCAG 2.x definition and the floor is a constant.
    const Pairs = [
      (crWindowForeground, crWindowBackground),
      (crWindowForeground, crPaneBackground),
      (crPaneTitleForeground, crPaneBackground),
      (crPaneTitleForeground, crWindowBackground),
    ]
    for (fg, bg) in Pairs:
      let ratio = contrastRatio(chromeOf(fg), chromeOf(bg))
      echo "  ", $fg, " on ", $bg, ": ", ratio
      ck ratio >= MinimumContrastRatio
    # **THE FLOOR CAN FAIL**, and a floor nothing has ever failed is not a
    # floor. Two colours one shade apart must not clear it.
    ck contrastRatio("#12161c", "#13171d") < MinimumContrastRatio
    # And the arithmetic is anchored at both ends of its own range.
    ck contrastRatio("#000000", "#ffffff") > 20.9
    ck contrastRatio("#7ee3c8", "#7ee3c8") == 1.0

  test "the pane width is DERIVED and degrades to a visible sliver":
    # `apply_styles_to_div` accepts `100%` / `full` or a pixel value and
    # NOTHING ELSE — no `50%`, no `1fr` — so a front-end that wants panes side
    # by side has to do the division itself.
    ck paneWidthPx(1440, 5) > 0
    ck paneWidthPx(1440, 5) * 5 <= 1440
    # Two panes are each wider than five, which is the property a division
    # has and a constant does not.
    ck paneWidthPx(1440, 2) > paneWidthPx(1440, 5)
    # A degenerate viewport produces a sliver rather than a zero-width div
    # the renderer silently drops.
    ck paneWidthPx(0, 4) >= 1
    ck paneWidthPx(1440, 0) >= 1

# ===========================================================================
# THE SCAN — and its subject set is DERIVED, twice
# ===========================================================================
#
# §35/§35a: a scan is only as strong as its DERIVED subject set, and this one
# has two subject sets, both derived, because the campaign has been defeated
# six times by a scan that was right about the set it was given.
#
#   THE NAMES come from `isonim-gpui/src/isonim_gpui/window.nim`'s own
#   exported procedures, parsed at run time. Not a list typed here: a registry
#   function added upstream would be invisible to a typed list on the day it
#   was added, which is how a scan silently stops covering the thing it names.
#
#   THE FILES are every `.nim` under `src/frontend/gpui/` that is not a test.
#   Not `main.nim` alone: the cheapest way past a one-file scan is to make the
#   call from a file the scanned one imports, and this front-end grew two new
#   modules in this very milestone.
#
# ## FOUR ATTEMPTS TO DEFEAT THIS SCAN, PERFORMED RATHER THAN IMAGINED
#
# §35's whole lesson is that a scan is believed until somebody tries it, so it
# was tried. Each of these was applied to the real tree and the gate was run.
#
#   CAUGHT  A registry name in `chrome.nim` — inside the scanned directory but
#           NOT in `main.nim`. Reported by name: *"src/frontend/gpui/chrome.nim
#           still calls the window registry: destroy"*. This is the arm that
#           certifies the FILE set rather than the name set, and it is `M10` in
#           `run-plat37-window-mutations.py`.
#
#   CAUGHT, AFTER A REPAIR TO THIS SUITE  A Nim BLOCK comment,
#           `#[ destroy requestRepaint ]#`, appended to a scanned file. The
#           stripper handles LINE comments only, so a block comment must fail
#           loudly — and the guard that was supposed to do that read
#           `"#[" notin code`, over the STRIPPED text, where `#[` had already
#           been removed for beginning with `#`. It could never fire. The
#           obvious repair, `"#[" notin raw`, was ALSO wrong and reddened on
#           the real tree: `main.nim`'s doc comment quotes Rust's
#           `#[cfg(test)]`. The guard now recognises `#[` at the position
#           where a comment BEGINS, which is where the stripper already
#           stands; the block comment fails by name and the quotation does
#           not.
#
#   **DEFEATED, AND IT STAYS DEFEATED — THE RESIDUAL.** A registry name in a
#           file OUTSIDE `src/frontend/gpui/`. Appending
#           `const Plat37ScanDefeatProbe* = "createWindow"` to
#           `src/frontend/view_vocabulary/editor_surface.nim` — which this
#           front-end imports — left the scan GREEN. The subject FILE set is a
#           DIRECTORY, not the binary's import closure, so any call made from a
#           shared module is invisible to it.
#
#           Closing it would mean deriving the file set from the actual import
#           closure, which this repository already knows how to do
#           (`ci/test/editor-import-closure.sh` and the extractor behind it).
#           That is a larger change than this milestone should make to a
#           campaign-wide mechanism, and the honest thing is to state the hole
#           with the experiment that found it rather than to describe the scan
#           as airtight. What narrows it in practice is that the shared modules
#           under `src/frontend/view_vocabulary/` and
#           `src/frontend/viewmodel/` import no renderer at all — asserted from
#           the inside by `test_gpui_shell_split.nim` and by PLAT-29's import
#           closure gate — so a registry call from one of them would have to
#           add a renderer import first.
#
#           OWNER: Zahary Karadjov <zahary@metacraft-labs.com>
#           REVIEW-BY: 2026-12-22
#           DECISION (2026-09-22, at verification): RECORDED, NOT CLOSED. The
#           decision was taken rather than deferred, and route 4 below is why
#           it is the right one: closing the DIRECTORY hole would not have
#           closed the SPELLING hole, which lived inside the scanned set and
#           needed a different repair. Swapping the file set for the import
#           closure changes a mechanism five milestones share, and doing it
#           inside a milestone whose claim is *a window opened* would put a
#           campaign-wide regression on this milestone's account.
#
#   **CAUGHT, AFTER A REPAIR TO THIS SUITE — ROUTE 4, FOUND AT VERIFICATION.**
#           A registry call in a SCANNED file, spelled the way Nim's own
#           identifier equality allows: `create_window(...)` rather than
#           `createWindow(...)`. Nim ignores underscores and case after the
#           first character, so that is a real, compiling call to
#           `createWindow` — confirmed by running a two-file program under
#           `nim c -r`, in which the caller writes `create_window("hi")` and
#           receives the callee's return value — while `"createWindow" in
#           code` is FALSE. The scan stayed green with the whole registry
#           reachable from `main.nim` itself.
#
#           This is the route the recorded residual above does NOT cover, and
#           that is the point worth keeping: the hole was not in the file set
#           at all, so deriving the file set from the import closure would
#           have left it open. The repair is `nimIdentKey` / `identifierKeys`
#           below — compare TOKENS under Nim's equality instead of searching
#           for substrings — which also fixes the opposite fault the same
#           line had, that `destroy` matched inside `gpui_destroy_element`.
#           Both directions are armed in *"and it DOES reach gpui_launch"*.

const AmbiguousWindowNames = ["state", "size", "width", "height", "show",
                              "close"]
  ## Exported by `window.nim` AND ordinary English. `cmd.width` is not a call
  ## into the window registry and a scan that said it was would be red for a
  ## reason that has nothing to do with the claim.
  ##
  ## **THE EXCLUSION IS DECLARED AND IS ITSELF CHECKED**: every name here must
  ## still be exported by that module, so an upstream rename fails this gate
  ## rather than silently emptying the exclusion and, with it, shrinking the
  ## scan.

proc exportedWindowProcs(): seq[string] =
  ## Parse `proc <name>*(` out of the sibling's window module.
  result = @[]
  for raw in readFile(requireFile(WindowModuleRel,
      "The scan's subject set is DERIVED from isonim-gpui's own window " &
      "module. A hand-typed list would be blind to a registry function added " &
      "upstream on the day it was added (§35a).")).splitLines():
    let line = raw.strip()
    if not line.startsWith("proc "): continue
    let rest = line["proc ".len .. ^1]
    let star = rest.find('*')
    if star <= 0: continue
    let name = rest[0 ..< star]
    if name.len == 0 or not name.allCharsInSet(IdentChars): continue
    result.add name

proc gpuiSourceFiles(): seq[string] =
  ## Every `.nim` under `src/frontend/gpui` that is not a test. The binary's
  ## own sources, derived from the tree rather than listed.
  result = @[]
  for path in walkDirRec(GpuiSourceDir):
    if not path.endsWith(".nim"): continue
    if "/tests/" in path.replace('\\', '/'): continue
    result.add path
  result.sort()

proc splitCode(source: string): tuple[code: string, blockComment: bool] =
  ## The file with its line comments removed, and whether it contains a Nim
  ## BLOCK comment.
  ##
  ## **THE SCAN WOULD BE RED FOR THE WRONG REASON WITHOUT THE STRIPPING**, and
  ## saying so is the point: `main.nim` names `createWindow`, `show`, `destroy`
  ## and `requestRepaint` a dozen times in the very comment that explains why
  ## it no longer calls them. A scan that could not tell a mention from a call
  ## would have had to be weakened until it could not fail — which is how a
  ## scan becomes a decoration.
  ##
  ## **AND THE BLOCK-COMMENT FLAG IS COMPUTED BY THE SAME SCAN RATHER THAN BY
  ## A SECOND ONE**, which is the third spelling this check has had and the
  ## only correct one. The stripper handles LINE comments, so a `#[ … ]#`
  ## block must fail loudly instead of being handled silently — but:
  ##
  ##   * `"#[" notin code` could never fire, because `#[` begins with `#` and
  ##     the stripper had already removed it;
  ##   * `"#[" notin raw` fires on `main.nim`, whose doc comment quotes Rust's
  ##     `#[cfg(test)]` — a mention inside a comment, which is exactly the
  ##     thing the stripper exists to tolerate.
  ##
  ## A block comment is `#[` AT THE POSITION WHERE A COMMENT BEGINS, so it is
  ## recognised where the stripper already stands: at the first unquoted `#`
  ## of a line. Both of the above are then correct — the block comment fails,
  ## and `#[cfg(test)]` inside a `##` doc comment does not.
  var code = newStringOfCap(source.len)
  var hasBlock = false
  for raw in source.splitLines():
    var inString = false
    var i = 0
    var keep = ""
    while i < raw.len:
      let c = raw[i]
      if c == '"' and (i == 0 or raw[i - 1] != '\\'):
        inString = not inString
      if c == '#' and not inString:
        if i + 1 < raw.len and raw[i + 1] == '[':
          hasBlock = true
        break
      keep.add c
      inc i
    code.add keep
    code.add '\n'
  (code, hasBlock)

proc codeOnly(source: string): string =
  splitCode(source).code

proc nimIdentKey(s: string): string =
  ## An identifier reduced to the key Nim's OWN equality uses.
  ##
  ## **THIS EXISTS BECAUSE A SUBSTRING SCAN IS NOT A SCAN FOR NIM NAMES, AND
  ## THAT WAS DEFEATED RATHER THAN IMAGINED — SEE ROUTE 4 IN THE HEADER
  ## ABOVE.** Nim compares identifiers with the first character significant
  ## and the rest case-insensitive and underscore-insensitive, so
  ## `create_window`, `createwindow` and `createWindow` are ONE name to the
  ## compiler and three different strings to `in`. A scan written as
  ## `name in code` therefore stays green against a real, compiling call to
  ## the very procedure it is looking for, made from the very file it is
  ## reading. Measured 2026-09-22: `nim c -r` on a two-file program in which
  ## the caller writes `create_window("hi")` runs and returns the callee's
  ## value, while `"createWindow" in code` is `false`.
  ##
  ## See https://nim-lang.org/docs/manual.html#lexical-analysis-identifiers-amp-keywords
  if s.len == 0: return ""
  result = newStringOfCap(s.len)
  result.add s[0]
  for i in 1 ..< s.len:
    if s[i] == '_': continue
    result.add toLowerAscii(s[i])

proc identifierKeys(code: string): HashSet[string] =
  ## Every identifier-shaped token in `code`, reduced by `nimIdentKey`.
  ##
  ## **TOKENS AND NOT SUBSTRINGS, WHICH FIXES A SECOND FAULT IN THE SAME
  ## LINE.** `name in code` is true for `destroy` inside `destroyTree` and
  ## inside `gpui_destroy_element`, so the old spelling could also go red for
  ## a name nothing called — a scan that can be wrong in BOTH directions is
  ## one nobody can act on. Splitting on `IdentChars` and comparing whole
  ## tokens is exact in both.
  ##
  ## String LITERALS are deliberately still scanned: the stripper removes
  ## comments, not strings, and `M10` — the arm that certifies the file set —
  ## plants its registry name in one. A tokeniser that skipped strings would
  ## silently retire that arm.
  result = initHashSet[string]()
  var i = 0
  while i < code.len:
    if code[i] in IdentStartChars:
      var j = i
      while j < code.len and code[j] in IdentChars: inc j
      result.incl nimIdentKey(code[i ..< j])
      i = j
    else:
      inc i

suite "PLAT-37: the front-end reaches the window through gpui_launch":

  let exported = exportedWindowProcs()
  let sources = gpuiSourceFiles()

  test "the scan's two subject sets are derived and non-empty":
    echo "  window.nim exports ", exported.len, " procs: ",
         exported.sorted.join(" ")
    echo "  scanned ", sources.len, " source files under ", GpuiSourceDir
    ck exported.len >= 10
    ck sources.len >= 5
    ck "src/frontend/gpui/main.nim" in sources
    # The two modules this milestone added are in the set, which is the check
    # that would have caught the one-file version of this scan.
    ck "src/frontend/gpui/chrome.nim" in sources
    ck "src/frontend/gpui/replay_ops.nim" in sources
    # Every declared exclusion is still a real export upstream.
    for name in AmbiguousWindowNames:
      ck name in exported

  test "no source file CALLS the window registry, comments excluded":
    # **TWO SWITCHES ARE OFF, NOT ONE, AND THIS IS THE SECOND.**
    # `window.rs` carries no `cfg` outside `#[cfg(test)]`: `create_window` is
    # a `Vec` push and `show_window` a state transition, identical in both
    # builds. The only function that branches on `gpui-backend` is
    # `gpui_launch`. So a front-end on the registry path would have measured
    # NO difference between the two shims, whatever the Cargo feature said —
    # which is what every milestone from PLAT-20 to PLAT-23 was doing.
    var subjects: seq[string] = @[]
    for name in exported:
      if name in AmbiguousWindowNames: continue
      subjects.add name
    ck subjects.len == exported.len - AmbiguousWindowNames.len
    ck subjects.len > 0
    for path in sources:
      let (code, hasBlockComment) = splitCode(readFile(path))
      # **ASSERTED OVER THE RAW FILE AND NOT OVER THE STRIPPED CODE, AND THAT
      # DISTINCTION IS A DEFECT THIS SUITE HAD.** The stripper handles LINE
      # comments only, so a Nim block comment must fail loudly rather than be
      # handled silently. The first spelling read `"#[" notin code` — over the
      # STRIPPED text — and it could never fire: `#[` begins with `#`, so the
      # stripper had already removed it. Found by appending
      # `#[ destroy requestRepaint ]#` to a scanned file and watching the
      # scan stay green; over `raw` the same edit fails by name.
      ck not hasBlockComment
      # **COMPARED AS NIM IDENTIFIERS, NOT AS SUBSTRINGS.** See `nimIdentKey`:
      # `name in code` is green against `create_window(...)`, which is a real
      # call to `createWindow` — route 4, defeated on the real tree and closed
      # here rather than described.
      let idents = identifierKeys(code)
      for name in subjects:
        let key = nimIdentKey(name)
        if key in idents:
          checkpoint(path & " still calls the window registry: " & name)
        ck key notin idents

  test "and it DOES reach gpui_launch — the positive twin":
    # §4a. Without this, a scan over a set of names nothing uses would be
    # green against a front-end that opened no window at all, which is the
    # state it is supposed to detect the end of.
    var launchers = 0
    var quitters = 0
    for path in sources:
      let code = codeOnly(readFile(path))
      if "gpui_launch" in code: inc launchers
      if "gpui_quit_after_ms" in code: inc quitters
    echo "  files calling gpui_launch: ", launchers,
         ", gpui_quit_after_ms: ", quitters
    ck launchers >= 1
    ck quitters >= 1
    # The comment stripper is itself armed: it must not be so aggressive
    # that it removes code, and not so lax that it keeps comments.
    ck codeOnly("let a = 1 # createWindow").contains("let a = 1")
    ck not codeOnly("let a = 1 # createWindow").contains("createWindow")
    ck codeOnly("""let s = "# not a comment"""").contains("not a comment")
    # And so is the IDENTIFIER KEY, for the same reason: a normaliser nothing
    # arms is a decoration, and this one is the whole of route 4's repair.
    # The three spellings Nim calls ONE name must collapse together...
    ck nimIdentKey("create_window") == nimIdentKey("createWindow")
    ck nimIdentKey("createwindow") == nimIdentKey("createWindow")
    ck nimIdentKey("re_quest_Repaint") == nimIdentKey("requestRepaint")
    # ...and the one Nim calls a DIFFERENT name must not. The first character
    # is significant, so an over-eager `toLowerAscii` over the whole string
    # would merge `CreateWindow` with `createWindow` and make this scan red
    # for a name that is not the registry's.
    ck nimIdentKey("CreateWindow") != nimIdentKey("createWindow")
    # The tokeniser is two-sided: it must FIND a whole identifier...
    ck nimIdentKey("createWindow") in identifierKeys("  let w = create_Window(t)")
    # ...and must NOT find one that is only a substring of another.
    ck nimIdentKey("destroy") notin identifierKeys("  gpui_destroy_element(n)")
    ck nimIdentKey("destroy") in identifierKeys("  win.destroy()")

suite "PLAT-37: the assertion count":
  test "every case ran":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
