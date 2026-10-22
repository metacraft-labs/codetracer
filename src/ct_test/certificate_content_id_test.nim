## Content ids (``certificate_content_id``) against real git repositories.
##
## Every case builds a repository in a fresh temporary directory with the git
## on PATH and computes ids through the native host
## (``certificate_content_id_native``), so what is tested is the recipe as a
## producer runs it. Where an expected value is not git's own answer (a
## ``rev-parse HEAD^{tree}`` after the commit, or Content-Id §4.1's scoped
## recipe run verbatim through a shell), it is a known answer from
## ``test-certificates-spec/vectors/content/`` at revision
## d57e83746b16e7d7dc8562aabc7dec6754f4f62b, copied here as a constant with
## the case it comes from. That group is not WALKED by this suite: the
## conformance walker's pin predates it, and moving the pin is a later part
## of the work.
##
## MOCKING POLICY: none. The one seam the library has — ``ContentIdHost`` —
## is always the real native host; the incomplete-output case uses the same
## host with a deliberately tiny capture bound rather than a fake reply.

import std/[algorithm, os, osproc, random, sequtils, streams, strutils, times,
            tempfiles, unittest]

import certificate_content_id
import certificate_content_id_native

const
  EmptyTreeSha1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  EmptyTreeSha256 =
    "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"

# ---------------------------------------------------------------------------
# A git that sees only the repositories this suite makes
# ---------------------------------------------------------------------------

let suiteDir = createTempDir("ct-content-id-test-", "")

proc isolateGit() =
  ## The suite's own git calls and the library's (which inherit this
  ## process's environment) must not be redirected into some caller's
  ## repository — a hook exports GIT_DIR — or shaped by the developer's
  ## configuration (autocrlf, a default object format, commit signing).
  for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
              "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
              "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_LITERAL_PATHSPECS",
              "GIT_DEFAULT_HASH"]:
    delEnv(key)
  let emptyConfig = suiteDir / "gitconfig"
  writeFile(emptyConfig, "")
  putEnv("GIT_CONFIG_GLOBAL", emptyConfig)
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  for role in ["AUTHOR", "COMMITTER"]:
    putEnv("GIT_" & role & "_NAME", "Content Id Test")
    putEnv("GIT_" & role & "_EMAIL", "content-id@test.invalid")

isolateGit()

# The native host makes its temporary directories under the OS temporary
# directory. Pointing that at a directory of the suite's own (the suite's
# other temporary directories are made under `suiteDir` explicitly) lets every
# computation assert that it left nothing behind, failures included.
let hostTempDir = suiteDir / "host-tmp"
createDir(hostTempDir)
putEnv("TMPDIR", hostTempDir)

proc hostLitter(): seq[string] =
  for kind, path in walkDir(hostTempDir):
    result.add path.lastPathPart

proc runIn(dir: string; command: string; args: openArray[string]):
    tuple[code: int; output: string] =
  ## Run without a shell (no quoting hazards), stderr merged.
  let process = startProcess(command, workingDir = dir, args = args,
                             options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  let output = process.outputStream.readAll()
  (process.waitForExit(), output)

proc git(dir: string; args: varargs[string]): string =
  ## Run git and require success; the output without its line terminator.
  let (code, output) = runIn(dir, "git", args)
  doAssert code == 0, "git " & args.join(" ") & " failed in " & dir & ":\n" & output
  result = output
  result.stripLineEnd()

proc shell(dir, script: string): string =
  let (code, output) = runIn(dir, "/bin/sh", ["-c", script])
  doAssert code == 0, "sh -c " & script & " failed:\n" & output
  result = output
  result.stripLineEnd()

var repoCounter = 0
proc newRepo(objectFormat = "sha1"): string =
  inc repoCounter
  result = suiteDir / ("repo" & $repoCounter)
  createDir(result)
  discard git(result, "init", "-q", "--object-format=" & objectFormat, ".")

proc put(repo, path, content: string) =
  createDir(parentDir(repo / path))
  writeFile(repo / path, content)

proc commitAll(repo: string; message = "commit") =
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "-q", "-m", message)

let host = nativeContentIdHost()

proc indexBytes(repo: string): string =
  let index = repo / ".git/index"
  if fileExists(index): readFile(index) else: "<no index>"

proc w(repo: string; algorithm = caGitTreeSha1;
       scope: openArray[string] = []): ContentIdResult =
  ## Every working-tree computation in the suite goes through here, so every
  ## one of them, whatever its outcome, is checked to leave the user's index
  ## byte-identical and no temporary directory behind.
  let before = indexBytes(repo)
  result = computeContentId(host, repo, workingTreeState(), algorithm, scope)
  check indexBytes(repo) == before
  check hostLitter().len == 0

proc idOf(repo: string; algorithm = caGitTreeSha1;
          scope: openArray[string] = []): string =
  ## The working tree's id, which the case requires to be computable.
  let r = w(repo, algorithm, scope)
  doAssert r.outcome == cioComputed, "expected an id, got " & $r.outcome &
    ": " & r.reason
  r.id

proc scopedBySpecRecipe(repo, tree: string; scope: openArray[string]): string =
  ## Content-Id §4.1's scoped recipe, run VERBATIM through a shell pipe, so
  ## the library's equivalent formulation is checked against the text of the
  ## standard rather than against itself.
  let scratch = createTempDir("ct-content-id-recipe-", "", suiteDir)
  defer: removeDir(scratch)
  var quoted: seq[string]
  for path in scope:
    quoted.add quoteShell(path)
  shell(repo,
    "GIT_INDEX_FILE=" & scratch & "/scoped git read-tree --empty && " &
    "git --literal-pathspecs ls-tree -r -z --full-tree " & tree & " -- " &
    quoted.join(" ") & " | GIT_INDEX_FILE=" & scratch &
    "/scoped git update-index -z --index-info && " &
    "GIT_INDEX_FILE=" & scratch & "/scoped git write-tree")

proc treePaths(repo, tree: string): seq[string] =
  git(repo, "ls-tree", "-r", "--name-only", "--full-tree", tree).splitLines()
    .filterIt(it.len > 0)

proc digestOf(id: string): string = id[id.find(':') + 1 .. ^1]

proc conditionsOf(r: ContentIdResult): seq[NoContentIdCondition] =
  for state in r.states:
    result.add state.condition

proc pathsOf(r: ContentIdResult; condition: NoContentIdCondition): seq[string] =
  for state in r.states:
    if state.condition == condition:
      return state.paths

# ---------------------------------------------------------------------------

suite "content ids (Content-Id.md)":

  test "the content id is the tree a commit of the tested state records":
    let repo = newRepo()
    put(repo, "a.txt", "a1\n")
    put(repo, "b.txt", "b1\n")
    put(repo, "gone.txt", "gone\n")
    put(repo, "dir/c.txt", "c1\n")
    commitAll(repo)
    put(repo, "a.txt", "a2\n")                 # modified, unstaged
    put(repo, "b.txt", "b2\n")                 # partially staged:
    discard git(repo, "add", "b.txt")          #   b2 in the index,
    put(repo, "b.txt", "b3\n")                 #   b3 in the working tree
    removeFile(repo / "gone.txt")              # deleted, unstaged
    put(repo, "new.txt", "new\n")              # added, not yet committed
    discard git(repo, "add", "new.txt")
    put(repo, "scratch.txt", "scratch\n")      # untracked

    # `git status` refreshes the index it reads, so it runs BEFORE the bytes
    # are taken; from here on only the library touches the repository.
    let statusBefore = git(repo, "status", "--porcelain=v1")
    let refsBefore = git(repo, "for-each-ref") & git(repo, "rev-parse", "HEAD")
    let indexBefore = readFile(repo / ".git/index")

    let worktree = idOf(repo)

    # Only objects were written: the user's index is byte-identical (so the
    # recipe neither wrote it nor refreshed it), the working tree and every
    # ref are as they were.
    check readFile(repo / ".git/index") == indexBefore
    check git(repo, "status", "--porcelain=v1") == statusBefore
    check git(repo, "for-each-ref") & git(repo, "rev-parse", "HEAD") == refsBefore
    check readFile(repo / "b.txt") == "b3\n"

    # The index being committed is what `git write-tree` returns for it
    # (run on a copy here, because write-tree updates the index it reads).
    let staged = computeContentId(host, repo, indexState(), caGitTreeSha1)
    check staged.outcome == cioComputed
    let copy = suiteDir / "index-copy"
    copyFile(repo / ".git/index", copy)
    check staged.id == "git-tree-sha1:" &
      shell(repo, "GIT_INDEX_FILE=" & copy & " git write-tree")
    check readFile(repo / ".git/index") == indexBefore
    # With b.txt partially staged the two states differ, so a recipe that
    # read the user's index as the tested state would fail here.
    check staged.id != worktree

    discard git(repo, "commit", "-q", "-a", "-m", "the tested state")
    let head = git(repo, "rev-parse", "HEAD^{tree}")
    check worktree == "git-tree-sha1:" & head
    check computeContentId(host, repo, commitState("HEAD"), caGitTreeSha1).id ==
      worktree

  test "a scoped id keeps full paths and is not the subtree id":
    # The tree of test-certificates-spec vectors/content/scope-keeps-paths,
    # as a real working tree; its expected ids are the vector's.
    let repo = newRepo()
    put(repo, "src/db/schema.sql", "CREATE TABLE t (id INTEGER);\n")
    put(repo, "src/db/query.c", "int query(void);\n")
    put(repo, "lib/db/schema.sql", "CREATE TABLE t (id INTEGER);\n")
    put(repo, "lib/db/query.c", "int query(void);\n")
    put(repo, "src/dbx/extra.c", "int extra;\n")
    put(repo, "src/main.c", "int main(void);\n")
    put(repo, "README.md", "# example\n")
    discard git(repo, "add", "-A")

    let whole = idOf(repo)
    let srcDb = idOf(repo, scope = ["src/db"])
    let libDb = idOf(repo, scope = ["lib/db"])
    check whole == "git-tree-sha1:442d064fb66487bbe9030420a573b0bcb2149218"
    check srcDb == "git-tree-sha1:c4e13945e594dc4a56239682ec29f5206935d71f"
    check libDb == "git-tree-sha1:9292a4cf83a04b863e370f1da4e4335fcc3ffec0"
    check idOf(repo, scope = ["README.md", "src/db"]) ==
      "git-tree-sha1:54bd65c792c78a37a1696dedd3806cb6b9526054"
    check idOf(repo, caManifestV1Sha256, ["src/db"]) == "manifest-v1-sha256:" &
      "264ad79e2bcdfe3ef8c6f54a3b432898fca7b64f4e26cb02020cf73f95925a89"
    check idOf(repo, caManifestV1Sha256, ["lib/db"]) == "manifest-v1-sha256:" &
      "3d93d6fe7200e1d242f421dd61a163ed4d39e13111a75e0d063ef71bd7d2d008"

    # Identical directories, different scopes, different ids — and neither
    # is the tree object at the scoped directory, which has lost its path.
    check srcDb != libDb
    let wholeTree = digestOf(whole)
    let subtree = git(repo, "rev-parse", wholeTree & ":src/db")
    check digestOf(srcDb) != subtree
    check digestOf(libDb) != subtree
    check treePaths(repo, digestOf(srcDb)) == @["src/db/query.c", "src/db/schema.sql"]
    # `src/db` names a path component: `src/dbx` is not in it.
    check "src/dbx/extra.c" notin treePaths(repo, digestOf(srcDb))
    # The library's scoping agrees with §4.1's recipe run verbatim.
    check digestOf(srcDb) == scopedBySpecRecipe(repo, wholeTree, ["src/db"])
    check digestOf(idOf(repo, scope = ["README.md", "src/db"])) ==
      scopedBySpecRecipe(repo, wholeTree, ["README.md", "src/db"])

    # A commit's scoped id is computed the same way.
    commitAll(repo)
    check computeContentId(host, repo, commitState("HEAD"), caGitTreeSha1,
                           ["src/db"]).id == srcDb

  test "scoped pathspecs are literal":
    let repo = newRepo()
    put(repo, "a*", "star\n")
    put(repo, "ab", "neighbour\n")
    put(repo, "[x]", "bracket\n")
    put(repo, "x", "matched by [x] as a glob\n")
    discard git(repo, "add", "-A")
    let star = idOf(repo, scope = ["a*"])
    check treePaths(repo, digestOf(star)) == @["a*"]
    let bracket = idOf(repo, scope = ["[x]"])
    check treePaths(repo, digestOf(bracket)) == @["[x]"]
    # Every pattern-like or magic-looking name, a non-ASCII name, and a
    # directory whose name is a string prefix of its siblings', each agrees
    # with §4.1's recipe and selects exactly what it names.
    put(repo, "a?", "question\n")
    put(repo, ":foo", "leading colon\n")
    put(repo, "foo", "matched by :foo as magic\n")
    put(repo, ":(glob)x", "magic-looking\n")
    put(repo, "café.txt", "non-ascii\n")
    put(repo, "src/d/f.c", "d\n")
    put(repo, "src/d.c", "sibling file\n")
    put(repo, "src/db/g.c", "sibling directory\n")
    discard git(repo, "add", "-A")
    let whole = digestOf(idOf(repo))
    for (scope, paths) in [("a*", @["a*"]), ("a?", @["a?"]), ("[x]", @["[x]"]),
                           (":foo", @[":foo"]), (":(glob)x", @[":(glob)x"]),
                           ("café.txt", @["café.txt"]),
                           ("src/d", @["src/d/f.c"])]:
      let scoped = digestOf(idOf(repo, scope = [scope]))
      check git(repo, "-c", "core.quotePath=false", "ls-tree", "-r",
                "--name-only", "--full-tree", scoped).splitLines() == paths
      check scoped == scopedBySpecRecipe(repo, whole, [scope])
    check digestOf(idOf(repo, scope = ["a*", ":foo", "src/d"])) ==
      scopedBySpecRecipe(repo, whole, ["a*", ":foo", "src/d"])
    # Under an inherited GIT_GLOB_PATHSPECS the scope still means the file.
    putEnv("GIT_GLOB_PATHSPECS", "1")
    defer: delEnv("GIT_GLOB_PATHSPECS")
    check idOf(repo, scope = ["a*"]) == star

  test "an empty scope and an empty repository are the empty tree":
    # vectors/content/empty-scope: `src/d` is a string prefix of `src/db/a.c`
    # but not a path component of it, so it matches nothing.
    let repo = newRepo()
    put(repo, "src/db/a.c", "int a;\n")
    put(repo, "README.md", "# example\n")
    discard git(repo, "add", "-A")
    check idOf(repo, scope = ["src/d"]) == "git-tree-sha1:" & EmptyTreeSha1
    check idOf(repo, scope = ["missing"]) == "git-tree-sha1:" & EmptyTreeSha1
    check idOf(repo, scope = ["src/db"]) ==
      "git-tree-sha1:98ad9ba0593a06cf1523e881a0342c0c6dd93512"
    check idOf(repo, caManifestV1Sha256, ["src/d"]) ==
      "manifest-v1-sha256:" & EmptyManifestDigest

    # A repository with no index tracks nothing. Its untracked file is not
    # content, and computing W creates no index.
    let fresh = newRepo()
    put(fresh, "untracked.txt", "not tracked\n")
    check not fileExists(fresh / ".git/index")
    check idOf(fresh) == "git-tree-sha1:" & EmptyTreeSha1
    check computeContentId(host, fresh, indexState(), caGitTreeSha1).id ==
      "git-tree-sha1:" & EmptyTreeSha1
    check not fileExists(fresh / ".git/index")

    let fresh256 = newRepo("sha256")
    check idOf(fresh256, caGitTreeSha256) == "git-tree-sha256:" & EmptyTreeSha256
    put(fresh256, "src/db/a.c", "int a;\n")
    discard git(fresh256, "add", "-A")
    check idOf(fresh256, caGitTreeSha256, ["src/d"]) ==
      "git-tree-sha256:" & EmptyTreeSha256

  test "a SHA-256 repository yields git-tree-sha256":
    # The files of vectors/content/order-independent, whose sha256 tree the
    # sha256-object-format case pins.
    let repo = newRepo("sha256")
    put(repo, "src/main.c", "int run(void);\nint main(void) { return run(); }\n")
    put(repo, "README.md", "# example\n")
    put(repo, "src/lib/util.c", "int run(void) { return 0; }\n")
    put(repo, "docs/guide.md", "Run `make`, then `make test`.\n")
    put(repo, "Makefile", "all:\n\tcc -o example src/main.c src/lib/util.c\n")
    discard git(repo, "add", "-A")
    let algorithm = repositoryTreeAlgorithm(host, repo)
    check algorithm.ok and algorithm.algorithm == caGitTreeSha256
    let worktree = idOf(repo, caGitTreeSha256)
    check worktree == "git-tree-sha256:" &
      "e0d1c185ce7f1781f9a77658f8c5b7c5680206b736cbfa55d2c8cbc45b2fc58c"
    check idOf(repo, caGitTreeSha256, ["src"]) == "git-tree-sha256:" &
      "e7645212f0f66428129f0057888cf58bcfdbff79598b2a5a3418b49248c3d2b7"
    check digestOf(worktree).len == 64
    check parseContentId(worktree).form == cifWellFormed
    # manifest-v1 does not depend on the object format.
    check idOf(repo, caManifestV1Sha256) == "manifest-v1-sha256:" &
      "22fcef71cdff4fffd4498f6ae08ab6c1f3f3c8b632701c7f2970a3bdbb991391"
    commitAll(repo)
    check worktree == "git-tree-sha256:" & git(repo, "rev-parse", "HEAD^{tree}")

    # The other object format's algorithm cannot be computed: that is
    # "unverifiable" to a verifier, never a mismatch and never an id.
    let sha1There = w(repo, caGitTreeSha1)
    check sha1There.outcome == cioCannotCompute
    check sha1There.id == ""
    let sha1Repo = newRepo()
    put(sha1Repo, "f", "f\n")
    discard git(sha1Repo, "add", "f")
    check w(sha1Repo, caGitTreeSha256).outcome == cioCannotCompute

  test "manifest-v1 orders records by full-path bytes":
    # vectors/content/byte-order: `a.b` (2E) sorts before `a/b` (2F), which
    # a per-directory walk gets backwards.
    let entries = @[
      ManifestEntry(path: "a0", mode: "100644", content: "a0\n"),
      ManifestEntry(path: "a/b", mode: "100644", content: "a/b\n"),
      ManifestEntry(path: "a.b", mode: "100644", content: "a.b\n")]
    let records =
      "100644 " & sha256Hex("a.b\n") & " a.b\0" &
      "100644 " & sha256Hex("a/b\n") & " a/b\0" &
      "100644 " & sha256Hex("a0\n") & " a0\0"
    let digest = manifestV1Sha256(entries)
    check digest.outcome == cioComputed
    check digest.id == "manifest-v1-sha256:" & sha256Hex(records)
    check digest.id == "manifest-v1-sha256:" &
      "1627cc999756b257f236a240b7c107b2b5353f0911e7295a1bafd05da1cfd2ad"
    # Input order does not matter.
    check manifestV1Sha256(entries.reversed()).id == digest.id
    check manifestV1Sha256([entries[1], entries[0], entries[2]]).id == digest.id
    check manifestV1Sha256(entries, ["a"]).id == "manifest-v1-sha256:" &
      "d84f6f4e8defed0ef88cb60862c2dee0aafc7cbb3a0d19a5cd191c52a2212c84"
    check manifestV1Sha256(entries, ["missing"]).id ==
      "manifest-v1-sha256:" & EmptyManifestDigest
    check manifestV1Sha256(newSeq[ManifestEntry]()).digest == EmptyManifestDigest

    # vectors/content/modes: every mode, with a symlink's target and a
    # gitlink's revision as content.
    let modes = @[
      ManifestEntry(path: "bin/run.sh", mode: "100755",
                    content: "#!/bin/sh\nexec example \"$@\"\n"),
      ManifestEntry(path: "lib.c", mode: "100644", content: "int lib;\n"),
      ManifestEntry(path: "current", mode: "120000", content: "lib.c"),
      ManifestEntry(path: "vendor/dep", mode: "160000",
                    content: "3f2a9c1e5b7d4068a1c2e3f405162738495a6b7c")]
    check manifestV1Sha256(modes).id == "manifest-v1-sha256:" &
      "1f03dedc74d53af945a80403c4b4765fa204d0d3b2ed448a44fefed64ff1017a"

    # The same files in a real repository give the same manifest.
    let repo = newRepo()
    put(repo, "a0", "a0\n")
    put(repo, "a/b", "a/b\n")
    put(repo, "a.b", "a.b\n")
    discard git(repo, "add", "-A")
    check idOf(repo, caManifestV1Sha256) == digest.id
    check idOf(repo) == "git-tree-sha1:a681e65f5f2e61d66d1a912dcdaa16f594f03c15"

    # A NUL in a path cannot be represented: a state with no id, not a
    # digest over a truncated path.
    let nul = manifestV1Sha256(@[ManifestEntry(path: "a\0b", mode: "100644")])
    check nul.outcome == cioNoContentId
    check nul.conditionsOf == @[ncUnrepresentablePath]
    check manifestV1Sha256(entries & entries[0]).outcome == cioFailed
    check manifestV1Sha256(@[ManifestEntry(path: "x", mode: "100664")]).outcome ==
      cioFailed

  test "states with no content id are detected":
    # Unmerged entries.
    block:
      let repo = newRepo()
      put(repo, "f.txt", "base\n")
      commitAll(repo)
      let base = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
      discard git(repo, "checkout", "-q", "-b", "other")
      put(repo, "f.txt", "other\n")
      commitAll(repo)
      discard git(repo, "checkout", "-q", base)
      put(repo, "f.txt", "mine\n")
      commitAll(repo)
      let (code, _) = runIn(repo, "git", ["merge", "-q", "other"])
      check code != 0
      let indexBefore = readFile(repo / ".git/index")
      let conflicted = w(repo)
      check conflicted.outcome == cioNoContentId
      check conflicted.conditionsOf == @[ncUnmergedEntries]
      check conflicted.pathsOf(ncUnmergedEntries) == @["f.txt"]
      check conflicted.id == ""
      # `git add --update` on the real index would have resolved the
      # conflict; on the copy it never ran.
      check readFile(repo / ".git/index") == indexBefore
      let staged = computeContentId(host, repo, indexState(), caGitTreeSha1)
      check staged.outcome == cioNoContentId
      check staged.conditionsOf == @[ncUnmergedEntries]
      # Control: resolved, there is an id again.
      put(repo, "f.txt", "resolved\n")
      discard git(repo, "add", "f.txt")
      check w(repo).outcome == cioComputed

    # assume-unchanged: git would describe the indexed bytes while the tests
    # read the edited ones.
    block:
      let repo = newRepo()
      put(repo, "src/f.txt", "indexed\n")
      put(repo, "lib/g.txt", "g\n")
      commitAll(repo)
      discard git(repo, "update-index", "--assume-unchanged", "src/f.txt")
      put(repo, "src/f.txt", "edited\n")
      let hidden = w(repo)
      check hidden.outcome == cioNoContentId
      check hidden.conditionsOf == @[ncAssumeUnchanged]
      check hidden.pathsOf(ncAssumeUnchanged) == @["src/f.txt"]
      # Only within scope: a scope that excludes the entry has an id.
      check w(repo, scope = ["lib"]).outcome == cioComputed
      # Control.
      discard git(repo, "update-index", "--no-assume-unchanged", "src/f.txt")
      check idOf(repo) != "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}")

    # skip-worktree with the file present.
    block:
      let repo = newRepo()
      put(repo, "f.txt", "indexed\n")
      put(repo, "g.txt", "g\n")
      commitAll(repo)
      discard git(repo, "update-index", "--skip-worktree", "f.txt")
      put(repo, "f.txt", "edited\n")
      let hidden = w(repo)
      check hidden.outcome == cioNoContentId
      check hidden.conditionsOf == @[ncSkipWorktreePresent]
      check hidden.pathsOf(ncSkipWorktreePresent) == @["f.txt"]
      # Absent is how sparse checkout leaves such an entry, and then the
      # indexed content is what the id records: computable.
      removeFile(repo / "f.txt")
      check idOf(repo) == "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}")
      # Control: flag cleared, the file present again.
      put(repo, "f.txt", "edited\n")
      discard git(repo, "update-index", "--no-skip-worktree", "f.txt")
      check w(repo).outcome == cioComputed

    # A submodule with an uncommitted edit.
    block:
      let upstream = newRepo()
      put(upstream, "dep.c", "int dep;\n")
      commitAll(upstream)
      let repo = newRepo()
      put(repo, "main.c", "int main;\n")
      commitAll(repo)
      discard git(repo, "-c", "protocol.file.allow=always", "submodule", "add",
                  "-q", upstream, "vendor/dep")
      commitAll(repo, "add the submodule")
      let clean = idOf(repo)
      check clean == "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}")
      put(repo, "vendor/dep/dep.c", "int dep = 1;\n")
      let modified = w(repo)
      check modified.outcome == cioNoContentId
      check modified.conditionsOf == @[ncSubmoduleModified]
      check modified.pathsOf(ncSubmoduleModified) == @["vendor/dep"]
      check w(repo, scope = ["main.c"]).outcome == cioComputed
      # An untracked file inside it is not modified content.
      discard git(repo / "vendor/dep", "checkout", "--", "dep.c")
      put(repo, "vendor/dep/scratch.txt", "scratch\n")
      check idOf(repo) == clean
      # Control: the edit committed inside the submodule is a new gitlink,
      # which the id records.
      put(repo, "vendor/dep/dep.c", "int dep = 2;\n")
      discard git(repo / "vendor/dep", "commit", "-q", "-am", "edit")
      let moved = idOf(repo)
      check moved != clean
      check git(repo, "rev-parse", digestOf(moved) & ":vendor/dep") ==
        git(repo / "vendor/dep", "rev-parse", "HEAD")

  test "untracked files are outside the content":
    let repo = newRepo()
    put(repo, "tracked.txt", "tracked\n")
    commitAll(repo)
    let before = idOf(repo)
    put(repo, "scratch.txt", "scratch\n")
    put(repo, "new/dir/notes.md", "notes\n")
    check idOf(repo) == before
    check idOf(repo) == "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}")
    check git(repo, "status", "--porcelain=v1").contains("?? scratch.txt")

  test "the manifest's SHA-256 matches FIPS 180-4 and the system sha256sum":
    # The FIPS 180-4 examples (NIST CSRC "Example Values").
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("") == EmptyManifestDigest
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sha256Hex(repeat('a', 1_000_000)) ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    # Every length around the one- and two-block padding boundaries, and
    # every byte value, against an independent implementation.
    let scratch = createTempDir("ct-content-id-sha-", "", suiteDir)
    defer: removeDir(scratch)
    for length in [1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 256]:
      var data = newString(length)
      for i in 0 ..< length:
        data[i] = char((i * 37 + length) mod 256)
      writeFile(scratch / "data", data)
      let expected = shell(scratch, "sha256sum data").split(' ')[0]
      check sha256Hex(data) == expected
    # Large random inputs of random lengths, so a mistake that only shows on
    # long messages or particular byte patterns is caught too. The seed is
    # printed with a failure by the check's own message.
    var rng = initRand(0x5ca1ab1e)
    for round in 0 ..< 8:
      let length = rng.rand(64 * 1024 .. 3 * 1024 * 1024)
      var data = newString(length)
      for i in 0 ..< length:
        data[i] = char(rng.rand(255))
      writeFile(scratch / "data", data)
      let expected = shell(scratch, "sha256sum data").split(' ')[0]
      check sha256Hex(data) == expected

  test "a malformed content id is never repaired, and an unknown algorithm is not malformed":
    let full = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    let ok = parseContentId("git-tree-sha1:" & full)
    check ok.form == cifWellFormed
    check ok.algorithm == caGitTreeSha1 and ok.digest == full
    check parseContentId("git-tree-sha256:" & EmptyTreeSha256).form == cifWellFormed
    check parseContentId("manifest-v1-sha256:" & EmptyManifestDigest).form ==
      cifWellFormed
    for malformed in [
        "git-tree-sha1:" & full.toUpperAscii(),     # uppercase hex
        "git-tree-sha1:4B825dc642cb6eb9a060e54bf8d69288fbee4904",
        "git-tree-sha1:4b825dc",                    # abbreviated
        "git-tree-sha256:" & full,                  # sha1 length, sha256 algorithm
        full,                                       # no `:`
        ":" & full,                                 # empty algorithm
        "git-tree-sha1:",                           # empty digest
        "git-tree-sha1:4b825dc642cb6eb9a060e54bf8d69288fbee490g",  # non-hex
        "git-tree-sha1: " & full,
        "git-tree-sha1:" & full & "\n",
        "git-tree-sha1:abc:" & full]:               # split at the FIRST `:`
      let parsed = parseContentId(malformed)
      check parsed.form == cifMalformed
      check parsed.problem.len > 0
      # The verbatim text is kept; nothing was normalised.
      check parsed.text == malformed
    check parseContentId("git-tree-sha1:abc:" & full).algorithmName == "git-tree-sha1"
    # Unknown algorithms are well-formed: their digest length is unknowable.
    for unknown in ["git-tree-blake3:" & full, "Git-Tree-SHA1:" & full,
                    "future:ab"]:
      let parsed = parseContentId(unknown)
      check parsed.form == cifUnknownAlgorithm
      check parsed.problem == ""
    # ...but an unknown algorithm with a bad digest is still malformed.
    check parseContentId("future:AB").form == cifMalformed
    check parseContentId("future:").form == cifMalformed

  test "a state that cannot be computed is a failure, never an id":
    let notARepo = createTempDir("ct-content-id-plain-", "", suiteDir)
    defer: removeDir(notARepo)
    let outside = w(notARepo)
    check outside.outcome == cioFailed
    check outside.id == "" and outside.reason.len > 0

    let repo = newRepo()
    put(repo, "f.txt", "f\n")
    commitAll(repo)
    for revision in ["no-such-branch", "", "--all"]:
      let r = computeContentId(host, repo, commitState(revision), caGitTreeSha1)
      check r.outcome == cioFailed
      check r.id == ""
    for badScope in ["", "/f.txt", "./f.txt", "src/"]:
      let r = w(repo, scope = [badScope])
      check r.outcome == cioFailed
      check r.reason.len > 0

    # Output cut by the capture bound is never parsed as an answer: the same
    # native host, bounded to a few bytes, cannot read a tree id.
    let tiny = nativeContentIdHost(captureLimit = 8)
    let cut = computeContentId(tiny, repo, workingTreeState(), caGitTreeSha1)
    check cut.outcome == cioFailed
    check cut.id == ""

    # The dangerous truncation is the one that still parses: a listing cut
    # exactly at a record boundary looks like a complete shorter listing.
    # The native bridge keeps the TAIL of an over-long output, so here the
    # cut drops the first record — the one assume-unchanged entry, `a.txt` —
    # and a recipe reading what is left as the answer would issue an id for
    # the indexed bytes of a file the tests read edited. Every
    # `ls-files -s -v -z` record for `fNNN.txt` is 61 bytes
    # (`H 100644 <40 hex> 0<TAB>fNNN.txt<NUL>`), and the bound is a whole
    # number of them, above every other output the recipe reads (the
    # top-level path, the index path, a tree id).
    let listed = newRepo()
    let toplevelLength = git(listed, "rev-parse", "--path-format=absolute",
                             "--git-path", "index").len + 1
    let records = toplevelLength div 61 + 2
    for i in 0 ..< records:
      put(listed, "f" & align($i, 3, '0') & ".txt", "f\n")
    put(listed, "a.txt", "indexed\n")
    commitAll(listed)
    discard git(listed, "update-index", "--assume-unchanged", "a.txt")
    put(listed, "a.txt", "edited\n")
    check w(listed).conditionsOf == @[ncAssumeUnchanged]
    let boundary = nativeContentIdHost(captureLimit = records * 61)
    let prefix = computeContentId(boundary, listed, workingTreeState(), caGitTreeSha1)
    check prefix.outcome == cioFailed
    check prefix.id == ""

    # Computing from a subdirectory scopes by repository path, not by cwd.
    put(repo, "sub/x.txt", "x\n")
    discard git(repo, "add", "-A")
    check computeContentId(host, repo / "sub", workingTreeState(), caGitTreeSha1,
                           ["f.txt"]).id == idOf(repo, scope = ["f.txt"])

  test "a split index is neither modified nor added to":
    # Under core.splitIndex the user's index refers to a shared index in the
    # git directory, and git writes new shared indexes there whenever it
    # writes a split index. Computing an id must add none of them.
    let repo = newRepo()
    discard git(repo, "config", "core.splitIndex", "true")
    for i in 0 ..< 20:
      put(repo, "f" & $i & ".txt", $i & "\n")
    commitAll(repo)
    put(repo, "f0.txt", "edited\n")
    discard git(repo, "update-index", "--split-index")
    proc gitDirListing(): seq[string] =
      for kind, path in walkDir(repo / ".git"):
        result.add path.lastPathPart
      result.sort()
    let listingBefore = gitDirListing()
    check listingBefore.anyIt(it.startsWith("sharedindex."))
    let worktree = idOf(repo)
    check idOf(repo, scope = ["f1.txt"]).len > 0
    check computeContentId(host, repo, indexState(), caGitTreeSha1).outcome ==
      cioComputed
    check gitDirListing() == listingBefore
    discard git(repo, "commit", "-q", "-a", "-m", "the tested state")
    check worktree == "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}")

  # -------------------------------------------------------------------------
  # Stat data is never trusted for content (CTC-3b, 2026-10-10)
  #
  # The working-tree recipe runs `git add --update` in a COPY of the user's
  # index. git skips re-reading a file whose stat data (size, mtime, ctime,
  # inode, ...) matches its index entry, and re-reads one only when the entry
  # is "racily clean": its mtime not older than the INDEX FILE's own mtime
  # (https://git-scm.com/docs/racy-git). A copy has a fresh mtime, so a
  # same-size edit made in the same second as the last write of the real
  # index looked clean in the copy and the id named the OLD content. These
  # cases build each such state from explicit timestamps rather than by
  # racing the clock, so they fail deterministically against that recipe.
  #
  # `core.trustctime=false` (a real, documented setting, and git's advice on
  # filesystems with unreliable ctimes) takes the inode change time out of
  # git's stat comparison; the kernel sets ctime on every write and it
  # cannot be set back, so this is what makes "stat data unchanged"
  # reproducible from a test instead of from a one-second race.
  # -------------------------------------------------------------------------

  const StatTime = 1_700_000_000'i64
    ## An arbitrary, fixed mtime (2023-11-14) for the files and indexes below.

  proc setMtime(path: string; seconds: int64) =
    setLastModificationTime(path, fromUnix(seconds))

  proc treeWithBlob(repo, path, content: string): string =
    ## The id of HEAD's tree with ``path`` holding ``content``, built WITHOUT
    ## any stat data or working-tree read: the blob is hashed from the bytes,
    ## and a fresh index is assembled from HEAD's tree plus that blob. An
    ## oracle independent of the recipe under test.
    let blobFile = suiteDir / "oracle-blob"
    writeFile(blobFile, content)
    let blob = git(repo, "hash-object", "-w", "--no-filters", blobFile)
    let index = suiteDir / "oracle-index"
    removeFile(index)
    discard shell(repo, "GIT_INDEX_FILE=" & quoteShell(index) &
      " git read-tree HEAD && " &
      "GIT_INDEX_FILE=" & quoteShell(index) &
      " git update-index --cacheinfo 100644," & blob & "," & quoteShell(path))
    result = "git-tree-sha1:" &
      shell(repo, "GIT_INDEX_FILE=" & quoteShell(index) & " git write-tree")
    removeFile(index)

  proc statCleanRewrite(splitIndex: bool; indexMtime: int64): string =
    ## A repository whose committed ``a.txt`` ("aaaa\n", mtime ``StatTime``)
    ## has been rewritten in place to "bbbb\n" — same size, same inode, mtime
    ## set back to ``StatTime`` — with the real index's mtime ``indexMtime``.
    let repo = newRepo()
    discard git(repo, "config", "core.trustctime", "false")
    if splitIndex:
      discard git(repo, "config", "core.splitIndex", "true")
    put(repo, "a.txt", "aaaa\n")
    put(repo, "other.txt", "other\n")
    setMtime(repo / "a.txt", StatTime)
    commitAll(repo)
    setMtime(repo / ".git/index", indexMtime)
    writeFile(repo / "a.txt", "bbbb\n")         # in place: same inode
    setMtime(repo / "a.txt", StatTime)
    repo

  test "a same-size edit in the second of the last index write is seen":
    ## The real index's mtime EQUALS the edited file's: to git, reading the
    ## real index, the entry is racily clean and gets its content re-read —
    ## `git diff-files` (which writes no index) reports it. The copy must
    ## behave no worse.
    for split in [false, true]:
      checkpoint "core.splitIndex=" & $split
      let repo = statCleanRewrite(split, indexMtime = StatTime)
      check git(repo, "diff-files", "--name-only") == "a.txt"
      let expected = treeWithBlob(repo, "a.txt", "bbbb\n")
      check expected != "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}")
      check idOf(repo) == expected
      check idOf(repo, scope = ["a.txt"]) == idOf(repo, scope = ["a.txt"])
      check computeContentId(host, repo, workingTreeState(),
                             caManifestV1Sha256).outcome == cioComputed
      # The fixture is what it says: after the id the file is unchanged and
      # still reads as modified, and committing it yields the same tree.
      check readFile(repo / "a.txt") == "bbbb\n"
      discard git(repo, "commit", "-q", "-a", "-m", "the tested state")
      check "git-tree-sha1:" & git(repo, "rev-parse", "HEAD^{tree}") == expected

  test "a rewrite that restored every stat field is seen":
    ## The real index is NEWER than the file, as after any later `git add`:
    ## to git's stat check (and so to `git status`) the edit is invisible —
    ## exactly what an mtime-preserving tool (`cp -p`, `rsync -t`, `tar x`, a
    ## restore) leaves behind. Preserving the index's mtime on the copy would
    ## not see it either; a content id must, because a certificate names the
    ## content the tests ran on, not what the stat cache believes.
    let repo = statCleanRewrite(false, indexMtime = StatTime + 500)
    check git(repo, "diff-files", "--name-only") == ""   # git is fooled
    let expected = treeWithBlob(repo, "a.txt", "bbbb\n")
    check idOf(repo) == expected

  test "a filesystem monitor is not trusted for content":
    ## With `core.fsmonitor` set, git skips the stat check for entries the
    ## monitor last called unchanged. A monitor that lags (or, here, lies:
    ## it never reports a change) must not decide the content id.
    let repo = newRepo()
    put(repo, "a.txt", "aaaa\n")
    commitAll(repo)
    let hook = suiteDir / "silent-fsmonitor"
    writeFile(hook, "#!/bin/sh\nprintf 'token\\0'\n")
    setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})
    discard git(repo, "config", "core.fsmonitor", hook)
    discard git(repo, "config", "core.fsmonitorHookVersion", "2")
    discard git(repo, "update-index", "--fsmonitor")
    discard git(repo, "status", "--porcelain")       # records the token
    writeFile(repo / "a.txt", "a different size\n")
    check git(repo, "status", "--porcelain") == ""   # the monitor hides it
    check idOf(repo) == treeWithBlob(repo, "a.txt", "a different size\n")

  test "no temporary directory is left behind":
    check hostLitter().len == 0

# ---------------------------------------------------------------------------
# runResumable: the same recipe, with git answered later
# ---------------------------------------------------------------------------
#
# The Electron renderer cannot wait for git (Status-Bar.md, "A refresh never
# stalls the window"), so it drives the recipe through `runResumable` over an
# asynchronous git runner. These cases drive it over a DEFERRED runner — each
# call is queued, and the test answers it later, in order, by running it
# through the real native runner — and require exactly the synchronous
# recipe's answers. Not a mock of git: every reply is git's own; only the
# moment it is delivered is the test's, which is the property under test.

type
  DeferredGit = ref object
    queue: seq[tuple[call: GitCall; done: proc(reply: GitReply) {.closure, gcsafe.}]]
    delivered: int

  HostLedger = ref object
    ## What the file operations and git actually did, counted at the host.
    gitRuns, temps, copies, removals: int
    gitRunsAtRemoval: seq[int]

proc ledgerHost(ledger: HostLedger): ContentIdHost =
  ## The native host, counting. Every operation is the real one.
  let base = nativeContentIdHost()
  result = base
  result.git = proc(call: GitCall): GitReply {.closure, gcsafe.} =
    inc ledger.gitRuns
    base.git(call)
  result.makeTempDir = proc(): HostFileResult {.closure, gcsafe.} =
    inc ledger.temps
    base.makeTempDir()
  result.copyFile = proc(source, destination: string): HostFileResult
                        {.closure, gcsafe.} =
    inc ledger.copies
    base.copyFile(source, destination)
  result.removeDir = proc(path: string) {.closure, gcsafe.} =
    inc ledger.removals
    ledger.gitRunsAtRemoval.add ledger.gitRuns
    base.removeDir(path)

proc deferredHost(files: ContentIdHost; deferred: DeferredGit): AsyncContentIdHost =
  asyncContentIdHost(files,
    proc(call: GitCall; done: proc(reply: GitReply) {.closure, gcsafe.})
        {.closure, gcsafe.} =
      deferred.queue.add (call, done))

proc pump(deferred: DeferredGit; files: ContentIdHost) =
  ## Answer every queued call, oldest first, with the real git.
  while deferred.queue.len > 0:
    let (call, done) = deferred.queue[0]
    deferred.queue.delete(0)
    inc deferred.delivered
    done(files.git(call))

type ResumableRun = object
  result: ContentIdResult
  finishedInline: bool
  queuedAfterStart: int
  ledger: HostLedger
  deliveries: int

proc resumable(repo: string; state: ContentState; algorithm: ContentAlgorithm;
               scope: seq[string] = @[]): ResumableRun =
  let ledger = HostLedger()
  let files = ledgerHost(ledger)
  let deferred = DeferredGit()
  var finished = false
  var got: ContentIdResult
  runResumable(deferredHost(files, deferred),
    proc(h: ContentIdHost): ContentIdResult =
      computeContentId(h, repo, state, algorithm, scope),
    proc(value: ContentIdResult) =
      check not finished      # `done` runs exactly once
      finished = true
      got = value)
  result.finishedInline = finished
  result.queuedAfterStart = deferred.queue.len
  pump(deferred, files)
  check finished
  result.result = got
  result.ledger = ledger
  result.deliveries = deferred.delivered

proc sameResult(a, b: ContentIdResult): bool =
  a.outcome == b.outcome and a.id == b.id and a.reason == b.reason and
    a.states == b.states and
    (a.outcome == cioFailed or a.algorithm == b.algorithm)

suite "runResumable (the recipe over an asynchronous git)":

  test "every state gives the synchronous recipe's answer, git answered later":
    let repo = newRepo()
    put(repo, "a.txt", "alpha\n")
    put(repo, "src/b.nim", "echo 1\n")
    var binary = newString(256)
    for i in 0 ..< 256: binary[i] = char(i)
    put(repo, "blob.bin", binary & "\x80\xc0\xaf\xff")
    commitAll(repo)
    put(repo, "src/b.nim", "echo 2\n")
    discard git(repo, "add", "src/b.nim")
    put(repo, "a.txt", "alpha, edited\n")

    let assumed = newRepo()
    put(assumed, "hidden.txt", "one\n")
    commitAll(assumed)
    discard git(assumed, "update-index", "--assume-unchanged", "hidden.txt")
    put(assumed, "hidden.txt", "two\n")

    let outside = createTempDir("ct-content-id-outside-", "", suiteDir)

    let cases = @[
      ("W", repo, workingTreeState(), caGitTreeSha1, newSeq[string]()),
      ("H", repo, commitState("HEAD"), caGitTreeSha1, newSeq[string]()),
      ("S", repo, indexState(), caGitTreeSha1, newSeq[string]()),
      ("W scoped", repo, workingTreeState(), caGitTreeSha1, @["src"]),
      ("W sha256 in sha1", repo, workingTreeState(), caGitTreeSha256, newSeq[string]()),
      ("W manifest, binary blob", repo, workingTreeState(), caManifestV1Sha256,
       newSeq[string]()),
      ("H manifest, binary blob", repo, commitState("HEAD"), caManifestV1Sha256,
       newSeq[string]()),
      ("W assume-unchanged", assumed, workingTreeState(), caGitTreeSha1,
       newSeq[string]()),
      ("outside any repository", outside, workingTreeState(), caGitTreeSha1,
       newSeq[string]())]
    var kinds: seq[ContentIdOutcome]
    for (label, dir, state, algorithm, scope) in cases:
      checkpoint label
      let indexBefore = indexBytes(dir)
      let expected = computeContentId(host, dir, state, algorithm, scope)
      let run = resumable(dir, state, algorithm, scope)
      check sameResult(run.result, expected)
      if not sameResult(run.result, expected):
        checkpoint "resumable: " & $run.result.outcome & " " & run.result.id &
                   " " & run.result.reason
        checkpoint "sync:      " & $expected.outcome & " " & expected.id &
                   " " & expected.reason
      kinds.add run.result.outcome
      # No reply arrives inside the initial call: it launched exactly one git
      # call (the first) and returned without an answer.
      check not run.finishedInline
      check run.queuedAfterStart == 1
      # Each git call is run exactly once: replaying the journal never
      # re-runs git, so the count of real runs equals the deliveries.
      check run.ledger.gitRuns == run.deliveries
      # The index is copied at most once (once for W and S), a temporary
      # directory is made at most once, and it is removed exactly as often
      # as it was made — after the LAST git call, never mid-computation.
      check run.ledger.copies == (if state.kind in {cskWorkingTree, cskIndex} and
                                    run.result.outcome != cioFailed and
                                    algorithm != caGitTreeSha256: 1 else: 0)
      check run.ledger.temps <= 1
      check run.ledger.removals == run.ledger.temps
      if run.ledger.removals == 1:
        check run.ledger.gitRunsAtRemoval == @[run.ledger.gitRuns]
      check indexBytes(dir) == indexBefore
      check hostLitter().len == 0
    # The cases cover every outcome the indicator can meet.
    check cioComputed in kinds
    check cioCannotCompute in kinds
    check cioNoContentId in kinds
    check cioFailed in kinds
    # W, H and S really are three computations.
    let ids = [resumable(repo, workingTreeState(), caGitTreeSha1).result.id,
               resumable(repo, commitState("HEAD"), caGitTreeSha1).result.id,
               resumable(repo, indexState(), caGitTreeSha1).result.id]
    check ids[0] != ids[1] and ids[1] != ids[2] and ids[0] != ids[2]

  test "a runner that answers inside the call still gives one answer":
    ## A host may deliver a reply synchronously (a cached answer, a launch
    ## error reported inline). `runResumable` must neither re-enter the
    ## attempt nor lose the reply, and with every reply inline it finishes
    ## inside the call.
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    commitAll(repo)
    let native = host   # a local: a gcsafe closure cannot read a GC'd global
    let inline = asyncContentIdHost(native,
      proc(call: GitCall; done: proc(reply: GitReply) {.closure, gcsafe.})
          {.closure, gcsafe.} =
        done(native.git(call)))
    var answers = 0
    var got: ContentIdResult
    runResumable(inline,
      proc(h: ContentIdHost): ContentIdResult =
        computeContentId(h, repo, workingTreeState(), caGitTreeSha1),
      proc(value: ContentIdResult) =
        inc answers
        got = value)
    check answers == 1
    check sameResult(got, computeContentId(host, repo, workingTreeState(),
                                           caGitTreeSha1))
    check hostLitter().len == 0

  test "a computation that needs no git finishes inside the call":
    var answers = 0
    let deferred = DeferredGit()
    runResumable(deferredHost(host, deferred),
      proc(h: ContentIdHost): ContentIdResult =
        computeContentId(h, suiteDir, workingTreeState(), caGitTreeSha1,
                         ["/absolute"]),
      proc(value: ContentIdResult) =
        inc answers
        check value.outcome == cioFailed)
    check answers == 1
    check deferred.queue.len == 0

  test "a non-deterministic computation ends in a failure, not a hang":
    ## Replay is only sound for a deterministic computation. One that asks a
    ## DIFFERENT git command on its second attempt must be told so, and must
    ## finish — a hang would freeze the indicator forever.
    var attempts = 0
    var answers = 0
    var last: GitReply
    let deferred = DeferredGit()
    runResumable(deferredHost(host, deferred),
      proc(h: ContentIdHost): GitReply =
        inc attempts
        h.git(GitCall(argv: @["git", "--version", "--attempt-" & $attempts],
                      cwd: suiteDir)),
      proc(value: GitReply) =
        inc answers
        last = value)
    check answers == 0
    check deferred.queue.len == 1
    pump(deferred, host)
    check answers == 1
    check attempts == 2
    check last.exitCode < 0
    check "non-deterministic" in last.stderr

  test "a late or repeated reply is ignored":
    var answers = 0
    var saved: seq[proc(reply: GitReply) {.closure, gcsafe.}]
    let capturing = asyncContentIdHost(host,
      proc(call: GitCall; done: proc(reply: GitReply) {.closure, gcsafe.})
          {.closure, gcsafe.} =
        saved.add done)
    runResumable(capturing,
      proc(h: ContentIdHost): int =
        h.git(GitCall(argv: @["git", "--version"], cwd: suiteDir)).exitCode,
      proc(value: int) =
        inc answers
        check value == 0)
    check saved.len == 1
    saved[0](GitReply(exitCode: 0, complete: true))
    saved[0](GitReply(exitCode: 7, complete: true))
    check answers == 1

  test "a manifest's blobs are one operation: the attempts do not grow with the tree":
    ## Journaled one `git cat-file` at a time, a manifest over F files would
    ## re-run the recipe F times, each re-reading every blob before it — main-
    ## thread work quadratic in the tree (measured: 48 s and 326 ms tasks
    ## over 400 files under node). The blobs are one journaled operation
    ## instead, so a tree of 3 files and one of 60 take the same number of
    ## attempts, and every blob is still read exactly once, by real git.
    proc attemptsFor(repo: string; state: ContentState):
        tuple[attempts: int; run: ResumableRun] =
      let ledger = HostLedger()
      let files = ledgerHost(ledger)
      let deferred = DeferredGit()
      var attempts = 0
      var got: ContentIdResult
      var answers = 0
      runResumable(deferredHost(files, deferred),
        proc(h: ContentIdHost): ContentIdResult =
          inc attempts
          computeContentId(h, repo, state, caManifestV1Sha256),
        proc(value: ContentIdResult) =
          inc answers
          got = value)
      pump(deferred, files)
      check answers == 1
      result.attempts = attempts
      result.run = ResumableRun(result: got, ledger: ledger,
                                deliveries: deferred.delivered)

    let small = newRepo()
    for i in 0 ..< 3:
      put(small, "f" & $i & ".txt", "small " & $i & "\n")
    commitAll(small)
    let large = newRepo()
    for i in 0 ..< 60:
      put(large, "dir" & $(i mod 4) & "/f" & $i & ".txt", "large " & $i & "\n")
    commitAll(large)
    put(large, "dir0/f0.txt", "edited\n")

    for state in [workingTreeState(), commitState("HEAD")]:
      checkpoint $state.kind
      let a = attemptsFor(small, state)
      let b = attemptsFor(large, state)
      check sameResult(a.run.result, computeContentId(host, small, state,
                                                      caManifestV1Sha256))
      check sameResult(b.run.result, computeContentId(host, large, state,
                                                      caManifestV1Sha256))
      check b.run.result.outcome == cioComputed
      check a.attempts == b.attempts
      # Each blob read once: 60 of them, plus the recipe's own calls, all
      # delivered by the deferred runner and run once by the real git.
      check b.run.ledger.gitRuns == b.run.deliveries
      check b.run.deliveries - a.run.deliveries == 60 - 3
      check b.run.ledger.removals == b.run.ledger.temps
      check hostLitter().len == 0

  test "a manifest whose every blob answers inline gives the synchronous answer":
    ## The blob reader handles a reply delivered inside the call in a loop,
    ## not by recursion, so the stack does not grow with the tree.
    let repo = newRepo()
    for i in 0 ..< 500:
      put(repo, "many/f" & $i & ".txt", $i & "\n")
    commitAll(repo)
    let native = host
    let inline = asyncContentIdHost(native,
      proc(call: GitCall; done: proc(reply: GitReply) {.closure, gcsafe.})
          {.closure, gcsafe.} =
        done(native.git(call)))
    var answers = 0
    var got: ContentIdResult
    runResumable(inline,
      proc(h: ContentIdHost): ContentIdResult =
        computeContentId(h, repo, commitState("HEAD"), caManifestV1Sha256),
      proc(value: ContentIdResult) =
        inc answers
        got = value)
    check answers == 1
    check got.outcome == cioComputed
    check sameResult(got, computeContentId(host, repo, commitState("HEAD"),
                                           caManifestV1Sha256))

  test "a blob that cannot be read fails the manifest, as the synchronous loop does":
    ## The driver folds each reply with the recipe's own `stepOf`, so a
    ## failed `git cat-file` is the same failure on both paths, and the
    ## computation finishes rather than waiting.
    let repo = newRepo()
    put(repo, "a.txt", "a\n")
    put(repo, "b.txt", "b\n")
    commitAll(repo)
    let native = host
    proc failingBlobs(call: GitCall): GitReply =
      if "cat-file" in call.argv:
        GitReply(exitCode: 128, stderr: "fatal: planted", complete: true)
      else:
        native.git(call)
    var syncHost = host
    syncHost.git = proc(call: GitCall): GitReply {.closure, gcsafe.} =
      {.cast(gcsafe).}: failingBlobs(call)
    let expected = computeContentId(syncHost, repo, commitState("HEAD"),
                                    caManifestV1Sha256)
    check expected.outcome == cioFailed
    check "planted" in expected.reason
    let deferred = DeferredGit()
    var answers = 0
    var got: ContentIdResult
    runResumable(deferredHost(host, deferred),
      proc(h: ContentIdHost): ContentIdResult =
        computeContentId(h, repo, commitState("HEAD"), caManifestV1Sha256),
      proc(value: ContentIdResult) =
        inc answers
        got = value)
    pump(deferred, syncHost)
    check answers == 1
    check sameResult(got, expected)
    check hostLitter().len == 0

removeDir(suiteDir)
