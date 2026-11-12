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
import ../../../frontend/tui/tests/fixtures/[plat53_noir_project, plat55_noir_build,
                                            plat62_noir_circuit, plat63_verno_projects]
import ../../../frontend/viewmodel/tests/unit/build_fixtures/plat56_c_build
import results
import ../../../tools/demo_request_session
import ../../../frontend/tui/tests/fixtures/visual_fixture

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
    review*: string         ## a review dataset (`ct review <json>`), "" for none
    flags*: seq[string]     ## extra command-line options (`front-end-options`)
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

# --- terminal ---------------------------------------------------------------

proc writeProject*(s: StageState; files: JsonNode) =
  ## A project folder written from `files` (relative path -> content) into
  ## this run's root. It becomes the folder the next `open-project` (with
  ## `folder: $project`) edits, and the working directory of the next
  ## `open-recording`, so a replay started there edits it on Ctrl+F5.
  let root = s.root / "project"
  createDir(root)
  if files != nil and files.kind == JObject:
    for rel, content in files:
      if rel.contains("..") or rel.isAbsolute:
        raise newException(ValueError, "write-project: '" & rel &
                           "' is not a path inside the project")
      let path = root / rel
      if rel.endsWith("/"):
        createDir(path)
      else:
        createDir(path.parentDir)
        writeFile(path, content.getStr)
  s.launch.project = root
  s.launch.workDir = root

proc fixtureProject*(s: StageState; name: string) =
  ## One of the repository's fixture projects (the ones its suites build
  ## with), written into this run's project folder; `write-project` may add
  ## files to it afterwards.
  let root = s.root / "project"
  createDir(root)
  proc put(rel, content: string) =
    createDir((root / rel).parentDir)
    writeFile(root / rel, content)
  case name
  of "c-build":
    # PLAT-56's C project: src/main.c fails to build, src/ok.c builds.
    put("src/main.c", Plat56MainC)
    put("src/ok.c", Plat56OkC)
  of "noir-build-errors":
    # PLAT-55's Noir crate whose `nargo compile` reports two type errors.
    put("Nargo.toml", Plat55NargoToml)
    put("src/main.nr", Plat55MainNr)
    put("src/util.nr", Plat55UtilNr)
  of "verno-type-error", "verno-counterexample":
    # PLAT-63's Verno packages with the replaying `verno` stand-in (the
    # recorded run of the real verifier; its header in
    # `plat63_verno_projects.nim` says why it stands in), first on PATH.
    let run = if name == "verno-type-error": writeTypeErrRun() else: writeCounterexampleRun()
    removeDir(root)
    copyDir(run.root, root)
    copyDir(run.bin, s.root / "verno-bin")
    run.removeRun()
    for f in walkDirRec(s.root / "verno-bin"):
      if f.extractFilename == "verno":
        setFilePermissions(f, {fpUserRead, fpUserWrite, fpUserExec})
    s.launch.env["PATH"] = (s.root / "verno-bin") & ":" & getEnv("PATH")
  of "vcs-repo":
    # PLAT-47's git repository: a commit, then a modified, an added (staged)
    # and an untracked file (`scripts/plat47-vcs-fixture.sh`).
    removeDir(root)
    let (output, code) = execCmdEx("bash " &
      quoteShell(repo() / "scripts" / "plat47-vcs-fixture.sh") & " " & quoteShell(root))
    if code != 0:
      raise newException(IOError, "fixture-project vcs-repo: " & output)
  of "noir-constraints":
    # PLAT-62's Noir circuit, measured by `nargo info --json`.
    put("Nargo.toml", Plat62NargoToml)
    for (path, content) in Plat62Files: put(path, content)
  of "noir-tests":
    # PLAT-53's Noir crate with one passing and one failing test.
    put("Nargo.toml", Plat53NargoToml)
    put("src/main.nr", Plat53MainNr)
  else:
    raise newException(ValueError, "fixture-project: no fixture project '" & name & "'")
  s.launch.project = root
  s.launch.workDir = root

proc requestSession*(s: StageState) =
  ## The RS-M4 demo request session: a real `.ct` container with eight
  ## request spans over a recorded timeline, written by the canonical writer
  ## (`src/tools/demo_request_session`), as the recording to open.
  let folder = s.root / "request-session"
  removeDir(folder)
  createDir(folder)
  let written = writeDemoRequestSession(folder)
  if written.isErr:
    raise newException(IOError, "request-session: " & $written.error)
  s.launch.recording = folder

proc plantState*(s: StageState; file, content: string) =
  ## A file in the front-end's state directory (its saved layout, its keymap
  ## preference) before it starts.
  if file.contains("..") or file.isAbsolute:
    raise newException(ValueError, "plant-state: '" & file &
                       "' is not a name inside the state directory")
  let path = s.launch.env["CODETRACER_TUI_LAYOUT_DIR"] / file
  createDir(path.parentDir)
  writeFile(path, content)

proc visualRecording*(s: StageState) =
  ## The visual fixture's `gl_scene` recording (made by ct-mcr), opened with
  ## the real `ct_gfx_player`; a missing recording or player is a failed
  ## stage, named.
  let skip = visualFixtureSkip()
  if skip.len > 0:
    raise newException(IOError, "visual-recording: " & skip)
  s.launch.recording = visualFixtureFolder()

proc frontEndOptions*(s: StageState; options: JsonNode; term: string;
                      env: JsonNode = nil) =
  ## Command-line options the front-end starts with (`name: value` becomes
  ## `--name=value`, an empty value `--name`), the terminal type the
  ## terminal flavour announces (`TERM`), and environment variables (a
  ## `$project` in a value is the stage's project folder) — the options,
  ## terminals and environment a user starts the product with.
  if options != nil and options.kind == JObject:
    for k, v in options:
      let val = (if v.kind == JString: v.getStr else: $v)
      s.launch.flags.add(if val.len == 0: "--" & k else: "--" & k & "=" & val)
  if term.len > 0: s.launch.env["TERM"] = term
  if env != nil and env.kind == JObject:
    for k, v in env:
      s.launch.env[k] = v.getStr.replace("$project", s.launch.project)

proc dropRecordedFile*(s: StageState; name: string) =
  ## The prepared recording, copied into this run's root without the
  ## recorded source file `name`: a recording that lacks one of its files.
  if s.launch.recording.len == 0:
    raise newException(ValueError, "drop-recorded-file: no recording prepared")
  let copy = s.root / "recording-copy"
  removeDir(copy)
  copyDir(s.launch.recording, copy)
  var removed = 0
  for f in walkDirRec(copy / "files"):
    if f.extractFilename == name:
      removeFile(f)
      inc removed
  if removed != 1:
    raise newException(IOError, "drop-recorded-file: " & $removed &
                       " recorded files are named " & name)
  s.launch.recording = copy

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
  of "open-review":
    # `ct review <dataset>`: a DeepReview dataset (a path relative to the
    # repository, or absolute), opened in the review layout.
    let dataset = argStr(args, "dataset")
    if dataset.len == 0:
      raise newException(ValueError, "open-review: no dataset")
    let path = if dataset.isAbsolute: dataset else: repo() / dataset
    if not fileExists(path):
      raise newException(IOError, "open-review: no dataset at " & path)
    s.launch.review = path
    s.launch.recording = ""
    s.launch.project = ""
    s.launch.width = argInt(args, "width", s.launch.width)
    s.launch.height = argInt(args, "height", s.launch.height)
  of "select-keymap":
    let preset = argStr(args, "preset")
    if preset notin ["cua", "emacs", "vim", "kakoune"]:
      raise newException(ValueError, "select-keymap: unknown preset '" & preset & "'")
    s.launch.keymap = preset
  of "plant-config":
    s.plantConfig(argStr(args, "file"), argStr(args, "content"))
  of "write-project":
    s.writeProject(if args.isNil: nil else: args{"files"})
  of "plant-state":
    s.plantState(argStr(args, "file"), argStr(args, "content"))
  of "visual-recording":
    s.visualRecording()
  of "request-session":
    s.requestSession()
  of "fixture-project":
    s.fixtureProject(argStr(args, "name"))
  of "drop-recorded-file":
    s.dropRecordedFile(argStr(args, "name"))
  of "front-end-options":
    s.frontEndOptions(if args.isNil: nil else: args{"options"}, argStr(args, "term"),
                      if args.isNil: nil else: args{"env"})
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
     "review": s.launch.review, "flags": s.launch.flags, "env": env}

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
  result.launch.review = j{"review"}.getStr
  for k, v in j["env"]: result.launch.env[k] = v.getStr
  for f in j{"flags"}.getElems: result.launch.flags.add f.getStr
  for u in j{"stagesRun"}.getElems: result.stagesRun.add u.getStr
