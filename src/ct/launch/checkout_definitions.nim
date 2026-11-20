## ct/launch/checkout_definitions.nim — what a session reads from the checkout
## it opens.
##
## Project-Definitions.md is "how a repository teaches CodeTracer about
## itself", and for five campaigns the teaching stopped at the classroom door:
## `loadCheckoutDefinitions`, `presentersFor`, `applyCollections`,
## `loadCheckoutExecutableTier` and `trustDisclosure` were each built, each
## tested over real directories, and each called by no shipped binary. This
## module is the one call a front-end makes when a session opens, and it hands
## back everything the session needs as a value:
##
##   * the declarative tier, loaded (PLAT-11) — collections, visualiser rules,
##     scratchpad diff selections, and every problem a file had;
##   * each collection re-resolved, point by point, against the checkout's own
##     files through `readSourceFile` (§4: reported, never dropped);
##   * the visualisers those rules become (`value_visualisers.visualisersFor`,
##     PLAT-12), ready for `presentersFor`'s caller;
##   * the executable tier as the user's trust ledger admits it (PLAT-13): the
##     definitions that may run, and — for each one that may not — what the
##     user would be deciding about, so the disclosure can be shown to them;
##   * a stamp of the definition files' sizes and times, so a session can tell
##     an edit (§10 decision 4's authoring loop) from no change with a `stat`
##     rather than a read.
##
## ## WHICH CHECKOUT
##
## The caller's `root`: the directory a front-end already treats as the
## project (the terminal's working directory, the desktop's recorded
## `workdir`). NOTHING IS SEARCHED FOR ABOVE IT. A definition directory an
## ancestor holds belongs to some other project, and reading it because it
## happened to be higher up the tree is the kind of implicit reach §2 exists
## to rule out.
##
## The PACKAGE SCOPES — §6's per-package definitions in a monorepo — are
## derived from the recorded program's own source files: every directory
## between `root` and a recorded file that holds a `.codetracer/` of its own is
## a scope. That is the "package-scope list a monorepo would pass" PLAT-11's
## bound 1 said nothing computed. It is bounded by the files handed in and by
## `MaxDefinitionScopes`, and every scope still goes through the loaders' own
## `pathProblem` check.
##
## ## WHAT THIS DOES NOT DO
##
## It runs nothing. The executable definitions it returns are admitted
## handles; running one is `visualiseWith` / `diffWith`, which re-ask the
## ledger every time. And it reads no executable file the user has not granted
## — `loadCheckoutExecutableTier` asks the ledger before the open, which is the
## property PLAT-13's gate suites assert on the syscall.

import std/[os, strutils, times]

import ../../common/project_definitions
import ../../common/project_executables
import ../../common/value_presentation
import ../../common/value_visualisers

import ./grant_store
import ./project_definitions_dir
import ./project_executable_tier
import ./project_trust_store

export project_definitions, project_executables, value_presentation,
       value_visualisers
export project_executable_tier.ExecutableTierScan,
       project_executable_tier.ExecutableReview

type
  PendingDecision* = object
    ## An executable definition this checkout ships that the ledger does not
    ## admit: the decision the user has not taken (or took back).
    kind*: DefinitionFileKind
    scope*: string
    file*: string
      ## Repository-relative, as the user would read it.
    reason*: string
      ## The scan's own sentence for why it did not run.

  CheckoutDefinitions* = object
    root*: string
      ## The checkout, as the caller named it. "" when there was none.
    present*: bool
      ## A `.codetracer/` exists at the root or at one of `scopes`. False is
      ## the ordinary case — almost every repository ships none — and every
      ## other field is then empty.
    scopes*: seq[string]
    loaded*: LoadedProjectDefinitions
    resolutions*: seq[CollectionResolution]
    visualisers*: seq[Visualiser]
      ## The declarative rules as the presenter sees them. The executable
      ## visualiser is NOT here: its answers depend on the values on screen,
      ## so the session adds it per refresh (`computedVisualiser`).
    executable*: ExecutableTierScan
    pending*: seq[PendingDecision]
    identity*: RepositoryIdentity
    stamp*: string
      ## Sizes and modification times of every definition file, in a fixed
      ## order. Equal stamps mean nothing changed on disk.

const
  UserDefinitionsSubdir* = "definitions"
    ## The user's own definitions live in `<user root>/definitions/` — the
    ## launcher's user root (`$CODETRACER_USER_ROOT`, else
    ## `$HOME/.codetracer`), outside every checkout, never merged into a
    ## project's (§6).

proc userDefinitionsRoot*(): string =
  ## Where the user's own definitions are read from, or "" when there is no
  ## user root.
  let r = launcherUserRoot()
  if r.len == 0: "" else: r / UserDefinitionsSubdir

proc packageScopesFor*(root: string; sourcePaths: openArray[string]):
    seq[string] =
  ## Every directory strictly between `root` and a recorded source file that
  ## holds a `.codetracer/` of its own, as a repository-relative scope, in the
  ## order first met. See the module header.
  if root.len == 0: return
  let base = root.normalizedPath
  var checked = 0
  for p in sourcePaths:
    if checked >= 256 or result.len >= MaxDefinitionScopes: break
    inc checked
    let file = p.normalizedPath
    if not file.startsWith(base & "/"): continue
    var rel = file[base.len + 1 .. ^1].parentDir
    while rel.len > 0 and rel != "." and rel != "/":
      if rel notin result and dirExists(base / rel / ProjectDefinitionDir):
        result.add rel
      let up = rel.parentDir
      if up == rel: break
      rel = up

proc definitionsStamp*(root: string; scopes: openArray[string]): string =
  ## A `stat` of every file a load could read, as one string.
  ##
  ## WHAT AN AUTHOR CHANGES IS A FILE'S BYTES, and the two facts a `stat`
  ## answers about bytes without reading them are the size and the
  ## modification time — so a save that changes either changes the stamp. An
  ## absent file stamps as `-`, so creating or deleting one is a change too.
  var parts: seq[string] = @[]
  var dirs = @[root]
  for s in scopes: dirs.add root / s
  for d in dirs:
    for kind in DefinitionFileKind:
      let f = d / ProjectDefinitionDir / definitionFileName(kind)
      try:
        let info = getFileInfo(f, followSymlink = false)
        parts.add $info.size & "@" & $info.lastWriteTime.toUnixFloat
      except CatchableError, Defect:
        parts.add "-"
  let user = userDefinitionsRoot()
  if user.len > 0:
    for kind in DefinitionFileKind:
      let f = user / definitionFileName(kind)
      try:
        let info = getFileInfo(f, followSymlink = false)
        parts.add $info.size & "@" & $info.lastWriteTime.toUnixFloat
      except CatchableError, Defect:
        parts.add "-"
  parts.join(",")

proc readerFor(root: string): proc (path: string): SourceFile {.
    noSideEffect, gcsafe, raises: [].} =
  ## `readSourceFile` over `root`, in the shape `resolveCollection` takes.
  ##
  ## READING A FILE IS A SIDE EFFECT, and the cast that says so is HERE, in the
  ## caller, as `resolve.resolveCollection`'s own contract asks: "the I/O
  ## happens in the caller". The reader is the product's own — realpath on both
  ## sides, PLAT-8's `pathIsUnder`, `O_NOFOLLOW` — so a point cannot read
  ## outside the checkout by being resolved here rather than in a suite.
  result = proc (path: string): SourceFile {.noSideEffect, gcsafe,
                                             raises: [].} =
    {.cast(noSideEffect).}:
      {.cast(gcsafe).}:
        try:
          readSourceFile(root, path)
        except CatchableError:
          SourceFile(present: false)

proc readCheckoutDefinitions*(root: string;
                              sourcePaths: openArray[string] = [];
                              userRoot = "";
                              trustRoot = ""): CheckoutDefinitions =
  ## EVERYTHING A SESSION READS FROM THE CHECKOUT IT OPENS. See the header.
  ##
  ## `userRoot` is the user's own definitions directory (default
  ## `userDefinitionsRoot()`), `trustRoot` the launcher user root the trust
  ## ledger lives under (default: the launcher's). Both are parameters so a
  ## suite can point them at scratch directories; the product passes neither.
  result.root = root
  if root.len == 0 or not dirExists(root):
    return
  result.scopes = packageScopesFor(root, sourcePaths)
  result.present = dirExists(root / ProjectDefinitionDir) or
                   result.scopes.len > 0
  let users = if userRoot.len > 0: userRoot else: userDefinitionsRoot()
  result.stamp = definitionsStamp(root, result.scopes)
  if not result.present:
    return
  result.loaded = loadCheckoutDefinitions(root, result.scopes,
    if users.len > 0 and dirExists(users): users else: "")
  let reader = readerFor(root)
  for c in allCollections(result.loaded):
    result.resolutions.add resolveCollection(c, reader)
  result.visualisers = visualisersFor(result.loaded)
  result.executable = loadCheckoutExecutableTier(root, trustRoot, result.scopes)
  result.identity = result.executable.identity
  for p in result.executable.problems:
    if p.code notin {etcNoGrant, etcRevoked, etcContentChanged}: continue
    for kind in executableKinds():
      for scope in @[""] & result.scopes:
        if definitionPath(scope, kind) == p.file:
          result.pending.add PendingDecision(kind: kind, scope: scope,
                                             file: p.file, reason: p.detail)

func admittedOf*(d: CheckoutDefinitions; kind: DefinitionFileKind;
                 found: var ExecutableDefinition): bool =
  ## The admitted executable definition of `kind` nearest the recorded program
  ## (the deepest scope), if the ledger admitted one.
  var best = -1
  var bestDepth = -1
  for i, def in d.executable.definitions:
    if def.kind != kind: continue
    let depth = def.file.count('/')
    if depth > bestDepth:
      best = i
      bestDepth = depth
  if best < 0: return false
  found = d.executable.definitions[best]
  true

proc computedVisualiser*(d: CheckoutDefinitions;
                         values: openArray[PValue];
                         trustRoot = ""): tuple[visualiser: Visualiser,
                                                ran: bool,
                                                problems: seq[string]] =
  ## RUN THE PROJECT'S EXECUTABLE VISUALISER over the values a surface is about
  ## to show, and hand back its answers as a `Visualiser` the pipeline can
  ## read without running anything (`presenter.computedAnswer`).
  ##
  ## Through `visualiseWithCurrentTrust`, so a revocation taken since the
  ## session opened stops the code here and now rather than at the next load.
  ## A value whose run trapped or ran out of work gets no answer and renders
  ## the way it would have without the definition; the first such problem is
  ## reported so the user is told rather than left to wonder.
  var def: ExecutableDefinition
  if not d.admittedOf(dfkVisualiserCode, def):
    return
  var computed: seq[ComputedSummary] = @[]
  var seenInputs: seq[string] = @[]
  for v in values:
    if v.isNil or computed.len >= MaxComputedSummaries: continue
    let input = executableInputOf(v)
    if input.len == 0 or input.len > MaxExecutableInputBytes or
       input in seenInputs:
      continue
    seenInputs.add input
    let answer = def.visualiseWithCurrentTrust(input, trustRoot)
    result.ran = true
    if answer.fromDefinition:
      computed.add ComputedSummary(input: input, text: answer.text)
    elif result.problems.len < 4:
      for p in answer.problems: result.problems.add render(p)
  result.visualiser = executableVisualiser(def.file, computed)

proc reviewPending*(d: CheckoutDefinitions; p: PendingDecision):
    tuple[review: ExecutableReview, disclosure: string] =
  ## What the user reads before deciding about `p`: the file's digest, taken
  ## now because they asked, and `trustDisclosure`'s derived account of what a
  ## grant would permit.
  result.review = reviewExecutableDefinition(d.root, p.scope, p.kind)
  if result.review.digest.len == 0:
    return
  result.disclosure = trustDisclosure(d.identity, p.kind,
                                      result.review.digest, d.root)

proc describeCheckout*(d: CheckoutDefinitions): string =
  ## The whole state of this checkout's definitions, as a reader is shown it:
  ## what loaded, what is in force, what each collection resolved to, and what
  ## the executable tier did.
  if d.root.len == 0:
    return "no project is open, so no project definitions were read"
  if not d.present:
    return "'" & d.root & "' has no " & ProjectDefinitionDir &
      "/ directory, so it declares no project definitions"
  var lines: seq[string] = @[]
  lines.add "checkout: " & d.root
  if d.scopes.len > 0:
    lines.add "package scopes: " & d.scopes.join(", ")
  lines.add describeLoad(d.loaded)
  for r in d.resolutions:
    lines.add "collection '" & r.collection.name & "': " & summarise(r)
  lines.add describeVisualisers(withVisualisers(d.visualisers))
  lines.add describeScan(d.executable)
  for p in d.pending:
    lines.add "not run: " & p.file & " — " & p.reason
  lines.join("\n")
