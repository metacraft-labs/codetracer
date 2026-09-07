## ui_dispatch.nim — the EFFECT half of `--ui`. PLAT-1.
##
## Specification: `codetracer-specs/CLI/ct/ui-selection.md` §3.
##
## `ui_selection.nim` decides; this module does the three things a decision
## cannot do by itself: read the `ui` key out of the user's configuration file,
## find the component binary a handoff names, and `exec` it.
##
## ## WHY THIS IS NOT `common/config.loadConfig`
##
## §3.1: the `--ui` decision is taken before any configuration file is touched,
## and §5 nevertheless puts the configuration third in the resolution order.
## Those are reconciled by asking a much smaller question than `loadConfig`
## asks: `configuredUiValue` reads ONE top-level key and has no other effect.
## `loadConfig` parses the whole schema through NimYAML, and — on a first run or
## a schema mismatch — CREATES `~/.config/codetracer/`, COPIES the default
## config into it and REWRITES a config it could not parse. Doing any of that
## before deciding which front-end to start would be a side effect of asking a
## question, on a path whose whole budget is a handful of milliseconds.
##
## The narrow reader is only ever consulted when the flag and the environment
## have BOTH declined to answer (`ui_selection.uiNeedsConfig`), so
## `ct replay --ui=tui <trace>` reads no file at all.
##
## ## WHY THE KEY MUST BE AT COLUMN ZERO
##
## `src/config/default_config.yaml` already contains a `ui:` key — nested under
## `flow:`, where it selects the flow presentation and has nothing to do with a
## front-end. A reader that matched `ui:` anywhere would resolve every default
## installation to `--ui=parallel` and refuse to start. Column zero is what
## distinguishes a document's own key from a key inside a mapping, and
## `ui_dispatch_test.nim` asserts exactly that case against the shipped default
## config rather than against an invented fixture.

import std/[os, oserrors, strutils]

import ../ui_selection
import ../../common/config
import component_roots

when defined(posix):
  import std/posix
else:
  import std/osproc

# The component-root environment variables are part of this module's surface: a
# caller that resolves a handoff has to be able to say where it looked, and a
# test that isolates one has to be able to name the variable rather than spell
# it.
export ui_selection
export component_roots

const
  tuiBinaryEnvVar* = "CODETRACER_TUI_BIN"
    ## An explicit override for the terminal front-end's binary.
    ##
    ## It exists for the same reason `CODETRACER_COMPONENTS_ROOT` does: a
    ## developer running out of a checkout has no installed component bundle,
    ## and a test that needs the handoff to reach a KNOWN binary must be able to
    ## say which one without installing anything. It is checked first, so it
    ## also lets a user pin a build.

proc configuredUiValue*(): string =
  ## §5's third layer: `ui = "<value>"` in the user's configuration.
  ##
  ## Returns "" when there is no configuration file, when it has no top-level
  ## `ui` key, or when anything at all goes wrong reading it. A configuration
  ## file that cannot be read is not an answer to "which front-end", and
  ## refusing to start over it would make an unrelated YAML mistake fatal to
  ## every command.
  ##
  ## The file is located the way `common/config.findConfig` locates it — walking
  ## up from the working directory, then the user's config directory — but
  ## WITHOUT its create-and-copy fallback. See the module header.
  var candidates: seq[string] = @[]
  try:
    var current = getCurrentDir()
    while true:
      candidates.add current / configPath
      let parent = current.parentDir
      if parent == current or parent.len == 0:
        break
      current = parent
    candidates.add userConfigDir / configPath
  except CatchableError, Defect:
    return ""

  for candidate in candidates:
    var raw = ""
    try:
      if not fileExists(candidate):
        continue
      raw = readFile(candidate)
    except CatchableError:
      continue
    for line in raw.splitLines():
      # COLUMN ZERO ONLY — see the module header. `line[0]` is safe because an
      # empty line cannot start with 'u'.
      if not line.startsWith(UiConfigKey & ":"):
        continue
      var value = line[UiConfigKey.len + 1 .. ^1]
      let hash = value.find('#')
      if hash >= 0:
        value = value[0 ..< hash]
      value = value.strip()
      if value.len >= 2 and
         ((value[0] == '"' and value[^1] == '"') or
          (value[0] == '\'' and value[^1] == '\'')):
        value = value[1 ..< ^1]
      # The FIRST top-level `ui` key in the FIRST configuration file found
      # wins, and an empty one is "no answer" rather than "the empty
      # front-end".
      if value.len > 0:
        return value
      return ""
    # A configuration file that exists and declares no `ui` key is still THE
    # configuration: `findConfig`'s walk stops at the first file it finds, and
    # continuing past it here would let a config file three directories up
    # answer for a project that has one of its own.
    return ""
  ""

proc resolveTuiBinary*(componentBin: string): string =
  ## Where `codetracer-tui` is, in the order a component should look.
  ##
  ## Returns "" when nothing is found; the caller reports that by name rather
  ## than exec'ing a bare filename and letting `execv` produce ENOENT.
  let override = getEnv(tuiBinaryEnvVar, "")
  if override.len > 0:
    return override

  let installed = findComponentBinary("codetracer-tui", componentBin)
  if installed.len > 0:
    return installed

  # Beside this binary, which is where a bundled desktop install puts it.
  try:
    let sibling = getAppDir() / componentBin
    if fileExists(sibling):
      return sibling
  except CatchableError, Defect:
    discard

  # The developer layout: `src/build-{debug,release}/bin/ct` is three levels
  # under the checkout, and `just build-tui` writes `build/bin/codetracer-tui`.
  try:
    let checkout = getAppDir().parentDir.parentDir.parentDir
    let devBuild = checkout / "build" / "bin" / componentBin
    if fileExists(devBuild):
      return devBuild
  except CatchableError, Defect:
    discard

  findExe(componentBin)

proc execHandoff*(binary: string; args: seq[string]) {.noreturn.} =
  ## Become `binary`. §3: "for a value naming a different binary, `exec`s it
  ## with the remaining arguments."
  ##
  ## `execv` rather than a subprocess, and it is load-bearing rather than
  ## stylistic: `src/frontend/tui/main.nim` refuses to draw when stdout is not a
  ## terminal (`isatty` on fd 1, exit 3). A front-end spawned as a child with
  ## pipes would get exactly that refusal, so the terminal the launcher handed
  ## this process has to be inherited rather than re-created — the same reason
  ## `launch/electron.nim` uses `execv` and the same property
  ## `src/tests/launcher/test_real_launcher_exec.nim` reads back off a pty.
  when defined(posix):
    let argc = args.len + 1
    var argv = cast[cstringArray](alloc0((argc + 1) * sizeof(cstring)))
    argv[0] = binary.cstring
    for i, arg in args:
      argv[i + 1] = arg.cstring
    argv[argc] = nil
    discard execv(binary.cstring, argv)
    # `execv` returns only on failure.
    stderr.writeLine("ct: could not start '" & binary & "': " &
                     osErrorMsg(osLastError()))
    quit(1)
  else:
    # Windows has no `execv` with the semantics above; `osproc` inherits the
    # console handles, which is what the terminal front-end needs there.
    var process = startProcess(binary, args = args,
                               options = {poParentStreams})
    quit(waitForExit(process))
