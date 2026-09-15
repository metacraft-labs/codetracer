## plugin_surfaces_test.nim — PLAT-9's PURE half: the contributed pane
## identity, the per-surface view decision (§6.2), the required/optional rule
## (§6.3), and the manifest validation behind both.
##
## ## WHAT THIS SUITE IS FOR, AND WHAT IT DELIBERATELY IS NOT
##
## `contributed_pane_id.nim`, `plugin_model/surfaces.nim` and the PLAT-9 half
## of `plugin_model/manifest.nim` are pure: no renderer, no process, no clock.
## So every decision in them is assertable in a lane that links nothing, and
## that is why the decisions live there.
##
## It is NOT the evidence that any of it is WIRED. A `chooseView` that returns
## `vcNone` and a host that activates the plugin anyway are indistinguishable
## from here, so `test_plugin_surfaces.nim` (vm-unit) drives the same manifests
## through the real host, the real reactive graph and the real PATH and
## measures the EFFECT: the plugin's own activation counter, the pane's
## rendered text, the exception that did not escape.
##
## ## NO MOCKS
##
## Every input is a value — a manifest string and a `FrontEnd` — and there is
## no collaborator here to stand in for. The mapping table `chooseView`
## consults is PLAT-3's own (`view_vocabulary/mappings.nim`), which
## `view_vocabulary_test.nim` verifies against isonim-gpui's source rather
## than against a copy written here.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper in this file is a `template`. There is exactly one
## (`ck`), and it wraps `unittest.check` — a `check` inside a plain `proc`
## sets a module-level global and the case reports `[OK]` with the failed
## comparison printed above it.
##
## Compile and run:
##   nim c -r src/common/plugin_surfaces_test.nim

import std/[options, strutils, unittest]

import ./plugin_model

const ExpectedAssertions = 207
  ## Written from a run, and asserted against the tally below.
  ## `ci/lib/run-nim-test-lane.sh` READS this name: a file that declares
  ## it AND fails when its own tally disagrees is a file whose assertion
  ## count the lane can report, which is what keeps `OK (n tests)` from
  ## being the only evidence a suite produces.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const SurfacesSource = staticRead("plugin_model/surfaces.nim")
  ## `plugin_model/surfaces.nim`, AS TEXT, so the sentence in its header can be
  ## compared with the table it describes. `staticRead` resolves relative to
  ## THIS file, and the module is in this repository and in this lane's compile
  ## closure already, so nothing here depends on a sibling checkout.

const AbsentAnchor = "ABSENT-ON-GPUI:"
  ## The marker the header line carries. ALL-CAPS AND FOLLOWED BY A COLON, so
  ## the scan below cannot be satisfied by prose about the subject
  ## (Verification-Harness-Traps §4d) — and that header now contains several
  ## sentences about the subject, including one that names `Image`.

func prosaicAbsentOnGpui(): seq[string] =
  ## The entries `surfaces.nim`'s header CLAIMS are absent on GPUI.
  for line in SurfacesSource.splitLines():
    let at = line.find(AbsentAnchor)
    if at < 0: continue
    for piece in line[at + AbsentAnchor.len .. ^1].split(','):
      let name = piece.strip()
      if name.len > 0: result.add name

proc parsed(text: string): ParsedManifest =
  parseManifest(text, "plugin_surfaces_test")

func codes(p: ParsedManifest): seq[PluginErrorCode] =
  for e in p.errors: result.add e.code

func detailFor(p: ParsedManifest; code: PluginErrorCode): string =
  for e in p.errors:
    if e.code == code: return e.detail
  ""

const
  Base = """
{
  "id": "acme.tool",
  "version": "1.0.0",
  "requires": { "core": "*" },
  "contributes": { "pane": [ $1 ] }
}
"""

proc withPane(entry: string): ParsedManifest =
  parsed(Base % [entry])

# ---------------------------------------------------------------------------
# The contributed pane identity (§6.1, §10.2)
# ---------------------------------------------------------------------------

suite "PLAT-9: a contributed pane id is namespaced, and the namespaces are disjoint":

  test "a bare name is not a contributed pane id — which is what makes a builtin one impossible":
    # THE COLLISION DEFENCE, as a total function rather than a reserved-word
    # list. Every built-in pane's spelling is a bare name, so every built-in
    # pane's spelling fails here, and no list has to be kept in step with
    # `PaneKind`.
    ck paneIdProblem("editor") == pipNoSeparator
    ck paneIdProblem("calltrace") == pipNoSeparator
    ck paneIdProblem("debugControls") == pipNoSeparator
    ck not isContributedPaneId("editor")
    # ... and the control: the same word, namespaced, IS one. The refusal is
    # about the missing namespace, not about the word.
    ck isContributedPaneId("acme.tool/editor")

  test "composition is injective, so one plugin cannot name into another's namespace":
    # Neither segment may contain the separator, so `(plugin, surface)` maps to
    # exactly one string. Two plugins can collide only by sharing a plugin id,
    # which `resolve` already refuses as `pecDuplicatePlugin`.
    ck qualifiedPaneId("acme.tool", "metrics") == "acme.tool/metrics"
    ck qualifiedPaneId("acme", "tool/metrics") == "acme/tool/metrics"
    ck paneIdProblem("acme/tool/metrics") == pipTooManySeparators
    ck pluginOf("acme.tool/metrics") == "acme.tool"
    ck surfaceOf("acme.tool/metrics") == "metrics"

  test "the charset is closed, so an id survives a layout document unchanged":
    ck paneIdProblem("acme.tool/me\"trics") == pipBadCharacter
    ck paneIdProblem("acme.tool/me\ntrics") == pipBadCharacter
    ck paneIdProblem("acme.tool/me trics") == pipBadCharacter
    ck paneIdProblem("acme.tool/métrics") == pipBadCharacter
    ck paneIdProblem("acme.tool/me\\trics") == pipBadCharacter
    ck paneIdProblem("../../etc/passwd") == pipTooManySeparators
    ck paneIdProblem("acme.tool/..") == pipEdgePunctuation
    # The control: everything the charset DOES admit.
    ck isContributedPaneId("acme.tool-2/metrics_v3.beta")

  test "the empty and edge cases each have their own answer":
    ck paneIdProblem("") == pipEmpty
    ck paneIdProblem("/") == pipEmptySegment
    ck paneIdProblem("/metrics") == pipEmptySegment
    ck paneIdProblem("acme.tool/") == pipEmptySegment
    ck paneIdProblem(".acme/metrics") == pipEdgePunctuation
    ck paneIdProblem("acme-/metrics") == pipEdgePunctuation
    # THE LENGTHS ARE LITERALS, NOT `MaxPaneIdSegment + 1`. Written against the
    # constant this case MOVES WITH IT: widening the bound to 4096 widens the
    # input too, and the case stays green having asserted nothing about the
    # bound. That is not hypothetical — arm M3 of
    # `run-plat9-surface-mutations.py` SURVIVED until this was written the
    # other way round. So the lengths are written out and the constant is
    # asserted to be the one they were chosen for.
    ck MaxPaneIdSegment == 64
    ck paneIdProblem("a".repeat(65) & "/m") == pipTooLong
    ck isContributedPaneId("a".repeat(64) & "/m")

  test "every problem has its own text, it names the subject, and none is empty":
    var n = 0
    for p in PaneIdProblem:
      let text = describe(p, "acme.tool/metrics")
      ck text.len > 0
      inc n
      if p != pipEmpty:
        # `pipEmpty`'s subject IS the empty string, so it is the one arm that
        # cannot quote it. Every other arm must.
        ck "acme.tool/metrics" in text
    ck n == 8

# ---------------------------------------------------------------------------
# §6.2 — which view runs here
# ---------------------------------------------------------------------------

suite "PLAT-9 §6.2: native where supplied, abstract as the baseline":

  test "a native view is PREFERRED over the abstract one on its own front-end":
    let m = withPane("""
      { "id": "graph", "views": ["Text"], "nativeViews": ["web"] }""")
    ck m.isOk
    let c = m.manifest.contributions[0]
    ck chooseView(c, feWeb).kind == vcNative
    # ... and the SAME surface falls back to the abstract baseline elsewhere.
    # That pair is §6.2's "honest arrangement" in one manifest.
    ck chooseView(c, feTerminal).kind == vcAbstract

  test "an abstract view alone runs on every front-end whose mapping has it":
    let m = withPane("""{ "id": "notes", "views": ["Text"] }""")
    ck m.isOk
    for fe in FrontEnd:
      ck chooseView(m.manifest.contributions[0], fe).kind == vcAbstract

  test "'abstract' is not automatically 'everywhere', and PLAT-3's table says so":
    # `Modal` maps to `msAbsent` on GPUI. **THIS CASE USED `Table` UNTIL
    # 2026-09-15**, on PLAT-3's reasoning that a tag outside isonim-gpui's
    # `tagMap` "reaches a Rust classifier with no case for it" — which PLAT-21
    # rendered through the real shim and found to be false: an unknown tag
    # keeps its spelling and classifies as `Div`, exactly as `button` does. So
    # `Table` and `ProgressIndicator` are `msPartial` now and a plugin surface
    # built on either is ADMITTED on GPUI. `Modal` is the entry that stayed
    # absent, and for the reason that was always the real one: there is no
    # ELEMENT focus in that renderer, so the exclusivity a Modal IS cannot be
    # built out of anything the medium offers. See `mappings.gpuiMapping`'s
    # three corrected rows and `gpui_gaps.PLAT21-VG3`.
    ck mappingFor(feGpui, pkModal).status == msAbsent
    # …and the two that MOVED, asserted here so this case fails if they move
    # back without the measurement moving with them.
    ck mappingFor(feGpui, pkTable).status == msPartial
    ck mappingFor(feGpui, pkProgressIndicator).status == msPartial
    let m = withPane("""{ "id": "rows", "views": ["Modal"] }""")
    ck m.isOk
    let c = m.manifest.contributions[0]
    let gpui = chooseView(c, feGpui)
    ck gpui.kind == vcNone
    ck gpui.absence == vaVocabularyAbsentHere
    ck gpui.absentViews == @[pkModal]
    # The control, on the same entry: the terminal renders a Modal completely
    # — the focus trap is isonim-tui's own — so the refusal is about the
    # FRONT-END and not about the entry.
    ck mappingFor(feTerminal, pkModal).status == msComplete
    ck chooseView(c, feTerminal).kind == vcAbstract
    # And the entry that used to stand here now PASSES on GPUI, which is the
    # behaviour change the correction carries.
    let tbl = withPane("""{ "id": "rows2", "views": ["Table"] }""")
    ck tbl.isOk
    ck chooseView(tbl.manifest.contributions[0], feGpui).kind == vcAbstract

  test "the GPUI absent set is read out of the table, and the prose is pinned to it":
    # THE SENTENCE THIS PINS WAS WRONG, IN TWO PLACES, FOR AS LONG AS IT HAD
    # EXISTED. `surfaces.nim`'s header and Extensibility-Model.md §6.4 both
    # said `Table`, `ProgressIndicator` and `Image`. `Image` is `msComplete` on
    # GPUI — `img` is one of two tags reaching a dedicated Rust element kind —
    # and `Modal`, which they omitted, is the third absent entry. The code was
    # right throughout (`chooseView` calls `mappingFor`), so nothing was red
    # and nothing could be: the case above exercises `Table` and nothing in the
    # tree read the prose. This case reads both.
    let derived = absentEntryNames(feGpui)
    # THE SIZE IS KNOWABLE, so the control is the COUNT rather than
    # non-emptiness (Verification-Harness-Traps §4b): "at least one" is
    # satisfied by one member of three, which is exactly the state the wrong
    # sentence was in.
    ck derived.len == 1
    # ... and the scan reaches exactly one line, so neither an empty read nor a
    # second marker can satisfy the comparison below (§4).
    ck SurfacesSource.count(AbsentAnchor) == 1
    ck prosaicAbsentOnGpui().len == 1
    ck prosaicAbsentOnGpui() == derived

    # Every member of the DERIVED set refuses, through the real `chooseView` —
    # over the set the table produces rather than over one entry written out
    # here, which is how two of the three could be wrong in a green tree.
    for name in derived:
      let m = withPane("{ \"id\": \"s\", \"views\": [\"" & name & "\"] }")
      ck m.isOk
      let choice = chooseView(m.manifest.contributions[0], feGpui)
      ck choice.kind == vcNone
      ck choice.absence == vaVocabularyAbsentHere

    # THE POSITIVE TWIN OVER THE SAME TABLE (§4a), and it is the half that
    # catches this particular defect: every entry NOT in the derived set HAS a
    # view on GPUI, so naming one of them absent reddens here rather than
    # nowhere.
    var present = 0
    var total = 0
    for k in ViewKind:
      inc total
      if vocabularyName(k) in derived: continue
      let m = withPane("{ \"id\": \"s\", \"views\": [\"" &
                       vocabularyName(k) & "\"] }")
      ck m.isOk
      ck chooseView(m.manifest.contributions[0], feGpui).kind == vcAbstract
      inc present
    ck total == 16
    ck present == total - derived.len

    # The correction itself, named on both sides, so the direction is legible.
    ck mappingFor(feGpui, pkImage).status == msComplete
    ck mappingFor(feGpui, pkModal).status == msAbsent
    ck "Image" notin derived
    ck "Modal" in derived

  test "a partial mapping is present, not absent":
    # `msPartial` means the front-end renders it and the binding supplies a
    # semantic. That is a cost to the binding author, not an absence to the
    # user, and collapsing the two would refuse surfaces that work.
    ck mappingFor(feGpui, pkButton).status == msPartial
    let m = withPane("""{ "id": "act", "views": ["Button"] }""")
    ck m.isOk
    ck chooseView(m.manifest.contributions[0], feGpui).kind == vcAbstract

  test "declaring nothing is its own absence, with its own remedy":
    let m = withPane("""{ "id": "mystery" }""")
    ck m.isOk
    let choice = chooseView(m.manifest.contributions[0], feTerminal)
    ck choice.kind == vcNone
    ck choice.absence == vaNothingDeclared
    ck choice.absentViews.len == 0

# ---------------------------------------------------------------------------
# §6.3 — required / optional
# ---------------------------------------------------------------------------

suite "PLAT-9 §6.3: a required surface with no view names the front-end AND the surface":

  test "the refusal names both, and says what to do about it":
    let m = withPane("""
      { "id": "flamegraph", "requirement": "required",
        "nativeViews": ["electron"] }""")
    ck m.isOk
    let refusals = surfaceRefusals(m.manifest, feTerminal)
    ck refusals.len == 1
    ck refusals[0].code == pecSurfaceUnavailableOnFrontEnd
    ck refusals[0].plugin == "acme.tool"
    # §6.3 asks for the front-end and the surface. Both, by name, and the
    # `--ui` value the user actually typed.
    ck "flamegraph" in refusals[0].detail
    ck "terminal" in refusals[0].detail
    ck "--ui=tui" in refusals[0].detail
    # And the remedies, because a refusal a user cannot act on is a blank tab
    # in a different costume.
    ck "nativeViews" in refusals[0].detail
    ck "optional" in refusals[0].detail

  test "the SAME surface on the front-end it was written for is not refused":
    let m = withPane("""
      { "id": "flamegraph", "requirement": "required",
        "nativeViews": ["electron"] }""")
    ck surfaceRefusals(m.manifest, feWeb).len == 0
    ck availableSurfaces(m.manifest, feWeb).len == 1
    ck availableSurfaces(m.manifest, feTerminal).len == 0

  test "an optional surface is simply not present, and is still NAMED":
    let m = withPane("""
      { "id": "flamegraph", "requirement": "optional",
        "nativeViews": ["electron"] }""")
    ck surfaceRefusals(m.manifest, feTerminal).len == 0
    ck availableSurfaces(m.manifest, feTerminal).len == 0
    let absent = absentOptionalSurfaces(m.manifest, feTerminal)
    ck absent.len == 1
    ck absent[0].id == "flamegraph"

  test "optional is the default, so omitting the field never refuses a plugin":
    let m = withPane("""{ "id": "flamegraph", "nativeViews": ["electron"] }""")
    ck m.isOk
    ck m.manifest.contributions[0].requirement == srOptional
    ck surfaceRefusals(m.manifest, feTerminal).len == 0

  test "the absent-vocabulary refusal names the ENTRIES, not just the surface":
    let m = withPane("""
      { "id": "rows", "requirement": "required", "views": ["Modal", "Text"] }""")
    let refusals = surfaceRefusals(m.manifest, feGpui)
    ck refusals.len == 1
    ck "Modal" in refusals[0].detail
    ck "rows" in refusals[0].detail
    ck "gpui" in refusals[0].detail
    # `Text` maps completely on GPUI, so it must NOT be blamed.
    ck mappingFor(feGpui, pkText).status != msAbsent
    ck not refusals[0].detail.contains("Modal, Text")

  test "a COMMAND is invoked, not drawn, so §6.3 never refuses one":
    # The partition is data (`RenderingContributionKinds`), and this is the
    # case that makes it a behaviour rather than a comment: a required command
    # with no views on any front-end is refused nowhere.
    ck ckCommand notin RenderingContributionKinds
    ck ckViewModel notin RenderingContributionKinds
    ck ckPane in RenderingContributionKinds
    ck ckMarker in RenderingContributionKinds
    ck ckStatusItem in RenderingContributionKinds
    let m = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "contributes": {
        "command": [ { "id": "acme.run", "requirement": "required" } ]
      }
    }
    """)
    ck m.isOk
    for fe in FrontEnd:
      ck surfaceRefusals(m.manifest, fe).len == 0

# ---------------------------------------------------------------------------
# Resolution phase 3b — the refusal FAILS the plugin
# ---------------------------------------------------------------------------

suite "PLAT-9: a surface refusal fails the plugin and blocks its dependents":

  const Desktop = """
  {
    "id": "acme.flame", "version": "1.0.0",
    "contributes": {
      "pane": [ { "id": "flamegraph", "requirement": "required",
                  "nativeViews": ["electron"] } ]
    }
  }
  """
  const Dependent = """
  {
    "id": "acme.extra", "version": "1.0.0",
    "requires": { "plugins": { "acme.flame": "^1.0.0" } }
  }
  """

  test "on the terminal the plugin is not loadable and is not in the order":
    let r = resolve(@[parsed(Desktop), parsed(Dependent)], semver(1, 0, 0),
                    some(feTerminal))
    ck not r.isLoadable("acme.flame")
    ck r.failureFor("acme.flame").code == pecSurfaceUnavailableOnFrontEnd
    ck "acme.flame" notin r.order
    # §4.2's "does not activate half-alive": the dependent is blocked too, and
    # the plan for the event it declared contains nothing.
    ck not r.isLoadable("acme.extra")
    ck r.failureFor("acme.extra").code == pecBlockedByDependency

  test "on the desktop the SAME two manifests both load":
    let r = resolve(@[parsed(Desktop), parsed(Dependent)], semver(1, 0, 0),
                    some(feWeb))
    ck r.isLoadable("acme.flame")
    ck r.isLoadable("acme.extra")
    ck r.order.len == 2
    ck r.errors.len == 0

  test "resolving with no front-end makes NO claim about surfaces":
    # `none` is the absence of a claim rather than a claim of availability.
    # A default value here would silently apply one front-end's answer to
    # every session.
    let r = resolve(@[parsed(Desktop)], semver(1, 0, 0))
    ck r.isLoadable("acme.flame")
    ck r.errors.len == 0

# ---------------------------------------------------------------------------
# Manifest validation of PLAT-9's declarations
# ---------------------------------------------------------------------------

suite "PLAT-9: the new declarations are validated where they enter":

  test "an unknown front-end is refused, naming the set":
    let m = withPane("""{ "id": "g", "nativeViews": ["kde"] }""")
    ck pecUnknownFrontEnd in m.codes()
    ck "kde" in m.detailFor(pecUnknownFrontEnd)
    ck "terminal" in m.detailFor(pecUnknownFrontEnd)
    # The control: every alias the table lists is accepted.
    for alias in knownFrontEndNames():
      ck withPane("""{ "id": "g", "nativeViews": ["""" & alias & """"] }""").isOk

  test "the --ui spellings are aliases of PLAT-3's three, and say so":
    let m = withPane("""
      { "id": "g", "nativeViews": ["electron", "webui", "tui"] }""")
    ck m.isOk
    ck m.manifest.contributions[0].nativeFrontEnds == {feWeb, feTerminal}

  test "a third requirement spelling is refused rather than rounded":
    let m = withPane("""{ "id": "g", "requirement": "preferred" }""")
    ck pecUnknownRequirement in m.codes()
    ck "preferred" in m.detailFor(pecUnknownRequirement)
    ck "required" in m.detailFor(pecUnknownRequirement)

  test "a malformed contributed pane id is refused at load time":
    # The id here is composed from the PLUGIN id and the surface id, so this
    # manifest's `acme.tool` + `met rics` is what fails.
    let m = withPane("""{ "id": "met rics" }""")
    ck pecBadContributedPaneId in m.codes()
    ck "acme.tool/met rics" in m.detailFor(pecBadContributedPaneId)
    ck m.manifest.contributions.len == 0
    # The control: the same manifest with a well-formed surface id.
    ck withPane("""{ "id": "metrics" }""").isOk

  test "a pane and a marker sharing one local id are refused, naming both":
    # MEASURED BEFORE THE RULE EXISTED: 0 parse errors, the manifest loaded,
    # ONE record survived in the surface registry with kind `pane`, and the
    # marker was dropped by a `hasKey` test with nothing anywhere saying so.
    # `qualifiedPaneId` carries no contribution kind, so both compose
    # `acme.tool/metrics` — one registry key, one `declaresSurface` answer,
    # one `contributeView` target. A silently dropped contribution is
    # `lpUnknownPane`'s failure in a different costume.
    let m = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "contributes": {
        "pane": [ { "id": "metrics", "views": ["Text"] } ],
        "marker": [ { "id": "metrics", "views": ["Text"] } ]
      }
    }
    """)
    ck pecDuplicateContribution in m.codes()
    let detail = m.detailFor(pecDuplicateContribution)
    # BOTH contributions are named, because either one may be the typo and an
    # author told only "duplicate id" has to go and find the other.
    ck "pane" in detail
    ck "marker" in detail
    ck "acme.tool/metrics" in detail

    # Two panes with one id are the same collision and are refused the same
    # way — the rule is about the composed key, not about kinds differing.
    let sameKind = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "contributes": {
        "pane": [ { "id": "metrics", "views": ["Text"] },
                  { "id": "metrics", "views": ["Text"] } ]
      }
    }
    """)
    ck pecDuplicateContribution in sameKind.codes()

    # THE CONTROL, and it is two controls in one: the same two surfaces with
    # distinct ids parse, AND a `command` sharing a local id with a pane is
    # NOT refused — commands are reached by `commandIds`, never by
    # `qualifiedPaneId` or `declaresSurface`, so they are not in this
    # namespace and a rule that refused them would be a rule with no failure
    # behind it.
    let distinct2 = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "contributes": {
        "pane": [ { "id": "metrics", "views": ["Text"] } ],
        "marker": [ { "id": "metrics-gutter", "views": ["Text"] } ]
      }
    }
    """)
    ck distinct2.isOk
    ck distinct2.manifest.contributions.len == 2
    let withCommand = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "contributes": {
        "pane": [ { "id": "metrics", "views": ["Text"] } ],
        "command": [ { "id": "metrics" } ]
      }
    }
    """)
    ck withCommand.isOk
    ck ckCommand notin RenderingContributionKinds

  test "a plugin id that cannot be half of a pane id is caught through the pane":
    let m = parsed("""
    {
      "id": "acme/tool", "version": "1.0.0",
      "contributes": { "pane": [ { "id": "metrics" } ] }
    }
    """)
    ck pecBadContributedPaneId in m.codes()
    ck "acme/tool/metrics" in m.detailFor(pecBadContributedPaneId)

  test "a dependency outside the declared executables can never be met":
    let m = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "contributes": {
        "pane": [ { "id": "d", "views": ["Text"], "needs": ["rg"],
                    "install": "ct install rg" } ]
      }
    }
    """)
    ck pecUndeclaredDependency in m.codes()
    ck "rg" in m.detailFor(pecUndeclaredDependency)

  test "a declared dependency without an install action is refused":
    # §8.2: "a name and an install action, not 'unavailable'". A surface that
    # declared the first and not the second could only ever render the third.
    let m = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "capabilities": ["process"],
      "executables": ["rg"],
      "traceEgress": { "acknowledged": true,
        "statement": "runs ripgrep over recorded source and keeps it local" },
      "contributes": {
        "pane": [ { "id": "d", "views": ["Text"], "needs": ["rg"] } ]
      }
    }
    """)
    ck pecMissingInstallHint in m.codes()
    ck "rg" in m.detailFor(pecMissingInstallHint)
    ck m.manifest.contributions.len == 0

  test "a dependency declared BOTH ways, with the remedy, parses":
    let m = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "capabilities": ["process"],
      "executables": ["rg"],
      "traceEgress": { "acknowledged": true,
        "statement": "runs ripgrep over recorded source and keeps it local" },
      "contributes": {
        "pane": [ { "id": "d", "views": ["Text"], "needs": ["rg"],
                    "install": "ct install rg",
                    "reprobe": [ { "event": "trace-opened" } ] } ]
      }
    }
    """)
    ck m.isOk
    let c = m.manifest.contributions[0]
    ck c.needs == @["rg"]
    ck c.install == "ct install rg"
    ck c.reprobe.len == 1
    ck c.reprobe[0].kind == aeTraceOpened

  test "a path is not a dependency name":
    let m = parsed("""
    {
      "id": "acme.tool", "version": "1.0.0",
      "capabilities": ["process"],
      "executables": ["rg"],
      "traceEgress": { "acknowledged": true,
        "statement": "runs ripgrep over recorded source and keeps it local" },
      "contributes": {
        "pane": [ { "id": "d", "views": ["Text"], "needs": ["/usr/bin/rg"],
                    "install": "ct install rg" } ]
      }
    }
    """)
    ck pecBadDeclaration in m.codes()
    ck "/usr/bin/rg" in m.detailFor(pecBadDeclaration)

  test "the re-probe vocabulary IS the activation vocabulary, and nothing else":
    let unknown = withPane("""
      { "id": "d", "views": ["Text"], "reprobe": [ { "event": "midnight" } ] }""")
    ck pecUnknownReprobeTrigger in unknown.codes()
    ck "midnight" in unknown.detailFor(pecUnknownReprobeTrigger)
    # A trigger whose meaning is entirely in its argument needs the argument,
    # for the same reason the activation event does.
    let noValue = withPane("""
      { "id": "d", "views": ["Text"], "reprobe": [ { "event": "language" } ] }""")
    ck pecUnknownReprobeTrigger in noValue.codes()
    # The control: with the value, the same trigger parses.
    let ok = withPane("""
      { "id": "d", "views": ["Text"],
        "reprobe": [ { "event": "language", "value": "rust" } ] }""")
    ck ok.isOk
    ck ok.manifest.contributions[0].reprobe[0].value == "rust"

  test "a contributed pane carries its qualified id, composed once":
    let m = withPane("""{ "id": "metrics", "views": ["Text"] }""")
    ck m.isOk
    let panes = contributedPanes(m.manifest)
    ck panes.len == 1
    ck panes[0].qualifiedId == "acme.tool/metrics"
    ck panes[0].plugin == "acme.tool"
    ck isContributedPaneId(panes[0].qualifiedId)

# ---------------------------------------------------------------------------
# The counted-assertion tally (Verification-Harness-Traps §4c)
# ---------------------------------------------------------------------------

suite "PLAT-9: the counted-assertion tally":

  test "the tally":
    # Written from a run. A suite whose cases silently stopped running would
    # still report green without this.
    check countedAssertions == ExpectedAssertions
