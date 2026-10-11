## CT-Test-Certificates CTC-3i: `ct test run` from the refc `ct` hands the run
## to the ORC `ct-test` installed beside it.
##
## The `ct` binary is built --mm:refc, under which the parallel runner is
## unsafe, so it never runs tests itself: `src/ct/codetracer.nim` execs the
## `ct-test` that `src/ct_test/ct_test_delegate.nim` finds — beside the real
## path of the running `ct`, then the install's `tools/` directory, then PATH —
## and refuses, naming those places, when there is none.
##
## NO MOCKS. Every case runs the real `ct` and the real `ct-test` from a
## development build, copied or linked into scratch layouts that look like an
## install, against real git workspaces. The tests that pass and fail are the
## Go fixture the provider suites use (`src/ct_test/fixtures/go_test_project`),
## so `go` must be on PATH (the dev shell provides it); its absence fails the
## suite loudly rather than skipping it. Certificates go to a scratch
## `TEST_CERTIFICATES_DIR`, never to the user's store.
##
## Run: `nim c -r src/tests/cli/ct_test_run_delegation_test.nim` after
## `just build-once` (which builds `ct` and `ct-test` into `src/build-debug/bin`).
## `CODETRACER_E2E_CT_PATH` / `CODETRACER_E2E_CT_TEST_PATH` point it elsewhere.

import std/[json, os, osproc, strtabs, strutils, unittest]

import ../../ct_test/ct_test_delegate

const
  RunTimeoutMs = 300_000
    ## A wedge guard for one `go test` run, not a performance budget.

proc repoRoot(): string =
  ## ``<repo>/src/tests/cli`` -> ``<repo>``
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  ## Resolved as `agent_cli_test.nim` resolves it.
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  let buildDir = getEnv("CODETRACER_BUILD_DIR",
    repoRoot() / "src" / "build-debug")
  result = buildDir / "bin" / addFileExt("ct", ExeExt)

proc ctTestBinary(): string =
  ## The ORC runner the build puts beside `ct`.
  result = getEnv("CODETRACER_E2E_CT_TEST_PATH", "")
  if result.len == 0:
    result = ctBinary().parentDir / ctTestFileName()

proc scratchRoot(): string =
  result = getTempDir() / "ct-test-run-delegation-" & $getCurrentProcessId()
  createDir(result)
  # Resolved, because the lookup resolves the executable's path before it
  # looks beside it, and the paths it reports are compared with these.
  result = expandFilename(result)

let scratch = scratchRoot()

proc pathWithoutCtTest(): string =
  ## The inherited PATH minus every directory that holds a `ct-test`, so a
  ## case controls exactly which `ct-test` (if any) is reachable. git and go
  ## stay reachable.
  var kept: seq[string] = @[]
  for dir in getEnv("PATH").split(PathSep):
    if dir.len > 0 and not fileExists(dir / ctTestFileName()):
      kept.add dir
  kept.join($PathSep)

proc installCopy(src, dest: string) =
  createDir(dest.parentDir)
  copyFile(src, dest)
  setFilePermissions(dest, getFilePermissions(src))

proc git(workspace: string; args: varargs[string]) =
  let (output, code) = execCmdEx(
    "git -c user.email=ct@example.invalid -c user.name=ct " &
    args.join(" "), workingDir = workspace)
  doAssert code == 0, "git " & args.join(" ") & " failed: " & output

proc goWorkspace(name: string; failing = false): string =
  ## A committed copy of the Go fixture. `failing` breaks one assertion, so
  ## the run executes tests and one of them fails.
  result = scratch / "workspaces" / name
  removeDir(result)
  createDir(result.parentDir)
  copyDir(repoRoot() / "src" / "ct_test" / "fixtures" / "go_test_project",
          result)
  if failing:
    let testFile = result / "calculator_test.go"
    let original = readFile(testFile)
    let broken = original.replace("!= 5", "!= 6")
    doAssert broken != original,
      "the Go fixture changed shape; update the failing variant"
    writeFile(testFile, broken)
  git(result, "init", "-q")
  git(result, "add", "-A")
  git(result, "commit", "-qm", "fixture")

proc lookupWorkspace(name: string): string =
  ## A committed copy of the Python `unittest` fixture, whose provider
  ## discovers tests but declares it cannot run them. `ct-test test run`
  ## answers it with exit 2 and the verdict `nothing-executed`, with no
  ## toolchain involved; a `ct` that did not delegate answers with its refusal
  ## and exit 1. That difference is how the lookup cases tell whether the run
  ## reached `ct-test`.
  result = scratch / "workspaces" / name
  removeDir(result)
  createDir(result.parentDir)
  copyDir(repoRoot() / "src" / "ct_test" / "fixtures" /
          "python_unittest_project", result)
  git(result, "init", "-q")
  git(result, "add", "-A")
  git(result, "commit", "-qm", "fixture")

type
  Run = object
    exitCode: int
    stdout, stderr: string

proc run(exe: string; args: seq[string]; workspace, certificates: string;
         path = getEnv("PATH")): Run =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["PATH"] = path
  env["TEST_CERTIFICATES_DIR"] = certificates
  let outFile = scratch / "stdout.txt"
  let errFile = scratch / "stderr.txt"
  # Files rather than pipes: a run's output is not bounded by a pipe buffer,
  # and the two streams must stay separate to be compared one by one.
  let command = quoteShellCommand(@[exe] & args) &
    " > " & quoteShell(outFile) & " 2> " & quoteShell(errFile)
  let process = startProcess("/bin/sh", workingDir = workspace,
    args = @["-c", command], env = env, options = {})
  defer: close(process)
  result.exitCode = waitForExit(process, timeout = RunTimeoutMs)
  result.stdout = readFile(outFile)
  result.stderr = readFile(errFile)

proc normalizedSummary(stdout, certificates: string): JsonNode =
  ## The run summary with the fields that differ between two runs of the same
  ## tests removed: the wall time, the issue time inside the certificate
  ## document, and the store-specific file the certificate was written to
  ## (whose name is derived from that document). Everything else — counts,
  ## verdict, errors, the certificate's binding and argv — must be identical.
  result = parseJson(stdout)
  result.delete("wall_time_ms")
  let cert = result{"certificate"}
  if cert != nil and cert.kind == JObject:
    if cert.hasKey("written_to"):
      let written = cert["written_to"].getStr()
      check written.startsWith(certificates)
      cert["written_to"] = %relativePath(written.parentDir, certificates)
    if cert.hasKey("document"):
      var lines: seq[string] = @[]
      for line in cert["document"].getStr().splitLines():
        if not line.startsWith("issued_at = "):
          lines.add line
      cert["document"] = %lines.join("\n")

proc reachedCtTest(r: Run): bool =
  ## Whether a run on a `lookupWorkspace` was executed by `ct-test`: its exit
  ## 2 and `nothing-executed` verdict, where the refusal is exit 1.
  checkpoint(r.stdout & r.stderr)
  r.exitCode == 2 and
    parseJson(r.stdout){"verdict"}.getStr() == "nothing-executed"

proc certificateFiles(root: string): seq[string] =
  if dirExists(root):
    for path in walkDirRec(root):
      if path.endsWith(".toml"):
        result.add path

proc freshStore(name: string): string =
  result = scratch / "stores" / name
  removeDir(result)
  createDir(result)

suite "ct test run delegates to the ORC ct-test":
  setup:
    require fileExists(ctBinary())
    require fileExists(ctTestBinary())

  test "a refc ct beside ct-test runs the tests exactly as ct-test does":
    require findExe("go").len > 0  # the fixture's toolchain; see the header
    let layout = scratch / "beside" / "bin"
    installCopy(ctBinary(), layout / addFileExt("ct", ExeExt))
    installCopy(ctTestBinary(), layout / ctTestFileName())
    let workspace = goWorkspace("passing")
    let viaCt = freshStore("via-ct")
    let direct = freshStore("direct")
    let delegated = run(layout / addFileExt("ct", ExeExt),
      @["test", "run", "--workspace", "."], workspace, viaCt)
    let reference = run(layout / ctTestFileName(),
      @["test", "run", "--workspace", "."], workspace, direct)
    checkpoint(delegated.stdout & delegated.stderr)
    check delegated.exitCode == 0
    check delegated.exitCode == reference.exitCode
    check delegated.stderr == reference.stderr
    check normalizedSummary(delegated.stdout, viaCt) ==
      normalizedSummary(reference.stdout, direct)
    let summary = parseJson(delegated.stdout)
    check summary["passed"].getInt() > 0
    check summary["certificate"]["issued"].getBool()
    # Published to the scratch store, and the certificate is ct-test's own:
    # it records the command that actually ran.
    check certificateFiles(viaCt).len == 1
    check "argv = [\"ct-test\", \"test\", \"run\", \"--workspace\", \".\"]" in
      summary["certificate"]["document"].getStr()
    # ...and `ct` itself then reports the working tree covered by it.
    let verify = run(layout / addFileExt("ct", ExeExt),
      @["test", "verify", "--worktree"], workspace, viaCt)
    checkpoint(verify.stdout & verify.stderr)
    check verify.exitCode == 0

  test "a failing test's exit status and output come through unchanged":
    require findExe("go").len > 0
    let layout = scratch / "beside" / "bin"
    installCopy(ctBinary(), layout / addFileExt("ct", ExeExt))
    installCopy(ctTestBinary(), layout / ctTestFileName())
    let workspace = goWorkspace("failing", failing = true)
    let viaCt = freshStore("failing-via-ct")
    let direct = freshStore("failing-direct")
    let delegated = run(layout / addFileExt("ct", ExeExt),
      @["test", "run", "--workspace", "."], workspace, viaCt)
    let reference = run(layout / ctTestFileName(),
      @["test", "run", "--workspace", "."], workspace, direct)
    checkpoint(delegated.stdout & delegated.stderr)
    check delegated.exitCode == 1
    check delegated.exitCode == reference.exitCode
    check delegated.stderr == reference.stderr
    check normalizedSummary(delegated.stdout, viaCt) ==
      normalizedSummary(reference.stdout, direct)
    check parseJson(delegated.stdout)["failed"].getInt() > 0
    check certificateFiles(viaCt).len == 0

  test "without a reachable ct-test, ct refuses and names the lookup":
    let lonely = scratch / "lonely" / "bin"
    let ct = lonely / addFileExt("ct", ExeExt)
    installCopy(ctBinary(), ct)
    let store = freshStore("lonely")
    let refused = run(ct, @["test", "run", "--workspace", "."],
      lookupWorkspace("lonely"), store, path = pathWithoutCtTest())
    checkpoint(refused.stdout & refused.stderr)
    check refused.exitCode == 1
    let errors = parseJson(refused.stdout)["errors"]
    check errors.len == 1
    let message = errors[0].getStr()
    check "--mm:refc" in message
    check ("next to this executable (" & lonely / ctTestFileName() & ")") in
      message
    check "the install's tools directory (there is none)" in message
    check ("`" & ctTestFileName() & "` on PATH") in message
    check message in refused.stderr
    check certificateFiles(store).len == 0

  test "a symlinked ct finds the ct-test next to its target":
    when defined(windows):
      skip()
    else:
      let real = scratch / "real" / "bin"
      installCopy(ctBinary(), real / "ct")
      installCopy(ctTestBinary(), real / ctTestFileName())
      let links = scratch / "links"
      removeDir(links)
      createDir(links)
      createSymlink(real / "ct", links / "ct")
      let reached = run(links / "ct", @["test", "run", "--workspace", "."],
        lookupWorkspace("symlinked"), freshStore("symlinked"),
        path = pathWithoutCtTest())
      checkpoint(reached.stdout & reached.stderr)
      check reachedCtTest(reached)

  test "the install's tools directory is searched second":
    let root = scratch / "tools-layout"
    removeDir(root)
    installCopy(ctBinary(), root / "bin" / addFileExt("ct", ExeExt))
    installCopy(ctTestBinary(), root / "tools" / ctTestFileName())
    let reached = run(root / "bin" / addFileExt("ct", ExeExt),
      @["test", "run", "--workspace", "."], lookupWorkspace("tools"),
      freshStore("tools"), path = pathWithoutCtTest())
    check reachedCtTest(reached)

  test "PATH is searched last":
    let root = scratch / "path-layout"
    removeDir(root)
    installCopy(ctBinary(), root / "bin" / addFileExt("ct", ExeExt))
    installCopy(ctTestBinary(), root / "elsewhere" / ctTestFileName())
    let reached = run(root / "bin" / addFileExt("ct", ExeExt),
      @["test", "run", "--workspace", "."], lookupWorkspace("on-path"),
      freshStore("on-path"),
      path = root / "elsewhere" & $PathSep & pathWithoutCtTest())
    check reachedCtTest(reached)

suite "the ct-test lookup":
  test "the order is beside the executable, then tools, then PATH":
    let root = scratch / "order"
    removeDir(root)
    for dir in ["bin", "tools", "path"]:
      createDir(root / dir)
      writeFile(root / dir / ctTestFileName(), "")
    writeFile(root / "bin" / "ct", "")
    let all = locateCtTest(root / "bin" / "ct", root / "path")
    check all.found == root / "bin" / ctTestFileName()
    check all.tried.len == 3
    removeFile(root / "bin" / ctTestFileName())
    check locateCtTest(root / "bin" / "ct", root / "path").found ==
      root / "tools" / ctTestFileName()
    removeFile(root / "tools" / ctTestFileName())
    check locateCtTest(root / "bin" / "ct", root / "path").found ==
      root / "path" / ctTestFileName()
    removeFile(root / "path" / ctTestFileName())
    check locateCtTest(root / "bin" / "ct", root / "path").found == ""

  test "the running executable is never its own delegate":
    ## A refc binary that happens to be named `ct-test` must not hand
    ## `test run` to itself — not from beside itself, and not from PATH.
    let root = scratch / "self"
    removeDir(root)
    createDir(root / "bin")
    let self = root / "bin" / ctTestFileName()
    writeFile(self, "")
    let lookup = locateCtTest(self, root / "bin")
    check lookup.found == ""
    # ...while a different `ct-test` later on PATH is still found.
    createDir(root / "other")
    writeFile(root / "other" / ctTestFileName(), "")
    check locateCtTest(self, root / "bin" & $PathSep & root / "other").found ==
      root / "other" / ctTestFileName()

  test "a symlink is resolved before looking beside it":
    when defined(windows):
      skip()
    else:
      let root = scratch / "resolve"
      removeDir(root)
      createDir(root / "real")
      createDir(root / "link")
      writeFile(root / "real" / "ct", "")
      writeFile(root / "real" / ctTestFileName(), "")
      createSymlink(root / "real" / "ct", root / "link" / "ct")
      let lookup = locateCtTest(root / "link" / "ct", "")
      check lookup.selfExe == expandFilename(root / "real" / "ct")
      check lookup.found == expandFilename(root / "real") / ctTestFileName()

removeDir(scratch)
