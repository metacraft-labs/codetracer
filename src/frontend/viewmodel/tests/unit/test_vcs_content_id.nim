## test_vcs_content_id.nim — SB-2a. **The content facts W, H and S, and the
## local certificate store's roots, through the platform facade, on the native
## host.**
##
## Status-Bar.md ("Requirements") makes the certificate indicator decide on
## three content ids: W (the working tree, computed in a temporary index), H
## (`HEAD^{tree}`) and S (the user's index, via `git write-tree`). They reach
## the indicator through `VcsFacade.contentId`; the store it reads them against
## is found through `FileSystemFacade.certificateStoreRoots`
## (test-certificates-spec Transport §2.1). This suite drives both on the
## NATIVE instantiation — `desktop_native`'s platform, and `nativeVcs`, the
## facade the terminal's and GPUI's hosts use — against real repositories
## built with the system git:
##
##   1. W, H and S equal what git itself answers: W after `git commit -a` is
##      `HEAD^{tree}`, S is `git write-tree` (run on a copy of the index, so
##      the expectation does not disturb the state it describes), and W and S
##      differ for a partially staged file;
##   2. the call changes no ref, not the index file (byte for byte), not
##      `git status`;
##   3. each Content-Id §3 state comes back as its condition with its paths —
##      never as an id, and in particular never as H;
##   4. an algorithm the host cannot compute here is "cannot compute", a
##      failure to compute is an error value, and no git at all is "cannot
##      compute";
##   5. a host whose profile lacks `capVcsRead` is refused, naming it;
##   6. the store roots follow Transport §2.1, and a root is readable through
##      the existing `fs` operations.
##
## No mocks: the system git, real files, the shipped native instantiation.
## Every temporary directory is removed at the end of the suite, explicitly.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../platform/platform
import ../../host/native_vcs
import ../../host/desktop_native
import ../../../../ct_test/certificate_store_roots

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# ---------------------------------------------------------------------------
# A git that sees only the repositories this suite makes
# ---------------------------------------------------------------------------

let suiteDir = createTempDir("ct-vcs-content-id-", "")

for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR",
            "GIT_NAMESPACE", "GIT_LITERAL_PATHSPECS", "GIT_DEFAULT_HASH"]:
  delEnv(key)
writeFile(suiteDir / "gitconfig", "")
putEnv("GIT_CONFIG_GLOBAL", suiteDir / "gitconfig")
putEnv("GIT_CONFIG_NOSYSTEM", "1")
for role in ["AUTHOR", "COMMITTER"]:
  putEnv("GIT_" & role & "_NAME", "Content Facts Test")
  putEnv("GIT_" & role & "_EMAIL", "content-facts@test.invalid")

proc runIn(dir, command: string; args: openArray[string];
           env: openArray[(string, string)] = []): tuple[code: int; output: string] =
  var environment: StringTableRef = nil
  if env.len > 0:
    environment = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      environment[key] = value
    for (key, value) in env:
      environment[key] = value
  let process = startProcess(command, workingDir = dir, args = args,
                             env = environment,
                             options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  let output = process.outputStream.readAll()
  (process.waitForExit(), output)

proc git(dir: string; args: varargs[string]): string =
  let (code, output) = runIn(dir, "git", args)
  doAssert code == 0, "git " & args.join(" ") & " failed in " & dir & ":\n" & output
  output.strip(leading = false)

var repoCounter = 0
proc newRepo(): string =
  inc repoCounter
  result = suiteDir / ("repo" & $repoCounter)
  createDir(result)
  discard git(result, "init", "-q", "--object-format=sha1", ".")

proc put(repo, path, content: string) =
  createDir(parentDir(repo / path))
  writeFile(repo / path, content)

proc commitAll(repo: string; message = "commit") =
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "-q", "-m", message)

proc writeTreeOnCopy(repo: string): string =
  ## `git write-tree` over a COPY of the user's index: what S must equal,
  ## without the expectation itself storing a cache-tree into the index the
  ## suite is about to checksum.
  let copy = suiteDir / ("index-copy-" & $repoCounter)
  copyFile(repo / ".git/index", copy)
  let (code, output) = runIn(repo, "git", ["write-tree"],
                             env = [("GIT_INDEX_FILE", copy)])
  removeFile(copy)
  doAssert code == 0, output
  output.strip()

type RepoSnapshot = object
  refs, head, index, status: string

proc snapshot(repo: string): RepoSnapshot =
  ## Everything the call must leave alone: every ref, what HEAD points at,
  ## the index file byte for byte, and the working tree as status sees it.
  RepoSnapshot(
    refs: git(repo, "for-each-ref", "--format=%(refname) %(objectname)"),
    head: readFile(repo / ".git/HEAD"),
    index: (if fileExists(repo / ".git/index"): readFile(repo / ".git/index")
            else: "<no index>"),
    # GIT_OPTIONAL_LOCKS=0 so that the snapshot's own `git status` does not
    # refresh the index it is about to compare.
    status: runIn(repo, "git", ["status", "--porcelain=v1",
                                "--untracked-files=all"],
                  env = [("GIT_OPTIONAL_LOCKS", "0")]).output)

# The facades under test.
let desktop = newDesktopNativePlatform()
let tuiVcs = nativeVcs(NativeVcsProfile)

proc contentOf(vcs: VcsFacade; repo: string; state: VcsBlobSource;
               algorithm = "git-tree-sha1";
               scope: seq[string] = @[]): PlatformOutcome[VcsContentId] =
  awaitSync(vcs.contentId(repo, state, algorithm, scope))

proc idOf(vcs: VcsFacade; repo: string; state: VcsBlobSource;
          algorithm = "git-tree-sha1"; scope: seq[string] = @[]): string =
  let outcome = contentOf(vcs, repo, state, algorithm, scope)
  doAssert outcome.ok, "contentId failed: " & $outcome.error
  doAssert outcome.value.kind == vcikComputed,
    "contentId did not compute: " & outcome.value.reason
  outcome.value.id

# ---------------------------------------------------------------------------

suite "the native host's W, H and S equal git's own":

  test "after `git commit -a`, W = H = S, and each is git's tree":
    let repo = newRepo()
    put(repo, "a.txt", "one\n")
    put(repo, "src/b.nim", "echo 1\n")
    commitAll(repo)
    put(repo, "a.txt", "two\n")
    discard git(repo, "commit", "-q", "-a", "-m", "second")
    let head = git(repo, "rev-parse", "HEAD^{tree}")
    for vcs in [desktop.vcs, tuiVcs]:
      ck idOf(vcs, repo, vbsWorkingTree) == "git-tree-sha1:" & head
      ck idOf(vcs, repo, vbsHead) == "git-tree-sha1:" & head
      ck idOf(vcs, repo, vbsIndex) == "git-tree-sha1:" & writeTreeOnCopy(repo)
      ck idOf(vcs, repo, vbsIndex) == "git-tree-sha1:" & head

  test "a partially staged file: W, S and H are three different trees":
    let repo = newRepo()
    put(repo, "f.txt", "base\n")
    put(repo, "g.txt", "untouched\n")
    commitAll(repo)
    put(repo, "f.txt", "staged\n")
    discard git(repo, "add", "f.txt")
    put(repo, "f.txt", "staged\nand then edited\n")
    put(repo, "untracked.txt", "not part of any state\n")
    let before = snapshot(repo)

    let w = idOf(desktop.vcs, repo, vbsWorkingTree)
    let s = idOf(desktop.vcs, repo, vbsIndex)
    let h = idOf(desktop.vcs, repo, vbsHead)
    ck s == "git-tree-sha1:" & writeTreeOnCopy(repo)
    ck h == "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}")
    ck w != s
    ck w != h
    ck s != h

    # W is what `git commit -a` would record: prove it on a clone of the
    # state rather than by restating the recipe.
    let clone = suiteDir / "clone-of-partial"
    discard git(suiteDir, "clone", "-q", repo, clone)
    copyFile(repo / "f.txt", clone / "f.txt")
    discard git(clone, "commit", "-q", "-a", "-m", "as tested")
    ck w == "git-tree-sha1:" & git(clone, "rev-parse", "HEAD^{tree}")
    removeDir(clone)

    # Nothing the user can see moved: refs, HEAD, the index file byte for
    # byte, and status — the untracked file included.
    let after = snapshot(repo)
    ck after.refs == before.refs
    ck after.head == before.head
    ck after.index == before.index
    ck after.status == before.status
    ck "untracked.txt" in after.status

  test "a scope selects entries at their full paths":
    let repo = newRepo()
    put(repo, "src/x.nim", "x\n")
    put(repo, "docs/y.md", "y\n")
    commitAll(repo)
    let scoped = idOf(desktop.vcs, repo, vbsWorkingTree, scope = @["src"])
    ck scoped != idOf(desktop.vcs, repo, vbsWorkingTree)
    # The scoped tree still holds `src/x.nim` under `src/`, and nothing else.
    let tree = scoped["git-tree-sha1:".len .. ^1]
    ck git(repo, "ls-tree", "-r", "--name-only", tree) == "src/x.nim"
    # An edit outside the scope does not move it; one inside does.
    put(repo, "docs/y.md", "changed\n")
    ck idOf(desktop.vcs, repo, vbsWorkingTree, scope = @["src"]) == scoped
    put(repo, "src/x.nim", "changed\n")
    ck idOf(desktop.vcs, repo, vbsWorkingTree, scope = @["src"]) != scoped

  test "manifest-v1-sha256 is computed too, and names its algorithm":
    let repo = newRepo()
    put(repo, "m.txt", "manifest\n")
    commitAll(repo)
    let outcome = contentOf(desktop.vcs, repo, vbsHead, "manifest-v1-sha256")
    ck outcome.ok
    ck outcome.value.kind == vcikComputed
    ck outcome.value.id.startsWith("manifest-v1-sha256:")
    ck outcome.value.id.len == "manifest-v1-sha256:".len + 64
    ck outcome.value.algorithm == "manifest-v1-sha256"

suite "a state with no content id is a reason, not an id":

  proc expectCondition(repo: string; condition: NoContentIdCondition;
                       paths: seq[string]) =
    let outcome = contentOf(desktop.vcs, repo, vbsWorkingTree)
    ck outcome.ok
    ck outcome.value.kind == vcikNoContentId
    ck outcome.value.id == ""
    ck outcome.value.conditions.len == 1
    if outcome.value.conditions.len == 1:
      ck outcome.value.conditions[0].condition == condition
      ck outcome.value.conditions[0].paths == paths
    ck outcome.value.reason.len > 0
    # H is computable in every one of these states, and W must not borrow it.
    let head = contentOf(desktop.vcs, repo, vbsHead)
    ck head.ok and head.value.kind == vcikComputed
    ck outcome.value.id != head.value.id

  test "unmerged entries":
    let repo = newRepo()
    put(repo, "c.txt", "base\n")
    commitAll(repo)
    discard git(repo, "checkout", "-q", "-b", "other")
    put(repo, "c.txt", "other\n")
    commitAll(repo)
    discard git(repo, "checkout", "-q", "-")
    put(repo, "c.txt", "mine\n")
    commitAll(repo)
    let (code, _) = runIn(repo, "git", ["merge", "-q", "other"])
    ck code != 0
    let before = snapshot(repo)
    expectCondition(repo, ncUnmergedEntries, @["c.txt"])
    let after = snapshot(repo)
    ck after.index == before.index
    ck after.refs == before.refs
    # S has no content id either: an unmerged index cannot be committed.
    let staged = contentOf(desktop.vcs, repo, vbsIndex)
    ck staged.ok and staged.value.kind == vcikNoContentId

  test "an assume-unchanged entry":
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    put(repo, "b.txt", "b\n")
    commitAll(repo)
    discard git(repo, "update-index", "--assume-unchanged", "b.txt")
    expectCondition(repo, ncAssumeUnchanged, @["b.txt"])

  test "a skip-worktree entry whose file is present":
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    put(repo, "s.txt", "s\n")
    commitAll(repo)
    discard git(repo, "update-index", "--skip-worktree", "s.txt")
    expectCondition(repo, ncSkipWorktreePresent, @["s.txt"])

  test "a submodule with modified content":
    let inner = newRepo()
    put(inner, "inner.txt", "inner\n")
    commitAll(inner)
    let repo = newRepo()
    put(repo, "top.txt", "top\n")
    commitAll(repo)
    discard git(repo, "-c", "protocol.file.allow=always", "submodule", "add",
                "-q", inner, "sub")
    discard git(repo, "commit", "-q", "-m", "add submodule")
    put(repo, "sub/inner.txt", "modified inside the submodule\n")
    expectCondition(repo, ncSubmoduleModified, @["sub"])

suite "what is not an id is never an id":

  test "an algorithm in the other object format is cannot-compute":
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    commitAll(repo)
    let outcome = contentOf(desktop.vcs, repo, vbsWorkingTree, "git-tree-sha256")
    ck outcome.ok
    ck outcome.value.kind == vcikCannotCompute
    ck outcome.value.id == ""
    ck outcome.value.algorithm == "git-tree-sha256"

  test "an algorithm this host does not implement is cannot-compute":
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    commitAll(repo)
    let outcome = contentOf(desktop.vcs, repo, vbsHead, "blake3-tree")
    ck outcome.ok
    ck outcome.value.kind == vcikCannotCompute
    ck "blake3-tree" in outcome.value.reason

  test "outside a repository is a failure value, not an id":
    let outside = suiteDir / "not-a-repository"
    createDir(outside)
    for state in [vbsWorkingTree, vbsIndex, vbsHead]:
      let outcome = contentOf(desktop.vcs, outside, state)
      ck not outcome.ok
      if not outcome.ok:
        ck outcome.error.kind == pkFailed
        ck "not inside a git working tree" in outcome.error.message

  test "with no git on this host the answer is cannot-compute":
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    commitAll(repo)
    let savedPath = getEnv("PATH")
    let emptyBin = suiteDir / "empty-bin"
    createDir(emptyBin)
    putEnv("PATH", emptyBin)
    let outcome = contentOf(desktop.vcs, repo, vbsWorkingTree)
    putEnv("PATH", savedPath)
    ck outcome.ok
    if outcome.ok:
      ck outcome.value.kind == vcikCannotCompute
      ck "git cannot be run" in outcome.value.reason

suite "contentId requires capVcsRead":

  test "a host holding capVcsRead computes; one without it is refused, by name":
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    commitAll(repo)
    let readOnly = nativeVcs(NativeVcsProfile.withCapabilities(
      {capVcsRead}, @[]))
    let granted = contentOf(readOnly, repo, vbsHead)
    ck granted.ok and granted.value.kind == vcikComputed

    # Everything BUT capVcsRead — write and remote included — is not enough.
    let withoutRead = nativeVcs(NativeVcsProfile.withCapabilities(
      {capVcsWrite, capVcsRemote}, @[]))
    let refused = contentOf(withoutRead, repo, vbsHead)
    ck not refused.ok
    if not refused.ok:
      ck refused.error.kind == pkNotSupported
      ck "capVcsRead" in refused.error.message
      ck "vcs.contentId" in refused.error.message

suite "the host resolves the local certificate store's roots":

  proc roots(): CertificateStoreRoots =
    let outcome = awaitSync(desktop.fs.certificateStoreRoots())
    doAssert outcome.ok, $outcome.error
    outcome.value

  let saved = @[("TEST_CERTIFICATES_DIR", getEnv("TEST_CERTIFICATES_DIR")),
                ("TEST_CERTIFICATES_SYSTEM_DIR", getEnv("TEST_CERTIFICATES_SYSTEM_DIR")),
                ("XDG_STATE_HOME", getEnv("XDG_STATE_HOME")),
                ("HOME", getEnv("HOME"))]
  proc restore() =
    for (key, value) in saved:
      if value.len == 0: delEnv(key) else: putEnv(key, value)

  test "TEST_CERTIFICATES_DIR wins, and is read on every call":
    putEnv("TEST_CERTIFICATES_DIR", suiteDir / "explicit-store")
    putEnv("XDG_STATE_HOME", suiteDir / "state")
    ck roots().available
    ck roots().user == suiteDir / "explicit-store"
    putEnv("TEST_CERTIFICATES_DIR", suiteDir / "moved-store")
    ck roots().user == suiteDir / "moved-store"
    restore()

  test "then XDG_STATE_HOME, then ~/.local/state on Linux":
    when defined(linux):
      delEnv("TEST_CERTIFICATES_DIR")
      putEnv("XDG_STATE_HOME", suiteDir / "state")
      ck roots().user == suiteDir / "state" / "test-certificates"
      delEnv("XDG_STATE_HOME")
      putEnv("HOME", suiteDir / "home")
      ck roots().user == suiteDir / "home" / ".local/state/test-certificates"
      restore()

  test "a relative value is ignored, and says so":
    when defined(linux):
      putEnv("TEST_CERTIFICATES_DIR", "relative/store")
      putEnv("XDG_STATE_HOME", "relative-state")
      putEnv("HOME", suiteDir / "home")
      let r = roots()
      ck r.user == suiteDir / "home" / ".local/state/test-certificates"
      var mentioned = 0
      for problem in r.problems:
        if "TEST_CERTIFICATES_DIR" in problem and "ignored" in problem: inc mentioned
        if "XDG_STATE_HOME" in problem and "ignored" in problem: inc mentioned
      ck mentioned == 2
      restore()

  test "the system root is the per-uid partition":
    when defined(linux):
      # The uid as `id -u` reports it: the expectation comes from outside the
      # code under test, which reads `getuid()` itself.
      let idOutput = runIn(suiteDir, "id", ["-u"]).output.strip()
      delEnv("TEST_CERTIFICATES_SYSTEM_DIR")
      ck roots().system == "/var/lib/test-certificates/" & idOutput
      putEnv("TEST_CERTIFICATES_SYSTEM_DIR", suiteDir / "system")
      ck roots().system == suiteDir / "system" / idOutput
      putEnv("TEST_CERTIFICATES_SYSTEM_DIR", "relative-system")
      ck roots().system == "/var/lib/test-certificates/" & idOutput
      restore()

  test "a root is readable through the existing fs operations":
    let store = suiteDir / "readable-store"
    createDir(store / "git-tree-sha1" / "4b")
    writeFile(store / "git-tree-sha1" / "4b" / "record.toml", "x = 1\n")
    putEnv("TEST_CERTIFICATES_DIR", store)
    let root = roots().user
    let listing = awaitSync(desktop.fs.listDir(root / "git-tree-sha1" / "4b"))
    ck listing.ok
    ck listing.ok and listing.value.len == 1 and
       listing.value[0].name == "record.toml"
    let missing = awaitSync(desktop.fs.listDir(root / "no-such-algorithm"))
    ck not missing.ok and missing.error.kind == pkNotFound
    restore()

  test "the macOS and Windows tables, through the one resolver":
    # The resolver is pure, so the other platforms' rows of Transport §2.1
    # are checked here over an injected environment rather than not at all.
    proc envOf(pairs: seq[(string, string)]): StoreEnvironment =
      result = proc(name: string): string =
        for (key, value) in pairs:
          if key == name: return value
        ""
    let mac = resolveCertificateStoreRoots(srpMacos,
      envOf(@[("HOME", "/Users/u"), ("XDG_STATE_HOME", "/ignored/on/macos")]),
      "501")
    ck mac.user == "/Users/u/Library/Application Support/test-certificates"
    ck mac.system == "/Library/Application Support/test-certificates/501"
    let sid = "S-1-5-21-1-2-3-1001"
    let win = resolveCertificateStoreRoots(srpWindows,
      envOf(@[("LOCALAPPDATA", r"C:\Users\u\AppData\Local"),
              ("ProgramData", r"C:\ProgramData"),
              ("TEST_CERTIFICATES_DIR", r"C:relative")]), sid)
    ck win.user == r"C:\Users\u\AppData\Local\test-certificates"
    ck win.system == r"C:\ProgramData\test-certificates\" & sid
    ck win.problems.len == 1 and "TEST_CERTIFICATES_DIR" in win.problems[0]
    # With no SID (what every host answers on Windows today) the system root
    # is left unresolved and the reason recorded, never guessed.
    let noSid = resolveCertificateStoreRoots(srpWindows,
      envOf(@[("LOCALAPPDATA", r"C:\L"), ("ProgramData", r"C:\ProgramData")]), "")
    ck noSid.system == ""
    ck noSid.user == r"C:\L\test-certificates"
    var named = false
    for problem in noSid.problems:
      if "SID" in problem: named = true
    ck named

suite "the tally":
  test "every assertion ran, and the suite cleans up after itself":
    removeDir(suiteDir)
    ck not dirExists(suiteDir)
    ck CHECKS >= 80
