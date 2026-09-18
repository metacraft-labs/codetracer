## launch/project_trust_store.nim — PLAT-13's filesystem half of the trust
## grant: where a checkout's identity comes from, and where the decision lives.
##
## `common/project_trust.nim` has the model and no filesystem. This file has the
## filesystem and no model. The split is PLAT-10's (`plugin_model/grant_ledger`
## / `launch/grant_store`) and PLAT-11's (`common/project_definitions` /
## `launch/project_definitions_dir`), for the same reason both give: it is what
## makes the policy assertable in `common-units`, a lane that links no renderer
## and opens no handle.
##
## ## THE LOCK, THE STAGING FILE AND THE ATOMIC RENAME ARE PLAT-10'S, BY CALL
##
## `grant_store.nim` already solved "two processes edit one ledger": a
## pid-unique staging path so two writers never share a staging inode, an
## exclusive `flock(2)` spanning the whole read-modify-write so a lost `revoke`
## cannot restore a capability the user took back, and a lock file that is a
## SEPARATE INODE from the ledger because an advisory lock is held on an inode
## and the ledger is replaced by `moveFile`.
##
## Every one of those arguments applies here unchanged, and the second-worst
## thing this file could do is re-derive them. So it CALLS them:
## `withGrantLedgerLock` and `grantLedgerStagingPath` both take the ledger's
## path as a parameter, so they serialise THIS ledger with no edit to
## `grant_store.nim` at all — which also means PLAT-10's mutation arms keep
## pointing at the lines they quote (Verification-Harness-Traps §16).
##
## The worst thing it could do is invent a second user root. It does not:
## `launcherUserRoot()` is PLAT-10's, so a user who moves
## `CODETRACER_USER_ROOT` to a second profile gets that profile's plugin grants
## AND that profile's project grants, rather than half of each.
##
##     <user root>/grants/v1/grants.tsv     PLAT-10 — per-plugin capabilities
##     <user root>/grants/v1/projects.tsv   THIS FILE — per-repository trust
##
## Two files rather than one because the two are keyed on different things — a
## plugin id and a checkout identity — and a single table with a nullable key
## would be a schema that can represent a row nobody can interpret.
##
## ## WHAT THE TWO ENTRY POINTS RETURN, AND WHY IT IS NOT A `bool` ANYWHERE
##
## `grantExecutableTier` and `revokeExecutableTier` answer "" on success or the
## problem, and "success" means *the decision the caller asked for is the one in
## force* — not "a row was appended". Re-granting a decision already recorded
## appends nothing and succeeds; a field the ledger's grammar cannot carry
## appends nothing and FAILS, and both were one `bool` that both call sites
## `discard`ed until 2026-09-13. `recordReport` is the one place either of them
## turns the ledger's answer into a report, and `project_trust.decisionStands`
## is the one place the two non-records are told apart.
##
## ## IDENTITY IS THE CHECKOUT DIRECTORY ITSELF, NOT ITS NAME
##
## §2.3: "recorded by identity rather than by path, so moving a checkout does
## not silently re-grant and a different repository at the same path does not
## inherit it."
##
## `checkoutIdentity` resolves the checkout with `realpath(3)` and then asks the
## operating system for the DIRECTORY's own identity — `(device, file-id)`,
## which is `(st_dev, st_ino)` on POSIX and the volume serial plus file index on
## Windows. Four properties follow, and each is a clause of §2.3 or of PLAT-13's
## own test list:
##
##   | event | identity | effect |
##   |---|---|---|
##   | `mv checkout elsewhere` | unchanged | the grant survives the move; nothing is re-granted |
##   | `cp -r checkout copy` | DIFFERENT | the copy is not granted — a grant is for one checkout |
##   | `rm -rf checkout && git clone other checkout` | DIFFERENT | a different repository at the same path inherits nothing |
##   | the path is reached through a symlink | unchanged | resolving first is what makes two names for one directory one identity |
##
## **WHY NOT THE GIT REMOTE OR THE ROOT COMMIT.** Both were considered and both
## are wrong here, and the reason is the same in each case: they identify the
## PROJECT and not the CHECKOUT. Two clones of one repository would share a
## grant, so trusting a colleague's fork you have read would silently trust the
## upstream you have not — and neither is available at all for a repository with
## no remote or no commits. They are also data *inside the repository*, which is
## the one place a trust key must not come from.
##
## **THE RESIDUAL, NAMED RATHER THAN LEFT TO BE FOUND.** An inode number can be
## REUSED after the directory holding it is deleted. A checkout that is removed
## and a different repository created in its place *may*, on some filesystems,
## land on the same `(device, inode)` and inherit the grant. Mitigated rather
## than closed: the grant is also bound to the executable file's CONTENT DIGEST
## (`project_trust.admit`), so the reused identity still admits nothing unless
## the new repository ships byte-identical code. Closing it properly needs a
## marker the host writes somewhere the repository cannot reach and is named
## here rather than implemented.

import std/[os, strutils]

import nimcrypto/[sha2, hash]

import ../../common/project_trust
import ./grant_store

export project_trust

const
  projectTrustFileName* = "projects.tsv"
    ## Beside PLAT-10's `grants.tsv`, under the same `grants/v1/`.

proc projectTrustLedgerPath*(root = ""): string =
  ## The ledger's absolute path, or "" when there is no user root.
  ##
  ## DERIVED FROM `grant_store.grantLedgerPath` by replacing its last component,
  ## so the two ledgers cannot come to live in different directories — the one
  ## thing that would break the "one profile, one set of decisions" property the
  ## header is about.
  let sibling = grantLedgerPath(root)
  if sibling.len == 0: return ""
  sibling.parentDir / projectTrustFileName

proc checkoutIdentity*(root: string): RepositoryIdentity =
  ## The identity of ONE checkout, or "" when there is not one to identify.
  ##
  ## THE EMPTY ANSWER IS THE ONE A CALLER MUST HANDLE, and `project_trust.admit`
  ## turns it into `etaNoIdentity` rather than into a grant. A path that does
  ## not exist, is not a directory, or cannot be `stat`ed has no identity, and
  ## inventing one from the string would be exactly the path-keyed grant §2.3
  ## forbids.
  ##
  ## ## ONE RESOLUTION, AND TWO MECHANISMS WERE DELETED TO GET THERE
  ##
  ## This function first read `expandFilename(root)`, then `dirExists` on the
  ## result, then `getFileInfo(..., followSymlink = true)`, and it was WRONG in
  ## the way Verification-Harness-Traps §32a describes rather than in its answer:
  ## three mechanisms, two of them redundant, so two mutation arms aimed at real
  ## lines could not be killed.
  ##
  ##   * `expandFilename` was redundant with `followSymlink = true`. Measured, by
  ##     arm S3: replacing it with `resolved = root` left the suite GREEN,
  ##     because `getFileInfo` follows the link itself and answers the TARGET's
  ##     identity either way.
  ##   * `dirExists` was redundant with `info.kind != pcDir`. Measured, by arm
  ##     S2: `if false: return ""` on the kind test left the suite green, because
  ##     `dirExists` had already refused every file.
  ##
  ## Both are gone. What remains is ONE call that resolves and ONE test of what
  ## it found, each with an arm that kills — which is what §14 buys when there is
  ## one predicate, and what §32a says you have to pay for the moment there are
  ## deliberately two.
  if root.len == 0: return ""
  try:
    let info = getFileInfo(root, followSymlink = true)
    if info.kind != pcDir: return ""
    result = "fs1:" & $info.id.device & ":" & $info.id.file
  except CatchableError, Defect:
    return ""

proc contentDigest*(bytes: string): string =
  ## The digest a grant is recorded over.
  ##
  ## SHA-256, from `nimcrypto`, which `src/ct/ci/bpf_monitor.nim` and
  ## `src/ct/online_sharing/artifact_crypto.nim` already use for the same
  ## purpose in this repository. It is here rather than in `common/` because
  ## `common/project_trust.nim` is pure and asserted in a lane with no
  ## dependencies; what the model needs is a STRING it compares, and what
  ## produces the string is the half that already links a crypto library.
  ##
  ## It is not a `hash` and it is not `std/sha1`: this value is the thing that
  ## stops a `git pull` inheriting a grant, so a collision is somebody else's
  ## code running under a decision that was taken about different code.
  "sha256:" & toLowerAscii($sha256.digest(bytes))

proc loadProjectTrustFrom*(path: string): TrustLedgerParse =
  ## An absent file is an EMPTY ledger with no problems — a machine where nobody
  ## has trusted a repository yet is the ordinary first run. An UNREADABLE one
  ## IS a problem, because "nothing is trusted" and "I could not read what is
  ## trusted" have to be distinguishable (`grant_store.loadGrantLedgerFrom`, and
  ## the same argument).
  if path.len == 0:
    result.problems.add "no user root: neither " & userRootEnvVar &
      " nor HOME is set, so there is nowhere to read a project trust grant from"
    return
  if not fileExists(path):
    return
  var text: string
  try:
    text = readFile(path)
  except CatchableError as e:
    result.problems.add "could not read the project trust ledger at '" & path &
      "': " & e.msg
    return
  result = parseTrustLedger(text)
  for i in 0 ..< result.problems.len:
    result.problems[i] = path & ": " & result.problems[i]

proc loadProjectTrust*(root = ""): TrustLedgerParse =
  loadProjectTrustFrom(projectTrustLedgerPath(root))

proc writeTrustLocked(ledger: ProjectTrustLedger; path: string): string =
  ## THE CALLER HOLDS THE LOCK. `flock` on a second descriptor of the same file
  ## from the same process BLOCKS, so a save that took its own lock inside an
  ## update that already held one would deadlock against itself — PLAT-10's
  ## `writeLedgerLocked` carries the same sentence for the same reason.
  try:
    createDir(path.parentDir)
    let staging = grantLedgerStagingPath(path)
    writeFile(staging, ledger.render())
    moveFile(staging, path)
  except CatchableError as e:
    return "could not write the project trust ledger at '" & path & "': " & e.msg
  ""

proc saveProjectTrustTo*(ledger: ProjectTrustLedger; path: string): string =
  ## "" on success, or the problem. Not an exception: the caller is a user
  ## action ("stop trusting this") whose failure has to reach that user.
  if path.len == 0:
    return "no user root: neither " & userRootEnvVar & " nor HOME is set, " &
      "so there is nowhere to record a project trust grant"
  withGrantLedgerLock(path):
    result = writeTrustLocked(ledger, path)

proc updateProjectTrustAt*(path: string;
                           edit: proc(l: var ProjectTrustLedger)): string =
  ## THE READ-MODIFY-WRITE, UNDER ONE LOCK, and the operation a revocation
  ## actually is.
  ##
  ## PLAT-10 measured why this cannot be "load, edit, save": two processes that
  ## each load the same starting ledger both succeed and the file carries
  ## whichever was written last. No file is torn; one decision is simply gone.
  ## If the lost one is a `revoke`, the code is running again at the next start
  ## — the one direction this record must never fail in.
  if path.len == 0:
    return "no user root: neither " & userRootEnvVar & " nor HOME is set, " &
      "so there is nowhere to record a project trust grant"
  withGrantLedgerLock(path):
    var current = loadProjectTrustFrom(path).ledger
    edit(current)
    result = writeTrustLocked(current, path)

proc updateProjectTrust*(root = "";
                         edit: proc(l: var ProjectTrustLedger)): string =
  updateProjectTrustAt(projectTrustLedgerPath(root), edit)

proc recordReport(checkoutRoot: string; outcome: TrustRecordOutcome;
                  failure: string): string =
  ## TURN WHAT THE LEDGER DID INTO WHAT THE CALLER IS TOLD. "" only when the
  ## decision the caller asked for is the one in force.
  ##
  ## ONE FUNCTION, BOTH ENTRY POINTS (§14). `grantExecutableTier` and
  ## `revokeExecutableTier` both `discard`ed the ledger's answer until
  ## 2026-09-13 and both returned "" — so a `revoke` whose `at` carried a
  ## newline reported SUCCESS while nothing was written and the definition went
  ## on loading and running. Two call sites that decide this separately are two
  ## chances to make that mistake again; this is the only place either of them
  ## turns an outcome into a report.
  ##
  ## AND THE TEST IS `decisionStands`, NOT `recorded`. Re-granting a decision
  ## already in force appends nothing and is a success; a field that cannot be
  ## written appends nothing and is a failure. The two were one `bool` and that
  ## is how this arrived.
  if failure.len > 0: return failure
  if decisionStands(outcome): return ""
  "the decision about '" & checkoutRoot & "' was NOT recorded: " &
    outcomeText(outcome)

proc grantExecutableTier*(userRoot, checkoutRoot: string;
                          kind: DefinitionFileKind; digest, at: string;
                          note = ""): string =
  ## The whole of "the user said yes", from a directory: identify the checkout,
  ## take the lock, record ONE decision about ONE file and ONE digest.
  ##
  ## THE NOTE DEFAULTS TO THE CHECKOUT PATH AND THE PATH DECIDES NOTHING. §2.3's
  ## "by identity rather than by path" is a statement about what `admit` reads;
  ## a user looking at a ledger of `fs1:66306:1441795` rows with no idea which
  ## directory each was is a user who cannot exercise the "visible" half of the
  ## same sentence.
  ##
  ## AND A DEFAULT DERIVED FROM A PATH IS AN INJECTION SITE. Measured on
  ## 2026-09-13: a checkout whose directory name carried a newline and a
  ## tab-separated `grant` row made ONE call to this function record TWO
  ## decisions, the second of them against a DIFFERENT checkout, and
  ## `parseTrustLedger` read both back with no problems reported. The ledger
  ## now refuses a field it cannot carry (`project_trust.representableField`)
  ## and `pathAnnotation` is where that refusal meets a path.
  let identity = checkoutIdentity(checkoutRoot)
  if identity.len == 0:
    return "'" & checkoutRoot & "' is not a checkout this machine can " &
      "identify, so there is nothing to record a grant against"
  # THE ANNOTATION GOES THROUGH ONE FUNCTION (`project_trust.pathAnnotation`),
  # because a checkout path is the most attacker-reachable string in this
  # record and the ledger's grammar refuses a field that would become a second
  # ROW. A path that cannot be a field costs its annotation and never its
  # grant; §2.3's decision came from the identity, not from the path.
  let annotation = if note.len > 0: note else: pathAnnotation(checkoutRoot)
  # THE LEDGER'S ANSWER IS CARRIED OUT OF THE CLOSURE, NOT `discard`ED.
  # `pathAnnotation` closes the DEFAULT note; `at`, and a `note` the caller
  # supplies, come from the caller and go into the same row grammar, so the
  # decision can still be refused here — and a refusal reported as "" is a
  # decision the user believes they took.
  var outcome = troNoIdentity
  let failure = updateProjectTrust(userRoot, proc(l: var ProjectTrustLedger) =
    outcome = l.grant(identity, kind, digest, at, annotation))
  recordReport(checkoutRoot, outcome, failure)

proc revokeExecutableTier*(userRoot, checkoutRoot: string;
                           kind: DefinitionFileKind; at: string;
                           note = ""): string =
  ## The whole of "the user took it back". Symmetrical with the grant, through
  ## the same lock and the same read-modify-write.
  let identity = checkoutIdentity(checkoutRoot)
  if identity.len == 0:
    return "'" & checkoutRoot & "' is not a checkout this machine can " &
      "identify, so there is no grant recorded against it to withdraw"
  let annotation = if note.len > 0: note else: pathAnnotation(checkoutRoot)
  # AND HERE IT MATTERS MOST, WHICH IS WHY IT IS A SEPARATE CALL SITE RATHER
  # THAN A SHARED ONE. A grant that is not recorded fails CLOSED. A revocation
  # that is not recorded fails OPEN: `updateProjectTrustAt`'s own comment says
  # "if the lost one is a `revoke`, the code is running again at the next
  # start", and until 2026-09-13 this line reached that state with no race at
  # all — an `at` carrying a newline, answered "".
  var outcome = troNoIdentity
  let failure = updateProjectTrust(userRoot, proc(l: var ProjectTrustLedger) =
    outcome = l.revoke(identity, kind, at, annotation))
  recordReport(checkoutRoot, outcome, failure)
