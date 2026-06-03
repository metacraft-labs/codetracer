## M7 verification suite for the CodeTracer Launcher help-delegate
## subcommands implemented in ``help_delegate.nim``.
##
## Each named test in this module corresponds to one row in the M7
## "Verification" section of
## ``codetracer-specs/Planned-Work/CodeTracer-Launcher.status.org``.
## The tests drive the real built ``ct`` binary as a subprocess --
## they do not mock the subcommand handlers. Mocking would defeat
## the M7 quality bar (the launcher itself will run the binary in
## production, so the test should too).
##
## To stay isolated from the developer's real installs, every test
## sets ``CODETRACER_COMPONENTS_ROOT`` and ``CODETRACER_REGISTRY_PATH``
## to a fresh tmp directory. This is the same isolation mechanism
## the launcher exposes for M1 fixture tests
## (see ``codetracer-launcher/src/launcher.nim::collectLevels``).
##
## Build/run:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/help_delegate_test \
##       src/ct/launch/help_delegate_test.nim

import std/[ os, osproc, streams, strtabs, strutils, unittest ]

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  ## ``src/ct/launch/help_delegate_test.nim`` -> repo root.
const ctBinary = repoRoot / "src" / "build-debug" / "bin" / "ct"

proc runtimeEnv(extras: openArray[(string, string)]): StringTableRef =
  ## Build a child process env: parent env minus any test-isolation
  ## variables, plus the LD_LIBRARY_PATH augmentation ct needs at
  ## runtime (the binary dlopen's libcrypto / libssl from the Nix
  ## openssl prefix, which is published in
  ## ``CODETRACER_LD_LIBRARY_PATH`` -- see ``src/ct/codetracer.nim``).
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  let ctLdPath = getEnv("CODETRACER_LD_LIBRARY_PATH", "")
  if ctLdPath.len > 0:
    let current = getEnv("LD_LIBRARY_PATH", "")
    if current.len == 0:
      result["LD_LIBRARY_PATH"] = ctLdPath
    else:
      result["LD_LIBRARY_PATH"] = ctLdPath & ":" & current
  # Each test sets its own components/registry overrides on top of
  # this base env -- clear any inherited values so a wider-scope
  # test fixture cannot leak into a narrower one.
  result.del("CODETRACER_COMPONENTS_ROOT")
  result.del("CODETRACER_COMPONENTS_PATH")
  result.del("CODETRACER_REGISTRY_PATH")
  for (k, v) in extras:
    result[k] = v

proc runCt(args: openArray[string], env: StringTableRef,
            workdir = ""): tuple[code: int, stdoutStr, stderrStr: string] =
  ## Run the built ct binary with ``args`` and ``env`` and return the
  ## exit code plus captured stdout / stderr. Stderr is captured
  ## separately so tests can assert on stdout-only output.
  if not fileExists(ctBinary):
    raise newException(IOError,
      "ct binary missing at " & ctBinary &
      " -- rebuild with `just build-once` or the direct nim invocation "&
      "documented in src/ct/launch/help_delegate_test.nim header")
  let cwd = if workdir.len > 0: workdir else: getCurrentDir()
  let p = startProcess(ctBinary, workingDir = cwd, args = @args,
                       env = env,
                       options = {poStdErrToStdOut, poUsePath})
  let outp = p.outputStream.readAll()
  let code = waitForExit(p)
  close p
  (code, outp, "")

proc writeFixtureCapabilities(dir: string, name, version: string,
                              binBaseName: string,
                              extraLines: seq[string] = @[]) =
  let compDir = dir / (name & "@" & version)
  createDir(compDir / "bin")
  let binPath = compDir / "bin" / binBaseName
  var lines = @[
    "name " & name,
    "version " & version,
    "bin " & binBaseName,
  ]
  lines.add extraLines
  writeFile(compDir / "capabilities", lines.join("\n") & "\n")
  # Drop an empty file so other tests can see the bin path exists.
  writeFile(binPath, "")
  setFilePermissions(binPath, {fpUserRead, fpUserExec})

proc writeFixtureBinScript(dir: string, name, version: string,
                            binBaseName: string,
                            describeOutput: string,
                            extraCapLines: seq[string] = @[]) =
  ## Like :proc:`writeFixtureCapabilities` but also installs a real
  ## shell-script binary that prints ``describeOutput`` when invoked
  ## as ``<bin> ct-describe-commands``. This is how the help
  ## delegate's per-component query is exercised end-to-end.
  let compDir = dir / (name & "@" & version)
  createDir(compDir / "bin")
  let binPath = compDir / "bin" / binBaseName
  var lines = @[
    "name " & name,
    "version " & version,
    "bin " & binBaseName,
  ]
  lines.add extraCapLines
  writeFile(compDir / "capabilities", lines.join("\n") & "\n")
  # Shell script implementing the describe-commands subset of the
  # ct-* protocol. The here-doc body is the test's expected output.
  var script = "#!/bin/sh\n"
  script.add "if [ \"$1\" = \"ct-describe-commands\" ]; then\n"
  script.add "cat <<'__EOF__'\n"
  script.add describeOutput
  script.add "__EOF__\n"
  script.add "  exit 0\n"
  script.add "fi\n"
  script.add "exit 0\n"
  writeFile(binPath, script)
  setFilePermissions(binPath, {fpUserRead, fpUserExec, fpUserWrite})

proc writeRegistryFile(root: string, body: string) =
  createDir(root)
  writeFile(root / "registry.txt", body)

proc writeLatestFile(root: string, component, version: string) =
  let latestDir = root / "latest"
  createDir(latestDir)
  writeFile(latestDir / component, version & "\n")

suite "M7 — codetracer-desktop help delegate":

  test "test_ct_describe_commands_output":
    ## Spec §2.6: ct-describe-commands emits a block per command with
    ## ``command``, ``description``, ``file-types`` (when applicable)
    ## etc. We verify the ``record`` command's block is present with
    ## the expected fields.
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": getTempDir() / "m7-empty-comp",
      "CODETRACER_REGISTRY_PATH":   getTempDir() / "m7-empty-reg",
    })
    createDir(env["CODETRACER_COMPONENTS_ROOT"])
    createDir(env["CODETRACER_REGISTRY_PATH"])
    let res = runCt(@["ct-describe-commands"], env)
    check res.code == 0
    check "command record\n" in res.stdoutStr
    let recordBlockStart = res.stdoutStr.find("command record\n")
    check recordBlockStart >= 0
    # The ``record`` block must continue with description + file-types
    # before the next blank line. Slice that block out.
    let blockEnd = res.stdoutStr.find("\n\n", start = recordBlockStart)
    check blockEnd >= 0
    let recBlock = res.stdoutStr[recordBlockStart .. blockEnd]
    check "description Record a program execution" in recBlock
    check "file-types " in recBlock
    check ".py" in recBlock
    check ".rb" in recBlock
    # ``replay`` should appear too -- with a description but no
    # file-types (per spec §2.6 example).
    check "command replay\n" in res.stdoutStr
    # The launcher-delegate plumbing subcommands must NOT leak into
    # the user-visible describe output.
    check "command ct-describe-commands" notin res.stdoutStr
    check "command ct-help" notin res.stdoutStr
    check "command ct-complete" notin res.stdoutStr

  test "test_ct_help_installed_components":
    ## ct-help lists commands from all installed components with
    ## correct descriptions. We install a fixture component
    ## alongside codetracer-desktop (the self entry).
    let tmpRoot = getTempDir() / "m7-help-installed"
    removeDir(tmpRoot)
    createDir(tmpRoot)
    let compRoot = tmpRoot / "components"
    let regRoot  = tmpRoot / "registry"
    createDir(compRoot); createDir(regRoot)
    writeFixtureBinScript(compRoot,
      name = "codetracer-rr-backend", version = "1.2.0",
      binBaseName = "codetracer-rr-backend",
      describeOutput = """command shell
description Instrumented shell for complex build systems
note Requires active license

command record
description Record and replay compiled programs
file-types .c .cpp .rs .nim

""")
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": compRoot,
      "CODETRACER_REGISTRY_PATH":   regRoot,
    })
    let res = runCt(@["ct-help"], env)
    check res.code == 0
    # codetracer-desktop's own command shows up via the self entry.
    check "replay" in res.stdoutStr
    check "Replay a recorded trace" in res.stdoutStr
    # codetracer-rr-backend's command + description from its
    # describe output show up too.
    check "shell" in res.stdoutStr
    check "Instrumented shell" in res.stdoutStr
    # Both components are listed under Installed.
    check "Installed:" in res.stdoutStr
    check "codetracer-desktop" in res.stdoutStr
    check "codetracer-rr-backend" in res.stdoutStr

  test "test_ct_help_uninstalled_components":
    ## ct-help shows "Not installed:" section with install-hint from
    ## the registry for components present in the registry but not in
    ## the components directory.
    let tmpRoot = getTempDir() / "m7-help-uninstalled"
    removeDir(tmpRoot)
    createDir(tmpRoot)
    let compRoot = tmpRoot / "components"
    let regRoot  = tmpRoot / "registry"
    createDir(compRoot); createDir(regRoot)
    let registryBody = """# fixture registry
updated 2026-06-04
min-launcher-version 1.0.0

mirror https://example.invalid/dl

component codetracer-python-recorder
description Python program recorder (db backend)
install-hint pip install codetracer-python-recorder
tier free
latest 0.4.0

  versions 0.4.0 ..
  commands record run
  file-types .py
"""
    writeRegistryFile(regRoot, registryBody)
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": compRoot,
      "CODETRACER_REGISTRY_PATH":   regRoot,
    })
    let res = runCt(@["ct-help"], env)
    check res.code == 0
    check "Not installed:" in res.stdoutStr
    check "codetracer-python-recorder" in res.stdoutStr
    check "pip install codetracer-python-recorder" in res.stdoutStr

  test "test_ct_help_upgrade_hint":
    ## A cached ``latest/<component>`` newer than the installed
    ## version surfaces a ``[<latest> available]`` annotation.
    let tmpRoot = getTempDir() / "m7-help-upgrade"
    removeDir(tmpRoot)
    createDir(tmpRoot)
    let compRoot = tmpRoot / "components"
    let regRoot  = tmpRoot / "registry"
    createDir(compRoot); createDir(regRoot)
    # An installed component pinned to an older version.
    writeFixtureBinScript(compRoot,
      name = "codetracer-rr-backend", version = "25.11.1",
      binBaseName = "codetracer-rr-backend",
      describeOutput = """command record
description Record and replay compiled programs
file-types .c .cpp

""")
    # latest cache says 26.01.1.
    writeLatestFile(regRoot, "codetracer-rr-backend", "26.01.1")
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": compRoot,
      "CODETRACER_REGISTRY_PATH":   regRoot,
    })
    let res = runCt(@["ct-help"], env)
    check res.code == 0
    check "[26.01.1 available]" in res.stdoutStr
    check "codetracer-rr-backend" in res.stdoutStr
    check "25.11.1" in res.stdoutStr

  test "test_ct_help_dynamic_notes":
    ## A ``note`` line in a component's ct-describe-commands output
    ## must surface alongside its command in the rendered help.
    let tmpRoot = getTempDir() / "m7-help-notes"
    removeDir(tmpRoot)
    createDir(tmpRoot)
    let compRoot = tmpRoot / "components"
    let regRoot  = tmpRoot / "registry"
    createDir(compRoot); createDir(regRoot)
    writeFixtureBinScript(compRoot,
      name = "codetracer-rr-backend", version = "1.2.0",
      binBaseName = "codetracer-rr-backend",
      describeOutput = """command shell
description Instrumented shell for complex build systems
note Requires active license

""")
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": compRoot,
      "CODETRACER_REGISTRY_PATH":   regRoot,
    })
    let res = runCt(@["ct-help"], env)
    check res.code == 0
    check "shell" in res.stdoutStr
    check "Requires active license" in res.stdoutStr
    # The renderer wraps the note in square brackets per spec §2.6.
    check "[Requires active license]" in res.stdoutStr

  test "test_ct_complete_top_level":
    ## ct-complete with an empty partial returns every known
    ## top-level command name -- at minimum, the codetracer-desktop
    ## self-surface commands.
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": getTempDir() / "m7-complete-empty",
      "CODETRACER_REGISTRY_PATH":   getTempDir() / "m7-complete-empty-reg",
    })
    createDir(env["CODETRACER_COMPONENTS_ROOT"])
    createDir(env["CODETRACER_REGISTRY_PATH"])
    let res = runCt(@["ct-complete"], env)
    check res.code == 0
    let lines = res.stdoutStr.splitLines()
    check "record" in lines
    check "replay" in lines
    check "run" in lines
    check "list" in lines
    # ct-* helpers must NOT appear in top-level completion.
    check "ct-describe-commands" notin lines
    check "ct-help" notin lines
    check "ct-complete" notin lines

  test "test_ct_complete_subcommand":
    ## ct-complete <subcommand> filters file completions by the
    ## subcommand's declared file-types. ``record`` supports
    ## ``.py``/``.rb``/etc., so ``.txt`` should be filtered out.
    let workdir = getTempDir() / "m7-complete-subcommand"
    removeDir(workdir)
    createDir(workdir)
    writeFile(workdir / "foo.py", "")
    writeFile(workdir / "foo.rb", "")
    writeFile(workdir / "foo.txt", "")
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": getTempDir() / "m7-complete-subcomp",
      "CODETRACER_REGISTRY_PATH":   getTempDir() / "m7-complete-subreg",
    })
    createDir(env["CODETRACER_COMPONENTS_ROOT"])
    createDir(env["CODETRACER_REGISTRY_PATH"])
    let res = runCt(@["ct-complete", "record", "foo."], env, workdir = workdir)
    check res.code == 0
    let lines = res.stdoutStr.splitLines()
    var hasPy = false
    var hasRb = false
    var hasTxt = false
    for ln in lines:
      if ln.endsWith("foo.py"): hasPy = true
      if ln.endsWith("foo.rb"): hasRb = true
      if ln.endsWith("foo.txt"): hasTxt = true
    check hasPy
    check hasRb
    check not hasTxt
