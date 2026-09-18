## project_executable_tier_test.nim — PLAT-13's real-disk suite. Real
## directories, real files, real permissions, real symlinks, a real `flock`ed
## ledger, and real WebAssembly modules that really run.
##
## ## NO MOCKS. NOTHING HERE STANDS IN FOR ANYTHING
##
## Every checkout below is a directory under `getTempDir()` with real files in
## it; every grant goes through `project_trust_store`, which takes the same
## `flock(2)` and writes through the same pid-unique staging path PLAT-10 uses
## for plugin capabilities; every module is decoded by the shipped decoder and
## executed by the shipped interpreter. The only thing constructed by hand is
## the wasm bytes, and the builder that emits them
## (`common/project_wasm_fixtures.nim`) is an ENCODER of the published binary
## format, not a double — its header argues that at length.
##
## ## WHAT "CLONING AND OPENING EXECUTES NOTHING" IS ASSERTED ON
##
## Verification-Harness-Traps runs through every escape this campaign found and
## they all share one shape: the report was unchanged while the state moved. So
## the gate is asserted on effects, at three levels, and the weakest of the
## three is the one most suites would have stopped at:
##
##   1. **the needle.** `ExecutionNeedle` is a byte string that occurs nowhere
##      else in this repository, and no module CONTAINS it — `storeLiteral`
##      emits one `i32.store8` per character, so the needle can only appear if
##      those instructions RETIRED. Every case that asserts a refusal sweeps the
##      WHOLE of what the load produced for it: the scan's rendering, every
##      problem's text, and the visualiser's answer. PLAT-11 swept the same way
##      for `PRIVATE-KEY-MATERIAL-ct-plat11`, because a "safe" message is a
##      common place for the thing you refused to come back.
##   2. **the syscall that did not happen.** The definition file is made
##      unreadable at the OS level and the fixture is PROVED unreadable before
##      it is used. A load with no grant then reports nothing about permissions;
##      the SAME function over the SAME directory WITH a grant reports the
##      `open` failure. A reader that opened the file and swallowed the error
##      passes the first arm and fails the second.
##   3. **the returned status**, which is asserted too and is evidence of
##      nothing on its own.
##
## ## THIS SUITE REQUIRES A NON-ROOT USER, AND SAYS SO RATHER THAN SKIPPING
##
## Arm 2 rests on the kernel enforcing a file mode. `root` is not subject to
## one, so the case PROVES its fixture first — an ordinary `readFile` of the
## unreadable file must fail — and goes red rather than quiet if it does not. A
## case that silently skipped would be invisible coverage, which is the failure
## this repository's lane report exists to make impossible.
##
## ## TRAP 13 (Verification-Harness-Traps §13, §13a)
##
## Every assertion helper is a `template`.
##
## Compile and run:
##   nim c -r src/ct/launch/project_executable_tier_test.nim

import std/[os, strutils, unittest]

when defined(posix):
  import std/posix

import ./project_executable_tier
import ../../common/project_wasm_fixtures
import ../../common/project_definitions
import ./project_definitions_dir
import ./grant_store

const ExpectedAssertions = 199
  ## Written from a run, and asserted against the tally at the end of the file.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

template ckNoNeedle(scan: ExecutableTierScan; visualised: string) =
  ## THE EFFECT ASSERTION. Everything the load produced is swept for the needle
  ## — the rendering, every problem's own text, and whatever a caller managed to
  ## visualise — because a refusal that quotes the thing it refused has leaked
  ## it, and because a module that ran and was then discarded is
  ## indistinguishable from one that did not run if you only read a status.
  inc countedAssertions
  var leaked = false
  if describeScan(scan).contains(ExecutionNeedle): leaked = true
  for p in scan.problems:
    if render(p).contains(ExecutionNeedle): leaked = true
    if p.detail.contains(ExecutionNeedle): leaked = true
  if visualised.contains(ExecutionNeedle): leaked = true
  if leaked:
    checkpoint("the needle came back:\n" & describeScan(scan) &
               "\n  visualised: " & visualised)
  check not leaked

template ckRefusedWith(scan: ExecutableTierScan; wantedFile: string;
                       wanted: ExecutableTierCode) =
  ## A refusal asserted BY CODE (§4b): this gate has eleven distinct refusals
  ## and their remedies differ, so "it refused" is not an assertion.
  ##
  ## THE PARAMETER IS `wantedFile` AND NOT `file`, and that is not cosmetic: a
  ## template parameter named `file` is substituted into `p.file` inside its own
  ## body, which does not compile and would otherwise be fixed by hoisting the
  ## comparison out of the helper — into a `proc`, which is trap 13.
  inc countedAssertions
  var sawWanted = false
  for p in scan.problems:
    if p.code == wanted and p.file == wantedFile: sawWanted = true
  if not sawWanted:
    checkpoint("wanted " & $wanted & " for '" & wantedFile & "', got:\n" &
               describeScan(scan))
  check sawWanted

let At = "2026-09-12T12:00:00Z"

var worldCounter = 0

type World = object
  root: string      ## the checkout
  userRoot: string  ## the launcher's user root, where the ledger lives

proc newWorld(name: string): World =
  ## A real directory pair, torn down and rebuilt per case so no case inherits
  ## another's ledger.
  inc worldCounter
  let base = getTempDir() / ("ct-plat13-" & name & "-" & $getCurrentProcessId() &
                             "-" & $worldCounter)
  removeDir(base)
  createDir(base / "checkout" / ProjectDefinitionDir)
  createDir(base / "userroot")
  World(root: base / "checkout", userRoot: base / "userroot")

proc writeExecutable(w: World; kind: DefinitionFileKind; bytes: string): string =
  ## Put a module where a definition file lives, and answer its digest.
  let path = w.root / definitionPath("", kind)
  createDir(path.parentDir)
  writeFile(path, bytes)
  contentDigest(bytes)

proc writeDeclarative(w: World) =
  ## A real declarative definition beside the executable one, so every case can
  ## assert the tier that is supposed to load still does.
  writeFile(w.root / ProjectDefinitionDir / "points.toml", """
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"

[[collection.point]]
kind = "tracepoint"
path = "src/router.nim"
anchor = "proc handleRequest"
""")
  createDir(w.root / "src")
  writeFile(w.root / "src" / "router.nim", "proc handleRequest() =\n  discard\n")

proc scanOf(w: World): ExecutableTierScan =
  loadCheckoutExecutableTier(w.root, w.userRoot)

proc visualisedBy(w: World; scan: ExecutableTierScan): string =
  ## Drive the path that RUNS things. A scan with no definition produces no
  ## text, which is exactly what makes this the right place to sweep for the
  ## needle: a gate that leaked a definition would produce it here.
  ##
  ## IT GOES THROUGH `visualiseWithCurrentTrust`, which is what a session
  ## holding a handle calls: the ledger is re-read and `stillAdmitted` is asked
  ## again. A helper that ran the handle unconditionally would make every
  ## revocation case below assert a FRESH LOAD finding nothing, which is the
  ## one shape that cannot see a handle already in hand.
  for d in scan.definitions:
    if d.kind == dfkVisualiserCode:
      return d.visualiseWithCurrentTrust("a recorded value", w.userRoot).text
  ""

# ---------------------------------------------------------------------------
# 1. The gate. Cloning and opening runs nothing.
# ---------------------------------------------------------------------------

suite "PLAT-13: cloning and opening a repository executes NOTHING":

  test "an executable definition with no grant is not run — on the EFFECT":
    var w = newWorld("nogrant")
    w.writeDeclarative()
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())

    # THE FIXTURE IS PROVED BEFORE IT IS USED (§4). A needle that never could
    # have appeared proves nothing about the gate, so the same module, admitted
    # by hand, is shown to produce it.
    var proofTrust: ProjectTrustLedger
    discard proofTrust.grant(checkoutIdentity(w.root), dfkVisualiserCode,
                             digest, At, "proof")
    let proof = admitExecutable(dfkVisualiserCode, "proof", digest,
                                readFile(w.root / definitionPath("", dfkVisualiserCode)),
                                etaAdmitted, checkoutIdentity(w.root))
    ck proof.ok
    ckEq proof.definition.visualiseWith(proofTrust, "a recorded value").text,
         ExecutionNeedle

    let scan = scanOf(w)
    ckEq scan.definitions.len, 0
    ckRefusedWith scan, ".codetracer/visualisers.wasm", etcNoGrant
    ckNoNeedle scan, visualisedBy(w, scan)
    ck describeScan(scan).contains("was NOT opened, not read, not decoded")

    # AND THE DECLARATIVE TIER STILL LOADS, which is §2.1's whole point: the
    # useful majority is data, and it arrives without a decision.
    let declarative = loadCheckoutDefinitions(w.root)
    ckEq declarative.project.collections.len, 1
    ckEq declarative.project.collections[0].name, "the request path"
    var sawNotice = false
    for p in declarative.problems:
      if p.code == pdnExecutableTierPresent: sawNotice = true
    ck sawNotice

  test "with no grant the file is not OPENED — the syscall that did not happen":
    var w = newWorld("noopen")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    let path = w.root / definitionPath("", dfkVisualiserCode)

    # Make the bytes unreadable, and PROVE the kernel is enforcing it before
    # anything is concluded from it. Running this suite as root makes the
    # fixture unprovable, and it goes RED rather than quiet — see the header.
    setFilePermissions(path, {})
    var enforced = false
    try:
      discard readFile(path)
    except CatchableError:
      enforced = true
    ck enforced

    # NO GRANT: nothing is said about permissions, because nothing was opened.
    let refused = scanOf(w)
    ckEq refused.definitions.len, 0
    ckRefusedWith refused, ".codetracer/visualisers.wasm", etcNoGrant
    var sawUnreadable = false
    for p in refused.problems:
      if p.code == etcUnreadable: sawUnreadable = true
    ck not sawUnreadable
    ck not describeScan(refused).contains("open failed")

    # THE TWIN, THROUGH THE SAME FUNCTION OVER THE SAME DIRECTORY: with a grant
    # in force the read IS attempted and the refusal is the operating system's.
    # A reader that had opened the file and swallowed the error would pass the
    # arm above and fail this one.
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    let attempted = scanOf(w)
    ckEq attempted.definitions.len, 0
    ckRefusedWith attempted, ".codetracer/visualisers.wasm", etcUnreadable
    ck describeScan(attempted).contains("open failed")
    ckNoNeedle attempted, visualisedBy(w, attempted)

    setFilePermissions(path, {fpUserRead, fpUserWrite})

  test "a granted definition RUNS, which is what makes the refusals mean something":
    var w = newWorld("granted")
    w.writeDeclarative()
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    let scan = scanOf(w)
    ckEq scan.problems.len, 0
    ckEq scan.definitions.len, 1
    ckEq scan.definitions[0].file, ".codetracer/visualisers.wasm"
    ckEq scan.definitions[0].digest, digest
    ckEq visualisedBy(w, scan), ExecutionNeedle
    ck describeScan(scan).contains("trusted: .codetracer/visualisers.wasm")

# ---------------------------------------------------------------------------
# 2. §2.3: by identity rather than by path
# ---------------------------------------------------------------------------

suite "PLAT-13: the grant is recorded by IDENTITY, not by path":

  test "a COPY of a granted checkout is not granted":
    var w = newWorld("copy")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    ckEq visualisedBy(w, scanOf(w)), ExecutionNeedle

    let copyRoot = w.root.parentDir / "copy-of-checkout"
    copyDir(w.root, copyRoot)
    # The bytes are identical, so the DIGEST cannot be what refuses this — only
    # the identity can, which is what makes this case disjoint from the
    # content-changed one (Verification-Harness-Traps §32a).
    ckEq contentDigest(readFile(copyRoot / definitionPath("", dfkVisualiserCode))),
         digest
    ck checkoutIdentity(copyRoot) != checkoutIdentity(w.root)
    ck checkoutIdentity(copyRoot).len > 0

    let copied = loadCheckoutExecutableTier(copyRoot, w.userRoot)
    ckEq copied.definitions.len, 0
    ckRefusedWith copied, ".codetracer/visualisers.wasm", etcNoGrant
    ckNoNeedle copied, visualisedBy(w, copied)

  test "MOVING a granted checkout keeps its grant and re-grants nothing":
    var w = newWorld("moved")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    let before = checkoutIdentity(w.root)

    let movedRoot = w.root.parentDir / "moved-checkout"
    moveDir(w.root, movedRoot)
    # THE POSITIVE TWIN FOR THE CASE ABOVE. Without it, "a copy is not granted"
    # is equally satisfied by an identity that changes whenever anything at all
    # happens to a directory — which would make every grant last until the next
    # `mv` and teach users to re-grant reflexively.
    ckEq checkoutIdentity(movedRoot), before
    let moved = loadCheckoutExecutableTier(movedRoot, w.userRoot)
    ckEq moved.definitions.len, 1
    ckEq loadCheckoutExecutableTier(movedRoot, w.userRoot).definitions.len, 1
    var visualised = ""
    for d in moved.definitions:
      visualised = d.visualiseWithCurrentTrust("v", w.userRoot).text
    ckEq visualised, ExecutionNeedle
    # AND NOTHING WAS RECORDED BY THE MOVE. The ledger is the one it was.
    let parse = loadProjectTrust(w.userRoot)
    ckEq parse.ledger.entries.len, 1

  test "a DIFFERENT repository later at the same path inherits nothing":
    var w = newWorld("replaced")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    ckEq visualisedBy(w, scanOf(w)), ExecutionNeedle
    let granted = checkoutIdentity(w.root)

    # The replacement directory is created BEFORE the original is removed, so
    # its inode cannot be the original's — which makes this case deterministic
    # rather than a bet on the filesystem's allocator. (Inode reuse after a
    # delete is a named residual of this design; see PLAT-13's status section.)
    let staged = w.root.parentDir / "other-repository"
    createDir(staged / ProjectDefinitionDir)
    writeFile(staged / definitionPath("", dfkVisualiserCode), needleModule())
    removeDir(w.root)
    moveDir(staged, w.root)

    ck checkoutIdentity(w.root) != granted
    let other = scanOf(w)
    ckEq other.definitions.len, 0
    ckRefusedWith other, ".codetracer/visualisers.wasm", etcNoGrant
    ckNoNeedle other, visualisedBy(w, other)

  test "a checkout that cannot be identified is refused, not guessed at":
    var w = newWorld("noident")
    discard w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq checkoutIdentity(w.root.parentDir / "no-such-checkout"), ""
    ckEq checkoutIdentity(""), ""
    ckEq checkoutIdentity(w.root / definitionPath("", dfkVisualiserCode)), ""
    ck checkoutIdentity(w.root).startsWith("fs1:")
    # A path reached through a symlink is the SAME checkout, because the
    # identity is the directory and not the name.
    when defined(posix):
      let alias = w.root.parentDir / "alias"
      createSymlink(w.root, alias)
      ckEq checkoutIdentity(alias), checkoutIdentity(w.root)

  test "and a SCAN of a root that is not a checkout says so, rather than being silent":
    # THE PREDICATE ABOVE IS NOT THE REPORT, AND NOTHING ASSERTED THE REPORT.
    # `readExecutableDefinition` returned in silence for two different events —
    # "this repository ships no executable definitions", which is what almost
    # every repository is and is correct to be silent about, and "this is not a
    # checkout I can read at all", which is a failure. Both got the sentence a
    # healthy checkout gets. Measured on 2026-09-13, before the repair:
    #
    #   a path that does not exist:  identity=""  definitions=0  problems=0
    #   an empty root:               identity=""  definitions=0  problems=0
    #   a FILE, not a directory:     identity=""  definitions=0  problems=0
    #     describeScan: checkout '': no executable-tier definitions
    #
    # It failed CLOSED, which is why no refusal assertion anywhere could see it
    # (Verification-Harness-Traps §15, from the other end) and why only a case
    # about the REPORT can.
    var w = newWorld("noscan")
    var led: ProjectTrustLedger

    let absent = scanExecutableTier(w.root.parentDir / "no-such-checkout", led)
    ckEq absent.identity, ""
    ckEq absent.definitions.len, 0
    ck absent.problems.len > 0
    ckRefusedWith absent, ".codetracer/visualisers.wasm", etcNoIdentity
    ck describeScan(absent).contains("is not a directory this machine can")
    ck describeScan(absent).contains("no-such-checkout")

    let empty = scanExecutableTier("", led)
    ck empty.problems.len > 0
    ckRefusedWith empty, ".codetracer/visualisers.wasm", etcNoIdentity

    # A FILE, not a directory. This one RESOLVES — `realpath(3)` is perfectly
    # happy with it — so it is the case that separates "the root did not
    # resolve" from "the root is not a checkout", and a repair that had tested
    # only the first would leave it silent.
    let aFile = w.root.parentDir / "a-file-not-a-checkout"
    writeFile(aFile, "not a directory")
    let notDir = scanExecutableTier(aFile, led)
    ck notDir.problems.len > 0
    ckRefusedWith notDir, ".codetracer/visualisers.wasm", etcNoIdentity

    # THE TWIN, AND IT IS THE WHOLE POINT OF THE REPAIR (§4a, §15). A REAL
    # checkout that simply ships no executable definition is still SILENT —
    # almost every repository is in that state, and reporting it would be noise
    # on every launch. A repair that reported both would have been the same
    # defect with the sentences swapped.
    let healthy = scanExecutableTier(w.root, led)
    ck healthy.identity.len > 0
    ckEq healthy.definitions.len, 0
    ckEq healthy.problems.len, 0
    ck describeScan(healthy).contains("no executable-tier definitions")
    ck not describeScan(healthy).contains("is not a directory this machine can")

# ---------------------------------------------------------------------------
# 3. Revocation, through the path that runs things
# ---------------------------------------------------------------------------

suite "PLAT-13: revocation stops the code running, not only the record":

  test "after a revoke the running path produces nothing, and no needle":
    var w = newWorld("revoke")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    ckEq visualisedBy(w, scanOf(w)), ExecutionNeedle

    ckEq revokeExecutableTier(w.userRoot, w.root, dfkVisualiserCode, At), ""

    # PLAT-10's lesson: `resolveAll()` rebuilt from an un-narrowed parse and
    # handed a revoked capability back while the record said REVOKED. So this
    # asserts through `loadCheckoutExecutableTier` — the function a session
    # calls, which re-reads the ledger off disk — and on what it produces,
    # rather than on the ledger.
    let after = scanOf(w)
    ckEq after.definitions.len, 0
    ckRefusedWith after, ".codetracer/visualisers.wasm", etcRevoked
    ckNoNeedle after, visualisedBy(w, after)
    ckEq visualisedBy(w, after), ""
    ck describeScan(after).contains("Reinstalling, re-cloning or pulling does " &
                                    "not undo a revocation")

    # The record agrees, and it is the WEAKER of the two claims — it is asserted
    # second and on purpose.
    ckEq loadProjectTrust(w.userRoot).ledger.stateOf(
      checkoutIdentity(w.root), dfkVisualiserCode), tsRevoked

    # THE TWIN, IN THE SAME CASE: granting again brings the needle back, so the
    # absence above is the revocation and not a broken fixture.
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    ckEq visualisedBy(w, scanOf(w)), ExecutionNeedle

  test "the file changing after a grant is a separate decision, on the EFFECT":
    var w = newWorld("changed")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    ckEq visualisedBy(w, scanOf(w)), ExecutionNeedle

    # A `git pull` brings code the user consented to nothing about. The identity
    # is unchanged and the ledger still says `grant`, so ONLY the digest can
    # refuse this — which is what makes it disjoint evidence (§32a).
    discard w.writeExecutable(dfkVisualiserCode, echoLengthModule())
    ck checkoutIdentity(w.root).len > 0
    ckEq loadProjectTrust(w.userRoot).ledger.stateOf(
      checkoutIdentity(w.root), dfkVisualiserCode), tsGranted

    let pulled = scanOf(w)
    ckEq pulled.definitions.len, 0
    ckRefusedWith pulled, ".codetracer/visualisers.wasm", etcContentChanged
    ckEq visualisedBy(w, pulled), ""
    ck describeScan(pulled).contains("a grant covers the bytes it was given for")

    # Granting the NEW bytes admits them, so the refusal is about the change.
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode,
                             contentDigest(echoLengthModule()), At), ""
    ckEq visualisedBy(w, scanOf(w)), "16"   # `visualisedBy` passes 16 bytes

  test "the grant is per FILE: trusting a visualiser does not trust a diff":
    var w = newWorld("perfile")
    let vis = w.writeExecutable(dfkVisualiserCode, needleModule())
    discard w.writeExecutable(dfkDiffCode, byteEqualityDiffModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, vis, At), ""
    let scan = scanOf(w)
    ckEq scan.definitions.len, 1
    ckEq scan.definitions[0].kind, dfkVisualiserCode
    ckRefusedWith scan, ".codetracer/diffs.wasm", etcNoGrant

# ---------------------------------------------------------------------------
# 4. The bytes come from where a definition file lives, and nowhere else
# ---------------------------------------------------------------------------

suite "PLAT-13: an executable definition is read from its own place only":

  test "a checked-in symlink cannot make the host run bytes from outside":
    when defined(posix):
      var w = newWorld("symlink")
      let bytes = needleModule()
      let digest = w.writeExecutable(dfkVisualiserCode, bytes)
      ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
      ckEq visualisedBy(w, scanOf(w)), ExecutionNeedle

      # The outside file carries the SAME bytes, so the digest matches and the
      # grant is in force. Only the placement rule can refuse this.
      let outside = w.root.parentDir / "outside.wasm"
      writeFile(outside, bytes)
      let path = w.root / definitionPath("", dfkVisualiserCode)
      removeFile(path)
      createSymlink(outside, path)
      ckEq contentDigest(readFile(path)), digest

      let scan = scanOf(w)
      ckEq scan.definitions.len, 0
      ckRefusedWith scan, ".codetracer/visualisers.wasm", etcNotContained
      ckNoNeedle scan, visualisedBy(w, scan)
      ck describeScan(scan).contains("outside.wasm")

      # And `.codetracer` ITSELF being a symlink is the same refusal, which the
      # equality rule gets for free and a leaf-only check would not.
      var w2 = newWorld("symdir")
      let d2 = w2.writeExecutable(dfkVisualiserCode, bytes)
      ckEq grantExecutableTier(w2.userRoot, w2.root, dfkVisualiserCode, d2, At), ""
      let real = w2.root.parentDir / "elsewhere"
      moveDir(w2.root / ProjectDefinitionDir, real)
      createSymlink(real, w2.root / ProjectDefinitionDir)
      let scan2 = scanOf(w2)
      ckEq scan2.definitions.len, 0
      ckRefusedWith scan2, ".codetracer/visualisers.wasm", etcNotContained
      ckNoNeedle scan2, visualisedBy(w2, scan2)

      # THE TWIN: a checkout REACHED through a symlink still reads its own
      # files, so the rule refuses a link that leaves the checkout and not a
      # link that leads to it. PLAT-11 found exactly this half-repair by
      # writing the positive twin (Verification-Harness-Traps §15).
      var w3 = newWorld("linkroot")
      let d3 = w3.writeExecutable(dfkVisualiserCode, bytes)
      let alias = w3.root.parentDir / "alias-to-checkout"
      createSymlink(w3.root, alias)
      ckEq grantExecutableTier(w3.userRoot, alias, dfkVisualiserCode, d3, At), ""
      ckEq loadCheckoutExecutableTier(alias, w3.userRoot).definitions.len, 1
      var text3 = ""
      for d in loadCheckoutExecutableTier(alias, w3.userRoot).definitions:
        text3 = d.visualiseWithCurrentTrust("v", w3.userRoot).text
      ckEq text3, ExecutionNeedle

  test "an oversized module is refused by its SIZE, before it is read":
    var w = newWorld("oversize")
    var big = needleModule()
    while big.len <= MaxWasmBytes: big.add "\0"
    let digest = w.writeExecutable(dfkVisualiserCode, big)
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    let scan = scanOf(w)
    ckEq scan.definitions.len, 0
    ckRefusedWith scan, ".codetracer/visualisers.wasm", etcMalformedModule
    ck describeScan(scan).contains("costs a stat rather than a read")

  test "a granted file that is not a module this build runs is refused by name":
    var w = newWorld("notmodule")
    let digest = w.writeExecutable(dfkVisualiserCode, importingModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    let scan = scanOf(w)
    ckEq scan.definitions.len, 0
    ckRefusedWith scan, ".codetracer/visualisers.wasm", etcMalformedModule
    ck describeScan(scan).contains("handed NOTHING")

  test "a definition in a package scope outside the checkout is refused":
    var w = newWorld("scope")
    let scan = loadCheckoutExecutableTier(w.root, w.userRoot,
                                          ["../elsewhere", "packages/ok"])
    ckRefusedWith scan, "../elsewhere/.codetracer", etcNotContained
    ckEq scan.definitions.len, 0

  test "an absent definition is not a problem and not a decision":
    var w = newWorld("absent")
    w.writeDeclarative()
    let scan = scanOf(w)
    ckEq scan.definitions.len, 0
    ckEq scan.problems.len, 0
    ck describeScan(scan).contains("no executable-tier definitions")

# ---------------------------------------------------------------------------
# 5. §7, from disk: bounded, the offender named, the structural fallback taken
# ---------------------------------------------------------------------------

suite "PLAT-13: a project's own comparison, bounded by the host":

  test "a real diff definition answers, and a non-terminating one falls back":
    var w = newWorld("diff")
    let digest = w.writeExecutable(dfkDiffCode, byteEqualityDiffModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkDiffCode, digest, At), ""
    let scan = scanOf(w)
    ckEq scan.definitions.len, 1
    let good = scan.definitions[0]
    ckEq good.diffWithCurrentTrust("alpha", "alpha", w.userRoot).verdict, dvEqual
    ck good.diffWithCurrentTrust("alpha", "alpha", w.userRoot).fromDefinition
    ckEq good.diffWithCurrentTrust("alpha", "alphb", w.userRoot).verdict,
         dvDifferent

    # §7: "The host bounds it, reports the offender by name, and falls back to
    # the structural diff."
    let loopDigest = w.writeExecutable(dfkDiffCode, nonTerminatingModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkDiffCode, loopDigest, At), ""
    let looping = scanOf(w).definitions[0]
    let answer = looping.diffWithCurrentTrust("alpha", "alpha", w.userRoot)
    ckEq answer.verdict, dvEqual
    ck not answer.fromDefinition
    ckEq answer.offender, ".codetracer/diffs.wasm#" & DiffExport
    ck describeFallback(answer).contains(".codetracer/diffs.wasm")
    ck describeFallback(answer).contains("structurally instead")
    ckEq looping.diffWithCurrentTrust("alpha", "beta", w.userRoot).verdict,
         dvDifferent

# ---------------------------------------------------------------------------
# 6. The ledger on disk is PLAT-10's ledger, beside PLAT-10's
# ---------------------------------------------------------------------------

suite "PLAT-13: the trust ledger is a real, locked, atomically written file":

  test "it sits beside the plugin ledger and leaves no staging file behind":
    var w = newWorld("store")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""

    let path = projectTrustLedgerPath(w.userRoot)
    ckEq path, w.userRoot / "grants" / "v1" / "projects.tsv"
    ckEq path.parentDir, grantLedgerPath(w.userRoot).parentDir
    ck fileExists(path)
    ck readFile(path).startsWith(TrustLedgerHeader)

    var listed: seq[string] = @[]
    for kind, p in walkDir(path.parentDir):
      listed.add p.extractFilename
    # The LOCK outlives the write on purpose — it is a separate inode from the
    # ledger, because an advisory lock is held on an inode and the ledger is
    # REPLACED by `moveFile`. The STAGING file must not be there.
    ck "projects.tsv" in listed
    ck "projects.tsv.lock" in listed
    for name in listed:
      ck not name.contains(".tmp.")

    # A second decision goes through the read-modify-write under one lock and
    # keeps the first.
    ckEq revokeExecutableTier(w.userRoot, w.root, dfkVisualiserCode, At), ""
    let parse = loadProjectTrust(w.userRoot)
    ckEq parse.problems.len, 0
    ckEq parse.ledger.entries.len, 2
    ck parse.ledger.describe(checkoutIdentity(w.root)).contains(w.root)

  test "a ledger that cannot be identified or read grants nothing":
    var w = newWorld("nostore")
    discard w.writeExecutable(dfkVisualiserCode, needleModule())
    # A checkout that is not there cannot be granted, and the refusal says so
    # rather than recording a row against a path.
    let gone = w.root.parentDir / "not-a-checkout"
    ck grantExecutableTier(w.userRoot, gone, dfkVisualiserCode, "d", At).contains(
      "not a checkout this machine can identify")
    ck revokeExecutableTier(w.userRoot, gone, dfkVisualiserCode, At).contains(
      "no grant recorded against it to withdraw")
    ckEq loadProjectTrust(w.userRoot).ledger.entries.len, 0
    # And an unreadable ledger is a PROBLEM rather than an empty one, so "I
    # could not read what is trusted" and "nothing is trusted" stay apart.
    let scan = scanOf(w)
    ckEq scan.definitions.len, 0
    ckRefusedWith scan, ".codetracer/visualisers.wasm", etcNoGrant

# ---------------------------------------------------------------------------
# 7. A handle somebody is already holding, and a checkout path nobody chose
# ---------------------------------------------------------------------------

suite "PLAT-13: a revoke reaches a definition that is ALREADY loaded":

  test "a HELD handle stops running, asserted through the handle itself":
    # PLAT-10's `resolveAll()` one tier up. Every other revocation case in this
    # file asserts through `loadCheckoutExecutableTier` — a FRESH load — and a
    # fresh load that finds nothing is exactly the shape that cannot see a
    # handle a session is already holding. `ExecutableDefinition.module` IS the
    # cached parse, so this case takes a handle BEFORE the revoke and never
    # reloads it.
    var w = newWorld("heldhandle")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""

    let scan = scanOf(w)
    ckEq scan.definitions.len, 1
    let held = scan.definitions[0]          # <- the handle, taken once
    ckEq held.identity, checkoutIdentity(w.root)
    ckEq held.visualiseWithCurrentTrust("a recorded value", w.userRoot).text,
         ExecutionNeedle

    ckEq revokeExecutableTier(w.userRoot, w.root, dfkVisualiserCode, At), ""

    # THE SAME OBJECT, AFTER THE USER CHANGED THEIR MIND. `trustDisclosure`
    # says "withdrawing it stops the code running rather than only recording
    # that you changed your mind", and this is that sentence asserted.
    let after = held.visualiseWithCurrentTrust("a recorded value", w.userRoot)
    ck not after.fromDefinition
    ckEq after.text, ""
    ckEq after.problems.len, 1
    ckEq after.problems[0].code, etcRevoked
    ck not after.text.contains(ExecutionNeedle)
    for pb in after.problems:
      ck not render(pb).contains(ExecutionNeedle)
    # And §7's comparison from a held handle, through the same re-read.
    #
    # THESE TWO ARE NOT THE EVIDENCE FOR THE RE-READ, AND SAYING SO IS THE
    # POINT (§32a, §7a). The handle here is a `dfkVisualiserCode`, so
    # `diffWith`'s `entry != DiffExport` arm answers structurally and leaves
    # `fromDefinition` false for a reason that has nothing to do with the
    # revoke: a visualiser handle can never be `fromDefinition` through
    # `diffWith`, revoked or not. What these DO grade is that the entry point
    # is total from a held handle — a verdict is never absent, which is §7's
    # own requirement. The evidence that `diffWith` re-asks the ledger is the
    # pure suite's "a §7 comparison from a held handle falls back once the
    # grant is gone", which holds a REAL diff definition, and arm E10 is
    # attributed to that case's `Check failed: not answer.fromDefinition`.
    let answer = held.diffWithCurrentTrust("alpha", "alpha", w.userRoot)
    ck not answer.fromDefinition
    ckEq answer.verdict, dvEqual

    # THE TWIN, IN THE SAME CASE AND ON THE SAME OBJECT: granting again brings
    # the SAME handle back, so the refusal above is the decision rather than a
    # handle that has stopped working.
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    ckEq held.visualiseWithCurrentTrust("a recorded value", w.userRoot).text,
         ExecutionNeedle

suite "PLAT-13: a checkout path cannot write a second row into the ledger":

  test "a newline in a real directory name records ONE decision, not two":
    # THE INJECTION, WITH A REAL DIRECTORY. `grantExecutableTier` defaults the
    # ledger note to the checkout path, and POSIX permits a newline and a tab
    # in a directory name — so the most attacker-reachable string in the record
    # is the one a `git clone` argument chooses.
    when defined(posix):
      var w = newWorld("inject")
      let victim = newWorld("victim")
      let victimDigest = victim.writeExecutable(dfkVisualiserCode, needleModule())
      let victimIdentity = checkoutIdentity(victim.root)
      ck victimIdentity.len > 0

      # The VICTIM has decided nothing, proved before anything else happens.
      ckEq loadCheckoutExecutableTier(victim.root, w.userRoot).definitions.len, 0
      ckRefusedWith loadCheckoutExecutableTier(victim.root, w.userRoot),
        ".codetracer/visualisers.wasm", etcNoGrant

      # A checkout whose NAME is a forged ledger row for the victim.
      let forged = "evil\n" & ["grant", victimIdentity, "visualisers.wasm",
                              victimDigest, At,
                              "forged"].join($TrustFieldSeparator)
      let hostile = w.root.parentDir / forged
      createDir(hostile / ProjectDefinitionDir)
      writeFile(hostile / definitionPath("", dfkVisualiserCode), needleModule())
      let hostileDigest = contentDigest(needleModule())
      # THE FIXTURE IS PROVED: the directory really exists under that name and
      # really has an identity, so nothing below passes because the setup
      # quietly failed (§4).
      ck dirExists(hostile)
      ck checkoutIdentity(hostile).len > 0
      ck checkoutIdentity(hostile) != victimIdentity

      ckEq grantExecutableTier(w.userRoot, hostile, dfkVisualiserCode,
                               hostileDigest, At), ""

      # ONE CALL, ONE ROW. Before the grammar was closed this read TWO, with
      # zero problems, and the victim ran.
      let parse = loadProjectTrust(w.userRoot)
      ckEq parse.problems.len, 0
      ckEq parse.ledger.entries.len, 1
      # READ THROUGH A GUARD, so that a run in which NO row was recorded fails
      # this assertion instead of dying in the middle of it. A case that raises
      # here never reaches the two assertions below, and those are the only
      # evidence `pathAnnotation` has that `representableField` does not (§32a).
      var recordedNote = "(no row was recorded at all)"
      if parse.ledger.entries.len > 0:
        recordedNote = parse.ledger.entries[0].note
      ckEq recordedNote, UnrepresentablePathNote
      ckEq parse.ledger.stateOf(victimIdentity, dfkVisualiserCode), tsUndecided

      # AND ON THE EFFECT: the victim checkout still runs nothing.
      let victimScan = loadCheckoutExecutableTier(victim.root, w.userRoot)
      ckEq victimScan.definitions.len, 0
      ckRefusedWith victimScan, ".codetracer/visualisers.wasm", etcNoGrant
      ckNoNeedle victimScan, visualisedBy(victim, victimScan)

      # THE TWIN, AND IT IS `pathAnnotation`'S OWN EVIDENCE (§32a). Two
      # mechanisms stand between a hostile path and a forged row —
      # `representableField`, which refuses the FIELD, and `pathAnnotation`,
      # which substitutes a writable note — and `representableField` alone
      # would refuse the whole ROW, so the user's decision would be silently
      # lost. That is Verification-Harness-Traps §15 exactly: a repair failing
      # in the safe direction, with every security assertion MORE satisfied.
      # So the property only `pathAnnotation` has is that the hostile
      # checkout's OWN grant is still in force and its own code still runs.
      let hostileScan = loadCheckoutExecutableTier(hostile, w.userRoot)
      ckEq hostileScan.definitions.len, 1
      var ran = ""
      for d in hostileScan.definitions:
        ran = d.visualiseWithCurrentTrust("v", w.userRoot).text
      ckEq ran, ExecutionNeedle

      # And an ORDINARY path is still recorded verbatim, so the substitution
      # above is about this path rather than about every path.
      var plain = newWorld("plainpath")
      let d2 = plain.writeExecutable(dfkVisualiserCode, needleModule())
      ckEq grantExecutableTier(plain.userRoot, plain.root, dfkVisualiserCode,
                               d2, At), ""
      ck loadProjectTrust(plain.userRoot).ledger.describe(
        checkoutIdentity(plain.root)).contains(plain.root)

suite "PLAT-13: a decision the ledger refused is NOT reported as taken":

  test "a decision that could not be recorded is reported, and the code says so":
    # THE HALF `pathAnnotation` DOES NOT CLOSE. The default NOTE is derived from
    # the checkout path and goes through `pathAnnotation`; `at` — and a `note` a
    # caller supplies — do not, and they reach the same row grammar. Until
    # 2026-09-13 both entry points `discard`ed the ledger's answer and returned
    # "", so:
    #
    #     revoke with an `at` carrying a newline -> "" (SUCCESS), 0 rows
    #     the definition it was about: STILL LOADING, STILL RUNNING
    #
    # A grant that is not recorded fails CLOSED. A revocation that is not
    # recorded fails OPEN, which is the direction `updateProjectTrustAt`'s own
    # comment says this record must never fail in.
    var w = newWorld("unrecorded")
    let digest = w.writeExecutable(dfkVisualiserCode, needleModule())
    let hostileAt = "2026-09-13T12:00:00Z\ngrant\tfs1:0:0\tvisualisers.wasm"

    # 1. THE GRANT. Refused, reported, and nothing loads — fail-closed, which is
    #    why the report rather than the effect is what moves here.
    let refusedGrant = grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode,
                                           digest, hostileAt)
    ck refusedGrant.len > 0
    ck refusedGrant.contains(unrepresentableFieldText())
    ckEq loadProjectTrust(w.userRoot).ledger.entries.len, 0
    ckEq scanOf(w).definitions.len, 0

    # 2. AND AN ORDINARY GRANT STILL WORKS, so the refusal above is about the
    #    field rather than about this call.
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    let granted = scanOf(w)
    ckEq granted.definitions.len, 1
    ckEq visualisedBy(w, granted), ExecutionNeedle

    # 3. THE TWO NON-RECORDS ARE DIFFERENT ANSWERS. Re-granting the decision
    #    already in force writes no row either, and it is a SUCCESS: a caller
    #    that could not tell it from the refusal above would have to treat one
    #    of the two wrongly, which is what one `bool` for both forced.
    ckEq grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest, At), ""
    ckEq loadProjectTrust(w.userRoot).ledger.entries.len, 1

    # 4. THE REVOCATION THAT FAILS OPEN, ON THE EFFECT. It is reported — and the
    #    definition is STILL LOADING and STILL RUNNING, which is the fact a "" a
    #    user reads as success would have hidden.
    let refusedRevoke = revokeExecutableTier(w.userRoot, w.root,
                                             dfkVisualiserCode, hostileAt)
    ck refusedRevoke.len > 0
    ck refusedRevoke.contains(unrepresentableFieldText())
    let stillRunning = scanOf(w)
    ckEq stillRunning.definitions.len, 1
    ckEq visualisedBy(w, stillRunning), ExecutionNeedle
    ckEq loadProjectTrust(w.userRoot).ledger.entries.len, 1

    # 5. THE TWIN, AND THE EFFECT THE WHOLE CASE IS ABOUT: a revocation that CAN
    #    be recorded stops the definition loading and stops the code running.
    ckEq revokeExecutableTier(w.userRoot, w.root, dfkVisualiserCode, At), ""
    let after = scanOf(w)
    ckEq after.definitions.len, 0
    ckRefusedWith after, ".codetracer/visualisers.wasm", etcRevoked
    ckNoNeedle after, visualisedBy(w, after)

# ---------------------------------------------------------------------------

suite "PLAT-13: the counted-assertion tally":

  test "the tally":
    check countedAssertions == ExpectedAssertions
