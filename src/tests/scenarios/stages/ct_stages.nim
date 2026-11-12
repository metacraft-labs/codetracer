## ct_stages.nim — the CodeTracer pack's stages (`../pack/codetracer.pack.yaml`).
##
## A scenario's stage is the custom set-up code that runs before its steps
## (DemoVideoScript-Format §4.7): it records programs, writes projects and
## configuration, and decides how the front-end will be started. Everything
## here runs BEFORE the stage channel closes; nothing in it is reachable from
## a step.
##
## One implementation for every front-end. The terminal and GPUI bindings
## link this module; the desktop's binding (TypeScript) runs it as the
## `ct-scenario-stage` command (`ct_scenario_stage.nim`). What differs per
## front-end is only how the prepared launch is started, which each binding
## does itself from the `Launch` this module produces.
##
## State isolation: every run gets its own scratch root with its own
## `CODETRACER_HOME`, XDG homes and layout directory, so a scenario never
## reads or writes the user's CodeTracer state (codetracer `AGENTS.md`,
## "Tests never touch your real CodeTracer state").

import std/[json, os, osproc, strutils, times, tables]

import ../../../frontend/tui/tests/fixtures/fixture_provider
import ../../../frontend/tui/tests/fixtures/plat65_nim_project
import ../../../frontend/viewmodel/host/native_nim_tracer

export fixture_provider

type
  Launch* = object
    ## What the front-end is started on, prepared by the stage.
    recording*: string      ## a recording folder ("" for Edit mode)
    project*: string        ## a project folder to edit ("" for a replay)
    file*: string           ## a file to open in Edit mode
    workDir*: string        ## the front-end's working directory
    width*, height*: int    ## the window, in the front-end's own unit
    tick*: int              ## -1: at the recording's entry
    keymap*: string         ## the base keymap ("" for the product default)
    env*: OrderedTable[string, string]

  StageState* = ref object
    root*: string           ## this run's scratch root
    launch*: Launch
    stagesRun*: seq[string]

proc repo*(): string = fixture_provider.repoRoot()

proc newStageState*(root = ""): StageState =
  ## A fresh, isolated state root for one run.
  let base =
    if root.len > 0: root
    else: getTempDir() / ("ct-scenario-" & $getCurrentProcessId() & "-" &
                          $int(epochTime() * 1000))
  createDir(base)
  result = StageState(root: base)
  result.launch.width = 0
  result.launch.height = 0
  result.launch.tick = -1
  result.launch.workDir = repo()
  let home = base / "ct-home"
  createDir(home)
  # The marker the product's own state guards look for: a CODETRACER_HOME a
  # test made, never a user's.
  writeFile(home / ".codetracer-test-home", "")
  for (k, v) in [("CODETRACER_HOME", home),
                 ("XDG_STATE_HOME", base / "state"),
                 ("XDG_DATA_HOME", base / "data"),
                 ("XDG_CONFIG_HOME", base / "config"),
                 ("CODETRACER_TUI_LAYOUT_DIR", base / "layout")]:
    createDir(v)
    result.launch.env[k] = v

proc configDir*(s: StageState): string =
  ## The product's configuration directory for this run
  ## (`ct_home.ctConfigDir`: `$CODETRACER_HOME/config`).
  s.launch.env["CODETRACER_HOME"] / "config"

proc argInt(args: JsonNode; key: string; default: int): int =
  if args.isNil or not args.hasKey(key): default
  else: args[key].getInt(default)

proc argStr(args: JsonNode; key: string; default = ""): string =
  if args.isNil or not args.hasKey(key): default
  else: args[key].getStr(default)

proc resolveProgram(program: string): string =
  ## A program named by the scenario: a path under the repository's
  ## `test-programs/`, or one relative to the repository.
  if program.isAbsolute: return program
  let r = repo()
  if fileExists(r / "test-programs" / program) or dirExists(r / "test-programs" / program):
    return "test-programs" / program
  program

proc recordProgram*(s: StageState; program, backend: string): string =
  ## A recording of `program`, through the fixture corpus: a cached recording
  ## when this build can read one made from the same sources, else `ct record`
  ## — the binary and subcommand a user records with. A missing recorder is a
  ## failed stage, named; never a scenario that silently passes.
  let rel = resolveProgram(program)
  var name = rel.replace("test-programs/", "").replace("/", "_").replace(".", "_")
  if backend.len > 0: name.add "_" & backend
  var spec: FixtureSpec
  var declared = false
  for d in DeclaredFixtures:
    if d.program == rel or d.name == program:
      spec = d
      declared = true
  if not declared:
    if rel.endsWith(".py"):
      spec = pythonScriptSpec(name, rel)
    else:
      spec = FixtureSpec(name: name, program: rel,
                         recorder: "the recorder `ct record` selects for " & rel,
                         probe: FixtureProbe(kind: pkNargo),
                         buildHint: "build the recorder for this language",
                         blockedOn: "")
      if not (rel.endsWith(".nr") or dirExists(repo() / rel)):
        # Not a Noir project: there is no probe for this recorder, so record
        # directly and let `ct record` name what is missing.
        let dest = fixtureCacheRoot(repo()) / (name & "-scenario")
        if isUsableTraceDir(dest) and cachedRecordingRefusal(dest).len == 0:
          return dest
        removeDir(dest)
        createDir(dest.parentDir)
        let ct = findCtBinary()
        if ct.len == 0: raise newException(IOError, "record-program: `ct` is not built")
        let cmd = quoteShell(ct) & " record " &
                  (if backend.len > 0: "--backend " & quoteShell(backend) & " " else: "") &
                  "-o " & quoteShell(dest) & " " & quoteShell(repo() / rel)
        let (output, code) = execCmdEx(cmd)
        if code != 0:
          raise newException(IOError, "record-program " & rel & ": `ct record` exited " &
                             $code & "\n" & output)
        if isUsableTraceDir(dest): return dest
        for kind, path in walkDir(dest):
          if kind == pcDir and isUsableTraceDir(path): return path
        raise newException(IOError, "record-program " & rel & ": no recording in " & dest)
  let resolved = resolveFixture(spec)
  if resolved.outcome != foRecorded:
    raise newException(IOError, "record-program: " &
                       missingPrereqMessage(spec, resolved.detail))
  resolved.tracePath

proc nimProject*(s: StageState) =
  ## The Nim compile-time tracing project (`plat65_nim_project`), written into
  ## this run's root, and a trace of its `static:` block made by the product's
  ## own route (`NativeNimTracer`, as `Ctrl+K T S` makes it). The window opens
  ## on that trace, in the project folder, so it shows `tracing.nim` with the
  ## macro call and every later trace opens beside it.
  let missing = plat65_nim_project.missingPrereq()
  if missing.len > 0:
    raise newException(IOError, "nim-project: prerequisite missing: " & missing)
  let root = s.root / "nim-project"
  removeDir(root)
  createDir(root)
  writeFile(root / "tracing.nim", TracingNim)
  writeFile(root / "build.nims", BuildNims)
  let folder = s.root / "nim-start"
  removeDir(folder)
  const StateVar = "CODETRACER_TUI_LAYOUT_DIR"
  let saved = getEnv(StateVar)
  let state = s.root / "nim-tracer-state"
  putEnv(StateVar, state)
  try:
    let t = newNativeNimTracer()
    let path = root / "tracing.nim"
    discard t.startNimTrace(NimTraceRequest(action: ntaStaticBlock, path: path,
                                            line: StaticLines.a, column: 3),
                            readFile(path).splitLines())
    while t.vm.running:
      if not t.pollNimTrace():
        sleep(50)
    if t.vm.phase != ntpDone:
      raise newException(IOError, "nim-project: tracing the static block: " & t.vm.message)
    moveDir(t.vm.tracePath, folder)
  finally:
    if saved.len > 0: putEnv(StateVar, saved) else: delEnv(StateVar)
    removeDir(state)
  s.launch.recording = folder
  s.launch.workDir = root
  s.launch.project = root

proc plantConfig*(s: StageState; file, content: string) =
  ## A file in the product's configuration directory, before the front-end
  ## starts (keybindings.json, a layout, settings).
  if file.contains("..") or file.isAbsolute:
    raise newException(ValueError, "plant-config: '" & file &
                       "' is not a name inside the configuration directory")
  let path = s.configDir / file
  createDir(path.parentDir)
  writeFile(path, content)

proc runStage*(s: StageState; use: string; args: JsonNode) =
  ## One stage call. `open-recording` / `open-project` only DECIDE the launch;
  ## the binding starts its own front-end from `s.launch` afterwards.
  s.stagesRun.add use
  case use
  of "record-program":
    s.launch.recording = s.recordProgram(argStr(args, "program"), argStr(args, "backend"))
  of "nim-project":
    s.nimProject()
  of "open-recording":
    let rec = argStr(args, "recording")
    if rec.len > 0:
      s.launch.recording = if rec.isAbsolute: rec else: repo() / rec
    if s.launch.recording.len == 0:
      raise newException(ValueError,
        "open-recording: no recording — call record-program or nim-project first, or pass `recording`")
    s.launch.width = argInt(args, "width", s.launch.width)
    s.launch.height = argInt(args, "height", s.launch.height)
    s.launch.tick = argInt(args, "tick", -1)
  of "open-project":
    var folder = argStr(args, "folder")
    if folder == "$project": folder = s.launch.project
    elif folder.len > 0 and not folder.isAbsolute:
      folder = repo() / resolveProgram(folder)
    if folder.len == 0:
      raise newException(ValueError, "open-project: no folder")
    s.launch.project = folder
    s.launch.recording = ""
    s.launch.file = argStr(args, "file")
    s.launch.workDir = folder
    s.launch.width = argInt(args, "width", s.launch.width)
    s.launch.height = argInt(args, "height", s.launch.height)
  of "select-keymap":
    let preset = argStr(args, "preset")
    if preset notin ["cua", "emacs", "vim", "kakoune"]:
      raise newException(ValueError, "select-keymap: unknown preset '" & preset & "'")
    s.launch.keymap = preset
  of "plant-config":
    s.plantConfig(argStr(args, "file"), argStr(args, "content"))
  of "start-from-layout":
    let layout = argStr(args, "layout")
    let src = currentSourcePath().parentDir.parentDir / "fixtures" / "layouts" / layout
    if not fileExists(src):
      raise newException(IOError, "start-from-layout: no layout fixture " & src)
    copyFile(src, s.launch.env["CODETRACER_TUI_LAYOUT_DIR"] / layout.extractFilename)
  else:
    raise newException(KeyError, "the CodeTracer pack has no stage '" & use & "'")

proc toJson*(s: StageState): JsonNode =
  ## The prepared launch, as `ct-scenario-stage` prints it for the desktop's
  ## binding.
  var env = newJObject()
  for k, v in s.launch.env: env[k] = %v
  %*{"root": s.root, "recording": s.launch.recording, "project": s.launch.project,
     "file": s.launch.file, "workDir": s.launch.workDir, "width": s.launch.width,
     "height": s.launch.height, "tick": s.launch.tick, "keymap": s.launch.keymap,
     "env": env}

proc removeStage*(s: StageState) =
  ## The run's scratch root, removed when the run ends.
  if s.root.len > 0 and s.root.startsWith(getTempDir()):
    removeDir(s.root)

proc saveTo*(s: StageState; path: string) =
  ## The state between two `ct-scenario-stage` calls (one per stage call).
  var j = s.toJson()
  j["stagesRun"] = %s.stagesRun
  writeFile(path, $j)

proc loadFrom*(path: string): StageState =
  let j = parseJson(readFile(path))
  result = StageState(root: j["root"].getStr)
  result.launch.recording = j["recording"].getStr
  result.launch.project = j["project"].getStr
  result.launch.file = j["file"].getStr
  result.launch.workDir = j["workDir"].getStr
  result.launch.width = j["width"].getInt
  result.launch.height = j["height"].getInt
  result.launch.tick = j["tick"].getInt
  result.launch.keymap = j["keymap"].getStr
  for k, v in j["env"]: result.launch.env[k] = v.getStr
  for u in j{"stagesRun"}.getElems: result.stagesRun.add u.getStr
