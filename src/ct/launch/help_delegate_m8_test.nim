## M8 verification suite for the CodeTracer Launcher shell completion
## subcommands (``ct-completions <shell>``) and the two-level
## ``ct-complete`` dispatch implemented in ``help_delegate.nim``.
##
## Each named test in this module corresponds to one row in the M8
## "Verification" section of
## ``codetracer-specs/Planned-Work/CodeTracer-Launcher.status.org``.
## The tests drive the real built ``ct`` binary as a subprocess to
## stay honest about the user-visible behaviour.
##
## Quality bar reminder from the milestone spec:
##
## * ``test_completion_top_level_fast`` must verify *no* component
##   binary was exec'd. We install a fake component whose script
##   prints a unique marker when run and assert the marker is
##   *absent* from the launcher's output.
## * ``test_completion_subcommand_delegation`` must verify the right
##   component binary *was* exec'd. The fake component prints its
##   marker plus a list of candidates; we assert both appear in the
##   launcher's stdout.
##
## Build/run:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/help_delegate_m8_test \
##       src/ct/launch/help_delegate_m8_test.nim

import std/[ os, osproc, streams, strtabs, strutils, unittest ]

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  ## ``src/ct/launch/help_delegate_m8_test.nim`` -> repo root.
const ctBinary = repoRoot / "src" / "build-debug" / "bin" / "ct"

proc runtimeEnv(extras: openArray[(string, string)]): StringTableRef =
  ## Build a child process env: parent env minus any test-isolation
  ## variables, plus the LD_LIBRARY_PATH augmentation ct needs at
  ## runtime. Mirrors the M7 test helper.
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
  result.del("CODETRACER_COMPONENTS_ROOT")
  result.del("CODETRACER_COMPONENTS_PATH")
  result.del("CODETRACER_REGISTRY_PATH")
  for (k, v) in extras:
    result[k] = v

proc runCt(args: openArray[string], env: StringTableRef,
            workdir = ""): tuple[code: int, stdoutStr: string] =
  ## Run the built ct binary with ``args`` and ``env`` and return the
  ## exit code plus combined stdout/stderr (the binary writes both
  ## informational and result lines to stdout).
  if not fileExists(ctBinary):
    raise newException(IOError,
      "ct binary missing at " & ctBinary &
      " -- rebuild with `just build-once`.")
  let cwd = if workdir.len > 0: workdir else: getCurrentDir()
  let p = startProcess(ctBinary, workingDir = cwd, args = @args,
                       env = env,
                       options = {poStdErrToStdOut, poUsePath})
  let outp = p.outputStream.readAll()
  let code = waitForExit(p)
  close p
  (code, outp)

proc writeMarkerComponent(dir: string, name, version, binBaseName: string,
                          marker: string,
                          extraCapLines: seq[string],
                          completeOutput = "") =
  ## Install a fake component:
  ## * The capabilities file declares ``name``/``version``/``bin`` and
  ##   any extra capability lines (e.g. ``shell``, ``record .py``)
  ##   provided by the caller.
  ## * The bin script prints ``marker`` to its own stdout whenever it
  ##   is invoked with ``ct-complete`` (so tests can assert presence
  ##   or absence in the launcher's output).
  ## * When ``completeOutput`` is non-empty the script also prints
  ##   those lines after the marker -- this lets the delegation test
  ##   verify candidates flow back through the launcher unchanged.
  let compDir = dir / (name & "@" & version)
  createDir(compDir / "bin")
  let binPath = compDir / "bin" / binBaseName
  var capLines = @[
    "name " & name,
    "version " & version,
    "bin " & binBaseName,
  ]
  capLines.add extraCapLines
  writeFile(compDir / "capabilities", capLines.join("\n") & "\n")
  var script = "#!/bin/sh\n"
  script.add "if [ \"$1\" = \"ct-complete\" ]; then\n"
  script.add "  printf '%s\\n' '" & marker & "'\n"
  if completeOutput.len > 0:
    # Emit each completion-candidate line separately so we exercise
    # the launcher's stream-through behaviour.
    for line in completeOutput.splitLines:
      if line.len == 0: continue
      script.add "  printf '%s\\n' '" & line & "'\n"
  script.add "  exit 0\n"
  script.add "fi\n"
  # ct-describe-commands path: stay quiet so assembleHelp() does not
  # incidentally pick up our marker via the describe protocol.
  script.add "if [ \"$1\" = \"ct-describe-commands\" ]; then\n"
  script.add "  exit 0\n"
  script.add "fi\n"
  script.add "exit 0\n"
  writeFile(binPath, script)
  setFilePermissions(binPath, {fpUserRead, fpUserExec, fpUserWrite})

suite "M8 — codetracer-desktop shell completion":

  test "test_bash_completion_script":
    ## Spec §2.7: ct-completions bash emits a bash completion script
    ## that defines _ct_completions and registers it with
    ## ``complete -F``.
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": getTempDir() / "m8-bash-empty",
      "CODETRACER_REGISTRY_PATH":   getTempDir() / "m8-bash-empty-reg",
    })
    createDir(env["CODETRACER_COMPONENTS_ROOT"])
    createDir(env["CODETRACER_REGISTRY_PATH"])
    let res = runCt(@["ct-completions", "bash"], env)
    check res.code == 0
    check "_ct_completions" in res.stdoutStr
    check "complete -F _ct_completions ct" in res.stdoutStr
    # Spec §2.7 mandates the script delegates to ``codetracer
    # ct-complete`` (bypassing the launcher exec hop).
    check "codetracer ct-complete" in res.stdoutStr
    # The script must be syntactically valid bash. We use ``bash -n``
    # (the noexec / parse-only mode) instead of actually sourcing it.
    # Sourcing would execute the top-level ``complete -F`` call, which
    # fails on bash builds that omit the ``complete`` builtin (e.g.
    # some minimal Nix bash variants). Whether ``complete`` is wired
    # up correctly at runtime is the user's shell's job; here we only
    # care that the generator emitted valid bash syntax.
    let bashBin = findExe("bash")
    if bashBin.len > 0:
      let scriptPath = getTempDir() / "m8-bash-completion-script.sh"
      writeFile(scriptPath, res.stdoutStr)
      let p = startProcess(bashBin, args = @["-n", scriptPath],
        options = {poStdErrToStdOut, poUsePath})
      let bashOut = p.outputStream.readAll()
      let bashCode = waitForExit(p)
      close p
      check bashCode == 0
      # ``bash -n`` is silent on success; surface any parser output to
      # make failures easier to diagnose.
      check bashOut.len == 0
      removeFile(scriptPath)

  test "test_zsh_completion_script":
    ## Spec §2.7: ct-completions zsh emits a zsh completion function
    ## that registers itself with compdef.
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": getTempDir() / "m8-zsh-empty",
      "CODETRACER_REGISTRY_PATH":   getTempDir() / "m8-zsh-empty-reg",
    })
    createDir(env["CODETRACER_COMPONENTS_ROOT"])
    createDir(env["CODETRACER_REGISTRY_PATH"])
    let res = runCt(@["ct-completions", "zsh"], env)
    check res.code == 0
    # A zsh completion function for ``ct`` must either begin with the
    # ``#compdef`` magic comment that autoloaded ``_ct`` files use,
    # or end with an explicit ``compdef`` call. Our generated script
    # uses both, belt-and-braces.
    check "#compdef ct" in res.stdoutStr
    check "compdef _ct ct" in res.stdoutStr
    # Must delegate to ``codetracer ct-complete`` per spec §2.7.
    check "codetracer ct-complete" in res.stdoutStr
    # The function must call ``compadd`` (the zsh primitive for
    # contributing candidates) or ``_arguments``; we use compadd.
    check "compadd" in res.stdoutStr

  test "test_fish_completion_script":
    ## Spec §2.7: ct-completions fish emits ``complete -c ct`` lines
    ## wired to a helper function that calls back into the launcher.
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": getTempDir() / "m8-fish-empty",
      "CODETRACER_REGISTRY_PATH":   getTempDir() / "m8-fish-empty-reg",
    })
    createDir(env["CODETRACER_COMPONENTS_ROOT"])
    createDir(env["CODETRACER_REGISTRY_PATH"])
    let res = runCt(@["ct-completions", "fish"], env)
    check res.code == 0
    check "complete -c ct" in res.stdoutStr
    check "codetracer ct-complete" in res.stdoutStr
    # Fish needs the dynamic ``-a '(...)'`` form to invoke the helper
    # at completion time.
    check "(__ct_complete)" in res.stdoutStr

  test "test_completion_top_level_fast":
    ## Top-level ``ct-complete ""`` must enumerate commands from the
    ## installed components' *capability files alone* -- the spec's
    ## fast path (§2.7). We prove no component binary ran by
    ## installing a fake component whose binary emits a unique marker
    ## whenever it is invoked. The marker must be absent from the
    ## launcher's output.
    let tmpRoot = getTempDir() / "m8-toplevel-fast"
    removeDir(tmpRoot)
    createDir(tmpRoot)
    let compRoot = tmpRoot / "components"
    let regRoot  = tmpRoot / "registry"
    createDir(compRoot); createDir(regRoot)
    const fastMarker = "MARKER_TOP_LEVEL_FAST_PATH_RAN_BINARY"
    writeMarkerComponent(compRoot,
      name = "codetracer-rr-backend", version = "1.2.0",
      binBaseName = "codetracer-rr",
      marker = fastMarker,
      extraCapLines = @[
        "shell",
        "record .c .cpp .rs",
      ])
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": compRoot,
      "CODETRACER_REGISTRY_PATH":   regRoot,
    })
    let res = runCt(@["ct-complete"], env)
    check res.code == 0
    let lines = res.stdoutStr.splitLines()
    # codetracer-desktop's own commands must be present (from the
    # compile-time self-surface, no I/O at all).
    check "record" in lines
    check "replay" in lines
    check "run" in lines
    # The third-party component's ``shell`` command, which only
    # appears in its capabilities file, must also appear -- proving
    # the parser actually consulted the file.
    check "shell" in lines
    # Crucial: the fast path must *not* have run the component
    # binary. If it did, the marker would be in stdout.
    check fastMarker notin res.stdoutStr
    # Launcher-delegate plumbing must not leak.
    check "ct-describe-commands" notin lines
    check "ct-help" notin lines
    check "ct-complete" notin lines
    check "ct-completions" notin lines

  test "test_completion_subcommand_delegation":
    ## ``ct-complete <foreign-cmd> ...`` must locate the component
    ## that declares ``<foreign-cmd>`` in its capabilities file and
    ## exec ``<component-bin> ct-complete <args>``. We install a fake
    ## ``codetracer-rr-backend`` that declares ``shell`` and emits a
    ## delegation marker plus a set of fake candidates. The launcher
    ## must (a) actually run that binary and (b) stream its output
    ## through unchanged.
    let tmpRoot = getTempDir() / "m8-subcmd-delegation"
    removeDir(tmpRoot)
    createDir(tmpRoot)
    let compRoot = tmpRoot / "components"
    let regRoot  = tmpRoot / "registry"
    createDir(compRoot); createDir(regRoot)
    const delegateMarker = "RR_CT_COMPLETE_CALLED"
    const candidateA = "--build-system=cmake"
    const candidateB = "--build-system=cargo"
    writeMarkerComponent(compRoot,
      name = "codetracer-rr-backend", version = "1.2.0",
      binBaseName = "codetracer-rr",
      marker = delegateMarker,
      extraCapLines = @[ "shell" ],
      completeOutput = candidateA & "\n" & candidateB & "\n")
    let env = runtimeEnv({
      "CODETRACER_COMPONENTS_ROOT": compRoot,
      "CODETRACER_REGISTRY_PATH":   regRoot,
    })
    # Drive a typical "ct shell --b<TAB>" completion request.
    let res = runCt(@["ct-complete", "shell", "--b"], env)
    check res.code == 0
    # The marker proves we exec'd the component binary -- i.e. we
    # took the delegation path and not the local self path.
    check delegateMarker in res.stdoutStr
    # The candidates the component emitted must be forwarded
    # verbatim to the launcher's stdout.
    check candidateA in res.stdoutStr
    check candidateB in res.stdoutStr
