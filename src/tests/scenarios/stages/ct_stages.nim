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
import ../../../frontend/headless_app/layout_model
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
    review*: string         ## a review dataset (`ct review <PATH>`), or ""
    flags*: seq[string]     ## extra command-line options (`front-end-options`)
    welcome*: bool          ## start on the welcome screen (nothing open)
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


# --- pw1: agents, reviews and build projects ----------------------------------

proc writeExecutable(path, content: string) =
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
                            fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc stubAgent*(s: StageState; agent: string) =
  ## The Agent Activity pane's agent, replaced: the pane starts `codex-acp`
  ## from `PATH` (`index/ipc_subsystems/acp_ipc.nim`), so a `codex-acp`
  ## wrapper around a stdio ACP agent written for the tests goes first on the
  ## front-end's `PATH`. The real agent needs a paid account and the network,
  ## and cannot be made to refuse a turn or hold one on demand; everything on
  ## CodeTracer's side of the ACP boundary stays real. The agents' own headers
  ## give the protocol they implement.
  let script =
    case agent
    of "refusing": repo() / "src/tests/gui/tests/agent-activity/fixtures/acp-refusing-agent.js"
    of "replay": repo() / "src/tests/gui/tests/agent-activity-deepreview/fixtures/acp-replay-agent.js"
    else: raise newException(ValueError, "stub-agent: unknown agent '" & agent & "'")
  let node = findExe("node")
  if node.len == 0:
    raise newException(IOError, "stub-agent: prerequisite missing: `node` is not on PATH")
  let dir = s.root / "stub-agent"
  createDir(dir)
  writeExecutable(dir / "codex-acp",
    "#!/bin/sh\nexec " & quoteShell(node) & " " & quoteShell(script) & " \"$@\"\n")
  s.launch.env["PATH"] = dir & ":" & getEnv("PATH")
  s.launch.env["CT_FAKE_ACP_LOG"] = dir / "methods.log"

proc reviewDataset*(s: StageState; variant: string) =
  ## A review dataset (`deepreview/fixtures/sample-review.json`), written into
  ## the run's root as the variant asks, and the review the next
  ## `open-review` opens. A session reference names the replay agent
  ## (`agent-activity-deepreview/fixtures/acp-replay-agent.js`), which the
  ## review resolves the way `ct review collect` stamps it: by reference.
  let sample = repo() / "src/tests/gui/tests/deepreview/fixtures/sample-review.json"
  let dir = s.root / "review"
  createDir(dir)
  let replayAgent = repo() / "src/tests/gui/tests/agent-activity-deepreview/fixtures/acp-replay-agent.js"
  proc withSession(id: string; args: seq[string]): JsonNode =
    result = parseJson(readFile(sample))
    result["session"] = %*{"sessionId": id, "backend": "acp", "workspacePath": dir,
                           "taskId": "", "agentCommand": replayAgent, "agentArgs": args,
                           "endpoint": ""}
  var dataset: JsonNode
  case variant
  of "plain":
    dataset = parseJson(readFile(sample))
  of "session":
    dataset = withSession("session-fixture", @[])
  of "session-pruned":
    dataset = withSession("session-pruned", @[])
  of "test-run":
    createDir(dir / "review-trace")
    dataset = withSession("session-fixture", @["--test-run", "--trace-dir=" & dir / "review-trace"])
  of "test-run-partial":
    dataset = withSession("session-fixture", @["--test-run-partial"])
  of "evidence":
    # The datasets the replayed session's evidence calls name: two that
    # exist, one cleaned up (`gone.json`, never written).
    let evidence = dir / "evidence"
    createDir(evidence)
    for (name, title, a, b) in [("iteration-1.json", "DeepReview: iteration one", 0, 2),
                                ("iteration-2.json", "DeepReview: iteration two", 2, 3)]:
      var d = parseJson(readFile(sample))
      d["sessionTitle"] = %title
      var files = newJArray()
      for i in a ..< b: files.add d["files"][i]
      d["files"] = files
      writeFile(evidence / name, $d)
    dataset = withSession("session-fixture", @["--evidence", "--evidence-dir=" & evidence])
  else:
    raise newException(ValueError, "review-dataset: unknown variant '" & variant & "'")
  let path = dir / (variant & ".json")
  writeFile(path, pretty(dataset))
  s.launch.review = path

const
  CompilerNargoOutput = "\e[1m\e[38;5;9merror\e[0m: Expected type bool, found type Field\n" &
    "  \e[1m\e[38;5;12m-->\e[0m src/main.nr:3:19\n   |\n 3 |     let b: bool = a;\n" &
    "   |                   ^ Expected type bool, found type Field\n\n" &
    "\e[1m\e[38;5;9merror\e[0m: Aborting due to 1 previous error\n"
  CompilerTscOutput = "src/index.ts(4,7): error TS2322: Type 'string' is not assignable to type 'number'.\n" &
    "src/index.ts(7,7): error TS2322: Type 'number' is not assignable to type 'string'.\n" &
    "src/index.ts(11,17): error TS2339: Property 'nonExistent' does not exist on type '{}'.\n" &
    "\nFound 3 errors.\n"
  CompilerGccOutput = "main.c:10:5: \e[1;31merror:\e[0m expected ';' before '}' token\n" &
    "   10 |     printf(\"hello\")\n      |     ^~~~~~\n" &
    "main.c:15:12: \e[1;35mwarning:\e[0m unused variable 'x' [-Wunused-variable]\n"

proc projectFixture*(s: StageState; name: string) =
  ## A named project, written into the run's root, and the folder the next
  ## `open-project` (`folder: $project`) opens. Its `.codetracer/build.yaml`
  ## declares the tasks the desktop's main process runs for real.
  let root = s.root / ("project-" & name)
  removeDir(root)
  createDir(root)
  proc tasks(lines: varargs[string]) =
    createDir(root / ".codetracer")
    writeFile(root / ".codetracer" / "build.yaml", "tasks:\n" & lines.join("\n") & "\n")
  case name
  of "c-build-tasks":
    # The PLAT-56 project: the real gcc fails on main.c with two errors and
    # a warning, and builds ok.c.
    createDir(root / "src")
    writeFile(root / "src" / "main.c", Plat56MainC)
    writeFile(root / "src" / "ok.c", Plat56OkC)
    tasks("  fail:", "    command: \"" & Plat56FailCommand & "\"", "    default: true",
          "  pass:", "    command: \"" & Plat56PassCommand & "\"",
          "  slow:", "    command: \"sleep 30\"",
          "  clean:", "    command: \"gcc -fdiagnostics-color=always -c src/ok.c -o /dev/null\"")
  of "noir-build":
    createDir(root / "src")
    writeFile(root / "Nargo.toml", Plat55NargoToml)
    writeFile(root / "src" / "main.nr", Plat55MainNr)
    writeFile(root / "src" / "util.nr", Plat55UtilNr)
  of "run-build-saves":
    # The build prints the file it read, so what it saw is on screen.
    writeFile(root / "note.c", "int on_disk = 1;\n")
    tasks("  show:", "    command: \"cat note.c\"", "    default: true")
  of "lone-file":
    writeFile(root / "lone.c", "int lone_marker = 1;\n")
  of "lone-file-task":
    writeFile(root / "lone.c", "int lone_marker = 1;\n")
    tasks("  check:", "    command: \"grep -c lone_marker lone.c\"")
  of "build-streams":
    # Plain progress on stdout and on stderr: no location, no severity word.
    writeFile(root / "README", "build-streams\n")
    tasks("  streams:",
          "    command: \"printf 'Compiling main\\\\nLinking main\\\\n'; printf 'progress: 2 of 2 units done\\\\n' >&2\"",
          "    default: true")
  of "compiler-output":
    # Each compiler's diagnostics as it prints them, printed by a task.
    writeFile(root / "nargo.txt", CompilerNargoOutput)
    writeFile(root / "tsc.txt", CompilerTscOutput)
    writeFile(root / "gcc.txt", CompilerGccOutput)
    tasks("  nargo:", "    command: \"cat nargo.txt >&2; exit 1\"", "    default: true",
          "  tsc:", "    command: \"cat tsc.txt; exit 2\"",
          "  gcc:", "    command: \"cat gcc.txt >&2; exit 1\"")
  else:
    raise newException(ValueError, "project-fixture: unknown project '" & name & "'")
  s.launch.project = root
  s.launch.workDir = root

proc gitWorkspace*(s: StageState) =
  ## A committed git repository the agent works on in its own worktree.
  let root = s.root / "git-workspace"
  removeDir(root)
  createDir(root / "src")
  writeFile(root / "src" / "feature.nim", "proc featureValue*(): int =\n  1\n")
  writeFile(root / "feature_test.nim", "import src/feature\n\ndoAssert featureValue() == 1\n")
  for args in [@["init", "."], @["config", "user.email", "codetracer-gui@example.invalid"],
               @["config", "user.name", "CodeTracer GUI E2E"], @["config", "commit.gpgsign", "false"],
               @["add", "."], @["commit", "-m", "Initial fixture"]]:
    let (output, code) = execCmdEx("git " & args.quoteShellCommand, workingDir = root)
    if code != 0:
      raise newException(IOError, "git-workspace: git " & args.join(" ") & ": " & output)
  s.launch.project = root
  s.launch.workDir = root

proc agentHarbor*(s: StageState) =
  ## The real Agent Harbor the worktree session runs on. There is no
  ## stand-in: the session's whole point is Harbor's worktree and its task
  ## history, so without a server this is a missing prerequisite, named.
  let url = getEnv("AGENT_HARBOR_M7_BASE_URL")
  if url.len == 0:
    raise newException(IOError, "agent-harbor: prerequisite missing: AGENT_HARBOR_M7_BASE_URL " &
      "(a real Agent Harbor REST server prepared with the CodeTracer worktree scenario)")
  for k in ["AGENT_HARBOR_M7_BASE_URL", "AGENT_HARBOR_M7_API_KEY", "AGENT_HARBOR_M7_SCENARIO",
            "AGENT_HARBOR_M7_MOCK_AGENT_BINARY"]:
    if existsEnv(k): s.launch.env[k] = getEnv(k)

proc plantEditLayout*(s: StageState; fixture: string) =
  ## A saved edit-mode layout a previous session left behind
  ## (`$CODETRACER_HOME/config/default_edit_layout.json`), from the review
  ## fixtures (`deepreview/fixtures/<fixture>.json`).
  let src = repo() / "src/tests/gui/tests/deepreview/fixtures" / (fixture & ".json")
  if not fileExists(src):
    raise newException(IOError, "plant-edit-layout: no layout fixture " & src)
  createDir(s.configDir)
  copyFile(src, s.configDir / "default_edit_layout.json")

# --- gpui -------------------------------------------------------------------

proc copyProject*(s: StageState; folder: string) =
  ## A copy of a project folder (a path under test-programs, or a single file
  ## there) in this run's project folder, so an Edit-mode scenario writes to
  ## its own files; `open-project` with `folder: $project` opens it.
  let rel = resolveProgram(folder)
  let src = if rel.isAbsolute: rel else: repo() / rel
  let dest = s.root / "project"
  removeDir(dest)
  if dirExists(src): copyDir(src, dest)
  elif fileExists(src):
    createDir(dest)
    copyFile(src, dest / src.extractFilename)
  else:
    raise newException(IOError, "copy-project: no folder or file " & src)
  s.launch.project = dest
  s.launch.workDir = dest

proc savedLayout*(s: StageState; file, ops: string) =
  ## The shared default with layout commands applied, saved as the
  ## front-end's own layout document — what a rearranged window leaves for
  ## its next start (the commands are `layout_model`'s, the product's own).
  if file.len == 0 or file.contains('/') or file.contains(".."):
    raise newException(ValueError, "saved-layout: '" & file & "' is not a file name")
  proc paneOf(n: string): PaneKind =
    for k in PaneKind:
      if $k == n: return k
    raise newException(ValueError, "saved-layout: no pane '" & n & "'")
  let shared = sharedDefaultLayout()
  var layout = initLayout(shared.tree, sharedDefaultDocked())
  for op in ops.split(','):
    let p = op.strip.split(':')
    if p.len == 0 or p[0].len == 0: continue
    let cmd =
      case p[0]
      of "dock":
        var edge = leBottom
        for e in LayoutEdge:
          if $e == p[2]: edge = e
        cmdDock(paneOf(p[1]), edge)
      of "activate": cmdActivateTab(paneOf(p[1]))
      of "merge": cmdMergeIntoStack(paneOf(p[1]), paneOf(p[2]))
      else: raise newException(ValueError, "saved-layout: unknown op '" & op & "'")
    let r = apply(layout, cmd)
    if r.kind != loApplied:
      raise newException(ValueError, "saved-layout: '" & op & "' was refused")
    layout = r.layout
  let path = s.launch.env["CODETRACER_TUI_LAYOUT_DIR"] / file
  createDir(path.parentDir)
  writeFile(path, $saveLayout(layout))

const
  FlameScene = "res://scenes/hcr2_probe.tscn"
  FlamePatchAt = 120

proc hcrFlame*(s: StageState; platform, edit, arm: string) =
  ## The hot-code-reload flame demo, prepared for a window whose palette runs
  ## "Apply Edit & Hot-Reload" (`src/tests/gui/tests/hcr-apply-edit/
  ## flame-hcr-driver.ts` resolves the same paths). The window gets the
  ## CODETRACER_HCR_* settings; a watcher started here runs the patched flame
  ## against the coordinator socket once the command opens it, which is what
  ## the demo's own harness did beside the test. A missing piece fails the
  ## stage, named.
  let want = if platform.len > 0: platform.toLowerAscii else: "linux"
  when not defined(windows):
    if want == "windows":
      raise newException(IOError, "hcr-flame: the Windows arm (the Windows " &
        "HCR driver, its .pdb and .dll) needs a Windows host; this is " & hostOS)
  if arm.len > 0 and arm notin ["green", "harness-launches", "live-edit"]:
    raise newException(ValueError, "hcr-flame: unknown arm '" & arm & "'")
  let workspace = repo().parentDir
  let flame = getEnv("CODETRACER_FLAME_DEMO_REPO", workspace / "codetracer-flame-demo")
  let engineRepo = workspace / "codetracer-engine-godot"
  var engine = ""
  for cand in [engineRepo / "bin" / "godot.linuxbsd.template_debug.x86_64.hcrq",
               engineRepo / "bin" / "godot.linuxbsd.template_debug.x86_64.hcrgpu"]:
    if fileExists(cand) and engine.len == 0: engine = cand
  if engine.len == 0:
    raise newException(IOError, "hcr-flame: prerequisite missing: no patchable Godot engine under " &
                       engineRepo / "bin" & " (codetracer-engine-godot, built with its HCR target)")
  let driver = getEnv("CODETRACER_HCR_DRIVER", flame / "artifacts" / "h3-driver" / "hcr_patch_driver")
  for (what, where) in [
      ("the flame demo checkout (codetracer-flame-demo)", flame),
      ("the imported Godot project (`just import` in the flame demo)", flame / ".godot"),
      ("the patchable FlameField GDExtension (`just gdext-hcr`)",
       flame / "bin" / "libflamefield.macos.template_debug.so"),
      ("the prebuilt HCR coordinator driver", driver),
      ("the apply-edit command", flame / "scripts" / "ct_hcr_apply_edit.py")]:
    if not (fileExists(where) or dirExists(where)):
      raise newException(IOError, "hcr-flame: prerequisite missing: " & what & ": " & where)
  let work = s.root / "hcr"
  createDir(work)
  let socket = "/tmp" / ("ct-hcr-" & $getCurrentProcessId() & ".sock")
  let ticks = work / "ticks-patched.log"
  writeFile(ticks, "")
  for (k, v) in [("CODETRACER_HCR_APPLY_EDIT_CMD", flame / "scripts" / "ct_hcr_apply_edit.py"),
                 ("CODETRACER_HCR_DRIVER", driver),
                 ("CODETRACER_HCR_EDIT", (if edit.len > 0: edit else: "rise_speed=5.4")),
                 ("CODETRACER_HCR_WAIT_FOR", ticks),
                 ("CODETRACER_HCR_MARKER", "CT_H2 frame=" & $FlamePatchAt & " "),
                 ("CODETRACER_HCR_MARKER_TIMEOUT_MS", "180000"),
                 ("CODETRACER_HCR_SOCKET", socket),
                 ("CODETRACER_HCR_REPORT", work / "apply-edit-report.json")]:
    s.launch.env[k] = v
  # The patched flame, started when the command the user runs opens the
  # coordinator's socket (and not before: the coordinator waits to read the
  # flame's own frame line before it publishes).
  let watcher = "for i in $(seq 1 1200); do [ -S " & quoteShell(socket) & " ] && break; sleep 0.1; done; " &
    "[ -S " & quoteShell(socket) & " ] || exit 0; " &
    "CT_H2_FRAMES=360 CT_H2_TICKFILE=" & quoteShell(ticks) & " REPRO_HCR_AGENT_SOCKET=" & quoteShell(socket) &
    " exec " & quoteShell(engine) & " --headless --path " & quoteShell(flame) & " --scene " & FlameScene &
    " > " & quoteShell(work / "patched.log") & " 2>&1"
  if arm in ["green", "harness-launches"]:
    # "Launch Under Live Edit (HCR)" runs the workspace's launch
    # configuration: a scratch workspace holding the flame project's derived
    # `.vscode/launch.json`, opened in Edit mode by `open-project $project`.
    let launchJson = flame / ".vscode" / "launch.json"
    if not fileExists(launchJson):
      raise newException(IOError, "hcr-flame: prerequisite missing: the flame project's " &
                         "derived launch configuration: " & launchJson)
    let ws = s.root / "hcr-workspace"
    createDir(ws / ".vscode")
    copyFile(launchJson, ws / ".vscode" / "launch.json")
    s.launch.project = ws
    return
  discard startProcess("/bin/sh", args = ["-c", watcher], options = {})

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
    # Without `dataset`, the one `review-dataset` wrote.
    let dataset = argStr(args, "dataset")
    if dataset.len > 0:
      let path = if dataset.isAbsolute: dataset else: repo() / dataset
      if not fileExists(path):
        raise newException(IOError, "open-review: no dataset at " & path)
      s.launch.review = path
    elif s.launch.review.len == 0:
      raise newException(ValueError, "open-review: no dataset — name one, or call review-dataset first")
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
  # --- pw1 ---
  of "stub-agent":
    s.stubAgent(argStr(args, "agent"))
  of "review-dataset":
    s.reviewDataset(argStr(args, "variant", "plain"))
  of "plant-edit-layout":
    s.plantEditLayout(argStr(args, "fixture"))
  of "project-fixture":
    s.projectFixture(argStr(args, "name"))
  of "git-workspace":
    s.gitWorkspace()
  of "agent-harbor":
    s.agentHarbor()
  of "open-welcome":
    s.launch.recording = ""
    s.launch.project = ""
    s.launch.review = ""
    s.launch.welcome = true
    s.launch.width = argInt(args, "width", s.launch.width)
    s.launch.height = argInt(args, "height", s.launch.height)
  of "copy-project":
    s.copyProject(argStr(args, "folder"))
  of "saved-layout":
    s.savedLayout(argStr(args, "file"), argStr(args, "ops"))
  of "start-from-layout":
    let layout = argStr(args, "layout")
    let src = currentSourcePath().parentDir.parentDir / "fixtures" / "layouts" / layout
    if not fileExists(src):
      raise newException(IOError, "start-from-layout: no layout fixture " & src)
    copyFile(src, s.launch.env["CODETRACER_TUI_LAYOUT_DIR"] / layout.extractFilename)
  of "hcr-flame":
    s.hcrFlame(argStr(args, "platform"), argStr(args, "edit"), argStr(args, "arm"))
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
     "review": s.launch.review, "flags": s.launch.flags, "welcome": s.launch.welcome,
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
  result.launch.review = j{"review"}.getStr
  result.launch.welcome = j{"welcome"}.getBool
  for k, v in j["env"]: result.launch.env[k] = v.getStr
  for f in j{"flags"}.getElems: result.launch.flags.add f.getStr
  for u in j{"stagesRun"}.getElems: result.stagesRun.add u.getStr
