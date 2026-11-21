## host/project_definitions_host.nim — the terminal session's project
## definitions: read when the session opens, applied to its panes, re-read
## when the author edits them, and the trust decision put in front of the
## user.
##
## `ct/launch/checkout_definitions` reads a checkout into a value. This module
## is what a SESSION does with that value, and nothing in it is specific to a
## terminal: it writes the shared `PointListVM` (so the Points pane, the
## gutter, and a collaborator all see a checkout's collections), it builds the
## visualiser tier every value surface renders with, and it answers the
## scratchpad's comparison. The terminal's runtime reaches it through
## `ProjectDefinitionsService`'s closures, which `tui_session.wireDefinitions`
## installs.
##
## ## THE AUTHORING LOOP
##
## Project-Definitions §10 decision 4: "How does a user preview a visualiser
## while writing one? … a live preview in the scratchpad against a real
## recorded value." `pollChanged` is a `stat` of the definition files
## (`definitionsStamp`), taken at most every `DefinitionsPollMs` from the
## host loop's idle tick; when the stamp moves the definitions are re-read,
## and every surface that renders values — the scratchpad's pinned values
## first among them — re-renders through the new rules on the next frame.
## Pin a value, save `.codetracer/visualisers.toml`, watch it change.
##
## ## THE TRUST DECISION REACHES A HUMAN
##
## PLAT-13's residue 6: `trustDisclosure` was derived, named the checkout, the
## file and the bytes, and was read by a test and never by a person. Here:
##
##   * opening a checkout that ships code the user has not granted puts one
##     line on the status line saying so, and naming `:project review`;
##   * `:project review` reads the file to DIGEST it (never to decode or run
##     it) and shows `trustDisclosure` in full;
##   * `:project grant` grants exactly what was shown — the same file, the
##     same digest — and refuses when nothing was reviewed, or when the file
##     changed since it was;
##   * `:project revoke` withdraws it, and the session's held handle stops at
##     its next run, because every run re-reads the ledger.

import std/[os, sets, strutils, times]

import ../../../ct/launch/checkout_definitions
import ../../../ct/launch/project_executable_tier
import ../../../ct/launch/project_trust_store
import ../../../common/value_comparison
import ../../viewmodel/viewmodels/point_list_vm
import ../../viewmodel/viewmodels/point_collection_source
import ../../viewmodel/store/types as store_types

export checkout_definitions.CheckoutDefinitions

proc describeComparison*(c: Comparison): string =
  ## The scratchpad's one line for a comparison (`value_comparison.describe`).
  value_comparison.describe(c)

const
  DefinitionsPollMs* = 250
    ## How often the idle tick may `stat` the definition files. A save is
    ## seen within a quarter of a second; a session with no `.codetracer/`
    ## pays one failed `stat` per file per tick.

type
  Reviewed = object
    kind: DefinitionFileKind
    scope: string
    digest: string

  SessionDefinitions* = ref object
    root*: string
    sources*: seq[string]
    defs*: CheckoutDefinitions
    computed*: Visualiser
    computedProblems*: seq[string]
    reviewed: seq[Reviewed]
    upkeep*: TrustUpkeep
    loads*: int
      ## How many times the definitions were read: 1 after the open, +1 per
      ## re-read. A suite waits on this rather than on a clock.
    lastPollMs: int64
    trustRoot*: string
      ## The launcher user root the ledger is under; "" for the launcher's own.
    inProgram*: Visualiser
      ## §5.1 mechanism 1: what the RECORDED PROGRAM's own visualiser function
      ## answered, read out of the recording by the session
      ## (`HeadlessDebugSession.loadInProgramVisualiser`). Not a definition
      ## file, so not re-read when one is saved; the top tier when it has
      ## answers.

proc load(sd: SessionDefinitions) =
  sd.defs = readCheckoutDefinitions(sd.root, sd.sources,
                                    trustRoot = sd.trustRoot)
  inc sd.loads
  sd.computed = Visualiser()
  sd.computedProblems = @[]

proc openSessionDefinitions*(root: string; sources: openArray[string];
                             trustRoot = ""): SessionDefinitions =
  ## Read `root`'s definitions for a session that just opened, and keep the
  ## trust ledger tidy while we are here (`keepProjectTrust`: what can never
  ## be admitted again is forgotten, a moved checkout's path note is brought
  ## up to date). Upkeep writes the ledger only when something changed.
  result = SessionDefinitions(root: root, sources: @sources,
                              trustRoot: trustRoot)
  result.load()
  if result.defs.identity.len > 0 and result.defs.present:
    result.upkeep = keepProjectTrust(trustRoot,
                                     [(result.defs.identity, root)])

proc reload*(sd: SessionDefinitions): bool =
  ## Read the definitions again. True when anything on disk had changed.
  if sd.isNil: return false
  let before = sd.defs.stamp
  sd.load()
  sd.defs.stamp != before

proc pollChanged*(sd: SessionDefinitions; nowMs: int64): bool =
  ## The idle tick's question: did the author save a definition file? A `stat`
  ## per file, at most every `DefinitionsPollMs`; a re-read only when the
  ## stamp moved.
  if sd.isNil or sd.root.len == 0: return false
  if nowMs - sd.lastPollMs < DefinitionsPollMs: return false
  sd.lastPollMs = nowMs
  let scopes = packageScopesFor(sd.root, sd.sources)
  if definitionsStamp(sd.root, scopes) == sd.defs.stamp:
    return false
  sd.load()
  true

proc applyPoints*(sd: SessionDefinitions; vm: PointListVM) =
  ## Write the checkout's collections into the session's point list — beside,
  ## never over, the points the user and the engine put there.
  if sd.isNil or vm.isNil: return
  var cols: seq[PointCollection] = @[]
  for r in sd.defs.resolutions: cols.add r.collection
  vm.mergeCollections(sd.defs.resolutions, defaultEnabled(cols), sd.root)

proc visualisersFor*(sd: SessionDefinitions;
                     values: openArray[PValue]): seq[Visualiser] =
  ## The tier every value surface renders with: the declared rules, and — when
  ## the user granted the project's code — the executable visualiser's answers
  ## for `values`, the ones about to be shown.
  if sd.isNil: return
  if sd.inProgram.computed.len > 0:
    result.add sd.inProgram
  result.add sd.defs.visualisers
  var def: ExecutableDefinition
  if sd.defs.admittedOf(dfkVisualiserCode, def) and values.len > 0:
    let (vis, _, problems) = computedVisualiser(sd.defs, values, sd.trustRoot)
    sd.computed = vis
    sd.computedProblems = problems
    if vis.computed.len > 0:
      result.add vis

proc valuesOnScreen*(variables: openArray[store_types.Variable]): seq[PValue] =
  ## The values a Variables pane is about to show — each variable and its
  ## first level of members — which is what a project's executable visualiser
  ## is run over. One answer for every front-end that draws the pane.
  for v in variables:
    if v.presented.isNil: continue
    result.add v.presented
    for m in v.presented.members:
      if not m.value.isNil: result.add m.value

proc compare*(sd: SessionDefinitions; a, b: PValue): Comparison =
  ## The scratchpad's "is this the same value?": the project's own comparison
  ## when the user granted one, the comparison the project SELECTED for this
  ## type when it selected one, and the structural comparison otherwise.
  if not sd.isNil:
    var def: ExecutableDefinition
    if sd.defs.admittedOf(dfkDiffCode, def):
      return compareWithDefinition(def,
        loadProjectTrust(sd.trustRoot).ledger, a, b)
    var sel: DiffSelection
    if selectDiff(sd.defs.loaded, a, sel):
      return compareValues(a, b, sel, true)
  compareValues(a, b, DiffSelection(), false)

proc openingNotice*(sd: SessionDefinitions): string =
  ## The one line a user sees when the session opens, or "" when the checkout
  ## declares nothing worth interrupting them about.
  if sd.isNil or not sd.defs.present: return ""
  var parts: seq[string] = @[]
  var points = 0
  for r in sd.defs.resolutions: points += r.points.len
  if sd.defs.resolutions.len > 0:
    parts.add $sd.defs.resolutions.len & " point collection(s), " & $points &
      " point(s)"
  if sd.defs.visualisers.len > 0:
    parts.add $sd.defs.visualisers.len & " visualiser(s)"
  let refused = refusals(sd.defs.loaded.problems).len
  if refused > 0:
    parts.add $refused & " definition problem(s)"
  result = "project definitions: " &
    (if parts.len > 0: parts.join(", ") else: "none in force")
  if sd.defs.pending.len > 0:
    result.add " — this project ships code (" & sd.defs.pending[0].file &
      ") that was NOT run; :project review to decide"
  elif sd.defs.executable.definitions.len > 0:
    result.add " — running the project's trusted code (" &
      sd.defs.executable.definitions[0].file & ")"
  result.add " — :project for details"

proc report*(sd: SessionDefinitions): string =
  ## `:project`: everything about this checkout's definitions.
  if sd.isNil:
    return "no recording is open, so no project definitions were read"
  result = describeCheckout(sd.defs)
  if sd.inProgram.computed.len > 0:
    result.add "\nthe recorded program's own visualiser (" &
      sd.inProgram.id & ") answered for " & $sd.inProgram.computed.len &
      " recorded value(s); it outranks every definition"
  if sd.computedProblems.len > 0:
    result.add "\nthe project's visualiser did not answer for some values:"
    for p in sd.computedProblems: result.add "\n  " & p
  if sd.defs.identity.len > 0:
    result.add "\n\ntrust decisions about this checkout:\n" &
      describe(loadProjectTrust(sd.trustRoot).ledger, sd.defs.identity)
  let u = describeUpkeep(sd.upkeep)
  if u.len > 0: result.add "\n" & u
  result.add "\n\n:project review — read what trusting this project's code " &
    "would permit\n:project grant — grant what you reviewed\n" &
    ":project revoke — withdraw a grant\n:project reload — read the " &
    "definitions again (saving a file does this by itself)"

proc review*(sd: SessionDefinitions): tuple[ok: bool, text: string] =
  ## `:project review`: the disclosure, for every executable definition this
  ## checkout ships that the ledger does not admit. Reading the bytes to
  ## digest them happens here, because the user asked.
  if sd.isNil or sd.defs.pending.len == 0:
    return (false, "this project ships no code awaiting a decision")
  var parts: seq[string] = @[]
  sd.reviewed = @[]
  for p in sd.defs.pending:
    let (r, disclosure) = sd.defs.reviewPending(p)
    if disclosure.len == 0:
      parts.add "'" & p.file & "' could not be reviewed: " & r.failure
      continue
    sd.reviewed.add Reviewed(kind: p.kind, scope: p.scope, digest: r.digest)
    parts.add disclosure & "\n  (" & $r.bytes & " bytes; currently not run: " &
      p.reason & ")"
  if sd.reviewed.len > 0:
    parts.add "Type :project grant to grant exactly what is shown above, or " &
      "close this to decide nothing."
  (sd.reviewed.len > 0, parts.join("\n\n"))

proc grant*(sd: SessionDefinitions): string =
  ## `:project grant`: record a grant for what `review` showed, by the digest
  ## the user saw. A file that changed since is refused — the user would be
  ## granting bytes they did not review.
  if sd.isNil or sd.reviewed.len == 0:
    return "nothing was reviewed: :project review first, so you see what " &
      "you are granting"
  let at = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var said: seq[string] = @[]
  for r in sd.reviewed:
    let current = reviewExecutableDefinition(sd.root, r.scope, r.kind)
    let file = definitionPath(r.scope, r.kind)
    if current.digest != r.digest:
      said.add file & " changed since you reviewed it; review it again"
      continue
    let failure = grantExecutableTier(sd.trustRoot, sd.root, r.kind,
                                      r.digest, at)
    said.add (if failure.len == 0: "granted " & file else: failure)
  sd.reviewed = @[]
  discard sd.reload()
  said.join("; ")

proc revoke*(sd: SessionDefinitions): string =
  ## `:project revoke`: withdraw every grant this checkout holds. The handle
  ## the session holds stops at its next run (`stillAdmitted`).
  if sd.isNil or sd.defs.identity.len == 0:
    return "no checkout is open to withdraw a grant from"
  let ledger = loadProjectTrust(sd.trustRoot).ledger
  let at = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var said: seq[string] = @[]
  for kind in executableKinds():
    if ledger.stateOf(sd.defs.identity, kind) != tsGranted: continue
    let failure = revokeExecutableTier(sd.trustRoot, sd.root, kind, at)
    said.add (if failure.len == 0: "withdrew the grant for " &
                definitionFileName(kind)
              else: failure)
  discard sd.reload()
  if said.len == 0: "this checkout holds no grant to withdraw"
  else: said.join("; ")

proc renderedWith*(v: PValue; budget: Budget;
                   visualisers: seq[Visualiser]): string =
  ## One value as one line at `budget`, through `visualisers` — the
  ## scratchpad's rendering of a pinned value.
  if v.isNil: return ""
  present(v, budget, presenters = withVisualisers(visualisers)).root.text

proc scratchpadBudget*(): Budget = ScratchpadBudget
