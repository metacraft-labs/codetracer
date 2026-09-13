## launch/project_executable_tier.nim — PLAT-13's gated reader. The ONLY thing
## in this product that opens an executable-tier definition file.
##
## ## WHY THIS IS A SEPARATE FILE FROM `project_definitions_dir.nim`
##
## §6 puts the trust gate on a FILE rather than on a section of one, and this is
## that sentence applied to the reader as well as to the format. PLAT-11's
## reader is structurally incapable of reading an executable definition — its
## `readDefinitionFile` hands on a `DefinitionFile` with an EMPTY `text` for any
## kind whose `tierOf` is `dtExecutable`, and PLAT-11's own arms (D1, D5, L3)
## and its case "the executable-tier file's BYTES never enter the process" hold
## that down. **That file is untouched by PLAT-13.**
##
## So there are two readers, and which one can read which tier is decided by
## which file you are in rather than by a branch inside one of them. A reader of
## `project_definitions_dir.nim` can satisfy themselves that cloning and opening
## reads no code without reading this file at all.
##
## ## THE ORDER IS THE DELIVERABLE
##
##   1. does the file exist? (a `stat`, never an `open`)
##   2. `project_trust.mayReadBytes` — **before any open**
##   3. the path is exactly where a definition file must be — no symlink, in
##      this checkout
##   4. the size bound, from `stat`, before the read
##   5. read, through a descriptor that is verified to be the file that was
##      checked
##   6. digest, and `project_trust.admit`
##   7. decode, through `project_executables.admitExecutable`
##   8. **and again on every run.** `visualiseWithCurrentTrust` /
##      `diffWithCurrentTrust` re-read the ledger and re-ask
##      `stillAdmitted` before a held handle executes anything, because an
##      admitted definition is a CACHED PARSE and a fresh load that finds
##      nothing cannot see a handle somebody is already holding
##
## Steps 2 and 6 are the same predicate asked twice with different information —
## `mayReadBytes` is `admit` without the digest test, and both read one private
## function in `project_trust.nim`. They are not two checks: they are one check
## at the only two moments it can be asked.
##
## **Nothing before step 5 opens the file.** That is what makes "cloning a
## repository and opening it in CodeTracer must not execute code from that
## repository" assertable as an EFFECT: the suite makes the file unreadable at
## the OS level, and a load with no grant reports nothing about permissions
## while a load WITH a grant reports the `EACCES` — one function, one fixture,
## and the only difference between the two runs is the decision.
##
## ## CONTAINMENT IS AN EQUALITY HERE, NOT A `pathIsUnder`
##
## PLAT-11 had to ask "is this path, which a repository chose, inside the
## checkout" — a containment question, answered by `capabilities.pathIsUnder`
## over two `realpath`s. This file asks something narrower, because the path is
## a CONSTANT (`layout.definitionPath`): it must be exactly
## `<resolved checkout>/.codetracer/<name>`.
##
## That equality is strictly stronger than containment: a `.codetracer` that is
## a symlink, a `visualisers.wasm` that is a symlink to an identical file
## elsewhere, and a bind mount in the middle all make the two strings differ
## while `pathIsUnder` would be satisfied. Calling `pathIsUnder` as well was
## considered and REFUSED: it would be a second mechanism with no case only it
## can satisfy, and Verification-Harness-Traps §16a is that defence in depth
## silently halves mutation coverage unless each mechanism gets evidence of its
## own. One rule, one arm, one case.
##
## `O_NOFOLLOW` and the `(dev, ino)` re-verification below are the exception to
## that paragraph and they are declared as such: they close the window BETWEEN
## the resolve and the open, which no equality can, and PLAT-11 measured that
## they are not independently arm-able when the path opened is `realpath`'s own
## output. They are recorded as deliberately unarmed, with that measurement, in
## PLAT-13's status section rather than left implicit.

import std/[os, strutils]

when defined(posix):
  import std/posix

import ../../common/project_executables
import ../../common/project_definitions
import ./project_trust_store

export project_executables, project_trust_store

type
  ExecutableTierScan* = object
    ## What one checkout's executable tier produced.
    ##
    ## `definitions` is what may RUN. `problems` is every file that exists and
    ## did not become one, with the reason — a definition that is simply absent
    ## is not a problem, because almost every repository has none and reporting
    ## its absence would be noise on every launch (PLAT-11's `DiscoveryOutcome`,
    ## same rule).
    identity*: RepositoryIdentity
    definitions*: seq[ExecutableDefinition]
    problems*: seq[ExecutableTierProblem]

when defined(posix):
  let O_NOFOLLOW_CT {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    ## `std/posix` declares `O_CLOEXEC` and not this, on every platform. Taken
    ## from the header rather than written as a number because the value differs
    ## between Linux (0o400000), the BSDs (0x100) and macOS — PLAT-11's
    ## `project_definitions_dir.nim` carries the same declaration and the same
    ## reason.

proc resolvedRealPath(path: string): string =
  ## `realpath(3)` on POSIX, or "" when the path resolves to nothing.
  ##
  ## NOT SHARED WITH PLAT-11's identically-shaped function, and the reason is
  ## the one PLAT-11 itself gave for not sharing PLAT-8's `canonicalPath`:
  ## `project_definitions_dir.resolvedRealPath` is private, and exporting it
  ## would edit a file whose literal lines PLAT-11's arms D6, D7 and D8 quote —
  ## an arm whose needle a tidy-up moved is silently unkillable
  ## (Verification-Harness-Traps §16). The four lines are duplicated knowingly;
  ## what is NOT duplicated is a decision, which is §14's actual subject.
  ##
  ## On Windows `expandFilename` is `GetFullPathNameW`, which normalises and
  ## resolves no link, so the equality below is a normalisation there and a real
  ## resolution on POSIX. Stated rather than implied — PLAT-8 shipped the
  ## opposite sentence and a verification pass had to withdraw it.
  try:
    expandFilename(path)
  except CatchableError, Defect:
    ""

proc readVerified(path: string; dest: var string): string =
  ## Read a file through a descriptor verified to be the file that was checked.
  ## Returns "" on success or the reason it failed.
  ##
  ## The path handed in is `realpath`'s own output, so it contains no symlink in
  ## any position as of the resolve; `O_NOFOLLOW` and the `fstat`/`lstat`
  ## comparison close the window between that resolve and this open, and they
  ## FAIL CLOSED — a disagreement is an error, never a retry.
  when not defined(posix):
    try:
      dest = readFile(path)
    except CatchableError as e:
      return e.msg
    return ""
  else:
    var fd = posix.open(path.cstring, O_RDONLY or O_NOFOLLOW_CT or O_CLOEXEC)
    if fd < 0:
      return "open failed (errno " & $errno & ")"
    var opened, named: Stat
    if fstat(fd, opened) != 0 or lstat(path.cstring, named) != 0 or
       opened.st_dev != named.st_dev or opened.st_ino != named.st_ino:
      discard posix.close(fd)
      return "the file changed between being checked and being opened"
    var f: File
    if not open(f, FileHandle(fd), fmRead):
      discard posix.close(fd)
      return "the descriptor could not be read"
    try:
      dest = f.readAll()
    except CatchableError as e:
      f.close()
      return e.msg
    f.close()
    return ""

proc readExecutableDefinition*(root: string; scope: string;
                               kind: DefinitionFileKind;
                               ledger: ProjectTrustLedger;
                               identity: RepositoryIdentity;
                               scan: var ExecutableTierScan) =
  ## ONE executable definition, from one `.codetracer/`. See the header for the
  ## order, which is the deliverable.
  let reported = definitionPath(scope, kind)

  # 1. A `stat`. An absent definition is not a problem and not a decision.
  let resolvedRoot = resolvedRealPath(root)
  if resolvedRoot.len == 0: return
  let expected = resolvedRoot / reported
  if not fileExists(expected): return

  # 2. THE GRANT, BEFORE ANY OPEN.
  let permission = mayReadBytes(ledger, identity, kind)
  if not permission.permitted:
    scan.problems.add ExecutableTierProblem(
      file: reported, code: codeFor(permission.refusal),
      detail: admissionText(permission.refusal) & ". " &
              admissionRemedy(permission.refusal) &
              ". The file was NOT opened, not read, not decoded and not run")
    return

  # 3. The file must be exactly where a definition file is. See the header.
  let resolvedFile = resolvedRealPath(expected)
  if resolvedFile.len == 0 or resolvedFile != expected:
    scan.problems.add ExecutableTierProblem(
      file: reported, code: etcNotContained,
      detail: "it resolves to '" &
        (if resolvedFile.len == 0: "(nothing)" else: resolvedFile) &
        "' rather than to '" & expected & "'. An executable definition is read " &
        "only from the exact place a definition file lives, so a symlink — in " &
        "the file, in '.codetracer', or anywhere above them — cannot make the " &
        "host run bytes from outside the repository you granted")
    return

  # 4. The size bound, from a `stat`, BEFORE the read. Reading a gigabyte and
  #    then refusing it for being large is a denial of service with a polite
  #    message (PLAT-11's `readDefinitionFile`, same rule).
  var size: BiggestInt = 0
  try:
    size = getFileSize(expected)
  except CatchableError as e:
    scan.problems.add ExecutableTierProblem(file: reported, code: etcUnreadable,
      detail: "could not be measured: " & e.msg)
    return
  if size > MaxWasmBytes:
    scan.problems.add ExecutableTierProblem(file: reported,
      code: etcMalformedModule,
      detail: $size & " bytes on disk; the bound is " & $MaxWasmBytes &
        ". The size is taken before the file is opened, so an oversized " &
        "module costs a stat rather than a read")
    return

  # 5. The read.
  var bytes = ""
  let failure = readVerified(expected, bytes)
  if failure.len > 0:
    scan.problems.add ExecutableTierProblem(file: reported, code: etcUnreadable,
      detail: failure)
    return

  # 6 and 7. The digest, the admission, and the decode — in `project_executables`,
  # which is the one door.
  let digest = contentDigest(bytes)
  let admission = admit(ledger, identity, kind, digest)
  let admitted = admitExecutable(kind, reported, digest, bytes, admission,
                                 identity)
  if not admitted.ok:
    scan.problems.add admitted.problem
    return
  if not admitted.definition.hasEntryPoint:
    scan.problems.add ExecutableTierProblem(file: reported,
      code: etcMissingExport,
      detail: "it exports no '" & exportFor(kind) & "'")
    return
  scan.definitions.add admitted.definition

proc scanExecutableTier*(root: string; ledger: ProjectTrustLedger;
                         packageScopes: openArray[string] = []):
    ExecutableTierScan =
  ## Every executable definition in a checkout that this user has trusted, and
  ## a named problem for every one they have not.
  ##
  ## THE SCOPE LIST IS THE CALLER'S AND IS CHECKED, exactly as PLAT-11's is: a
  ## recursive walk of a cloned repository is an unbounded amount of work over
  ## attacker-chosen directory names, and a scope is a path from the repository
  ## so it is checked like one.
  result.identity = checkoutIdentity(root)
  for kind in executableKinds():
    readExecutableDefinition(root, "", kind, ledger, result.identity, result)
  var scopes = 0
  for scope in packageScopes:
    inc scopes
    if scopes > MaxDefinitionScopes:
      result.problems.add ExecutableTierProblem(
        file: ProjectDefinitionDir, code: etcNotContained,
        detail: "more than " & $MaxDefinitionScopes &
          " package scopes were offered to one scan")
      break
    if pathProblem(scope) != ppOk:
      result.problems.add ExecutableTierProblem(
        file: scope & "/" & ProjectDefinitionDir, code: etcNotContained,
        detail: describe(pathProblem(scope), scope) &
          ". A package scope is a path from the repository root and is " &
          "checked as one")
      continue
    for kind in executableKinds():
      readExecutableDefinition(root, scope, kind, ledger, result.identity,
                               result)

proc loadCheckoutExecutableTier*(root: string; userRoot = "";
                                 packageScopes: openArray[string] = []):
    ExecutableTierScan =
  ## The whole of PLAT-13, from two directories: read the user's trust ledger,
  ## then scan the checkout against it.
  ##
  ## A LEDGER THAT COULD NOT BE READ ADMITS NOTHING, and that is the safe
  ## direction rather than an accident: `parseTrustLedger` keeps the rows that
  ## parsed and reports the rest, so a corrupted line costs the grants it
  ## carried and never manufactures one.
  let parse = loadProjectTrust(userRoot)
  result = scanExecutableTier(root, parse.ledger, packageScopes)
  for p in parse.problems:
    result.problems.add ExecutableTierProblem(
      file: "<project trust ledger>", code: etcNoGrant, detail: p)

proc visualiseWithCurrentTrust*(d: ExecutableDefinition; input: string;
                                userRoot = "";
                                work = MaxExecutableWork): VisualisedText =
  ## RUN A HELD HANDLE, AGAINST THE DECISION AS IT IS NOW.
  ##
  ## A session keeps `ExecutableDefinition`s between loads — that is what a
  ## cached parse is for — and a revocation taken in another process, or in
  ## this one, has to reach them. `scanExecutableTier` cannot: it answers about
  ## a FRESH load, and a fresh load that finds nothing is the one shape that
  ## cannot see a handle somebody is already holding. That is PLAT-10's
  ## `resolveAll()` defect restated, and it is why `visualiseWith` takes a
  ## ledger at all.
  ##
  ## So this is the entry point a caller holding a handle uses: re-read the
  ## user's ledger off disk, and let `stillAdmitted` decide. A ledger that
  ## cannot be read parses to an EMPTY one, which admits nothing — the safe
  ## direction, and the same direction `loadCheckoutExecutableTier` fails in.
  d.visualiseWith(loadProjectTrust(userRoot).ledger, input, work)

proc diffWithCurrentTrust*(d: ExecutableDefinition; a, b: string;
                           userRoot = "";
                           work = MaxExecutableWork): DiffAnswer =
  ## `visualiseWithCurrentTrust`'s twin for §7's comparison, through the same
  ## re-read and the same `stillAdmitted` (one predicate, one function).
  d.diffWith(loadProjectTrust(userRoot).ledger, a, b, work)

proc describeScan*(scan: ExecutableTierScan): string =
  ## What a reader is shown. Every definition that ran and every one that did
  ## not, with the reason — because "this project ships a visualiser and I see
  ## nothing" needs an answer other than silence (PLAT-11's
  ## `pdnExecutableTierPresent`, one tier up).
  var lines: seq[string] = @[]
  for d in scan.definitions:
    lines.add "  trusted: " & d.file & " (" & d.digest & ")"
  for p in scan.problems:
    lines.add "  " & render(p)
  if lines.len == 0:
    return "checkout '" & scan.identity &
      "': no executable-tier definitions"
  "checkout '" & scan.identity & "':\n" & lines.join("\n")
