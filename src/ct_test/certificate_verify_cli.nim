## ``ct test verify`` — is this state covered by the certificates in the local
## certificate store?
##
## The consumer half of `ct test`'s certificates, usable from a pre-commit
## hook. It evaluates ONE state of a git repository:
##
## * ``--staged`` — the index being committed. Its content id is the tree
##   ``git write-tree`` returns for that index, which honours the
##   ``GIT_INDEX_FILE`` git points at a temporary index for ``commit -a`` and
##   ``commit <paths>``, so inside a pre-commit hook it is exactly the tree the
##   commit will record (test-certificates-spec Content-Id.md §5);
## * ``--worktree`` — the tracked files as they are, computed in a temporary
##   index as a producer computes them (Content-Id.md §4.1);
## * ``--commit <rev>`` — ``<rev>^{tree}``.
##
## and answers with three exit codes (Verification.md §7): ``0`` covered,
## ``1`` not covered, ``2`` could not decide — a state with no content id, a
## record this consumer cannot evaluate that might have covered the gap, an
## unreadable store or configuration, an empty requirement, or a command line
## it cannot act on. Exactly one line on stderr says which and why. "No
## certificate found for this content" and "certificates found, none
## matched" are different lines (Transport.md §5): the first usually means
## the tests were never run on this content, the second that they were and
## do not cover what is required.
##
## Why ``--staged`` needs no stat distrust
## ---------------------------------------
## The working-tree computation dates its temporary index at the epoch
## (``certificate_content_id.StatDistrustTime``) because ``git add --update``
## would otherwise trust stat data and could hash OLD bytes for a file edited
## within the index's timestamp granularity. ``--staged`` runs no ``add`` at
## all: ``write-tree`` builds the tree from the object ids already recorded in
## the index, and those ARE what the commit records — for ``commit -a`` git
## refreshed and re-added the working tree into that index itself before the
## hook ran. Nothing in the staged computation reads a working-tree file, so
## there is no stat data to distrust.
##
## The requirement
## ---------------
## `ct test`'s own (CTC-3 operator decision 4): framework ``ct-test`` only —
## any other framework's record is IGNORED and named as such, never rejected
## (Verification.md §2) — the host platform, and as targets, in order of
## precedence:
##
## 1. ``--targets`` (comma-separated or repeated), when given;
## 2. else ``[certificate] targets`` in the workspace's committed
##    ``.codetracer/test.toml`` (the project-definitions file set's
##    declarative ``dfkTest``), read FROM THE STATE BEING EVALUATED — the
##    index for ``--staged``, the commit for ``--commit``, the file on disk
##    for ``--worktree`` — so the list a commit is gated on is the list that
##    commit carries, and an unstaged edit to the file cannot move the gate;
## 3. else every target ``ct test discover`` reports for the workspace whose
##    provider can run here (``run_orchestration.isRunnableUnit``): a target
##    nothing on this platform can run is one no run here could certify.
##
## A configuration file that exists and cannot be used — an unknown schema
## version, an unknown key, a malformed value — is exit 2, naming the file.
## It is never read as "no declared list", which would silently widen or
## narrow the gate. ``--platform`` replaces the host platform.
##
## A pre-commit hook
## -----------------
## ``PreCommitHookCommand`` is the documented one line. It is the EARLY
## answer, not the enforcement point (``git commit --no-verify`` skips it),
## and it must run AFTER every hook step that rewrites staged content: a step
## that stages a rewritten file after the gate has checked produces a commit
## the gate never saw (Standard.md §5.1).
##
## Nothing here signs or writes: the store is read through
## ``certificate_store``'s read-only seam, and git is asked only read-only
## plumbing questions plus the content-id recipe, which writes loose objects
## and nothing else.

import std/[algorithm, json, os, sets, strutils, tables]

import contracts
import discovery
import run_orchestration
import certificate
import certificate_issuance
import certificate_content_id
import certificate_content_id_native
import certificate_store
import certificate_store_roots_native
import certificate_verification
import ../ct/launch/project_definitions_dir

const
  VerifyCovered* = 0
    ## Every required target is covered on every required platform.
  VerifyNotCovered* = 1
    ## The requirement is not met, and every record that could not be
    ## evaluated was irrelevant to it: run the tests.
  VerifyUndecided* = 2
    ## This consumer could not tell. Re-running the tests changes nothing
    ## until the reason in the stderr line is addressed.

  PreCommitHookCommand* = "ct test verify --staged"
    ## The one line a project puts LAST in ``.git/hooks/pre-commit``.

  VerifyStderrPrefix* = "ct test verify: "

type
  VerifyStateKind* = enum
    vskStaged = "staged"
    vskWorktree = "worktree"
    vskCommit = "commit"

  VerifyOptions* = object
    state*: VerifyStateKind
    revision*: string
    workspace*: string
    targets*: seq[string]
    targetsGiven*: bool
    platforms*: seq[string]
    platformsGiven*: bool
    jsonOutput*: bool
    errors*: seq[string]

  RequirementSource* = enum
    rsTargetsFlag = "--targets"
    rsDeclared = "declared"
    rsDiscovered = "discovered"

  ResolvedRequirement* = object
    ok*: bool
    problem*: string
      ## Why no requirement could be formed; the verb exits 2 on it.
    source*: RequirementSource
    file*: string
      ## The configuration file consulted, repository-relative; empty when
      ## ``--targets`` made it unnecessary.
    targets*: seq[string]
    notRequired*: seq[string]
      ## Discovered targets whose provider cannot run here (``rsDiscovered``).

proc verifyUsage*(): string =
  "ct test verify (--staged | --worktree | --commit <rev>) " &
  "[--workspace <path>] [--targets <t>[,<t>...]] [--platform <p>[,<p>...]] " &
  "[--json]"

proc splitList(value: string; into: var seq[string]; flag: string;
               errors: var seq[string]) =
  for part in value.split(','):
    let item = part.strip()
    if item.len == 0:
      errors.add "an empty entry in " & flag & " '" & value & "'"
    elif item notin into:
      into.add item

proc parseVerifyArgs*(args: seq[string]): VerifyOptions =
  ## The ``test verify`` argument vector. Exactly one state is required:
  ## guessing one would answer a question nobody asked.
  var states = 0
  var i = 0
  while i < args.len:
    let arg = args[i]
    case arg
    of "--staged":
      result.state = vskStaged
      inc states
    of "--worktree":
      result.state = vskWorktree
      inc states
    of "--commit":
      if i + 1 >= args.len:
        result.errors.add "missing value for --commit"
      else:
        result.state = vskCommit
        result.revision = args[i + 1]
        inc i
      inc states
    of "--workspace":
      if i + 1 >= args.len: result.errors.add "missing value for --workspace"
      else: result.workspace = args[i + 1]; inc i
    of "--targets":
      if i + 1 >= args.len: result.errors.add "missing value for --targets"
      else:
        result.targetsGiven = true
        splitList(args[i + 1], result.targets, "--targets", result.errors)
        inc i
    of "--platform":
      if i + 1 >= args.len: result.errors.add "missing value for --platform"
      else:
        result.platformsGiven = true
        splitList(args[i + 1], result.platforms, "--platform", result.errors)
        inc i
    of "--json":
      result.jsonOutput = true
    else:
      result.errors.add "unknown verify argument: " & arg
    inc i
  if states == 0:
    result.errors.add "say which state to evaluate: --staged, --worktree " &
                      "or --commit <rev>"
  elif states > 1:
    result.errors.add "--staged, --worktree and --commit are exclusive; " &
                      "give exactly one"
  if result.state == vskCommit and
     (result.revision.len == 0 or result.revision.startsWith("-")):
    result.errors.add "--commit needs a revision, not '" & result.revision & "'"
  if result.workspace.len == 0:
    result.workspace = getCurrentDir()
  result.workspace = absolutePath(result.workspace)

# ---------------------------------------------------------------------------
# Git, read-only
# ---------------------------------------------------------------------------

proc git(host: ContentIdHost; cwd: string; args: openArray[string]): GitReply =
  ## One read-only plumbing call. The inherited environment is kept on
  ## purpose — inside a hook, ``GIT_INDEX_FILE`` names the index being
  ## committed — and ``GIT_OPTIONAL_LOCKS=0`` keeps git from refreshing an
  ## index while answering.
  host.git(GitCall(argv: @["git"] & @args, cwd: cwd,
                   env: @[("GIT_OPTIONAL_LOCKS", "0")]))

proc oneLine(reply: GitReply): string =
  result = reply.stdout
  result.stripLineEnd()

proc describeState(options: VerifyOptions): string =
  case options.state
  of vskStaged: "the staged content"
  of vskWorktree: "the working tree"
  of vskCommit: "commit " & options.revision

proc contentStateOf(options: VerifyOptions): ContentState =
  case options.state
  of vskStaged: indexState()
  of vskWorktree: workingTreeState()
  of vskCommit: commitState(options.revision)

# ---------------------------------------------------------------------------
# The configuration file, read from the state being evaluated
# ---------------------------------------------------------------------------

type
  ConfigRead = object
    ok: bool
    problem: string
    file: string
    declared: bool
    targets: seq[string]

proc readTestConfiguration(host: ContentIdHost; toplevel, scope: string;
                           options: VerifyOptions): ConfigRead =
  ## ``<scope>/.codetracer/test.toml`` as the evaluated state has it, through
  ## the project-definitions loader. Only this one constant name is read.
  let reported = definitionPath(scope, dfkTest)
  result.file = reported
  var files: seq[DefinitionFile]
  var problems: seq[ProjectDefinitionProblem]
  case options.state
  of vskWorktree:
    let scan = readCheckoutDefinition(toplevel, scope, dfkTest)
    files = scan.files
    problems = scan.problems
  of vskStaged, vskCommit:
    # `:<path>` is the index's stage-0 entry (the index being committed,
    # inside a hook); `<rev>:<path>` is the commit's.
    let spec = (if options.state == vskStaged: ":" else: options.revision & ":") &
               reported
    let lookup = git(host, toplevel, ["rev-parse", "--verify", "-q", spec])
    if lookup.exitCode == 1 and lookup.complete:
      return ConfigRead(ok: true, file: reported)       # no such file there
    if lookup.exitCode != 0 or not lookup.complete:
      return ConfigRead(file: reported, problem: "git could not look up '" &
        spec & "': " & lookup.stderr.strip())
    let oid = oneLine(lookup)
    let kind = git(host, toplevel, ["cat-file", "-t", oid])
    if kind.exitCode != 0 or oneLine(kind) != "blob":
      return ConfigRead(file: reported, problem: "'" & reported & "' in " &
        describeState(options) & " is not a file")
    let size = git(host, toplevel, ["cat-file", "-s", oid])
    var bytes = 0
    try:
      bytes = parseInt(oneLine(size))
    except ValueError:
      return ConfigRead(file: reported, problem: "git could not size '" &
        reported & "': " & size.stderr.strip())
    if bytes > MaxDefinitionBytes:
      # Before the read, as the disk reader does.
      return ConfigRead(file: reported, problem: "'" & reported & "' is " &
        $bytes & " bytes; the bound is " & $MaxDefinitionBytes)
    let blob = git(host, toplevel, ["cat-file", "blob", oid])
    if blob.exitCode != 0 or not blob.complete:
      return ConfigRead(file: reported, problem: "git could not read '" &
        reported & "': " & blob.stderr.strip())
    files = @[DefinitionFile(kind: dfkTest, origin: doProject, scope: scope,
                             path: reported, text: blob.stdout)]

  let loaded = loadProjectDefinitions(files)
  for problem in loaded.problems:
    problems.add problem
  let refused = refusals(problems)
  if refused.len > 0:
    var rendered: seq[string]
    for problem in refused:
      rendered.add render(problem)
    return ConfigRead(file: reported, problem: "the ct test configuration '" &
      reported & "' could not be used, so no requirement is assumed: " &
      rendered.join("; "))
  let found = testConfigurationFor(loaded.project, scope)
  result.ok = true
  if found.found and found.config.certificateTargetsDeclared:
    result.declared = true
    result.targets = found.config.certificateTargets

# ---------------------------------------------------------------------------
# The requirement
# ---------------------------------------------------------------------------

proc discoveredRequirement*(workspace: string; registry: ProviderRegistry;
                            cache: DiscoveryCache): ResolvedRequirement =
  ## Every target ``ct test discover`` reports for ``workspace`` that a
  ## provider here can run. A target is named as ``ct test run`` names it in
  ## a certificate: the test file, workspace-relative
  ## (``workspace_scope.workspaceRelativePath``, the rule
  ## ``certificate_issuance`` applies to the targets it attests).
  result.source = rsDiscovered
  let response = discover(
    DiscoverRequest(scope: dskWorkspace, workspaceRoot: workspace), registry,
    cache)
  if discoverExitCode(response) != 0:
    var messages: seq[string]
    for d in response.diagnostics:
      if d.severity == dsError:
        messages.add d.message
    result.problem = "`ct test discover` failed, so the targets to require " &
      "are unknown: " & messages.join("; ")
    return
  var required = initOrderedSet[string]()
  var unrunnable = initOrderedSet[string]()
  for unit in enumerateRunUnits(response, registry):
    let target = workspaceRelativePath(workspace, unit.item.file)
    if target.len == 0:
      continue
    if isRunnableUnit(registry, unit):
      required.incl target
    else:
      unrunnable.incl target
  for target in required:
    result.targets.add target
  for target in unrunnable:
    if target notin required:
      result.notRequired.add target
  # Byte order, so the report does not depend on directory enumeration.
  result.targets.sort(system.cmp[string])
  result.notRequired.sort(system.cmp[string])
  result.ok = true

proc resolveRequirement*(options: VerifyOptions; host: ContentIdHost;
                         toplevel, scope: string; registry: ProviderRegistry;
                         cache: DiscoveryCache): ResolvedRequirement =
  ## ``--targets``, else the declared list, else discovery (module header).
  if options.targetsGiven:
    return ResolvedRequirement(ok: options.targets.len > 0,
      source: rsTargetsFlag, targets: options.targets,
      problem: (if options.targets.len == 0: "--targets names no target"
                else: ""))
  let config = readTestConfiguration(host, toplevel, scope, options)
  if not config.ok:
    return ResolvedRequirement(source: rsDeclared, file: config.file,
                               problem: config.problem)
  if config.declared:
    return ResolvedRequirement(ok: true, source: rsDeclared, file: config.file,
                               targets: config.targets)
  result = discoveredRequirement(options.workspace, registry, cache)
  result.file = config.file
  if result.ok and result.targets.len == 0:
    result.ok = false
    result.problem = "there is nothing to require: discovery found no test " &
      "a provider here can run" &
      (if result.notRequired.len > 0:
         " (" & $result.notRequired.len & " discovered, none runnable here)"
       else: "") &
      ", and '" & config.file & "' declares no [certificate] targets"

# ---------------------------------------------------------------------------
# The verb
# ---------------------------------------------------------------------------

type
  VerifyResult* = object
    exitCode*: int
    line*: string
      ## The one stderr line, without the prefix.
    report*: JsonNode

proc notes(entries: seq[CertificateNote]): JsonNode =
  result = newJArray()
  for entry in entries:
    result.add %*{"certificate": entry.certificate, "why": entry.why}

proc summarise(entries: seq[CertificateNote]; label: string): string =
  if entries.len == 0:
    return ""
  var parts: seq[string]
  for entry in entries:
    parts.add entry.certificate.extractFilename & " (" & entry.why & ")"
  label & " " & $entries.len & ": " & parts.join(", ")

proc undecided(report: JsonNode; reason: string): VerifyResult =
  report["outcome"] = %"undecided"
  report["exit"] = %VerifyUndecided
  report["reason"] = %reason
  VerifyResult(exitCode: VerifyUndecided,
               line: "could not decide (exit 2) — " & reason, report: report)

proc evaluateVerify*(options: VerifyOptions; registry: ProviderRegistry;
                     cache: DiscoveryCache): VerifyResult =
  ## Everything ``test verify`` does except printing. Never raises for a
  ## state it cannot judge: that is exit 2, with the reason.
  var report = %*{"state": $options.state, "workspace": options.workspace}
  if options.state == vskCommit:
    report["revision"] = %options.revision
  let host = nativeContentIdHost()
  let what = describeState(options)

  # ---- the repository ----------------------------------------------------
  let top = git(host, options.workspace, ["rev-parse", "--show-toplevel"])
  if top.exitCode != 0 or not top.complete:
    return undecided(report, "'" & options.workspace & "' is not inside a " &
      "git working tree, so there is no content to look up: " &
      top.stderr.strip())
  let toplevel = oneLine(top)
  let prefixReply = git(host, options.workspace, ["rev-parse", "--show-prefix"])
  if prefixReply.exitCode != 0 or not prefixReply.complete:
    return undecided(report, "git could not place '" & options.workspace &
      "' inside its repository: " & prefixReply.stderr.strip())
  var scope = oneLine(prefixReply)
  if scope.endsWith("/"):
    scope.setLen(scope.len - 1)
  let repo = toplevel.lastPathPart
  report["repo"] = %repo

  # ---- the state's content id --------------------------------------------
  let format = repositoryTreeAlgorithm(host, toplevel)
  if not format.ok:
    return undecided(report, "the repository's object format could not be " &
      "read: " & format.failure)
  let contentState = contentStateOf(options)
  let content = computeContentId(host, toplevel, contentState, format.algorithm)
  case content.outcome
  of cioComputed:
    report["content"] = %content.id
  of cioNoContentId:
    var conditions = newJArray()
    for state in content.states:
      conditions.add %*{"condition": $state.condition, "paths": state.paths}
    report["no_content_id"] = conditions
    return undecided(report, what & " has no content id, so no certificate " &
      "can cover it: " & content.reason)
  of cioCannotCompute, cioFailed:
    return undecided(report, "the content id of " & what & " could not be " &
      "computed: " & content.reason)

  # ---- the requirement ---------------------------------------------------
  let requirement = resolveRequirement(options, host, toplevel, scope,
                                       registry, cache)
  var platforms = options.platforms
  if not options.platformsGiven:
    platforms = @[currentPlatform()]
  report["requirement"] = %*{
    "source": $requirement.source, "file": requirement.file,
    "framework": CtTestFramework, "targets": requirement.targets,
    "platforms": platforms, "not_required": requirement.notRequired}
  if not requirement.ok:
    return undecided(report, requirement.problem)
  if platforms.len == 0:
    return undecided(report, "--platform names no platform")

  # ---- the store ---------------------------------------------------------
  let store = readCertificateStore(nativeStoreAccess(), options.workspace,
    LocalStoreQuery(roots: nativeCertificateStoreRoots(),
                    contentIds: @[content.id]))
  report["searched"] = %store.searched
  var foundNames: seq[string]
  for record in store.certificates:
    foundNames.add record.name
  report["found"] = %foundNames
  report["store_rejected"] = %store.rejected
  report["store_problems"] = %store.problems
  if store.unreadable:
    return undecided(report, "the certificate store could not be read: " &
      store.unreadableReason)

  # ---- the verdict (Verification.md) -------------------------------------
  # The oracle answers for THIS state, in whatever algorithm and scope a
  # record names; the repository's own algorithm over the whole tree is the
  # id already computed. Memoised: several records usually ask the same.
  var answers = initTable[string, ContentAnswer]()
  let oracle: ContentOracle = proc(algorithm: string; paths: seq[string]):
      ContentAnswer {.closure.} =
    let key = algorithm & "\0" & paths.join("\0")
    if key in answers:
      return answers[key]
    let (known, parsed) = lookupAlgorithm(algorithm)
    if not known:
      result = ContentAnswer(computed: false,
        reason: "'" & algorithm & "' is not an algorithm this consumer knows")
    elif parsed == content.algorithm and paths.len == 0:
      result = ContentAnswer(computed: true, id: content.id)
    else:
      let other = computeContentId(host, toplevel, contentState, parsed, paths)
      result =
        if other.outcome == cioComputed: ContentAnswer(computed: true, id: other.id)
        else: ContentAnswer(computed: false, reason: other.reason)
    answers[key] = result
  var candidates: seq[CandidateCertificate]
  for record in store.certificates:
    candidates.add CandidateCertificate(name: record.name, text: record.text)
  let verdict = verifyCertificates(
    EvaluatedState(repo: repo, content: oracle),
    Requirement(frameworksImplemented: @[CtTestFramework],
                framework: CtTestFramework, targets: requirement.targets,
                platforms: platforms),
    candidates, KeyStore())
  var missing = newJArray()
  for gap in verdict.missing:
    missing.add %*{"framework": gap.framework, "platform": gap.platform,
                   "targets": gap.targets}
  report["missing"] = missing
  report["rejected"] = notes(verdict.rejected)
  report["ignored"] = notes(verdict.ignored)
  report["unevaluated"] = notes(verdict.unevaluated)

  let sourceText =
    case requirement.source
    of rsTargetsFlag: "--targets"
    of rsDeclared: requirement.file
    of rsDiscovered: "the targets `ct test discover` reports that can run here"
  let requirementText = $requirement.targets.len & " target(s) from " &
    sourceText & " on " & platforms.join(", ")
  var tail: seq[string]
  for part in [summarise(verdict.rejected, "rejected"),
               summarise(verdict.ignored, "ignored (not ct-test)"),
               summarise(verdict.unevaluated, "unevaluated")]:
    if part.len > 0:
      tail.add part
  for problem in store.rejected:
    tail.add problem
  for problem in store.problems:
    tail.add "note: " & problem
  let tailText = (if tail.len > 0: "; " & tail.join("; ") else: "")

  case verdict.outcome
  of ocCovered:
    report["outcome"] = %"covered"
    report["exit"] = %VerifyCovered
    VerifyResult(exitCode: VerifyCovered, report: report,
      line: "covered (exit 0) — " & what & " (" & content.id & ") is " &
        "covered for " & requirementText & tailText)
  of ocUnverifiable:
    undecided(report, "a record that could not be evaluated might cover " &
      what & " (" & content.id & ") for " & requirementText & tailText)
  of ocNotCovered:
    report["outcome"] = %"not-covered"
    report["exit"] = %VerifyNotCovered
    var gaps: seq[string]
    for gap in verdict.missing:
      gaps.add gap.targets.join(", ") & " on " & gap.platform
    let found = store.certificates.len + store.rejected.len
    report["finding"] = %(if found == 0: "none-found" else: "none-matched")
    let line =
      if found == 0:
        "not covered (exit 1) — none found: no certificate in the local " &
        "certificate store for " & what & " (" & content.id & "); searched " &
        store.searched.join(", ") & "; run the tests on this content " &
        "(`ct test run`) to issue one" & tailText
      else:
        "not covered (exit 1) — none matched: " & $found & " record(s) " &
        "found for " & what & " (" & content.id & "), none covering " &
        gaps.join("; ") & " (required: " & requirementText & ")" & tailText
    VerifyResult(exitCode: VerifyNotCovered, report: report, line: line)

proc runVerify*(args: seq[string]; registry: ProviderRegistry;
                cache: DiscoveryCache): int =
  ## ``ct test verify``. One line on stderr, always; the full report on
  ## stdout with ``--json``.
  let options = parseVerifyArgs(args)
  if options.errors.len > 0:
    # A command line this verb cannot act on is "could not decide": a hook
    # that misspells its flag must refuse, and must not read as "not covered,
    # run the tests".
    stderr.writeLine VerifyStderrPrefix & "could not decide (exit 2) — " &
      options.errors.join("; ") & "; usage: " & verifyUsage()
    if options.jsonOutput:
      echo (%*{"outcome": "undecided", "exit": VerifyUndecided,
               "errors": options.errors}).pretty
    return VerifyUndecided
  var verdict: VerifyResult
  try:
    verdict = evaluateVerify(options, registry, cache)
  except CatchableError as err:
    verdict = VerifyResult(exitCode: VerifyUndecided,
      line: "could not decide (exit 2) — " & err.msg,
      report: %*{"outcome": "undecided", "exit": VerifyUndecided,
                 "reason": err.msg})
  if options.jsonOutput:
    verdict.report["message"] = %verdict.line
    echo verdict.report.pretty
  # ONE line: a hook's output is read by a person mid-commit, and git's own
  # messages may carry line breaks into a reason.
  stderr.writeLine VerifyStderrPrefix &
    verdict.line.replace("\r\n", " ").replace('\n', ' ')
  verdict.exitCode
